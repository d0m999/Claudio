import ClaudioCore
import Dispatch
import Foundation

// MARK: - claudio.log: rolling diagnostic log + doctor tail-read (ENGINEERING.md 决议 6, T6)
//
// Acceptance (ENGINEERING.md T6 / team-lead handoff):
// (1) exceeding the size cap triggers rotation; the log never grows unboundedly.
// (2) an appended line can always be parsed back by doctor's reader.
// (3) concurrent appends never tear/interleave a line's content.

@MainActor
func runLogSuites() {
    suite("appendLogLine writes a line readRecentLogEntries parses back exactly") {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

            let wrote = appendLogLine(
                event: "stop", reason: "afplay 启动失败：/usr/bin/afplay",
                timestamp: timestamp, to: logFile, lockFile: lockFile)
            expect(wrote, "appendLogLine on an uncontended lock must report success")

            let entries = readRecentLogEntries(from: logFile)
            expect(entries.count == 1, "expected exactly one entry, got \(entries.count)")
            expect(entries.first?.event == "stop", "event must round-trip exactly")
            expect(
                entries.first?.reason == "afplay 启动失败：/usr/bin/afplay",
                "reason (Chinese prose incl. punctuation) must round-trip exactly, got"
                    + " \(String(describing: entries.first?.reason))")
            expect(
                entries.first.map { abs($0.timestamp.timeIntervalSince(timestamp)) < 1 } ?? false,
                "timestamp must round-trip to within a second (ISO8601 truncates sub-second)")
        }
    }

    suite("appendLogLine self-heals a missing parent directory (first-run onboarding)") {
        withTempDirectory { root in
            let missingParent = root.appendingPathComponent("does-not-exist-yet")
            let logFile = missingParent.appendingPathComponent("claudio.log")
            let lockFile = missingParent.appendingPathComponent("claudio.log.lock")
            expect(
                !FileManager.default.fileExists(atPath: missingParent.path),
                "sanity: parent directory must not exist before appendLogLine runs")

            let wrote = appendLogLine(
                event: "stop", reason: "test", to: logFile, lockFile: lockFile)
            expect(wrote, "appendLogLine must self-heal the missing parent directory")
            expect(
                readRecentLogEntries(from: logFile).count == 1,
                "the line must actually be readable after self-heal")
        }
    }

    suite("readRecentLogEntries: missing log file (fresh install) -> empty, never crashes") {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            expect(
                readRecentLogEntries(from: logFile).isEmpty,
                "a log file that was never written must read back as zero entries")
        }
    }

    suite("readRecentLogEntries: a garbled/malformed line is skipped, not crashed on") {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            writeFixture("this is not a valid log line at all\n", to: logFile)
            expect(
                readRecentLogEntries(from: logFile).isEmpty,
                "a line with no parseable timestamp/event/reason fields must be skipped")
        }
    }

    suite("readRecentLogEntries returns entries oldest-to-newest, capped at maxLines") {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            for index in 0..<10 {
                appendLogLine(
                    event: "evt-\(index)", reason: "reason-\(index)",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    to: logFile, lockFile: lockFile)
            }

            let entries = readRecentLogEntries(from: logFile, maxLines: 3)
            expect(entries.count == 3, "expected exactly 3 entries (capped), got \(entries.count)")
            expect(
                entries.map(\.event) == ["evt-7", "evt-8", "evt-9"],
                "expected the LAST 3 appended entries in original order, got \(entries.map(\.event))"
            )
        }
    }

    suite(
        "rotation (acceptance 1): appending far past maxBytes keeps the log bounded, never"
            + " growing unboundedly"
    ) {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            let maxBytes = 2_000
            let iterations = 500
            for index in 0..<iterations {
                appendLogLine(
                    event: "stop",
                    reason: "some reasonably long failure reason text number \(index)",
                    to: logFile, lockFile: lockFile, maxBytes: maxBytes)
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
            let finalSize = (attributes?[.size] as? NSNumber)?.intValue ?? Int.max
            // Unbounded growth would be ~500 * 60 bytes ≈ 30,000 bytes. A working rotation
            // keeps the file within a small constant multiple of maxBytes regardless of how
            // many lines were appended.
            expect(
                finalSize <= maxBytes * 2,
                "log file must stay bounded near maxBytes (\(maxBytes)) after \(iterations)"
                    + " appends, got \(finalSize) bytes — rotation is not capping growth")

            // The tail must still be genuinely readable (rotation didn't corrupt content).
            let entries = readRecentLogEntries(from: logFile, maxLines: 5)
            expect(
                entries.last?.event == "stop" && entries.last?.reason.hasSuffix("\(iterations - 1)")
                    == true,
                "the most recently appended entry must survive rotation intact, got"
                    + " \(String(describing: entries.last))")
        }
    }

    suite(
        "rotation never leaves a truncated/partial first line that misparses (only whole"
            + " lines survive a rotation cut)"
    ) {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            let maxBytes = 300
            for index in 0..<40 {
                appendLogLine(
                    event: "evt", reason: "r\(index)", to: logFile, lockFile: lockFile,
                    maxBytes: maxBytes)
            }

            guard let data = try? Data(contentsOf: logFile),
                let text = String(data: data, encoding: .utf8)
            else {
                expect(false, "log file must still be readable after repeated rotation")
                return
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                let fields = line.components(separatedBy: "\t")
                expect(
                    fields.count == 3,
                    "every surviving line after rotation must have exactly 3 tab-delimited"
                        + " fields (no partial line), got \(fields.count) in: \(line)")
            }
        }
    }

    suite(
        "concurrency (acceptance 3): concurrent appendLogLine calls from many threads never"
            + " tear or interleave a line's content"
    ) {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            let iterations = 60

            DispatchQueue.concurrentPerform(iterations: iterations) { index in
                appendLogLine(
                    event: "concurrent-evt-\(index)", reason: "concurrent-reason-\(index)",
                    to: logFile, lockFile: lockFile)
            }

            guard let data = try? Data(contentsOf: logFile),
                let text = String(data: data, encoding: .utf8)
            else {
                expect(false, "log file must be readable after concurrent appends")
                return
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            expect(
                !lines.isEmpty,
                "at least some concurrent appends must have succeeded (uncontended start)")

            // How many of the `iterations` concurrent appends actually landed varies run to
            // run (lock contention is real, non-blocking-skip is by design) — so, to keep
            // this suite's total assertion count deterministic across runs, every line is
            // folded into three FIXED checks below rather than one `expect` per line.
            var eventIndices: [Int] = []
            var everyLineWellFormed = true
            var everyLineInternallyConsistent = true
            for line in lines {
                let fields = line.components(separatedBy: "\t")
                guard fields.count == 3 else {
                    everyLineWellFormed = false
                    continue
                }
                guard
                    let eventIndex = Int(
                        fields[1].replacingOccurrences(of: "concurrent-evt-", with: "")),
                    fields[2] == "concurrent-reason-\(eventIndex)"
                else {
                    everyLineInternallyConsistent = false
                    continue
                }
                eventIndices.append(eventIndex)
            }

            expect(
                everyLineWellFormed,
                "every line must have exactly 3 tab-delimited fields, never torn/merged"
                    + " content — some line in \(lines) did not")
            expect(
                everyLineInternallyConsistent,
                "every line's event and reason must belong to the SAME append call (no"
                    + " interleaving between two concurrent writers) — some line in \(lines)"
                    + " mismatched")
            expect(
                Set(eventIndices).count == eventIndices.count,
                "each concurrent append's index must appear at most once — a duplicate would"
                    + " mean a torn/retried write, got \(eventIndices)")
        }
    }

    suite(
        "readRecentLogEntries: a garbled trailing line doesn't shrink the maxLines budget"
            + " of well-formed entries (codex review of ea08eca, P2)"
    ) {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            for index in 0..<3 {
                appendLogLine(
                    event: "evt-\(index)", reason: "reason-\(index)",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    to: logFile, lockFile: lockFile)
            }
            // Simulate a corrupted/partial trailing write by appending a line with no
            // parseable timestamp/event/reason fields directly (bypassing appendLogLine).
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(Data("garbled-not-a-real-line\n".utf8))
                try? handle.close()
            }

            let entries = readRecentLogEntries(from: logFile, maxLines: 3)
            expect(
                entries.count == 3,
                "a malformed trailing line must not shrink the valid-entry budget, got"
                    + " \(entries.count)")
            expect(
                entries.map(\.event) == ["evt-0", "evt-1", "evt-2"],
                "must still return the 3 real entries in oldest-to-newest order, got"
                    + " \(entries.map(\.event))")
        }
    }

    suite(
        "appendLogLine reports failure (not success) when the underlying write fails"
            + " (codex review of ea08eca, P2)"
    ) {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            let lockFile = root.appendingPathComponent("claudio.log.lock")
            // Force the write to fail: `logFile` is itself a directory, so `open(2)`
            // with O_WRONLY on it fails (EISDIR) even though the parent exists fine.
            try? FileManager.default.createDirectory(
                at: logFile, withIntermediateDirectories: true)

            let wrote = appendLogLine(
                event: "stop", reason: "test", to: logFile, lockFile: lockFile)
            expect(
                !wrote,
                "appendLogLine must report failure when the underlying write fails, not"
                    + " silently claim success")
        }
    }
}
