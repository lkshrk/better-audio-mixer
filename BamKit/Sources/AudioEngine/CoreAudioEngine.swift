import AppKit
import BamCore
import CoreAudio
import Foundation

public actor CoreAudioEngine: AudioEngineProtocol {
    typealias ChangeListenerFactory = @Sendable (
        AudioObjectID,
        AudioObjectPropertySelector,
        @escaping @Sendable () -> Void
    ) -> any ChangeListenerToken

    private final class ChangeListenerFactoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var override: ChangeListenerFactory?

        func set(_ factory: ChangeListenerFactory?) {
            lock.lock()
            override = factory
            lock.unlock()
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

    func performGuardedOutputRebuildForTests(uids: Set<String>, unmute: Bool, rebuild: () -> Bool) {
        performGuardedOutputRebuild(uids: uids, unmute: unmute, rebuild)
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

    private static func resolvedDeviceMuted(uid: String) -> Bool {
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
    func recoverRouterForTests(reason: RecoveryReason) {
        routerTapSig = "test-generation"
        recoverRouterAfterHealthFailure(signature: "test-generation", reason: reason)
    }
    func retryAfterRearmForTests(reason: RecoveryReason) {
        retryAfterRearm(reason: reason, signature: "test-generation")
    }
    func installRouterForTests(resources: sending RouterAggregate.IOResources) {
        router = RouterAggregate(taps: [], resources: resources)
    }
    func hasRouterForTests() -> Bool { router != nil }
    func checkRouterHealthForTests() async -> Bool {
        guard let signature = routerTapSig else { return false }
        var state = RouterHealthState()
        return await checkRouterHealth(signature: signature, generation: routerGeneration, state: &state)
    }
    func routerStartupStateForTests() -> (pending: String?, deviceIDs: [String: AudioObjectID], monitoring: Bool) {
        (pendingRouterTapSig, appliedDeviceIDs, routerHealthTask != nil)
    }

    /// The output UID the running aggregate is actually bound to, after live-list
    /// resolution. May differ from the stored config UID when a device re-enumerated;
    /// the view model reads this to persist the new UID.
    private var _boundOutputUID: String?

    // Router: one aggregate (all source taps + the selected output) summing
    // each tap × its gain in a single hardware-clocked IOProc.
    private var router: RouterAggregate?
    private var lastAudioDiagnostics: AudioDiagnostics?
    private var diagnosticsGeneration = 0
    private var buildDiagnostics = AudioDiagnostics()

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
    /// Configured source slots survive process exit/relaunch. Membership updates
    /// retain tap identity and the running renderer; hardware protection still
    /// covers the non-atomic transfer between source and remainder taps.
    private var liveTaps: [String: (spec: DesiredTapSpec, tap: RouterAggregate.Tap)] = [:]
    private var routerMembershipUncertain = false
    /// Signature of the aggregate currently live (output + ordered tap uuids).
    /// When the next desired signature matches, the aggregate is left running and
    /// only its gains are refolded — no rebuild, no offline flash.
    private var routerTapSig: String?
    /// HAL started successfully, but a fresh valid callback has not confirmed readiness.
    private var pendingRouterTapSig: String?
    private var lastHealthyObservation: ContinuousClock.Instant?
    private var routerGeneration = 0
    private var healthyGeneration: Int?
    private var appliedDeviceIDs: [String: AudioObjectID] = [:]

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

        mutating func retainExpectedSources(_ ids: Set<String>) {
            sourceStaleSamples = sourceStaleSamples.filter { ids.contains($0.key) }
            lastSourceFrames = lastSourceFrames.filter { ids.contains($0.key) }
        }
    }

    private static let healthGainFloor: Double = 0.0001

    typealias Polling = (playing: @Sendable () -> Set<String>, processes: @Sendable () -> [AudioProcessInfo])
    private nonisolated let polling: Polling

    public init() {
        polling = (ProcessEnumerator.playingBundleIDs, { ProcessEnumerator.allProcesses() })
    }

    init(polling: Polling) { self.polling = polling }

    public nonisolated func outputDevices() async -> [AudioDevice] {
        await Task.detached(priority: .utility) {
            ProcessEnumerator.systemOutputDevices().map {
                AudioDevice(uid: $0.uid, name: $0.name, transportType: $0.transportType)
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

    /// Capture follows macOS routing independently of BAM's listening output.
    /// An absent system output must not turn the listening device into a fallback.
    static func tapCaptureOutputUID(defaultOutputUID: String?) -> String? {
        defaultOutputUID
    }

    private static func tapCaptureOutputUID() -> String? {
        tapCaptureOutputUID(defaultOutputUID: ProcessEnumerator.defaultOutputDeviceUID())
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
        if let intended = recoveryOutputIntent[uid] { return intended.volume }
        let observed = await Task.detached(priority: .utility) { Self.resolvedDeviceVolume(uid: uid) }.value
        return recoveryOutputIntent[uid]?.volume ?? observed
    }

    public func outputDeviceState(uid: String) async -> OutputDeviceState? {
        recoveryOutputIntent[uid] ?? Self.resolvedDeviceState(uid: uid)
    }

    /// Synchronous snapshot for termination, before the caller protects physical output.
    public nonisolated static func deviceState(uid: String) -> OutputDeviceState? {
        resolvedDeviceState(uid: uid)
    }

    public func restoreOutputDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) async -> OutputWriteResult {
        if restoreMute, state.mutes.values.contains(false), !outputReleaseReady {
            engineLog.error("hardware release blocked: pending=\(self.pendingRouterTapSig != nil, privacy: .public) uncertainMembership=\(self.routerMembershipUncertain, privacy: .public)")
            // Preserve a valid user mute intent for engine-owned recovery, but
            // never release hardware while the renderer is still pending.
            if let intended = recoveryOutputIntent[state.uid], intended.deviceID == state.deviceID,
               Set(intended.mutes.keys) == Set(state.mutes.keys) {
                recoveryOutputIntent[state.uid]?.mutes = state.mutes
            }
            return .failed
        }
        let result = restoreDeviceState(state, restoreVolume: restoreVolume, restoreMute: restoreMute)
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
                var address = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, element)
                var value: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
                return value != 0
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

    private func restoreDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) -> OutputWriteResult {
        if restoreVolume {
            engineLog.notice("hardware volume state restore target=\(state.volume, privacy: .public) restoreMute=\(restoreMute, privacy: .public) uid=\(state.uid, privacy: .private)")
        }
        let result: OutputWriteResult
        if let ops = Self.deviceOpsStore.get() {
            guard state.deviceID == 0, Set(state.volumes.keys) == [0], Set(state.mutes.keys) == [0] else { return .failed }
            if restoreVolume {
                let written = ops.setVolume(state.uid, state.volume)
                guard written == .applied else { return written }
            }
            result = restoreMute ? ops.setMuted(state.uid, state.muted) : .applied
        } else {
            guard let current = Self.resolvedDeviceState(uid: state.uid), current.deviceID == state.deviceID else { return .failed }
            result = Self.writeDeviceState(state, current: current, restoreVolume: restoreVolume, restoreMute: restoreMute,
                volume: { element, value in
                    Self.confirmedVolume(uid: state.uid, device: state.deviceID, element: element, value: value)
                },
                mute: { element, value in
                    Self.confirmedMute(uid: state.uid, device: state.deviceID, element: element, muted: value)
                })
        }
        if restoreMute {
            if result == .applied && state.muted { protectedOutputUIDs.insert(state.uid) }
            else { protectedOutputUIDs.remove(state.uid) }
        }
        return result
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
                    // A partial release is not a restored device. Re-protect every
                    // element best-effort and report failure even if protection succeeds.
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

    public func setOutputVolume(uid: String, _ volume: Float) {
        Self.setDeviceVolume(uid: uid, volume)
        if let intended = recoveryOutputIntent[uid], volume.isFinite {
            recoveryOutputIntent[uid]?.volumes = intended.volumes.mapValues { _ in max(0, min(1, volume)) }
        }
    }

    /// Synchronous, actor-free device-volume write. Safe to call from app
    /// termination (which can't await the actor). Completion is confirmed on a
    /// separate listener queue because HAL may apply the write asynchronously.
    public nonisolated static func setDeviceVolume(uid: String, _ volume: Float) {
        _ = setDeviceVolumeChecked(uid: uid, volume)
    }

    public func outputMuted(uid: String) -> Bool {
        recoveryOutputIntent[uid]?.muted ?? Self.resolvedDeviceMuted(uid: uid)
    }

    private nonisolated static func deviceMuted(uid: String) -> Bool {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return false }
        let main = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var muteAddress = main
        if AudioObjectHasProperty(dev, &muteAddress) { return CA.uint32(dev, main) == 1 }
        guard let channels = outputChannelCount(device: dev), channels > 0 else { return false }
        return (1...channels).allSatisfy { channel in
            CA.uint32(dev, CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(channel))) == 1
        }
    }

    /// Synchronous, actor-free mute write (mirror of `setDeviceVolume`). Safe from
    /// app termination. Used to silence the device across an aggregate/tap teardown
    /// or setup, during which CoreAudio briefly resets the device volume to 100%.
    public nonisolated static func setDeviceMuted(uid: String, _ muted: Bool) {
        _ = setDeviceMutedChecked(uid: uid, muted)
    }

    public func setOutputMuted(uid: String, _ muted: Bool) {
        if let intended = recoveryOutputIntent[uid] {
            recoveryOutputIntent[uid]?.mutes = intended.mutes.mapValues { _ in muted }
        }
        guard muted || outputReleaseReady else { return }
        Self.setDeviceMuted(uid: uid, muted)
    }

    public func setOutputMutedChecked(uid: String, _ muted: Bool) async -> OutputWriteResult {
        if !muted && !outputReleaseReady {
            if let intended = recoveryOutputIntent[uid] {
                recoveryOutputIntent[uid]?.mutes = intended.mutes.mapValues { _ in false }
            }
            return .failed
        }
        return writeOutputMute(uid: uid, muted)
    }

    private func writeOutputMute(uid: String, _ muted: Bool) -> OutputWriteResult {
        let result = Self.resolvedSetDeviceMuted(uid: uid, muted)
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
            retryAfterRearm(reason: reason, signature: attempt.signature,
                            generation: attempt.generation, resetSourceIDs: attempt.sourceIDs)
        }
    }

    public func setOutputVolumeChecked(uid: String, _ volume: Float) async -> OutputWriteResult {
        Self.resolvedSetDeviceVolume(uid: uid, volume)
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
        var address = CA.address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
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

    public func stop() {
        stopRouter()
    }

    /// Keep the first intended device state across failed recovery attempts.
    /// A failed protection/rebuild/restore never authorizes an unmute.
    @discardableResult
    private func performGuardedOutputRebuild(uids: Set<String>, unmute: Bool, _ rebuild: () -> Bool) -> Bool {
        guard !uids.isEmpty else { return false }
        for uid in uids where recoveryOutputIntent[uid] == nil {
            guard let state = Self.resolvedDeviceState(uid: uid) else { return false }
            recoveryOutputIntent[uid] = state
        }
        for uid in uids {
            guard writeOutputMute(uid: uid, true) == .applied else {
                bamLog("router recovery: output mute failed; keeping existing routing", level: .error)
                return false
            }
        }
        guard rebuild() else { return false }
        // Restore every exact volume element before any unmute; retain intent on failure.
        for uid in uids {
            engineLog.notice("hardware volume recovery restore uid=\(uid, privacy: .private)")
            guard let intent = recoveryOutputIntent[uid],
                  restoreDeviceState(intent, restoreVolume: true, restoreMute: false) == .applied else { return false }
        }
        for uid in uids {
            guard let intent = recoveryOutputIntent[uid] else { continue }
            if unmute && !intent.muted {
                guard restoreDeviceState(intent, restoreVolume: false, restoreMute: true) == .applied else { return false }
            }
            recoveryOutputIntent[uid] = nil
        }
        return true
    }

    public func routerOutputUIDs(config: BamConfig) async -> Set<String> {
        resolvedRouterOutputUIDs(config: config)
    }

    private func resolvedRouterOutputUIDs(config: BamConfig) -> Set<String> {
        if let recoveryTestHooks { return recoveryTestHooks.outputUIDs }
        let stored = config.mixes.compactMap { mix -> String? in
            if case .hardware(let uid) = mix.dest { return uid }; return nil
        }.first
        let uids = Self.listeningOutputUIDs(selected: Self.resolveOutputUID(stored: stored),
                                           bound: _boundOutputUID, pending: Set(recoveryOutputIntent.keys))
        return Set(uids.filter { ProcessEnumerator.deviceID(forUID: $0) != nil })
    }

    /// Capture identities participate in topology validation, never hardware
    /// protection unless that device is also a current/previous BAM output.
    nonisolated static func listeningOutputUIDs(selected: String?, bound: String?, pending: Set<String>) -> Set<String> {
        pending.union([selected, bound].compactMap { $0 })
    }

    struct DesiredTapSpec: Equatable {
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
        let stored = config.mixes.compactMap { mix -> String? in
            if case .hardware(let uid) = mix.dest { return uid }; return nil
        }.first
        guard let output = Self.resolveOutputUID(stored: stored), output == _boundOutputUID else { return false }
        guard let capture = Self.tapCaptureOutputUID() else { return false }
        let ids = Set([output, capture])
        guard ids == Set(appliedDeviceIDs.keys), ids.allSatisfy({ uid in
            guard let id = ProcessEnumerator.deviceID(forUID: uid), id == appliedDeviceIDs[uid] else { return false }
            return CA.uint32(id, CA.address(kAudioDevicePropertyDeviceIsAlive)) == 1
        }) else { return false }
        let processes = ProcessEnumerator.allProcesses()
        // PID translation can instantiate a HAL object. Preflight may only read the existing list.
        guard let selfObject = processes.first(where: { $0.pid == getpid() })?.objectID else { return false }
        let desired = Self.desiredTapSpecs(config: config, processes: processes,
                                          captureUID: capture, selfObjectID: selfObject)
        // Startup/stale health is not evidence that an unchanged router needs mutation.
        // The generation-bound monitor independently observes stalls and owns guarded recovery.
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
    public func startRouter(config: BamConfig) -> RouterStatus {
        let requiredOutputs = resolvedRouterOutputUIDs(config: config)
        guard !requiredOutputs.isEmpty else {
            // A missing lookup is not proof that an existing renderer is gone.
            // Keep its ownership until a listening output can be protected.
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .noOutput)
        }
        guard requiredOutputs.isSubset(of: protectedOutputUIDs) else {
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
        }
        let signpostID = engineSignposter.makeSignpostID()
        let signpostState = engineSignposter.beginInterval("CoreAudioEngine.startRouter", id: signpostID)
        defer { engineSignposter.endInterval("CoreAudioEngine.startRouter", signpostState) }

        // The single output everything mixes into is the user's saved BAM choice.
        // The system default only seeds a missing initial selection. Resolve the
        // stored UID against the live device list first — USB devices (e.g. the
        // Razer wireless dongle) re-enumerate with a new trailing instance index,
        // so the persisted UID can go stale while the device is still present.
        let storedUID = config.mixes.compactMap { mix -> String? in
            if case .hardware(let uid) = mix.dest { return uid } else { return nil }
        }.first
        let outputUID = Self.resolveOutputUID(stored: storedUID)
        guard let outputUID else {
            bamLog("startRouter: no output device (no hardware dest, no default output) — all \(config.mixes.count) mixes offline", level: .error)
            guard closeRouter() else {
                return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
            }
            _boundOutputUID = nil
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .noOutput)
        }
        if let storedUID, storedUID != outputUID {
            engineLog.debug(
                "startRouter: stored output absent stored=\(storedUID, privacy: .private) rebound=\(outputUID, privacy: .private)"
            )
        }
        guard let captureUID = Self.tapCaptureOutputUID() else {
            guard closeRouter() else {
                return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
            }
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .noOutput)
        }
        let listeningUIDs = requiredOutputs.union([outputUID])
        guard listeningUIDs.isSubset(of: protectedOutputUIDs),
              listeningUIDs.allSatisfy({ Self.resolvedDeviceMuted(uid: $0) }) else {
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
        }
        let currentDeviceIDs = Dictionary(uniqueKeysWithValues: Set([outputUID, captureUID]).compactMap { uid in
            ProcessEnumerator.deviceID(forUID: uid).map { (uid, $0) }
        })
        guard currentDeviceIDs.count == Set([outputUID, captureUID]).count else {
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .noOutput)
        }
        if !appliedDeviceIDs.isEmpty && !Self.sameDeviceTopology(currentDeviceIDs, appliedDeviceIDs) {
            // A stable UID can name a new HAL object after reconnect.
            routerGeneration += 1
            guard closeRouter() else {
                return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
            }
            if currentDeviceIDs[captureUID] != appliedDeviceIDs[captureUID] { liveTaps.removeAll() }
        }
        if captureUID != outputUID {
            engineLog.debug(
                "startRouter: capture/render split capture=\(captureUID, privacy: .private) render=\(outputUID, privacy: .private)"
            )
        }

        let allProcs = ProcessEnumerator.allProcesses()

        guard let selfObjectID = ProcessEnumerator.processObject(forPID: getpid()) else {
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
        }
        let desired = Self.desiredTapSpecs(config: config, processes: allProcs, captureUID: captureUID,
                                          selfObjectID: selfObjectID)

        if let live = router, routerTapSig != nil,
           let updates = Self.membershipUpdates(desired: desired, live: liveTaps.mapValues(\.spec)) {
            let pending = routerMembershipUncertain ? desired : updates
            routerMembershipUncertain = true
            for spec in pending {
                guard let cached = liveTaps[spec.sourceID],
                      cached.tap.proc.update(description: spec.description()) else {
                    return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
                }
                liveTaps[spec.sourceID] = (spec, cached.tap)
            }
            applyRouterGains(config, to: live)
            guard live.hasCompatibleTapFormats(),
                  live.waitUntilReady(after: live.readinessToken),
                  live.hasCompatibleTapFormats() else {
                return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
            }
            routerMembershipUncertain = false
            routerConfig = config
            return .ok
        }

        // Actual source/device edits can change the layout. Reuse compatible
        // taps, but never replace a tap just because its process list changed.
        var newLive: [String: (spec: DesiredTapSpec, tap: RouterAggregate.Tap)] = [:]
        var orderedTaps: [RouterAggregate.Tap] = []
        var failedTapSourceIDs = Set<String>()
        for d in desired {
            if let cached = liveTaps[d.sourceID], cached.spec.structuralSignature == d.structuralSignature {
                if cached.spec != d || routerMembershipUncertain {
                    routerMembershipUncertain = true
                    guard cached.tap.proc.update(description: d.description()) else {
                        return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
                    }
                    liveTaps[d.sourceID] = (d, cached.tap)
                }
                newLive[d.sourceID] = (d, cached.tap)
                orderedTaps.append(cached.tap)
            } else if let proc = ProcessTap(description: d.description()) {
                let tap = RouterAggregate.Tap(sourceID: d.sourceID, proc: proc)
                newLive[d.sourceID] = (d, tap)
                orderedTaps.append(tap)
            } else {
                failedTapSourceIDs.insert(d.sourceID)
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
            guard closeRouter() else {
                return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
            }
            liveTaps = newLive
            routerMembershipUncertain = false
            _boundOutputUID = outputUID
            routerHealthBaseline = nil
            routerHealthTask?.cancel()
            routerHealthTask = nil
            return RouterStatus(cause: .noSourcesRunning)
        }

        let aggSig = outputUID + "|" + orderedTaps.map(\.proc.uuid).joined(separator: ",")
        if let live = router, routerTapSig == aggSig || pendingRouterTapSig == aggSig {
            // Tap set AND output unchanged → leave the running aggregate alone and
            // only refold gains. This is the hot path for ordinary edits: no
            // rebuild, no offline flash, no blast.
            applyRouterGains(config, to: live)
            if pendingRouterTapSig != nil {
                return checkPendingRouterReadiness() ? .ok
                    : RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
            }
            return .ok
        }

        // Structural change: confirmed hardware mute protects break-before-make.
        // Retaining a .mutedWhenTapped tap alone does not suppress direct audio
        // while its reader is stopped. Closing first also frees the fixed UID.
        var builtOK = true
        var failureStatus = RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
        func doRebuild() {
            lastHealthyObservation = nil
            healthyGeneration = nil
            routerGeneration += 1
            routerHealthTask?.cancel()
            routerHealthTask = nil
            routerHealthBaseline = nil
            guard closeRouter() else { builtOK = false; return }
            // Drop obsolete taps only after the previous callback and aggregate
            // are confirmed gone, with the output still protected.
            liveTaps = newLive
            let aggregateSignpostID = engineSignposter.makeSignpostID()
            let aggregateSignpostState = engineSignposter.beginInterval("CoreAudioEngine.rebuildAggregate", id: aggregateSignpostID)
            var aggregateFailure: RouterAggregate.BuildFailure?
            let agg = RouterAggregate(taps: orderedTaps)
            router = agg
            diagnosticsGeneration = routerGeneration
            let buildStart = ProcessInfo.processInfo.systemUptime
            let started = agg.start(outputUID: outputUID, failure: &aggregateFailure)
            recordAggregateBuild(success: started, milliseconds: (ProcessInfo.processInfo.systemUptime - buildStart) * 1000)
            guard started else {
                engineSignposter.endInterval("CoreAudioEngine.rebuildAggregate", aggregateSignpostState)
                bamLog("startRouter: aggregate build failed (\(orderedTaps.count) taps, output \(outputUID), failure \(String(describing: aggregateFailure))) — \(config.mixes.count) mixes offline", level: .error)
                routerTapSig = nil
                _ = closeRouter() // Failure retains the partially built router for retry.
                builtOK = false
                failureStatus = RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .buildFailed)
                return
            }
            engineSignposter.endInterval("CoreAudioEngine.rebuildAggregate", aggregateSignpostState)
            applyRouterGains(config, to: agg)
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
            builtOK = checkPendingRouterReadiness()
        }
        doRebuild()
        if !builtOK { return failureStatus }
        return .ok
    }

    /// Track the actual renderer even while the caller keeps it hardware-muted.
    func trackStartedRouter(signature: String, outputUID: String, deviceIDs: [String: AudioObjectID]) {
        routerTapSig = nil
        pendingRouterTapSig = signature
        _boundOutputUID = outputUID
        appliedDeviceIDs = deviceIDs
    }

    private func checkPendingRouterReadiness() -> Bool {
        guard let router else { return false }
        let formatsBefore = router.hasCompatibleTapFormats()
        let ready = formatsBefore && router.waitUntilReady(after: router.readinessToken)
        let formatsAfter = router.hasCompatibleTapFormats()
        return completeRouterStartup(formatsBefore: formatsBefore, ready: ready, formatsAfter: formatsAfter)
    }

    /// Boolean observation boundary lets tests exercise pending ownership without HAL.
    func completeRouterStartup(formatsBefore: Bool, ready: Bool, formatsAfter: Bool) -> Bool {
        guard let agg = router, let signature = pendingRouterTapSig else { return false }
        guard formatsBefore, ready, formatsAfter else {
            engineLog.error("router readiness rejected formatsBefore=\(formatsBefore, privacy: .public) ready=\(ready, privacy: .public) formatsAfter=\(formatsAfter, privacy: .public) \(agg.startupDiagnostics, privacy: .public)")
            // A slow first callback must not restart its own startup clock on every retry.
            // Keep valid started resources protected; incompatible formats still require teardown.
            if !formatsBefore || !formatsAfter { _ = closeRouter() }
            return false
        }
        pendingRouterTapSig = nil
        routerTapSig = signature
        routerMembershipUncertain = false
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
                try? await Task.sleep(for: .seconds(2))
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
        // Device queries may outlive a switch/stop. Never apply their result to
        // another generation or make controls wait for those read-only queries.
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
        let expectedSourceIDs = expectedAudibleSourceIDs(config: config, processes: processSnapshot)
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

        if Self.aggregateRecoveryRequired(snapshot: h, state: state) {
            bamLog("router health failed: fires=\(h.fires) inBufs=\(h.inputBuffers) inCh=\(h.inputChannels) inFrames=\(h.inputFrames) outBufs=\(h.outputBuffers) outCh=\(h.outputChannels) outFrames=\(h.outputFrames) limiterFailures=\(h.limiterFailures); rebuilding aggregate", level: .error)
            recoverRouterAfterHealthFailure(signature: signature, reason: .aggregateStalled)
            return false
        }

        if outputFormatDrifted(current: observation.2) {
            state.outputFormatDriftSamples += 1
        } else {
            state.outputFormatDriftSamples = 0
        }
        if state.outputFormatDriftSamples >= 2 {
            bamLog("router health failed: output format/sample-rate changed; rebuilding aggregate", level: .error)
            recoverRouterAfterHealthFailure(signature: signature, reason: .outputFormatDrift)
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
            recoverRouterAfterHealthFailure(signature: signature, reason: .tapFormatDrift, resetSourceIDs: Set(formatBad))
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
            recoverRouterAfterHealthFailure(signature: signature, reason: .sourceTapStalled, resetSourceIDs: Set(sourceFrameBad))
            return false
        }

        // A fully-clean sample: nothing stale, no drift, no idle source flagged.
        let healthy = state.staleSamples == 0
            && state.noInputSamples == 0
            && state.outputFormatDriftSamples == 0
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

    /// Native render errors can silence output while callbacks and input continue advancing.
    /// Reuse the aggregate recovery budget, protected teardown and generation-bound rearm.
    nonisolated static func aggregateRecoveryRequired(snapshot: RouterAggregate.HealthSnapshot,
                                                       state: RouterHealthState) -> Bool {
        snapshot.limiterFailures > 0 || state.staleSamples >= 3 || state.noInputSamples >= 3
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

    private func expectedAudibleSourceIDs(
        config: BamConfig,
        processes: [AudioProcessInfo]
    ) -> Set<String> {
        let groupedTargets = config.sources
            .filter { $0.kind == .app }
            .flatMap(\.bundleIDs)

        var expected = Set<String>()
        for source in config.sources where effectiveSourceGain(config: config, sourceID: source.id) > Self.healthGainFloor {
            switch source.kind {
            case .app:
                if processes.contains(where: { proc in
                    proc.isRunningOutput && Self.matchedTarget(proc.bundleID, source.bundleIDs) != nil
                }) {
                    expected.insert(source.id)
                }
            case .rest:
                let selfBundle = Bundle.main.bundleIdentifier
                if processes.contains(where: { proc in
                    proc.isRunningOutput
                        && proc.bundleID != selfBundle
                        && Self.matchedTarget(proc.bundleID, groupedTargets) == nil
                }) {
                    expected.insert(source.id)
                }
            }
        }
        return expected
    }

    private func effectiveSourceGain(config: BamConfig, sourceID: String) -> Double {
        guard !config.masterMuted else { return 0 }
        if let solo = config.solo, solo != sourceID { return 0 }
        var gain = 0.0
        for mix in config.mixes {
            guard let send = mix.sends.first(where: { $0.source == sourceID }), !send.muted else {
                continue
            }
            gain += config.master * mix.level * send.level
        }
        return gain
    }

    private func recoverRouterAfterHealthFailure(
        signature: String,
        reason: RecoveryReason,
        resetSourceIDs: Set<String> = [],
        allowOffline: Bool = false
    ) {
        guard routerTapSig == signature || (allowOffline && routerTapSig == nil), let config = routerConfig else { return }
        lastHealthyObservation = nil
        let event = routerRecoveryPolicy.recordAttempt(reason: reason)
        emitRouterRecoveryEvent(event)
        routerHealthTask?.cancel()
        routerHealthTask = nil
        let restored = performGuardedOutputRebuild(uids: resolvedRouterOutputUIDs(config: config), unmute: !config.masterMuted) {
            if allowOffline, pendingRouterTapSig != nil {
                guard case .attempting = event else { return false }
                return !(recoveryTestHooks?.rebuild() ?? self.startRouter(config: config)).isFailure
            }
            routerGeneration += 1
            recoveryTestHooks?.willTearDown()
            guard closeRouter() else { return false }
            for sourceID in resetSourceIDs { liveTaps[sourceID] = nil }
            routerHealthBaseline = nil
            guard case .attempting = event else { return false }
            bamLog("router recovery: \(reason.rawValue)")
            return !(recoveryTestHooks?.rebuild() ?? self.startRouter(config: config)).isFailure
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

    private func retryAfterRearm(reason: RecoveryReason, signature: String, generation: Int? = nil, resetSourceIDs: Set<String> = []) {
        guard !Task.isCancelled else { return }
        rearmTasks[reason] = nil
        guard generation == nil || generation == routerGeneration else { return }
        if routerRecoverySuspended {
            suspendedRecoveries[reason] = (signature, generation, resetSourceIDs)
            return
        }
        // Only retry if this router generation is still the one that paused, and it is
        // actually still offline (router got torn down on pause).
        guard routerTapSig == nil || routerTapSig == signature, routerConfig != nil else { return }
        bamLog("router recovery re-arm fired: \(reason.rawValue)")
        recoverRouterAfterHealthFailure(signature: signature, reason: reason, resetSourceIDs: resetSourceIDs, allowOffline: true)
    }

    // MARK: router recovery events

    private var routerEventListeners: [UUID: [any ChangeListenerToken]] = [:]
    private var routerRecoveryEventSinks: [UUID: AsyncStream<RouterRecoveryEvent>.Continuation] = [:]

    /// Emits whenever the audio process list or output-device list changes — the
    /// only moments a previously failed `startRouter` could newly succeed (an app
    /// started, or an output device appeared). The view model retries on each
    /// event, so recovery is event-driven rather than a blind poll.
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
        routerEventListeners[id] = [
            Self.changeListenerFactoryStore.make(
                object: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            ) { continuation.yield(()) },
            Self.changeListenerFactoryStore.make(
                object: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDevices
            ) { continuation.yield(()) },
            // Default-output switches (between two devices that both stay present)
            // change no device LIST, so without this the router never re-resolves
            // its fallback target and keeps routing to the old device.
            Self.changeListenerFactoryStore.make(
                object: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice
            ) { continuation.yield(()) },
        ]
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

    /// Fold each source's level · mute · solo-gate · device level · master · pan
    /// into L/R scalars and push them to the aggregate (off the audio thread).
    private func applyRouterGains(_ config: BamConfig, to target: RouterAggregate? = nil) {
        guard let router = target ?? self.router else { return }
        let master = config.masterMuted ? 0 : Float(config.master)
        let solo = config.solo
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
            router.setGain(sourceID: source.id, l: l, r: r)
        }
    }

    /// Live per-source + per-mix levels while the router runs.
    public func routerSnapshots() -> AsyncStream<RouterSnapshot> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    continuation.yield(await self.routerSnapshot())
                    try? await Task.sleep(for: .milliseconds(33))
                }
                continuation.finish()
            }
            self.routerSamplerTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func routerSnapshot() -> RouterSnapshot {
        guard let cfg = routerConfig else { return .silent }
        var sourceMeters: [String: (level: Float, left: Float, right: Float)] = [:]
        let sources = cfg.sources.map { s -> RouterSourceMeter in
            let level = router?.meter(sourceID: s.id) ?? RMSMeter.floorDB
            let stereo = router?.stereoMeter(sourceID: s.id)
                ?? (left: RMSMeter.floorDB, right: RMSMeter.floorDB)
            sourceMeters[s.id] = (level, stereo.left, stereo.right)
            return RouterSourceMeter(
                id: s.id, name: s.name,
                level: level, levelLeft: stereo.left, levelRight: stereo.right
            )
        }
        let mixes = cfg.mixes.map { m -> MixMeter in
            // A device's level mirrors the source it groups (one source per mix).
            let lvl: Float
            let stereo: (left: Float, right: Float)
            if let sid = m.sends.first?.source, let cached = sourceMeters[sid] {
                lvl = cached.level
                stereo = (cached.left, cached.right)
            } else {
                lvl = RMSMeter.floorDB
                stereo = (RMSMeter.floorDB, RMSMeter.floorDB)
            }
            return MixMeter(id: m.id, name: m.name, level: lvl,
                            levelLeft: stereo.left, levelRight: stereo.right)
        }
        return RouterSnapshot(sources: sources, mixes: mixes)
    }

    /// Recompute routing gains live (level/mute/solo/pan/master) without
    /// rebuilding the aggregate or its taps.
    public func updateRouterGains(config: BamConfig) {
        routerConfig = config
        applyRouterGains(config)
    }

    public func stopRouter() {
        _ = stopRouterUnderProtection()
    }

    public func stopRouterChecked() async -> Bool { stopRouterUnderProtection() }

    private func closeRouter() -> Bool {
        // Once close is attempted, this generation must never take the reuse
        // path even if only some HAL teardown stages succeeded.
        routerTapSig = nil
        pendingRouterTapSig = nil
        guard router?.close() ?? true else { return false }
        if var snapshot = router?.audioDiagnostics() {
            snapshot.generation = diagnosticsGeneration
            lastAudioDiagnostics = snapshot
        }
        router = nil
        return true
    }

    private func stopRouterUnderProtection() -> Bool {
        lastHealthyObservation = nil
        // Stopping destroys the aggregate too; leave protection restoration to the caller.
        if router != nil || !liveTaps.isEmpty {
            guard let config = routerConfig else { return false }
            let outputs = resolvedRouterOutputUIDs(config: config)
            guard !outputs.isEmpty else { return false }
            for uid in outputs {
                guard writeOutputMute(uid: uid, true) == .applied else { return false }
            }
        }
        routerGeneration += 1
        routerHealthTask?.cancel()
        routerHealthTask = nil
        routerSamplerTask?.cancel()
        routerSamplerTask = nil
        for t in rearmTasks.values { t.cancel() }
        rearmTasks.removeAll()
        guard closeRouter() else { return false }
        liveTaps.removeAll()
        routerMembershipUncertain = false
        routerConfig = nil
        routerTapSig = nil
        routerHealthBaseline = nil
        _boundOutputUID = nil
        appliedDeviceIDs.removeAll()
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
