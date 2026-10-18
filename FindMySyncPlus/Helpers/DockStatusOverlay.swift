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

        // Running has no badge: `update(for:)` hands the tile back to the system instead.
        // Stopped is the circuit tree's blue, so the badge belongs to the icon; error is red.
        var currentStyle: BadgeStyle {
            switch state {
            case .running, .stopped:
                return BadgeStyle(
                    backgroundColor: NSColor(srgbRed: 0.008, green: 0.533, blue: 0.820, alpha: 1.0),
                    symbolName: "pause.fill",
                    symbolScale: 0.44,
                    symbolWeight: .bold
                )
            case .error:
                return BadgeStyle(
                    // The system badge's red, matched beside Messages in Display P3 screenshots.
                    // In P3 because sRGB cannot reach it, and a little brighter than measured,
                    // because the Dock dims a drawn tile by a few percent and not its own badge.
                    backgroundColor: NSColor(displayP3Red: 0.941, green: 0.302, blue: 0.231, alpha: 1.0),
                    symbolName: "exclamationmark",
                    symbolScale: 0.56,
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

            // Badge metrics: the size and place of the system's own Dock badge, measured from
            // a screenshot beside Messages. The visible icon spans the middle 80% of the tile,
            // and the system badge is 48% of that, centered 87% across and 12% down it.
            let overlaySide = w * 0.385
            let center      = NSPoint(x: w * 0.796, y: bounds.maxY - w * 0.196)
            let badgeRect   = NSRect(
                x: center.x - overlaySide / 2,
                y: center.y - overlaySide / 2,
                width: overlaySide,
                height: overlaySide
            )

            // The shadow falls only outside the disc: under a 90% disc, the part beneath it
            // showed through and dimmed the badge. An opaque fill casts it, clipped away.
            let circle = NSBezierPath(ovalIn: badgeRect)
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: bounds)
            outside.append(circle)
            outside.windingRule = .evenOdd
            outside.addClip()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = max(1, w * 0.035)
            shadow.shadowOffset     = NSSize(width: 0, height: -1)
            shadow.shadowColor      = NSColor.black.withAlphaComponent(0.25)
            shadow.set()
            NSColor.black.setFill()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()

            // 90% opaque, like the system badge, which lets a little of the icon through.
            style.backgroundColor.withAlphaComponent(0.9).setFill()
            circle.fill()

            // The symbol's color comes from its configuration: drawing a symbol image after
            // setting a color does not tint it.
            let config = NSImage.SymbolConfiguration(pointSize: overlaySide * style.symbolScale,
                                                     weight: style.symbolWeight)
                .applying(.init(paletteColors: [.white]))
            if let img = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = img.size
                let drawRect = NSRect(
                    x: badgeRect.midX - s.width / 2,
                    y: badgeRect.midY - s.height / 2,
                    width: s.width, height: s.height
                )
                img.draw(in: drawRect)
            }
        }
    }

    func update(for state: State) {
        // Running is the normal state and carries no badge. Handing the tile back to the system
        // also lets macOS draw the icon itself, with its glass and its dark and tinted variants.
        if state == .running {
            restore()
            return
        }
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
