import SwiftUI
import AppKit

@MainActor
final class PolicyController {
    private(set) var current: NSApplication.ActivationPolicy

    init(initial: NSApplication.ActivationPolicy) {
        current = initial
        NSApplication.shared.setActivationPolicy(initial)
    }

    func becomeRegular() {
        guard current != .regular else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        current = .regular
    }

    func becomeAccessory() {
        guard current != .accessory else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        current = .accessory
    }
}

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let policy: PolicyController
    private var controllers: Set<NSWindowController> = []
    private weak var mainWindowController: NSWindowController?
    var hasMainWindow: Bool { mainWindowController?.window != nil }
    var hasOpenUserWindows: Bool { return !controllers.isEmpty }

    init(policy: PolicyController) {
        self.policy = policy
        super.init()
    }

    func activateMainWindow() -> Bool {
        guard let controller = mainWindowController, let win = controller.window else { return false }
        policy.becomeRegular()
        NSRunningApplication.current.activate(options: [])
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        win.deminiaturize(nil)
        return true
    }

    func showWindow<V: View>(title: String, @ViewBuilder content: () -> V) {
        policy.becomeRegular()

        let hosting = NSHostingController(rootView: AnyView(content()))
        // SwiftUI supplies the window title and the toolbar items from the root view's
        // `navigationTitle` and `toolbar`; the separator under the toolbar shows only while
        // content is scrolled beneath it.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let win = NSWindow(contentViewController: hosting)
        win.title = title
        win.setContentSize(NSSize(width: 800, height: 810))
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.styleMask.insert(.fullSizeContentView)
        win.toolbarStyle = .unified
        win.titlebarSeparatorStyle = .automatic

        let controller = NSWindowController(window: win)
        self.mainWindowController = controller
        controllers.insert(controller)

        controller.showWindow(nil)
        win.center()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            win.deminiaturize(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let controller = controllers.first(where: { $0.window === window }) {
            controllers.remove(controller)
        }
        if mainWindowController?.window === window {
            mainWindowController = nil
        }
        if controllers.isEmpty {
            policy.becomeAccessory()
            // Show one-time education panel when the last window closes
            EducationWindowController.shared.showIfNeeded()
        }
    }
}

extension Notification.Name {
    /// Posted by the Status pane's toolbar items; the pane runs them, with its toast when
    /// a run is already going.
    static let toolbarRunNowRequested = Notification.Name("ToolbarRunNowRequested")
    static let toolbarDryRunRequested = Notification.Name("ToolbarDryRunRequested")
}

@MainActor
final class WindowCoordinator {
    static var shared: WindowCoordinator?

    private let policy: PolicyController
    private let windows: WindowManager

    // Weak references to app-scoped models so we can inject them into SwiftUI content
    private weak var settings: SettingsStore?
    private weak var logger: LogStore?
    private weak var app: AppModel?

    init(policy: PolicyController, settings: SettingsStore, logger: LogStore, app: AppModel) {
        self.policy = policy
        self.windows = WindowManager(policy: policy)
        self.settings = settings
        self.logger = logger
        self.app = app
    }

    private func refreshDockOverlay() {
        guard let app else { return }
        let state: DockStatusOverlay.State = app.lastRunHadFatalError ? .error : (app.isRunning ? .running : .stopped)
        DockStatusOverlay.shared.update(for: state)
    }

    func openMain() {
        guard let settings, let logger, let app else { return }
        // If a main window already exists, activate/bring it to front
        if windows.activateMainWindow() {
            refreshDockOverlay()
            return
        }
        // Otherwise, create the main window
        windows.showWindow(title: "") {
            RootView()
                .environmentObject(settings)
                .environmentObject(logger)
                .environmentObject(app)
        }
        refreshDockOverlay()
    }

}

// MARK: - Menu Items

@MainActor
private struct OpenMainMenuItem: View {
    var body: some View {
        Button {
            Task { @MainActor in
                WindowCoordinator.shared?.openMain()
            }
        } label: {
            Label("Open FindMySync+", systemImage: "sidebar.left")
        }
    }
}

// MARK: - App Delegate (simplified)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let openMainOnLaunch = UserDefaults.standard.bool(forKey: "openMainOnLaunch")
        let runInMenuBarOnly = !openMainOnLaunch
        if runInMenuBarOnly {
            // Ensure accessory policy at launch for agent apps; no fallback status item (MenuBarExtra provides UI)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowCoordinator.shared?.openMain()
        return true
    }
}

// MARK: - InstallCoordinator View

@MainActor
private struct InstallCoordinator: View {
    let policy: PolicyController
    let settings: SettingsStore
    let logger: LogStore
    let app: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                if WindowCoordinator.shared == nil {
                    WindowCoordinator.shared = WindowCoordinator(
                        policy: policy,
                        settings: settings,
                        logger: logger,
                        app: app
                    )
                }
                // Bind core models and optionally start scheduler on launch
                app.bind(settings: settings, logger: logger)

