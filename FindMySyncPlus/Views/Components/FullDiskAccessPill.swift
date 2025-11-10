import SwiftUI
import AppKit

extension NSWorkspace {
    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            open(url)
        }
    }
}

struct FullDiskAccessPill: View {
    var body: some View {
        Button {
            NSWorkspace.shared.openFullDiskAccess()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.black)
                Text("Full Disk Access required")
                    .foregroundColor(.black)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.yellow)
                    .overlay(Capsule().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .help("Open Privacy → Full Disk Access")
    }
}
