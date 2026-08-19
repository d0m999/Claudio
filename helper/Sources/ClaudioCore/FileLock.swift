import Darwin
import Foundation

/// The outcome of a single non-blocking ``FileLock/attemptLock()`` call.
public enum LockAttempt: Sendable, Equatable {
    /// The lock is now held (or was already held by this instance).
    case acquired
    /// Another holder currently has the lock — a non-blocking skip (the expected
    /// contended path for `play`'s debounce). Corresponds to `flock`'s `EWOULDBLOCK`.
    case busy
    /// A real system error prevented the attempt (`open`/`flock` failed for a reason
    /// other than contention). Carries the POSIX `errno` for logging/reporting.
    case failed(errno: Int32)
}

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

    /// Attempts to acquire the exclusive lock without blocking, distinguishing the three
    /// outcomes that matter to `play`'s skip-style debounce:
    ///
    /// - ``LockAttempt/acquired`` — the lock is now held (or was already held by this
    ///   instance); the caller may run its critical section.
    /// - ``LockAttempt/busy`` — another holder currently has it (`flock` reported
    ///   `EWOULDBLOCK`); the caller should skip. This is the *expected* contended path.
    /// - ``LockAttempt/failed`` — a real system error (`open`/`flock` failed for any
    ///   reason other than contention, e.g. `~/.claudio` was deleted or is unwritable).
    ///
    /// Collapsing `failed` into `busy` would make `play` silently treat a broken
    /// filesystem as a debounce skip, so a real failure never surfaces (T1 review P1).
    ///
    /// A missing *parent* directory (`errno == ENOENT`) is self-healed by creating it and
    /// retrying `open` once — see the first-run onboarding rationale inline below.
    @discardableResult
    public func attemptLock() -> LockAttempt {
        if descriptor == -1 {
            var opened = open(path, O_CREAT | O_RDWR, 0o600)
            if opened == -1 && errno == ENOENT {
                // Self-heal: `O_CREAT` only ever creates the leaf file, never a missing
                // *parent* directory — and nothing else in Claudio proactively creates
                // `~/.claudio/` up front. Without this, the first lock any command reaches for
                // on a brand-new machine (no `~/.claudio/` yet) would fail with a misleading
                // "retry later" error that could never actually succeed on retry — and since
                // the lock split there are three such first-touch candidates, not one:
                // `settings.lock` (`claudio install`), `config.lock` (`claudio use`,
                // `performFirstRunSetup`), and `play.lock` (`claudio play`). Whichever runs
                // first creates the directory for the other two. Only ENOENT triggers this:
                // any other errno
                // (e.g. `EACCES`) is a real failure that a directory creation wouldn't
                // fix, and must fall straight through to `.failed` below.
                let parentDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
                try? ensurePrivateDirectoryTree(at: parentDirectory)
                opened = open(path, O_CREAT | O_RDWR, 0o600)
            }
            // If the directory creation above failed too (e.g. permission denied, or a
            // path component collides with an existing file), this retried `open` fails
            // again and its real errno surfaces via `.failed` below — never silently
            // treated as success.
            guard opened != -1 else { return .failed(errno: errno) }
            descriptor = opened
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return .acquired
        }
        // Capture errno immediately: any intervening libc call would clobber it.
        let flockErrno = errno
        // `EWOULDBLOCK` (== `EAGAIN` on Darwin) is the one errno that means "held by
        // someone else" — the only true contention signal. Everything else is a real
        // error and must not be conflated with a debounce skip.
        return flockErrno == EWOULDBLOCK ? .busy : .failed(errno: flockErrno)
    }

    /// Convenience over ``attemptLock()``: `true` iff the lock was acquired. Callers that
    /// must tell contention (`busy`) apart from a real system error (`failed`) — as
    /// `play` does — should use ``attemptLock()`` instead.
    @discardableResult
    public func tryLock() -> Bool {
        attemptLock() == .acquired
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

/// The outcome of a ``withNonBlockingLock(path:_:)`` call.
public enum LockedRun<T> {
    /// The lock was acquired and `body` ran, producing this value.
    case ran(T)
    /// Another holder currently held the lock — `body` did **not** run (skip-style
    /// debounce). Non-blocking: this returns immediately (ENGINEERING.md 决议 5).
    case skipped
    /// A real system error (not contention) prevented acquiring the lock — `body` did
    /// **not** run. Carries the POSIX `errno` so the caller can log/report the broken
    /// filesystem instead of silently treating it as a debounce skip (T1 review P1).
    case failed(errno: Int32)
}

/// Runs `body` while holding a non-blocking exclusive lock on `path`.
///
/// Returns ``LockedRun/ran(_:)`` with the body's value when the lock was acquired,
/// ``LockedRun/skipped`` when another holder currently has it (the "跳过式去抖" primitive
/// `play` builds its debounce on), or ``LockedRun/failed(errno:)`` when a real system
/// error stopped the attempt. Never blocks; never runs `body` unless the lock was
/// actually acquired.
@discardableResult
public func withNonBlockingLock<T>(path: String, _ body: () throws -> T) rethrows -> LockedRun<T> {
    let lock = FileLock(path: path)
    switch lock.attemptLock() {
    case .acquired:
        defer { lock.unlock() }
        return .ran(try body())
    case .busy:
        return .skipped
    case .failed(let code):
        return .failed(errno: code)
    }
}
