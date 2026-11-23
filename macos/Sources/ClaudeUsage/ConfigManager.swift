import Foundation

final class ConfigManager {
    private let configURL: URL
    private let settingsURL: URL
    let appDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appDirectory = appSupport.appendingPathComponent("ClaudeUsage")
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        // Restrict directory to owner-only (rwx------). It holds the Claude
        // session cookie, so a failure is logged instead of swallowed, and the
        // result is read back: setAttributes can succeed on a filesystem that
        // ignores POSIX modes.
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)
        } catch {
            NSLog("ClaudeUsage: could not lock %@ to owner-only: %@", appDirectory.path, error.localizedDescription)
        }
        if let mode = (try? FileManager.default.attributesOfItem(atPath: appDirectory.path))?[.posixPermissions] as? NSNumber,
           mode.intValue & 0o077 != 0 {
            NSLog("ClaudeUsage: %@ is readable by others (mode %o); cookie folder is not locked", appDirectory.path, mode.intValue)
        }
        configURL = appDirectory.appendingPathComponent("config.json")
        settingsURL = appDirectory.appendingPathComponent("settings.json")
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

    // MARK: - Display Settings

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func saveSettings(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }
}
