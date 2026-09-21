import SwiftUI
import AppKit

/// The six destinations, in sidebar order. Tracking is the Device Manager, embedded: the
/// name fits Items and Friends as well as Devices (#23).
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

struct RootView: View {
    @EnvironmentObject var logger: LogStore
    @State private var selection: Dest? = .home
    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
        } detail: {
            Detail(selection: selection)
        }
        .frame(minWidth: 600, minHeight: 450)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToStatus)) { _ in
            selection = .status
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAccess)) { _ in
            selection = .access
        }
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }
}

private struct PillWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SidebarRow: View {
    let destination: Dest
    let title: String
    let systemImage: String

    var body: some View {
        NavigationLink(value: destination) {
            Label {
                Text(title)
                    .padding(.leading, 4)
            } icon: {
                Image(systemName: systemImage)
                    .font(.title2)
            }
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Dest?
    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var app: AppModel
    @State private var pillWidth: CGFloat = 0

    private var baseMin: CGFloat { 140 }
    private var baseIdeal: CGFloat { 160 }
    private var baseMax: CGFloat { 300 }

    private var computedMinWidth: CGFloat {
        if logger.needsFullDiskAccess {
            // Ensure pill fits with a little leading/trailing padding
            let desired = pillWidth + 16 // ~8pt padding on each side
            return max(baseMin, desired)
        } else {
            return baseMin
        }
    }

    private var computedIdealWidth: CGFloat {
        if logger.needsFullDiskAccess {
            return max(baseIdeal, computedMinWidth)
        } else {
            return baseIdeal
        }
    }

    private var computedMaxWidth: CGFloat {
        if logger.needsFullDiskAccess {
            // Allow max to be at least the ideal/min to avoid clamping
            return max(baseMax, computedIdealWidth)
        } else {
            return baseMax
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarList
            // A real footer below the list rather than an overlay on it, so the
            // divider separates it from the navigation instead of floating over it.
            if settings.transportMode == .mqtt {
                // Inset to match the sidebar's own group dividers. Full width was
                // the only edge-to-edge line in the panel, which read as "separate
                // region below" rather than "another group" — most likely what made
                // the footer look like a recessed well.
                Divider()
                    .padding(.horizontal, 10)
                MQTTStatusLight(connected: app.mqttConnected,
                                host: settings.mqttHost,
                                port: settings.mqttPort,
                                onTap: { selection = .access })
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    // No background of our own: the footer sits outside the List
                    // and so does not inherit its material. Painting anything here
                    // makes the strip read as a recessed well rather than a last
                    // row of the sidebar.
                    .background(Color.clear)
            }
        }
        .navigationSplitViewColumnWidth(
            min: computedMinWidth,
            ideal: computedIdealWidth,
            max: computedMaxWidth
        )
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Text("SYNCHRONIZATION")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            SidebarRow(destination: .home, title: "Home", systemImage: "house")
            SidebarRow(destination: .status, title: "Status", systemImage: "waveform.path.ecg.magnifyingglass")

            Divider()
                .padding(.vertical, 4)

            Text("SETTINGS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            SidebarRow(destination: .access, title: "Access", systemImage: "key")
            SidebarRow(destination: .tracking, title: "Tracking", systemImage: "scope")
            SidebarRow(destination: .general, title: "General", systemImage: "gearshape.2")

            Divider()
                .padding(.vertical, 4)

            SidebarRow(destination: .about, title: "About", systemImage: "info.circle")
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            if logger.needsFullDiskAccess {
                FullDiskAccessPill()
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PillWidthPreferenceKey.self, value: geo.size.width)
                        }
                    )
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: logger.needsFullDiskAccess)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: pillWidth)
        .onPreferenceChange(PillWidthPreferenceKey.self) { newWidth in
            // Use the max to avoid jitter; width changes only when pill content changes
            pillWidth = max(0, newWidth)
        }
    }
}

struct Detail: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var app: AppModel
    let selection: Dest?
    @ViewBuilder var body: some View {
        switch selection {
        case .home:     HomeView()
        case .status:   StatusView()
        case .tracking: DeviceManagerView()
        case .access: AccessSettingsView()
        case .general:  GeneralSettingsView()
        case .about:    AboutView()
        case .none:     HomeView()
        }
    }
}
