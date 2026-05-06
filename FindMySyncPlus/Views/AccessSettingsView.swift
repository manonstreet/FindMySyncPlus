import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AccessSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var app: AppModel

    @State private var showAuth: Bool = false
    @State private var showMqttPassword: Bool = false
    @State private var authLastTest: Date? = nil
    @State private var hoveringEye: Bool = false
    @State private var hoveringMqttEye: Bool = false

    private enum ConnectionTestStatus {
        case idle, running, success, rejected, failed, invalidURL(String)
    }
    @State private var connectionTestStatus: ConnectionTestStatus = .idle
    @State private var bulkImportResult: String? = nil

    private enum KeyTab: String, CaseIterable { case all, fmip, fmf, localStorage }
    @State private var selectedKeyTab: KeyTab = .all

    @State private var pendingTransportMode: TransportMode?
    @State private var showTransportSwitchAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(
                    title: "ENDPOINT",
                    tip: "REST uses HTTP POST to device_tracker/see. MQTT uses HA auto-discovery with richer attributes.\n\n"
                        + "Switching transport modes creates new entities in Home Assistant. "
                        + "Old entities from the previous mode will become stale and should be removed manually."
                )
                endpointCard
                connectionTestCard

                SectionHeader(title: "LOCAL", tip: "Local key and macOS permissions required for decryption.")
                    .padding(.top, 8)
                keysCard
                permissionStatusCard
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 610)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            NotificationCenter.default.post(name: .clearToolbarItems, object: nil)
        }
        .alert("Switch Transport?",
               isPresented: $showTransportSwitchAlert,
               presenting: pendingTransportMode) { mode in
            Button("Switch") {
                app.stop()
                settings.setTransportMode(mode)
                connectionTestStatus = .idle
                pendingTransportMode = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTransportMode = nil
            }
        } message: { _ in
            Text(
                "Switching transport will stop the scheduler and create new device tracker entities in Home Assistant. "
                + "Old entities from the previous transport will become stale and should be removed manually.\n\n"
                + "Configure your new transport settings, verify the connection, then restart the scheduler when ready."
            )
        }
    }

    // Small labeled section header used between groups of cards
    private struct SectionHeader: View {
        let title: String
        let tip: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                InfoTip(message: tip)
                Spacer()
            }
            .padding(.top, 4)
            .padding(.bottom, -4)
        }
    }

    // MARK: - Full-Width Segmented Controls
    private struct FullWidthSegmentedControl<T: CaseIterable & Equatable>: NSViewRepresentable where T.AllCases: RandomAccessCollection {
        @Binding var selection: T
        let labels: [String]

        func makeNSView(context: Context) -> NSSegmentedControl {
            let control = NSSegmentedControl(
                labels: labels,
                trackingMode: .selectOne,
                target: context.coordinator,
                action: #selector(Coordinator.selectionChanged(_:))
            )
            control.segmentDistribution = .fillEqually
            control.selectedSegment = Array(T.allCases).firstIndex(of: selection) ?? 0
            return control
        }

        func updateNSView(_ control: NSSegmentedControl, context: Context) {
            let idx = Array(T.allCases).firstIndex(of: selection) ?? 0
            if control.selectedSegment != idx {
                control.selectedSegment = idx
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
            guard let width = proposal.width else { return nil }
            return CGSize(width: width, height: nsView.intrinsicContentSize.height)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(selection: $selection)
        }

        final class Coordinator: NSObject {
            let selection: Binding<T>
            init(selection: Binding<T>) { self.selection = selection }

            @objc func selectionChanged(_ sender: NSSegmentedControl) {
                let cases = Array(T.allCases)
                let idx = sender.selectedSegment
                guard idx >= 0, idx < cases.count else { return }
                selection.wrappedValue = cases[idx]
            }
        }
    }

    // MARK: - Transport Picker (inline)
    private var transportPicker: some View {
        FullWidthSegmentedControl<TransportMode>(
            selection: Binding(
                get: { settings.transportMode },
                set: { newMode in
                    guard newMode != settings.transportMode else { return }
                    if app.isRunning {
                        pendingTransportMode = newMode
                        showTransportSwitchAlert = true
                    } else {
                        settings.setTransportMode(newMode)
                        connectionTestStatus = .idle
                    }
                }
            ),
            labels: TransportMode.allCases.map { $0.rawValue.uppercased() }
        )
    }

    // MARK: - Endpoint Card (picker + all connection fields)
    private var endpointCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                transportPicker

                if settings.transportMode == .rest {
                    // -- URL --
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("URL")
                            .font(.title3).fontWeight(.semibold)
                        InfoTip(message: "Home Assistant device tracker endpoint used for POST requests.")
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        TextField("http://homeassistant.local:8123/api/services/device_tracker/see", text: $settings.endpointURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: settings.endpointURL) { _, _ in
                                connectionTestStatus = .idle
                            }
                        Color.clear.frame(width: 16)
                    }

                    // -- Authorization --
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Authorization")
                            .font(.title3).fontWeight(.semibold)
                        InfoTip(message: "Exact string sent in the authorization header.")
                        Spacer()
                    }
                    .padding(.top, 4)
                    HStack(spacing: 8) {
                        let authBinding = Binding<String>(
                            get: { settings.endpointAuth },
                            set: { settings.updateEndpointAuth($0) }
                        )
                        Group {
                            if showAuth {
                                TextField("Bearer <token>", text: authBinding)
                            } else {
                                SecureField("Bearer <token>", text: authBinding)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button { showAuth.toggle() } label: {
                            Image(systemName: showAuth ? "eye.slash" : "eye")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(hoveringEye ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.7))
                                .frame(width: 16, alignment: .center)
                        }
                        .buttonStyle(.borderless)
                        .onHover { hoveringEye = $0 }
                        .help(showAuth ? "Hide value" : "Show value")
                    }
                } else {
                    // -- Broker --
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Broker")
                            .font(.title3).fontWeight(.semibold)
                        InfoTip(message: "MQTT broker connection details. HA's built-in Mosquitto add-on typically runs on port 1883 (or 8883 with TLS).")
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        TextField("homeassistant.local", text: $settings.mqttHost)
                            .textFieldStyle(.roundedBorder)
                        Text(":")
                            .foregroundStyle(.secondary)
                        TextField("1883", value: $settings.mqttPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Button {
                            settings.mqttUseTLS.toggle()
                            if settings.mqttUseTLS && settings.mqttPort == 1883 {
                                settings.mqttPort = 8883
                            } else if !settings.mqttUseTLS && settings.mqttPort == 8883 {
                                settings.mqttPort = 1883
                            }
                        } label: {
                            Image(systemName: settings.mqttUseTLS ? "lock.fill" : "lock.open")
                                .foregroundStyle(settings.mqttUseTLS ? Color.green : Color.secondary)
                                .frame(width: 16, alignment: .center)
                        }
                        .buttonStyle(.borderless)
                        .help(settings.mqttUseTLS ? "TLS enabled — click to disable" : "TLS disabled — click to enable")
                    }

                    // -- Credentials --
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Credentials")
                            .font(.title3).fontWeight(.semibold)
                        InfoTip(message: "MQTT broker username and password. Leave blank for anonymous access.")
                        Spacer()
                    }
                    .padding(.top, 4)
                    HStack(spacing: 8) {
                        TextField("Username", text: $settings.mqttUsername)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        let passwordBinding = Binding<String>(
                            get: { settings.mqttPassword },
                            set: { settings.updateMqttPassword($0) }
                        )
                        Group {
                            if showMqttPassword {
                                TextField("Password", text: passwordBinding)
                            } else {
                                SecureField("Password", text: passwordBinding)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button { showMqttPassword.toggle() } label: {
                            Image(systemName: showMqttPassword ? "eye.slash" : "eye")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(hoveringMqttEye ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.7))
                                .frame(width: 16, alignment: .center)
                        }
                        .buttonStyle(.borderless)
                        .onHover { hoveringMqttEye = $0 }
                        .help(showMqttPassword ? "Hide password" : "Show password")
                    }

                    // -- Topic Prefix --
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Topic Prefix")
                            .font(.title3).fontWeight(.semibold)
                        InfoTip(message: "Prefix for MQTT discovery and state topics. Must match the prefix configured in Home Assistant's MQTT integration.")
                        Spacer()
                    }
                    .padding(.top, 4)
                    HStack(spacing: 8) {
                        TextField("findmysyncplus/", text: $settings.mqttTopicPrefix)
                            .textFieldStyle(.roundedBorder)
                        Color.clear.frame(width: 16)
                    }
                }
            }
        }
    }

    // MARK: - Connection Test (generic for REST/MQTT)
    private var connectionTestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Connection Test")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: settings.transportMode == .rest
                            ? "Performs a GET request on the base /api/ endpoint to verify the Authorization header."
                            : "Attempts to connect to the MQTT broker to verify host, port, and credentials.")
                    Spacer()
                }
                HStack {
                    connectionTestStatusDisplay
                    Spacer()
                    Button {
                        Task {
                            await MainActor.run {
                                connectionTestStatus = .running
                                authLastTest = nil
                            }
                            if settings.transportMode == .rest {
                                let outcome = await app.triggerManualAuthTestAsync()
                                await MainActor.run {
                                    authLastTest = Date()
                                    switch outcome {
                                    case .success:
                                        connectionTestStatus = .success
                                    case .authRejected:
                                        connectionTestStatus = .rejected
                                    case .badConfig(let msg):
                                        connectionTestStatus = .invalidURL(msg ?? "Invalid configuration")
                                    case .transient:
                                        connectionTestStatus = .failed
                                    }
                                }
                            } else {
                                let (ok, msg) = await app.triggerManualMQTTTestAsync()
                                await MainActor.run {
                                    authLastTest = Date()
                                    connectionTestStatus = ok ? .success : .failed
                                    if !ok {
                                        connectionTestStatus = .invalidURL(msg)
                                    }
                                }
                            }
                        }
                    } label: {
                        if app.isPerformingRun {
                            Label("Wait…", systemImage: "network")
                        } else {
                            Label("Verify", systemImage: "network")
                        }
                    }
                    .disabled(app.isPerformingRun || testButtonDisabled)
                }
            }
        }
    }

    private var testButtonDisabled: Bool {
        switch settings.transportMode {
        case .rest:
            return settings.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .mqtt:
            return settings.mqttHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private var connectionTestStatusDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch connectionTestStatus {
            case .idle:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                Text("Not tested")
                    .font(.body)
                    .foregroundStyle(.secondary)

            case .running:
                ProgressView().controlSize(.small)
                Text("Wait…").foregroundStyle(.secondary)

            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(settings.transportMode == .rest ? "Auth OK" : "Connected")
                if let t = authLastTest {
                    Text("· \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .rejected:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Auth rejected")
                if let t = authLastTest {
                    Text("· \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .failed:
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(settings.transportMode == .rest ? "Request failed" : "Connection failed")
                if let t = authLastTest {
                    Text("· \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .invalidURL(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason)
            }
        }
    }

    // MARK: - Decryption Keys (segmented)
    private var keysCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Decryption Keys")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Import key files exported by the key extractor.\nKeys are stored securely in your Keychain.\nRight-click a key to clear it.")
                    Spacer()
                }

                FullWidthSegmentedControl<KeyTab>(
                    selection: $selectedKeyTab,
                    labels: ["All", "Find My", "FMF", "LocalStorage"]
                )

                Group {
                    switch selectedKeyTab {
                    case .all:
                        VStack(alignment: .leading, spacing: 6) {
                            keyStatusRow("Find My", status: settings.fmipKeyStatus, kind: .fmip)
                            keyStatusRow("FMF", status: settings.fmfKeyStatus, kind: .fmf)
                            keyStatusRow("LocalStorage", status: settings.localStorageKeyStatus, kind: .localStorage)
                        }
                        HStack {
                            if let result = bulkImportResult {
                                Text(result)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await bulkImportKeys() }
                            } label: {
                                Label("Import All from Folder", systemImage: "folder.badge.plus")
                            }
                        }
                    case .fmip:
                        keyStatusRow("Find My", status: settings.fmipKeyStatus, kind: .fmip)
                        HStack {
                            Spacer()
                            Button {
                                Task {
                                    if let url = await openFilePanel(allowed: [.propertyList]) {
                                        do {
                                            try settings.importFMIPKey(from: url)
                                            app.invalidateCacheDecryptorKey()
                                        } catch {
                                            logger.error("FMIP key import failed: \(error.localizedDescription)")
                                        }
                                    }
                                }
                            } label: {
                                Label("Import Key", systemImage: "square.and.arrow.down")
                            }
                        }
                    case .fmf:
                        keyStatusRow("FMF", status: settings.fmfKeyStatus, kind: .fmf)
                        HStack {
                            Spacer()
                            Button {
                                Task {
                                    if let url = await openFilePanel(allowed: [.propertyList]) {
                                        do {
                                            try settings.importFMFKey(from: url)
                                            app.invalidateFMFKey()
                                        } catch {
                                            logger.error("FMF key import failed: \(error.localizedDescription)")
                                        }
                                    }
                                }
                            } label: {
                                Label("Import Key", systemImage: "square.and.arrow.down")
                            }
                        }
                    case .localStorage:
                        keyStatusRow("LocalStorage", status: settings.localStorageKeyStatus, kind: .localStorage)
                        HStack {
                            Spacer()
                            Button {
                                Task {
                                    if let url = await openFilePanel(allowed: [.data]) {
                                        do {
                                            try settings.importLocalStorageKey(from: url)
                                            app.invalidateLocalStorageKey()
                                        } catch {
                                            logger.error("LocalStorage key import failed: \(error.localizedDescription)")
                                        }
                                    }
                                }
                            } label: {
                                Label("Import Key", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private enum KeyKind { case fmip, fmf, localStorage }

    @ViewBuilder
    private func keyStatusRow(_ name: String, status: KeyStatus, kind: KeyKind? = nil) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .notPresent:
                Image(systemName: "xmark.seal.fill").foregroundStyle(.secondary)
            case .present:
                Image(systemName: "seal").foregroundStyle(.secondary)
            case .valid:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .invalid:
                Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
            }
            Text(name)
                .foregroundStyle(status == .notPresent || status == .present ? .secondary : .primary)
            Spacer()
            Text(keyStatusLabel(status))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            if let kind, status != .notPresent {
                Button(role: .destructive) {
                    clearKey(kind)
                } label: {
                    Label("Clear Key", systemImage: "trash")
                }
            }
        }
    }

    private func clearKey(_ kind: KeyKind) {
        switch kind {
        case .fmip:
            Keychain.delete(.fmipSymmetricKey)
            settings.fmipKeyStatus = .notPresent
            settings.enableDevices = false
            settings.enableItems = false
            app.invalidateCacheDecryptorKey()
        case .fmf:
            Keychain.delete(.fmfKey)
            settings.fmfKeyStatus = .notPresent
            app.invalidateFMFKey()
        case .localStorage:
            Keychain.delete(.localStorageKey)
            settings.localStorageKeyStatus = .notPresent
            settings.enableFriends = false
            app.invalidateLocalStorageKey()
        }
    }

    private func keyStatusLabel(_ status: KeyStatus) -> String {
        switch status {
        case .notPresent: return "Not set"
        case .present: return "Loaded"
        case .valid: return "Valid"
        case .invalid: return "Invalid"
        }
    }

    // MARK: - Permissions
    private var permissionStatusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Permission Status")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Grant Full Disk Access so the app can read the Find My cache files.")
                    Spacer()
                }
                HStack {
                    HStack(spacing: 6) {
                        if logger.needsFullDiskAccess {
                            Image(systemName: "xmark.shield.fill")
                                .foregroundStyle(.red)
                            Text("Full Disk Access")
                                .foregroundStyle(.primary)
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("Full Disk Access")
                                .foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                    Button {
                        openFullDiskAccessPreferences()
                    } label: {
                        Label("Open Preferences", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    // MARK: - Helpers
    @MainActor
    private func openFilePanel(allowed: [UTType]) async -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types = allowed
        if let bplist = UTType(filenameExtension: "bplist") {
            types.append(bplist)
        }
        if let keyType = UTType(filenameExtension: "key") {
            types.append(keyType)
        }
        panel.allowedContentTypes = Array(Set(types))
        let result = panel.runModal()
        if result == .OK { return panel.url }
        return nil
    }

    @MainActor
    private func openFolderPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        let result = panel.runModal()
        if result == .OK { return panel.url }
        return nil
    }

    @MainActor
    private func bulkImportKeys() async {
        guard let folder = await openFolderPanel() else { return }

        let fmipFile = folder.appendingPathComponent("FMIPDataManager.bplist")
        let fmfFile = folder.appendingPathComponent("FMFDataManager.bplist")
        let lsFile = folder.appendingPathComponent("LocalStorage.key")

        var imported = 0
        var missing: [String] = []
        let total = 3

        if FileManager.default.fileExists(atPath: fmipFile.path) {
            do {
                try settings.importFMIPKey(from: fmipFile)
                app.invalidateCacheDecryptorKey()
                imported += 1
            } catch {
                logger.error("Bulk import: FMIP key failed: \(error.localizedDescription)")
            }
        } else {
            missing.append("FMIPDataManager.bplist")
        }

        if FileManager.default.fileExists(atPath: fmfFile.path) {
            do {
                try settings.importFMFKey(from: fmfFile)
                app.invalidateFMFKey()
                imported += 1
            } catch {
                logger.error("Bulk import: FMF key failed: \(error.localizedDescription)")
            }
        } else {
            missing.append("FMFDataManager.bplist")
        }

        if FileManager.default.fileExists(atPath: lsFile.path) {
            do {
                try settings.importLocalStorageKey(from: lsFile)
                app.invalidateLocalStorageKey()
                imported += 1
            } catch {
                logger.error("Bulk import: LocalStorage key failed: \(error.localizedDescription)")
            }
        } else {
            missing.append("LocalStorage.key")
        }

        if imported == total {
            bulkImportResult = "Imported \(imported) of \(total) keys"
        } else if imported > 0 {
            bulkImportResult = "Imported \(imported) of \(total) keys — \(missing.joined(separator: ", ")) not found"
        } else {
            bulkImportResult = "No keys found in selected folder"
        }
    }

    private func openFullDiskAccessPreferences() {
        NSWorkspace.shared.openFullDiskAccess()
    }
}
