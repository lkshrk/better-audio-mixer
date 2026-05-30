import XCTest
@testable import AudioEngine

/// Readers are created in `prepare` and must exist before the writer fills the
/// ring (real order: capture starts, then audio flows). Each test prepares the
/// mix first, then fills source rings, then renders.
final class MixerTests: XCTestCase {
    private func fill(_ ring: RingBuffer, l: Float, r: Float, frames: Int) {
        var buf = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { buf[f * 2] = l; buf[f * 2 + 1] = r }
        buf.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
    }

    private func makeMixer() -> Mixer {
        Mixer(channels: 2, sampleRate: 48_000, slackMs: 0, maxFrames: 512)
    }

    func testSingleSourceFullLevelCenterPassesThrough() {
        let m = makeMixer()
        m.prepare(
            mixes: [MixSpec(id: "stream", destUID: "X", master: 1,
                            sends: [MixSendSpec(sourceID: "a", level: 1, muted: false)])],
            pans: ["a": 0.5], solo: nil
        )
        fill(m.ring(for: "a"), l: 0.5, r: 0.25, frames: 256)
        var out = [Float](repeating: -9, count: 256 * 2)
        out.withUnsafeMutableBufferPointer { m.renderMix(id: "stream", frames: 256, into: $0.baseAddress!) }
        XCTAssertEqual(out[0], 0.5 * 0.7071, accuracy: 1e-3)
        XCTAssertEqual(out[1], 0.25 * 0.7071, accuracy: 1e-3)
    }

    func testMutedSourceIsSilent() {
        let m = makeMixer()
        m.prepare(
            mixes: [MixSpec(id: "stream", destUID: "X", master: 1,
                            sends: [MixSendSpec(sourceID: "a", level: 1, muted: true)])],
            pans: [:], solo: nil
        )
        fill(m.ring(for: "a"), l: 0.8, r: 0.8, frames: 128)
        var out = [Float](repeating: -9, count: 128 * 2)
        out.withUnsafeMutableBufferPointer { m.renderMix(id: "stream", frames: 128, into: $0.baseAddress!) }
        XCTAssertEqual(out.max(), 0)
        XCTAssertEqual(out.min(), 0)
    }

    func testTwoSourcesSumWithLevels() {
        let m = makeMixer()
        m.prepare(
            mixes: [MixSpec(id: "mix", destUID: "X", master: 1, sends: [
                MixSendSpec(sourceID: "a", level: 0.5, muted: false),
                MixSendSpec(sourceID: "b", level: 1.0, muted: false),
            ])],
            pans: ["a": 1.0, "b": 1.0], solo: nil // hard right → all energy on R
        )
        fill(m.ring(for: "a"), l: 0.4, r: 0.4, frames: 64)
        fill(m.ring(for: "b"), l: 0.2, r: 0.2, frames: 64)
        var out = [Float](repeating: 0, count: 64 * 2)
        out.withUnsafeMutableBufferPointer { m.renderMix(id: "mix", frames: 64, into: $0.baseAddress!) }
        XCTAssertEqual(out[0], 0, accuracy: 1e-4)
        XCTAssertEqual(out[1], 0.4, accuracy: 1e-3) // 0.4*0.5 + 0.2*1.0
    }

    func testSoloDropsOtherSources() {
        let m = makeMixer()
        m.prepare(
            mixes: [MixSpec(id: "mix", destUID: "X", master: 1, sends: [
                MixSendSpec(sourceID: "a", level: 1, muted: false),
                MixSendSpec(sourceID: "b", level: 1, muted: false),
            ])],
            pans: ["a": 0.5, "b": 0.5], solo: "a"
        )
        fill(m.ring(for: "a"), l: 0.5, r: 0.5, frames: 64)
        fill(m.ring(for: "b"), l: 0.5, r: 0.5, frames: 64)
        var out = [Float](repeating: 0, count: 64 * 2)
        out.withUnsafeMutableBufferPointer { m.renderMix(id: "mix", frames: 64, into: $0.baseAddress!) }
        XCTAssertEqual(out[0], 0.5 * 0.7071, accuracy: 1e-3) // only "a"
    }

    func testMasterFaderScalesPostSum() {
        let m = makeMixer()
        m.prepare(
            mixes: [MixSpec(id: "mix", destUID: "X", master: 0.25,
                            sends: [MixSendSpec(sourceID: "a", level: 1, muted: false)])],
            pans: ["a": 1.0], solo: nil
        )
        fill(m.ring(for: "a"), l: 1.0, r: 1.0, frames: 64)
        var out = [Float](repeating: 0, count: 64 * 2)
        out.withUnsafeMutableBufferPointer { m.renderMix(id: "mix", frames: 64, into: $0.baseAddress!) }
        XCTAssertEqual(out[1], 0.25, accuracy: 1e-3) // 1.0 * 0.25
    }

    func testMixMinusSourceAbsentFromMix() {
        let m = makeMixer()
        m.prepare(mixes: [
            MixSpec(id: "stream", destUID: "S", master: 1, sends: [
                MixSendSpec(sourceID: "me", level: 1, muted: false),
                MixSendSpec(sourceID: "game", level: 1, muted: false),
            ]),
            MixSpec(id: "chat", destUID: "C", master: 1, sends: [
                MixSendSpec(sourceID: "game", level: 1, muted: false), // no "me"
            ]),
        ], pans: ["me": 1.0, "game": 1.0], solo: nil)
        fill(m.ring(for: "me"), l: 0.6, r: 0.6, frames: 64)
        fill(m.ring(for: "game"), l: 0.3, r: 0.3, frames: 64)

        var s = [Float](repeating: 0, count: 64 * 2)
        var c = [Float](repeating: 0, count: 64 * 2)
        s.withUnsafeMutableBufferPointer { m.renderMix(id: "stream", frames: 64, into: $0.baseAddress!) }
        c.withUnsafeMutableBufferPointer { m.renderMix(id: "chat", frames: 64, into: $0.baseAddress!) }
        XCTAssertEqual(s[1], 0.9, accuracy: 1e-3) // me + game
        XCTAssertEqual(c[1], 0.3, accuracy: 1e-3) // game only
    }
}
