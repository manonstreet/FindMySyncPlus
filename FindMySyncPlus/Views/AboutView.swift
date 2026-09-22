import SwiftUI
import AppKit
import Foundation

struct AboutView: View {
    /// The license whose text the Licenses sheet opens at; the sheet is up while it is set.
    @State private var licenseShown: ShippedLicense?

    /// `Version 1.5b (0423d49)`.
    ///
    /// The commit in preference to `CFBundleVersion`, which has read a hardcoded 1 since
    /// the project was created and so answered nothing. `build.sh` passes `GIT_COMMIT` and
    /// Info.plist substitutes it; a build that does not pass one leaves the key empty and
    /// this falls back to the build number rather than showing a gap.
    ///
    /// **Not a build phase, deliberately.** A script reading `git` cannot work here:
    /// `ENABLE_USER_SCRIPT_SANDBOXING` is on, and in a worktree the real git directory sits
    /// outside `SRCROOT` entirely. Turning that off for a version string is not a trade
    /// worth making, so the value is passed in instead.
    ///
    /// A trailing `+` means the tree had uncommitted changes when it was built, which is
    /// the difference between "you are running this commit" and "you are running something
    /// like it". That question came up repeatedly while testing and neither of us could
    /// answer it from the app.
    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "—"
        let commit = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String
        let stamped = (commit?.isEmpty == false) ? commit : nil
        return "Version \(short) (\(stamped ?? build))"
    }

    private struct CreditLink: View {
        let title: String
        let author: String
        let url: String
        let description: String
        /// The license whose text the app ships, opening the Licenses sheet at it. Absent for
        /// the research the app draws on without shipping its code.
        var license: ShippedLicense?
        /// The link's text, where the license name alone would mislead: the GPL covers the
        /// icon, not the app.
        var licenseLabel: String?
        var onLicense: (ShippedLicense) -> Void = { _ in }

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
                    if let license {
                        AppLink(title: licenseLabel ?? license.licenseName) { onLicense(license) }
                            .font(.callout)
                    }
                }
            }
        }
    }

    var body: some View {
        PaneColumn {
            AppHero(title: "FindMySync+",
                    subtitle: versionString,
                    text: "Decrypts the local Find My cache and publishes device, item and "
                        + "friend locations to Home Assistant.")
            authorSection
            acknowledgments
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { utilityBar }
        .sheet(item: $licenseShown) { license in
            LicensesView(showing: license)
                .frame(width: 650, height: 500)
        }
    }

    /// The artwork at a size worth looking at, with the credit line beside it. No card
    /// behind it: the PNG is opaque and its own background is 242,243,242, which is the
    /// card fill, so a card would swallow its edge. The rounded clip and shadow are what
    /// separate it from the pane.
    private var authorSection: some View {
        HStack(alignment: .center, spacing: 22) {
                Image("logo-grayscale")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Author").font(.title2).fontWeight(.semibold)
                    Text("I am an information security professional and Home Assistant enthusiast "
                         + "who values privacy. I built this app for me, hopefully you find it useful too.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
        }
        // Matches the cards' outer inset, so the artwork's left edge lines up with theirs.
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    /// What the app is built on and what it ships: the sources it draws on, and the two
    /// libraries. These five entries are the third-party notices, and the license texts are
    /// in the Licenses sheet; `Docs/THIRD-PARTY-NOTICES.md` is in the bundle but unused.
    private var acknowledgments: some View {
        TitledCard(title: "Acknowledgments") {
            VStack(alignment: .leading, spacing: 18) {
                CreditLink(
                    title: "FindMySync",
                    author: "Martin Pham",
                    url: "https://github.com/MartinPham/FindMySync",
                    description: "The original application, icon, and conceptual inspiration for this project's "
                        + "core functionality. The icon is used with a plus added.",
                    license: .findMySyncIcon,
                    licenseLabel: "Icon license: GNU General Public License 3.0",
                    onLicense: { licenseShown = $0 }
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
                CreditLink(
                    title: "CocoaMQTT",
                    author: "emqx",
                    url: "https://github.com/emqx/CocoaMQTT",
                    description: "The MQTT client.",
                    license: .cocoaMQTT,
                    onLicense: { licenseShown = $0 }
                )
                CreditLink(
                    title: "Ink",
                    author: "John Sundell",
                    url: "https://github.com/JohnSundell/Ink",
                    description: "The Markdown parser behind the help.",
                    license: .ink,
                    onLicense: { licenseShown = $0 }
                )
            }
        }
    }

    /// The links, trailing. About only. The same height as the sidebar's footer, so the two
    /// dividers meet: 6 pt of padding, the light's own 5 pt, and its caption line.
    private var utilityBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 18) {
                Spacer()
                AppLink(title: "GitHub") { open("https://github.com/manonstreet/FindMySyncPlus") }
                AppLink(title: "Changelog") { open("https://github.com/manonstreet/FindMySyncPlus/blob/HEAD/CHANGELOG.md") }
                AppLink(title: "Report a Bug") { open("https://github.com/manonstreet/FindMySyncPlus/issues") }
            }
            .font(.callout)
            .padding(.horizontal, 22)
            .frame(height: 35)
        }
        .background(.bar)
    }

    private func open(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}
