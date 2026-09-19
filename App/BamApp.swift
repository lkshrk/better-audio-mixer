import AppKit
import ServiceManagement
import SwiftUI

struct RunningApplicationIdentity: Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

enum SingleInstanceGuard {
    static let appBundleIdentifiers: Set<String> = [
        "me.harke.bam",
        "me.harke.bam.dev"
    ]

    static func hasOtherInstance(
        bundleIdentifier: String?,
        currentPID: pid_t,
        runningApplications: [RunningApplicationIdentity]
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        let guardedBundleIdentifiers = appBundleIdentifiers.union([bundleIdentifier])
        return runningApplications.contains {
            guard let runningBundleIdentifier = $0.bundleIdentifier else { return false }
            return guardedBundleIdentifiers.contains(runningBundleIdentifier)
                && $0.processIdentifier != currentPID
        }
    }

    static func shouldTerminateCurrentProcess() -> Bool {
        let runningApplications = appBundleIdentifiers
            .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
            .map {
                RunningApplicationIdentity(
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier
                )
            }
        return hasOtherInstance(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            currentPID: getpid(),
            runningApplications: runningApplications
        )
    }
}

/// LSUIElement agent: the status item is the only way in (left-click window, right-click menu).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ConsoleViewModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var started = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningUnderXCTest {
            return
        }

        if SingleInstanceGuard.shouldTerminateCurrentProcess() {
            NSApp.terminate(nil)
            return
        }

        buildWindow()
        buildStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        started = true
        Task { await model.start() }
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// A second instance or a test host never touched the hardware, so it exits at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard started, !terminating else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            _ = await model.prepareForExit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func systemDidWake(_ note: Notification) {
        model.systemDidWake()
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
        centerTrafficLights(barHeight: Tuning.titleBarHeight)
    }

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

        let about = NSMenuItem(title: "About BAM…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit BAM", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    nonisolated static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    nonisolated static var versionLabel: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "BAM \(shortVersion) (\($0))" } ?? "BAM \(shortVersion)"
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func toggleDriver() { model.driverEnabled.toggle() }

    @objc private func toggleLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        try? enabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct BamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The AppDelegate owns the window; an empty Settings scene satisfies the App protocol.
        Settings { EmptyView() }
    }
}
