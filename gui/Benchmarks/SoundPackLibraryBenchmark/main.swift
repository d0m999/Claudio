import ClaudioCore
import ClaudioGUICore
import Darwin
import Foundation

private struct BenchmarkDurationProbe: AudioDurationProbing {
    func probeDuration(of fileURL: URL) -> TimeInterval? { 1 }
}

private enum BenchmarkFailure: Error, CustomStringConvertible {
    case scan(String)
    case streamEnded
    case invalidFixture(expected: Int, actual: Int)
    case invalidArguments(String)
    case budgetExceeded(coldP95: Double, cachedP95: Double)

    var description: String {
        switch self {
        case .scan(let reason): return reason
        case .streamEnded: return "SoundPackLibrary state stream unexpectedly ended"
        case .invalidFixture(let expected, let actual):
            return "expected \(expected) packs, got \(actual)"
        case .invalidArguments(let reason): return reason
        case .budgetExceeded(let coldP95, let cachedP95):
            return String(
                format: "benchmark budget exceeded (cold %.3f ms, cached %.3f ms)",
                coldP95,
                cachedP95)
        }
    }
}

private struct Measurement {
    let milliseconds: Double
    let snapshot: SoundPackLibrarySnapshot
}

private func percentile95(_ samples: [Double]) -> Double {
    let ordered = samples.sorted()
    let index = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
    return ordered[index]
}

private func projectedPackCount(
    _ snapshot: SoundPackLibrarySnapshot,
    selectedPackID: String
) -> Int {
    let config = ClaudioConfig(selectedPack: selectedPackID)
    let cards = snapshot.packCards(config: config)
    _ = snapshot.eventRows(packID: selectedPackID, config: config)
    return cards.count
}

private func refreshMeasurement(
    library: SoundPackLibrary,
    trigger: SoundPackLibraryRefreshTrigger,
    afterRevision: UInt64?,
    expectedPackCount: Int
) async throws -> Measurement {
    let stream = await library.states()
    let started = DispatchTime.now().uptimeNanoseconds
    await library.requestRefresh(trigger: trigger)
    for await state in stream {
        switch state {
        case .ready(let snapshot) where afterRevision.map({ snapshot.revision > $0 }) ?? true:
            let projected = projectedPackCount(snapshot, selectedPackID: "pack-000")
            guard projected == expectedPackCount else {
                throw BenchmarkFailure.invalidFixture(
                    expected: expectedPackCount, actual: projected)
            }
            return Measurement(
                milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                snapshot: snapshot)
        case .failed(_, let error):
            throw BenchmarkFailure.scan(error.message)
        default:
            continue
        }
    }
    throw BenchmarkFailure.streamEnded
}

