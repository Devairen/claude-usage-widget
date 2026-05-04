import Foundation

final class UsageService {
    private static let uuidPattern = try! Regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")

    func fetch(orgId: String, cookie: String) async throws -> UsageData {
        // Validate org_id is a proper UUID to prevent URL injection
        guard orgId.wholeMatch(of: Self.uuidPattern) != nil,
              let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else {
            throw UsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Chrome-impersonation headers (must match the TLS fingerprint dance)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "\"Google Chrome\";v=\"147\", \"Not.A/Brand\";v=\"8\", \"Chromium\";v=\"147\"",
            forHTTPHeaderField: "Sec-Ch-Ua"
        )
        request.setValue("?0", forHTTPHeaderField: "Sec-Ch-Ua-Mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "Sec-Ch-Ua-Platform")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(UsageData.self, from: data)
        case 401, 403:
            throw UsageError.authFailed
        default:
            throw UsageError.httpError(http.statusCode)
        }
    }
}
