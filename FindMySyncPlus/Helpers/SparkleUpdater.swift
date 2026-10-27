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

    /// Download and install updates with no dialog, relaunching the app. Off unless the user
    /// turns it on, here or with the checkbox on Sparkle's alert; Sparkle stores it.
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
            // Turned on with an update already known: fetch it now rather than at the next
            // scheduled check, which can be a day away.
            if newValue, updateVersion != nil { controller?.updater.checkForUpdatesInBackground() }
        }
    }

    /// Whether a sync run is in progress. An install waits for it rather than cutting a run
    /// off halfway through its publishes. Set at launch.
    var isBusy: @MainActor () -> Bool = { false }

    /// Told when an install starts or ends, so Home Assistant's update entity can show it.
    var onInstallingChanged: (@MainActor () -> Void)?

    @Published private(set) var isInstalling = false

    /// A press of Install in Home Assistant, waiting on Sparkle's background check.
    private var installRequested = false
    private var waitingLogged = false

    /// Set while automatic download is on only for one Install press, so the user's own
    /// choice can be put back — including on the next launch, if the app stopped before it was.
    nonisolated static let temporaryAutoDownloadKey = "updateAutoDownloadForOneInstall"

    func start(logger: LogStore) {
        self.logger = logger
        guard !ReadRoot.isDemo else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        if UserDefaults.standard.bool(forKey: Self.temporaryAutoDownloadKey) {
            restoreTemporaryAutoDownload()
            logger.info("Update: automatic installs set back to off after an install request "
                        + "that did not finish")
        }
        // Nothing is assigned here. automaticallyChecksForUpdates, updateCheckInterval and
        // automaticallyDownloadsUpdates all persist in the app's defaults, and SPUUpdater.h
        // says setting them on launch ignores whatever the user chose — including from the
        // checkbox on Sparkle's own alert. Info.plist supplies the first-run values.

        let override = UserDefaults.standard.string(forKey: "updateFeedOverride") ?? ""
        if Self.usableFeedOverride(override) != nil {
            logger.warn("Update feed overridden: \(override)")
        } else if !override.isEmpty {
            logger.warn("Update feed override ignored, it is not https: \(override)")
        }

        // A probing check, straight after starting the updater, which is one of the three
        // calls the header sanctions at this point. It reports through the delegate and puts
        // nothing on screen, so the arrow is up to date from launch while Sparkle's schedule
        // still owns the alert. Skipped versions are not reported, so Skip This Version
        // quiets the arrow too.
        //
        // With automatic installs on it is the background check instead, which downloads and
        // hands the update over. Either check counts as the scheduled one and moves the next
        // a full interval out, so a probe here would hold an install back for a day.
        if controller?.updater.automaticallyChecksForUpdates == true {
            if controller?.updater.automaticallyDownloadsUpdates == true {
                controller?.updater.checkForUpdatesInBackground()
            } else {
                controller?.updater.checkForUpdateInformation()
            }
        }
    }

    /// Sparkle's dialog, with Install. Raised only when the user asks — from the menu line,
    /// from Check Now, or from About's Install Update button.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Home Assistant's Install button. The press is the user's consent for this one update,
    /// so it works whether or not automatic installs are on: Sparkle only hands over an update
    /// it downloaded itself, so automatic download is turned on for this check if it was off,
    /// and put back as soon as the check answers.
    func requestInstall() {
        guard let updater = controller?.updater else {
            logger?.info("Install requested, but the updater is not running")
            return
        }
        guard !installRequested, !isInstalling else {
            logger?.info("Install requested: one is already under way")
            return
        }
        installRequested = true
        setInstalling(true)
        if !updater.automaticallyDownloadsUpdates {
            UserDefaults.standard.set(true, forKey: Self.temporaryAutoDownloadKey)
            updater.automaticallyDownloadsUpdates = true
        }
        logger?.info("Install requested: checking for an update")
        updater.checkForUpdatesInBackground()
    }

    /// The request ended without an install: nothing newer, or the check failed.
    private func endInstallRequest(_ message: String) {
        guard installRequested else { return }
        installRequested = false
        restoreTemporaryAutoDownload()
        setInstalling(false)
        logger?.info(message)
    }

    private func restoreTemporaryAutoDownload() {
        guard UserDefaults.standard.bool(forKey: Self.temporaryAutoDownloadKey) else { return }
        controller?.updater.automaticallyDownloadsUpdates = false
        UserDefaults.standard.removeObject(forKey: Self.temporaryAutoDownloadKey)
    }

    /// Run Sparkle's handler — install and relaunch, no dialog — once no sync is running.
    private func install(_ handler: @escaping () -> Void, version: String) {
        setInstalling(true)
        if isBusy() {
            if !waitingLogged {
                logger?.info("Update: \(version) will install when the sync run finishes")
                waitingLogged = true
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.install(handler, version: version)
            }
            return
        }
        logger?.info("Update: installing \(version) and relaunching")
        handler()
    }

    private func setInstalling(_ value: Bool) {
        guard isInstalling != value else { return }
        isInstalling = value
        onInstallingChanged?()
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
        Self.usableFeedOverride(UserDefaults.standard.string(forKey: "updateFeedOverride") ?? "")
    }

    /// The override when it is an https URL, else `nil`. EdDSA still guards the archive over
    /// http, but the release notes Sparkle shows would come from whoever answered.
    nonisolated static func usableFeedOverride(_ value: String) -> String? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return value
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
            self?.endInstallRequest("Install requested: already up to date")
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
            self?.endInstallRequest("Install requested: the update failed — \(message)")
        }
    }

    /// Sparkle downloaded an update by itself and would install it when the app quits. Taking
    /// it — returning true — installs it now instead, with no dialog, but only when the user
    /// asked: automatic installs are on, or Install was pressed in Home Assistant. Otherwise
    /// Sparkle keeps its install-on-quit.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let handler = immediateInstallHandler
        return MainActor.assumeIsolated {
            let temporary = UserDefaults.standard.bool(forKey: Self.temporaryAutoDownloadKey)
            let optedIn = (controller?.updater.automaticallyDownloadsUpdates ?? false) && !temporary
            guard installRequested || optedIn else { return false }
            installRequested = false
            restoreTemporaryAutoDownload()
            logger?.info("Update: \(version) downloaded")
            install(handler, version: version)
            return true
        }
    }
}
