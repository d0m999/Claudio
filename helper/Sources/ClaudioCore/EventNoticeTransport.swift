import Darwin
import Dispatch
import Foundation

public enum EventNoticeTransportFailure: String, Codable, Sendable, Equatable {
    case descriptorMissing = "descriptor_missing"
    case descriptorUnreadable = "descriptor_unreadable"
    case descriptorUnsafe = "descriptor_unsafe"
    case endpointMissing = "endpoint_missing"
    case endpointUnsafe = "endpoint_unsafe"
    case invalidNotice = "invalid_notice"
    case messageTooLarge = "message_too_large"
    case wouldBlock = "would_block"
    case permissionDenied = "permission_denied"
    case endpointClosed = "endpoint_closed"
    case ownerBusy = "owner_busy"
    case socketFailed = "socket_failed"
    case writeFailed = "write_failed"
}

public enum EventNoticeSendOutcome: Sendable, Equatable {
    case sent
    case dropped(EventNoticeTransportFailure)
}

/// The descriptor is intentionally tiny and contains no source values. Its socket path points to
/// a private, short-lived directory owned by the GUI receiver.
public struct EventNoticeEndpointDescriptor: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public let schema: Int
    public let epoch: UUID
    public let socketPath: String
    public let socketInode: UInt64

    public init(
        schema: Int = EventNoticeEndpointDescriptor.currentSchema,
        epoch: UUID,
        socketPath: String,
        socketInode: UInt64
    ) {
        self.schema = schema
        self.epoch = epoch
        self.socketPath = socketPath
        self.socketInode = socketInode
    }
}

public enum EventNoticeTransport {
    public static let maximumMessageBytes = 8 * 1024

    public static func loadDescriptor(
        from descriptorFile: URL = ClaudioPaths.eventNoticeDescriptorFile
    ) -> EventNoticeEndpointDescriptor? {
        guard isPrivateRegularFile(descriptorFile),
            case .success(let data) = readRegularFileBounded(
                at: descriptorFile,
                maxBytes: 4 * 1024,
                followSymlink: false),
            let descriptor = try? JSONDecoder().decode(
                EventNoticeEndpointDescriptor.self,
                from: data),
            isValidDescriptor(descriptor)
        else { return nil }
        return descriptor
    }

    public static func send(
        _ notice: HostEventNotice,
        to descriptor: EventNoticeEndpointDescriptor
    ) -> EventNoticeSendOutcome {
        guard notice.isSemanticallyValid, notice.receiverEpoch == descriptor.epoch else {
            return .dropped(.invalidNotice)
        }
        guard isValidDescriptor(descriptor) else {
            return .dropped(.endpointUnsafe)
        }
        guard let data = try? JSONEncoder().encode(notice), data.count <= maximumMessageBytes else {
            return .dropped(.messageTooLarge)
        }

        let socketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return .dropped(.socketFailed) }
        defer { _ = Darwin.close(socketFD) }
        let flags = fcntl(socketFD, F_GETFL)
        guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return .dropped(.socketFailed)
        }

        var address = sockaddr_un()
        guard fillSocketAddress(&address, path: descriptor.socketPath) else {
            return .dropped(.endpointUnsafe)
        }
        let addressLength = socketAddressLength(address)
        let result = data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(
                        socketFD,
                        baseAddress,
                        rawBuffer.count,
                        MSG_DONTWAIT,
                        sockaddrPointer,
                        addressLength)
                }
            }
        }
        guard result == data.count else {
            switch errno {
            case EAGAIN, EWOULDBLOCK, ENOBUFS: return .dropped(.wouldBlock)
            case EACCES, EPERM: return .dropped(.permissionDenied)
            case ENOENT, ECONNREFUSED: return .dropped(.endpointClosed)
            default: return .dropped(.writeFailed)
            }
        }
        return .sent
    }

    fileprivate static func isValidDescriptor(_ descriptor: EventNoticeEndpointDescriptor) -> Bool {
        let temporaryRoot = FileManager.default.temporaryDirectory.path
        guard descriptor.schema == EventNoticeEndpointDescriptor.currentSchema,
            !descriptor.socketPath.isEmpty,
            descriptor.socketPath.utf8.count < MemoryLayout<sockaddr_un>.size,
            descriptor.socketPath.hasPrefix(temporaryRoot + "/")
        else { return false }
        let socketURL = URL(fileURLWithPath: descriptor.socketPath)
        let directoryURL = socketURL.deletingLastPathComponent()
        var directoryStatus = stat()
        guard lstat(directoryURL.path, &directoryStatus) == 0,
            directoryStatus.st_mode & S_IFMT == S_IFDIR,
            directoryStatus.st_uid == getuid(),
            directoryStatus.st_mode & 0o777 == 0o700
        else { return false }
        var status = stat()
        guard lstat(descriptor.socketPath, &status) == 0,
            status.st_mode & S_IFMT == S_IFSOCK,
            status.st_uid == getuid(),
            UInt64(status.st_ino) == descriptor.socketInode
        else { return false }
        return (status.st_mode & 0o777) == 0o600
    }

    fileprivate static func fillSocketAddress(
        _ address: inout sockaddr_un,
        path: String
    ) -> Bool {
        let bytes = Array(path.utf8)
        let maximumPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size
        guard !bytes.isEmpty, bytes.count < maximumPathBytes else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return true
    }

    fileprivate static func socketAddressLength(_: sockaddr_un) -> socklen_t {
        socklen_t(MemoryLayout<sockaddr_un>.size)
    }

    private static func isPrivateRegularFile(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == getuid()
        else { return false }
        return (status.st_mode & 0o777) == 0o600
    }
}

