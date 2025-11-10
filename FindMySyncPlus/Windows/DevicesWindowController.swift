import SwiftUI
import AppKit

final class DevicesWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    static let shared = DevicesWindowController()

    // Host view gets swapped on show() to inject env objects each time
    private let host = NSHostingController(rootView: AnyView(EmptyView()))

    // Toolbar identifiers
    private let toolbarID  = NSToolbar.Identifier("DevicesToolbar")
    private let helpItemID = NSToolbarItem.Identifier("DevicesToolbar.Help")

    // Ensure DevicesWindowController() uses our setup path
    convenience init() {
        self.init(window: nil)
    }

    override init(window: NSWindow?) {
        let win = NSWindow(contentViewController: host)
        win.title = "Device Manager"
        win.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 560, height: 560))
        super.init(window: win)

        win.delegate = self

        // AppKit toolbar (robust across close/reopen)
        let tb = NSToolbar(identifier: toolbarID)
        tb.delegate = self
        tb.allowsUserCustomization = false
        tb.displayMode = .iconOnly
        tb.sizeMode = .small
        win.toolbar = tb
        win.toolbarStyle = .unified
        win.toolbar?.isVisible = true
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Public API you already call
    func show(settings: SettingsStore, app: AppModel, logger: LogStore) {
        host.rootView = AnyView(
            DeviceManagerView()
                .environmentObject(settings)
                .environmentObject(app)
                .environmentObject(logger)
        )
        guard let win = window else { return }
        WindowCoordinator.shared?.registerExternalWindow(self)
        if win.toolbar == nil {
            // Defensive: reattach toolbar if it got cleared
            let tb = NSToolbar(identifier: toolbarID)
            tb.delegate = self
            tb.displayMode = .iconAndLabel
            win.toolbar = tb
        }
        win.toolbar?.isVisible = true
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, helpItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, helpItemID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case helpItemID:
            let item = NSToolbarItem(itemIdentifier: helpItemID)
            item.paletteLabel = "Help"
            item.toolTip = "Device Management Help"
            item.image = NSImage(systemSymbolName: "questionmark.app.fill", accessibilityDescription: "Help")
            item.target = self
            item.action = #selector(openHelp)
            item.isBordered = true
            item.visibilityPriority = .high
            return item

        default:
            return nil
        }
    }

    @objc private func openHelp() {
        DeviceManagerHelpWindowController.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            WindowCoordinator.shared?.unregisterExternalWindow(self)
        }
    }
}
