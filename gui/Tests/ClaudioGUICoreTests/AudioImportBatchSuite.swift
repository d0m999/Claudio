import ClaudioGUICore
import Foundation

// MARK: - importAudioFiles: multi-file batch, partial success (T8 acceptance criterion 7:
// "accept the valid files, and return a per-file list of rejected files each with its
// human Chinese reason")

@MainActor
func runAudioImportBatchSuites() {
    suite("importAudioFiles: a mixed batch accepts the valid files and lists each rejection's reason") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, maxFileSizeBytes: 100)

            let goodSource = root.appendingPathComponent("source/good.wav")
            writeFixture(validWAVData(), to: goodSource)

            var oversizedData = validWAVData()
            oversizedData.append(Data(repeating: 0, count: 200))
            let oversizedSource = root.appendingPathComponent("source/big.wav")
            writeFixture(oversizedData, to: oversizedSource)

            let badFormatSource = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: badFormatSource)

            let requests = [
                AudioImportRequest(sourceURL: goodSource, suggestedFileName: "good.wav"),
                AudioImportRequest(sourceURL: oversizedSource, suggestedFileName: "big.wav"),
                AudioImportRequest(sourceURL: badFormatSource, suggestedFileName: "evil.mp3"),
            ]

            let result = importAudioFiles(requests, packID: "my-pack", environment: environment)

            expect(result.accepted.count == 1, "exactly one file in the batch must be accepted")
            expect(
                result.accepted.first?.fileName == "good.wav",
                "the accepted file must be the legal wav")
            expect(result.rejected.count == 2, "exactly two files in the batch must be rejected")

            let rejectedNames = Set(result.rejected.map(\.sourceFileName))
            expect(
                rejectedNames == ["big.wav", "evil.mp3"],
                "rejected must name exactly the two bad files, got \(rejectedNames)")

            let bigReason = result.rejected.first { $0.sourceFileName == "big.wav" }?.reason
            guard case .oversize = bigReason else {
                expect(false, "big.wav must be rejected as .oversize, got \(String(describing: bigReason))")
                return
            }
            let evilReason = result.rejected.first { $0.sourceFileName == "evil.mp3" }?.reason
            expect(
                evilReason == .nonWhitelistFormat,
                "evil.mp3 must be rejected as .nonWhitelistFormat, got \(String(describing: evilReason))"
            )

            expect(
                FileManager.default.fileExists(
                    atPath: userPacksDirectory.appendingPathComponent("my-pack/good.wav").path),
                "the accepted file must actually be on disk")
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacksDirectory.appendingPathComponent("my-pack/big.wav").path),
                "a rejected file must never be written to disk")
        }
    }

    suite("importAudioFiles: an all-valid batch accepts every file, rejects none") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)

            let firstSource = root.appendingPathComponent("source/one.wav")
            writeFixture(validWAVData(), to: firstSource)
            let secondSource = root.appendingPathComponent("source/two.mp3")
            writeFixture(validMP3ID3Data(), to: secondSource)

            let requests = [
                AudioImportRequest(sourceURL: firstSource, suggestedFileName: "one.wav"),
                AudioImportRequest(sourceURL: secondSource, suggestedFileName: "two.mp3"),
            ]
            let result = importAudioFiles(requests, packID: "my-pack", environment: environment)

            expect(result.accepted.count == 2, "both legal files must be accepted")
            expect(result.rejected.isEmpty, "no file should be rejected in an all-valid batch")
        }
    }

    suite("importAudioFiles: an all-invalid batch rejects every file, accepts none") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)

            let firstSource = root.appendingPathComponent("source/one.mp3")
            writeFixture(evilShellScriptData(), to: firstSource)
            let secondSource = root.appendingPathComponent("source/two.mp3")
            writeFixture(evilShellScriptData(), to: secondSource)

            let requests = [
                AudioImportRequest(sourceURL: firstSource, suggestedFileName: "one.mp3"),
                AudioImportRequest(sourceURL: secondSource, suggestedFileName: "two.mp3"),
            ]
            let result = importAudioFiles(requests, packID: "my-pack", environment: environment)

            expect(result.accepted.isEmpty, "no file should be accepted in an all-invalid batch")
            expect(result.rejected.count == 2, "both files must be rejected")
        }
    }
}
