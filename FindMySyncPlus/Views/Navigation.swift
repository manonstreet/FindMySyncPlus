import SwiftUI
import AppKit

enum Dest: Hashable { case home, status, access, extras, about }

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

    /// 140 is what the navigation itself needs. The MQTT footer needs a little
    /// more — "MQTT Disconnected" plus the icon column and padding comes to about
    /// 142 — so the minimum rises only when that footer is present, the same way
    /// the Full Disk Access pill widens the sidebar while it is showing.
    private var baseMin: CGFloat { settings.transportMode == .mqtt ? 152 : 140 }
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
                Divider()
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
            SidebarRow(destination: .extras, title: "General", systemImage: "gearshape.2")

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
        case .access: AccessSettingsView()
        case .extras:   GeneralSettingsView()
        case .about:    AboutView()
        case .none:     HomeView()
        }
    }
}
