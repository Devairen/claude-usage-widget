import SwiftUI

struct PopoverView: View {
    var viewModel: UsageViewModel
    var configManager: ConfigManager
    var onOpenSettings: () -> Void
    var onSignIn: () -> Void

    private var settings: AppSettings {
        configManager.loadSettings()
    }

    private var accentColor: Color {
        Theme.accent(from: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)

            switch viewModel.state {
            case .loading:     loadingView
            case .needsConfig: needsConfigView
            case .authFailed:  authFailedView
            case .loaded:      usageContent
            case .error(let m): errorView(m)
            }

            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 272)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accentColor)
                .frame(width: 8, height: 8)
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - State Views

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.7)
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 24)
    }

    private var needsConfigView: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.title2)
                .foregroundStyle(accentColor)
            Text("Setup Required")
                .font(.system(size: 13, weight: .medium))
            Text("Sign in to start tracking\nyour Claude usage.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign in to Claude") {
                onSignIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .controlSize(.small)

            Button("Manual Setup…") {
                onOpenSettings()
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var authFailedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Authentication Failed")
                .font(.system(size: 13, weight: .medium))
            Text("Your cookie may have expired.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign in Again") {
                onSignIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            Text("Error")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Usage Content

    private var usageContent: some View {
        let s = settings
        return VStack(alignment: .leading, spacing: 0) {
            // 5h session (with pace estimate)
            if let fiveHour = viewModel.fiveHour, fiveHour.utilization != nil {
                UsageSectionView(
                    title: "5h Session",
                    icon: "timer",
                    percentage: fiveHour.utilization ?? 0,
                    resetISO: fiveHour.resetsAt,
                    settings: s,
                    burnRate: viewModel.burnRatePerMinute,
                    minutesToLimit: viewModel.minutesToLimit,
                    willHitLimit: viewModel.willHitLimitBeforeReset
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Weekly (7d)
            if let sevenDay = viewModel.sevenDay, sevenDay.utilization != nil {
                Divider().padding(.horizontal, 12)

                UsageSectionView(
                    title: "Weekly (7d)",
                    icon: "calendar",
                    percentage: sevenDay.utilization ?? 0,
                    resetISO: sevenDay.resetsAt,
                    settings: s
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, viewModel.models.isEmpty ? 10 : 6)

                // Per-model breakdown
                if !viewModel.models.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(viewModel.models) { model in
                            ModelRowView(model: model, settings: s)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }

            // Extra usage
            if let extra = viewModel.extraUsage, extra.isEnabled == true {
                Divider().padding(.horizontal, 12)

                HStack {
                    Label("Extra Usage", systemImage: "creditcard")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    let currency = extra.currency ?? "USD"
                    let used = extra.usedCredits ?? 0
                    let limit = extra.monthlyLimit ?? 0
                    if limit > 0 {
                        Text(String(format: "%.2f / %.2f %@", used, limit, currency))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                    } else {
                        Text(String(format: "%.2f %@", used, currency))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                if let lastUpdated = viewModel.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let age = configManager.configAgeDays, age >= 25 {
                    Label("Cookie \(age)d old", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Button("Settings…") {
                    onOpenSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
