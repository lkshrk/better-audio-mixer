import CoreAudio
import Foundation

enum CA {
    static let hardwareWriteState = HardwareWriteState()

    /// A timed-out accepted write can still land shortly after. HAL exposes no request
    /// IDs, so the device stays protected for a settle window before any new write.
    final class HardwareWriteState: @unchecked Sendable {
        private struct Device: Hashable { let uid: String; let id: AudioObjectID }
        private let lock = NSLock()
        private let settleWindow: TimeInterval
        private var uncertain: [Device: Date] = [:]

        init(settleWindow: TimeInterval = 2) { self.settleWindow = settleWindow }

        func perform(
            uid: String, device: AudioObjectID, protectingMute: Bool,
            onFailure: () -> Void = {},
            confirm: (_ forceWrite: Bool, _ accepted: () -> Void) -> Bool
        ) -> Bool {
            // ponytail: serialize control writes across devices; use per-device locks
            // only if control-thread contention becomes material. Listener is independent.
            let result = lock.withLock {
                let key = Device(uid: uid, id: device)
                if let latched = uncertain[key] {
                    if Date().timeIntervalSince(latched) < settleWindow {
                        engineLog.error("hardware write blocked by an earlier unconfirmed request device=\(device, privacy: .public) protectingMute=\(protectingMute, privacy: .public)")
                        if protectingMute { _ = confirm(true, {}) }
                        // Best-effort protection cannot cancel an older pending write.
                        return false
                    }
                    uncertain[key] = nil
                }
                var accepted = false
                let confirmed = confirm(false, { accepted = true })
                if !protectingMute && accepted && !confirmed {
                    engineLog.error("hardware write accepted but unconfirmed; retaining protection device=\(device, privacy: .public)")
                    uncertain[key] = Date()
                }
                return confirmed
            }
            // A failed live volume control may start unmuted. Its protection must
            // reenter this state after unlocking, never leave it merely latched.
            if !result { onFailure() }
            return result
        }
    }

    /// HAL setters acknowledge a request, not its completion. The listener runs on a
    /// global queue so a synchronous actor/termination caller cannot block delivery.
    static func confirmedWrite(
        _ object: AudioObjectID, _ addr: AudioObjectPropertyAddress,
        isCurrent: () -> Bool, write: () -> Bool, matches: () -> Bool,
        landed: (() -> Bool)? = nil,
        timeout: TimeInterval = 0.5, forceWrite: Bool = false
    ) -> Bool {
        confirmWrite(isCurrent: isCurrent, matches: matches, landed: landed, subscribe: { signal in
            var address = addr
            let queue = DispatchQueue.global(qos: .userInitiated)
            let listener: AudioObjectPropertyListenerBlock = { _, _ in signal() }
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr else { return nil }
            return { _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener) }
        }, write: write, timeout: timeout, forceWrite: forceWrite)
    }

    /// Injectable observation boundary for deterministic tests; never infers completion
    /// from a successful setter or a notification whose readback is still stale.
    /// `matches` decides whether a write is needed; `landed` (default `matches`)
    /// confirms the readback after the write.
    static func confirmWrite(
        isCurrent: () -> Bool, matches: () -> Bool, landed: (() -> Bool)? = nil,
        subscribe: (@escaping @Sendable () -> Void) -> (() -> Void)?,
        write: () -> Bool, timeout: TimeInterval = 0.5, forceWrite: Bool = false,
        wait: (DispatchSemaphore, DispatchTime) -> Bool = { $0.wait(timeout: $1) == .success }
    ) -> Bool {
        guard isCurrent() else { return false }
        if !forceWrite && matches() { return isCurrent() }
        let signal = DispatchSemaphore(value: 0)
        guard let unsubscribe = subscribe({ signal.signal() }) else { return false }
        defer { unsubscribe() }
        guard isCurrent() else { return false }
        // The state may have reached the target while the listener was installed.
        if !forceWrite && matches() { return isCurrent() }
        let deadline = DispatchTime.now() + timeout
        // Discard notifications already observed before this request. HAL provides
        // no request correlation; callers must serialize writes and retain uncertainty
        // after timeout rather than treating a retry's notification as cancellation.
        while signal.wait(timeout: .now()) == .success {
            if DispatchTime.now() >= deadline { return false }
        }
        guard isCurrent(), write() else { return false }
        func hasLanded() -> Bool { landed.map { $0() } ?? matches() }
        while wait(signal, deadline) {
            guard isCurrent() else { return false }
            if hasLanded() { return isCurrent() }
            if DispatchTime.now() >= deadline { return false }
        }
        return false
    }

    static func volumeMatches(_ actual: Float?, target: Float) -> Bool {
        guard let actual, actual.isFinite, (0...1).contains(actual), target.isFinite else { return false }
        if actual == target { return true }
        // Silence and unity are exact safety boundaries. Match each channel's
        // requested calibration independently, including newly scaled calibrations.
        guard target > 0, target < 1 else { return false }
        // ponytail: measured 12% writes can read 12.1502%; cap rounding acceptance at
        // 0.2 percentage points AND 2% relative.
        return abs(actual - target) <= min(0.002, target * 0.02)
    }

    /// Devices quantize scalars (USB dB steps read back ±0.005, 1/16-step devices ±0.03).
    static let volumeLandingTolerance: Float = 0.07

    /// Post-write confirmation: the request landed on a quantizing device.
    static func volumeLanded(_ actual: Float?, target: Float) -> Bool {
        guard let actual, actual.isFinite, (0...1).contains(actual), target.isFinite else { return false }
        if actual == target { return true }
        guard target > 0, target < 1 else { return false }
        return abs(actual - target) <= volumeLandingTolerance
    }

    static func uint32Value(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var value: UInt32 = 0
        var address = addr
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func dataSize(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var size: UInt32 = 0
        var a = addr
        let status = AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size)
        return status == noErr ? size : nil
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress,
        of type: T.Type
    ) -> [T] {
        guard let size = dataSize(object, addr), size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<T>.alignment
        )
        defer { raw.deallocate() }
        var a = addr
        var io = size
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &io, raw)
        guard status == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress,
        default def: T
    ) -> T {
        var value = def
        var a = addr
        var io = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        return status == noErr ? value : def
    }

    static func cfString(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress
    ) -> String? {
        var value: CFString? = nil
        var a = addr
        var io = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }

    static func uint32(
        _ object: AudioObjectID,
        _ addr: AudioObjectPropertyAddress
    ) -> UInt32 {
        value(object, addr, default: UInt32(0))
    }

    static func float64(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Double? {
        var v: Float64 = 0
        var a = addr
        var io = UInt32(MemoryLayout<Float64>.size)
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        return st == noErr && io == MemoryLayout<Float64>.size ? v : nil
    }

    static func float32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Float? {
        var v: Float32 = 0
        var a = addr
        var io = UInt32(MemoryLayout<Float32>.size)
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &io, $0)
        }
        return st == noErr && io == MemoryLayout<Float32>.size ? v : nil
    }

    static func isSettable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        let st = AudioObjectIsPropertySettable(object, &a, &settable)
        return st == noErr && settable.boolValue
    }

    @discardableResult
    static func setFloat32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: Float) -> Bool {
        var v: Float32 = value
        var a = addr
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), $0)
        }
        return st == noErr
    }

    @discardableResult
    static func setUInt32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var v: UInt32 = value
        var a = addr
        let st = withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), $0)
        }
        return st == noErr
    }
}
