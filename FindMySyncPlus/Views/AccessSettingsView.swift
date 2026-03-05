import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AccessSettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var logger: LogStore
    @EnvironmentObject var app: AppModel

    @State private var showAuth: Bool = false
    @State private var authLastTest: Date? = nil
    @State private var hoveringEye: Bool = false

    private enum AuthStatus {
        case idle, running, success, rejected, failed, invalidURL(String)
    }
    @State private var authStatus: AuthStatus = .idle
    @State private var bulkImportResult: String? = nil

    private enum KeyTab: String, CaseIterable { case all, fmip, fmf, localStorage }
    @State private var selectedKeyTab: KeyTab = .all

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "ENDPOINT", tip: "Configure Home Assistant endpoint and authorization.")
                endpointCard
                authCard
                authTestCard

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

    // MARK: - Full-Width Segmented Control
    private struct SegmentedKeyPicker: NSViewRepresentable {
        @Binding var selection: KeyTab

        func makeNSView(context: Context) -> NSSegmentedControl {
            let labels = KeyTab.allCases.map { tab -> String in
                switch tab {
                case .all: "All"
                case .fmip: "Find My"
                case .fmf: "FMF"
                case .localStorage: "LocalStorage"
                }
            }
            let control = NSSegmentedControl(
                labels: labels,
                trackingMode: .selectOne,
                target: context.coordinator,
                action: #selector(Coordinator.selectionChanged(_:))
            )
            control.segmentDistribution = .fillEqually
            control.selectedSegment = KeyTab.allCases.firstIndex(of: selection) ?? 0
            return control
        }

        func updateNSView(_ control: NSSegmentedControl, context: Context) {
            let idx = KeyTab.allCases.firstIndex(of: selection) ?? 0
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
            let selection: Binding<KeyTab>
            init(selection: Binding<KeyTab>) { self.selection = selection }

            @objc func selectionChanged(_ sender: NSSegmentedControl) {
                let cases = Array(KeyTab.allCases)
                let idx = sender.selectedSegment
                guard idx >= 0, idx < cases.count else { return }
                selection.wrappedValue = cases[idx]
            }
        }
    }

    // MARK: - Endpoint
    private var endpointCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("URL")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Home Assistant device tracker endpoint used for POST requests.")
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("http://homeassistant.local:8123/api/services/device_tracker/see", text: $settings.endpointURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: settings.endpointURL) { _, _ in
                            authStatus = .idle
                        }
                }
            }
        }
    }

    // MARK: - Authorization
    private var authCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Authorization")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Exact string sent in the authorization header.")
                    Spacer()
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                    .layoutPriority(1)

                    Spacer(minLength: 0)

                    Button { showAuth.toggle() } label: {
                        Image(systemName: showAuth ? "eye.slash" : "eye")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(hoveringEye ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .onHover { hoveringEye = $0 }
                    .help(showAuth ? "Hide value" : "Show value")
                }
            }
        }
    }

    // MARK: - Auth Test
    private var authTestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Auth Test")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: #"Performs a GET request on the base /api/ endpoint to verify the Authorization header."#)
                    Spacer()
                }
                HStack {
                    authStatusDisplay
                    Spacer()
                    Button {
                        Task {
                            await MainActor.run {
                                authStatus = .running
                                authLastTest = nil
                            }
                            let outcome = await app.triggerManualAuthTestAsync()
                            await MainActor.run {
                                authLastTest = Date()
                                switch outcome {
                                case .success:
                                    authStatus = .success
                                case .authRejected:
                                    authStatus = .rejected
                                case .badConfig(let msg):
                                    authStatus = .invalidURL(msg ?? "Invalid configuration")
                                case .transient:
                                    authStatus = .failed
                                }
                            }
                        }
                    } label: {
                        if app.isPerformingRun {
                            Label("Wait…", systemImage: "key.fill")
                        } else {
                            Label("Test Auth", systemImage: "key.fill")
                        }
                    }
                    .disabled(app.isPerformingRun || settings.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var authStatusDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch authStatus {
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
                Text("Auth OK")
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
                Text("Request failed")
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

                SegmentedKeyPicker(selection: $selectedKeyTab)

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
                                            app.invalidateDecryptorKey()
                                        } catch {}
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
                                            app.invalidateFriendDecryptorKey()
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
            app.invalidateDecryptorKey()
        case .fmf:
            Keychain.delete(.fmfKey)
            settings.fmfKeyStatus = .notPresent
            app.invalidateFMFKey()
        case .localStorage:
            Keychain.delete(.localStorageKey)
            settings.localStorageKeyStatus = .notPresent
            settings.enableFriends = false
            app.invalidateFriendDecryptorKey()
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
                app.invalidateDecryptorKey()
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
                app.invalidateFriendDecryptorKey()
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

