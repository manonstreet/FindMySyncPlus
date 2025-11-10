import AppKit
import SwiftUI

final class DeviceManagerHelpWindowController: NSWindowController {
    static let shared = DeviceManagerHelpWindowController()
    private var windowRef: NSWindow?

    func show() {
        if let w = windowRef {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: DeviceManagerHelpView())
        let w = NSWindow(contentViewController: host)
        w.title = "Device Management Help"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 720, height: 560))
        w.center()
        w.isReleasedWhenClosed = false
        w.titleVisibility = .visible
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.windowRef = w
        self.window = w
    }
}

extension DeviceManagerHelpWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w == windowRef {
            windowRef = nil
        }
    }
}
