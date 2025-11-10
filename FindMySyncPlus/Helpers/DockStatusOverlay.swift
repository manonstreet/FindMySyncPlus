import SwiftUI
import AppKit

@MainActor
final class DockStatusOverlay {
    static let shared = DockStatusOverlay()
    private var baseIcon: NSImage? = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
    enum State { case stopped, running, error }

    private final class DockTileView: NSView {
        let base: NSImage
        let state: State

        struct BadgeStyle {
            let backgroundColor: NSColor
            let symbolName: String
            let symbolScale: CGFloat
            let symbolWeight: NSFont.Weight
        }

        var currentStyle: BadgeStyle {
            switch state {
            case .running:
                return BadgeStyle(
                    backgroundColor: .systemGreen,
                    symbolName: "play.fill",
                    symbolScale: 0.58,
                    symbolWeight: .bold
                )
            case .stopped:
                return BadgeStyle(
                    backgroundColor: .systemGray,
                    symbolName: "pause.fill",
                    symbolScale: 0.58,
                    symbolWeight: .bold
                )
            case .error:
                return BadgeStyle(
                    backgroundColor: NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),
                    symbolName: "exclamationmark",
                    symbolScale: 0.72,
                    symbolWeight: .heavy
                )
            }
        }

        init(base: NSImage, state: State, size: CGSize) {
            self.base = base
            self.state = state
            super.init(frame: NSRect(origin: .zero, size: size))
            wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            base.draw(in: bounds)
            let w = bounds.width
            let style = currentStyle

            // Badge metrics — TOP-RIGHT corner
            let overlaySide = w * 0.30
            let pad         = w * 0.06
            let badgeRect   = NSRect(
                x: bounds.maxX - overlaySide - pad,
                y: bounds.maxY - overlaySide - pad,
                width: overlaySide,
                height: overlaySide
            )

            // Badge circle with shadow
            let circle = NSBezierPath(ovalIn: badgeRect)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = max(1, w * 0.035)
            shadow.shadowOffset     = NSSize(width: 0, height: -1)
            shadow.shadowColor      = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            style.backgroundColor.setFill()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Double outline for separation on bright/dark bases
            NSColor.white.withAlphaComponent(0.95).setStroke()
            circle.lineWidth = max(1.5, w * 0.022)
            circle.stroke()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            circle.lineWidth = max(1, w * 0.012)
            circle.stroke()

            // Center the SF Symbol using the style properties
            if let img = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: overlaySide * style.symbolScale, weight: style.symbolWeight)) {
                let s = img.size
                let drawRect = NSRect(
                    x: badgeRect.midX - s.width / 2,
                    y: badgeRect.midY - s.height / 2,
                    width: s.width, height: s.height
                )
                NSColor.white.set()
                img.draw(in: drawRect)
            }
        }
    }

    func update(for state: State) {
        let base = baseIcon ?? NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
        guard let base else { return }

        let tile = NSApp.dockTile
        let view = DockTileView(base: base, state: state, size: tile.size)
        tile.contentView = view
        tile.display() // push redraw
    }

    // Remove the custom Dock content and let the system show the stock icon again.
    func restore() {
        let tile = NSApp.dockTile
        tile.contentView = nil
        tile.display()
    }
}
