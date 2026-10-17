import Foundation

// MARK: - API Response

struct UsageData: Codable {
    let fiveHour: UsageEntry?
    let sevenDay: UsageEntry?
    let sevenDaySonnet: UsageEntry?
    let sevenDayOpus: UsageEntry?
    let sevenDayOmelette: UsageEntry?  // "Design" tier
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case sevenDayOmelette = "seven_day_omelette"
        case extraUsage = "extra_usage"
    }
}

struct UsageEntry: Codable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?
    let currency: String?
    let decimalPlaces: Int?  // amounts are in minor units (cents); 2 → divide by 100

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
        case currency
        case decimalPlaces = "decimal_places"
    }

    private var divisor: Double { pow(10, Double(decimalPlaces ?? 2)) }
    var usedAmount: Double { (usedCredits ?? 0) / divisor }
    var limitAmount: Double { (monthlyLimit ?? 0) / divisor }
}

// MARK: - Config

struct AppConfig: Codable {
    let orgId: String
    let cookie: String

    enum CodingKeys: String, CodingKey {
        case orgId = "org_id"
        case cookie
    }
}

// MARK: - Display Settings (persisted separately from credentials)

struct AppSettings: Codable {
    var showPercentageInBar: Bool = false
    var showClaudeIcon: Bool = false
    var customAccentColorHex: String? = nil  // e.g. "#FF6B35"
    var alwaysUseAccentColor: Bool = false   // true = don't shift to red at high usage
}

// MARK: - Errors

enum UsageError: Error, LocalizedError {
    case authFailed
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .authFailed:
            return "Authentication failed — refresh your cookie"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error \(code)"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let configUpdated = Notification.Name("ClaudeUsageConfigUpdated")
    static let settingsUpdated = Notification.Name("ClaudeUsageSettingsUpdated")
}
