import BamControlKit
import BamCore
import Foundation

/// Bridges the live console model onto the `MixerControl` surface the Stream Deck
/// `ControlServer` drives. A "mix" on the wire is a console *device* (`config.mixes`);
/// per-device position uses the cube `AudioTaper`, while master volume passes through
/// linear (the hardware scalar is already perceptual).
extension ConsoleViewModel: MixerControl {

    var controlSnapshot: ControlSnapshot {
        let mixes = devices.map { mix -> MixSnapshot in
            let pos = AudioTaper.position(fromGain: deviceLevel(mix.id))
            return MixSnapshot(
                id: mix.id,
                name: mix.name,
                emoji: mix.emoji ?? "",
                pos: pos,
                pct: Int((pos * 100).rounded()),
                muted: deviceMuted(mix.id),
                level: mixLevel(mix.id)
            )
        }
        let master = MasterSnapshot(
            pos: outputVolume,
            pct: Int((outputVolume * 100).rounded()),
            muted: masterMuted,
            level: masterMeter,
            icon: systemOutputIcon
        )
        return ControlSnapshot(mixes: mixes, master: master)
    }

    func setPos(mixID: String, pos: Double) {
        setDeviceLevel(mixID, AudioTaper.gain(fromPosition: pos))
    }

    func nudgePos(mixID: String, delta: Double) {
        let pos = AudioTaper.position(fromGain: deviceLevel(mixID))
        setDeviceLevel(mixID, AudioTaper.gain(fromPosition: max(0, min(1, pos + delta))))
    }

    func setMuted(mixID: String, muted: Bool) {
        setDeviceMuted(mixID, muted)
    }

    func toggleMuted(mixID: String) {
        setDeviceMuted(mixID, !deviceMuted(mixID))
    }

    func setMasterPos(pos: Double) {
        setOutputVolume(pos)
    }

    func nudgeMasterPos(delta: Double) {
        setOutputVolume(outputVolume + delta)
    }

    func setMasterMuted(muted: Bool) {
        setMasterMuted(muted)
    }

    func listMixes() -> [MixSnapshot] {
        controlSnapshot.mixes
    }

    func listOutputs() -> [OutputSnapshot] {
        let activeUID = systemOutputUID
        return hardwareOutputDevices.map { dev in
            OutputSnapshot(uid: dev.uid, name: dev.name, active: dev.uid == activeUID,
                           icon: dev.outputIcon)
        }
    }

    /// v2 stub: switching the live aggregate output re-taps every source (ear hazard +
    /// dropout + TCC re-prompt), so the wire switch is gated on the v3 Mixer. Returns
    /// false → ControlServer replies `error{code:"unsupported"}`.
    func setOutputDevice(uid: String) -> Bool {
        false
    }
}
