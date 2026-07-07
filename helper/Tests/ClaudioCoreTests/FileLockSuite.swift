import ClaudioCore
import Foundation

// MARK: - FileLock: non-blocking flock(2) wrapper (ENGINEERING.md 决议 1 + 5, T1)
//
// `play`'s skip-style debounce needs a **non-blocking** exclusive lock: a hook is a
// synchronous call path, so `play` must never block waiting for the lock — if it can't
// acquire immediately, that means "someone else is currently handling a play" and it
// should skip. These tests exercise `tryLock`/`unlock` directly with two independent
// `open()`s of the same path within a single test process, which is exactly the
// situation `flock(2)` locks conflict on (locks are per open-file-description, not per
// path) — this is a faithful in-process simulation of two competing `claudio play`
// processes without needing to fork real subprocesses.

/// A trivial error used to drive `withNonBlockingLock`'s throwing-body path in tests.
private struct ThrowingBodyError: Error {}

@MainActor
func runFileLockSuites() {
    suite("tryLock acquires an uncontended lock") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let lock = FileLock(path: lockPath)
            expect(lock.tryLock(), "first tryLock on an uncontended path should succeed")
            lock.unlock()
        }
    }

    suite("a second holder cannot acquire while the first still holds the lock") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let first = FileLock(path: lockPath)
            let second = FileLock(path: lockPath)

            expect(first.tryLock(), "first tryLock should succeed")
            expect(
                !second.tryLock(),
                "second tryLock on the same path must fail while first holds the lock (non-blocking)"
            )

            first.unlock()
        }
    }

    suite("unlock releases the lock so a later tryLock can succeed") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let first = FileLock(path: lockPath)
            let second = FileLock(path: lockPath)

            expect(first.tryLock(), "first tryLock should succeed")
            first.unlock()
            expect(second.tryLock(), "tryLock after release should succeed")
            second.unlock()
        }
    }

    suite("deinit releases the lock without an explicit unlock() call") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            do {
                let scoped = FileLock(path: lockPath)
                expect(scoped.tryLock(), "scoped tryLock should succeed")
                // `scoped` goes out of scope here; `deinit` must release the flock so the
                // fd isn't leaked and the next holder isn't blocked forever.
            }
            let after = FileLock(path: lockPath)
            expect(after.tryLock(), "tryLock after the holder deinit'd should succeed")
            after.unlock()
        }
    }

    suite("locks on different paths never conflict") {
        withTempDirectory { directory in
            let lockA = FileLock(path: directory.appendingPathComponent("a.lock").path)
            let lockB = FileLock(path: directory.appendingPathComponent("b.lock").path)
            expect(lockA.tryLock(), "lock A should succeed")
            expect(lockB.tryLock(), "lock B on a different path should also succeed")
            lockA.unlock()
            lockB.unlock()
        }
    }

    suite("tryLock is idempotent-safe when called twice by the same holder") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let lock = FileLock(path: lockPath)
            expect(lock.tryLock(), "first tryLock should succeed")
            // Re-locking on the same open file description is a no-op success for flock(2).
            expect(lock.tryLock(), "re-locking the same holder should still report success")
            lock.unlock()
        }
    }

    suite("withNonBlockingLock runs the body and returns .ran(value) when uncontended") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let outcome = withNonBlockingLock(path: lockPath) { 42 }
            if case .ran(let value) = outcome {
                expect(value == 42, "withNonBlockingLock should carry the body's value")
            } else {
                expect(false, "uncontended withNonBlockingLock should be .ran, got \(outcome)")
            }
        }
    }

    suite("withNonBlockingLock returns .skipped without running the body when contended") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let holder = FileLock(path: lockPath)
            expect(holder.tryLock(), "holder should acquire the lock first")

            var bodyRan = false
            let outcome = withNonBlockingLock(path: lockPath) { () -> Int in
                bodyRan = true
                return 1
            }

            if case .skipped = outcome {
                // expected
            } else {
                expect(false, "contended withNonBlockingLock must be .skipped, got \(outcome)")
            }
            expect(!bodyRan, "withNonBlockingLock must not run the body when contended")
            holder.unlock()
        }
    }

    suite("attemptLock reports .busy (not .failed) under real contention") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let first = FileLock(path: lockPath)
            let second = FileLock(path: lockPath)
            expect(first.tryLock(), "first tryLock should succeed")
            expect(
                second.attemptLock() == .busy,
                "a contended attemptLock must be .busy, never .failed")
            first.unlock()
        }
    }

    suite("attemptLock reports .failed (not .busy) when the lock file can't be opened") {
        withTempDirectory { directory in
            // Parent directory does not exist → open(O_CREAT) fails with ENOENT. This is
            // the real production failure mode: `~/.claudio` deleted or unwritable. It
            // must NOT be mistaken for contention.
            let unreachable =
                directory
                .appendingPathComponent("does-not-exist", isDirectory: true)
                .appendingPathComponent("play.lock").path
            let lock = FileLock(path: unreachable)
            if case .failed = lock.attemptLock() {
                // expected
            } else {
                expect(false, "open() failure must be .failed, not .busy/.acquired")
            }
            expect(!lock.tryLock(), "tryLock must be false when the lock file can't be opened")
        }
    }

    suite("withNonBlockingLock surfaces .failed (never .skipped) on a real system error") {
        withTempDirectory { directory in
            let unreachable =
                directory
                .appendingPathComponent("does-not-exist", isDirectory: true)
                .appendingPathComponent("play.lock").path
            var bodyRan = false
            let outcome = withNonBlockingLock(path: unreachable) { () -> Int in
                bodyRan = true
                return 1
            }
            if case .failed = outcome {
                // expected — a broken filesystem must not masquerade as a debounce skip.
            } else {
                expect(false, "system error must be .failed, got \(outcome)")
            }
            expect(!bodyRan, "withNonBlockingLock must not run the body on a system error")
        }
    }

    suite("withNonBlockingLock releases the lock after the body returns") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            _ = withNonBlockingLock(path: lockPath) { 1 }

            let after = FileLock(path: lockPath)
            expect(after.tryLock(), "lock must be released once withNonBlockingLock returns")
            after.unlock()
        }
    }

    suite("withNonBlockingLock releases the lock even when the body throws") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            _ = try? withNonBlockingLock(path: lockPath) { throw ThrowingBodyError() }

            let after = FileLock(path: lockPath)
            expect(after.tryLock(), "lock must be released even when the body throws")
            after.unlock()
        }
    }
}
