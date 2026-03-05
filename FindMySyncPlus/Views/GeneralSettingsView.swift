import SwiftUI
import AppKit
import Foundation

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var app: AppModel

    @StateObject private var loginItemManager = LoginItemManager()
    
    @State private var intervalMinutes: Int = 5
    @State private var waitSecondsInt: Int = 10

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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                schedulerCard
                findMyCard
                sourcesCard
                deviceManagerCard
            }
            // --- STANDARDIZED LAYOUT ---
            .padding(.horizontal, 18)
            .contentMargins(.top, 8)
            .padding(.top, 8)
            .frame(maxWidth: 610)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: onAppearPopulate)
        .onAppear {
            NotificationCenter.default.post(name: .clearToolbarItems, object: nil)
        }
        .onChange(of: intervalMinutes) { _, newMinutes in
            let clamped = max(Self.minIntervalMinutes, min(newMinutes, Self.maxIntervalMinutes))
            settings.updateIntervalSec = Double(clamped * 60)
            if clamped != newMinutes {
                intervalMinutes = clamped
            }
        }
        .onChange(of: waitSecondsInt) { _, newSeconds in
            let clamped = max(Self.minWaitSeconds, min(newSeconds, Self.maxWaitSeconds))
            settings.findMyWaitSeconds = Double(clamped)
            if clamped != newSeconds {
                waitSecondsInt = clamped
            }
        }
    }

    private var schedulerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Startup & Scheduling")
                        .font(.title3).fontWeight(.semibold)
                        
                    InfoTip(message: "Control open at login, start syncing on app launch, and scheduler run frequency.")
                    Spacer()
                }
                
                SettingsToggleRow(label: "Open at Login", isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { loginItemManager.setLoginItem(enabled: $0, logger: logger) }
                ))
                SettingsToggleRow(label: "Open Main Window on Startup", isOn: $settings.openMainOnLaunch)
                SettingsToggleRow(label: "Auto-start Scheduler", isOn: $settings.autoStartSchedulerOnLaunch)
                
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Update Interval ")
                        .font(.body)
                        + Text("(minutes)").foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    TextField("", value: $intervalMinutes, formatter: Self.intFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)

                    Stepper("", value: $intervalMinutes, in: Self.minIntervalMinutes...Self.maxIntervalMinutes)
                        .labelsHidden()
                }
            }
        }
    }

    private var findMyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Find My Cache Refresh")
                        .font(.title3).fontWeight(.semibold)
                        
                    InfoTip(message: "Launch, wait and terminate Find My so caches update before decryption.")
                    Spacer()
                }

                SettingsToggleRow(label: "Launch Find My before each run", isOn: $settings.autoLaunchKillFindMy)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (Text("Wait ")
                        .font(.body)
                     + Text("(seconds)").foregroundStyle(.secondary))
                        .foregroundStyle(settings.autoLaunchKillFindMy ? .primary : .secondary)

                    Spacer()

                    TextField("", value: $waitSecondsInt, formatter: Self.intFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.autoLaunchKillFindMy)

                    Stepper("", value: $waitSecondsInt, in: Self.minWaitSeconds...Self.maxWaitSeconds)
                        .labelsHidden()
                        .disabled(!settings.autoLaunchKillFindMy)
                }
            }
        }
    }
    
    private var sourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Find My Sources")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Choose which local Find My caches to process.")
                    Spacer()
                }

                VStack(spacing: 10) {
                    SettingsToggleRow(label: "Devices", isOn: $settings.enableDevices, disabled: settings.fmipKeyStatus == .notPresent)
                    SettingsToggleRow(label: "Items", isOn: $settings.enableItems, disabled: settings.fmipKeyStatus == .notPresent)
                    SettingsToggleRow(label: "Friends", isOn: $settings.enableFriends, disabled: settings.localStorageKeyStatus == .notPresent)
                }
                .font(.body)
                .padding(.top, 2)

                if settings.fmipKeyStatus == .notPresent || settings.localStorageKeyStatus == .notPresent {
                    Text("Import keys in Access settings to enable sources")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
        
    private var deviceManagerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Device Management")
                        .font(.title3).fontWeight(.semibold)

                    InfoTip(message: "Apple rotates device UUIDs periodically. These settings control how many\nold UUIDs to keep per alias and whether to automatically add new UUIDs\nwhen device names match.")
                }
                SettingsToggleRow(label: "Auto-learn UUIDs", isOn: $settings.autoLearnUUIDs)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Maximum UUIDs tracked")
                    Spacer()
                    TextField("", value: $settings.maxUUIDsPerAlias, formatter: Self.intFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $settings.maxUUIDsPerAlias, in: 1...5)
                        .labelsHidden()
                }
            }
        }
    }
    
    private func onAppearPopulate() {
        let mins = max(1, Int(settings.updateIntervalSec / 60.0))
        intervalMinutes = mins

        let secs = max(1, Int(settings.findMyWaitSeconds.rounded()))
        waitSecondsInt = secs
    }
}

