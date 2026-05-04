import AppKit
import SwiftUI

enum Theme {
    // Claude brand palette — warm orange/terracotta, saturated to pop in menu bar
    static let claudeTan    = NSColor(red: 0xE8 / 255.0, green: 0x9B / 255.0, blue: 0x68 / 255.0, alpha: 1) // #E89B68
    static let claudeOrange = NSColor(red: 0xE0 / 255.0, green: 0x6B / 255.0, blue: 0x3E / 255.0, alpha: 1) // #E06B3E
    static let claudeDeep   = NSColor(red: 0xCC / 255.0, green: 0x48 / 255.0, blue: 0x22 / 255.0, alpha: 1) // #CC4822
    static let claudeRed    = NSColor(red: 0xC0 / 255.0, green: 0x28 / 255.0, blue: 0x1C / 255.0, alpha: 1) // #C0281C

    /// Usage threshold colors — all in the Claude warm family, shifting to red at danger levels.
    static func color(for percentage: Double) -> NSColor {
        switch percentage {
        case ..<33:  return claudeTan
        case 33..<66: return claudeOrange
        case 66..<90: return claudeDeep
        default:      return claudeRed
        }
    }

    static func swiftUIColor(for percentage: Double) -> Color {
        Color(nsColor: color(for: percentage))
    }

    /// The accent color used for headers and branding elements.
    static let accent = Color(nsColor: claudeOrange)

    /// Format an ISO 8601 reset timestamp into "resets in Xh Ym"
    static func resetText(from isoString: String?) -> String? {
        guard let date = parseISO(isoString) else { return nil }

        let remaining = date.timeIntervalSince(Date())
        guard remaining > 0 else { return "resetting…" }

        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours >= 24 {
            let days = hours / 24
            let h = hours % 24
            return "resets in \(days)d \(h)h"
        } else if hours > 0 {
            return "resets in \(hours)h \(minutes)m"
        } else {
            return "resets in \(minutes)m"
        }
    }

    /// Format the reset time as a local clock time, e.g. "(14:32)"
    static func resetClockTime(from isoString: String?) -> String? {
        guard let date = parseISO(isoString) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return "(\(df.string(from: date)))"
    }

    /// Format a duration in minutes as "Xh Ym" or "Xm"
    static func formatMinutes(_ minutes: Double) -> String {
        let total = Int(minutes)
        let h = total / 60
        let m = total % 60
        if h >= 24 {
            return "\(h / 24)d \(h % 24)h"
        } else if h > 0 {
            return "\(h)h \(m)m"
        } else {
            return "\(m)m"
        }
    }

    /// Parse an ISO 8601 date string.
    static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
