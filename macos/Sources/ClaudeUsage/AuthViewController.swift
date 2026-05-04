import AppKit
import WebKit

final class AuthViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var credentialsCaptured = false
    private var extractionInProgress = false

    /// Called with (orgId, cookieString) on successful login.
    var onComplete: ((String, String) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))

        statusLabel = NSTextField(labelWithString: "Checking for existing session…")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

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
            webView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Observe cookie changes — catches login even when didFinish misses it
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
                    self.beginExtraction()
                } else {
                    self.statusLabel.stringValue = "Sign in to your Claude account"
                    self.webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
                }
            }
        }
    }

    // MARK: - Credential extraction

    /// Navigate the WebView to the organizations API endpoint.
    /// The WebView sends its own cookies automatically — no JS fetch needed.
    private func beginExtraction() {
        guard !extractionInProgress else { return }
        extractionInProgress = true
        let url = URL(string: "https://claude.ai/api/organizations")!
        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !credentialsCaptured else { return }

        // If we navigated to /api/organizations, read the JSON response body
        if webView.url?.path == "/api/organizations" {
            readOrganizations()
            return
        }

        // Otherwise, check if the user just logged in (sessionKey appeared)
        checkForSession()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if extractionInProgress {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Network error — try again"
                self.extractionInProgress = false
            }
        }
    }

    private func checkForSession() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.credentialsCaptured else { return }
            let hasSession = cookies.contains { $0.domain.contains("claude.ai") && $0.name == "sessionKey" }
            if hasSession {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Signed in — fetching organization info…"
                    self.beginExtraction()
                }
            }
        }
    }

    private func readOrganizations() {
        // The WebView loaded /api/organizations as a page — the response body is the JSON
        webView.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let self else { return }

            guard let jsonString = result as? String,
                  let jsonData = jsonString.data(using: .utf8) else {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Failed to read organization data. Retrying…"
                    self.extractionInProgress = false
                    // Might have been redirected to login — check again
                    self.checkForSession()
                }
                return
            }

            struct Org: Codable { let uuid: String }
            guard let orgs = try? JSONDecoder().decode([Org].self, from: jsonData),
                  let org = orgs.first else {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "No organizations found — check your account."
                    self.extractionInProgress = false
                }
                return
            }

            // Got org_id — now grab the cookie string
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let cookieString = cookies
                    .filter { $0.domain.contains("claude.ai") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                DispatchQueue.main.async {
                    self.credentialsCaptured = true
                    self.statusLabel.stringValue = "Done — credentials saved."
                    self.onComplete?(org.uuid, cookieString)
                }
            }
        }
    }

    // MARK: - Navigation Policy (HTTPS only — blocks javascript:/file:/data: schemes)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https" else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate (handle OAuth popups)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Only allow HTTPS popups (OAuth redirects)
        if let url = navigationAction.request.url, url.scheme == "https" {
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
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Signed in — fetching organization info…"
                    self.beginExtraction()
                }
            }
        }
    }
}
