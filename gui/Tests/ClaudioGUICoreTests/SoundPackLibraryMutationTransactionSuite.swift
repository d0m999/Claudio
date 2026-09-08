import ClaudioCore
import Foundation

@testable import ClaudioGUICore

private final class MutationTransactionScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let firstScanEntered = DispatchSemaphore(value: 0)
    private let firstScanResume = DispatchSemaphore(value: 0)
    private let blocksFirstScan: Bool
    private let failsFirstScan: Bool
    private var requestsStorage: [SoundPackLibraryScanRequest] = []

    init(blocksFirstScan: Bool = false, failsFirstScan: Bool = false) {
        self.blocksFirstScan = blocksFirstScan
        self.failsFirstScan = failsFirstScan
    }

    var requests: [SoundPackLibraryScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func waitUntilFirstScanEntered() -> Bool {
        firstScanEntered.wait(timeout: .now() + 5) == .success
    }

    func allowFirstScanToFinish() {
        firstScanResume.signal()
    }

    func scan(
        _ request: SoundPackLibraryScanRequest
    ) -> Result<[SoundPackFacts], SoundPackLibraryError> {
        lock.lock()
        requestsStorage.append(request)
        let call = requestsStorage.count
        lock.unlock()

        if blocksFirstScan && call == 1 {
            firstScanEntered.signal()
            _ = firstScanResume.wait(timeout: .now() + 5)
        }
        if failsFirstScan && call == 1 {
            return .failure(.scanFailed(reason: "stale transaction failure"))
        }
        return .success([mutationTransactionFact(name: "scan-\(call)")])
    }
}

private final class MutationTerminalDeferralProbe: @unchecked Sendable {
    private let deferred = DispatchSemaphore(value: 0)

    func record() {
        deferred.signal()
    }

    func wait() -> Bool {
        deferred.wait(timeout: .now() + 5) == .success
    }
}

private final class MutationWaiterCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completedStorage = false

    var completed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completedStorage
    }

    func record() {
        lock.lock()
        completedStorage = true
        lock.unlock()
    }
}

private func mutationTransactionFact(name: String) -> SoundPackFacts {
    SoundPackFacts(
        id: "pack-result",
        name: name,
        isCC0: false,
        factoryIntegrity: nil,
        eventCoverage: [.stop: .present(fileName: "stop.mp3")],
        cardState: .partial(present: 1, total: Event.allCases.count),
        audioInventory: .available([
            PackAudioFile(fileName: "stop.mp3", isOrphan: false)
        ]))
}

