import SwiftUI

struct UsageSectionView: View {
    let title: String
    let icon: String
    let percentage: Double
    let resetISO: String?
    var settings: AppSettings? = nil

    // Optional pace estimate (5h session only)
    var burnRate: Double? = nil       // %/min
    var minutesToLimit: Double? = nil
    var willHitLimit: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ArcView(percentage: percentage, size: 40, lineWidth: 4.5, settings: settings)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(percentage))% used")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.swiftUIColor(for: percentage, settings: settings))

                    if let resetText = Theme.resetText(from: resetISO) {
                        HStack(spacing: 4) {
                            Text(resetText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            if let clock = Theme.resetClockTime(from: resetISO) {
                                Text(clock)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // Pace estimate line
                    if let toLimit = minutesToLimit, let rate = burnRate {
                        HStack(spacing: 4) {
                            Image(systemName: willHitLimit ? "exclamationmark.triangle.fill" : "bolt.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(willHitLimit ? .orange : .secondary)

                            Text("limit in ~\(Theme.formatMinutes(toLimit))")
                                .font(.system(size: 11, weight: willHitLimit ? .medium : .regular))
                                .foregroundStyle(willHitLimit ? .orange : .secondary)

                            Text("· \(String(format: "%.1f", rate))%/min")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()
            }
        }
    }
}
