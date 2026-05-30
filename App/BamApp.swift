import AppKit
import ServiceManagement
import SwiftUI

/// Owns the window, the menu-bar status item, and the view model. The app is an
/// LSUIElement agent (no dock icon); the status item is the only way in:
/// left-click opens the window, right-click shows the controls menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ConsoleViewModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildStatusItem()
        // Under XCTest the app is only a test host; don't spin up the real
        // CoreAudio engine (taps, permission popup, device writes).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        // Launch silent to the menu bar (agent app). The window opens on the
        // status-item click — by then start() has loaded the saved config, so
        // there's no empty "no devices yet" flash.
        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.dimOutputForExit()
    }

    // MARK: - Window

    private func buildWindow() {
        let host = NSHostingController(rootView: ConsoleView(model: model))
        let w = NSWindow(contentViewController: host)
        w.setContentSize(NSSize(width: 880, height: 600))
        w.contentMinSize = NSSize(width: 640, height: 440)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = "BAM"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.collectionBehavior.remove(.fullScreenPrimary)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.center()
        window = w
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        centerTrafficLights(barHeight: 38)
    }

    // Vertically center the traffic-light buttons within our taller (38pt) custom
    // bar so they line up with the brand row, instead of the default titlebar center.
    private func centerTrafficLights(barHeight: CGFloat) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }
        let h = buttons.first?.frame.height ?? 14
        let y = container.frame.height - barHeight + (barHeight - h) / 2
        for b in buttons { b.frame.origin.y = y }
    }

    // MARK: - Menu-bar status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "BAM")
            btn.image?.isTemplate = true
            btn.target = self
            btn.action = #selector(statusClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = buildMenu()
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
        } else {
            showWindow()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let driver = NSMenuItem(title: "Audio Driver Enabled",
                                action: #selector(toggleDriver), keyEquivalent: "")
        driver.target = self
        driver.state = model.driverEnabled ? .on : .off
        menu.addItem(driver)

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close", action: #selector(closeWindow), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)

        let quit = NSMenuItem(title: "Quit BAM", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleDriver() { model.driverEnabled.toggle() }

    @objc private func toggleLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        try? enabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register()
    }

    @objc private func closeWindow() { window.performClose(nil) }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct BamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No SwiftUI scene window — the AppDelegate owns an AppKit window so it
        // can survive close/reopen and stay out of the dock. This empty Settings
        // scene satisfies the App protocol without showing anything.
        Settings { EmptyView() }
    }
}