@MainActor
private func waitForMutationScanCount(
    _ scanner: MutationTransactionScanner,
    _ expected: Int,
    timeoutNanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if scanner.requests.count >= expected { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return scanner.requests.count >= expected
}

@MainActor
private func drainMutationNotifications(_ library: SoundPackLibrary) async {
    await library.waitUntilIdleForTesting()
    for _ in 0..<16 { await Task.yield() }
}

@MainActor
func runSoundPackLibraryMutationTransactionSuites() async {
    await suite("SoundPackLibrary transaction：idle noChange 不启动 scan") {
        let scanner = MutationTransactionScanner()
        let library = SoundPackLibrary(scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let mutation = library.beginMutation(packIDs: ["pack-nochange"])

        expect(library.endMutation(mutation, changed: false), "有效 token 必须恰好关闭一次")
        await drainMutationNotifications(library)

        expect(scanner.requests.isEmpty, "idle noChange 必须保持零 scan")
    }

    await suite("SoundPackLibrary transaction：idle changed 启动一次 exact-ID scan") {
        let scanner = MutationTransactionScanner()
        let library = SoundPackLibrary(scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let mutation = library.beginMutation(packIDs: ["pack-a", "pack-b"])

        expect(library.endMutation(mutation, changed: true), "有效 changed token 必须成功关闭")
        expect(
            await waitForMutationScanCount(scanner, 1),
            "idle changed 必须启动 completion scan")
        await drainMutationNotifications(library)

        expect(scanner.requests.count == 1, "idle changed 只能启动一次 scan")
        expect(
            scanner.requests.first?.invalidatedPackIDs == ["pack-a", "pack-b"]
                && scanner.requests.first?.invalidatesAll == false,
            "idle changed 必须携带 exact affected IDs，不能退化为 full invalidation")
    }

    await suite("SoundPackLibrary transaction：old in-flight + noChange 只追加一次 follow-up") {
        let scanner = MutationTransactionScanner(blocksFirstScan: true)
        let deferral = MutationTerminalDeferralProbe()
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan),
            onRejectedTerminalDeferred: deferral.record)

        await library.requestRefresh(trigger: .initial)
        guard scanner.waitUntilFirstScanEntered() else {
            scanner.allowFirstScanToFinish()
            expect(false, "旧 scan 必须确定性进入 in-flight")
            return
        }
        let mutation = library.beginMutation(packIDs: ["pack-nochange"])
        scanner.allowFirstScanToFinish()
        expect(deferral.wait(), "pre-fence 必须拒绝并 defer 旧 terminal")
        expect(scanner.requests.count == 1, "mutation open 时不得启动 follow-up")

        expect(library.endMutation(mutation, changed: false), "noChange token 必须成功关闭")
        expect(
            await waitForMutationScanCount(scanner, 2),
            "旧 scan 跨过 noChange interval 仍必须补一次 scan")
        await drainMutationNotifications(library)

        expect(scanner.requests.count == 2, "old + noChange 最终必须正好一次 follow-up")
        expect(
            scanner.requests.last?.invalidatedPackIDs == ["pack-nochange"]
                && scanner.requests.last?.invalidatesAll == false,
            "noChange follow-up 必须保留 pre-fence exact ID")
    }

    await suite("SoundPackLibrary transaction：old in-flight + changed 只追加一次 exact-union follow-up")
    {
        let scanner = MutationTransactionScanner(blocksFirstScan: true)
        let deferral = MutationTerminalDeferralProbe()
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan),
            onRejectedTerminalDeferred: deferral.record)

        await library.requestRefresh(trigger: .initial)
        guard scanner.waitUntilFirstScanEntered() else {
            scanner.allowFirstScanToFinish()
            expect(false, "旧 scan 必须确定性进入 in-flight")
            return
        }
        let mutation = library.beginMutation(packIDs: ["pack-a", "pack-b"])
        scanner.allowFirstScanToFinish()
        expect(deferral.wait(), "changed pre-fence 必须拒绝并 defer 旧 terminal")
        expect(scanner.requests.count == 1, "changed mutation open 时不得抢跑 follow-up")

        expect(library.endMutation(mutation, changed: true), "changed token 必须成功关闭")
        expect(
            await waitForMutationScanCount(scanner, 2),
            "changed completion 必须启动 follow-up")
        await drainMutationNotifications(library)

        expect(scanner.requests.count == 2, "old + changed 最终必须正好一次 follow-up")
        expect(
            scanner.requests.last?.invalidatedPackIDs == ["pack-a", "pack-b"]
                && scanner.requests.last?.invalidatesAll == false,
            "changed follow-up 必须携带 exact affected-ID union")
    }

    await suite("SoundPackLibrary transaction：stale failure 不发布且不提前恢复 waiter") {
        let scanner = MutationTransactionScanner(blocksFirstScan: true, failsFirstScan: true)
        let deferral = MutationTerminalDeferralProbe()
        let completion = MutationWaiterCompletionProbe()
        let library = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: scanner.scan),
            onRejectedTerminalDeferred: deferral.record)

        await library.requestRefresh(trigger: .initial)
        guard scanner.waitUntilFirstScanEntered() else {
            scanner.allowFirstScanToFinish()
            expect(false, "旧 failure scan 必须确定性进入 in-flight")
            return
        }
        let waiter = Task {
            let state = await library.refreshSnapshot(trigger: .windowPresentation)
            completion.record()
            return state
        }
        await library.waitUntilRefreshWaiterIsRegisteredForTesting()
        let mutation = library.beginMutation(packIDs: ["pack-failure"])
        scanner.allowFirstScanToFinish()

        expect(deferral.wait(), "pre-fence 必须拒绝并 defer 旧 failure terminal")
        expect(!completion.completed, "旧 failure terminal 不得提前恢复 waiter")
        let deferredState = await library.stateForTesting()
        if case .failed = deferredState {
            expect(false, "旧 failure terminal 不得发布为 library state")
        } else {
            expect(true, "旧 failure 已被拒绝")
        }
        expect(scanner.requests.count == 1, "mutation open 时 failure follow-up 不得抢跑")

        expect(library.endMutation(mutation, changed: true), "failure-crossing token 必须关闭")
        expect(
            await waitForMutationScanCount(scanner, 2),
            "final close 后必须启动唯一 failure recovery follow-up")
        let terminal = await waiter.value
        guard case .ready = terminal else {
            expect(false, "waiter 必须由 follow-up ready 恢复，实得 \(terminal)")
            return
        }
        await drainMutationNotifications(library)

        expect(completion.completed, "follow-up terminal 后 waiter 必须恢复")
        expect(scanner.requests.count == 2, "stale failure 后只能追加一次 follow-up")
        expect(
            scanner.requests.last?.invalidatedPackIDs == ["pack-failure"]
                && scanner.requests.last?.invalidatesAll == false,
            "failure recovery follow-up 必须携带 exact affected ID")
    }

    await suite("SoundPackLibrary transaction：overlapping tokens 任意 close order 只在 final close 扫一次")
    {
        for closesAFirst in [true, false] {
            let scanner = MutationTransactionScanner()
            let library = SoundPackLibrary(
                scanner: SoundPackLibraryScanner(operation: scanner.scan))
            let mutationA = library.beginMutation(packIDs: ["pack-a"])
            let mutationB = library.beginMutation(packIDs: ["pack-b"])

            let first = closesAFirst ? mutationA : mutationB
            let final = closesAFirst ? mutationB : mutationA
            expect(
                library.endMutation(first, changed: closesAFirst),
                "第一个 overlapping token 必须独立关闭")
            await drainMutationNotifications(library)
            expect(
                scanner.requests.isEmpty,
                "另一个 token 仍 open 时不得启动 scan（closesAFirst=\(closesAFirst)）")

            expect(
                library.endMutation(final, changed: !closesAFirst),
                "final overlapping token 必须独立关闭")
            expect(
                await waitForMutationScanCount(scanner, 1),
                "final close 必须启动唯一 completion scan")
            await drainMutationNotifications(library)

            expect(
                scanner.requests.count == 1,
                "两个 overlapping tokens 最终只能产生一次 scan")
            expect(
                scanner.requests.first?.invalidatedPackIDs == ["pack-a", "pack-b"]
                    && scanner.requests.first?.invalidatesAll == false,
                "overlapping tokens 必须合并为 exact affected-ID union")
        }
    }

    await suite("SoundPackLibrary transaction：foreign/replay token fail closed 且不能释放 fence") {
        let ownerScanner = MutationTransactionScanner()
        let foreignScanner = MutationTransactionScanner()
        let owner = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: ownerScanner.scan))
        let foreign = SoundPackLibrary(
            scanner: SoundPackLibraryScanner(operation: foreignScanner.scan))
        let mutation = owner.beginMutation(packIDs: ["pack-owner"])

        expect(
            !foreign.endMutation(mutation, changed: true),
            "foreign library 必须拒绝不属于自己的 token")
        let waiter = Task { await owner.refreshSnapshot(trigger: .retry) }
        await owner.waitUntilRefreshWaiterIsRegisteredForTesting()
        await drainMutationNotifications(owner)
        expect(
            ownerScanner.requests.isEmpty,
            "foreign end 不能释放 owner fence 或让 parked refresh 抢跑")

        expect(owner.endMutation(mutation, changed: false), "owner 必须仍能关闭原 token")
        expect(
            await waitForMutationScanCount(ownerScanner, 1),
            "真正 owner final close 后 parked refresh 必须继续")
        _ = await waiter.value
        expect(!owner.endMutation(mutation, changed: true), "replayed token 必须被拒绝")
        await drainMutationNotifications(owner)

        expect(ownerScanner.requests.count == 1, "token replay 不得产生第二次 scan")
        expect(foreignScanner.requests.isEmpty, "foreign token 不得改变 foreign library")
    }

    await suite("SoundPackLibrary transaction：refreshSnapshot waiter 仅在 final terminal 后恢复") {
        let scanner = MutationTransactionScanner(blocksFirstScan: true)
        let completion = MutationWaiterCompletionProbe()
        let library = SoundPackLibrary(scanner: SoundPackLibraryScanner(operation: scanner.scan))
        let mutationA = library.beginMutation(packIDs: ["pack-a"])
        let mutationB = library.beginMutation(packIDs: ["pack-b"])
        let waiter = Task {
            let state = await library.refreshSnapshot(trigger: .windowPresentation)
            completion.record()
            return state
        }
        await library.waitUntilRefreshWaiterIsRegisteredForTesting()

        expect(library.endMutation(mutationA, changed: true), "第一个 waiter fence 必须关闭")
        await drainMutationNotifications(library)
        expect(scanner.requests.isEmpty, "final token 前 waiter 请求不得启动 scan")
        expect(!completion.completed, "final token 前 waiter 不得恢复")

        expect(library.endMutation(mutationB, changed: false), "final waiter fence 必须关闭")
        guard scanner.waitUntilFirstScanEntered() else {
            scanner.allowFirstScanToFinish()
            expect(false, "final close 后 scan 必须进入 terminal 前闸门")
            return
        }
        expect(!completion.completed, "scan terminal 发布前 waiter 仍不得恢复")
        scanner.allowFirstScanToFinish()

        let terminal = await waiter.value
        guard case .ready = terminal else {
            expect(false, "final scan 必须用 ready terminal 恢复 waiter，实得 \(terminal)")
            return
        }
        expect(completion.completed, "final terminal 后 waiter 必须恢复")
        expect(scanner.requests.count == 1, "waiter transaction 只能触发一次 scan")
        expect(
            scanner.requests.first?.invalidatedPackIDs == ["pack-a", "pack-b"]
                && scanner.requests.first?.invalidatesAll == false,
            "waiter final scan 必须携带 overlapping exact-ID union")
    }
}
