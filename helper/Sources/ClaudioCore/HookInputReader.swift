import Darwin
import Foundation

public enum HookInputReadStatus: String, Sendable, Equatable {
    case data
    case empty
    case ttySkipped = "tty_skipped"
    case timedOut = "timed_out"
    case tooLarge = "too_large"
    case readFailed = "read_failed"
}

public struct HookInputReadResult: Sendable, Equatable {
    public let status: HookInputReadStatus
    public let data: Data?
    public let bytesRead: Int

    public init(status: HookInputReadStatus, data: Data? = nil, bytesRead: Int = 0) {
        self.status = status
        self.data = data
        self.bytesRead = bytesRead
    }
}

/// One bounded, non-blocking stdin read for a host hook. It never waits for an unbounded EOF and
/// restores the descriptor flags before returning, so the host process retains its pipe semantics.
public enum HookInputReader {
    public static let defaultMaximumBytes = 64 * 1024
    public static let defaultBudget: TimeInterval = 0.020

    public static func read(
        from fileDescriptor: Int32 = FileHandle.standardInput.fileDescriptor,
        maximumBytes: Int = defaultMaximumBytes,
        budget: TimeInterval = defaultBudget
    ) -> HookInputReadResult {
        guard maximumBytes > 0, budget >= 0 else {
            return HookInputReadResult(status: .readFailed)
        }
        guard isatty(fileDescriptor) != 1 else {
            return HookInputReadResult(status: .ttySkipped)
        }

        let originalFlags = fcntl(fileDescriptor, F_GETFL)
        guard originalFlags >= 0 else {
            return HookInputReadResult(status: .readFailed)
        }
        defer { _ = fcntl(fileDescriptor, F_SETFL, originalFlags) }
        guard fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            return HookInputReadResult(status: .readFailed)
        }

        let deadline =
            DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, budget) * 1_000_000_000)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(fileDescriptor, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                bytes.append(buffer, count: count)
                if bytes.count > maximumBytes {
                    return HookInputReadResult(
                        status: .tooLarge,
                        bytesRead: bytes.count)
                }
                // A complete JSON document does not need an EOF from a host that keeps stdin open.
                if (try? JSONSerialization.jsonObject(
                    with: bytes,
                    options: [.fragmentsAllowed])) != nil
                {
                    return HookInputReadResult(status: .data, data: bytes, bytesRead: bytes.count)
                }
                continue
            }
            if count == 0 {
                return HookInputReadResult(
                    status: bytes.isEmpty ? .empty : .data,
                    data: bytes.isEmpty ? nil : bytes,
                    bytesRead: bytes.count)
            }

            let code = errno
            if code == EINTR { continue }
            guard code == EAGAIN || code == EWOULDBLOCK else {
                return HookInputReadResult(status: .readFailed, bytesRead: bytes.count)
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return HookInputReadResult(
                    status: bytes.isEmpty ? .timedOut : .data,
                    data: bytes.isEmpty ? nil : bytes,
                    bytesRead: bytes.count)
            }
            let remainingNanoseconds = deadline - now
            let timeoutMilliseconds = Int32(
                min(
                    UInt64(Int32.max),
                    max(1, (remainingNanoseconds + 999_999) / 1_000_000)))
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0)
            let polled = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if polled < 0, errno == EINTR { continue }
            if polled < 0 {
                return HookInputReadResult(status: .readFailed, bytesRead: bytes.count)
            }
            if polled == 0 {
                return HookInputReadResult(
                    status: bytes.isEmpty ? .timedOut : .data,
                    data: bytes.isEmpty ? nil : bytes,
                    bytesRead: bytes.count)
            }
        }
    }
}
