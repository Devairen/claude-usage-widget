import SwiftUI

struct SettingsView: View {
    var onSignIn: (() -> Void)?

    @State private var orgId = ""
    @State private var cookie = ""
    @State private var showSaved = false
    @State private var saveError: String?

    // Display settings
    @State private var showPercentageInBar = false
    @State private var showClaudeIcon = false
    @State private var customAccentHex = ""
    @State private var pickerColor = Color(nsColor: Theme.claudeOrange)
    @State private var alwaysUseAccentColor = false

    private let configManager = ConfigManager()

    private var isConnected: Bool {
        configManager.load() != nil
    }

    var body: some View {
        Form {
            // MARK: - Account
            Section {
                Button(isConnected ? "Switch Account" : "Sign in to Claude") {
                    onSignIn?()
                }
                .buttonStyle(.borderedProminent)
            } header: {
                Text("Account")
            } footer: {
                Text(isConnected
                     ? "Already connected. Use this to sign in with a different account."
                     : "Opens claude.ai — sign in and your credentials are captured automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Manual Setup
            Section {
                TextField("Organization ID", text: $orgId)
                    .textFieldStyle(.roundedBorder)

                SecureField("Cookie", text: $cookie)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(orgId.isEmpty || cookie.isEmpty)

                    if showSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                    }

                    if let saveError {
                        Label(saveError, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                    }
                }
            } header: {
                Text("Manual Setup")
            } footer: {
                Text("claude.ai > DevTools > Network > Settings/Usage > copy org ID from URL and Cookie header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Display
            Section {
                Toggle("Show percentage in menu bar", isOn: $showPercentageInBar)
                    .onChange(of: showPercentageInBar) { saveDisplaySettings() }

                Toggle("Show Claude icon in menu bar", isOn: $showClaudeIcon)
                    .onChange(of: showClaudeIcon) { saveDisplaySettings() }

                Toggle("Keep accent color at high usage", isOn: $alwaysUseAccentColor)
                    .onChange(of: alwaysUseAccentColor) { saveDisplaySettings() }

                // Color picker — label, hex field, picker, reset on one clean line
                LabeledContent("Accent color") {
                    HStack(spacing: 8) {
                        TextField("#hex", text: $customAccentHex)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 96)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit {
                                syncPickerFromHex()
                                saveDisplaySettings()
                            }

                        ColorPicker("", selection: $pickerColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: pickerColor) {
                                customAccentHex = hexFromColor(pickerColor)
                                saveDisplaySettings()
                            }

                        if !customAccentHex.isEmpty {
                            Button {
                                customAccentHex = ""
                                pickerColor = Theme.defaultAccent
                                saveDisplaySettings()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reset to default")
                        }
                    }
                }
                // Live preview at different usage levels
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ForEach([20.0, 45.0, 75.0, 95.0], id: \.self) { pct in
                            VStack(spacing: 4) {
                                ArcView(
                                    percentage: pct,
                                    size: 32,
                                    lineWidth: 3.5,
                                    showLabel: false,
                                    settings: previewSettings
                                )
                                Text("\(Int(pct))%")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.swiftUIColor(for: pct, settings: previewSettings))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

            } header: {
                Text("Display")
            } footer: {
                Text("\"Keep accent color\" prevents the arc from shifting to red at high usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Info
            Section {
                LabeledContent("Config file") {
                    Text(configManager.configPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let age = configManager.configAgeDays {
                    LabeledContent("Cookie age") {
                        Text("\(age) days")
                            .foregroundStyle(age >= 25 ? .orange : .secondary)
                    }
                }
            } header: {
                Text("Info")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear { loadAll() }
        .onReceive(NotificationCenter.default.publisher(for: .configUpdated)) { _ in
            loadAll()
        }
    }

    // MARK: - Helpers

    /// Settings reflecting the current UI state (for live preview).
    private var previewSettings: AppSettings {
        AppSettings(
            showPercentageInBar: showPercentageInBar,
            showClaudeIcon: showClaudeIcon,
            customAccentColorHex: customAccentHex.isEmpty ? nil : customAccentHex,
            alwaysUseAccentColor: alwaysUseAccentColor
        )
    }

    private func syncPickerFromHex() {
        if let nsColor = Theme.nsColor(fromHex: customAccentHex) {
            pickerColor = Color(nsColor: nsColor)
        }
    }

    private func hexFromColor(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func loadAll() {
        if let config = configManager.load() {
            orgId = config.orgId
            cookie = config.cookie
        }
        let settings = configManager.loadSettings()
        showPercentageInBar = settings.showPercentageInBar
        showClaudeIcon = settings.showClaudeIcon
        alwaysUseAccentColor = settings.alwaysUseAccentColor
        customAccentHex = settings.customAccentColorHex ?? ""
        syncPickerFromHex()
    }

    private func save() {
        let config = AppConfig(
            orgId: orgId.trimmingCharacters(in: .whitespacesAndNewlines),
            cookie: cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try configManager.save(config)
            saveError = nil
            showSaved = true
            NotificationCenter.default.post(name: .configUpdated, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSaved = false
            }
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func saveDisplaySettings() {
        let settings = AppSettings(
            showPercentageInBar: showPercentageInBar,
            showClaudeIcon: showClaudeIcon,
            customAccentColorHex: customAccentHex.isEmpty ? nil : customAccentHex,
            alwaysUseAccentColor: alwaysUseAccentColor
        )
        try? configManager.saveSettings(settings)
        NotificationCenter.default.post(name: .settingsUpdated, object: nil)
    }
}
