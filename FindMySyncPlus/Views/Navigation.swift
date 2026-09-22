import SwiftUI
import AppKit

/// The six destinations, in sidebar order. Tracking is the alias list, which had its own
/// window until 1.6b; the name fits Items and Friends as well as Devices (#23).
enum Dest: String, CaseIterable, Hashable {
    case home, status, tracking, access, general, about

    var title: String {
        switch self {
        case .home: "Home"
        case .status: "Status"
        case .tracking: "Tracking"
        case .access: "Access"
        case .general: "General"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .status: "waveform.path.ecg"
        case .tracking: "scope"
        case .access: "key.fill"
        case .general: "gearshape.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The sidebar tile's color, System Settings-style.
    var tint: Color {
        switch self {
        case .home: .blue
        case .status: .green
        case .tracking: .orange
        case .access: .purple
        case .general: .gray
        case .about: .teal
        }
    }
}

/// The main window: a split view with a fixed sidebar, the pane name as the window
/// title, and the pane's actions as toolbar items. The window's own title bar and toolbar
/// draw the chrome, so on macOS 26 and later the toolbar is glass with content scrolling
/// under it, and 14 and 15 draw their plainer toolbar from the same code.
struct RootView: View {
    @State private var selection: Dest = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The Tracking help, a sheet over the main window like Licenses on About.
    /// The state is here, not in the toolbar button: a sheet is attached to the pane.
    @State private var showTrackingHelp = false
    // Deliberately no environment objects here. The app model publishes every second while
    // the scheduler counts down, and a shell that observed it re-rendered on each tick,
    // which kept every scroll view's overlay scroller awake. The few views that need model
    // state observe it themselves.

    private static let sidebarWidth: CGFloat = 190

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            // The pane's scroll view is the detail's top-level content, so it reaches under
            // the toolbar and the OS blurs it there. A stack around it would keep it below.
            pane
                // White under the toolbar too, so content scrolls under it on one ground.
                .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea())
                .navigationTitle(selection.title)
                .toolbar {
                    // On every pane, so the toolbar keeps one height and the sidebar's
                    // header lines up with it: with no items SwiftUI drops the toolbar to a
                    // bare title bar.
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                            }
                        } label: {
                            Label("Hide or show the sidebar", systemImage: "sidebar.leading")
                        }
                        .help("Hide or show the sidebar")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        PaneToolbarActions(selection: selection, showHelp: $showTrackingHelp)
                    }
                }
                .sheet(isPresented: $showTrackingHelp) {
                    TrackingHelpSheet().frame(width: 650, height: 500)
                }
        }
        // Wide enough for the Tracking lists' own 480 pt minimum beside the sidebar.
        .frame(minWidth: 780, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToStatus)) { _ in
            selection = .status
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAccess)) { _ in
            selection = .access
        }
    }

    @ViewBuilder private var pane: some View {
        switch selection {
        case .home:     HomeView()
        case .status:   StatusView()
        case .tracking: TrackingView()
        case .access:   AccessSettingsView()
        case .general:  GeneralSettingsView()
        case .about:    AboutView()
        }
    }
}

/// A real sidebar list, so the OS draws the selection, the material and the collapse: one
/// row per destination, a tinted tile and the name, no section headers. The MQTT light is
/// the footer, and the Full Disk Access pill floats above it while access is missing.
struct Sidebar: View {
    @Binding var selection: Dest

    var body: some View {
        List(selection: Binding<Dest?>(
            get: { selection },
            set: { if let dest = $0 { selection = dest } }
        )) {
            ForEach(Dest.allCases, id: \.self) { dest in
                HStack(spacing: 12) {
                    DestTile(dest: dest)
                    Text(dest.title).font(.title3)
                }
                .padding(.vertical, 4)
                .tag(dest)
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            FullDiskAccessBadge()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooterLight(onTap: { selection = .access })
        }
    }
}

/// The pill shown while Full Disk Access is missing. Its own view, so the sidebar itself
/// does not observe the log store.
private struct FullDiskAccessBadge: View {
    @EnvironmentObject var logger: LogStore

    var body: some View {
        Group {
            if logger.needsFullDiskAccess {
                FullDiskAccessPill()
                    .fixedSize()
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: logger.needsFullDiskAccess)
    }
}

/// The MQTT light as the sidebar's last row. MQTT only; REST has no connection to report.
private struct SidebarFooterLight: View {
    let onTap: () -> Void
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var app: AppModel

    var body: some View {
        if settings.transportMode == .mqtt {
            VStack(spacing: 0) {
                Divider().padding(.horizontal, 10)
                MQTTStatusLight(connected: app.mqttConnected,
                                host: settings.mqttHost,
                                port: settings.mqttPort,
                                onTap: onTap)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
        }
    }
}

/// The pane's actions as toolbar items, icon only, which the OS styles. Status gets Run Now
/// and Dry Run and handles the notifications itself, with its toast when a run is already
/// going. Tracking gets Run Now, straight to the model, because the Unassigned list is
/// built from the last sync, and its help.
private struct PaneToolbarActions: View {
    let selection: Dest
    @Binding var showHelp: Bool
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch selection {
        case .status:
            Button {
                NotificationCenter.default.post(name: .toolbarRunNowRequested, object: nil)
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .help("Run Now")
            .disabled(app.isPerformingRun)
            Button {
                NotificationCenter.default.post(name: .toolbarDryRunRequested, object: nil)
            } label: {
                Label("Dry Run", systemImage: "umbrella.fill")
            }
            .help("Dry Run")
            .disabled(app.isPerformingRun)
        case .tracking:
            Button {
                showHelp = true
            } label: {
                Label("Tracking Help", systemImage: "questionmark.app.fill")
            }
            .help("Tracking Help")
            Button {
                _ = app.runNowIfIdle()
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .help("Run Now")
            .disabled(app.isPerformingRun)
        default:
            EmptyView()
        }
    }
}

/// The Tracking help as a sheet, the shape of the Licenses sheet: the same
/// markdown view over `TRACKING.md`, a Done button, presented at the same size.
private struct TrackingHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TrackingHelpView()
            .navigationTitle("Tracking Help")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}
