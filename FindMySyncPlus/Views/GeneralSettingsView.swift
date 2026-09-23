import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    @StateObject private var loginItemManager = LoginItemManager()

    /// Whether this macOS provides friend locations at all; decides how the Friends row reads.
    private let friendsAvailability = FriendsAvailability.current

    @State private var intervalMinutes = 5
    @State private var waitSecondsInt = 10

    private static let minIntervalMinutes = 1
    private static let maxIntervalMinutes = 180
    private static let minWaitSeconds = 1
    private static let maxWaitSeconds = 30

    private static let intFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.minimum = 0
        nf.maximumFractionDigits = 0
        return nf
    }()

    private static let metersFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimum = 0
        nf.maximum = 50
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        return nf
    }()

    private var isMQTT: Bool { settings.transportMode == .mqtt }
    private var movementEnabled: Bool { isMQTT && settings.skipRepeatedLocations }

    /// On macOS 14 the LocalStorage key is not needed, so its absence must not prompt the
    /// user to go and import one.
    private var sourcesNeedKeys: Bool {
        settings.fmipKeyStatus == .notPresent
            || (friendsAvailability.isSupported && settings.localStorageKeyStatus == .notPresent)
    }

    var body: some View {
        PaneColumn {
            PaneHero(dest: .general,
                     text: "Control the sync schedule, the Find My sources, and the rules for publishing to Home Assistant.")

            SettingsGroup(title: "Startup & Scheduling",
                          tip: "Control open at login, start syncing on app launch, and scheduler run frequency.") {
                SettingRow(title: "Open at Login") {
                    AppSwitch(isOn: Binding(
                        get: { loginItemManager.isEnabled },
                        set: { loginItemManager.setLoginItem(enabled: $0, logger: logger) }))
                }
                SettingRow(title: "Open Main Window on Startup") {
                    AppSwitch(isOn: $settings.openMainOnLaunch)
                }
                SettingRow(title: "Auto-start Scheduler") {
                    AppSwitch(isOn: $settings.autoStartSchedulerOnLaunch)
                }
                SettingRow(title: "Update Interval", qualifier: "minutes") {
                    numberField($intervalMinutes,
                                range: Self.minIntervalMinutes...Self.maxIntervalMinutes, width: 56)
                }
            }

            SettingsGroup(title: "Find My Cache Refresh",
                          tip: "Launch, wait and terminate Find My so caches update before decryption.") {
                SettingRow(title: "Launch Find My before each run") {
                    AppSwitch(isOn: $settings.autoLaunchKillFindMy)
                }
                SettingRow(title: "Wait", qualifier: "seconds", disabled: !settings.autoLaunchKillFindMy) {
                    numberField($waitSecondsInt, range: Self.minWaitSeconds...Self.maxWaitSeconds, width: 64)
                        .disabled(!settings.autoLaunchKillFindMy)
                }
            }

            SettingsGroup(title: "Home Assistant", tip: """
                Subscribing listens on an MQTT topic to trigger an ad-hoc Find My \
                launch and run a single sync. Useful when combined with disabling \
                Find My before each run to reduce system load.

                Skip repeated locations publishes an entity update only when \
                Find My reports a different location, rather than on every sync. \
                Minimum movement treats near-identical locations as unchanged; at \
                0, only exact coordinate matches are skipped. A skipped entity keeps \
                its last timestamps, so read Sync status for freshness.
                """) {
                SettingRow(title: "Subscribe to sync requests",
                           qualifier: isMQTT ? nil : "MQTT only", disabled: !isMQTT) {
                    AppSwitch(isOn: isMQTT ? $settings.enableRefreshTrigger : .constant(false))
                        .disabled(!isMQTT)
                }
                SettingRow(title: "Skip repeated locations",
                           qualifier: isMQTT ? nil : "MQTT only", disabled: !isMQTT) {
                    AppSwitch(isOn: isMQTT ? $settings.skipRepeatedLocations : .constant(false))
                        .disabled(!isMQTT)
                }
                SettingRow(title: "Minimum movement", qualifier: "meters", disabled: !movementEnabled) {
                    AppNumberField(text: Self.metersFormatter.string(for: settings.minimumMovementMeters) ?? "",
                                   width: 64) {
                        HStack(spacing: 6) {
                            TextField("", value: $settings.minimumMovementMeters, formatter: Self.metersFormatter)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .textFieldStyle(.roundedBorder)
                            Stepper("", value: $settings.minimumMovementMeters, in: 0...50, step: 0.5)
                                .labelsHidden()
                        }
                    }
                    .disabled(!movementEnabled)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup(title: "Find My Sources", tip: "Choose which local Find My caches to process.") {
                    SettingRow(title: "Devices", disabled: settings.fmipKeyStatus == .notPresent) {
                        AppSwitch(isOn: $settings.enableDevices)
                            .disabled(settings.fmipKeyStatus == .notPresent)
                    }
                    SettingRow(title: "Items", disabled: settings.fmipKeyStatus == .notPresent) {
                        AppSwitch(isOn: $settings.enableItems)
                            .disabled(settings.fmipKeyStatus == .notPresent)
                    }
                    // Reads off, because that is what it does. The stored preference is
                    // deliberately left alone: it can legitimately be true on a machine
                    // that was upgraded, and writing false would lose the setting for
                    // anyone who later moves to macOS 15.
                    SettingRow(title: "Friends",
                               qualifier: friendsAvailability.isSupported ? nil : FriendsAvailability.toggleQualifier,
                               disabled: !friendsAvailability.isSupported || settings.localStorageKeyStatus == .notPresent) {
                        AppSwitch(isOn: friendsAvailability.isSupported ? $settings.enableFriends : .constant(false))
                            .disabled(!friendsAvailability.isSupported || settings.localStorageKeyStatus == .notPresent)
                    }
                }
                if sourcesNeedKeys {
                    Text("Import keys in Access settings to enable sources")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
            }

            SettingsGroup(title: "Tracking", tip: """
                Apple rotates device UUIDs periodically. \
                These settings control how many old UUIDs to keep \
                per alias and whether to automatically add new UUIDs \
                when device names match.

                Show new entity count surfaces a badge with the count of \
                newly discovered entities in the sidebar, and opening \
                Tracking clears it. Aliasing an entity prevents it from \
                re-discovery; when Apple rotates its UUID, Auto-learn UUIDs \
                is what carries the alias across.
                """) {
                SettingRow(title: "Auto-learn UUIDs") {
                    AppSwitch(isOn: $settings.autoLearnUUIDs)
                }
                SettingRow(title: "Maximum UUIDs tracked") {
                    AppNumberField(text: "\(settings.maxUUIDsPerAlias)", width: 56) {
                        HStack(spacing: 6) {
                            TextField("", value: $settings.maxUUIDsPerAlias, formatter: Self.intFormatter)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .textFieldStyle(.roundedBorder)
                            Stepper("", value: $settings.maxUUIDsPerAlias, in: 1...5)
                                .labelsHidden()
                        }
                    }
                }
                // Last, so Auto-learn UUIDs and Maximum UUIDs tracked stay adjacent — they
                // are one subject, how much UUID history an alias keeps.
                SettingRow(title: "Show new entity count") {
                    AppSwitch(isOn: $settings.showNewEntityCount)
                }
            }
        }
        .onAppear {
            intervalMinutes = max(Self.minIntervalMinutes, Int(settings.updateIntervalSec / 60.0))
            waitSecondsInt = max(Self.minWaitSeconds, Int(settings.findMyWaitSeconds))
        }
        .onChange(of: intervalMinutes) { _, new in
            let clamped = max(Self.minIntervalMinutes, min(new, Self.maxIntervalMinutes))
            settings.updateIntervalSec = Double(clamped * 60)
            if clamped != new { intervalMinutes = clamped }
        }
        .onChange(of: waitSecondsInt) { _, new in
            let clamped = max(Self.minWaitSeconds, min(new, Self.maxWaitSeconds))
            settings.findMyWaitSeconds = Double(clamped)
            if clamped != new { waitSecondsInt = clamped }
        }
    }

    private func numberField(_ value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat) -> some View {
        AppNumberField(text: "\(value.wrappedValue)", width: width) {
            HStack(spacing: 6) {
                TextField("", value: value, formatter: Self.intFormatter)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: value, in: range)
                    .labelsHidden()
            }
        }
    }
}
