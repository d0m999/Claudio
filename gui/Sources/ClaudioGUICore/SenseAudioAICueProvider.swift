import CoreFoundation
import Dispatch
import Foundation

/// Evidence-gated SenseAudio adapter. The fixed API routes are usable only through a registry that
/// also owns an exact, verified asset policy; the default production registry intentionally does
/// not expose this profile until the external origin/MIME contract is confirmed.
public struct SenseAudioAICueProvider: AICueCandidateSetProvider, Sendable {
    private static let voiceProbeURL = fixedURL("https://api.senseaudio.cn/v1/get_voice")
    private static let acceptedJSONMediaTypes: Set<String> = ["application/json"]
    private static let maximumJSONResponseBytes = 512 * 1_024
    private static let maximumResponseEnvelopeBytes = 512 * 1_024
    private static let sampleRate = 32_000
    private static let bitrate = 128_000
    private static let channelCount = 1
    private static let audioFormat = "mp3"

    private let registry: AICueProviderRegistry
    private let unaryTransport: any AICueUnaryTransport
    private let assetFetcher: any AICueAssetFetching

    public let profile: AICueProviderProfile

    package init(
        registry: AICueProviderRegistry,
        unaryTransport: any AICueUnaryTransport = AICueURLSessionUnaryTransport(),
        assetFetcher: any AICueAssetFetching = AICueURLSessionAssetFetcher()
    ) throws {
        guard
            let profile = try? registry.profile(for: .senseAudioChina),
            registry.assetPolicy(for: .senseAudioChina) != nil
        else { throw AICueProviderRegistryError.unknownProfile }
        self.registry = registry
        self.profile = profile
        self.unaryTransport = unaryTransport
        self.assetFetcher = assetFetcher
    }

    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        let body = try jsonBody(["voice_type": "all"])
        let request = try transportRequest(
            url: Self.voiceProbeURL,
            body: body,
            maximumWireBytes: Self.maximumJSONResponseBytes,
            deadline: .startingNow())
        let response: AICueHTTPResponse
        do {
            response = try await unaryTransport.send(
                request,
                authentication: .bearerAPIKey,
                credential: credential)
        } catch AICueTransportError.httpStatus(401, _) {
            // Only the fixed API origin's HTTP authentication response rejects a new key. Business
            // statuses and a missing fixed voice are capability failures, preserving the old key.
            throw AICueProviderError.invalidCredential
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error,
                unexpectedMediaType: .requiredModelsUnavailable)
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw AICueProviderError.invalidCredential }
            throw statusError(response.statusCode, unexpectedMediaType: .requiredModelsUnavailable)
        }
        guard
            response.finalURL == request.url,
            normalizedMediaType(response) == "application/json",
            let root = jsonObject(response.body),
            providerStatusCode(root) == 0,
            let systemVoices = root["system_voice"] as? [[String: Any]],
            systemVoices.contains(where: {
                $0["voice_id"] as? String == profile.routes[.speech]?.voiceID
            })
        else {
            throw AICueProviderError.requiredModelsUnavailable
        }
    }

    public func generateCandidateSet(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse] {
        try requireRemainingBudget(deadline)
        switch plan.modality {
        case .speech:
            return try await generateSpeech(
                plan: plan,
                credential: credential,
                deadline: deadline)
        case .animal, .soundEffect:
            return try await generateSoundEffects(
                plan: plan,
                credential: credential,
                deadline: deadline)
        case .mixed:
            throw AICueProviderError.invalidRequest
        }
    }

    private func generateSpeech(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse] {
        guard
            let route = profile.routes[.speech],
            route.authentication == .bearerAPIKey,
            route.transport == .hexEncodedContainer,
            route.candidateSetPolicy.semantics == .numbered,
            route.candidateSetPolicy.minimumAcceptedCount
                == route.candidateSetPolicy.requestedCount,
            let voiceID = route.voiceID,
            let spokenContent = plan.spokenContent,
            !spokenContent.isEmpty,
            let languageTag = plan.languageTag,
            AICueLanguageTagMatcher.matches(
                languageTag,
                allowlist: route.supportedLanguageTags),
            (1...profile.constraints.maximumDurationMilliseconds).contains(
                plan.targetDurationMilliseconds)
        else { throw AICueProviderError.invalidRequest }

        let body = try jsonBody([
            "audio_setting": [
                "bitrate": Self.bitrate,
                "channel": Self.channelCount,
                "format": Self.audioFormat,
                "sample_rate": Self.sampleRate,
            ],
            "model": route.modelID,
            "stream": false,
            "text": spokenContent,
            "voice_setting": [
                "pitch": 0,
                "speed": 1,
                "voice_id": voiceID,
                "vol": 1,
            ],
        ])
        var candidates: [AICueProviderCandidateResponse] = []
        candidates.reserveCapacity(route.candidateSetPolicy.requestedCount)
        for ordinalValue in 1...route.candidateSetPolicy.requestedCount {
            try Task.checkCancellation()
            try requireRemainingBudget(deadline)
            let request = try transportRequest(
                url: route.endpoint,
                body: body,
                maximumWireBytes: AICueTransportCeilings.miniMaxWireBytes,
                deadline: deadline)
            let response: AICueHTTPResponse
            do {
                // SenseAudio POSTs are deliberately never retried: a repeated generation may be
                // billable even when the first response was lost.
                response = try await unaryTransport.send(
                    request,
                    authentication: route.authentication,
                    credential: credential)
            } catch {
                throw AICueProviderTransportErrorMapper.map(
                    error,
                    unexpectedMediaType: .invalidAudioResponse)
            }
            let audio = try decodeTTSResponse(
                response,
                expectedURL: request.url,
                modelID: route.modelID)
            guard let ordinal = AICueCandidateOrdinal(rawValue: ordinalValue) else {
                throw AICueProviderError.invalidRequest
            }
            candidates.append(
                AICueProviderCandidateResponse(
                    identity: .numbered(ordinal),
                    audio: audio))
        }
        return candidates
    }

    private func generateSoundEffects(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse] {
        guard
            let route = profile.routes[plan.modality],
            route.authentication == .bearerAPIKey,
            route.transport == .remoteAssets,
            route.candidateSetPolicy.semantics == .numbered,
            let assetPolicy = registry.assetPolicy(for: profile.id),
            (1...profile.constraints.maximumDurationMilliseconds).contains(
                plan.targetDurationMilliseconds)
        else { throw AICueProviderError.invalidRequest }

        let normalizedPrompt = normalizePrompt(plan.soundDescription)
        guard !normalizedPrompt.isEmpty else { throw AICueProviderError.invalidRequest }
        let durationSeconds = min(
            3,
            max(1, Int(ceil(Double(plan.targetDurationMilliseconds) / 1_000))))
        let body = try jsonBody([
            "duration_seconds": durationSeconds,
            "model": route.modelID,
            "output_format": Self.audioFormat,
            "smart_duration": false,
            "text": normalizedPrompt,
            "variants_count": route.candidateSetPolicy.requestedCount,
        ])
        let request = try transportRequest(
            url: route.endpoint,
            body: body,
            maximumWireBytes: Self.maximumJSONResponseBytes,
            deadline: deadline)
        let response: AICueHTTPResponse
        do {
            // Native batch creation is one billable POST and has no automatic retry.
            response = try await unaryTransport.send(
                request,
                authentication: route.authentication,
                credential: credential)
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error,
                unexpectedMediaType: .invalidAudioResponse)
        }

        let batch = try parseSFXBatch(
            response,
            expectedURL: request.url,
            assetPolicy: assetPolicy,
            requestedCount: route.candidateSetPolicy.requestedCount)
        var candidates: [AICueProviderCandidateResponse] = []
        candidates.reserveCapacity(batch.items.count)
        for item in batch.items {
            try Task.checkCancellation()
            try requireRemainingBudget(deadline)
            do {
                let fetched = try await assetFetcher.fetch(
                    item.url,
                    policy: assetPolicy,
                    deadline: deadline)
                guard let ordinal = AICueCandidateOrdinal(rawValue: item.variantIndex + 1) else {
                    throw AICueProviderError.invalidAudioResponse
                }
                candidates.append(
                    AICueProviderCandidateResponse(
                        identity: .numbered(ordinal),
                        audio: AICueProviderAudioResponse(
                            data: fetched.data,
                            mediaType: fetched.mediaType,
                            modelID: route.modelID,
                            requestID: batch.requestID)))
            } catch AICueAssetFetchError.cancelled {
                throw AICueProviderError.cancelled
            } catch AICueAssetFetchError.deadlineExceeded {
                throw AICueProviderError.deadlineExceeded
            } catch is CancellationError {
                throw AICueProviderError.cancelled
            } catch {
                // An individual resource failure cannot authorize a different host and does not
                // invalidate siblings. The engine applies the route's minimum accepted count.
                continue
            }
        }
        return candidates
    }

    private func decodeTTSResponse(
        _ response: AICueHTTPResponse,
        expectedURL: URL,
        modelID: String
    ) throws -> AICueProviderAudioResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw statusError(response.statusCode, unexpectedMediaType: .invalidAudioResponse)
        }
        guard
            response.finalURL == expectedURL,
            normalizedMediaType(response) == "application/json",
            response.body.count <= AICueTransportCeilings.miniMaxWireBytes,
            let root = jsonObject(response.body),
            providerStatusCode(root) == 0,
            let payload = root["data"] as? [String: Any],
            integer(payload["status"]) == 2,
            let audioHex = payload["audio"] as? String,
            !audioHex.isEmpty,
            audioHex.utf8.count.isMultiple(of: 2)
        else { throw AICueProviderError.invalidAudioResponse }

        let encodedAudioBytes = audioHex.utf8.count
        guard
            encodedAudioBytes <= response.body.count,
            response.body.count - encodedAudioBytes <= Self.maximumResponseEnvelopeBytes
        else { throw AICueProviderError.responseTooLarge }

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
        try validateDeclaredTTSMetadata(root["extra_info"], decodedByteCount: audio.count)
        guard sniffAudioFormat(audio) == .mp3 else {
            throw AICueProviderError.invalidAudioResponse
        }
        return AICueProviderAudioResponse(
            data: audio,
            mediaType: "audio/mpeg",
            modelID: modelID,
            requestID: sanitizedAICueProviderRequestID(root["trace_id"] as? String))
    }

    private func validateDeclaredTTSMetadata(_ value: Any?, decodedByteCount: Int) throws {
        guard let value else { return }
        guard let metadata = value as? [String: Any] else {
            throw AICueProviderError.invalidAudioResponse
        }
        let declarations: [(String, Int)] = [
            ("audio_sample_rate", Self.sampleRate),
            ("bitrate", Self.bitrate),
            ("audio_channel", Self.channelCount),
            ("audio_size", decodedByteCount),
        ]
        for (key, expected) in declarations where metadata[key] != nil {
            guard integer(metadata[key]) == expected else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        if metadata["audio_format"] != nil {
            guard (metadata["audio_format"] as? String)?.lowercased() == Self.audioFormat else {
                throw AICueProviderError.invalidAudioResponse
            }
        }
        if metadata["audio_length"] != nil {
            guard
                let duration = integer(metadata["audio_length"]),
                (1...profile.constraints.maximumDurationMilliseconds).contains(duration)
            else { throw AICueProviderError.invalidAudioResponse }
        }
    }

    private struct SFXDownloadItem {
        let variantIndex: Int
        let url: URL
    }

    private struct SFXBatch {
        let requestID: String?
        let items: [SFXDownloadItem]
    }

    private func parseSFXBatch(
        _ response: AICueHTTPResponse,
        expectedURL: URL,
        assetPolicy: AICueAssetPolicy,
        requestedCount: Int
    ) throws -> SFXBatch {
        guard (200..<300).contains(response.statusCode) else {
            throw statusError(response.statusCode, unexpectedMediaType: .invalidAudioResponse)
        }
        guard
            response.finalURL == expectedURL,
            normalizedMediaType(response) == "application/json",
            response.body.count <= Self.maximumJSONResponseBytes,
            let root = jsonObject(response.body),
            let status = root["status"] as? String,
            status == "completed" || status == "partial_success",
            let rawItems = root["items"] as? [[String: Any]],
            !rawItems.isEmpty,
            rawItems.count <= requestedCount
        else { throw AICueProviderError.invalidAudioResponse }

        var seenIndexes: Set<Int> = []
        var seenURLs: Set<URL> = []
        var declaredCompletedCount = 0
        var downloadable: [SFXDownloadItem] = []
        for rawItem in rawItems {
            guard
                let variantIndex = integer(rawItem["variant_index"]),
                (0..<requestedCount).contains(variantIndex),
                seenIndexes.insert(variantIndex).inserted,
                let itemStatus = rawItem["status"] as? String,
                itemStatus == "completed" || itemStatus == "failed"
            else { throw AICueProviderError.invalidAudioResponse }

            let parsedURL: URL?
            if let rawURL = rawItem["audio_url"] {
                guard
                    let value = rawURL as? String,
                    !value.isEmpty,
                    let url = URL(string: value),
                    seenURLs.insert(url).inserted,
                    (try? AICueURLSessionAssetFetcher.request(
                        url: url,
                        policy: assetPolicy,
                        deadline: .startingNow())) != nil
                else {
                    // Any URL that is present but outside the registry-owned trust boundary rejects
                    // the whole batch before the first asset request is sent.
                    throw AICueProviderError.invalidAudioResponse
                }
                parsedURL = url
            } else {
                parsedURL = nil
            }

            guard itemStatus == "completed" else { continue }
            declaredCompletedCount += 1
            guard
                let url = parsedURL,
                (rawItem["output_format"] as? String)?.lowercased() == Self.audioFormat,
                let duration = integer(rawItem["duration_seconds"]),
                (1...3).contains(duration)
            else {
                // Provider-completed items with incomplete media declarations are individual
                // failures; the route policy decides whether the remaining local set is publishable.
                continue
            }
            downloadable.append(SFXDownloadItem(variantIndex: variantIndex, url: url))
        }

        switch status {
        case "completed":
            guard declaredCompletedCount == requestedCount else {
                throw AICueProviderError.invalidAudioResponse
            }
        case "partial_success":
            guard (1..<requestedCount).contains(declaredCompletedCount) else {
                throw AICueProviderError.invalidAudioResponse
            }
        default:
            throw AICueProviderError.invalidAudioResponse
        }
        return SFXBatch(
            requestID: sanitizedAICueProviderRequestID(root["generation_id"] as? String),
            items: downloadable.sorted { $0.variantIndex < $1.variantIndex })
    }

    private func transportRequest(
        url: URL,
        body: Data,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) throws -> AICueTransportRequest {
        guard let origin = try? AICueOrigin(url: url) else {
            throw AICueProviderError.invalidRequest
        }
        return AICueTransportRequest(
            method: .post,
            url: url,
            expectedOrigin: origin,
            expectedPath: url.path,
            headers: ["accept": "application/json", "content-type": "application/json"],
            body: body,
            acceptedMediaTypes: Self.acceptedJSONMediaTypes,
            maximumWireBytes: maximumWireBytes,
            deadline: deadline)
    }

    private func statusError(
        _ statusCode: Int,
        unexpectedMediaType: AICueProviderError
    ) -> AICueProviderError {
        AICueProviderTransportErrorMapper.map(
            AICueTransportError.httpStatus(code: statusCode, retryAfterSeconds: nil),
            unexpectedMediaType: unexpectedMediaType)
    }

    private func requireRemainingBudget(_ deadline: AICueGenerationDeadline) throws {
        guard
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
        else { throw AICueProviderError.deadlineExceeded }
    }

    private func normalizePrompt(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
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
            preconditionFailure("Invalid built-in SenseAudio URL")
        }
        return url
    }
}
