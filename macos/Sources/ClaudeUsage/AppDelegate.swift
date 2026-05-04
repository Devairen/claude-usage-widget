import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var authWindow: NSWindow?
    private var pollTimer: Timer?
    private var configObserver: Any?
    private var settingsObserver: Any?
    private var clickOutMonitor: Any?

    let viewModel = UsageViewModel()
    let configManager = ConfigManager()
    private let usageService = UsageService()
    private let loggingService = LoggingService()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        viewModel.bootstrapFromHistory()
        setupStatusItem()
        setupPopover()
        observeConfigChanges()
        startPolling()

        // Auto-open auth on first launch if no config exists
        if configManager.load() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAuthWindow()
            }
        }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = renderArcIcon(percentage: 0, color: .tertiaryLabelColor, settings: configManager.loadSettings())
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Global click monitor — closes popover when clicking anywhere outside
            clickOutMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = clickOutMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutMonitor = nil
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                viewModel: viewModel,
                configManager: configManager,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onSignIn: { [weak self] in self?.showAuthWindow() }
            )
        )
    }

    // MARK: - Settings Window

    func showSettings() {
        closePopover()

        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView(
                onSignIn: { [weak self] in self?.showAuthWindow() }
            ))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Claude Usage — Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 460, height: 560))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Auth Window

    func showAuthWindow() {
        closePopover()

        let authVC = AuthViewController()
        authVC.onComplete = { [weak self] orgId, cookie in
            guard let self else { return }
            let config = AppConfig(orgId: orgId, cookie: cookie)
            try? self.configManager.save(config)
            NotificationCenter.default.post(name: .configUpdated, object: nil)
            self.authWindow?.close()
            self.authWindow = nil
        }

        let window = NSWindow(contentViewController: authVC)
        window.title = "Sign in to Claude"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 640))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        authWindow = window
    }

    // MARK: - Polling

    private func startPolling() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let config = configManager.load() else {
            viewModel.state = .needsConfig
            updateIcon()
            return
        }

        Task { @MainActor in
            do {
                let data = try await usageService.fetch(orgId: config.orgId, cookie: config.cookie)
                viewModel.update(with: data)
                loggingService.log(data)
            } catch is CancellationError {
                // Ignore task cancellation
            } catch let error as UsageError where error == .authFailed {
                viewModel.state = .authFailed
            } catch {
                viewModel.state = .error(error.localizedDescription)
            }
            updateIcon()
        }
    }

    // MARK: - Config observation

    private func observeConfigChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .configUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.poll()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }
    }

    // MARK: - Icon Rendering

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let settings = configManager.loadSettings()
        let color: NSColor
        switch viewModel.state {
        case .authFailed:    color = .systemOrange
        case .error:         color = .systemRed
        case .needsConfig:   color = .tertiaryLabelColor
        default:             color = Theme.color(for: viewModel.fiveHourPct, settings: settings)
        }
        button.image = renderArcIcon(percentage: viewModel.fiveHourPct, color: color, settings: settings)
    }

    // The actual Claude AI logo path (from official SVG, viewBox 0 0 100 100)
    private static let claudeLogoPath = "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"

    /// Draw the Claude logo scaled into a rect, filled with the given color.
    private func drawClaudeLogo(in rect: NSRect, color: NSColor) {
        guard let cgPath = CGPath.from(svgPath: Self.claudeLogoPath) else { return }

        // The SVG viewBox is 0 0 100 100. Scale to fit our rect.
        let svgSize: CGFloat = 100
        let scale = min(rect.width, rect.height) / svgSize
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: rect.origin.x, y: rect.origin.y)
        transform = transform.scaledBy(x: scale, y: scale)

        guard let scaled = cgPath.copy(using: &transform) else { return }
        let bezier = NSBezierPath(cgPath: scaled)
        color.setFill()
        bezier.fill()
    }

    private func renderArcIcon(percentage: Double, color: NSColor, settings: AppSettings) -> NSImage {
        let showPct = settings.showPercentageInBar
        let showIcon = settings.showClaudeIcon

        let iconSize: CGFloat = 18
        let logoSize: CGFloat = 14
        let gap: CGFloat = 3
        var totalWidth: CGFloat = iconSize
        if showIcon { totalWidth += logoSize + gap }
        if showPct { totalWidth += 32 + gap }

        let image = NSImage(size: NSSize(width: totalWidth, height: iconSize), flipped: false) { rect in
            var xOffset: CGFloat = 0

            // Optional Claude logo
            if showIcon {
                let yPos = (rect.height - logoSize) / 2
                self.drawClaudeLogo(in: NSRect(x: xOffset, y: yPos, width: logoSize, height: logoSize), color: color)
                xOffset += logoSize + gap
            }

            // Circular arc
            let center = CGPoint(x: xOffset + iconSize / 2, y: rect.midY)
            let radius: CGFloat = 7
            let lineWidth: CGFloat = 2.5

            // Background track
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            NSColor.tertiaryLabelColor.setStroke()
            track.lineWidth = lineWidth
            track.stroke()

            // Progress arc (starts at top, sweeps visually clockwise)
            let drawPct = max(percentage, 0)
            if drawPct >= 100 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                color.setStroke()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.stroke()
            } else if drawPct > 0 {
                let startAngle: CGFloat = 90
                let endAngle: CGFloat = 90 - (drawPct / 100 * 360)
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle,
                    clockwise: true
                )
                color.setStroke()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.stroke()
            }
            xOffset += iconSize + gap

            // Optional percentage text — vertically centered
            if showPct {
                let pctStr = "\(Int(percentage))%"
                let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color
                ]
                let str = NSAttributedString(string: pctStr, attributes: attrs)
                let textSize = str.size()
                let yPos = (rect.height - textSize.height) / 2
                str.draw(at: NSPoint(x: xOffset, y: yPos))
            }

            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - UsageError Equatable (for pattern matching)

extension UsageError: Equatable {
    static func == (lhs: UsageError, rhs: UsageError) -> Bool {
        switch (lhs, rhs) {
        case (.authFailed, .authFailed): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.httpError(let a), .httpError(let b)): return a == b
        default: return false
        }
    }
}
