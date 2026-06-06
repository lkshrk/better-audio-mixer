import CoreAudio
import Foundation

/// One Core Audio process tap. Owns the tap object's lifetime; reads its
/// negotiated stream format so the aggregate and RMS loop know the layout.
final class ProcessTap {
    let tapID: AudioObjectID
    let uuid: String
    let format: AudioStreamBasicDescription

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

    private static func readFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = CA.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = withUnsafeMutablePointer(to: &asbd) {
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? asbd : nil
    }
}
