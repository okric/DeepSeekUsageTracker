import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    enum TokenSource: String, Sendable {
        case none
        case browser
        case harness
    }

    @Published private(set) var snapshot = AppSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var isImportingHarness = false
    @Published private(set) var hasAPIKey = false
    @Published private(set) var hasOAuthToken = false
    @Published private(set) var hasUsageToken = false
    @Published private(set) var accountName: String?
    @Published private(set) var tokenSource: TokenSource = .none
    @Published private(set) var refreshInterval: TimeInterval = 300
    @Published private(set) var lastError: String?
    @Published private(set) var harnessAvailable = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var isChangingLaunchAtLogin = false

    private let api: DeepSeekAPI
    private let credentials: KeychainStore
    private let auth: DeepSeekAuth
    private let defaults: UserDefaults

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var signInTask: Task<Void, Never>?

    private let refreshKey = "refreshInterval"
    private let accountNameKey = "accountName"
    private let tokenSourceKey = "tokenSource"
    private let loginConfiguredKey = "didConfigureLoginItem"
    private let loginItemPathKey = "loginItemPath"

    init(
        api: DeepSeekAPI = .shared,
        credentials: KeychainStore = KeychainStore(),
        auth: DeepSeekAuth? = nil,
        defaults: UserDefaults = .standard)
    {
        self.api = api
        self.credentials = credentials
        self.auth = auth ?? DeepSeekAuth(api: api)
        self.defaults = defaults

        self.hasAPIKey = credentials.has(.apiKey)
        self.hasOAuthToken = credentials.has(.oauthToken)
        self.hasUsageToken = credentials.has(.usageToken)
        self.accountName = defaults.string(forKey: accountNameKey)
        self.tokenSource = TokenSource(rawValue: defaults.string(forKey: tokenSourceKey) ?? "") ?? .none
        let storedInterval = defaults.double(forKey: refreshKey)
        self.refreshInterval = storedInterval >= 60 ? storedInterval : 300
        self.harnessAvailable = HarnessImporter.fileExists()
    }

    var hasAnyCredential: Bool {
        hasAPIKey || hasOAuthToken || hasUsageToken
    }

    var hasAccountToken: Bool {
        hasOAuthToken || hasUsageToken
    }

    // MARK: Lifecycle

    func start() {
        refreshLaunchAtLoginStatus()
        scheduleTimer()
        Task { @MainActor in
            // LaunchServices may not know this bundle during the first launch tick.
            try? await Task.sleep(for: .milliseconds(1_500))
            configureLoginItemOnFirstLaunchIfNeeded()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        signInTask?.cancel()
        signInTask = nil
        auth.cancel()
    }

    // MARK: Refresh

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        snapshot.isLoading = true
        defer {
            isLoading = false
            snapshot.isLoading = false
        }

        let apiKey = credentials.read(.apiKey)
        let oauthToken = credentials.read(.oauthToken)
        let usageToken = credentials.read(.usageToken)
        hasAPIKey = apiKey != nil
        hasOAuthToken = oauthToken != nil
        hasUsageToken = usageToken != nil

        guard apiKey != nil || oauthToken != nil || usageToken != nil else {
            snapshot = AppSnapshot()
            lastError = nil
            return
        }

        let preferredCurrency = snapshot.balance?.currency
        async let balanceResult = capture {
            try await self.fetchBalance(apiKey: apiKey, oauthToken: oauthToken, usageToken: usageToken)
        }
        async let usageResult = capture {
            try await self.fetchUsage(oauthToken: oauthToken, usageToken: usageToken, preferredCurrency: preferredCurrency)
        }
        let (balanceOutcome, usageOutcome) = await (balanceResult, usageResult)

        var newSnapshot = snapshot
        var errors: [String] = []
        newSnapshot.needsReauth = false

        switch balanceOutcome {
        case let .success(balance):
            newSnapshot.balance = balance
        case let .failure(error):
            if isUnauthorized(error) { newSnapshot.needsReauth = true }
            errors.append("Balance — \(message(for: error))")
        }

        switch usageOutcome {
        case let .success(usage):
            newSnapshot.usage = usage
        case let .failure(error):
            if case APIError.missingCredentials = error {
                // No usage credential is a normal state, not an error.
            } else {
                if isUnauthorized(error) { newSnapshot.needsReauth = true }
                errors.append("Usage — \(message(for: error))")
            }
        }

        if case .success = balanceOutcome {
            newSnapshot.updatedAt = Date()
        } else if case .success = usageOutcome {
            newSnapshot.updatedAt = Date()
        }

        newSnapshot.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        newSnapshot.isStale = !errors.isEmpty && newSnapshot.updatedAt != nil
        newSnapshot.isLoading = false
        snapshot = newSnapshot
        lastError = newSnapshot.error
    }

    func refreshNow() {
        Task { await refresh() }
    }

    private func fetchBalance(
        apiKey: String?,
        oauthToken: String?,
        usageToken: String?
    ) async throws -> BalanceSnapshot {
        if let apiKey {
            return try await api.fetchBalance(apiKey: apiKey)
        }
        if let oauthToken {
            return try await api.fetchPlatformBalance(token: oauthToken, kind: .oauth)
        }
        if let usageToken {
            return try await api.fetchPlatformBalance(token: usageToken, kind: .web)
        }
        throw APIError.missingCredentials
    }

    private func fetchUsage(
        oauthToken: String?,
        usageToken: String?,
        preferredCurrency: String?
    ) async throws -> UsageSnapshot {
        if let oauthToken {
            do {
                return try await api.fetchUsage(
                    token: oauthToken,
                    kind: .oauth,
                    preferredCurrency: preferredCurrency)
            } catch let error as APIError where error.isUnauthorized {
                if let usageToken {
                    return try await api.fetchUsage(
                        token: usageToken,
                        kind: .web,
                        preferredCurrency: preferredCurrency)
                }
                throw error
            }
        }
        if let usageToken {
            return try await api.fetchUsage(
                token: usageToken,
                kind: .web,
                preferredCurrency: preferredCurrency)
        }
        throw APIError.missingCredentials
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    // MARK: DeepSeek Harness import

    func checkHarnessAvailability() {
        harnessAvailable = HarnessImporter.fileExists()
    }

    func importHarnessAPIKey() async throws {
        let login = try HarnessImporter.load()
        guard let apiKey = login.apiKey, !apiKey.isEmpty else {
            throw HarnessImportError.noAPIKey
        }
        try credentials.save(apiKey, for: .apiKey)
        hasAPIKey = true
        await refresh()
    }

    func importHarnessLogin() async throws {
        guard !isImportingHarness else { return }
        isImportingHarness = true
        lastError = nil
        defer { isImportingHarness = false }

        do {
            let login = try HarnessImporter.load()
            try credentials.save(login.accountToken, for: .oauthToken)
            hasOAuthToken = true
            tokenSource = .harness
            defaults.set(TokenSource.harness.rawValue, forKey: tokenSourceKey)

            if !hasAPIKey, let apiKey = login.apiKey, !apiKey.isEmpty {
                try? credentials.save(apiKey, for: .apiKey)
                hasAPIKey = credentials.has(.apiKey)
            }

            if let user = try? await api.fetchProfile(token: login.accountToken, kind: .oauth) {
                let name = user.displayName ?? user.contact
                accountName = name
                defaults.set(name, forKey: accountNameKey)
            }

            await refresh()
        } catch {
            lastError = message(for: error)
            throw error
        }
    }

    // MARK: Browser sign-in

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSigningIn = false }
            do {
                let result = try await self.auth.signIn()
                try self.credentials.save(result.token, for: .oauthToken)
                self.hasOAuthToken = true
                self.tokenSource = .browser
                self.defaults.set(TokenSource.browser.rawValue, forKey: self.tokenSourceKey)

                if let user = result.user {
                    let name = user.displayName ?? user.contact
                    self.accountName = name
                    self.defaults.set(name, forKey: self.accountNameKey)
                } else if let user = try? await self.api.fetchProfile(token: result.token, kind: .oauth) {
                    let name = user.displayName ?? user.contact
                    self.accountName = name
                    self.defaults.set(name, forKey: self.accountNameKey)
                }

                await self.refresh()
            } catch let error as AuthError where error == .cancelled {
                // User cancelled; do not surface an error.
            } catch {
                if !Task.isCancelled {
                    self.lastError = self.message(for: error)
                }
            }
        }
    }

    func cancelSignIn() {
        auth.cancel()
        signInTask?.cancel()
    }

    func signOut() {
        try? credentials.delete(.oauthToken)
        hasOAuthToken = false
        tokenSource = .none
        accountName = nil
        defaults.removeObject(forKey: tokenSourceKey)
        defaults.removeObject(forKey: accountNameKey)
        refreshNow()
    }

    // MARK: Credentials

    func saveAPIKey(_ rawValue: String) async throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw APIError.missingCredentials
        }
        try credentials.save(value, for: .apiKey)
        hasAPIKey = true
        lastError = nil

        do {
            let balance = try await api.fetchBalance(apiKey: value)
            snapshot.balance = balance
            snapshot.updatedAt = Date()
            snapshot.error = nil
        } catch {
            if let apiError = error as? APIError, apiError.isUnauthorized {
                try? credentials.delete(.apiKey)
                hasAPIKey = false
            }
            lastError = message(for: error)
            throw error
        }
        await refresh()
    }

    func removeAPIKey() {
        try? credentials.delete(.apiKey)
        hasAPIKey = false
        refreshNow()
    }

    func saveUsageToken(_ rawValue: String) async throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw APIError.missingCredentials
        }
        try credentials.save(value, for: .usageToken)
        hasUsageToken = true
        lastError = nil

        do {
            _ = try await api.fetchUsage(
                token: value,
                kind: .web,
                preferredCurrency: snapshot.balance?.currency)
        } catch {
            if let apiError = error as? APIError, apiError.isUnauthorized {
                try? credentials.delete(.usageToken)
                hasUsageToken = false
            }
            lastError = message(for: error)
            throw error
        }
        await refresh()
    }

    func removeUsageToken() {
        try? credentials.delete(.usageToken)
        hasUsageToken = false
        refreshNow()
    }

    // MARK: Refresh interval

    func setRefreshInterval(_ interval: TimeInterval) {
        let clamped = min(max(interval, 60), 3600)
        refreshInterval = clamped
        defaults.set(clamped, forKey: refreshKey)
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    // MARK: Preview

    #if DEBUG
    /// A deterministic connected account used by the Xcode preview canvas.
    static func preview() -> AppModel {
        let model = AppModel(credentials: KeychainStore(
            service: "com.deepseekusage.tracker.preview"))
        model.hasAPIKey = true
        model.hasOAuthToken = true
        model.accountName = "dev@example.com"
        model.tokenSource = .harness
        model.harnessAvailable = true
        model.snapshot = AppSnapshot(
            balance: BalanceSnapshot(
                currency: "USD",
                total: 7.41,
                granted: 0,
                toppedUp: 7.41,
                isAvailable: true,
                source: .platform,
                extras: [CurrencyAmount(
                    currency: "CNY",
                    total: 3.31,
                    granted: 3.31,
                    toppedUp: 0)]),
            usage: UsageSnapshot(
                currency: "CNY",
                cost: 2.64,
                totalTokens: 30_020_659,
                cacheHitTokens: 29_233_408,
                cacheMissTokens: 364_346,
                outputTokens: 422_905,
                requests: 180,
                periodCost: 2.64,
                periodTokens: 197_603_107,
                daily: [],
                period: .last30Days,
                approximate: false),
            updatedAt: Date(),
            error: nil)
        return model
    }
    #endif

    // MARK: Launch at login

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginNeedsApproval = false
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginNeedsApproval = true
        case .notRegistered, .notFound:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
        @unknown default:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        launchAtLoginError = nil
        Task {
            defer {
                isChangingLaunchAtLogin = false
                refreshLaunchAtLoginStatus()
            }
            do {
                if enabled {
                    if SMAppService.mainApp.status == .notRegistered {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
                defaults.set(true, forKey: loginConfiguredKey)
                defaults.set(Bundle.main.bundlePath, forKey: loginItemPathKey)
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The app is installed in /Applications for distribution. On its first launch
    /// there, opt into launch-at-login once; the Settings toggle remains authoritative.
    private var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        return path.hasPrefix("/Applications/") || path.hasPrefix(homeApplications + "/")
    }

    private func configureLoginItemOnFirstLaunchIfNeeded() {
        let currentPath = Bundle.main.bundlePath
        let configured = defaults.bool(forKey: loginConfiguredKey)
        let configuredPath = defaults.string(forKey: loginItemPathKey)
        guard !configured || configuredPath != currentPath else { return }
        guard isInApplicationsFolder else { return }

        func markConfigured() {
            defaults.set(true, forKey: loginConfiguredKey)
            defaults.set(currentPath, forKey: loginItemPathKey)
            refreshLaunchAtLoginStatus()
        }

        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            markConfigured()
        case .notRegistered, .notFound:
            do {
                try SMAppService.mainApp.register()
                markConfigured()
            } catch {
                // Leave the flag unset so a later launch can retry; Settings still
                // exposes the explicit toggle.
                launchAtLoginError = error.localizedDescription
            }
        @unknown default:
            break
        }
    }

    // MARK: Links

    func openUsagePage() {
        guard let url = URL(string: "https://platform.deepseek.com/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Error helpers

    private func isUnauthorized(_ error: Error) -> Bool {
        if let error = error as? APIError { return error.isUnauthorized }
        return false
    }

    private func message(for error: Error) -> String {
        if let error = error as? APIError { return error.errorDescription ?? "DeepSeek error" }
        if let error = error as? AuthError { return error.errorDescription ?? "Sign-in failed" }
        if let error = error as? HarnessImportError { return error.errorDescription ?? "Could not import login" }
        if let error = error as? KeychainStore.KeychainError { return error.errorDescription ?? "Keychain error" }
        return error.localizedDescription
    }
}
