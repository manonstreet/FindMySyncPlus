import SwiftUI
import AppKit
import Foundation

struct AboutView: View {
    @State private var showLicenses = false
    
    private var appIcon: Image {
        Image(nsImage: NSApplication.shared.applicationIconImage)
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    // Subtle card used for sections to match app styling
    private struct InfoCard<Content: View>: View {
        let content: Content
        init(@ViewBuilder content: () -> Content) { self.content = content() }
        var body: some View {
            content
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private struct CreditLink: View {
        let title: String
        let author: String
        let url: String
        let description: String

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "link")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4) // align with title baseline

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let destination = URL(string: url) {
                            Link(title, destination: destination)
                                .font(.headline)
                        } else {
                            Text(title)
                                .font(.headline)
                        }
                        Text("by \(author)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                NotificationCenter.default.post(name: .clearToolbarItems, object: nil)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    appIcon
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("FindMySync+")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(versionString)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    
                    Button("Third-Party Notices") { showLicenses = true }
                        .buttonStyle(.link)

                    Text("A macOS utility to decrypt the local Find My cache and post device locations to a Home Assistant endpoint.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Divider()

                Text("Author")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    Image("logo-grayscale")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 250, height: 250)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                }
                .frame(maxWidth: .infinity)

                Divider()

                Text("Acknowledgments")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)

                InfoCard {
                    VStack(alignment: .leading, spacing: 18) {
                        CreditLink(
                            title: "FindMySync",
                            author: "Martin Pham",
                            url: "https://github.com/MartinPham/FindMySync",
                            description: "The original application, icon, and conceptual inspiration for this project's core functionality."
                        )
                        CreditLink(
                            title: "findmy-cache-decryptor",
                            author: "Pnut-GGG",
                            url: "https://github.com/Pnut-GGG/findmy-cache-decryptor",
                            description: "Provided the reverse-engineered methodology for decrypting the Find My cache files in newer versions of MacOS."
                        )
                        CreditLink(
                            title: "FMIPDataManager-extractor",
                            author: "Pnut-GGG",
                            url: "https://github.com/Pnut-GGG/FMIPDataManager-extractor",
                            description: "The original method for extracting FMIP decryption keys from the macOS Keychain."
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .contentMargins(.top, 0)
            .padding(.top, 0)
            .padding(24)
            .frame(maxWidth: 610)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .sheet(isPresented: $showLicenses) {
            LicensesView()
                .frame(width: 650, height: 500)
        }
    }
}