/// GUI-owned receiver. The I/O queue only validates and decodes; the callback decides how to
/// re-enter MainActor. Each I/O turn drains at most 32 datagrams so stop cannot starve.
public final class EventNoticeReceiver: @unchecked Sendable {
    public let descriptor: EventNoticeEndpointDescriptor

    private let descriptorFile: URL
    private let callback: @Sendable (HostEventNotice) -> Void
    private let currentInstallationID: (@Sendable (HostID) -> UUID?)?
    private let ioQueue: DispatchQueue
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var ownerLock: FileLock?
    private var socketDirectory: URL?
    private let lock = NSLock()
    private var stopped = false

    public init(
        descriptorFile: URL = ClaudioPaths.eventNoticeDescriptorFile,
        ownerLockFile: URL = ClaudioPaths.eventNoticeOwnerLockFile,
        epoch: UUID = UUID(),
        currentInstallationID: (@Sendable (HostID) -> UUID?)? = nil,
        callback: @escaping @Sendable (HostEventNotice) -> Void
    ) throws {
        self.descriptorFile = descriptorFile
        self.callback = callback
        self.currentInstallationID = currentInstallationID
        ioQueue = DispatchQueue(label: "com.orbitzero.claudio.event-notices", qos: .userInitiated)

        try ensurePrivateDirectoryTree(at: ownerLockFile.deletingLastPathComponent())
        let owner = FileLock(path: ownerLockFile.path)
        switch owner.attemptLock() {
        case .acquired:
            ownerLock = owner
        case .busy:
            throw EventNoticeReceiverError.ownerBusy
        case .failed(let code):
            throw EventNoticeReceiverError.ownerLockFailed(errno: code)
        }

        do {
            if let oldDescriptor = EventNoticeTransport.loadDescriptor(from: descriptorFile) {
                Self.cleanupEndpoint(oldDescriptor)
                _ = unlink(descriptorFile.path)
            }
            let directory = try Self.makePrivateSocketDirectory()
            let socketPath = directory.appendingPathComponent("notice.sock").path
            var setupFD: Int32 = -1
            var installed = false
            defer {
                if setupFD >= 0 { _ = close(setupFD) }
                if !installed {
                    _ = unlink(socketPath)
                    _ = rmdir(directory.path)
                }
            }
            setupFD = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard setupFD >= 0 else { throw EventNoticeReceiverError.socketFailed(errno: errno) }
            var address = sockaddr_un()
            guard EventNoticeTransport.fillSocketAddress(&address, path: socketPath) else {
                throw EventNoticeReceiverError.socketPathTooLong
            }
            let addressLength = EventNoticeTransport.socketAddressLength(address)
            let flags = fcntl(setupFD, F_GETFL)
            guard flags >= 0, fcntl(setupFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
                let code = errno
                throw EventNoticeReceiverError.socketFailed(errno: code)
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(
                        setupFD,
                        sockaddrPointer,
                        addressLength)
                }
            }
            guard bound == 0 else {
                let code = errno
                throw EventNoticeReceiverError.socketFailed(errno: code)
            }
            guard chmod(socketPath, 0o600) == 0 else {
                let code = errno
                throw EventNoticeReceiverError.socketFailed(errno: code)
            }
            var status = stat()
            guard lstat(socketPath, &status) == 0 else {
                let code = errno
                throw EventNoticeReceiverError.socketFailed(errno: code)
            }
            let descriptor = EventNoticeEndpointDescriptor(
                epoch: epoch,
                socketPath: socketPath,
                socketInode: UInt64(status.st_ino))
            let data = try JSONEncoder().encode(descriptor)
            guard data.count <= 4 * 1024 else {
                throw EventNoticeReceiverError.descriptorTooLarge
            }
            try Self.writeDescriptor(data, to: descriptorFile)
            socketFD = setupFD
            socketDirectory = directory
            self.descriptor = descriptor
            setupFD = -1
            installed = true
        } catch {
            ownerLock?.unlock()
            ownerLock = nil
            throw error
        }
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        guard !stopped, readSource == nil, socketFD >= 0 else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler {}
        readSource = source
        source.resume()
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let source = readSource
        readSource = nil
        let fd = socketFD
        let owner = ownerLock
        ownerLock = nil
        let directory = socketDirectory
        socketDirectory = nil
        lock.unlock()

