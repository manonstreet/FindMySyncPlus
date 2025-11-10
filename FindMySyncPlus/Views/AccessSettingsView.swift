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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionHeader(title: "ENDPOINT", tip: "Configure Home Assistant endpoint and authorization.")
                endpointCard
                authCard
                authTestCard

                SectionHeader(title: "LOCAL", tip: "Local key and macOS permissions required for decryption.")
                    .padding(.top, 8)
                fmipKeyCard
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

    // MARK: - FMIP Key
    private var fmipKeyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Find My Key")
                        .font(.title3).fontWeight(.semibold)
                    InfoTip(message: "Import the FMIPDataManager key file (plist or bplist) exported by the helper tool.\nThe symmetric key will be stored securely in your Keychain.")
                    Spacer()
                }
                HStack(spacing: 8) {
                    switch settings.fmipKeyStatus {
                    case .notPresent:
                        Label("Not set", systemImage: "xmark.seal.fill")
                            .foregroundStyle(.secondary)
                    case .present:
                        Label("Loaded (unverified, Keychain)", systemImage: "seal")
                            .foregroundStyle(.secondary)
                    case .valid:
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Valid Key")
                            .foregroundStyle(.primary)
                    case .invalid:
                        Image(systemName: "xmark.seal.fill")
                            .foregroundStyle(.red)
                        Text("Invalid Key")
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Button {
                        Task {
                            if let url = await openFilePanel(allowed: [.propertyList]) {
                                do {
                                    try settings.importFMIPKey(from: url)
                                    app.invalidateDecryptorKey()
                                } catch {
                                    // Ignore error in UI; logger will capture it elsewhere if needed
                                }
                            }
                        }
                    } label: {
                        Label("Import Key", systemImage: "square.and.arrow.down")
                    }
                }
            }
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
        panel.allowedContentTypes = Array(Set(types))
        let result = panel.runModal()
        if result == .OK { return panel.url }
        return nil
    }

    private func openFullDiskAccessPreferences() {
        NSWorkspace.shared.openFullDiskAccess()
    }
}

