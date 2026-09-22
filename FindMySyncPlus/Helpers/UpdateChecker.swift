import Foundation
import SwiftUI
import AppKit

/// Asks the project's Releases page whether a newer version exists, and says so. It does not
/// download or install anything.
///
/// The bundle's `CFBundleShortVersionString` is compared to the latest release's `tag_name`.
/// Nothing else about the release is used, so a draft or a renamed asset cannot confuse it.
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case never
        case checking
        case current
        case available(version: String, url: URL)
        /// The message is shown to the user, so it names what failed rather than the error type.
        case failed(String)
    }

    @Published private(set) var state: State = .never
    @Published private(set) var lastChecked: Date?

    /// Newer than the running version, so the menu and the status item can ask one question.
    var updateVersion: String? {
        if case let .available(version, _) = state { return version }
        return nil
    }

    private let endpoint = URL(string: "https://api.github.com/repos/manonstreet/FindMySyncPlus/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/manonstreet/FindMySyncPlus/releases/latest")!
    private weak var logger: LogStore?
    private weak var settings: SettingsStore?
    private var loop: Task<Void, Never>?

    /// A day between automatic checks. A menu bar agent runs for weeks, so launch alone
    /// would leave a long-running copy never asking again.
    private static let interval: TimeInterval = 24 * 60 * 60

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The setting is read each time round rather than captured, so switching it off stops
    /// the next check instead of only the next launch.
    ///
    /// A demo session never checks. It reads fixtures rather than a real install, its logs
    /// are compared against stored baselines, and a line naming whatever GitHub tagged most
    /// recently would differ on every run.
    func start(logger: LogStore, settings: SettingsStore) {
        self.logger = logger
        self.settings = settings
        guard !ReadRoot.isDemo else { return }
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings?.autoCheckForUpdates == true {
                    await self.check(manual: false)
                }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func openReleasePage() {
        if case let .available(_, url) = state {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(releasesPage)
        }
    }

    /// `manual` only changes the log level: a check the user asked for is worth an info line,
    /// a background one is not.
    func check(manual: Bool) async {
        // Guarded here rather than only at start: one render session in ten beat the
        // launch-time check and put a live tag into its log baseline.
        guard manual || !ReadRoot.isDemo else { return }
        state = .checking
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        // GitHub rejects requests without one, and the header names this app rather than
        // whatever URLSession would send.
        request.setValue("FindMySyncPlus/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                finish(.failed("GitHub returned \(http.statusCode)"),
                       log: "Update check: GitHub returned \(http.statusCode)", level: .warn)
                return
            }
            guard let tag = try? JSONDecoder().decode(Release.self, from: data).tag_name else {
                finish(.failed("Could not read the latest release"),
                       log: "Update check: the response carried no tag_name", level: .warn)
                return
            }
            let newer = Self.isNewer(tag, than: currentVersion)
            // The raw tag beside the verdict: a comparison that goes wrong is unreadable
            // from the verdict alone.
            let line = "Update check: latest tag \(tag), running \(currentVersion) — "
                + (newer ? "update available" : "up to date")
            if newer {
                finish(.available(version: Self.displayVersion(tag), url: releasesPage),
                       log: line, level: .info)
            } else {
                finish(.current, log: line, level: manual ? .info : .debug)
            }
        } catch {
            finish(.failed("Could not reach GitHub"),
                   log: "Update check: \(error.localizedDescription)", level: manual ? .warn : .debug)
        }
    }

    private func finish(_ newState: State, log: String, level: LogLevel) {
        state = newState
        lastChecked = Date()
        logger?.log(level, log)
    }

    private struct Release: Decodable { let tag_name: String? }

    // MARK: - Version comparison

    /// The tag with any leading `v` removed, which is how the app states its own version.
    nonisolated static func displayVersion(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Whether `tag` names a version after `current`.
    ///
    /// Releases are `v1.4.7b`, `v1.5b`, `v1.6b`: dot-separated numbers with a suffix letter
    /// that every version carries, so only the numbers decide. A component that parses to
    /// nothing makes the comparison say no, because shipping an update prompt on a tag
    /// nobody can read is worse than missing one.
    nonisolated static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let candidate = components(displayVersion(tag)),
              let running = components(current) else { return false }
        for index in 0..<max(candidate.count, running.count) {
            let lhs = index < candidate.count ? candidate[index] : 0
            let rhs = index < running.count ? running[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    nonisolated private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        return numbers
    }
}
