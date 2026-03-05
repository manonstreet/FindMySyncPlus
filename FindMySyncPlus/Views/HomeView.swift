import SwiftUI

extension Notification.Name {
    static let navigateToStatus = Notification.Name("NavigateToStatus")
    static let navigateToAccess = Notification.Name("NavigateToAccess")
}


struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    
    @State private var isPulsing: Bool = false
    @State private var uptimeText: String = "—"
    @State private var now = Date()
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    private var statusText: String { app.statusText }
    private var statusColor: Color { app.statusColor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // --- Status Card ---
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { app.isRunning },
                            set: { newVal in newVal ? app.start() : app.stop() }
                        )) {
                            Text("Scheduler").font(.title2).bold()
                        }
                        .toggleStyle(.switch)
                        Divider()
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            statusGridRow
                            GridRow { Text("Last Run").fontWeight(.semibold); Text(app.lastRunText).monospacedDigit() }
                            GridRow { Text("Next Run").fontWeight(.semibold); Text(nextRunDisplayText()).monospacedDigit() }
                        }
                        Divider()
                        HStack(spacing: 12) {
                            Button {
                                _ = app.runNowIfIdle()
                            } label: {
                                Label("Run Now", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .overlay(ToolTipOverlay(text: "One time run without starting Scheduler (⇧⌘R)").allowsHitTesting(false))

                            Button { _ = app.runDryIfIdle() } label: {
                                Label("Dry Run", systemImage: "umbrella.fill")
                                    .symbolRenderingMode(.monochrome)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .overlay(ToolTipOverlay(text: "Evaluate all devices and log what would be sent, without POSTing to Home Assistant (⇧⌘D)").allowsHitTesting(false))
                        }
                        .controlSize(.large)
                        .disabled(app.isPerformingRun)
                    }
                }
                
                // --- Statistics Card ---
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            CardHeader(title: "Statistics", systemImage: "chart.bar.xaxis")
                            Spacer()
                            Button {
                                app.totalRunsCount = 0
                                app.runWarningsCount = 0
                                app.postedUpdatesCount = 0
                                app.learnedUUIDsCount = 0
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .imageScale(.small)
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(8)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Reset counters: Runs, Warning Runs, Posts")
                        }
                        Divider()
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("Uptime").fontWeight(.semibold); Text(uptimeText).monospacedDigit() }
                            GridRow { Text("Successful Runs").fontWeight(.semibold); Text("\(app.totalRunsCount)").monospacedDigit() }
                            GridRow { Text("Warning Runs").fontWeight(.semibold); Text("\(app.runWarningsCount)").monospacedDigit() }
                            GridRow { Text("Posted Updates").fontWeight(.semibold); Text("\(app.postedUpdatesCount)").monospacedDigit() }

                            if settings.autoLearnUUIDs {
                                GridRow { Text("Learned UUIDs").fontWeight(.semibold); Text("\(app.learnedUUIDsCount)").monospacedDigit() }
                            }
                        }
                    }
                }
                
                // --- Configuration Summary Card ---
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "Configuration Summary", systemImage: "gearshape")
                        Divider()
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Auto-start").fontWeight(.semibold)
                                Text(settings.autoStartSchedulerOnLaunch ? "Enabled" : "Disabled")
                                    .foregroundStyle(settings.autoStartSchedulerOnLaunch ? .primary : .secondary)
                            }

                            GridRow {
                                Text("Interval").fontWeight(.semibold)
                                Text("\(Int(settings.updateIntervalSec / 60)) minutes")
                            }

                            GridRow {
                                Text("Find My Refresh").fontWeight(.semibold)
                                Text(
                                    settings.autoLaunchKillFindMy
                                    ? "Enabled (\(Int(max(0, settings.findMyWaitSeconds)))s)"
                                    : "Disabled"
                                )
                                .foregroundStyle(settings.autoLaunchKillFindMy ? .primary : .secondary)
                            }

                            if settings.fmipKeyStatus == .notPresent || settings.fmipKeyStatus == .invalid {
                                GridRow {
                                    Text("Find My Key").fontWeight(.semibold)
                                    switch settings.fmipKeyStatus {
                                    case .notPresent:
                                        Button {
                                            NotificationCenter.default.post(name: .navigateToAccess, object: nil)
                                        } label: {
                                            Text("Not set")
                                                .foregroundStyle(.red)
                                                .underline()
                                        }
                                        .buttonStyle(.link)
                                    case .invalid:
                                        Button {
                                            NotificationCenter.default.post(name: .navigateToAccess, object: nil)
                                        } label: {
                                            Text("Invalid Key")
                                                .foregroundStyle(.red)
                                                .underline()
                                        }
                                        .buttonStyle(.link)
                                    default:
                                        EmptyView() // Not shown due to guard
                                    }
                                }
                            }

                            GridRow {
                                Text("Endpoint").fontWeight(.semibold)
                                if settings.endpointURL.isEmpty {
                                    Button {
                                        NotificationCenter.default.post(name: .navigateToAccess, object: nil)
                                    } label: {
                                        Text("Not set")
                                            .foregroundStyle(.red)
                                            .underline()
                                    }
                                    .buttonStyle(.link)
                                } else {
                                    Text(settings.endpointURL)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.primary)
                                }
                            }
                            
                            if settings.endpointAuthStatus == .notSet || settings.endpointAuthStatus == .invalid {
                                GridRow {
                                    Text("Auth Header").fontWeight(.semibold)
                                    switch settings.endpointAuthStatus {
                                    case .notSet:
                                        Button {
                                            NotificationCenter.default.post(name: .navigateToAccess, object: nil)
                                        } label: {
                                            Text("Not set")
                                                .foregroundStyle(.red)
                                                .underline()
                                        }
                                        .buttonStyle(.link)
                                    case .invalid:
                                        Button {
                                            NotificationCenter.default.post(name: .navigateToAccess, object: nil)
                                        } label: {
                                            Text("Invalid")
                                                .foregroundStyle(.red)
                                                .underline()
                                        }
                                        .buttonStyle(.link)
                                    default:
                                        EmptyView() // Not shown due to guard
                                    }
                                }
                            }

                            GridRow {
                                Text("Aliases Tracked").fontWeight(.semibold)
                                Text("\(settings.aliases.filter { $0.tracked }.count)").monospacedDigit()
                            }
                        }
                    }
                }

                Spacer()
            }
            .contentMargins(.top, 8)
            .padding(.top, 8)
            .padding(.horizontal, 18)
            .frame(maxWidth: 610)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: setupAnimations)
        .onAppear {
            NotificationCenter.default.post(name: .homeViewDidAppear, object: nil)
        }
        .onChange(of: app.isPerformingRun) { setupAnimations() }
        .onReceive(timer) { _ in
            now = Date()
            
            // Update the uptime text
            if let start = app.schedulerStartDate {
                let seconds = max(0, Int(Date().timeIntervalSince(start)))
                let days = seconds / 86_400
                let rem  = seconds % 86_400
                let h = rem / 3_600
                let m = (rem % 3_600) / 60
                let s = rem % 60
                if days > 0 {
                    uptimeText = "\(days)d " + String(format: "%02d:%02d:%02d", h, m, s)
                } else {
                    uptimeText = String(format: "%02d:%02d:%02d", h, m, s)
                }
            } else {
                uptimeText = "—"
            }
        }
    }
    
    private struct CardHeader: View {
        let title: String
        let systemImage: String
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3).bold()
            }
        }
    }

    private var statusGridRow: some View {
        GridRow {
            Text("Status").fontWeight(.semibold)
            HStack(spacing: 8) {
                Circle()
                    .foregroundColor(statusColor)
                    .frame(width: 10, height: 10)
                    .scaleEffect(isPulsing ? 1.4 : 1.0)
                    .opacity(isPulsing ? 0.5 : 1.0)
                
                if app.lastRunHadFatalError {
                    Button {
                        NotificationCenter.default.post(name: .navigateToStatus, object: nil)
                    } label: {
                        Text(statusText)
                            .foregroundStyle(.red)
                            .underline()
                    }
                    .buttonStyle(.link)
                } else {
                    Text(statusText).foregroundStyle(statusColor)
                }
            }
        }
    }

    private func setupAnimations() {
        if app.isPerformingRun {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        } else {
            withAnimation {
                isPulsing = false
            }
        }
    }
    
    private func nextRunDisplayText() -> String {
        if app.lastRunHadFatalError { return app.nextRunText }

        guard app.isRunning, let target = app.nextRun else {
            return app.nextRunText
        }

        let remaining = max(0, Int(target.timeIntervalSince(now)))
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        let s = remaining % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

