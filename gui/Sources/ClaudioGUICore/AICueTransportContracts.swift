import Dispatch
import Foundation

public struct AICueGenerationDeadline: Sendable, Hashable, CustomReflectable {
    public static let durationNanoseconds: UInt64 = 60 * 1_000_000_000

    package let startedAtUptimeNanoseconds: UInt64
    package let expiresAtUptimeNanoseconds: UInt64

    package init(startedAtUptimeNanoseconds: UInt64, durationNanoseconds: UInt64) {
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        let expiration = startedAtUptimeNanoseconds.addingReportingOverflow(durationNanoseconds)
        expiresAtUptimeNanoseconds = expiration.overflow ? .max : expiration.partialValue
    }

    public static func startingNow() -> AICueGenerationDeadline {
        AICueGenerationDeadline(
            startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            durationNanoseconds: durationNanoseconds)
    }

    package func remainingNanoseconds(at now: UInt64) -> UInt64? {
        guard now < expiresAtUptimeNanoseconds else { return nil }
        return expiresAtUptimeNanoseconds - now
    }

    public var customMirror: Mirror {
        let durationNanoseconds =
            expiresAtUptimeNanoseconds >= startedAtUptimeNanoseconds
            ? expiresAtUptimeNanoseconds - startedAtUptimeNanoseconds : 0
        return Mirror(
            self,
            children: ["durationNanoseconds": durationNanoseconds],
            displayStyle: .struct)
    }
}

package enum AICueOriginError: Error, Sendable, Equatable {
    case invalidScheme
    case invalidHost
    case invalidPort
}

/// A normalized HTTPS trust boundary. Paths intentionally remain separate because one origin can
/// expose several independently allowlisted provider operations.
package struct AICueOrigin: Hashable, Sendable {
    package let scheme: String
    package let host: String
    package let effectivePort: Int

    package init(scheme: String, host: String, port: Int?) throws {
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "https" else { throw AICueOriginError.invalidScheme }
        let normalizedHost = host.lowercased()
        guard
            !normalizedHost.isEmpty,
            normalizedHost.canBeConverted(to: .ascii),
            normalizedHost.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
            })
        else {
            throw AICueOriginError.invalidHost
        }
        let effectivePort = port ?? 443
        guard (1...65_535).contains(effectivePort) else {
            throw AICueOriginError.invalidPort
        }
        self.scheme = normalizedScheme
        self.host = normalizedHost
        self.effectivePort = effectivePort
    }

    package func matches(_ url: URL) -> Bool {
        guard
            url.scheme?.lowercased() == scheme,
            url.host?.lowercased() == host,
            (url.port ?? 443) == effectivePort
        else { return false }
        return true
    }
}

package struct AICueTransportRequest: Sendable, CustomReflectable {
    package let method: AICueHTTPMethod
    package let url: URL
    package let expectedOrigin: AICueOrigin
    package let expectedPath: String
    package let headers: [String: String]
    package let body: Data?
    package let acceptedMediaTypes: Set<String>
    package let maximumWireBytes: Int
    package let deadline: AICueGenerationDeadline

    package init(
        method: AICueHTTPMethod,
        url: URL,
        expectedOrigin: AICueOrigin,
        expectedPath: String,
        headers: [String: String],
        body: Data?,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) {
        self.method = method
        self.url = url
        self.expectedOrigin = expectedOrigin
        self.expectedPath = expectedPath
        self.headers = headers
        self.body = body
        self.acceptedMediaTypes = Set(acceptedMediaTypes.map { $0.lowercased() })
        self.maximumWireBytes = maximumWireBytes
        self.deadline = deadline
    }

    package var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "method": method.rawValue,
                "url": url.absoluteString,
                "expectedPath": expectedPath,
                "maximumWireBytes": maximumWireBytes,
            ],
            displayStyle: .struct)
    }
}

package enum AICueTransportError: Error, Sendable, Equatable {
    case invalidRequest
    case originMismatch
    case pathMismatch
    case authenticationHeaderRejected
    case redirectRejected
    case httpStatus(code: Int, retryAfterSeconds: Int?)
    case unexpectedMediaType
    case responseTooLarge
    case invalidResponse
    case backpressureExceeded
    case inactivityTimeout
    case deadlineExceeded
    case cancelled
    case transportFailure
}

package enum AICueTransportCeilings {
    package static let elevenLabsWireBytes = 5 * 1_024 * 1_024
    package static let elevenLabsDecodedBytes = 5 * 1_024 * 1_024
    package static let miniMaxWireBytes = (10 * 1_024 * 1_024) + (512 * 1_024)
    package static let miniMaxDecodedBytes = 5 * 1_024 * 1_024
    package static let qwenSSEWireBytes = 256 * 1_024
    package static let qwenDecodedPCMBytes = 144_000
    package static let largestAllowedWireBytes = miniMaxWireBytes
}

