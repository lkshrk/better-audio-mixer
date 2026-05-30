import Atomics
import BamCore
import Foundation

/// One routed source feeding one mix. The persisted level/mute/solo/pan collapse
/// into per-channel gains recomputed off-thread (`pushGains`); the render loop is
/// pure multiply-accumulate.
struct MixSendSpec: Sendable {
    let sourceID: String
    let level: Float        // 0…1 per-(source,mix)
    let muted: Bool
}

/// One destination. `destUID` is any output device UID — a claimed BAM virtual
/// device or a hardware output (the Monitor mix). Unified per Q6.
struct MixSpec: Sendable {
    let id: String
    let destUID: String
    let master: Float       // per-mix master fader, post-sum
    let sends: [MixSendSpec]
}

/// Central routing mixer. Sources write into shared `RingBuffer`s (single writer
/// each); every mix opens its destination and, in that device's render callback,
/// sums its routed sources × effective gain, applies its master, and writes the
/// result. Same-machine clock domain → no SRC (bass preserved).
final class Mixer {
    private final class Send {
        let reader: RingReader
        let gainL = AtomicFloat(0)
        let gainR = AtomicFloat(0)
        init(reader: RingReader) { self.reader = reader }
    }

    private final class Destination: @unchecked Sendable {
        let spec: MixSpec
        let sends: [Send]
        let master = AtomicFloat(1)
        let level = AtomicFloat(RMSMeter.floorDB)   // dBFS, post-master mix output
        let channels: Int
        let maxFrames: Int
        let scratch: UnsafeMutablePointer<Float>
        var client: VirtualDeviceClient?

        init(spec: MixSpec, sends: [Send], channels: Int, maxFrames: Int) {
            self.spec = spec
            self.sends = sends
            self.channels = channels
            self.maxFrames = maxFrames
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channels)
            scratch.initialize(repeating: 0, count: maxFrames * channels)
        }

        deinit {
            client?.stop()
            scratch.deinitialize(count: maxFrames * channels)
            scratch.deallocate()
        }

        /// RT render: sum routed sources into `dst` (interleaved), apply master.
        func render(frames: Int, dst: UnsafeMutablePointer<Float>) {
            let n = min(frames, maxFrames)
            let total = n * channels
            (dst).update(repeating: 0, count: total)
            for send in sends {
                send.reader.read(into: scratch, frames: n)
                let gL = send.gainL.load()
                let gR = send.gainR.load()
                if gL == 0 && gR == 0 { continue }
                if channels == 2 {
                    for f in 0..<n {
                        dst[f * 2]     += scratch[f * 2]     * gL
                        dst[f * 2 + 1] += scratch[f * 2 + 1] * gR
                    }
                } else {
                    for i in 0..<total { dst[i] += scratch[i] * gL }
                }
            }
            let m = master.load()
            if m != 1 { for i in 0..<total { dst[i] *= m } }
            var ss: Float = 0
            for i in 0..<total { ss += dst[i] * dst[i] }
            level.store(RMSMeter.dbFS(rms: total > 0 ? (ss / Float(total)).squareRoot() : 0))
            // If asked for more frames than scratch holds, silence the tail.
            if frames > n {
                (dst + total).update(repeating: 0, count: (frames - n) * channels)
            }
        }
    }

    let channels: Int
    let sampleRate: Double
    let slackFrames: Int
    private let maxFrames: Int
    private var destinations: [Destination] = []

    init(channels: Int = 2, sampleRate: Double = 48_000, slackMs: Double = 85, maxFrames: Int = 4096) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.slackFrames = Int(sampleRate * slackMs / 1000.0)
        self.maxFrames = maxFrames
    }

    /// Source id → its ring (created/owned by the capture layer).
    private(set) var sourceRings: [String: RingBuffer] = [:]

    /// Register (or fetch) a source's ring. The tap IOProc writes into it.
    func ring(for sourceID: String) -> RingBuffer {
        if let r = sourceRings[sourceID] { return r }
        let r = RingBuffer(channels: channels, slackFrames: slackFrames)
        sourceRings[sourceID] = r
        return r
    }

    /// Build destinations + fold gains, but do not open any device. Render can be
    /// driven directly (used by tests and before devices are claimed).
    func prepare(mixes: [MixSpec], pans: [String: Float], solo: String?) {
        stop()
        var built: [Destination] = []
        for spec in mixes {
            var sends: [Send] = []
            for s in spec.sends {
                let ring = ring(for: s.sourceID)
                sends.append(Send(reader: RingReader(ring: ring, prefillFrames: slackFrames)))
            }
            built.append(Destination(spec: spec, sends: sends, channels: channels, maxFrames: maxFrames))
        }
        destinations = built
        pushGains(mixes: mixes, pans: pans, solo: solo)
    }

    /// Build destinations for the given mixes. Each mix opens its device and
    /// starts rendering. Returns the mix ids that failed to open their device.
    func configure(mixes: [MixSpec], pans: [String: Float], solo: String?) -> [String] {
        prepare(mixes: mixes, pans: pans, solo: solo)
        var failed: [String] = []
        for dest in destinations {
            let client = VirtualDeviceClient(
                deviceUID: dest.spec.destUID, channels: channels, sampleRate: sampleRate
            ) { [weak dest] frames, out in
                dest?.render(frames: frames, dst: out)
            }
            if let client, client.start() {
                dest.client = client
            } else {
                failed.append(dest.spec.id)
            }
        }
        return failed
    }

    /// Drive one mix's render directly (no device). Test/headless seam.
    func renderMix(id: String, frames: Int, into dst: UnsafeMutablePointer<Float>) {
        destinations.first { $0.spec.id == id }?.render(frames: frames, dst: dst)
    }

    /// Mix ids in configured order.
    var mixIDs: [String] { destinations.map(\.spec.id) }

    /// Latest post-master output level (dBFS) for a mix.
    func mixLevel(id: String) -> Float {
        destinations.first { $0.spec.id == id }?.level.load() ?? RMSMeter.floorDB
    }

    /// Recompute per-send effective gains off the render thread (Q15). Folds
    /// level · mute · solo-gate · pan into L/R scalars; render stays a multiply.
    func pushGains(mixes: [MixSpec], pans: [String: Float], solo: String?) {
        let specByID = Dictionary(uniqueKeysWithValues: mixes.map { ($0.id, $0) })
        for dest in destinations {
            dest.master.store(specByID[dest.spec.id]?.master ?? dest.spec.master)
            let sends = specByID[dest.spec.id]?.sends ?? dest.spec.sends
            for (i, sendSpec) in sends.enumerated() where i < dest.sends.count {
                let soloed = solo == nil || solo == sendSpec.sourceID
                let eff = sendSpec.muted || !soloed ? 0 : sendSpec.level
                let pan = pans[sendSpec.sourceID] ?? 0.5
                let (l, r) = Self.equalPower(pan: pan)
                dest.sends[i].gainL.store(eff * l)
                dest.sends[i].gainR.store(eff * r)
            }
        }
    }

    /// Equal-power pan law. pan 0 = hard left, 0.5 = center, 1 = hard right.
    static func equalPower(pan: Float) -> (Float, Float) {
        let p = min(max(pan, 0), 1)
        let theta = p * (Float.pi / 2)
        return (cos(theta), sin(theta))
    }

    func stop() {
        for d in destinations { d.client?.stop() }
        destinations = []
    }
}
