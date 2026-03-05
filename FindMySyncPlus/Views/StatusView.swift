import SwiftUI
import Combine
import AppKit

private enum LogDisplayStyle: String, CaseIterable {
    case icons
    case textOnly
    var title: String { self == .icons ? "Icons" : "Text only" }
}

struct StatusView: View {
    @State private var showRunBusyToast: Bool = false
    @AppStorage("statusAutoScroll") private var autoScroll: Bool = true
    @AppStorage("statusSavedScrollID") private var savedScrollIDRaw: String = ""
    private let bottomSentinelID = UUID()
    @State private var scrollPos: UUID? = nil

    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var app: AppModel

    @State private var showDisplayMenu: Bool = false
    @AppStorage("logDisplayStyle") private var displayStyleRaw: String = LogDisplayStyle.icons.rawValue

    private var displayStyle: LogDisplayStyle {
        get { LogDisplayStyle(rawValue: displayStyleRaw) ?? .icons }
        set { displayStyleRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            logList
        }
        .overlay(alignment: .topTrailing) {
            if showRunBusyToast {
                Text("Run already in progress")
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 12)
                    .padding(.trailing, 12)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            logger.minimumLevel = settings.logLevel
            NotificationCenter.default.post(name: .statusViewDidAppear, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolbarRunNowRequested)) { _ in
            let ok = app.runNowIfIdle()
            if !ok { triggerRunBusyToast() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolbarDryRunRequested)) { _ in
            let ok = app.runDryIfIdle()
            if !ok { triggerRunBusyToast() }
        }
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let barWidth: CGFloat = 2
                let gutter: CGFloat   = 6
                let even = Color(nsColor: NSColor.alternatingContentBackgroundColors[0])
                let odd  = Color(nsColor: NSColor.alternatingContentBackgroundColors[1])

                ForEach(Array(logger.entries.enumerated()), id: \.element.id) { index, entry in
                    logRow(entry)
                        .id(entry.id)
                        .padding(.leading, barWidth + gutter)
                        .background(index.isMultiple(of: 2) ? even : odd)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(entry.level.accentColor)
                                .frame(width: barWidth)
                                .allowsHitTesting(false)
                        }
                }
                Color.clear
                    .frame(height: 1)
                    .id(bottomSentinelID)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .contentMargins(.top, 8)
        .scrollTargetLayout()
        .scrollPosition(id: $scrollPos, anchor: .top)
        .onChange(of: scrollPos) { _, newID in
            if !autoScroll {
                savedScrollIDRaw = newID?.uuidString ?? ""
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            if autoScroll {
                scrollPos = logger.entries.last?.id ?? bottomSentinelID
            } else if let id = UUID(uuidString: savedScrollIDRaw),
                      logger.entries.contains(where: { $0.id == id }) {
                scrollPos = id
            }
        }
        .onChange(of: logger.entries.count) {
            if autoScroll {
                withAnimation(.easeOut(duration: 0.18)) {
                    scrollPos = bottomSentinelID
                }
            }
        }
        .onChange(of: autoScroll) { _, isEnabled in
            if isEnabled {
                savedScrollIDRaw = ""
                let targetID = logger.entries.last?.id ?? bottomSentinelID
                withAnimation(.easeOut(duration: 0.18)) { scrollPos = targetID }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Toggle("Auto Scroll", isOn: $autoScroll)
            Spacer(minLength: 0)
            Picker("Log Level", selection: $settings.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { lv in
                    Text(lv.display).tag(lv)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.regular)
            .onChange(of: settings.logLevel) { _, newLevel in
                logger.minimumLevel = newLevel
            }

            Button("Clear") {
                logger.clear()
                logger.info("Status log cleared")
            }
                .controlSize(.regular)

            Button {
                showDisplayMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .imageScale(.small)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Display options")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDisplayMenu, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Icons") { displayStyleRaw = LogDisplayStyle.icons.rawValue; showDisplayMenu = false }
                        .buttonStyle(.plain)
                    Button("Text only") { displayStyleRaw = LogDisplayStyle.textOnly.rawValue; showDisplayMenu = false }
                        .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .fixedSize()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.bar)
    }

    @ViewBuilder
    private func logRow(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(e.timestampString)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 62, alignment: .leading)

            levelBadge(e.level)

            Text(e.message)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)   // pad the content, not the bar
    }

    @ViewBuilder
    private func levelBadge(_ level: LogLevel) -> some View {
        switch displayStyle {
        case .icons:
            Text(level.emoji).frame(width: 20, alignment: .center)
        case .textOnly:
            Text("[\(level.display)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(level.color)
                .lineLimit(1)
                .frame(minWidth: 45, alignment: .trailing)
        }
    }

    private func triggerRunBusyToast() {
        withAnimation(.easeOut(duration: 0.15)) { showRunBusyToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.2)) { showRunBusyToast = false }
        }
    }
}
