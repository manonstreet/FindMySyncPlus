import SwiftUI

/// The Device Manager's modal sheets and its empty state.
///
/// Presented from `DeviceManagerView` through bindings, so none of them reads the list's
/// state directly.
struct AssignAliasSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var assignUUID: String?
    @Binding var assignName: String
    @Binding var assignAlias: String
    var onConfirm: (_ uuid: String, _ name: String, _ alias: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                Text("Assign Device")
            }
            .font(.title3).fontWeight(.semibold)
            Text("Create a new alias for this device. You can manage tracking on the Aliases list.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline) {
                GridRow {
                    Text("Device").fontWeight(.semibold)
                    Text(assignName.isEmpty ? "(Unnamed device)" : assignName)
                }
                GridRow {
                    Text("UUID").fontWeight(.semibold)
                    Text(assignUUID ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Alias").fontWeight(.semibold)
                    TextField("alias", text: $assignAlias)
                        // No live slugify — let the user type freely
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                GridRow {
                    Text("") // spacer
                    Text("Allowed: letters, numbers, hyphen, underscore. Will be normalized on save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    assignUUID = nil
                    dismiss()
                }
                Button("Create") {
                    guard let uuid = assignUUID else { return }
                    // Normalize just once on save, ensuring uniqueness
                    let cleaned = slugifyAlias(assignAlias)
                    onConfirm(uuid, assignName, cleaned)
                    assignUUID = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((assignUUID ?? "").isEmpty || assignAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

struct RenameAliasSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var aliasKey: String?
    @Binding var renameText: String
    var onConfirm: (_ aliasKey: String, _ newAlias: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                Text("Rename Alias")
            }
            .font(.title3).fontWeight(.semibold)
            Text("Renaming creates a new Home Assistant Entity ID.").foregroundStyle(.secondary)
            TextField("alias", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            // Informational, not a warning: this is what renaming does, every time,
            // not something that might go wrong. A sync is what replaces the old
            // entity with the new one, so saying so sets the expectation that the
            // change lands in a moment rather than instantly.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("A sync runs after renaming, so Home Assistant picks up the new entity.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(width: 320, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { aliasKey = nil; dismiss() }
                Button("Rename") {
                    if let key = aliasKey {
                        onConfirm(key, renameText)
                    }
                    aliasKey = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((aliasKey ?? "").isEmpty || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        .multilineTextAlignment(.center)
    }
}
