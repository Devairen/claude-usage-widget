import Foundation
import Observation

@Observable
final class UsageViewModel {
    enum State {
        case loading
        case needsConfig
        case authFailed
        case loaded
        case error(String)
    }

    var state: State = .loading
    var fiveHour: UsageEntry?
    var sevenDay: UsageEntry?
    var extraUsage: ExtraUsage?
    var models: [ModelUsage] = []
    var lastUpdated: Date?

    // Burn rate tracking — ring buffer of recent (date, 5h%) samples
    private var samples: [(date: Date, pct: Double)] = []

    var fiveHourPct: Double {
        fiveHour?.utilization ?? 0
    }

    var sevenDayPct: Double {
        sevenDay?.utilization ?? 0
    }

    func update(with data: UsageData) {
        fiveHour = data.fiveHour
        sevenDay = data.sevenDay
        extraUsage = data.extraUsage
        lastUpdated = Date()
        state = .loaded

        // Per-model breakdown
        var m: [ModelUsage] = []
        if let u = data.sevenDaySonnet?.utilization  { m.append(ModelUsage(name: "Sonnet", percentage: u)) }
        if let u = data.sevenDayOpus?.utilization     { m.append(ModelUsage(name: "Opus", percentage: u)) }
        if let u = data.sevenDayOmelette?.utilization  { m.append(ModelUsage(name: "Design", percentage: u)) }
        models = m

        // Track sample for burn rate
        let pct = data.fiveHour?.utilization ?? 0
        addSample(date: Date(), pct: pct)
    }

    // MARK: - Burn Rate

    private func addSample(date: Date, pct: Double) {
        samples.append((date: date, pct: pct))

        // Keep last 15 minutes
        let cutoff = date.addingTimeInterval(-15 * 60)
        samples = samples.filter { $0.date >= cutoff }

        // Detect resets: if percentage drops by >20 points, discard older data
        for i in stride(from: samples.count - 1, through: 1, by: -1) {
            if samples[i].pct < samples[i - 1].pct - 20 {
                samples = Array(samples[i...])
                break
            }
        }
    }

    /// Bootstrap burn rate from history.json (called once on launch).
    func bootstrapFromHistory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let historyURL = appSupport?.appendingPathComponent("ClaudeUsage/history.json"),
              let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode([[Double]].self, from: data) else { return }

        let now = Date()
        let cutoff = now.addingTimeInterval(-15 * 60)

        for entry in history where entry.count >= 2 {
            let date = Date(timeIntervalSince1970: entry[0] * 60)
            if date >= cutoff {
                samples.append((date: date, pct: entry[1]))
            }
        }
    }

    /// Current burn rate in %/minute. Nil if idle or insufficient data.
    var burnRatePerMinute: Double? {
        guard samples.count >= 3 else { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }
        let minutes = last.date.timeIntervalSince(first.date) / 60
        guard minutes >= 2 else { return nil } // Need at least 2 minutes of data
        let delta = last.pct - first.pct
        guard delta > 0.5 else { return nil } // Ignore noise / idle
        return delta / minutes
    }

    /// Minutes until 100% at current burn rate. Nil if not burning.
    var minutesToLimit: Double? {
        guard let rate = burnRatePerMinute, rate > 0 else { return nil }
        let remaining = 100 - fiveHourPct
        guard remaining > 0 else { return nil }
        return remaining / rate
    }

    /// Minutes until the 5h session resets. Nil if no reset time available.
    var minutesToReset: Double? {
        guard let resetDate = Theme.parseISO(fiveHour?.resetsAt) else { return nil }
        let remaining = resetDate.timeIntervalSince(Date()) / 60
        return remaining > 0 ? remaining : nil
    }

    /// True if the user will hit 100% before the session resets.
    var willHitLimitBeforeReset: Bool {
        guard let toLimit = minutesToLimit, let toReset = minutesToReset else { return false }
        return toLimit < toReset
    }
}

struct ModelUsage: Identifiable {
    let name: String
    let percentage: Double
    var id: String { name }
}
