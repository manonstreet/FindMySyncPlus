import SwiftUI
import AppKit

// The grouped-form vocabulary the settings panes are built from: a flat card, a label
// floating above it, rows with separators, a pane's hero, and the column they sit in.
// Everything here is drawn with plain shapes, so `ImageRenderer` draws it as the window does.

enum PaneLayout {
    /// Forms cap and center; lists fill. Home, Access, General and About stop here and sit
    /// centered, which reads as deliberate at any width, sidebar shown or hidden. Status and
    /// Tracking take the whole column, as lists do on macOS.
    static let formMaxWidth: CGFloat = 800
}

/// The flat card fill: a shade off the pane, no stroke, no shadow. The hero, the cards and
/// the row groups all sit on it.
struct FlatFill: View {
    static let cornerRadius: CGFloat = 10
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
    }
}

/// A group label floating above its card, with the tip beside it. Inset to the card's edge.
struct FloatingLabel: View {
    let title: String
    var tip: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.title3).fontWeight(.semibold)
            if let tip { InfoTip(message: tip) }
            Spacer()
        }
        .padding(.horizontal, 20)
    }
}

/// The System Settings-style tinted tile: the glyph in white on a rounded square of the
/// destination's color. 28 pt in the sidebar; the hero uses it at 64.
struct DestTile: View {
    let dest: Dest
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: dest.systemImage)
            .font(.system(size: size * 0.54, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(dest.tint))
    }
}

/// The pane opened with its icon, name and one line, on a flat card. General and Access
/// only: the lists need the height, Home is a dashboard, and About leads with the app icon.
struct PaneHero: View {
    let dest: Dest
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            DestTile(dest: dest, size: 64)
                .padding(.bottom, 10)
            Text(dest.title).font(.largeTitle.weight(.bold))
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .background(FlatFill())
        .padding(.horizontal, 18)
    }
}

/// A title with an optional gray qualifier, a description beneath if there is one, and the
/// control at its intrinsic width on the trailing edge. Rows are separated by a line drawn
/// a point above each row's own top edge, so the first row's lies outside its group and
/// the group's clip removes it; callers mark nothing.
struct SettingRow<Control: View>: View {
    let title: String
    var description: String?
    /// A gray parenthetical after the title, for a unit or a reason the row is off:
    /// "Update Interval (minutes)", "Friends (Needs macOS 15)".
    var qualifier: String?
    var disabled = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .foregroundStyle(disabled ? .secondary : .primary)
                    if let qualifier {
                        Text("(\(qualifier))")
                            .foregroundStyle(.secondary)
                    }
                }
                if let description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control.fixedSize()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .offset(y: -1)
        }
    }
}

/// A group of rows: the label above, the rows flush to a flat card.
struct SettingsGroup<Content: View>: View {
    let title: String
    var tip: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FloatingLabel(title: title, tip: tip)
            VStack(spacing: 0) { content }
                .background(FlatFill())
                .clipShape(RoundedRectangle(cornerRadius: FlatFill.cornerRadius, style: .continuous))
                .padding(.horizontal, 18)
        }
    }
}

/// A card with its title floating above it and the tip beside the title, for content that
/// is not rows: fields, a segmented control, a status line with a button.
struct TitledCard<Content: View>: View {
    let title: String
    var tip: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FloatingLabel(title: title, tip: tip)
            Card { content }
        }
    }
}

/// The column a form pane's groups sit in: capped, centered, room below the last group.
struct PaneColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        AppScroll {
            // The label above each group is what separates it from the card before, so
            // the groups need more room between them than cards did.
            VStack(spacing: 22) { content }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: PaneLayout.formMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

extension View {
    /// A bordered box on the flat card, for a dashboard grid, so the values read as a table.
    @MainActor func innerBox() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
