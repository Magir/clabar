import Foundation
import Combine
import CryptoKit
import AppKit

// Ported from Blimp-Labs/claude-usage-bar (BSD-2-Clause); trimmed and adapted
// to dynamic buckets.

/// claude.com service health from the public Statuspage API.
struct ServiceStatus: Equatable {
    let indicator: String   // none | minor | major | critical | maintenance
    let description: String

    var isOperational: Bool { indicator == "none" }

    static func decode(from data: Data) -> ServiceStatus? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String else { return nil }
        return ServiceStatus(
            indicator: indicator,
            description: (status["description"] as? String) ?? indicator
        )
    }
}

@MainActor
final class UsageService: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var serviceStatus: ServiceStatus?
    @Published var isAuthenticated = false
    @Published var isAwaitingCode = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var pollingMinutes: Int

    var historyService: HistoryService?

    private var timer: Timer?
    private let session: URLSession
    private let credentialsStore: StoredCredentialsStore
    private var currentInterval: TimeInterval

    private enum RefreshResult { case success, permanentFailure, transientFailure }
    private var refreshTask: Task<RefreshResult, Never>?

    static let defaultPollingMinutes = 15
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 3600
    nonisolated static let defaultOAuthScopes = ["user:profile", "user:inference"]
    nonisolated private static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    nonisolated private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated private static let userinfoEndpoint = URL(string: "https://api.anthropic.com/api/oauth/userinfo")!
    nonisolated private static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    nonisolated private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    // PKCE state (lives only during an auth flow)
    private var codeVerifier: String?
    private var oauthState: String?

    init(session: URLSession = .shared, credentialsStore: StoredCredentialsStore = StoredCredentialsStore()) {
        self.session = session
        self.credentialsStore = credentialsStore
        let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
        let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
        self.pollingMinutes = minutes
        self.currentInterval = TimeInterval(minutes * 60)
        isAuthenticated = credentialsStore.load(defaultScopes: Self.defaultOAuthScopes) != nil
    }

    private var baseInterval: TimeInterval { TimeInterval(pollingMinutes * 60) }

    func updatePollingInterval(_ minutes: Int) {
        pollingMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "pollingMinutes")
        currentInterval = TimeInterval(minutes * 60)
        if isAuthenticated {
            scheduleTimer()
            Task { await fetchUsage() }
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard isAuthenticated else { return }
        Task {
            await fetchUsage()
            if accountEmail == nil { await fetchProfile() }
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isAuthenticated else { return }
                Task { await self.fetchUsage() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - OAuth PKCE flow

    func startOAuthFlow() {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateCodeVerifier()
        codeVerifier = verifier
        oauthState = state

        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.defaultOAuthScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
            isAwaitingCode = true
        }
    }

    func submitOAuthCode(_ rawCode: String) async {
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard let code = parts.first.map(String.init), !code.isEmpty else {
            lastError = L("Код не введён", "No code entered")
            return
        }
        if parts.count > 1, String(parts[1]) != oauthState {
            lastError = L("OAuth state не совпал — попробуйте ещё раз", "OAuth state mismatch — try again")
            isAwaitingCode = false
            codeVerifier = nil
            oauthState = nil
            return
        }
        guard let verifier = codeVerifier else {
            lastError = L("Нет активного OAuth-потока", "No pending OAuth flow")
            isAwaitingCode = false
            return
        }

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": oauthState ?? "",
            "client_id": clientId,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = L("Обмен кода не удался: ", "Code exchange failed: ") + "HTTP \(status)"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credentials = credentials(from: json) else {
                lastError = L("Не удалось разобрать ответ токена", "Could not parse token response")
                return
            }
            try credentialsStore.save(credentials)
            isAuthenticated = true
            isAwaitingCode = false
            lastError = nil
            codeVerifier = nil
            oauthState = nil
            await fetchProfile()
            startPolling()
        } catch {
            lastError = L("Ошибка обмена кода: ", "Code exchange error: ") + error.localizedDescription
        }
    }

    func signOut() {
        credentialsStore.delete()
        expireSession()
        lastError = nil
    }

    // MARK: - PKCE helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    // MARK: - Fetch

    func fetchUsage() async {
        // Piggy-back the claude.com health check on every usage poll.
        Task { await fetchServiceStatus() }

        guard credentialsStore.load(defaultScopes: Self.defaultOAuthScopes) != nil else {
            lastError = L("Не выполнен вход", "Not signed in")
            isAuthenticated = false
            return
        }
        do {
            guard let (data, http) = try await sendAuthorizedRequest(to: Self.usageEndpoint) else { return }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? currentInterval
                currentInterval = min(max(retryAfter, currentInterval * 2), Self.maxBackoffInterval)
                lastError = LT("Rate limit — интервал увеличен до {s}с", "Rate limited — backing off to {s}s", ["s": "\(Int(currentInterval))"])
                scheduleTimer()
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let decoded = try UsageResponse.decode(from: data)
            usage = decoded.reconciled(with: usage)
            lastError = nil
            lastUpdated = Date()
            if let usage { historyService?.record(usage: usage) }
            if currentInterval != baseInterval {
                currentInterval = baseInterval
                scheduleTimer()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated private static let statusEndpoint = URL(string: "https://status.claude.com/api/v2/status.json")!

    func fetchServiceStatus() async {
        guard let (data, response) = try? await session.data(from: Self.statusEndpoint),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = ServiceStatus.decode(from: data) else { return } // keep the last known state
        serviceStatus = status
    }

    func fetchProfile() async {
        if let local = Self.loadLocalProfile() {
            accountEmail = local
            return
        }
        guard let (data, http) = try? await sendAuthorizedRequest(
            to: Self.userinfoEndpoint, expireSessionOnAuthFailure: false
        ), http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let email = json["email"] as? String, !email.isEmpty {
            accountEmail = email
        } else if let name = json["name"] as? String, !name.isEmpty {
            accountEmail = name
        }
    }

    /// Fallback: read the account email from Claude Code's local config.
    nonisolated private static func loadLocalProfile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        if let email = account["emailAddress"] as? String, !email.isEmpty { return email }
        if let name = account["displayName"] as? String, !name.isEmpty { return name }
        return nil
    }

    // MARK: - Authorized requests

    private func sendAuthorizedRequest(
        to url: URL,
        expireSessionOnAuthFailure: Bool = true
    ) async throws -> (Data, HTTPURLResponse)? {
        guard let initialCredentials = credentialsStore.load(defaultScopes: Self.defaultOAuthScopes) else {
            lastError = L("Не выполнен вход", "Not signed in")
            isAuthenticated = false
            return nil
        }

        if initialCredentials.needsRefresh() {
            let refreshResult = await refreshCredentials()
            if refreshResult != .success, initialCredentials.isExpired() {
                switch refreshResult {
                case .permanentFailure:
                    if expireSessionOnAuthFailure { expireSession(message: L("Сессия истекла — войдите заново", "Session expired — sign in again")) }
                case .transientFailure:
                    lastError = L("Не удалось обновить токен — повторю позже", "Token refresh failed — will retry")
                case .success:
                    break
                }
                return nil
            }
        }

        let active = credentialsStore.load(defaultScopes: Self.defaultOAuthScopes) ?? initialCredentials
        var result = try await performAuthorizedRequest(token: active.accessToken, url: url)
        if result.1.statusCode != 401 { return result }

        switch await refreshCredentials() {
        case .success:
            guard let refreshed = credentialsStore.load(defaultScopes: Self.defaultOAuthScopes) else {
                if expireSessionOnAuthFailure { expireSession(message: L("Сессия истекла — войдите заново", "Session expired — sign in again")) }
                return nil
            }
            result = try await performAuthorizedRequest(token: refreshed.accessToken, url: url)
            if result.1.statusCode == 401 {
                if expireSessionOnAuthFailure { expireSession(message: L("Сессия истекла — войдите заново", "Session expired — sign in again")) }
                return nil
            }
            return result
        case .permanentFailure:
            if expireSessionOnAuthFailure { expireSession(message: L("Сессия истекла — войдите заново", "Session expired — sign in again")) }
            return nil
        case .transientFailure:
            lastError = L("Не удалось обновить токен — повторю позже", "Token refresh failed — will retry")
            return nil
        }
    }

    private func performAuthorizedRequest(token: String, url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func refreshCredentials() async -> RefreshResult {
        if let refreshTask { return await refreshTask.value }
        let task = Task { [weak self] in
            guard let self else { return RefreshResult.permanentFailure }
            return await self.performRefresh()
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func performRefresh() async -> RefreshResult {
        guard let current = credentialsStore.load(defaultScopes: Self.defaultOAuthScopes),
              let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            return .permanentFailure
        }

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        if !current.scopes.isEmpty {
            body["scope"] = current.scopes.joined(separator: " ")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .transientFailure }
            data = responseData
            http = httpResponse
        } catch {
            return .transientFailure
        }

        guard http.statusCode == 200 else {
            return (400..<500).contains(http.statusCode) ? .permanentFailure : .transientFailure
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = credentials(from: json, fallback: current) else {
            return .transientFailure
        }
        do {
            try credentialsStore.save(updated)
        } catch {
            return .transientFailure
        }
        isAuthenticated = true
        return .success
    }

    private func credentials(from json: [String: Any], fallback: StoredCredentials? = nil) -> StoredCredentials? {
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else { return nil }
        let scopes = (json["scope"] as? String)?
            .split(whereSeparator: \.isWhitespace).map(String.init)
            ?? fallback?.scopes ?? Self.defaultOAuthScopes
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
            ?? (json["expires_in"] as? String).flatMap(Double.init)
        return StoredCredentials(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? fallback?.refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) } ?? fallback?.expiresAt,
            scopes: scopes
        )
    }

    private func expireSession(message: String? = nil) {
        isAuthenticated = false
        usage = nil
        lastUpdated = nil
        accountEmail = nil
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let message { lastError = message }
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
