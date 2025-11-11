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
    var onDeviceManagerRequested: (() -> Void)?
    
    init(policy: PolicyController) {
        self.policy = policy
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(homeViewDidAppear), name: .homeViewDidAppear, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusViewDidAppear), name: .statusViewDidAppear, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clearToolbarItems), name: .clearToolbarItems, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func registerExternalWindowController(_ controller: NSWindowController) {
        controllers.insert(controller)
    }

    func unregisterExternalWindowController(_ controller: NSWindowController) {
        controllers.remove(controller)
    }

    func activateMainWindow() -> Bool {
        guard let controller = mainWindowController, let win = controller.window else { return false }
        policy.becomeRegular()
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        win.deminiaturize(nil)
        return true
    }

    func showWindow<V: View>(title: String, @ViewBuilder content: () -> V) {
        policy.becomeRegular()

        let hosting = NSHostingController(rootView: AnyView(content()))
        let win = NSWindow(contentViewController: hosting)
        win.title = title
        win.setContentSize(NSSize(width: 800, height: 780))
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.styleMask.insert(.fullSizeContentView)

        // Create a proper toolbar with toggle button
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        win.toolbar = toolbar
        win.toolbarStyle = .unified

        let controller = NSWindowController(window: win)
        self.mainWindowController = controller
        controllers.insert(controller)

        controller.showWindow(nil)
        win.center()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            win.deminiaturize(nil)
        }
    }

    private func currentToolbar() -> NSToolbar? {
        return mainWindowController?.window?.toolbar
    }

    private func setHomeToolbarItems() {
        removeToolbarItems([.runNow, .dryRun])
        
        guard let toolbar = currentToolbar() else { return }
        if !toolbar.items.contains(where: { $0.itemIdentifier == .deviceManager }) {
            toolbar.insertItem(withItemIdentifier: .deviceManager, at: 0)
        }
    }
    
    private func setStatusToolbarItems() {
        guard let toolbar = currentToolbar() else { return }
        
        let needed: [NSToolbarItem.Identifier] = [.runNow, .dryRun, .deviceManager]
        let current = toolbar.items.map { $0.itemIdentifier }
        
        // Add missing items
        var insertIndex = 0
        for id in needed where !current.contains(id) {
            toolbar.insertItem(withItemIdentifier: id, at: insertIndex)
            insertIndex += 1
        }
    }
    
    @objc private func clearToolbarItems() {
        removeToolbarItems([.runNow, .dryRun, .deviceManager])
    }
    
    private func removeToolbarItems(_ identifiers: [NSToolbarItem.Identifier]) {
        guard let toolbar = currentToolbar() else { return }
        for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
            if identifiers.contains(toolbar.items[index].itemIdentifier) {
                toolbar.removeItem(at: index)
            }
        }
    }

    @objc private func homeViewDidAppear() {
        // Delay ensures mainWindowController is set after window initialization completes
        DispatchQueue.main.async { [weak self] in
            self?.setHomeToolbarItems()
        }
    }
    
    @objc private func statusViewDidAppear() {
        DispatchQueue.main.async { [weak self] in
            self?.setStatusToolbarItems()
        }
    }
    
    @objc private func didTapDeviceManager() {
        onDeviceManagerRequested?()
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

private extension NSToolbarItem.Identifier {
    static let runNow = NSToolbarItem.Identifier("RunNow")
    static let dryRun = NSToolbarItem.Identifier("DryRun")
    static let deviceManager = NSToolbarItem.Identifier("DeviceManager")
}

extension Notification.Name {
    static let homeViewDidAppear = Notification.Name("HomeViewDidAppear")
    static let statusViewDidAppear = Notification.Name("StatusViewDidAppear")
    static let toolbarRunNowRequested = Notification.Name("ToolbarRunNowRequested")
    static let toolbarDryRunRequested = Notification.Name("ToolbarDryRunRequested")
    static let clearToolbarItems = Notification.Name("ClearToolbarItems")
}

extension WindowManager: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == .toggleSidebar {
            let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
            item.isBordered = true
            item.target = nil
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        } else if itemIdentifier == .runNow {
            let item = NSToolbarItem(itemIdentifier: .runNow)
            item.label = "Run Now"
            item.paletteLabel = "Run Now"
            item.toolTip = "Run Now"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(didTapRunNow)
            return item
        } else if itemIdentifier == .dryRun {
            let item = NSToolbarItem(itemIdentifier: .dryRun)
            item.label = "Dry Run"
            item.paletteLabel = "Dry Run"
            item.toolTip = "Dry Run"
            item.image = NSImage(systemSymbolName: "umbrella.fill", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(didTapDryRun)
            return item
        } else if itemIdentifier == .deviceManager {
            let item = NSToolbarItem(itemIdentifier: .deviceManager)
            item.label = "Device Manager"
            item.paletteLabel = "Device Manager"
            item.toolTip = "Device Manager"
            item.image = NSImage(systemSymbolName: "rectangle.stack.person.crop", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(didTapDeviceManager)
            return item
        }
        return nil
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .flexibleSpace, .runNow, .dryRun, .deviceManager]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar]
    }

    @objc private func didTapRunNow() {
        NotificationCenter.default.post(name: .toolbarRunNowRequested, object: nil)
    }

    @objc private func didTapDryRun() {
        NotificationCenter.default.post(name: .toolbarDryRunRequested, object: nil)
    }
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
        
        windows.onDeviceManagerRequested = { [weak self] in
            self?.openDeviceManager()
        }
        
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

    func openDeviceManager() {
        // If no primary user windows are open, ensure we remain accessory (no Dock)
        if !windows.hasOpenUserWindows {
            policy.becomeAccessory()
        }
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        if let settings, let app, let logger {
            DevicesWindowController.shared.show(settings: settings, app: app, logger: logger)
        }
    }
    
    func registerExternalWindow(_ controller: NSWindowController) {
        windows.registerExternalWindowController(controller)
    }

    func unregisterExternalWindow(_ controller: NSWindowController) {
        windows.unregisterExternalWindowController(controller)
        // If no user windows remain, return to accessory policy
        if !windows.hasOpenUserWindows {
            policy.becomeAccessory()
        }
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
                if settings.autoStartSchedulerOnLaunch { app.start() }
                if settings.openMainOnLaunch { WindowCoordinator.shared?.openMain() }
            }
    }
}

// MARK: - App Entry

@main
@MainActor
struct FindMySyncPlusApp: App {
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

    private var statusTextInMenu: String {
        if app.lastRunHadFatalError { return "Error" }
        if app.isPerformingRun {
            if app.currentRunMode == .dry { return "Running (dry)" }
            return "Running (\(app.currentRunKind.rawValue))"
        }
        if !app.isRunning { return "Stopped" }
        if app.lastRunHadWarnings { return "Running (with warnings)" }
        return "Running (Idle)"
    }

    private var statusColorInMenu: Color {
        if app.lastRunHadFatalError { return .red }
        if app.isPerformingRun { return .green }
        if app.lastRunHadWarnings { return .orange }
        if app.isRunning { return .green }
        return .secondary
    }
    
    private var nextRunMenuText: String {
        guard let nextRun = app.nextRun else { return "Next: —" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Next: \(formatter.string(from: nextRun))"
    }
    
    private var nextRunTooltipText: String {
        guard let nextRun = app.nextRun else { return "No next run scheduled" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return "Next scheduled run: \(formatter.string(from: nextRun))"
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

            Button {
                Task { @MainActor in
                    WindowCoordinator.shared?.openDeviceManager()
                }
            } label: {
                Label("Device Manager", systemImage: "rectangle.stack.person.crop")
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

