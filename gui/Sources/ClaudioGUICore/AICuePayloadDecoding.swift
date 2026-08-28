import Foundation

package enum AICueDecodedPayloadError: Error, Sendable, Equatable {
    case invalidEncoding
    case decodedPayloadTooLarge
}

package enum AICueBoundedHexDecoder {
    package static func decode(
        _ value: String,
        maximumDecodedBytes: Int
    ) throws -> Data {
        let bytes = Array(value.utf8)
        guard
            maximumDecodedBytes > 0,
            !bytes.isEmpty,
            bytes.count.isMultiple(of: 2)
        else {
            throw AICueDecodedPayloadError.invalidEncoding
        }
        guard bytes.count / 2 <= maximumDecodedBytes else {
            throw AICueDecodedPayloadError.decodedPayloadTooLarge
        }
        var decoded = Data()
        decoded.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                throw AICueDecodedPayloadError.invalidEncoding
            }
            decoded.append((high << 4) | low)
            index += 2
        }
        return decoded
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

/// Incremental strict Base64 decoder. Only decoded bytes are retained; encoded callback fragments
/// are reduced one quartet at a time so the SSE wire ceiling remains independent.
package struct AICueBoundedBase64Decoder: Sendable {
    private let maximumDecodedBytes: Int
    private var quartet: [UInt8] = []
    private var decoded = Data()
    private var sawPadding = false
    private var isFinished = false

    package init(maximumDecodedBytes: Int) {
        self.maximumDecodedBytes = maximumDecodedBytes
        quartet.reserveCapacity(4)
        decoded.reserveCapacity(min(maximumDecodedBytes, 144_000))
    }

    package mutating func append(_ fragment: String) throws {
        guard !isFinished, maximumDecodedBytes > 0 else {
            throw AICueDecodedPayloadError.invalidEncoding
        }
        for byte in fragment.utf8 {
            guard !sawPadding, isBase64Byte(byte) else {
                throw AICueDecodedPayloadError.invalidEncoding
            }
            quartet.append(byte)
            if quartet.count == 4 {
                try decodeQuartet()
            }
        }
    }

    package mutating func finish() throws -> Data {
        guard !isFinished, quartet.isEmpty, !decoded.isEmpty else {
            throw AICueDecodedPayloadError.invalidEncoding
        }
        isFinished = true
        return decoded
    }

    private mutating func decodeQuartet() throws {
        guard quartet.count == 4 else { throw AICueDecodedPayloadError.invalidEncoding }
        let paddingCount = quartet.reversed().prefix { $0 == 0x3D }.count
        guard paddingCount <= 2 else { throw AICueDecodedPayloadError.invalidEncoding }
        if quartet.dropLast(paddingCount).contains(0x3D) {
            throw AICueDecodedPayloadError.invalidEncoding
        }
        guard let chunk = Data(base64Encoded: Data(quartet)) else {
            throw AICueDecodedPayloadError.invalidEncoding
        }
        guard chunk.count <= maximumDecodedBytes - decoded.count else {
            throw AICueDecodedPayloadError.decodedPayloadTooLarge
        }
        decoded.append(chunk)
        quartet.removeAll(keepingCapacity: true)
        if paddingCount > 0 { sawPadding = true }
    }

    private func isBase64Byte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F, 0x3D:
            return true
        default:
            return false
        }
    }
}