@MainActor
private func cachedPresentationMilliseconds(
    library: SoundPackLibrary,
    environment: AudioImportEnvironment,
    configFile: URL,
    expectedPackCount: Int
) async throws -> Double {
    let started = DispatchTime.now().uptimeNanoseconds
    let model = SoundPacksWindowModel(
        configFile: configFile,
        lockFile: configFile.deletingLastPathComponent().appendingPathComponent("config.lock"),
        environment: environment,
        soundPackLibrary: library,
        refreshCoordinator: SoundPacksRefreshCoordinator())
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if model.libraryPresentationState == .ready {
            guard model.packCards.count == expectedPackCount else {
                throw BenchmarkFailure.invalidFixture(
                    expected: expectedPackCount, actual: model.packCards.count)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
        if case .loadFailed(let reason) = model.libraryPresentationState {
            throw BenchmarkFailure.scan(reason)
        }
        await Task.yield()
    }
    throw BenchmarkFailure.streamEnded
}

private func makeFixture(packCount: Int) throws -> (
    root: URL, environment: AudioImportEnvironment, configFile: URL
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "claudi0-sound-pack-benchmark-\(UUID().uuidString)", isDirectory: true)
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    let audio = Data(repeating: 0x41, count: 64)

    for index in 0..<packCount {
        let id = String(format: "pack-%03d", index)
        let directory = packs.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let manifest = """
            {"schema":1,"id":"\(id)","name":"Benchmark \(index)","events":{"task_start":"task_start.mp3","stop":"stop.mp3","stop_failure":"stop_failure.mp3","notification":"notification.mp3","subagent_stop":"subagent_stop.mp3"}}
            """
        try Data(manifest.utf8).write(
            to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        for fileName in [
            "task_start.mp3", "stop.mp3", "stop_failure.mp3", "notification.mp3",
            "subagent_stop.mp3",
        ] {
            try audio.write(to: directory.appendingPathComponent(fileName))
        }
    }

    let configFile = root.appendingPathComponent("config.json")
    try Data(
        #"{"selected_pack":"pack-000","events":{},"starred_packs":[]}"#.utf8
    ).write(to: configFile, options: .atomic)
    return (
        root,
        AudioImportEnvironment(
            userPacksDirectory: packs,
            durationProbe: BenchmarkDurationProbe(),
            packsLockFile: root.appendingPathComponent("packs.lock")),
        configFile
    )
}

let processEnvironment = ProcessInfo.processInfo.environment
let packCount = Int(processEnvironment["CLAUDIO_BENCHMARK_PACKS"] ?? "") ?? 100
let coldSampleCount = Int(processEnvironment["CLAUDIO_BENCHMARK_COLD_SAMPLES"] ?? "") ?? 30
let cachedSampleCount = Int(processEnvironment["CLAUDIO_BENCHMARK_CACHED_SAMPLES"] ?? "") ?? 100
let incrementalSampleCount =
    Int(processEnvironment["CLAUDIO_BENCHMARK_INCREMENTAL_SAMPLES"] ?? "") ?? 30
let coldLimitMilliseconds =
    Double(processEnvironment["CLAUDIO_BENCHMARK_COLD_LIMIT_MS"] ?? "") ?? 500.0
let cachedLimitMilliseconds =
    Double(processEnvironment["CLAUDIO_BENCHMARK_CACHED_LIMIT_MS"] ?? "") ?? 100.0

do {
    guard
        packCount > 0,
        coldSampleCount > 0,
        cachedSampleCount > 0,
        incrementalSampleCount > 0,
        coldLimitMilliseconds.isFinite,
        coldLimitMilliseconds > 0,
        cachedLimitMilliseconds.isFinite,
        cachedLimitMilliseconds > 0
    else {
        throw BenchmarkFailure.invalidArguments(
            "pack/sample counts and finite timing limits must all be positive")
    }
    let fixture = try makeFixture(packCount: packCount)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // Warm filesystem and generated code paths, but never reuse an app-session snapshot in cold
    // samples: each measured iteration owns a fresh SoundPackLibrary actor.
    for _ in 0..<3 {
        let library = SoundPackLibrary(environment: fixture.environment)
        _ = try await refreshMeasurement(
            library: library,
            trigger: .initial,
            afterRevision: nil,
            expectedPackCount: packCount)
    }

    var coldSamples: [Double] = []
    coldSamples.reserveCapacity(coldSampleCount)
    for _ in 0..<coldSampleCount {
        let library = SoundPackLibrary(environment: fixture.environment)
        let measurement = try await refreshMeasurement(
            library: library,
            trigger: .initial,
            afterRevision: nil,
            expectedPackCount: packCount)
        coldSamples.append(measurement.milliseconds)
    }

    let sharedLibrary = SoundPackLibrary(environment: fixture.environment)
    var latest = try await refreshMeasurement(
        library: sharedLibrary,
        trigger: .initial,
        afterRevision: nil,
        expectedPackCount: packCount
    ).snapshot

    var cachedSamples: [Double] = []
    cachedSamples.reserveCapacity(cachedSampleCount)
    for _ in 0..<cachedSampleCount {
        cachedSamples.append(
            try await cachedPresentationMilliseconds(
                library: sharedLibrary,
                environment: fixture.environment,
                configFile: fixture.configFile,
                expectedPackCount: packCount))
    }

    var incrementalSamples: [Double] = []
    incrementalSamples.reserveCapacity(incrementalSampleCount)
    for _ in 0..<incrementalSampleCount {
        let measurement = try await refreshMeasurement(
            library: sharedLibrary,
            trigger: .applicationActivation,
            afterRevision: latest.revision,
            expectedPackCount: packCount)
        latest = measurement.snapshot
        incrementalSamples.append(measurement.milliseconds)
    }

    let coldP95 = percentile95(coldSamples)
    let cachedP95 = percentile95(cachedSamples)
    let incrementalP95 = percentile95(incrementalSamples)
    print("packs=\(packCount)")
    print("cold_samples=\(coldSampleCount)")
    print(String(format: "cold_p95_ms=%.3f", coldP95))
    print("cached_samples=\(cachedSampleCount)")
    print(String(format: "cached_p95_ms=%.3f", cachedP95))
    print("incremental_samples=\(incrementalSampleCount)")
    print(String(format: "incremental_p95_ms=%.3f", incrementalP95))
    print(String(format: "cold_limit_ms=%.0f", coldLimitMilliseconds))
    print(String(format: "cached_limit_ms=%.0f", cachedLimitMilliseconds))

    guard coldP95 <= coldLimitMilliseconds, cachedP95 <= cachedLimitMilliseconds else {
        throw BenchmarkFailure.budgetExceeded(coldP95: coldP95, cachedP95: cachedP95)
    }
    print("result=pass")
} catch {
    fputs("benchmark failed: \(error)\n", stderr)
    exit(1)
}