        source?.cancel()
        if fd >= 0 {
            // DispatchSource cancellation is asynchronous. Wait for an already-running drain
            // before closing the descriptor, otherwise a stop racing a readable datagram can
            // turn the receiver's fd into a reused descriptor in another subsystem.
            ioQueue.sync {}
            lock.lock()
            if socketFD == fd { socketFD = -1 }
            lock.unlock()
            _ = close(fd)
        }
        owner?.unlock()
        if let directory {
            let current = EventNoticeTransport.loadDescriptor(from: descriptorFile)
            if current?.epoch == descriptor.epoch,
                current?.socketPath == descriptor.socketPath,
                current?.socketInode == descriptor.socketInode
            {
                _ = unlink(descriptorFile.path)
            }
            cleanupSocketDirectory(directory)
        }
    }

    private func drain() {
        lock.lock()
        guard !stopped, socketFD >= 0 else {
            lock.unlock()
            return
        }
        let fd = socketFD
        lock.unlock()
        var buffer = [UInt8](repeating: 0, count: EventNoticeTransport.maximumMessageBytes + 1)
        for _ in 0..<32 {
            lock.lock()
            let shouldStop = stopped
            lock.unlock()
            guard !shouldStop else { return }
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return recv(fd, baseAddress, rawBuffer.count, MSG_DONTWAIT)
            }
            if count <= 0 {
                if count < 0, errno == EINTR { continue }
                return
            }
            guard
                let notice = try? JSONDecoder().decode(
                    HostEventNotice.self,
                    from: Data(buffer.prefix(count)))
            else { continue }
            guard notice.isSemanticallyValid, notice.receiverEpoch == descriptor.epoch,
                let host = notice.host
            else { continue }
            let installationIsCurrent: Bool
            if let currentInstallationID {
                installationIsCurrent = currentInstallationID(host) == notice.installationID
            } else {
                installationIsCurrent = true
            }
            guard count <= EventNoticeTransport.maximumMessageBytes,
                installationIsCurrent
            else { continue }
            callback(notice)
        }
    }

    private static func cleanupEndpoint(_ oldDescriptor: EventNoticeEndpointDescriptor) {
        guard EventNoticeTransport.isValidDescriptor(oldDescriptor) else { return }
        let socket = URL(fileURLWithPath: oldDescriptor.socketPath)
        _ = unlink(socket.path)
        _ = rmdir(socket.deletingLastPathComponent().path)
    }

    private func cleanupSocketDirectory(_ directory: URL) {
        let socket = directory.appendingPathComponent("notice.sock")
        var status = stat()
        guard lstat(socket.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFSOCK,
            status.st_uid == getuid(),
            UInt64(status.st_ino) == descriptor.socketInode
        else { return }
        _ = unlink(socket.path)
        _ = rmdir(directory.path)
    }

    private static func makePrivateSocketDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        var template = base.appendingPathComponent("claudio-event-notices-XXXXXX").path.utf8CString
        let result = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress)
        }
        guard result != nil else { throw EventNoticeReceiverError.directoryFailed(errno: errno) }
        let path = String(cString: result!)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try ensurePrivateDirectoryTree(at: url)
        return url
    }

    private static func writeDescriptor(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try ensurePrivateDirectoryTree(at: directory)
        do {
            try data.write(to: destination, options: [.atomic])
            guard chmod(destination.path, 0o600) == 0 else {
                throw EventNoticeReceiverError.descriptorWriteFailed(errno: errno)
            }
        } catch let error as EventNoticeReceiverError {
            throw error
        } catch {
            throw EventNoticeReceiverError.descriptorWriteFailed(
                errno: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }
}

public enum EventNoticeReceiverError: Error, Sendable, Equatable, CustomStringConvertible {
    case ownerBusy
    case ownerLockFailed(errno: Int32)
    case directoryFailed(errno: Int32)
    case socketFailed(errno: Int32)
    case socketPathTooLong
    case descriptorTooLarge
    case descriptorWriteFailed(errno: Int32)

    public var description: String {
        switch self {
        case .ownerBusy: "event notice receiver owner is already active"
        case .ownerLockFailed(let errno): "event notice owner lock failed (errno \(errno))"
        case .directoryFailed(let errno): "event notice socket directory failed (errno \(errno))"
        case .socketFailed(let errno): "event notice socket failed (errno \(errno))"
        case .socketPathTooLong: "event notice socket path is too long"
        case .descriptorTooLarge: "event notice descriptor is too large"
        case .descriptorWriteFailed(let errno):
            "event notice descriptor write failed (errno \(errno))"
        }
    }

    /// Fixed redacted code for health surfaces; never carries errno, paths, or payload.
    public var diagnosticCode: String {
        switch self {
        case .ownerBusy: "owner_busy"
        case .ownerLockFailed: "owner_lock_failed"
        case .directoryFailed: "directory_failed"
        case .socketFailed: "socket_failed"
        case .socketPathTooLong: "socket_path_too_long"
        case .descriptorTooLarge: "descriptor_too_large"
        case .descriptorWriteFailed: "descriptor_write_failed"
        }
    }
}
