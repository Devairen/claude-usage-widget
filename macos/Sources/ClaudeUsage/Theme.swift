import AppKit
import SwiftUI

enum Theme {
    // Claude brand palette — warm orange/terracotta, punchy enough to pop in menu bar
    static let claudeTan    = NSColor(red: 0xF5 / 255.0, green: 0x8A / 255.0, blue: 0x3C / 255.0, alpha: 1) // #F58A3C
    static let claudeOrange = NSColor(red: 0xEF / 255.0, green: 0x52 / 255.0, blue: 0x1E / 255.0, alpha: 1) // #EF521E
    static let claudeDeep   = NSColor(red: 0xDE / 255.0, green: 0x2E / 255.0, blue: 0x0C / 255.0, alpha: 1) // #DE2E0C
    static let claudeRed    = NSColor(red: 0xD0 / 255.0, green: 0x12 / 255.0, blue: 0x08 / 255.0, alpha: 1) // #D01208

    // MARK: - Settings-aware color

    /// The danger color that all custom colors blend toward at high usage.
    private static let dangerRed = NSColor(red: 0.85, green: 0.12, blue: 0.08, alpha: 1)

    /// The resolved accent NSColor for the given settings.
    static func accentNSColor(from settings: AppSettings? = nil) -> NSColor {
        if let hex = settings?.customAccentColorHex, let c = nsColor(fromHex: hex) {
            return c
        }
        return claudeOrange
    }

    /// Usage color that adapts to the user's accent color.
    ///
    /// - No custom color: classic Claude palette (tan → orange → deep → red)
    /// - Custom color + keep accent OFF: blends from user's color toward red
    /// - Custom color + keep accent ON: stays user's color at all levels
    static func color(for percentage: Double, settings: AppSettings? = nil) -> NSColor {
        // If user has a custom color
        if let s = settings, s.customAccentColorHex != nil {
            let base = accentNSColor(from: s)

            // "Keep accent" = no shift at all
            if s.alwaysUseAccentColor { return base }

            // Blend toward red — stays base-ish until ~50%, then accelerates
            let t = pow(min(max(percentage, 0), 100) / 100, 2.5)
            return blend(from: base, to: dangerRed, fraction: t)
        }

        // No custom color + keep accent = default orange at all levels
        if let s = settings, s.alwaysUseAccentColor {
            return claudeOrange
        }

        // Default: classic Claude palette
        switch percentage {
        case ..<33:  return claudeTan
        case 33..<66: return claudeOrange
        case 66..<90: return claudeDeep
        default:      return claudeRed
        }
    }

    static func swiftUIColor(for percentage: Double, settings: AppSettings? = nil) -> Color {
        Color(nsColor: color(for: percentage, settings: settings))
    }

    /// Linearly interpolate between two colors in sRGB space.
    private static func blend(from a: NSColor, to b: NSColor, fraction t: CGFloat) -> NSColor {
        let ac = a.usingColorSpace(.sRGB) ?? a
        let bc = b.usingColorSpace(.sRGB) ?? b
        let r = ac.redComponent   + (bc.redComponent   - ac.redComponent)   * t
        let g = ac.greenComponent + (bc.greenComponent - ac.greenComponent) * t
        let bl = ac.blueComponent  + (bc.blueComponent  - ac.blueComponent)  * t
        return NSColor(red: r, green: g, blue: bl, alpha: 1)
    }

    /// The default accent color.
    static let defaultAccent = Color(nsColor: claudeOrange)

    /// SwiftUI accent color from settings.
    static func accent(from settings: AppSettings? = nil) -> Color {
        Color(nsColor: accentNSColor(from: settings))
    }

    /// Parse a hex color string like "#FF6B35" or "FF6B35" into an NSColor.
    static func nsColor(fromHex hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((val >> 16) & 0xFF) / 255.0,
            green: CGFloat((val >> 8) & 0xFF) / 255.0,
            blue: CGFloat(val & 0xFF) / 255.0,
            alpha: 1
        )
    }

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
