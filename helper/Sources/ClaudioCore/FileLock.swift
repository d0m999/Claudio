import Darwin
import Foundation

/// A non-blocking, exclusive `flock(2)` lock over a single path.
///
/// `claudio play` runs on a synchronous hook call path, so it must **never block**
/// waiting for a lock: if the lock is already held, that means another `claudio play`
/// invocation is currently handling the debounce/log critical section, and this one
/// should just skip (ENGINEERING.md 决议 1 + 5 + 指令: "锁必须非阻塞 `LOCK_NB`").
///
/// `flock(2)` locks are associated with an *open file description*, not a path or a
/// file descriptor number — so two independent `open()` calls on the same path (even
/// from the same process) compete for the lock exactly like two separate processes
/// would. That is what makes this class both correct for cross-process use and
/// testable in-process (see `FileLockSuite.swift`).
///
/// This type is intentionally **not** `Sendable`: an instance is owned by a single call
/// site for its whole lifetime (see ``withNonBlockingLock(path:_:)``). T5's concurrent
/// play path must not share one instance across threads/Tasks without first adding real
/// synchronization around `descriptor` (ENGINEERING.md 决议 5; T1 review HIGH).
public final class FileLock {
    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    /// Attempts to acquire the exclusive lock without blocking. Returns `true` if the
    /// lock was acquired (or already held by this instance), `false` if another holder
    /// currently has it — in which case this call returns immediately (no blocking).
    @discardableResult
    public func tryLock() -> Bool {
        if descriptor == -1 {
            let opened = open(path, O_CREAT | O_RDWR, 0o600)
            guard opened != -1 else { return false }
            descriptor = opened
        }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    /// Releases the lock (if held) and closes the underlying file descriptor. Safe to
    /// call multiple times, and safe to call even if the lock was never acquired.
    public func unlock() {
        guard descriptor != -1 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        // RAII release: a `FileLock` that goes out of scope without an explicit
        // `unlock()` must not leak the fd or leave the lock held forever.
        unlock()
    }
}

/// Runs `body` while holding a non-blocking exclusive lock on `path`.
///
/// If the lock cannot be acquired immediately, returns `nil` **without** running
/// `body` and **without blocking** — this is the "跳过式去抖" primitive `play` builds
/// its debounce on (ENGINEERING.md 决议 5).
@discardableResult
public func withNonBlockingLock<T>(path: String, _ body: () throws -> T) rethrows -> T? {
    let lock = FileLock(path: path)
    guard lock.tryLock() else { return nil }
    defer { lock.unlock() }
    return try body()
}
