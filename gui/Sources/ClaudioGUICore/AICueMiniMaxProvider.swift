import CoreFoundation
import Dispatch
import Foundation

/// The allowlisted MiniMax Mandarin speech AI cue adapter. It never owns a credential or a
/// free-form endpoint: JSON compilation and response decoding live here, while the shared unary
/// transport enforces exact-origin authentication, redirect refusal, wire bounds, cancellation and
/// deadline.
public struct MiniMaxAICueProvider: AICueProvider, Sendable {
    private static let voiceProbeURL = fixedURL("https://api.minimax.io/v1/get_voice")
    private static let registeredProfile =
        try! AICueProviderRegistry().profile(for: .miniMaxGlobal)
    private static let acceptedJSONMediaTypes: Set<String> = ["application/json"]
    private static let maximumProbeResponseBytes = 512 * 1_024
    private static let maximumResponseEnvelopeBytes = 512 * 1_024
    private static let sampleRate = 32_000
    private static let bitrate = 128_000
    private static let channelCount = 1
    private static let audioFormat = "mp3"

    private let unaryTransport: any AICueUnaryTransport

    public var profile: AICueProviderProfile {
        Self.registeredProfile
    }

    public init() {
        unaryTransport = AICueURLSessionUnaryTransport()
    }

    package init(unaryTransport: any AICueUnaryTransport) {
        self.unaryTransport = unaryTransport
    }

    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        let body = try jsonBody(["voice_type": "all"])
        guard let expectedOrigin = try? AICueOrigin(url: Self.voiceProbeURL) else {
            throw AICueProviderError.requiredModelsUnavailable
        }
        let request = AICueTransportRequest(
            method: .post,
            url: Self.voiceProbeURL,
            expectedOrigin: expectedOrigin,
            expectedPath: Self.voiceProbeURL.path,
            headers: ["accept": "application/json", "content-type": "application/json"],
            body: body,
            acceptedMediaTypes: Self.acceptedJSONMediaTypes,
            maximumWireBytes: Self.maximumProbeResponseBytes,
            deadline: .startingNow())
        let response: AICueHTTPResponse
        do {
            response = try await unaryTransport.send(
                request,
                authentication: .bearerAPIKey,
                credential: credential)
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error,
                unexpectedMediaType: .requiredModelsUnavailable)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AICueProviderTransportErrorMapper.map(
                AICueTransportError.httpStatus(
                    code: response.statusCode,
                    retryAfterSeconds: nil),
                unexpectedMediaType: .requiredModelsUnavailable)
        }
        guard
            response.finalURL == request.url,
            normalizedMediaType(response) == "application/json",
            let root = jsonObject(response.body),
            let statusCode = providerStatusCode(root)
        else {
            throw AICueProviderError.requiredModelsUnavailable
        }
        guard statusCode == 0 else { throw AICueProviderError.invalidCredential }
        guard responseContainsFixedVoice(root) else {
            throw AICueProviderError.requiredModelsUnavailable
        }
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
        guard
            request.profileID == profile.id,
            request.modality == .speech,
            let route = profile.routes[.speech],
            route.authentication == .bearerAPIKey,
            route.transport == .hexEncodedContainer,
            let voiceID = route.voiceID,
            let spokenContent = request.spokenContent,
            !spokenContent.isEmpty,
            let languageTag = request.languageTag,
            route.supportedLanguageTags.contains(languageTag),
            (1...profile.constraints.maximumDurationMilliseconds).contains(
                request.targetDurationMilliseconds)
        else {
            throw AICueProviderError.invalidRequest
        }
        guard let expectedOrigin = try? AICueOrigin(url: route.endpoint) else {
            throw AICueProviderError.invalidRequest
        }

        let body = try jsonBody([
            "audio_setting": [
                "bitrate": Self.bitrate,
                "channel": Self.channelCount,
                "format": Self.audioFormat,
                "sample_rate": Self.sampleRate,
            ],
            "language_boost": "Chinese",
            "model": route.modelID,
            "output_format": "hex",
            "stream": false,
            "text": spokenContent,
            "voice_setting": [
                "pitch": 0,
                "speed": 1,
                "voice_id": voiceID,
                "vol": 1,
            ],
        ])
        let transportRequest = AICueTransportRequest(
            method: .post,
            url: route.endpoint,
            expectedOrigin: expectedOrigin,
            expectedPath: route.endpoint.path,
            headers: ["accept": "application/json", "content-type": "application/json"],
            body: body,
            acceptedMediaTypes: Self.acceptedJSONMediaTypes,
            maximumWireBytes: AICueTransportCeilings.miniMaxWireBytes,
            deadline: deadline)
        let response: AICueHTTPResponse
        do {
            response = try await unaryTransport.send(
                transportRequest,
                authentication: route.authentication,
                credential: credential)
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error,
                unexpectedMediaType: .invalidAudioResponse)
        }
        return try decodeGenerationResponse(
            response,
            expectedURL: transportRequest.url,
            modelID: route.modelID)
    }

    private func decodeGenerationResponse(
        _ response: AICueHTTPResponse,
        expectedURL: URL,
        modelID: String
    ) throws -> AICueProviderAudioResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw AICueProviderTransportErrorMapper.map(
                AICueTransportError.httpStatus(
                    code: response.statusCode,
                    retryAfterSeconds: nil),
                unexpectedMediaType: .invalidAudioResponse)
        }
        guard
            response.finalURL == expectedURL,
            normalizedMediaType(response) == "application/json"
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        guard response.body.count <= AICueTransportCeilings.miniMaxWireBytes else {
            throw AICueProviderError.responseTooLarge
        }
        guard
            let root = jsonObject(response.body),
            let statusCode = providerStatusCode(root)
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        guard statusCode == 0 else { throw AICueProviderError.serviceUnavailable }
        guard
            let payload = root["data"] as? [String: Any],
            let audioHex = payload["audio"] as? String,
            !audioHex.isEmpty
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        let encodedAudioBytes = audioHex.utf8.count
        guard
            encodedAudioBytes <= response.body.count,
            response.body.count - encodedAudioBytes <= Self.maximumResponseEnvelopeBytes
        else {
            throw AICueProviderError.responseTooLarge
        }
        try validateDeclaredAudioMetadata(root["extra_info"])

        let audio: Data
        do {
            audio = try AICueBoundedHexDecoder.decode(
                audioHex,
                maximumDecodedBytes: AICueTransportCeilings.miniMaxDecodedBytes)
        } catch AICueDecodedPayloadError.decodedPayloadTooLarge {
            throw AICueProviderError.responseTooLarge
        } catch {
            throw AICueProviderError.invalidAudioResponse
        }
        guard sniffAudioFormat(audio) == .mp3 else {
            throw AICueProviderError.invalidAudioResponse
        }
        return AICueProviderAudioResponse(
            data: audio,
            mediaType: "audio/mpeg",
            modelID: modelID,
            requestID: sanitizedAICueProviderRequestID(root["trace_id"] as? String))
    }

    private func validateDeclaredAudioMetadata(_ value: Any?) throws {
        guard let value else { return }
        guard let metadata = value as? [String: Any] else {
            throw AICueProviderError.invalidAudioResponse
        }
        let declarations: [(String, Int)] = [
            ("audio_sample_rate", Self.sampleRate),
            ("bitrate", Self.bitrate),
            ("audio_channel", Self.channelCount),
        ]
        for (key, expected) in declarations {
            if let actual = integer(metadata[key]), actual != expected {
                throw AICueProviderError.invalidAudioResponse
            }
            if metadata[key] != nil, integer(metadata[key]) == nil {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        if let declaredFormat = metadata["audio_format"] {
            guard (declaredFormat as? String)?.lowercased() == Self.audioFormat else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
    }

    private func responseContainsFixedVoice(_ root: [String: Any]) -> Bool {
        guard let expectedVoiceID = profile.routes[.speech]?.voiceID else { return false }
        let categories = ["system_voice", "voice_cloning", "voice_generation"]
        return categories.contains { category in
            guard let voices = root[category] as? [[String: Any]] else { return false }
            return voices.contains { $0["voice_id"] as? String == expectedVoiceID }
        }
    }

    private func providerStatusCode(_ root: [String: Any]) -> Int? {
        guard let baseResponse = root["base_resp"] as? [String: Any] else { return nil }
        return integer(baseResponse["status_code"])
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

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func normalizedMediaType(_ response: AICueHTTPResponse) -> String {
        AICueTransportRequestBuilder.normalizedMediaType(response.headers["content-type"])
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw AICueProviderError.invalidRequest
        }
    }

    private static func fixedURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid built-in MiniMax URL")
        }
        return url
    }
}
