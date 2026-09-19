import AppKit
import SwiftUI
import XCTest
@testable import bam
import BamCore

/// Renders the console on the mock engine; writes PNGs when `BAM_SNAPSHOT_DIR` is set for visual review.
@MainActor
final class ConsoleSnapshotTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bam.snapshot.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static let config = BamConfig(
        sources: [
            Source(id: "s-game", name: "Game", kind: .app, bundleIDs: ["com.valvesoftware.steam"], hue: 0.0),
            Source(id: "s-chat", name: "Chat", kind: .app, bundleIDs: ["com.hnc.Discord"], hue: 0.66),
            Source(id: "s-music", name: "Music", kind: .app, bundleIDs: ["com.spotify.client"], hue: 0.38),
            Source(id: "s-browser", name: "Browser", kind: .app, bundleIDs: ["com.apple.Safari"], hue: 0.55),
        ],
        mixes: [
            Mix(id: "m-game", name: "Game", dest: .virtualSlot(0), level: 0.8, sends: [Send(source: "s-game")], tone: 0.0),
            Mix(id: "m-chat", name: "Chat", dest: .virtualSlot(1), level: 0.35, sends: [Send(source: "s-chat")], tone: 0.66),
            Mix(id: "m-music", name: "Music", dest: .virtualSlot(2), level: 0.12, sends: [Send(source: "s-music")], tone: 0.38),
            Mix(id: "m-browser", name: "Browser", dest: .virtualSlot(3), level: 1.0, sends: [Send(source: "s-browser")], tone: 0.55),
        ]
    )

    func testConsoleRendersOnMockEngine() async throws {
        let model = ConsoleViewModel(engine: MockAudioEngine(), defaults: defaults)
        await model.startMock(config: Self.config)
        model.setDeviceMuted("m-chat", true)
        model.setOutputVolume(0.72)
        try await Task.sleep(for: .milliseconds(600))

        let stage = Stage(ConsoleView(model: model))
        try await Task.sleep(for: .milliseconds(200))

        let image = try XCTUnwrap(stage.capture())
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        try write(image, named: "console.png")

        stage.close()
        await model.stop()
    }

    private func write(_ rep: NSBitmapImageRep, named name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["BAM_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try png.write(to: url.appendingPathComponent(name))
    }
}

/// Hosts the view in a window parked off-screen; `ImageRenderer` skips `ScrollView` content.
@MainActor
private final class Stage {
    private let window: NSWindow
    private let host: NSView
    private let size = NSSize(width: 880, height: 600)
    private let scale: CGFloat = 2

    init<V: View>(_ view: V) {
        host = NSHostingView(rootView: view.frame(width: 880, height: 600))
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
    }

    func capture() -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func close() {
        window.close()
    }
}
