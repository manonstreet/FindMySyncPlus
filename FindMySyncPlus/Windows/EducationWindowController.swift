import SwiftUI
import AppKit

@MainActor
final class EducationWindowController: NSWindowController {
    static let shared = EducationWindowController()

    private struct EducationView: View {
        @AppStorage("didSeeMenuBarEducation") private var didSeeEducation: Bool = false
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "menubar.rectangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Still Running in Menu Bar")
                        .font(.title3).bold()
                }
                Text("FindMySync+ keeps running from the menu bar after you close this window. Use the menu bar icon to reopen the app or quit.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Don’t show this again", isOn: $didSeeEducation)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.top, 6)
                HStack { Spacer(); Button("Got it") { dismiss() } .keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    private let host = NSHostingController(rootView: EducationView())

    convenience init() {
        self.init(window: nil)
    }

    override init(window: NSWindow?) {
        let win = NSWindow(contentViewController: host)
        win.title = ""
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func showIfNeeded() {
        let didSee = UserDefaults.standard.bool(forKey: "didSeeMenuBarEducation")
        guard !didSee else { return }
        guard let win = window else { return }
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show() {
        showIfNeeded()
    }
}