package protocol AICueUnaryTransport: Sendable {
    func send(
        _ request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse
}

package enum AICueTransportRequestBuilder {
    package static func authenticatedURLRequest(
        from request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) throws -> URLRequest {
        guard request.method == .get || request.method == .post else {
            throw AICueTransportError.invalidRequest
        }
        guard request.expectedOrigin.matches(request.url) else {
            throw AICueTransportError.originMismatch
        }
        guard
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            throw AICueTransportError.invalidRequest
        }
        guard
            request.expectedPath.hasPrefix("/"),
            !request.expectedPath.contains("?"),
            !request.expectedPath.contains("#"),
            components.percentEncodedPath == request.expectedPath
        else {
            throw AICueTransportError.pathMismatch
        }
        guard
            !request.acceptedMediaTypes.isEmpty,
            request.acceptedMediaTypes.allSatisfy(isValidMediaType),
            (1...AICueTransportCeilings.largestAllowedWireBytes).contains(
                request.maximumWireBytes),
            request.deadline.remainingNanoseconds(
                at: DispatchTime.now().uptimeNanoseconds) != nil,
            request.method != .get || request.body == nil
        else {
            if request.deadline.remainingNanoseconds(
                at: DispatchTime.now().uptimeNanoseconds) == nil
            {
                throw AICueTransportError.deadlineExceeded
            }
            throw AICueTransportError.invalidRequest
        }

        for (name, value) in request.headers {
            let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard normalized != "authorization", normalized != "xi-api-key" else {
                throw AICueTransportError.authenticationHeaderRejected
            }
            guard
                isValidHeaderName(name),
                value.utf8.allSatisfy({ $0 == 0x09 || (0x20...0x7E).contains($0) })
            else {
                throw AICueTransportError.invalidRequest
            }
        }

        var result = URLRequest(url: request.url)
        result.httpMethod = request.method.rawValue
        result.httpBody = request.body
        result.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            result.setValue(value, forHTTPHeaderField: name)
        }
        credential.withUTF8String { value in
            switch authentication {
            case .elevenLabsAPIKeyHeader:
                result.setValue(value, forHTTPHeaderField: "xi-api-key")
            case .bearerAPIKey:
                result.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            }
        }
        return result
    }

    package static func normalizedMediaType(_ value: String?) -> String {
        value?.split(separator: ";", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? ""
    }

    private static func isValidMediaType(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts.allSatisfy { !$0.isEmpty }
            && !value.contains(";")
            && !value.contains(" ")
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                    0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                    0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                    return true
                default:
                    return false
                }
            }
    }
}

package enum AICueTransportResponseValidator {
    package static func validate(
        _ response: URLResponse,
        for request: AICueTransportRequest
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw AICueTransportError.invalidResponse
        }
        guard http.url == request.url else {
            throw AICueTransportError.redirectRejected
        }
        guard !(300..<400).contains(http.statusCode) else {
            throw AICueTransportError.redirectRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            let rawRetryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { value in
                Int(value)
            }
            let retryAfter = rawRetryAfter.flatMap { (1...300).contains($0) ? $0 : nil }
            throw AICueTransportError.httpStatus(
                code: http.statusCode,
                retryAfterSeconds: retryAfter)
        }
        let mediaType = AICueTransportRequestBuilder.normalizedMediaType(
            http.value(forHTTPHeaderField: "content-type"))
        guard request.acceptedMediaTypes.contains(mediaType) else {
            throw AICueTransportError.unexpectedMediaType
        }
        guard http.expectedContentLength <= Int64(request.maximumWireBytes) else {
            throw AICueTransportError.responseTooLarge
        }
        return http
    }
}

package enum AICueTransportSessionConfiguration {
    package static func hardened(
        from configuration: URLSessionConfiguration?,
        timeouts: AICueTransportTimeouts
    ) -> URLSessionConfiguration {
        let hardened = URLSessionConfiguration.ephemeral
        // The injected configuration is a test seam, not a second policy surface. Retaining its
        // headers, cookies, cache, credential store, or timeouts could bypass exact-origin auth.
        hardened.protocolClasses = configuration?.protocolClasses
        hardened.httpAdditionalHeaders = nil
        hardened.urlCache = nil
        hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
        hardened.httpCookieStorage = nil
        hardened.httpShouldSetCookies = false
        hardened.urlCredentialStorage = nil
        // Explicit runner timers distinguish connection from post-response inactivity. Keep the
        // Foundation fallback no shorter than either budget so it cannot collapse them together.
        hardened.timeoutIntervalForRequest = max(
            timeouts.connectionSeconds,
            timeouts.inactivitySeconds)
        hardened.timeoutIntervalForResource = 60
        hardened.httpMaximumConnectionsPerHost = 1
        hardened.waitsForConnectivity = false
        return hardened
    }
}
