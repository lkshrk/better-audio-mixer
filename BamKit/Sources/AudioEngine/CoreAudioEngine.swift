import AppKit
import BamCore
import CoreAudio
import Foundation

extension BamConfig {
    var hardwareOutputUID: String? {
        for mix in mixes {
            if case .hardware(let uid) = mix.dest { return uid }
        }
        return nil
    }
}

extension RouterStatus {
    static func offline(_ config: BamConfig, _ cause: RouterFailureCause) -> RouterStatus {
        RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: cause)
    }
}

public actor CoreAudioEngine: AudioEngineProtocol {
    typealias ChangeListenerFactory = @Sendable (
        AudioObjectID,
        AudioObjectPropertySelector,
        @escaping @Sendable () -> Void
    ) -> any ChangeListenerToken

    private final class ChangeListenerFactoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var override: ChangeListenerFactory?
        private var pollInterval: Duration = .seconds(2)
        private var debounce: Duration = .milliseconds(250)

        func set(_ factory: ChangeListenerFactory?) {
            lock.lock()
            override = factory
            lock.unlock()
        }

        func setIntervals(poll: Duration?, debounce: Duration?) {
            lock.lock()
            pollInterval = poll ?? .seconds(2)
            self.debounce = debounce ?? .milliseconds(250)
            lock.unlock()
        }

        var intervals: (poll: Duration, debounce: Duration) {
            lock.lock()
            defer { lock.unlock() }
            return (pollInterval, debounce)
        }

        func make(
            object: AudioObjectID,
            selector: AudioObjectPropertySelector,
            onChange: @escaping @Sendable () -> Void
        ) -> any ChangeListenerToken {
            lock.lock()
            let factory = override
            lock.unlock()
            if let factory {
                return factory(object, selector, onChange)
            }
            return ChangeListener(object: object, selector: selector, onChange: onChange)
        }
    }

    private static let changeListenerFactoryStore = ChangeListenerFactoryStore()

    static func setChangeListenerFactoryForTests(_ factory: ChangeListenerFactory?) async {
        changeListenerFactoryStore.set(factory)
    }

    static func setRouterEventIntervalsForTests(poll: Duration?, debounce: Duration?) async {
        changeListenerFactoryStore.setIntervals(poll: poll, debounce: debounce)
    }

    typealias DeviceOps = (
        volume: @Sendable (String) -> Float?,
        muted: @Sendable (String) -> Bool,
        setVolume: @Sendable (String, Float) -> OutputWriteResult,
        setMuted: @Sendable (String, Bool) -> OutputWriteResult
    )

    private final class DeviceOpsStore: @unchecked Sendable {
        private let lock = NSLock()
        private var override: DeviceOps?

        func set(_ ops: DeviceOps?) {
            lock.lock()
            override = ops
            lock.unlock()
        }

        func get() -> DeviceOps? {
            lock.lock()
            defer { lock.unlock() }
            return override
        }
    }

    private static let deviceOpsStore = DeviceOpsStore()

    static func setDeviceOpsForTests(_ ops: DeviceOps?) async {
        deviceOpsStore.set(ops)
    }

    func performGuardedOutputRebuildForTests(uids: Set<String>, unmute: Bool, rebuild: () -> Bool) async {
        await performGuardedOutputRebuild(uids: uids, unmute: unmute) { rebuild() }
    }

    private static func resolvedDeviceVolume(uid: String) -> Float? {
        if let ops = deviceOpsStore.get() { return ops.volume(uid) }
        return deviceVolume(uid: uid)
    }

    private static func resolvedSetDeviceVolume(uid: String, _ volume: Float) -> OutputWriteResult {
        if let ops = deviceOpsStore.get() { return ops.setVolume(uid, volume) }
        return setDeviceVolumeChecked(uid: uid, volume)
    }

    private static func resolvedSetDeviceMuted(uid: String, _ muted: Bool) -> OutputWriteResult {
        if let ops = deviceOpsStore.get() { return ops.setMuted(uid, muted) }
        return setDeviceMutedChecked(uid: uid, muted)
    }

    private static func resolvedDeviceMuted(uid: String) -> Bool? {
        if let ops = deviceOpsStore.get() { return ops.muted(uid) }
        return deviceMuted(uid: uid)
    }

    private var recoveryOutputIntent: [String: OutputDeviceState] = [:]
    private var protectedOutputUIDs = Set<String>()
    struct RecoveryTestHooks: Sendable {
        let outputUIDs: Set<String>
        let willTearDown: @Sendable () -> Void
        let rebuild: @Sendable () -> RouterStatus
    }
    private var recoveryTestHooks: RecoveryTestHooks?
    func configureRecoveryForTests(config: BamConfig, hooks: RecoveryTestHooks) {
        routerConfig = config
        routerTapSig = "test-generation"
        recoveryTestHooks = hooks
    }
    func recoverRouterForTests(reason: RecoveryReason) async {
        routerTapSig = "test-generation"
        await recoverRouterAfterHealthFailure(signature: "test-generation", reason: reason)
    }
    func retryAfterRearmForTests(reason: RecoveryReason) async {
        await retryAfterRearm(reason: reason, signature: "test-generation")
    }
    func installRouterForTests(resources: sending RouterAggregate.IOResources) {
        router = RouterAggregate(taps: [], resources: resources)
    }
    func hasRouterForTests() -> Bool { router != nil }
    func routerAggregateIDForTests() -> AudioObjectID? { router?.aggregateID }
    func checkRouterHealthForTests() async -> Bool {
        guard let signature = routerTapSig else { return false }
        var state = RouterHealthState()
        return await checkRouterHealth(signature: signature, generation: routerGeneration, state: &state)
    }
    func routerStartupStateForTests() -> (pending: String?, deviceIDs: [String: AudioObjectID], monitoring: Bool) {
        (pendingRouterTapSig, appliedDeviceIDs, routerHealthTask != nil)
    }

    /// Output UID the running aggregate is bound to after live-list resolution; may differ from the stored UID.
    private var _boundOutputUID: String?

    private var router: RouterAggregate?
    private var lastAudioDiagnostics: AudioDiagnostics?
    private var diagnosticsGeneration = 0
    private var buildDiagnostics = AudioDiagnostics()
    private let meterPublication = MeterPublication()
    private let processCache: ProcessSnapshotCache

    public func audioDiagnostics() async -> AudioDiagnostics? {
        let current = router?.audioDiagnostics()
        var snapshot = current ?? lastAudioDiagnostics ?? AudioDiagnostics()
        if current != nil { snapshot.generation = diagnosticsGeneration }
        snapshot.isRunning = router != nil && routerTapSig != nil
        snapshot.aggregateBuildAttempts = buildDiagnostics.aggregateBuildAttempts
        snapshot.aggregateBuildSuccesses = buildDiagnostics.aggregateBuildSuccesses
        snapshot.aggregateBuildFailures = buildDiagnostics.aggregateBuildFailures
        snapshot.lastBuildMilliseconds = buildDiagnostics.lastBuildMilliseconds
        snapshot.maxBuildMilliseconds = buildDiagnostics.maxBuildMilliseconds
        return snapshot
    }

    private func recordAggregateBuild(success: Bool, milliseconds: Double) {
        buildDiagnostics.aggregateBuildAttempts = CallbackDiagnostics.increment(buildDiagnostics.aggregateBuildAttempts)
        if success {
            buildDiagnostics.aggregateBuildSuccesses = CallbackDiagnostics.increment(buildDiagnostics.aggregateBuildSuccesses)
        } else {
            buildDiagnostics.aggregateBuildFailures = CallbackDiagnostics.increment(buildDiagnostics.aggregateBuildFailures)
        }
        buildDiagnostics.lastBuildMilliseconds = max(0, milliseconds)
        buildDiagnostics.maxBuildMilliseconds = max(buildDiagnostics.maxBuildMilliseconds, milliseconds)
    }
    private var routerConfig: BamConfig?
    private var routerHealthBaseline: RouterHealthBaseline?
    private var routerHealthTask: Task<Void, Never>?
    private var routerRecoveryPolicy = RouterRecoveryPolicy()
    private var rearmTasks: [RecoveryReason: Task<Void, Never>] = [:]
    private var routerRecoverySuspended = false
    private var suspendedRecoveries: [RecoveryReason: (signature: String, generation: Int?, sourceIDs: Set<String>)] = [:]
    private var routerSamplerTask: Task<Void, Never>?
    /// Configured source slots survive process exit/relaunch; membership updates retain tap identity.
    private var liveTaps: [String: (spec: DesiredTapSpec, tap: RouterAggregate.Tap)] = [:]
    private var routerMembershipUncertain = false
    /// Signature of the live aggregate (output + ordered tap uuids); a matching next signature only refolds gains.
    private var routerTapSig: String?
    /// HAL started successfully, but a fresh valid callback has not confirmed readiness.
    private var pendingRouterTapSig: String?
    private var lastHealthyObservation: ContinuousClock.Instant?
    private var routerGeneration = 0
    private var healthyGeneration: Int?
    private var appliedDeviceIDs: [String: AudioObjectID] = [:]

    private var routerGateHeld = false
    private var routerGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Router mutations suspend across HAL work; the gate keeps them from interleaving.
    private func acquireRouterGate() async {
        if !routerGateHeld {
            routerGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            routerGateWaiters.append(continuation)
        }
    }

    private func releaseRouterGate() {
        if routerGateWaiters.isEmpty {
            routerGateHeld = false
        } else {
            routerGateWaiters.removeFirst().resume()
        }
    }

    struct SourceFormat: Equatable, Sendable {
        let sampleRate: Double
        let channels: Int
    }

    private struct RouterHealthBaseline {
        let generation: Int
        let outputUID: String
        let outputSampleRate: Double?
        let sourceFormats: [String: SourceFormat]
    }

    struct RouterHealthState {
        var lastFires = -1
        var staleSamples = 0
        var noInputSamples = 0
        var outputFormatDriftSamples = 0
        var sourceFormatDriftSamples: [String: Int] = [:]
        var lastSourceFrames: [String: Int] = [:]
        var sourceStaleSamples: [String: Int] = [:]
        var healthyStreak = 0
        var lastLimiterFailures = -1
        var limiterFailureSamples = 0

        mutating func retainExpectedSources(_ ids: Set<String>) {
            sourceStaleSamples = sourceStaleSamples.filter { ids.contains($0.key) }
            lastSourceFrames = lastSourceFrames.filter { ids.contains($0.key) }
        }

        /// Counts consecutive samples in which the cumulative failure total grew.
        mutating func recordLimiterFailures(_ total: Int) {
            if lastLimiterFailures >= 0, total > lastLimiterFailures {
                limiterFailureSamples += 1
            } else {
                limiterFailureSamples = 0
            }
            lastLimiterFailures = total
        }
    }

    private static let healthGainFloor: Float = 0.0001

    typealias Polling = (playing: @Sendable () -> Set<String>, processes: @Sendable () -> [AudioProcessInfo])
    private nonisolated let polling: Polling

    public init() {
        let cache = ProcessSnapshotCache()
        processCache = cache
        polling = (playing: {
            Set(cache.snapshot().filter { $0.isRunningOutput && !$0.bundleID.isEmpty }.map(\.bundleID))
        }, processes: { cache.snapshot() })
    }

    init(polling: Polling) {
        processCache = ProcessSnapshotCache()
        self.polling = polling
    }

    public nonisolated func outputDevices() async -> [AudioDevice] {
        await Task.detached(priority: .utility) {
            ProcessEnumerator.systemOutputDevices().map {
                AudioDevice(uid: $0.uid, name: $0.name, transportType: $0.transportType, dataSource: $0.dataSource)
            }
        }.value
    }

    public nonisolated func defaultOutputUID() async -> String? {
        await Task.detached(priority: .utility) { ProcessEnumerator.defaultOutputDeviceUID() }.value
    }

    /// The output device the live aggregate is bound to (post live-list resolution).
    public func boundOutputUID() -> String? { _boundOutputUID }

    /// Re-bind a stored output UID to a currently-present device. Exact UID wins.
    /// On miss, fall back to the single live device that shares the stored UID's
    /// stable anchor (USB re-enumeration drifts the trailing instance index but
    /// keeps the serial-bearing prefix). Missing or ambiguous selections stay
    /// unavailable; only an initial, unset selection can use the system default.
    static func resolveOutputUID(stored: String?) -> String? {
        if let stored, let device = ProcessEnumerator.deviceID(forUID: stored) {
            let streams: [AudioObjectID] = CA.array(device,
                CA.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput),
                of: AudioObjectID.self)
            if !streams.isEmpty { return stored }
        }
        return resolveOutputUID(stored: stored,
                                liveUIDs: ProcessEnumerator.systemOutputDevices().map(\.uid),
                                defaultUID: stored == nil ? ProcessEnumerator.defaultOutputDeviceUID() : nil)
    }

    static func resolveOutputUID(stored: String?, liveUIDs: [String], defaultUID: String?) -> String? {
        guard let stored else { return defaultUID }
        if liveUIDs.contains(stored) { return stored }
        let key = stableOutputKey(stored)
        let matches = liveUIDs.filter { stableOutputKey($0) == key }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Capture follows macOS routing; an absent system output never falls back to the listening device.
    private static func tapCaptureOutputUID() -> String? {
        ProcessEnumerator.defaultOutputDeviceUID()
    }

    /// Stable portion of a device UID across re-enumeration. Apple USB engine UIDs
    /// end in ":<instance>" that drifts on reconnect/wake, so drop it and anchor on
    /// the serial-bearing prefix. Other UID schemes (e.g. a display's GUID_endpoint)
    /// are returned whole so distinct endpoints of one device stay distinct.
    static func stableOutputKey(_ uid: String) -> String {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return uid }
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 1, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
            return parts.dropLast().joined(separator: ":")
        }
        return uid
    }

    public func outputVolume(uid: String) async -> Float? {
        if let intent = recoveryOutputIntent[uid] { return intent.volume }
        let observed = await HardwareExecutor.run { Self.resolvedDeviceVolume(uid: uid) }
        return recoveryOutputIntent[uid]?.volume ?? observed
    }

    public func outputDeviceState(uid: String) async -> OutputDeviceState? {
        if let intent = recoveryOutputIntent[uid] { return intent }
        return await HardwareExecutor.run { Self.resolvedDeviceState(uid: uid) }
    }

    /// Synchronous snapshot for termination, before the caller protects physical output.
    public nonisolated static func deviceState(uid: String) -> OutputDeviceState? {
        resolvedDeviceState(uid: uid)
    }

    public func restoreOutputDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) async -> OutputWriteResult {
        if restoreMute, state.mutes.values.contains(false), !outputReleaseReady {
            engineLog.error("hardware release blocked: pending=\(self.pendingRouterTapSig != nil, privacy: .public) uncertainMembership=\(self.routerMembershipUncertain, privacy: .public)")
            // User mute intent is deferred for engine-owned recovery, never applied while the renderer is pending.
            if let intended = recoveryOutputIntent[state.uid], intended.deviceID == state.deviceID,
               Set(intended.mutes.keys) == Set(state.mutes.keys) {
                recoveryOutputIntent[state.uid]?.mutes = state.mutes
            }
            return .failed
        }
        let result = await restoreDeviceState(state, restoreVolume: restoreVolume, restoreMute: restoreMute)
        if restoreMute {
            engineLog.notice("hardware mute restore target=\(state.muted, privacy: .public) applied=\(result == .applied, privacy: .public)")
        }
        return result
    }

    private var outputReleaseReady: Bool {
        pendingRouterTapSig == nil && !routerMembershipUncertain
            && ((router == nil && liveTaps.isEmpty) || routerTapSig != nil)
    }

    private static func resolvedDeviceState(uid: String) -> OutputDeviceState? {
        if let ops = deviceOpsStore.get() {
            guard let volume = ops.volume(uid), volume.isFinite else { return nil }
            return OutputDeviceState(uid: uid, deviceID: 0, volumes: [0: volume], mutes: [0: ops.muted(uid)])
        }
        guard let device = ProcessEnumerator.deviceID(forUID: uid) else { return nil }
        return captureDeviceState(uid: uid, deviceID: device, channels: outputChannelCount(device: device) ?? 0,
            volume: { CA.float32(device, CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0)) },
            mute: { element in
                CA.uint32Value(device, CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, element)).map { $0 != 0 }
            },
            settable: { CA.isSettable(device, CA.address($0, kAudioDevicePropertyScopeOutput, $1)) })
    }

    /// Shared capture path; a partial/unreadable control set cannot safely be restored.
    nonisolated static func captureDeviceState(
        uid: String, deviceID: UInt32, channels: Int,
        volume: (UInt32) -> Float?, mute: (UInt32) -> Bool?,
        settable: (AudioObjectPropertySelector, UInt32) -> Bool
    ) -> OutputDeviceState? {
        func elements(_ selector: AudioObjectPropertySelector) -> [UInt32] {
            if settable(selector, 0) { return [0] }
            return channels > 0 ? (1...channels).map(UInt32.init) : []
        }
        let volumeElements = elements(kAudioDevicePropertyVolumeScalar)
        let muteElements = elements(kAudioDevicePropertyMute)
        guard !volumeElements.isEmpty, !muteElements.isEmpty else { return nil }
        var volumes: [UInt32: Float] = [:]
        var mutes: [UInt32: Bool] = [:]
        for element in volumeElements {
            guard settable(kAudioDevicePropertyVolumeScalar, element), let value = volume(element),
                  value.isFinite, (0...1).contains(value) else { return nil }
            volumes[element] = value
        }
        for element in muteElements {
            guard settable(kAudioDevicePropertyMute, element), let value = mute(element) else { return nil }
            mutes[element] = value
        }
        return OutputDeviceState(uid: uid, deviceID: deviceID, volumes: volumes, mutes: mutes)
    }

    private func restoreDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) async -> OutputWriteResult {
        if restoreVolume {
            engineLog.notice("hardware volume state restore target=\(state.volume, privacy: .public) restoreMute=\(restoreMute, privacy: .public) uid=\(state.uid, privacy: .private)")
        }
        let result = await HardwareExecutor.run {
            Self.performRestore(state, restoreVolume: restoreVolume, restoreMute: restoreMute)
        }
        if restoreMute {
            if result == .applied && state.muted { protectedOutputUIDs.insert(state.uid) }
            else { protectedOutputUIDs.remove(state.uid) }
        }
        return result
    }

    private nonisolated static func performRestore(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) -> OutputWriteResult {
        if let ops = deviceOpsStore.get() {
            guard state.deviceID == 0, Set(state.volumes.keys) == [0], Set(state.mutes.keys) == [0] else { return .failed }
            if restoreVolume {
                let written = ops.setVolume(state.uid, state.volume)
                guard written == .applied else { return written }
            }
            return restoreMute ? ops.setMuted(state.uid, state.muted) : .applied
        }
        guard let current = resolvedDeviceState(uid: state.uid), current.deviceID == state.deviceID else { return .failed }
        return writeDeviceState(state, current: current, restoreVolume: restoreVolume, restoreMute: restoreMute,
            volume: { element, value in
                confirmedVolume(uid: state.uid, device: state.deviceID, element: element, value: value)
            },
            mute: { element, value in
                confirmedMute(uid: state.uid, device: state.deviceID, element: element, muted: value)
            })
    }

    /// Validates the complete saved shape before touching any element; volume failure never unmutes.
    nonisolated static func writeDeviceState(
        _ state: OutputDeviceState, current: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool,
        volume: (UInt32, Float) -> Bool, mute: (UInt32, Bool) -> Bool
    ) -> OutputWriteResult {
        guard state.uid == current.uid, state.deviceID == current.deviceID,
              !state.volumes.isEmpty, !state.mutes.isEmpty,
              Set(state.volumes.keys) == Set(current.volumes.keys), Set(state.mutes.keys) == Set(current.mutes.keys),
              state.volumes.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .failed }
        if restoreVolume {
            for element in state.volumes.keys.sorted() {
                guard volume(element, state.volumes[element]!) else { return .failed }
            }
        }
        if restoreMute {
            for element in state.mutes.keys.sorted() {
                guard mute(element, state.mutes[element]!) else {
                    // A partial release is not a restored device; re-protect every element and report failure.
                    for protectedElement in state.mutes.keys.sorted() { _ = mute(protectedElement, true) }
                    return .failed
                }
            }
        }
        return .applied
    }

    private static func deviceSampleRate(uid: String) -> Double? {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return nil }
        return CA.float64(dev, CA.address(kAudioDevicePropertyNominalSampleRate))
    }

    /// Synchronous, actor-free device-volume read (mirror of `setDeviceVolume`).
    public nonisolated static func deviceVolume(uid: String) -> Float? {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return nil }
        let main = CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        if let v = CA.float32(dev, main) { return v }
        // Some devices expose no main element — average the L/R channels.
        let l = CA.float32(dev, CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1))
        let r = CA.float32(dev, CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 2))
        if let l, let r { return (l + r) / 2 }
        return l ?? r
    }

    public func setOutputVolume(uid: String, _ volume: Float) async {
        if let intended = recoveryOutputIntent[uid], volume.isFinite {
            recoveryOutputIntent[uid]?.volumes = intended.volumes.mapValues { _ in max(0, min(1, volume)) }
        }
        await HardwareExecutor.run { Self.setDeviceVolume(uid: uid, volume) }
    }

    /// Synchronous, actor-free device-volume write. Safe to call from app
    /// termination (which can't await the actor). Completion is confirmed on a
    /// separate listener queue because HAL may apply the write asynchronously.
    public nonisolated static func setDeviceVolume(uid: String, _ volume: Float) {
        _ = setDeviceVolumeChecked(uid: uid, volume)
    }

    public func outputMuted(uid: String) async -> Bool {
        await outputMuteState(uid: uid) ?? false
    }

    /// nil when the device is absent or its mute controls cannot be read.
    public func outputMuteState(uid: String) async -> Bool? {
        if let intent = recoveryOutputIntent[uid] { return intent.muted }
        return await HardwareExecutor.run { Self.resolvedDeviceMuted(uid: uid) }
    }

    private nonisolated static func deviceMuted(uid: String) -> Bool? {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return nil }
        let main = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var muteAddress = main
        let hasMain = AudioObjectHasProperty(dev, &muteAddress)
        let channels = hasMain ? 0 : (outputChannelCount(device: dev) ?? 0)
        return muteState(
            main: hasMain ? CA.uint32Value(dev, main) : nil, hasMain: hasMain,
            channels: channels > 0 ? (1...channels).map { channel in
                CA.uint32Value(dev, CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(channel)))
            } : [])
    }

    /// Unreadable elements yield nil rather than "unmuted".
    nonisolated static func muteState(main: UInt32?, hasMain: Bool, channels: [UInt32?]) -> Bool? {
        if hasMain { return main.map { $0 == 1 } }
        guard !channels.isEmpty else { return nil }
        var muted = true
        for channel in channels {
            guard let channel else { return nil }
            muted = muted && channel == 1
        }
        return muted
    }

    /// Synchronous, actor-free mute write (mirror of `setDeviceVolume`). Safe from
    /// app termination. Used to silence the device across an aggregate/tap teardown
    /// or setup, during which CoreAudio briefly resets the device volume to 100%.
    public nonisolated static func setDeviceMuted(uid: String, _ muted: Bool) {
        _ = setDeviceMutedChecked(uid: uid, muted)
    }

    public func setOutputMuted(uid: String, _ muted: Bool) async {
        if let intended = recoveryOutputIntent[uid] {
            recoveryOutputIntent[uid]?.mutes = intended.mutes.mapValues { _ in muted }
        }
        guard muted || outputReleaseReady else { return }
        await HardwareExecutor.run { Self.setDeviceMuted(uid: uid, muted) }
    }

    public func setOutputMutedChecked(uid: String, _ muted: Bool) async -> OutputWriteResult {
        if !muted && !outputReleaseReady {
            if let intended = recoveryOutputIntent[uid] {
                recoveryOutputIntent[uid]?.mutes = intended.mutes.mapValues { _ in false }
            }
            return .failed
        }
        return await writeOutputMute(uid: uid, muted)
    }

    private func writeOutputMute(uid: String, _ muted: Bool) async -> OutputWriteResult {
        let result = await HardwareExecutor.run { Self.resolvedSetDeviceMuted(uid: uid, muted) }
        if muted && result == .applied { protectedOutputUIDs.insert(uid) }
        else { protectedOutputUIDs.remove(uid) }
        return result
    }

    public func acknowledgeOutputRestore(uids: Set<String>) async {
        for uid in uids { recoveryOutputIntent[uid] = nil }
    }

    public func setRouterRecoverySuspended(_ suspended: Bool) async {
        routerRecoverySuspended = suspended
        if suspended { return }
        let pending = suspendedRecoveries
        suspendedRecoveries.removeAll()
        for (reason, attempt) in pending {
            await retryAfterRearm(reason: reason, signature: attempt.signature,
                                  generation: attempt.generation, resetSourceIDs: attempt.sourceIDs)
        }
    }

    public func setOutputVolumeChecked(uid: String, _ volume: Float) async -> OutputWriteResult {
        await HardwareExecutor.run { Self.resolvedSetDeviceVolume(uid: uid, volume) }
    }

    public nonisolated static func setDeviceVolumeChecked(uid: String, _ volume: Float) -> OutputWriteResult {
        guard volume.isFinite else { return .failed }
        engineLog.notice("hardware volume direct target=\(volume, privacy: .public) uid=\(uid, privacy: .private)")
        return checkedDeviceWrite(uid: uid, selector: kAudioDevicePropertyVolumeScalar) { device, address in
            confirmedVolume(uid: uid, device: device, element: address.mElement, value: max(0, min(1, volume)))
        }
    }

    public nonisolated static func setDeviceMutedChecked(uid: String, _ muted: Bool) -> OutputWriteResult {
        checkedDeviceWrite(uid: uid, selector: kAudioDevicePropertyMute, reprotect: { device, address in
            if !muted { _ = confirmedMute(uid: uid, device: device, element: address.mElement, muted: true) }
        }) { device, address in
            confirmedMute(uid: uid, device: device, element: address.mElement, muted: muted)
        }
    }

    private nonisolated static func confirmedVolume(
        uid: String, device: AudioObjectID, element: UInt32, value: Float
    ) -> Bool {
        let address = CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        return CA.hardwareWriteState.perform(uid: uid, device: device, protectingMute: false, onFailure: {
            _ = checkedDeviceWrite(uid: uid, selector: kAudioDevicePropertyMute, expectedDevice: device) { device, address in
                confirmedMute(uid: uid, device: device, element: address.mElement, muted: true)
            }
        }) { forceWrite, accepted in
            CA.confirmedWrite(device, address,
                isCurrent: { ProcessEnumerator.deviceID(forUID: uid) == device },
                write: {
                    let result = CA.setFloat32(device, address, value)
                    if result { accepted() }
                    return result
                },
                matches: { CA.volumeMatches(CA.float32(device, address), target: value) },
                landed: { CA.volumeLanded(CA.float32(device, address), target: value) }, forceWrite: forceWrite)
        }
    }

    private nonisolated static func confirmedMute(uid: String, device: AudioObjectID, element: UInt32, muted: Bool) -> Bool {
        let address = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, element)
        return CA.hardwareWriteState.perform(uid: uid, device: device, protectingMute: muted) { forceWrite, accepted in
            CA.confirmedWrite(device, address,
                isCurrent: { ProcessEnumerator.deviceID(forUID: uid) == device },
                write: {
                    let result = CA.setUInt32(device, address, muted ? 1 : 0)
                    if result { accepted() }
                    return result
                },
                matches: { CA.uint32Value(device, address) == (muted ? 1 : 0) }, forceWrite: forceWrite)
        }
    }

    private nonisolated static func checkedDeviceWrite(
        uid: String, selector: AudioObjectPropertySelector,
        expectedDevice: AudioObjectID? = nil,
        reprotect: (AudioObjectID, AudioObjectPropertyAddress) -> Void = { _, _ in },
        write: (AudioObjectID, AudioObjectPropertyAddress) -> Bool
    ) -> OutputWriteResult {
        guard let device = ProcessEnumerator.deviceID(forUID: uid),
              expectedDevice == nil || expectedDevice == device else { return .failed }
        let main = CA.address(selector, kAudioDevicePropertyScopeOutput)
        if CA.isSettable(device, main) {
            if write(device, main) { return .applied }
            reprotect(device, main)
            return .failed
        }
        // Count every output channel; partial L/R protection is insufficient on multichannel devices.
        guard let channels = outputChannelCount(device: device), channels > 0 else { return .unsupported }
        let addresses = (1...channels).map { CA.address(selector, kAudioDevicePropertyScopeOutput, UInt32($0)) }
        guard addresses.allSatisfy({ CA.isSettable(device, $0) }) else { return .unsupported }
        var applied = true
        for address in addresses { if !write(device, address) { applied = false } }
        if applied && ProcessEnumerator.deviceID(forUID: uid) == device { return .applied }
        for address in addresses { reprotect(device, address) }
        return .failed
    }

    private nonisolated static func outputChannelCount(device: AudioObjectID) -> Int? {
        CA.outputBufferChannels(device)?.reduce(0, +)
    }

    public nonisolated func playingBundleIDs() async -> Set<String> {
        let read = polling.playing
        return await Task.detached(priority: .utility) { read() }.value
    }

    public nonisolated func runningAudioApps() async -> [AudioApp] {
        await Task.detached(priority: .utility) {
            let selfBundle = Bundle.main.bundleIdentifier
            var seen = Set<String>()
            return NSWorkspace.shared.runningApplications
                .filter {
                    $0.activationPolicy == .regular
                    && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != selfBundle
                }
                .compactMap { app -> AudioApp? in
                    let bid = app.bundleIdentifier!
                    guard seen.insert(bid).inserted else { return nil }
                    return AudioApp(bundleID: bid, displayName: app.localizedName ?? Self.displayName(bid))
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }.value
    }

    public func stop() async {
        await stopRouter()
    }

    /// Keeps the first intended device state across failed attempts; a failed step never authorizes an unmute.
    @discardableResult
    private func performGuardedOutputRebuild(uids: Set<String>, unmute: Bool, _ rebuild: () async -> Bool) async -> Bool {
        guard !uids.isEmpty else { return false }
        for uid in uids where recoveryOutputIntent[uid] == nil {
            guard let state = await HardwareExecutor.run({ Self.resolvedDeviceState(uid: uid) }) else { return false }
            recoveryOutputIntent[uid] = state
        }
        for uid in uids {
            let muted = await writeOutputMute(uid: uid, true)
            guard muted == .applied else {
                bamLog("router recovery: output mute failed; keeping existing routing", level: .error)
                return false
            }
        }
        guard await rebuild() else { return false }
        // Restore every exact volume element before any unmute; retain intent on failure.
        for uid in uids {
            engineLog.notice("hardware volume recovery restore uid=\(uid, privacy: .private)")
            guard let intent = recoveryOutputIntent[uid] else { return false }
            let restored = await restoreDeviceState(intent, restoreVolume: true, restoreMute: false)
            guard restored == .applied else { return false }
        }
        for uid in uids {
            guard let intent = recoveryOutputIntent[uid] else { continue }
            if unmute && !intent.muted {
                let released = await restoreDeviceState(intent, restoreVolume: false, restoreMute: true)
                guard released == .applied else { return false }
            }
            recoveryOutputIntent[uid] = nil
        }
        return true
    }

    public func routerOutputUIDs(config: BamConfig) async -> Set<String> {
        resolvedRouterOutputUIDs(config: config)
    }

    private func resolvedRouterOutputUIDs(config: BamConfig) -> Set<String> {
        listeningOutputUIDs(selected: Self.resolveOutputUID(stored: config.hardwareOutputUID))
    }

    private func listeningOutputUIDs(selected: String?) -> Set<String> {
        if let recoveryTestHooks { return recoveryTestHooks.outputUIDs }
        let uids = Self.listeningOutputUIDs(selected: selected, bound: _boundOutputUID,
                                           pending: Set(recoveryOutputIntent.keys))
        return Set(uids.filter { ProcessEnumerator.deviceID(forUID: $0) != nil })
    }

    /// Capture identities participate in topology validation, never hardware
    /// protection unless that device is also a current/previous BAM output.
    nonisolated static func listeningOutputUIDs(selected: String?, bound: String?, pending: Set<String>) -> Set<String> {
        pending.union([selected, bound].compactMap { $0 })
    }

    struct DesiredTapSpec: Equatable, Sendable {
        let sourceID: String
        let captureUID: String
        let processIDs: [AudioObjectID]
        let excludesProcesses: Bool
        var structuralSignature: String {
            "\(excludesProcesses ? "rest" : "app"):\(captureUID):0"
        }
        var sig: String {
            structuralSignature + ":" + processIDs.map(String.init).joined(separator: ",")
        }
        func description() -> CATapDescription {
            let description = excludesProcesses
                ? CATapDescription(excludingProcesses: processIDs, deviceUID: captureUID, stream: 0)
                : CATapDescription(processes: processIDs, deviceUID: captureUID, stream: 0)
            description.muteBehavior = .mutedWhenTapped
            return description
        }
    }

    nonisolated static func desiredTapSpecs(config: BamConfig, processes: [AudioProcessInfo],
                                           captureUID: String, selfObjectID: AudioObjectID?) -> [DesiredTapSpec] {
        var specs: [DesiredTapSpec] = []
        var groupedIDs: [AudioObjectID] = []
        for source in config.sources where source.kind == .app {
            let ids = processes.filter { matchedTarget($0.bundleID, source.bundleIDs) != nil }.map(\.objectID).sorted()
            groupedIDs.append(contentsOf: ids)
            specs.append(DesiredTapSpec(sourceID: source.id, captureUID: captureUID, processIDs: ids, excludesProcesses: false))
        }
        if let rest = config.sources.first(where: { $0.kind == .rest }) {
            if let selfObjectID { groupedIDs.append(selfObjectID) }
            specs.append(DesiredTapSpec(sourceID: rest.id, captureUID: captureUID, processIDs: groupedIDs.sorted(), excludesProcesses: true))
        }
        return specs
    }

    /// nil means a structural edit; an empty list means no membership writes.
    nonisolated static func membershipUpdates(desired: [DesiredTapSpec],
                                              live: [String: DesiredTapSpec]) -> [DesiredTapSpec]? {
        guard Set(desired.map(\.sourceID)) == Set(live.keys), desired.allSatisfy({
            live[$0.sourceID]?.structuralSignature == $0.structuralSignature
        }) else { return nil }
        return desired.filter { live[$0.sourceID] != $0 }
    }

    public func canKeepCurrentRouter(config: BamConfig) async -> Bool {
        guard !routerMembershipUncertain, config == routerConfig, router != nil, routerHealthTask != nil,
              rearmTasks.isEmpty, suspendedRecoveries.isEmpty, recoveryOutputIntent.isEmpty,
              let baseline = routerHealthBaseline, baseline.generation == routerGeneration,
              let expectedRate = baseline.outputSampleRate,
              let currentRate = Self.deviceSampleRate(uid: baseline.outputUID),
              abs(expectedRate - currentRate) <= 1 else { return false }
        guard let output = Self.resolveOutputUID(stored: config.hardwareOutputUID), output == _boundOutputUID else { return false }
        guard let capture = Self.tapCaptureOutputUID() else { return false }
        let ids = Set([output, capture])
        guard ids == Set(appliedDeviceIDs.keys), ids.allSatisfy({ uid in
            guard let id = ProcessEnumerator.deviceID(forUID: uid), id == appliedDeviceIDs[uid] else { return false }
            return CA.uint32(id, CA.address(kAudioDevicePropertyDeviceIsAlive)) == 1
        }) else { return false }
        let processes = polling.processes()
        // PID translation can instantiate a HAL object. Preflight may only read the existing list.
        guard let selfObject = processes.first(where: { $0.pid == getpid() })?.objectID else { return false }
        let desired = Self.desiredTapSpecs(config: config, processes: processes,
                                          captureUID: capture, selfObjectID: selfObject)
        return Self.canKeepRouterTopology(
            desired: Dictionary(uniqueKeysWithValues: desired.map { ($0.sourceID, $0.sig) }),
            live: liveTaps.mapValues(\.spec.sig),
            currentDevices: Dictionary(uniqueKeysWithValues: ids.compactMap { uid in
                ProcessEnumerator.deviceID(forUID: uid).map { (uid, $0) }
            }), appliedDevices: appliedDeviceIDs,
            currentFormats: Dictionary(uniqueKeysWithValues: liveTaps.compactMap { id, entry in
                entry.tap.proc.currentFormat().map {
                    (id, SourceFormat(sampleRate: $0.mSampleRate, channels: Int($0.mChannelsPerFrame)))
                }
            }), appliedFormats: baseline.sourceFormats,
            generation: routerGeneration, healthyGeneration: healthyGeneration,
            observedAt: lastHealthyObservation)
    }

    nonisolated static func sameDeviceTopology(_ current: [String: AudioObjectID], _ applied: [String: AudioObjectID]) -> Bool {
        !current.isEmpty && current == applied
    }

    /// Authorizes no mutation only. Unknown/stale health is left to the health monitor.
    nonisolated static func canKeepRouterTopology(
        desired: [String: String], live: [String: String],
        currentDevices: [String: AudioObjectID], appliedDevices: [String: AudioObjectID],
        currentFormats: [String: SourceFormat], appliedFormats: [String: SourceFormat],
        generation: Int, healthyGeneration: Int?, observedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard (healthyGeneration == nil || generation == healthyGeneration),
              !desired.isEmpty, desired == live,
              sameDeviceTopology(currentDevices, appliedDevices),
              Set(currentFormats.keys) == Set(desired.keys),
              Set(currentFormats.keys) == Set(appliedFormats.keys) else { return false }
        return currentFormats.allSatisfy { id, current in
            guard let expected = appliedFormats[id] else { return false }
            return current.sampleRate.isFinite && current.sampleRate > 0 && current.channels > 0
                && abs(current.sampleRate - expected.sampleRate) <= 1 && current.channels == expected.channels
        }
    }

    /// Build the central router from a config: one capture tap per grouped
    /// source, all gathered with the selected output device into a single
    /// hardware-clocked aggregate that sums each tap × its gain to the output.
    /// Returns mix ids that could not be brought online (empty on success).
    public func startRouter(config: BamConfig) async -> RouterStatus {
        await acquireRouterGate()
        defer { releaseRouterGate() }
        return await startRouterLocked(config: config)
    }

    private enum TapPreparation: @unchecked Sendable {
        case ready(RouterAggregate.Tap)
        case updateFailed
        case createFailed
    }

    /// Runs off the actor: confirmed membership writes and tap creation both block on HAL.
    private nonisolated static func prepareTaps(
        _ plan: [(spec: DesiredTapSpec, cached: RouterAggregate.Tap?, update: Bool)]
    ) -> [TapPreparation] {
        plan.map { entry in
            if let cached = entry.cached {
                if entry.update, !cached.proc.update(description: entry.spec.description()) { return .updateFailed }
                return .ready(cached)
            }
            guard let proc = ProcessTap(description: entry.spec.description()) else { return .createFailed }
            return .ready(RouterAggregate.Tap(sourceID: entry.spec.sourceID, proc: proc))
        }
    }

    private struct AggregateBuildOutcome: @unchecked Sendable {
        let aggregate: RouterAggregate
        let started: Bool
        let failure: RouterAggregate.BuildFailure?
        /// Meaningful only when `started` is false: whether the failed build's handles were released.
        let closed: Bool
        let milliseconds: Double
    }

    /// Runs off the actor: aggregate creation and AudioDeviceStart block on HAL.
    private nonisolated static func buildAggregate(taps: [RouterAggregate.Tap], outputUID: String) -> AggregateBuildOutcome {
        let aggregate = RouterAggregate(taps: taps)
        var failure: RouterAggregate.BuildFailure?
        let buildStart = ProcessInfo.processInfo.systemUptime
        let started = aggregate.start(outputUID: outputUID, failure: &failure)
        let milliseconds = (ProcessInfo.processInfo.systemUptime - buildStart) * 1000
        return AggregateBuildOutcome(aggregate: aggregate, started: started, failure: failure,
                                     closed: started ? false : aggregate.close(), milliseconds: milliseconds)
    }

    private func startRouterLocked(config: BamConfig) async -> RouterStatus {
        let storedUID = config.hardwareOutputUID
        let outputUID = Self.resolveOutputUID(stored: storedUID)
        let requiredOutputs = listeningOutputUIDs(selected: outputUID)
        guard !requiredOutputs.isEmpty else {
            // A missing lookup is not proof that an existing renderer is gone; keep ownership until protected.
            return .offline(config, .noOutput)
        }
        guard requiredOutputs.isSubset(of: protectedOutputUIDs) else {
            return .offline(config, .buildFailed)
        }
        let signpostID = engineSignposter.makeSignpostID()
        let signpostState = engineSignposter.beginInterval("CoreAudioEngine.startRouter", id: signpostID)
        defer { engineSignposter.endInterval("CoreAudioEngine.startRouter", signpostState) }

        guard let outputUID else {
            bamLog("startRouter: no output device (no hardware dest, no default output) — all \(config.mixes.count) mixes offline", level: .error)
            guard await closeRouter() else { return .offline(config, .buildFailed) }
            _boundOutputUID = nil
            return .offline(config, .noOutput)
        }
        if let storedUID, storedUID != outputUID {
            engineLog.debug(
                "startRouter: stored output absent stored=\(storedUID, privacy: .private) rebound=\(outputUID, privacy: .private)"
            )
        }
        guard let captureUID = Self.tapCaptureOutputUID() else {
            guard await closeRouter() else { return .offline(config, .buildFailed) }
            return .offline(config, .noOutput)
        }
        let listeningUIDs = requiredOutputs.union([outputUID])
        guard listeningUIDs.isSubset(of: protectedOutputUIDs) else { return .offline(config, .buildFailed) }
        let muteStates = await HardwareExecutor.run { listeningUIDs.map { Self.resolvedDeviceMuted(uid: $0) } }
        guard muteStates.allSatisfy({ $0 == true }) else { return .offline(config, .buildFailed) }
        let currentDeviceIDs = Dictionary(uniqueKeysWithValues: Set([outputUID, captureUID]).compactMap { uid in
            ProcessEnumerator.deviceID(forUID: uid).map { (uid, $0) }
        })
        guard currentDeviceIDs.count == Set([outputUID, captureUID]).count else {
            return .offline(config, .noOutput)
        }
        if !appliedDeviceIDs.isEmpty && !Self.sameDeviceTopology(currentDeviceIDs, appliedDeviceIDs) {
            // A stable UID can name a new HAL object after reconnect.
            routerGeneration += 1
            guard await closeRouter() else { return .offline(config, .buildFailed) }
            if currentDeviceIDs[captureUID] != appliedDeviceIDs[captureUID] { liveTaps.removeAll() }
        }
        if captureUID != outputUID {
            engineLog.debug(
                "startRouter: capture/render split capture=\(captureUID, privacy: .private) render=\(outputUID, privacy: .private)"
            )
        }

        let allProcs = polling.processes()
        guard let selfObjectID = ProcessEnumerator.processObject(forPID: getpid()) else {
            return .offline(config, .buildFailed)
        }
        let desired = Self.desiredTapSpecs(config: config, processes: allProcs, captureUID: captureUID,
                                          selfObjectID: selfObjectID)
        let generation = routerGeneration

        if let live = router, routerTapSig != nil,
           let updates = Self.membershipUpdates(desired: desired, live: liveTaps.mapValues(\.spec)) {
            let pending = routerMembershipUncertain ? desired : updates
            routerMembershipUncertain = true
            var plan: [(spec: DesiredTapSpec, cached: RouterAggregate.Tap?, update: Bool)] = []
            for spec in pending {
                guard let cached = liveTaps[spec.sourceID] else { return .offline(config, .buildFailed) }
                plan.append((spec, cached.tap, true))
            }
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepareTaps(plan) }.value
            guard generation == routerGeneration, router === live else { return .offline(config, .buildFailed) }
            for (entry, outcome) in zip(plan, prepared) {
                guard case .ready(let tap) = outcome else { return .offline(config, .buildFailed) }
                liveTaps[entry.spec.sourceID] = (entry.spec, tap)
            }
            applyRouterGains(config, to: live)
            let observation = await Task.detached(priority: .userInitiated) { await live.observeReadiness() }.value
            guard observation.accepted, generation == routerGeneration, router === live else { return .offline(config, .buildFailed) }
            routerMembershipUncertain = false
            routerConfig = config
            publishMeters()
            return .ok
        }

        // Reuse compatible taps; never replace a tap just because its process list changed.
        var plan: [(spec: DesiredTapSpec, cached: RouterAggregate.Tap?, update: Bool)] = []
        for d in desired {
            if let cached = liveTaps[d.sourceID], cached.spec.structuralSignature == d.structuralSignature {
                let update = cached.spec != d || routerMembershipUncertain
                if update { routerMembershipUncertain = true }
                plan.append((d, cached.tap, update))
            } else {
                plan.append((d, nil, false))
            }
        }
        let prepared = await Task.detached(priority: .userInitiated) { Self.prepareTaps(plan) }.value
        guard generation == routerGeneration else { return .offline(config, .buildFailed) }
        var newLive: [String: (spec: DesiredTapSpec, tap: RouterAggregate.Tap)] = [:]
        var orderedTaps: [RouterAggregate.Tap] = []
        var failedTapSourceIDs = Set<String>()
        for (entry, outcome) in zip(plan, prepared) {
            switch outcome {
            case .ready(let tap):
                if entry.update { liveTaps[entry.spec.sourceID] = (entry.spec, tap) }
                newLive[entry.spec.sourceID] = (entry.spec, tap)
                orderedTaps.append(tap)
            case .updateFailed:
                return .offline(config, .buildFailed)
            case .createFailed:
                failedTapSourceIDs.insert(entry.spec.sourceID)
            }
        }
        if !failedTapSourceIDs.isEmpty {
            let failedMixIDs = Self.mixIDs(referencing: failedTapSourceIDs, in: config)
            bamLog("startRouter: process tap creation failed for sources \(failedTapSourceIDs.sorted().joined(separator: ",")); likely audio-capture permission not yet granted; \(failedMixIDs.count) mixes offline", level: .error)
            return RouterStatus(failedMixIDs: failedMixIDs, cause: .permissionPending)
        }
        routerConfig = config

        // No configured capture sources. Configured but idle apps keep slots.
        guard !orderedTaps.isEmpty else {
            lastHealthyObservation = nil
            healthyGeneration = nil
            routerHealthTask?.cancel()
            routerHealthTask = nil
            routerHealthBaseline = nil
            guard await closeRouter() else { return .offline(config, .buildFailed) }
            liveTaps = newLive
            routerMembershipUncertain = false
            _boundOutputUID = outputUID
            publishMeters()
            return RouterStatus(cause: .noSourcesRunning)
        }

        let aggSig = outputUID + "|" + orderedTaps.map(\.proc.uuid).joined(separator: ",")
        if let live = router, routerTapSig == aggSig || pendingRouterTapSig == aggSig {
            // Same taps and output: refold gains only; a pending aggregate just re-checks readiness.
            applyRouterGains(config, to: live)
            if pendingRouterTapSig != nil {
                let promoted = await checkPendingRouterReadiness()
                return promoted ? .ok : .offline(config, .buildFailed)
            }
            publishMeters()
            return .ok
        }

        // Structural change under confirmed hardware mute: close first (frees the fixed UID), then build.
        lastHealthyObservation = nil
        healthyGeneration = nil
        routerGeneration += 1
        let buildGeneration = routerGeneration
        routerHealthTask?.cancel()
        routerHealthTask = nil
        routerHealthBaseline = nil
        guard await closeRouter() else { return .offline(config, .buildFailed) }
        liveTaps = newLive
        diagnosticsGeneration = buildGeneration
        let aggregateSignpostID = engineSignposter.makeSignpostID()
        let aggregateSignpostState = engineSignposter.beginInterval("CoreAudioEngine.rebuildAggregate", id: aggregateSignpostID)
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.buildAggregate(taps: orderedTaps, outputUID: outputUID)
        }.value
        engineSignposter.endInterval("CoreAudioEngine.rebuildAggregate", aggregateSignpostState)
        recordAggregateBuild(success: outcome.started, milliseconds: outcome.milliseconds)
        guard buildGeneration == routerGeneration else {
            let aggregate = outcome.aggregate
            if outcome.started, !(await Task.detached { aggregate.close() }.value) {
                bamLog("startRouter: superseded aggregate could not be closed", level: .error)
            }
            return .offline(config, .buildFailed)
        }
        guard outcome.started else {
            bamLog("startRouter: aggregate build failed (\(orderedTaps.count) taps, output \(outputUID), failure \(String(describing: outcome.failure))) — \(config.mixes.count) mixes offline", level: .error)
            if var snapshot = outcome.aggregate.audioDiagnostics() {
                snapshot.generation = diagnosticsGeneration
                lastAudioDiagnostics = snapshot
            }
            // A failed close retains the partially built router for the next protected retry.
            router = outcome.closed ? nil : outcome.aggregate
            routerTapSig = nil
            return .offline(config, .buildFailed)
        }
        let agg = outcome.aggregate
        router = agg
        applyRouterGains(routerConfig ?? config, to: agg)
        trackStartedRouter(signature: aggSig, outputUID: outputUID, deviceIDs: currentDeviceIDs)
        routerHealthBaseline = RouterHealthBaseline(
            generation: routerGeneration,
            outputUID: outputUID,
            outputSampleRate: Self.deviceSampleRate(uid: outputUID),
            sourceFormats: Dictionary(uniqueKeysWithValues: orderedTaps.map {
                ($0.sourceID, SourceFormat(
                    sampleRate: $0.proc.format.mSampleRate,
                    channels: Int($0.proc.format.mChannelsPerFrame)
                ))
            })
        )
        let promoted = await checkPendingRouterReadiness()
        return promoted ? .ok : .offline(config, .buildFailed)
    }

    /// Track the actual renderer even while the caller keeps it hardware-muted.
    func trackStartedRouter(signature: String, outputUID: String, deviceIDs: [String: AudioObjectID]) {
        routerTapSig = nil
        pendingRouterTapSig = signature
        _boundOutputUID = outputUID
        appliedDeviceIDs = deviceIDs
        publishMeters()
    }

    private func checkPendingRouterReadiness() async -> Bool {
        guard let agg = router, let signature = pendingRouterTapSig else { return false }
        let generation = routerGeneration
        let observation = await Task.detached(priority: .userInitiated) { await agg.observeReadiness() }.value
        guard generation == routerGeneration, router === agg, pendingRouterTapSig == signature else { return false }
        return await completeRouterStartup(formatsBefore: observation.formatsBefore, ready: observation.ready,
                                           formatsAfter: observation.formatsAfter)
    }

    /// Boolean observation boundary lets tests exercise pending ownership without HAL.
    func completeRouterStartup(formatsBefore: Bool, ready: Bool, formatsAfter: Bool) async -> Bool {
        guard let agg = router, let signature = pendingRouterTapSig else { return false }
        guard formatsBefore, ready, formatsAfter else {
            engineLog.error("router readiness rejected formatsBefore=\(formatsBefore, privacy: .public) ready=\(ready, privacy: .public) formatsAfter=\(formatsAfter, privacy: .public) \(agg.startupDiagnostics, privacy: .public)")
            // A slow first callback keeps its started resources; incompatible formats still require teardown.
            if !formatsBefore || !formatsAfter { _ = await closeRouter() }
            return false
        }
        pendingRouterTapSig = nil
        routerTapSig = signature
        routerMembershipUncertain = false
        publishMeters()
        startRouterHealthMonitor(signature: signature)
        engineLog.notice("startRouter: aggregate live taps=\(self.liveTaps.count, privacy: .public) output=\(self._boundOutputUID ?? "unknown", privacy: .private)")
        emitRouterRecoveryEvent(.recovered)
        return true
    }

    private func startRouterHealthMonitor(signature: String) {
        for task in rearmTasks.values { task.cancel() }
        rearmTasks.removeAll()
        routerHealthTask?.cancel()
        let generation = routerGeneration
        routerHealthTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            var state = RouterHealthState()
            while !Task.isCancelled {
                guard let self else { break }
                let shouldContinue = await self.checkRouterHealth(
                    signature: signature,
                    generation: generation,
                    state: &state
                )
                if !shouldContinue { break }
                try? await Task.sleep(for: .seconds(state.healthyStreak >= 5 ? 1 : 2))
            }
        }
    }

    private func checkRouterHealth(
        signature: String,
        generation: Int,
        state: inout RouterHealthState
    ) async -> Bool {
        guard !Task.isCancelled, generation == routerGeneration,
              routerTapSig == signature, router != nil, routerConfig != nil else { return false }
        if routerRecoverySuspended { return true }
        let tapIDs = liveTaps.mapValues { $0.tap.proc.tapID }
        let outputUID = routerHealthBaseline?.outputUID
        let readProcesses = polling.processes
        let scan = Task.detached(priority: .utility) { () -> ([AudioProcessInfo], [String: SourceFormat], Double?) in
            let processes = readProcesses()
            var formats: [String: SourceFormat] = [:]
            for (id, tapID) in tapIDs where !Task.isCancelled {
                if let format = ProcessTap.readFormat(tapID) {
                    formats[id] = SourceFormat(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
                }
            }
            let rate = !Task.isCancelled ? outputUID.flatMap { Self.deviceSampleRate(uid: $0) } : nil
            return (processes, formats, rate)
        }
        let observation = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
        // Device queries may outlive a switch/stop; their result never applies to another generation.
        guard !Task.isCancelled, generation == routerGeneration,
              routerTapSig == signature, let router, let config = routerConfig else { return false }
        if routerRecoverySuspended { return true }
        let h = router.healthSnapshot()
        let sourceHealth = router.sourceHealthSnapshots().map { snapshot in
            var current = snapshot
            if let format = observation.1[snapshot.sourceID] {
                current.sampleRate = format.sampleRate
                current.channels = format.channels
            }
            return current
        }
        let sourceHealthByID = Dictionary(uniqueKeysWithValues: sourceHealth.map { ($0.sourceID, $0) })
        let processSnapshot = observation.0
        let expectedSourceIDs = Self.expectedAudibleSourceIDs(config: config, processes: processSnapshot,
                                                               selfBundle: Bundle.main.bundleIdentifier)
        state.retainExpectedSources(expectedSourceIDs)

        if h.fires == state.lastFires || !h.hasAdvancedIO {
            state.staleSamples += 1
        } else {
            state.staleSamples = 0
        }
        state.lastFires = h.fires

        if !h.hasExpectedInput {
            state.noInputSamples += 1
        } else {
            state.noInputSamples = 0
        }
        state.recordLimiterFailures(h.limiterFailures)

        if Self.aggregateRecoveryRequired(snapshot: h, state: state) {
            bamLog("router health failed: fires=\(h.fires) inBufs=\(h.inputBuffers) inCh=\(h.inputChannels) inFrames=\(h.inputFrames) outBufs=\(h.outputBuffers) outCh=\(h.outputChannels) outFrames=\(h.outputFrames) limiterFailures=\(h.limiterFailures) rateMismatches=\(h.sampleRateMismatches) frameDivergence=\(h.frameDivergenceCallbacks); rebuilding aggregate", level: .error)
            scheduleRecovery(signature: signature, reason: .aggregateStalled)
            return false
        }

        if outputFormatDrifted(current: observation.2) {
            state.outputFormatDriftSamples += 1
        } else {
            state.outputFormatDriftSamples = 0
        }
        if state.outputFormatDriftSamples >= 2 {
            bamLog("router health failed: output format/sample-rate changed; rebuilding aggregate", level: .error)
            scheduleRecovery(signature: signature, reason: .outputFormatDrift)
            return false
        }

        let driftedSourceIDs = sourceFormatDriftedIDs(sourceHealth)
        for sourceID in driftedSourceIDs {
            state.sourceFormatDriftSamples[sourceID, default: 0] += 1
        }
        for sourceID in Array(state.sourceFormatDriftSamples.keys) where !driftedSourceIDs.contains(sourceID) {
            state.sourceFormatDriftSamples[sourceID] = 0
        }
        let formatBad = state.sourceFormatDriftSamples
            .filter { $0.value >= 2 }
            .map(\.key)
        if !formatBad.isEmpty {
            bamLog("router health failed: tap format changed for \(formatBad.sorted().joined(separator: ",")); dropping tap cache and rebuilding aggregate", level: .error)
            scheduleRecovery(signature: signature, reason: .tapFormatDrift, resetSourceIDs: Set(formatBad))
            return false
        }

        var sourceFrameBad: [String] = []
        for sourceID in expectedSourceIDs {
            guard let s = sourceHealthByID[sourceID] else { continue }
            let previousFrames = state.lastSourceFrames[sourceID]
            state.lastSourceFrames[sourceID] = s.inputFrames

            if let previousFrames, s.inputFrames <= previousFrames {
                state.sourceStaleSamples[sourceID, default: 0] += 1
            } else {
                state.sourceStaleSamples[sourceID] = 0
            }
            if state.sourceStaleSamples[sourceID, default: 0] >= 3 {
                sourceFrameBad.append(sourceID)
            }
        }

        if !sourceFrameBad.isEmpty {
            bamLog("router health failed: source tap stopped advancing for \(sourceFrameBad.sorted().joined(separator: ",")); dropping tap cache and rebuilding aggregate", level: .error)
            scheduleRecovery(signature: signature, reason: .sourceTapStalled, resetSourceIDs: Set(sourceFrameBad))
            return false
        }

        let healthy = state.staleSamples == 0
            && state.noInputSamples == 0
            && state.outputFormatDriftSamples == 0
            && state.limiterFailureSamples == 0
            && state.sourceStaleSamples.values.allSatisfy { $0 == 0 }
            && driftedSourceIDs.isEmpty
            && Set(sourceHealthByID.keys) == Set(routerHealthBaseline?.sourceFormats.keys.map { $0 } ?? [])
        lastHealthyObservation = healthy ? ContinuousClock.now : nil
        healthyGeneration = healthy ? generation : nil
        if healthy {
            if state.healthyStreak < 5 {
                state.healthyStreak += 1
                if state.healthyStreak == 5 {
                    routerRecoveryPolicy.reset()
                    bamLog("router recovery budget reset after sustained health")
                }
            }
        } else {
            state.healthyStreak = 0
        }
        return true
    }

    /// Recovery runs outside the health task so cancelling that task cannot abort the protected rebuild.
    private func scheduleRecovery(signature: String, reason: RecoveryReason, resetSourceIDs: Set<String> = []) {
        Task { [weak self] in
            await self?.recoverRouterAfterHealthFailure(signature: signature, reason: reason, resetSourceIDs: resetSourceIDs)
        }
    }

    /// Native render errors can silence output while callbacks and input continue advancing.
    nonisolated static func aggregateRecoveryRequired(snapshot: RouterAggregate.HealthSnapshot,
                                                       state: RouterHealthState) -> Bool {
        state.limiterFailureSamples >= 2 || state.staleSamples >= 3 || state.noInputSamples >= 3
    }

    private func outputFormatDrifted(current: Double?) -> Bool {
        guard let baseline = routerHealthBaseline,
              let expected = baseline.outputSampleRate,
              let current
        else { return false }
        return abs(current - expected) > 1
    }

    private func sourceFormatDriftedIDs(_ sources: [RouterAggregate.SourceHealthSnapshot]) -> Set<String> {
        guard let baseline = routerHealthBaseline else { return [] }
        return Set(sources.compactMap { source in
            guard let expected = baseline.sourceFormats[source.sourceID] else { return nil }
            let sampleRateChanged = abs(source.sampleRate - expected.sampleRate) > 1
            let channelsChanged = source.channels != expected.channels
            return sampleRateChanged || channelsChanged ? source.sourceID : nil
        })
    }

    static func mixIDs(referencing sourceIDs: Set<String>, in config: BamConfig) -> [String] {
        guard !sourceIDs.isEmpty else { return [] }
        return config.mixes.compactMap { mix in
            mix.sends.contains { sourceIDs.contains($0.source) } ? mix.id : nil
        }
    }

    nonisolated static func expectedAudibleSourceIDs(
        config: BamConfig,
        processes: [AudioProcessInfo],
        selfBundle: String?
    ) -> Set<String> {
        let groupedTargets = config.sources
            .filter { $0.kind == .app }
            .flatMap(\.bundleIDs)
        let gains = foldedGains(config)

        var expected = Set<String>()
        for source in config.sources {
            guard let gain = gains[source.id], max(gain.left, gain.right) > healthGainFloor else { continue }
            switch source.kind {
            case .app:
                if processes.contains(where: { proc in
                    proc.isRunningOutput && matchedTarget(proc.bundleID, source.bundleIDs) != nil
                }) {
                    expected.insert(source.id)
                }
            case .rest:
                if processes.contains(where: { proc in
                    proc.isRunningOutput
                        && proc.bundleID != selfBundle
                        && matchedTarget(proc.bundleID, groupedTargets) == nil
                }) {
                    expected.insert(source.id)
                }
            }
        }
        return expected
    }

    private func recoverRouterAfterHealthFailure(
        signature: String,
        reason: RecoveryReason,
        resetSourceIDs: Set<String> = [],
        allowOffline: Bool = false
    ) async {
        await acquireRouterGate()
        defer { releaseRouterGate() }
        guard routerTapSig == signature || (allowOffline && routerTapSig == nil), let config = routerConfig else { return }
        lastHealthyObservation = nil
        let event = routerRecoveryPolicy.recordAttempt(reason: reason)
        emitRouterRecoveryEvent(event)
        routerHealthTask?.cancel()
        routerHealthTask = nil
        let restored = await performGuardedOutputRebuild(uids: resolvedRouterOutputUIDs(config: config), unmute: !config.masterMuted) {
            if allowOffline, pendingRouterTapSig != nil {
                guard case .attempting = event else { return false }
                if let hooks = recoveryTestHooks { return !hooks.rebuild().isFailure }
                return !(await startRouterLocked(config: config)).isFailure
            }
            routerGeneration += 1
            recoveryTestHooks?.willTearDown()
            guard await closeRouter() else { return false }
            for sourceID in resetSourceIDs { liveTaps[sourceID] = nil }
            routerHealthBaseline = nil
            guard case .attempting = event else { return false }
            bamLog("router recovery: \(reason.rawValue)")
            if let hooks = recoveryTestHooks { return !hooks.rebuild().isFailure }
            return !(await startRouterLocked(config: config)).isFailure
        }
        if !restored {
            scheduleRecoveryRearm(reason: reason, signature: routerTapSig ?? signature, resetSourceIDs: resetSourceIDs)
        }
    }

    private func scheduleRecoveryRearm(reason: RecoveryReason, signature: String, resetSourceIDs: Set<String>) {
        rearmTasks[reason]?.cancel()
        let generation = routerGeneration
        let delay = max(0, routerRecoveryPolicy.pausedUntil(for: reason)?.timeIntervalSinceNow ?? 2)
        rearmTasks[reason] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.retryAfterRearm(reason: reason, signature: signature, generation: generation, resetSourceIDs: resetSourceIDs)
        }
    }

    private func retryAfterRearm(reason: RecoveryReason, signature: String, generation: Int? = nil, resetSourceIDs: Set<String> = []) async {
        guard !Task.isCancelled else { return }
        rearmTasks[reason] = nil
        guard generation == nil || generation == routerGeneration else { return }
        if routerRecoverySuspended {
            suspendedRecoveries[reason] = (signature, generation, resetSourceIDs)
            return
        }
        // Only the generation that paused may retry, and only while it is still offline.
        guard routerTapSig == nil || routerTapSig == signature, routerConfig != nil else { return }
        bamLog("router recovery re-arm fired: \(reason.rawValue)")
        await recoverRouterAfterHealthFailure(signature: signature, reason: reason, resetSourceIDs: resetSourceIDs, allowOffline: true)
    }

    // MARK: router recovery events

    private var routerEventListeners: [UUID: [any ChangeListenerToken]] = [:]
    private var routerRecoveryEventSinks: [UUID: AsyncStream<RouterRecoveryEvent>.Continuation] = [:]

    /// Emits (debounced) whenever the audio process list, the output-device list or the default output changes.
    public func routerEvents() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.addRouterEventListeners(id: id, continuation: continuation)
            continuation.onTermination = { _ in
                Task { await self.removeRouterEventListeners(id: id) }
            }
        }
    }

    private func addRouterEventListeners(
        id: UUID,
        continuation: AsyncStream<Void>.Continuation
    ) {
        let intervals = Self.changeListenerFactoryStore.intervals
        let cache = processCache
        let debounce = DebouncedTrigger(delay: intervals.debounce) { continuation.yield(()) }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var tokens: [any ChangeListenerToken] = [
            Self.changeListenerFactoryStore.make(object: system, selector: kAudioHardwarePropertyProcessObjectList) {
                cache.invalidate()
                debounce.fire()
            },
            Self.changeListenerFactoryStore.make(object: system, selector: kAudioHardwarePropertyDevices) {
                debounce.fire()
            },
            // Default-output switches between two present devices change no device list.
            Self.changeListenerFactoryStore.make(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice) {
                debounce.fire()
            },
        ]
        if tokens.contains(where: { !$0.isActive }) {
            engineLog.error("router events: listener registration failed; polling instead")
            let poll = Task { [interval = intervals.poll] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    cache.invalidate()
                    continuation.yield(())
                }
            }
            tokens.append(AnyChangeListenerToken { poll.cancel() })
        }
        tokens.append(AnyChangeListenerToken { debounce.cancel() })
        routerEventListeners[id] = tokens
    }

    private func removeRouterEventListeners(id: UUID) {
        routerEventListeners[id] = nil
    }

    public func routerRecoveryEvents() -> AsyncStream<RouterRecoveryEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { self.addRouterRecoveryEventSink(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeRouterRecoveryEventSink(id: id) }
            }
        }
    }

    public func resetRouterRecovery() {
        for t in rearmTasks.values { t.cancel() }
        rearmTasks.removeAll()
        suspendedRecoveries.removeAll()
        routerRecoveryPolicy.reset()
        emitRouterRecoveryEvent(.recovered)
    }

    private func addRouterRecoveryEventSink(
        id: UUID,
        continuation: AsyncStream<RouterRecoveryEvent>.Continuation
    ) {
        routerRecoveryEventSinks[id] = continuation
    }

    private func removeRouterRecoveryEventSink(id: UUID) {
        routerRecoveryEventSinks[id] = nil
    }

    private func emitRouterRecoveryEvent(_ event: RouterRecoveryEvent) {
        for sink in routerRecoveryEventSinks.values {
            sink.yield(event)
        }
    }

    /// Folds each source's level · mute · solo-gate · device level · master · pan into L/R scalars.
    nonisolated static func foldedGains(_ config: BamConfig) -> [String: (left: Float, right: Float)] {
        let master = config.masterMuted ? 0 : Float(config.master)
        let solo = config.solo
        var gains: [String: (left: Float, right: Float)] = [:]
        for source in config.sources {
            var l: Float = 0, r: Float = 0
            for mix in config.mixes {
                guard let send = mix.sends.first(where: { $0.source == source.id }) else { continue }
                let gated = (send.muted || (solo != nil && solo != source.id))
                    ? 0 : Float(mix.level * send.level) * master
                let (pl, pr) = AudioBalance.gains(pan: Float(config.pans[source.id] ?? 0.5))
                l += gated * pl
                r += gated * pr
            }
            gains[source.id] = (l, r)
        }
        return gains
    }

    private func applyRouterGains(_ config: BamConfig, to target: RouterAggregate? = nil) {
        guard let router = target ?? self.router else { return }
        for (sourceID, gain) in Self.foldedGains(config) {
            router.setGain(sourceID: sourceID, l: gain.left, r: gain.right)
        }
    }

    private func publishMeters() {
        meterPublication.publish(config: routerConfig, router: routerTapSig != nil ? router : nil)
    }

    /// Live per-source + per-mix levels while the router runs; sampled without touching the actor.
    public func routerSnapshots() -> AsyncStream<RouterSnapshot> {
        routerSamplerTask?.cancel()
        let publication = meterPublication
        let (stream, continuation) = AsyncStream<RouterSnapshot>.makeStream()
        let task = Task.detached {
            while !Task.isCancelled {
                continuation.yield(publication.snapshot())
                try? await Task.sleep(for: .milliseconds(33))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        routerSamplerTask = task
        return stream
    }

    /// Recompute routing gains live (level/mute/solo/pan/master) without
    /// rebuilding the aggregate or its taps.
    public func updateRouterGains(config: BamConfig) {
        routerConfig = config
        applyRouterGains(config)
        publishMeters()
    }

    public func stopRouter() async {
        _ = await stopRouterChecked()
    }

    public func stopRouterChecked() async -> Bool {
        await acquireRouterGate()
        defer { releaseRouterGate() }
        return await stopRouterLocked()
    }

    /// Once close is attempted, this generation never takes the reuse path even if only some stages succeeded.
    private func closeRouter() async -> Bool {
        routerTapSig = nil
        pendingRouterTapSig = nil
        guard let current = router else { return true }
        publishMeters()
        let closed = await Task.detached(priority: .userInitiated) { current.close() }.value
        guard closed else { return false }
        if var snapshot = current.audioDiagnostics() {
            snapshot.generation = diagnosticsGeneration
            lastAudioDiagnostics = snapshot
        }
        if router === current { router = nil }
        return true
    }

    private func stopRouterLocked() async -> Bool {
        lastHealthyObservation = nil
        // Stopping destroys the aggregate too; leave protection restoration to the caller.
        if router != nil || !liveTaps.isEmpty {
            guard let config = routerConfig else { return false }
            let outputs = resolvedRouterOutputUIDs(config: config)
            guard !outputs.isEmpty else { return false }
            for uid in outputs {
                let muted = await writeOutputMute(uid: uid, true)
                guard muted == .applied else { return false }
            }
        }
        routerGeneration += 1
        routerHealthTask?.cancel()
        routerHealthTask = nil
        routerSamplerTask?.cancel()
        routerSamplerTask = nil
        for t in rearmTasks.values { t.cancel() }
        rearmTasks.removeAll()
        guard await closeRouter() else { return false }
        liveTaps.removeAll()
        routerMembershipUncertain = false
        routerConfig = nil
        routerTapSig = nil
        routerHealthBaseline = nil
        _boundOutputUID = nil
        appliedDeviceIDs.removeAll()
        publishMeters()
        return true
    }

    private static func displayName(_ bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// A process matches a group target if its bundle equals the target or is a
    /// helper of it (e.g. com.brave.Browser.helper matches com.brave.Browser).
    private nonisolated static func matchedTarget(_ procBundle: String, _ targets: [String]) -> String? {
        guard !procBundle.isEmpty else { return nil }
        return targets.first { procBundle == $0 || procBundle.hasPrefix($0 + ".") }
    }
}
