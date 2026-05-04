import Foundation

final class ConfigManager {
    private let configURL: URL
    let appDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appDirectory = appSupport.appendingPathComponent("ClaudeUsage")
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        // Restrict directory to owner-only (rwx------)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)
        configURL = appDirectory.appendingPathComponent("config.json")
    }

    func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
        // Cookie file must be owner-only (rw-------)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    /// Days since config.json was last modified — proxy for cookie freshness.
    var configAgeDays: Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return nil }
        return Calendar.current.dateComponents([.day], from: modDate, to: Date()).day
    }

    var configPath: String { configURL.path }
}
