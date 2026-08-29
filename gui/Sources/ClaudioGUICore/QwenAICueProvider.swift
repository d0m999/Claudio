import CoreFoundation
import Dispatch
import Foundation

/// One fixed-region Qwen speech AI cue adapter. Region identity selects a registry-owned profile;
/// callers cannot supply an endpoint, model, voice or output format.
public struct QwenAICueProvider: AICueProvider, Sendable {
    private static let acceptedSSEMediaTypes: Set<String> = ["text/event-stream"]

    public let profile: AICueProviderProfile
    private let sseTransport: any AICueSSETransport

    public init(profileID: AICueProviderProfileID) throws {
        try self.init(
            profileID: profileID,
            sseTransport: AICueURLSessionSSETransport())
    }

    package init(
        profileID: AICueProviderProfileID,
        sseTransport: any AICueSSETransport
    ) throws {
        let profile: AICueProviderProfile
        do {
            profile = try AICueProviderRegistry().profile(for: profileID)
        } catch {
            throw AICueProviderError.invalidRequest
        }
        guard
            profile.providerID == .qwen,
            profile.credentialValidationPolicy == .deferredUntilExplicitGeneration,
            profile.supportedModalities == [.speech],
            profile.constraints.supportsInstructionControl,
            profile.routes[.speech]?.transport.isPCM == true
        else {
            throw AICueProviderError.invalidRequest
        }
        self.profile = profile
        self.sseTransport = sseTransport
    }

