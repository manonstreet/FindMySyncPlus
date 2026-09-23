import Foundation
import SwiftUI
import Sparkle

/// Asks the appcast whether a newer build exists, and installs one when asked to.
///
/// Sparkle does the scheduling. It persists `automaticallyChecksForUpdates`,
/// `updateCheckInterval` and the last-check date in the app's own defaults and checks when
/// the interval has elapsed, which a hand-rolled loop cannot match: a loop restarts with the
/// process, so anyone who quits and relaunches often would never reach a scheduled check.
/// `SUEnableAutomaticChecks` and `SUScheduledCheckInterval` in Info.plist set the starting
/// values; the header is explicit that the properties should not be assigned on every launch
/// or the stored preference is ignored.
///
/// What this class adds is the quiet signal. Sparkle's own alert is the loud path; the
/// delegate below turns the same events into `state`, which draws the arrow on the status
/// item and the Update Available line in the menu, so a user who dismisses the alert still
/// has something to come back to.
///
/// A demo session never starts the updater. The harness compares logs against stored
/// baselines, and anything that reaches the network during a render writes the state of the
/// world into them.
@MainActor
final class SparkleUpdater: NSObject, ObservableObject {

    enum State: Equatable {
        case never
        case checking
        case current
        case available(version: String)
        /// Shown to the user, so it names what failed rather than the error type.
        case failed(String)
    }

    @Published private(set) var state: State = .never
    @Published private(set) var lastChecked: Date?

    /// Newer than the running version, so the menu and the status item can ask one question.
    var updateVersion: String? {
        if case let .available(version) = state { return version }
        return nil
    }

    /// What Home Assistant's `update` entity should publish as `latest_version`.
    ///
    /// `nil` for every state that has no answer yet, which Home Assistant reads as unknown
    /// rather than as "up to date" — `UpdateEntity.state` returns `None` when either version
    /// is `None`. Claiming the installed version while a check is running or has failed would
    /// read as up to date and be a lie.
    ///
    /// `.current` reports the installed version, because equal versions are how Home
    /// Assistant expresses up to date.
    ///
    /// Pure and static so the mapping is testable without an updater, which a test cannot
    /// build in a state of its choosing.
    nonisolated static func latestVersion(for state: State, installed: String) -> String? {
        switch state {
        case .available(let version): version
        case .current: installed
        case .never, .checking, .failed: nil
        }
    }

    private var controller: SPUStandardUpdaterController?
    private weak var logger: LogStore?

    /// The user's preference, which Sparkle stores. Kept here rather than in `SettingsStore`
    /// because Sparkle persists it itself and a second copy is what drifts.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func start(logger: LogStore) {
        self.logger = logger
        guard !ReadRoot.isDemo else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // Nothing is assigned here. automaticallyChecksForUpdates, updateCheckInterval and
        // automaticallyDownloadsUpdates all persist in the app's defaults, and SPUUpdater.h
        // says setting them on launch ignores whatever the user chose — including from the
        // checkbox on Sparkle's own alert. Info.plist supplies the first-run values.

        let override = UserDefaults.standard.string(forKey: "updateFeedOverride") ?? ""
        if !override.isEmpty {
            logger.warn("Update feed overridden: \(override)")
        }

        // A probing check, straight after starting the updater, which is one of the three
        // calls the header sanctions at this point. It reports through the delegate and puts
        // nothing on screen, so the arrow is up to date from launch while Sparkle's schedule
        // still owns the alert. Skipped versions are not reported, so Skip This Version
        // quiets the arrow too.
        if controller?.updater.automaticallyChecksForUpdates == true {
            controller?.updater.checkForUpdateInformation()
        }
    }

    /// Sparkle's dialog, with Install. Raised only when the user asks — from the menu line,
    /// from Check Now, or from About's Install Update button.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func finish(_ newState: State, log: String, level: LogLevel) {
        state = newState
        lastChecked = Date()
        logger?.log(level, log)
    }
}

// Sparkle calls these on the main thread but declares them without isolation, so each hops
// back explicitly rather than assuming.
extension SparkleUpdater: SPUUpdaterDelegate {

    /// A feed to check instead of the one in Info.plist, for exercising the updater without
    /// publishing anything. Inert unless the key is set, the same contract as `demoRoot`:
    ///
    ///     defaults write com.manonstreet.FindMySyncPlus updateFeedOverride \
    ///         https://manonstreet.github.io/FindMySyncPlus/appcast-staging.xml
    ///
    /// This is what makes a staging run worth something — the binary doing the updating is
    /// the one that ships, rather than a differently-built cousin. Redirecting the feed does
    /// not weaken the update itself: every archive is still checked against the EdDSA public
    /// key compiled into the app, so a feed nobody signed for cannot deliver anything.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let override = UserDefaults.standard.string(forKey: "updateFeedOverride") ?? ""
        return override.isEmpty ? nil : override
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.finish(.available(version: version),
                         log: "Update check: \(version) is available", level: .info)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            self?.finish(.current, log: "Update check: up to date", level: .debug)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "no update found" as an abort as well, which is not a failure.
        let nsError = error as NSError
        guard nsError.code != Int(Sparkle.SUError.noUpdateError.rawValue) else { return }
        let message = nsError.localizedDescription
        Task { @MainActor [weak self] in
            self?.finish(.failed("Could not check for updates"),
                         log: "Update check: \(message)", level: .debug)
        }
    }
}
