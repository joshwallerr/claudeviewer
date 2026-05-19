import SwiftUI

struct SettingsView: View {
    @ObservedObject var limits: LimitsMonitor
    var onClose: () -> Void

    @State private var hasSaved: Bool = SecretStore.load() != nil
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var showAdvanced: Bool = false
    @State private var showManualPaste: Bool = false
    @State private var importing: Bool = false
    @State private var errorMessage: String?
    @State private var sessionKey: String = ""

    private let knownBrowsers: [Browser] = [.brave, .chrome, .arc, .edge]
    private var installedBrowsers: [Browser] { knownBrowsers.filter { $0.isInstalled } }

    private var primaryBrowser: Browser? {
        if let name = AppPreferences.lastImportBrowser,
           let b = installedBrowsers.first(where: { $0.displayName == name }) {
            return b
        }
        return installedBrowsers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if hasSaved {
                connectedBlock
            } else {
                disconnectedBlock
            }

            if LaunchAtLogin.isSupported {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) { newValue in
                        if let err = LaunchAtLogin.set(newValue) {
                            errorMessage = err
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
            }

            advancedSection

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var connectedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Connected to claude.ai")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            if let name = AppPreferences.lastImportBrowser {
                Text("via \(name)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let b = primaryBrowser {
                    Button(importing ? "Working…" : "Reconnect from \(b.displayName)") {
                        importFrom(b)
                    }
                    .controlSize(.small)
                    .disabled(importing)
                }
                Spacer()
                Button("Remove") {
                    limits.clear()
                    hasSaved = false
                    errorMessage = nil
                }
                .controlSize(.small)
            }
        }
    }

    private var disconnectedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                Text("Not connected")
                    .font(.system(size: 11, weight: .medium))
            }
            if let b = primaryBrowser {
                Button {
                    importFrom(b)
                } label: {
                    HStack {
                        Image(systemName: "globe")
                        Text(importing ? "Importing…" : "Import from \(b.displayName)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .disabled(importing)
                Text("macOS will ask for keychain access once — click \"Always Allow\".")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No supported browser detected. Open Other sign-in methods below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showAdvanced.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Other sign-in methods")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(installedBrowsers.filter { $0.displayName != primaryBrowser?.displayName },
                            id: \.displayName) { browser in
                        Button("Import from \(browser.displayName)") {
                            importFrom(browser)
                        }
                        .controlSize(.small)
                        .disabled(importing)
                    }
                    Button("Sign in with embedded browser") {
                        limits.presentSignIn()
                        onClose()
                    }
                    .controlSize(.small)
                    Button(showManualPaste ? "Hide manual paste" : "Paste session key manually") {
                        showManualPaste.toggle()
                        errorMessage = nil
                    }
                    .controlSize(.small)

                    if showManualPaste {
                        manualPasteBlock
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private var manualPasteBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DevTools → Application → Cookies → claude.ai → sessionKey")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            SecureField("sk-ant-sid01-…", text: $sessionKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disableAutocorrection(true)
            HStack {
                Spacer()
                Button(importing ? "Testing…" : "Save & Test") {
                    saveManual()
                }
                .controlSize(.small)
                .disabled(importing || sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func importFrom(_ browser: Browser) {
        importing = true
        errorMessage = nil
        Task {
            let err = await limits.importFromBrowser(browser)
            importing = false
            if let err {
                errorMessage = err
            } else {
                hasSaved = true
                onClose()
            }
        }
    }

    private func saveManual() {
        importing = true
        errorMessage = nil
        Task {
            let err = await limits.saveAndTest(sessionKey: sessionKey)
            importing = false
            if let err {
                errorMessage = err
            } else {
                sessionKey = ""
                hasSaved = true
                onClose()
            }
        }
    }
}
