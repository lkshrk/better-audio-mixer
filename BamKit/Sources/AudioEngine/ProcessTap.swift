import CoreAudio
import Foundation

/// One Core Audio process tap. Owns the tap object's lifetime; reads its
/// negotiated stream format so the aggregate and RMS loop know the layout.
/// Membership writes are serialized by the engine's router gate.
final class ProcessTap: @unchecked Sendable {
    let tapID: AudioObjectID
    let uuid: String
    let format: AudioStreamBasicDescription
    private let originalDescription: CATapDescription
    private var membershipUncertain = false

    init?(description: CATapDescription) {
        description.isPrivate = true

        let signpostID = engineSignposter.makeSignpostID()
        let signpostState = engineSignposter.beginInterval("ProcessTap.create", id: signpostID)
        defer { engineSignposter.endInterval("ProcessTap.create", signpostState) }

        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown) else { return nil }

        guard let fmt = ProcessTap.readFormat(id) else {
            AudioHardwareDestroyProcessTap(id)
            return nil
        }

        self.tapID = id
        self.uuid = description.uuid.uuidString
        self.format = fmt
        self.originalDescription = description
        engineLog.debug(
            "processTap uid=\(description.deviceUID ?? "any", privacy: .private) stream=\(description.stream.map(String.init) ?? "any", privacy: .public) mixdown=\(description.isMixdown, privacy: .public) mono=\(description.isMono, privacy: .public) exclusive=\(description.isExclusive, privacy: .public) sr=\(fmt.mSampleRate, privacy: .public) ch=\(fmt.mChannelsPerFrame, privacy: .public) flags=\(fmt.mFormatFlags, privacy: .public) bytesFrame=\(fmt.mBytesPerFrame, privacy: .public)"
        )
    }

    deinit {
        AudioHardwareDestroyProcessTap(tapID)
    }

    func currentFormat() -> AudioStreamBasicDescription? {
        Self.readFormat(tapID)
    }

    /// Only membership is mutable here. The aggregate owns a frozen layout and
    /// still reads this same tap; failed confirmation must retain output mute.
    func update(description: CATapDescription) -> Bool {
        // A timed-out write may still land later; only a protected destroy clears the uncertainty.
        guard !membershipUncertain else { return false }
        description.uuid = originalDescription.uuid
        description.isPrivate = true
        guard Self.sameConfiguration(description, originalDescription) else { return false }
        membershipUncertain = true
        let confirmed = CA.confirmedWrite(tapID, CA.address(kAudioTapPropertyDescription), isCurrent: {
            CA.cfString(self.tapID, CA.address(kAudioTapPropertyUID)) == self.uuid
        }, write: {
            var value: CATapDescription? = description
            var address = CA.address(kAudioTapPropertyDescription)
            return withUnsafePointer(to: &value) {
                AudioObjectSetPropertyData(self.tapID, &address, 0, nil,
                    UInt32(MemoryLayout<CATapDescription?>.size), $0) == noErr
            }
        }, matches: {
            guard let actual = Self.readDescription(self.tapID) else { return false }
            return Self.sameConfiguration(actual, description)
                && actual.processes.sorted() == description.processes.sorted()
        })
        membershipUncertain = !confirmed
        return confirmed
    }

    static func sameConfiguration(_ lhs: CATapDescription, _ rhs: CATapDescription) -> Bool {
        lhs.uuid == rhs.uuid && lhs.deviceUID == rhs.deviceUID && lhs.stream == rhs.stream
            && lhs.isPrivate == rhs.isPrivate && lhs.isExclusive == rhs.isExclusive
            && lhs.isMixdown == rhs.isMixdown && lhs.isMono == rhs.isMono
            && lhs.muteBehavior == rhs.muteBehavior
    }

    private static func readDescription(_ tapID: AudioObjectID) -> CATapDescription? {
        var address = CA.address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<CATapDescription?>.size)
        var value: CATapDescription?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        return status == noErr && size == MemoryLayout<CATapDescription?>.size ? value : nil
    }

    static func readFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = CA.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = withUnsafeMutablePointer(to: &asbd) {
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? asbd : nil
    }
}
