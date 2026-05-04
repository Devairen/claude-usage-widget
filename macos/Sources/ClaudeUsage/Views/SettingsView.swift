import SwiftUI

struct SettingsView: View {
    var onSignIn: (() -> Void)?

    @State private var orgId = ""
    @State private var cookie = ""
    @State private var showSaved = false
    @State private var saveError: String?

    private let configManager = ConfigManager()

    var body: some View {
        Form {
            Section {
                Button("Sign in to Claude") {
                    onSignIn?()
                }
                .buttonStyle(.borderedProminent)
            } header: {
                Text("Quick Setup")
            } footer: {
                Text("Opens claude.ai — sign in and your credentials are captured automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Organization ID", text: $orgId)
                    .textFieldStyle(.roundedBorder)
                    .help("UUID from the claude.ai usage API URL")

                SecureField("Cookie", text: $cookie)
                    .textFieldStyle(.roundedBorder)
                    .help("Full Cookie header value from DevTools")
            } header: {
                Text("Manual Setup")
            } footer: {
                Text("claude.ai \u{2192} DevTools \u{2192} Network \u{2192} reload Settings/Usage \u{2192} copy the org ID from the URL and the Cookie header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save") {
                        save()
                    }
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
            }

            Section {
                LabeledContent("Config file") {
                    Text(configManager.configPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
        .frame(width: 440, height: 400)
        .onAppear { loadConfig() }
        .onReceive(NotificationCenter.default.publisher(for: .configUpdated)) { _ in
            loadConfig()
        }
    }

    private func loadConfig() {
        if let config = configManager.load() {
            orgId = config.orgId
            cookie = config.cookie
        }
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
}
