import Foundation

final class LoggingService {
    private let csvURL: URL
    private let historyURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeUsage")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        csvURL = appDir.appendingPathComponent("usage-log.csv")
        historyURL = appDir.appendingPathComponent("history.json")
    }

    func log(_ data: UsageData) {
        appendCSV(data)
        appendHistory(data)
    }

    // MARK: - CSV (compatible with Windows widget's graph.py)

    private func appendCSV(_ data: UsageData) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let timestamp = df.string(from: Date())

        let fiveHour = String(format: "%.2f", data.fiveHour?.utilization ?? 0)
        let weekly = String(format: "%.2f", data.sevenDay?.utilization ?? 0)
        let line = "\(timestamp),\(fiveHour),\(weekly)\n"

        if !FileManager.default.fileExists(atPath: csvURL.path) {
            let header = "timestamp,five_hour_pct,weekly_pct\n"
            try? (header + line).write(to: csvURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: csvURL.path)
        } else if let handle = try? FileHandle(forWritingTo: csvURL) {
            handle.seekToEndOfFile()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
            try? handle.close()
        }
    }

    // MARK: - History (last 60 samples for sparkline / ETA)

    private func appendHistory(_ data: UsageData) {
        let bucket = Int(Date().timeIntervalSince1970 / 60)
        let pct = data.fiveHour?.utilization ?? 0

        var history: [[Double]] = []
        if let existing = try? Data(contentsOf: historyURL),
           let decoded = try? JSONDecoder().decode([[Double]].self, from: existing) {
            history = decoded
        }

        history.append([Double(bucket), pct])
        if history.count > 60 {
            history = Array(history.suffix(60))
        }

        if let encoded = try? JSONEncoder().encode(history) {
            try? encoded.write(to: historyURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
    }
}
