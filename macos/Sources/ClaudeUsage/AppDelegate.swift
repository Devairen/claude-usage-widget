import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var authWindow: NSWindow?
    private var pollTimer: Timer?
    private var configObserver: Any?

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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = renderArcIcon(percentage: 0, color: .tertiaryLabelColor)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
        popover.performClose(nil)

        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView(
                onSignIn: { [weak self] in self?.showAuthWindow() }
            ))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Claude Usage — Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 440, height: 360))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Auth Window

    func showAuthWindow() {
        popover.performClose(nil)

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
    }

    // MARK: - Icon Rendering

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let color: NSColor
        switch viewModel.state {
        case .authFailed:    color = .systemOrange
        case .error:         color = .systemRed
        case .needsConfig:   color = .tertiaryLabelColor
        default:             color = Theme.color(for: viewModel.fiveHourPct)
        }
        button.image = renderArcIcon(percentage: viewModel.fiveHourPct, color: color)
    }

    private func renderArcIcon(percentage: Double, color: NSColor) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7
            let lineWidth: CGFloat = 2.5

            // Background track
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            NSColor.tertiaryLabelColor.setStroke()
            track.lineWidth = lineWidth
            track.stroke()

            // Progress arc (starts at top, sweeps visually clockwise)
            // In AppKit's y-up coordinate system, clockwise:false = visually clockwise on screen
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
                    clockwise: false
                )
                color.setStroke()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.stroke()
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
