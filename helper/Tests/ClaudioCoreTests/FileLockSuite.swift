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

    suite("withNonBlockingLock runs the body and returns its value when uncontended") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let result = withNonBlockingLock(path: lockPath) { 42 }
            expect(result == 42, "withNonBlockingLock should return the body's value")
        }
    }

    suite("withNonBlockingLock returns nil without running the body when contended") {
        withTempDirectory { directory in
            let lockPath = directory.appendingPathComponent("play.lock").path
            let holder = FileLock(path: lockPath)
            expect(holder.tryLock(), "holder should acquire the lock first")

            var bodyRan = false
            let result = withNonBlockingLock(path: lockPath) { () -> Int in
                bodyRan = true
                return 1
            }

            expect(result == nil, "withNonBlockingLock must return nil when contended")
            expect(!bodyRan, "withNonBlockingLock must not run the body when contended")
            holder.unlock()
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
