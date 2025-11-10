import AppKit
import SwiftUI

struct ToolTipOverlay: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.toolTip = text
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        v.toolTip = text
    }
}