                // Once per launch, not per run: at the default 300 s interval the
                // scheduler would otherwise repeat this 288 times a day.
                let friends = FriendsAvailability.current
                if friends.isSpoofed { logger.warn(friends.spoofMessage) }
                if !friends.isSupported { logger.info(friends.restrictionMessage) }

                if settings.autoStartSchedulerOnLaunch { app.start() }
                if settings.openMainOnLaunch { WindowCoordinator.shared?.openMain() }
            }
    }
}

// MARK: - App Entry

@main
@MainActor
struct FindMySyncPlusApp: App {
    private static let menuTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()
    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Core models
    @StateObject private var settings = SettingsStore()
    @StateObject private var logger = LogStore()
    @StateObject private var app = AppModel()

    // Policy + coordination
    @State private var policyController: PolicyController!

    init() {
        // Ensure first-run defaults are registered before any reads
        UserDefaults.standard.register(defaults: [
            "openMainOnLaunch": true
        ])
        let openMainOnLaunch = UserDefaults.standard.bool(forKey: "openMainOnLaunch")
        // Effective menu bar mode: when not opening a window at launch, begin accessory (no Dock)
        let menuBarMode = !openMainOnLaunch
        let initialPolicy: NSApplication.ActivationPolicy = menuBarMode ? .accessory : .regular
        // Create and hold policy controller after NSApp is initialized (safe here in init)
        _policyController = State(initialValue: PolicyController(initial: initialPolicy))
    }

    private var statusBarIcon: NSImage {
        let size = NSSize(width: 32, height: 32)
        let icon = (NSApplication.shared.applicationIconImage?.copy() as? NSImage) ?? NSImage(size: size)
        icon.size = size
        icon.isTemplate = false
        return icon
    }

    private func nsColor(from color: Color) -> NSColor {
        // Attempt to resolve Color to NSColor; fall back to system secondary
        let cgColor = color.resolve(in: .init()).cgColor
        return NSColor(cgColor: cgColor) ?? .secondaryLabelColor
    }

    private func coloredDotImage(color: Color, diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let img = NSImage(size: size)
        img.lockFocusFlipped(false)
        defer { img.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(ovalIn: rect)
        nsColor(from: color).setFill()
        path.fill()

        img.isTemplate = false
        return img
    }

    private func toggleScheduler() {
        if app.isRunning { app.stop() } else { app.start() }
    }

    private var statusTextInMenu: String { app.statusText }
    private var statusColorInMenu: Color { app.statusColor }

    private var nextRunMenuText: String {
        guard let nextRun = app.nextRun else { return "Next: —" }
        return "Next: \(FindMySyncPlusApp.menuTimeFormatter.string(from: nextRun))"
    }

    private var nextRunTooltipText: String {
        guard let nextRun = app.nextRun else { return "No next run scheduled" }
        return "Next scheduled run: \(FindMySyncPlusApp.tooltipDateFormatter.string(from: nextRun))"
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(true)) {
            OpenMainMenuItem()

            Divider()

            Button {
                if app.lastRunHadFatalError {
                    Task { @MainActor in
                        WindowCoordinator.shared?.openMain()
                        NotificationCenter.default.post(name: .navigateToStatus, object: nil)
                    }
                }
            } label: {
                Label {
                    Text(statusTextInMenu)
                        .font(.body)
                        .underline(app.lastRunHadFatalError, color: .primary)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(nsImage: coloredDotImage(color: statusColorInMenu, diameter: 12))
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(app.lastRunHadFatalError)
            .help(app.lastRunHadFatalError ? "Open Status to resolve errors" : "")

            Divider()

            Menu("Scheduler", systemImage: "timer") {
                // Primary actions
                Button {
                    Task { @MainActor in _ = app.runNowIfIdle() }
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(app.isPerformingRun)

                Button {
                    Task { @MainActor in _ = app.runDryIfIdle() }
                } label: {
                    Label("Dry Run", systemImage: "umbrella.fill")
                }
                .disabled(app.isPerformingRun)

                Divider()

                // Start/Stop scheduler (icon only when stopping)
                Button {
                    Task { @MainActor in toggleScheduler() }
                } label: {
                    if app.isRunning {
                        Label("Stop Scheduler", systemImage: "stop.circle")
                    } else {
                        Label("Start Scheduler", systemImage: "play.circle")
                    }
                }
                .disabled(app.isPerformingRun)

                // Next run at the bottom
                if app.isRunning && !app.lastRunHadFatalError {
                    Button {} label: {
                        Label(nextRunMenuText, systemImage: "clock")
                    }
                    .disabled(true)
                    .help(nextRunTooltipText)
                }
            }

            Divider()

            Button { Task { @MainActor in NSApplication.shared.terminate(nil) } } label: { Label("Quit", systemImage: "xmark") }
        } label: {
            Image(nsImage: statusBarIcon)
                .renderingMode(.original)
                .background(
                    InstallCoordinator(policy: policyController, settings: settings, logger: logger, app: app)
                )
        }
        .menuBarExtraStyle(.automatic)
    }
}
