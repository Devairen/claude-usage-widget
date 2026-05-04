import AppKit
import WebKit

final class AuthViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var retryButton: NSButton!
    private var credentialsCaptured = false
    private var extractionInProgress = false
    private var extractionRetries = 0

    /// Called with (orgId, cookieString) on successful login.
    var onComplete: ((String, String) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))

        // Bottom bar with status + retry button
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bottomBar)

        statusLabel = NSTextField(labelWithString: "Checking for existing session…")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(statusLabel)

        retryButton = NSButton(title: "Retry", target: self, action: #selector(retryExtraction))
        retryButton.controlSize = .small
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(retryButton)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),

            statusLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -8),

            retryButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
            retryButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        checkExistingSession()
    }

    // MARK: - Session check

    private func checkExistingSession() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let hasSession = cookies.contains { $0.domain.contains("claude.ai") && $0.name == "sessionKey" }

            DispatchQueue.main.async {
                if hasSession {
                    self.statusLabel.stringValue = "Found existing session — refreshing credentials…"
                    // Load claude.ai so we have a page context for fetch()
                    self.webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
                } else {
                    self.statusLabel.stringValue = "Sign in to your Claude account"
                    self.webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
                }
            }
        }
    }

    // MARK: - Credential extraction via JS fetch (no page navigation needed)

    private func beginExtraction() {
        guard !extractionInProgress else { return }
        extractionInProgress = true
        retryButton.isHidden = true
        statusLabel.stringValue = "Fetching organization info…"

        // Use fetch() from the page context — same-origin, uses cookies automatically,
        // no Cloudflare challenge, returns clean JSON (not browser-rendered HTML).
        // callAsyncJavaScript wraps this in an async function automatically — just provide the body.
        let js = """
        const r = await fetch('/api/organizations', {credentials: 'same-origin'});
        if (!r.ok) return JSON.stringify({error: 'HTTP ' + r.status});
        const data = await r.json();
        return JSON.stringify(data);
        """

        webView.callAsyncJavaScript(js, in: nil, in: .page) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let value):
                guard let jsonString = value as? String,
                      let jsonData = jsonString.data(using: .utf8) else {
                    self.handleExtractionFailure("Empty response from API")
                    return
                }

                // Check for error response
                struct ErrorResp: Codable { let error: String? }
                if let errResp = try? JSONDecoder().decode(ErrorResp.self, from: jsonData),
                   let errMsg = errResp.error {
                    self.handleExtractionFailure("API error: \(errMsg)")
                    return
                }

                // Parse org list
                struct Org: Codable { let uuid: String }
                if let orgs = try? JSONDecoder().decode([Org].self, from: jsonData),
                   let org = orgs.first {
                    self.captureCredentials(orgId: org.uuid)
                    return
                }

                self.handleExtractionFailure("No organizations found in response")

            case .failure(let error):
                self.handleExtractionFailure("JS error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func retryExtraction() {
        extractionInProgress = false
        extractionRetries = 0
        statusLabel.stringValue = "Retrying…"
        // Navigate to claude.ai first to ensure we have page context
        webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !credentialsCaptured else { return }

        // If we're on claude.ai (not login or OAuth), try extraction
        if let host = webView.url?.host, host.contains("claude.ai"),
           webView.url?.path != "/login" {
            checkForSessionThenExtract()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        // Ignore cancellations (e.g. from redirects)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }

        if extractionInProgress {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Network error — click Retry"
                self.retryButton.isHidden = false
                self.extractionInProgress = false
            }
        }
    }

    private func checkForSessionThenExtract() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.credentialsCaptured else { return }
            let hasSession = cookies.contains { $0.domain.contains("claude.ai") && $0.name == "sessionKey" }
            if hasSession && !self.extractionInProgress {
                DispatchQueue.main.async {
                    self.beginExtraction()
                }
            }
        }
    }

    private func captureCredentials(orgId: String) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let cookieString = cookies
                .filter { $0.domain.contains("claude.ai") }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            guard !cookieString.isEmpty else {
                DispatchQueue.main.async {
                    self.handleExtractionFailure("No cookies found")
                }
                return
            }

            DispatchQueue.main.async {
                self.credentialsCaptured = true
                self.statusLabel.stringValue = "Done — credentials saved."
                self.retryButton.isHidden = true
                self.onComplete?(orgId, cookieString)
            }
        }
    }

    private func handleExtractionFailure(_ reason: String) {
        extractionInProgress = false

        if extractionRetries < 2 {
            extractionRetries += 1
            statusLabel.stringValue = "\(reason). Retrying (\(extractionRetries)/2)…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, !self.credentialsCaptured else { return }
                self.beginExtraction()
            }
        } else {
            statusLabel.stringValue = "\(reason). Click Retry or check your account."
            retryButton.isHidden = false
        }
    }

    // MARK: - Navigation Policy (block dangerous schemes only)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" || scheme == "http" || scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    // MARK: - WKUIDelegate (handle OAuth popups)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - Cookie Observer

extension AuthViewController: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard !credentialsCaptured, !extractionInProgress else { return }

        cookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.credentialsCaptured, !self.extractionInProgress else { return }
            let hasSession = cookies.contains { $0.domain.contains("claude.ai") && $0.name == "sessionKey" }
            if hasSession {
                // Wait a moment for the post-login redirect to settle, then extract
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, !self.credentialsCaptured, !self.extractionInProgress else { return }
                    self.statusLabel.stringValue = "Signed in — fetching organization info…"
                    self.beginExtraction()
                }
            }
        }
    }
}
