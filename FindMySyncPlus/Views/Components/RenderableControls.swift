import SwiftUI
import AppKit

// Controls with a drawn stand-in while rendering, the sibling of `RenderableContainers`.
//
// `ImageRenderer` draws AppKit-backed controls as a placeholder, which hides exactly what a
// pane render is read for: where a switch or a field sits and how wide it is. These use
// the real control normally and a drawn likeness while a snapshot is being taken.

/// A switch at the mini size, the one the grouped rows use.
struct AppSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        substituting({
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }, whileRendering: {
            // The small switch measured about 44 by 26 points on macOS 27. The mini one is
            // drawn at that scaled by the small-to-mini ratio of the older sizes, and has
            // not been measured; see plans/1.6b-ux-refresh.md.
            let scale: CGFloat = 0.82
            return ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 44 * scale, height: 26 * scale)
                Circle().fill(.white)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .padding(2)
            }
        })
    }
}

/// A number field with its stepper, at the small size. `real` is the live pair; the
/// likeness shows `text` at `width`.
struct AppNumberField<Real: View>: View {
    let text: String
    let width: CGFloat
    @ViewBuilder let real: Real
    var body: some View {
        substituting({ real.controlSize(.small) }, whileRendering: {
            HStack(spacing: 6) {
                Text(text)
                    .font(.callout)
                    .frame(width: width - 12, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                VStack(spacing: 0) {
                    Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .frame(width: 15, height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            }
        })
    }
}

/// A bordered or prominent button at the small size.
struct AppButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    var disabled = false
    let action: () -> Void

    @ViewBuilder private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }

    var body: some View {
        substituting({
            Group {
                if prominent {
                    Button(action: action) { label }.buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) { label }.buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .disabled(disabled)
        }, whileRendering: {
            label
                .font(.body)
                .foregroundStyle(prominent ? Color.white : (disabled ? Color.secondary : Color.primary))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(prominent ? 0 : 0.35), lineWidth: 1))
        })
    }
}

/// A link-styled button.
struct AppLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        substituting({
            Button(title, action: action).buttonStyle(.link)
        }, whileRendering: {
            Text(title).foregroundStyle(Color.accentColor)
        })
    }
}
