import Atomics
import Foundation

/// Lock-free interleaved-Float audio ring. One writer (a source's tap IOProc),
/// many independent readers (one `RingReader` per mix consuming this source).
///
/// The writer advances a monotonic frame counter published with release
/// ordering; each reader holds its own cursor and acquires that counter before
/// copying, so samples written before the publish are visible. Readers never
/// mutate shared state, so any number of mixes can pull the same source
/// concurrently. Underrun fills silence and keeps the cursor clock-aligned
/// (never stall, never duplicate). Same-machine tap↔device share a clock domain,
/// so no resampling — slack absorbs jitter.
final class RingBuffer: @unchecked Sendable {
    let channels: Int
    let capacityFrames: Int          // power of two
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeFrame = ManagedAtomic<UInt64>(0)

    /// `slackFrames` is the target pre-fill / headroom (~85 ms). Capacity is the
    /// next power of two ≥ 2·slack so a lagging reader still has room before the
    /// writer laps it.
    init(channels: Int, slackFrames: Int) {
        precondition(channels > 0)
        let want = max(2, slackFrames * 2)
        var cap = 1
        while cap < want { cap <<= 1 }
        self.channels = channels
        self.capacityFrames = cap
        self.mask = cap - 1
        let count = cap * channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channels)
        storage.deallocate()
    }

    /// Total frames ever written (monotonic). Acquire ordering for readers.
    var framesWritten: UInt64 { writeFrame.load(ordering: .acquiring) }

    /// Writer side (RT thread). `src` is interleaved with `self.channels`.
    func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let base = Int(writeFrame.load(ordering: .relaxed))
        for f in 0..<frames {
            let slot = ((base + f) & mask) * channels
            let s = f * channels
            for c in 0..<channels { storage[slot + c] = src[s + c] }
        }
        writeFrame.store(UInt64(base + frames), ordering: .releasing)
    }

    /// Reader side. Copies `frames` interleaved frames into `dst` starting at
    /// `from` (a reader's cursor). Frames not yet written are zero-filled.
    /// Returns the number of real (non-silence) frames delivered. If the cursor
    /// lagged past capacity it snaps forward, dropping stale audio.
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int, from cursor: UInt64) -> (real: Int, nextCursor: UInt64) {
        let w = writeFrame.load(ordering: .acquiring)
        var start = cursor
        // Reader lapped: snap to oldest still-valid frame.
        if w > UInt64(capacityFrames), start < w - UInt64(capacityFrames) {
            start = w - UInt64(capacityFrames)
        }
        let avail = start < w ? Int(min(w - start, UInt64(frames))) : 0
        for f in 0..<avail {
            let slot = (Int(start &+ UInt64(f)) & mask) * channels
            let d = f * channels
            for c in 0..<channels { dst[d + c] = storage[slot + c] }
        }
        if avail < frames {
            let zeroFrom = avail * channels
            let zeroCount = (frames - avail) * channels
            (dst + zeroFrom).update(repeating: 0, count: zeroCount)
        }
        // Always advance by the full block so the playback clock stays aligned.
        return (avail, start &+ UInt64(frames))
    }
}

/// A per-mix read cursor into a shared `RingBuffer`. Not thread-safe on its own;
/// each mix's render owns one and drives it from a single thread.
final class RingReader {
    private let ring: RingBuffer
    private var cursor: UInt64

    init(ring: RingBuffer, prefillFrames: Int) {
        self.ring = ring
        // Start `prefillFrames` behind the writer so steady-state has slack.
        let w = ring.framesWritten
        self.cursor = w > UInt64(prefillFrames) ? w - UInt64(prefillFrames) : 0
    }

    var channels: Int { ring.channels }

    /// Fill `dst` (interleaved) with `frames`; underrun → silence. Returns real
    /// frame count for diagnostics.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let (real, next) = ring.read(into: dst, frames: frames, from: cursor)
        cursor = next
        return real
    }
}
