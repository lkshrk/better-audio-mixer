import BamCore
import CoreAudio
import XCTest
@testable import AudioEngine

final class EngineConcurrencyTests: XCTestCase {
    override func tearDown() async throws {
        await CoreAudioEngine.setChangeListenerFactoryForTests(nil)
        await CoreAudioEngine.setRouterEventIntervalsForTests(poll: nil, debounce: nil)
    }

    func testResubscribingMeterSamplerCancelsThePreviousSampler() async {
        let engine = CoreAudioEngine()
        let first = await engine.routerSnapshots()
        let firstFinished = Task { () -> Int in
            var count = 0
            for await _ in first { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(80))
        let second = await engine.routerSnapshots()
        let secondTask = Task { for await _ in second {} }
        let delivered = await withTimeout(seconds: 2) { await firstFinished.value }
        XCTAssertNotNil(delivered, "the first sampler must finish once a second subscription replaces it")
        XCTAssertGreaterThan(delivered ?? 0, 0, "the first sampler was live before being replaced")
        secondTask.cancel()
    }

    func testMeterSamplingDoesNotRequireTheActor() async {
        let publication = MeterPublication()
        XCTAssertEqual(publication.snapshot(), .silent)
        let config = BamConfig(sources: [Source(id: "s", name: "S", kind: .rest)],
                               mixes: [Mix(id: "m", name: "M", dest: .virtualSlot(0), sends: [Send(source: "s")])])
        publication.publish(config: config, router: nil)
        let offline = publication.snapshot()
        XCTAssertEqual(offline.sources.map(\.id), ["s"])
        XCTAssertEqual(offline.mixes.map(\.id), ["m"])
        XCTAssertEqual(offline.sources.first?.level, RMSMeter.floorDB)
        XCTAssertEqual(offline.mixes.first?.levelLeft, RMSMeter.floorDB)
        publication.publish(config: nil, router: nil)
        XCTAssertEqual(publication.snapshot(), .silent)
    }

    func testFailedListenerRegistrationFallsBackToPolling() async {
        await CoreAudioEngine.setRouterEventIntervalsForTests(poll: .milliseconds(40), debounce: nil)
        await CoreAudioEngine.setChangeListenerFactoryForTests { _, _, _ in InactiveToken() }
        let engine = CoreAudioEngine()
        let events = await engine.routerEvents()
        let received = await withTimeout(seconds: 2) {
            for await _ in events { return true }
            return false
        }
        XCTAssertEqual(received, true, "a dead listener must not leave routerEvents silent forever")
    }

    func testRouterEventsAreDebounced() async {
        await CoreAudioEngine.setRouterEventIntervalsForTests(poll: nil, debounce: .milliseconds(300))
        let handlers = HandlerBox()
        await CoreAudioEngine.setChangeListenerFactoryForTests { _, _, onChange in
            handlers.append(onChange)
            return AnyChangeListenerToken {}
        }
        let engine = CoreAudioEngine()
        let events = await engine.routerEvents()
        let counter = HandlerBox()
        let consumer = Task {
            for await _ in events { counter.append {} }
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handlers.count, 3)
        for _ in 0..<5 {
            handlers.fireAll()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(counter.count, 0, "nothing is delivered while notifications keep arriving")
        let deadline = ContinuousClock.now + .seconds(3)
        while counter.count == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.count, 1, "a burst collapses into exactly one delivery")
        consumer.cancel()
    }

    func testProcessSnapshotCacheReusesInfoWithinTTLAndRefreshesRunningState() {
        let reads = HandlerBox()
        let ids = LockedValue<[AudioObjectID]>([1, 2])
        let running = LockedValue<Bool>(false)
        let cache = ProcessSnapshotCache(ttl: .seconds(1), readers: .init(
            objectIDs: { ids.value },
            info: { id in
                reads.append {}
                return AudioProcessInfo(objectID: id, pid: pid_t(id), bundleID: "app.\(id)", isRunningOutput: running.value)
            },
            isRunningOutput: { _ in running.value }))
        let start = ContinuousClock.now
        XCTAssertEqual(cache.snapshot(now: start).map(\.bundleID), ["app.1", "app.2"])
        XCTAssertEqual(reads.count, 2)
        running.value = true
        XCTAssertFalse(cache.snapshot(now: start.advanced(by: .milliseconds(500))).allSatisfy(\.isRunningOutput),
                       "within the TTL the cached running state is served")
        XCTAssertTrue(cache.snapshot(now: start.advanced(by: .seconds(2))).allSatisfy(\.isRunningOutput),
                      "after the TTL only the running flag is re-read")
        XCTAssertEqual(reads.count, 2, "bundle IDs are never re-read for a stable object list")
        cache.invalidate()
        running.value = false
        XCTAssertFalse(cache.snapshot(now: start.advanced(by: .seconds(2))).allSatisfy(\.isRunningOutput),
                       "invalidation forces a refresh regardless of age")
        ids.value = [1, 2, 3]
        XCTAssertEqual(cache.snapshot(now: start.advanced(by: .seconds(2))).count, 3)
        XCTAssertEqual(reads.count, 5, "a changed object list re-reads every process")
    }

    func testSampleRateMismatchCountFlagsSplitClocks() {
        XCTAssertEqual(RouterAggregate.sampleRateMismatchCount(tapRates: [48_000, 48_000], outputRate: 48_000), 0)
        XCTAssertEqual(RouterAggregate.sampleRateMismatchCount(tapRates: [44_100, 48_000, 96_000], outputRate: 48_000), 2)
        XCTAssertEqual(RouterAggregate.sampleRateMismatchCount(tapRates: [.nan], outputRate: 48_000), 1)
        let aggregate = RouterAggregate(taps: [])
        aggregate.cells.counter(.sampleRateMismatches).store(2, ordering: .relaxed)
        aggregate.cells.counter(.frameDivergenceCallbacks).store(7, ordering: .relaxed)
        let health = aggregate.healthSnapshot()
        XCTAssertEqual(health.sampleRateMismatches, 2)
        XCTAssertEqual(health.frameDivergenceCallbacks, 7)
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private final class InactiveToken: ChangeListenerToken {
    var isActive: Bool { false }
}

private final class HandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return handlers.count
    }

    func append(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
    }

    func fireAll() {
        lock.lock(); let current = handlers; lock.unlock()
        current.forEach { $0() }
    }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