    /// Qwen has no read-only API-key probe. Credential validation happens only through an explicit
    /// generation lease; this method fails closed if a caller tries to use the probe seam.
    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        throw AICueProviderError.invalidRequest
    }

    public func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        guard
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
        else {
            throw AICueProviderError.deadlineExceeded
        }
        let instructions = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            request.profileID == profile.id,
            request.modality == .speech,
            !instructions.isEmpty,
            let route = profile.routes[.speech],
            route.authentication == .bearerAPIKey,
            case .ssePCM(let pcmFormat) = route.transport,
            let voiceID = route.voiceID,
            let spokenContent = request.spokenContent,
            !spokenContent.isEmpty,
            let languageTag = request.languageTag,
            AICueLanguageTagMatcher.matches(
                languageTag,
                allowlist: route.supportedLanguageTags),
            let languageFamily = AICueLanguageTagMatcher.family(for: languageTag),
            (1...profile.constraints.maximumDurationMilliseconds).contains(
                request.targetDurationMilliseconds),
            let scheme = route.endpoint.scheme,
            let host = route.endpoint.host,
            let expectedOrigin = try? AICueOrigin(
                scheme: scheme,
                host: host,
                port: route.endpoint.port)
        else {
            throw AICueProviderError.invalidRequest
        }
        let languageType = languageType(for: languageFamily)

        let body = try jsonBody([
            "input": [
                "instructions": instructions,
                "language_type": languageType,
                "text": spokenContent,
                "voice": voiceID,
            ],
            "model": route.modelID,
        ])
        let transportRequest = AICueTransportRequest(
            method: .post,
            url: route.endpoint,
            expectedOrigin: expectedOrigin,
            expectedPath: route.endpoint.path,
            headers: [
                "accept": "text/event-stream",
                "content-type": "application/json",
                "X-DashScope-SSE": "enable",
            ],
            body: body,
            acceptedMediaTypes: Self.acceptedSSEMediaTypes,
            maximumWireBytes: AICueTransportCeilings.qwenSSEWireBytes,
            deadline: deadline)

        var sequence = AICueSSETerminalValidator()
        var pcm = Data()
        pcm.reserveCapacity(AICueTransportCeilings.qwenDecodedPCMBytes)
        var providerRequestID: String?
        do {
            for try await event in sseTransport.events(
                for: transportRequest,
                authentication: route.authentication,
                credential: credential)
            {
                try Task.checkCancellation()
                let chunk = try decode(event, expectedPCMFormat: pcmFormat)
                try sequence.accept(isTerminal: chunk.isTerminal)
                if let requestID = chunk.requestID {
                    if let providerRequestID, providerRequestID != requestID {
                        throw AICueProviderError.invalidAudioResponse
                    }
                    providerRequestID = requestID
                }
                if chunk.isTerminal {
                    guard chunk.encodedPCM.isEmpty else {
                        throw AICueProviderError.invalidAudioResponse
                    }
                    continue
                }
                guard !chunk.encodedPCM.isEmpty else {
                    throw AICueProviderError.invalidAudioResponse
                }
                var decoder = AICueBoundedBase64Decoder(
                    maximumDecodedBytes: AICueTransportCeilings.qwenDecodedPCMBytes - pcm.count)
                try decoder.append(chunk.encodedPCM)
                pcm.append(try decoder.finish())
            }
            try Task.checkCancellation()
            try sequence.finish()
        } catch let error as AICueProviderError {
            throw error
        } catch AICueDecodedPayloadError.decodedPayloadTooLarge {
            throw AICueProviderError.responseTooLarge
        } catch is AICueDecodedPayloadError, is AICueSSESequenceError {
            throw AICueProviderError.invalidAudioResponse
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error,
                unexpectedMediaType: .invalidAudioResponse)
        }

        let wav = try makeWAV(from: pcm, format: pcmFormat)
        return AICueProviderAudioResponse(
            data: wav,
            mediaType: "audio/wav",
            modelID: route.modelID,
            requestID: providerRequestID)
    }

    private func languageType(for family: AICueLanguageFamily) -> String {
        switch family {
        case .chinese: return "Chinese"
        case .english: return "English"
        }
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw AICueProviderError.invalidRequest
        }
    }

    private func decode(
        _ event: AICueSSEEvent,
        expectedPCMFormat: AICuePCMFormat
    ) throws -> QwenSSEChunk {
        guard
            let data = event.data.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusCode = integer(root["status_code"])
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        guard statusCode == 200 else { throw providerError(for: statusCode) }
        guard
            let output = root["output"] as? [String: Any],
            let audio = output["audio"] as? [String: Any],
            let encodedPCM = audio["data"] as? String
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        try validateOptionalFormatDeclarations(audio, expectedPCMFormat: expectedPCMFormat)

        let isTerminal: Bool
        switch output["finish_reason"] {
        case is NSNull:
            isTerminal = false
            guard audio["url"] == nil || audio["url"] is NSNull else {
                throw AICueProviderError.invalidAudioResponse
            }
        case let value as String where value == "stop":
            isTerminal = true
            if let url = audio["url"], !(url is NSNull), !(url is String) {
                throw AICueProviderError.invalidAudioResponse
            }
        default:
            throw AICueProviderError.invalidAudioResponse
        }
        return QwenSSEChunk(
            encodedPCM: encodedPCM,
            isTerminal: isTerminal,
            requestID: sanitizedAICueProviderRequestID(root["request_id"] as? String))
    }

    private func validateOptionalFormatDeclarations(
        _ audio: [String: Any],
        expectedPCMFormat: AICuePCMFormat
    ) throws {
        for key in ["sample_rate", "sampleRate"] where audio[key] != nil {
            guard integer(audio[key]) == expectedPCMFormat.sampleRate else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        for key in ["channels", "channel"] where audio[key] != nil {
            guard integer(audio[key]) == expectedPCMFormat.channels else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        for key in ["bits_per_sample", "bitsPerSample"] where audio[key] != nil {
            guard integer(audio[key]) == expectedPCMFormat.bitsPerSample else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        for key in ["format", "response_format"] where audio[key] != nil {
            guard (audio[key] as? String)?.lowercased() == "pcm" else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        if let byteOrder = audio["byte_order"] {
            guard
                ["little", "little-endian", "le"].contains(
                    (byteOrder as? String)?.lowercased() ?? "")
            else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
    }

    private func integer(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private func providerError(for statusCode: Int) -> AICueProviderError {
        switch statusCode {
        case 401: return .invalidCredential
        case 402: return .insufficientCredits
        case 403: return .forbidden
        case 429: return .rateLimited(retryAfterSeconds: nil)
        case 500...599: return .serviceUnavailable
        default: return .invalidRequest
        }
    }

    private func makeWAV(from pcm: Data, format: AICuePCMFormat) throws -> Data {
        guard
            !pcm.isEmpty,
            pcm.count.isMultiple(of: format.bitsPerSample / 8),
            pcm.count <= AICueTransportCeilings.qwenDecodedPCMBytes
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        let byteRate =
            format.sampleRate
            * format.channels
            * format.bitsPerSample / 8
        let blockAlign =
            format.channels
            * format.bitsPerSample / 8
        var wav = Data()
        wav.reserveCapacity(44 + pcm.count)
        wav.append(Data("RIFF".utf8))
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(format.channels))
        wav.appendLittleEndian(UInt32(format.sampleRate))
        wav.appendLittleEndian(UInt32(byteRate))
        wav.appendLittleEndian(UInt16(blockAlign))
        wav.appendLittleEndian(UInt16(format.bitsPerSample))
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        guard wav.count <= AICueTransportCeilings.qwenDecodedPCMBytes + 44 else {
            throw AICueProviderError.responseTooLarge
        }
        return wav
    }
}

extension AICueProviderAudioTransport {
    fileprivate var isPCM: Bool {
        if case .ssePCM = self { return true }
        return false
    }
}

private struct QwenSSEChunk {
    let encodedPCM: String
    let isTerminal: Bool
    let requestID: String?
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
