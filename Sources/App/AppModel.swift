import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var harnessAvailable = false
    /// Non-nil when the Harness credential file exists but holds no usable login.
    @Published private(set) var harnessSetupError: String?
    @Published private(set) var accountName: String?
    @Published private(set) var refreshInterval: TimeInterval = 300
    @Published private(set) var lastError: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var isChangingLaunchAtLogin = false

    private let api: DeepSeekAPI
    private let defaults: UserDefaults

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private let refreshKey = "refreshInterval"
    private let accountNameKey = "accountName"
    private let loginConfiguredKey = "didConfigureLoginItem"
    private let loginItemPathKey = "loginItemPath"

    init(api: DeepSeekAPI = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        let storedInterval = defaults.double(forKey: refreshKey)
        refreshInterval = storedInterval >= 60 ? storedInterval : 300
        accountName = defaults.string(forKey: accountNameKey)
        harnessAvailable = HarnessImporter.fileExists()
    }

    // MARK: Lifecycle

    func start() {
        refreshLaunchAtLoginStatus()
        scheduleTimer()
        Task { @MainActor in
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
    }

    // MARK: Refresh

    /// Single credential source: the DeepSeek Harness credential file, read
    /// live at every refresh so DSH-side token renewals flow through.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        snapshot.isLoading = true
        defer {
            isLoading = false
            snapshot.isLoading = false
        }

        harnessAvailable = HarnessImporter.fileExists()

        guard harnessAvailable else {
            snapshot.balance = nil
            snapshot.usage = nil
            snapshot.updatedAt = nil
            snapshot.error = nil
            snapshot.needsReauth = false
            snapshot.isStale = false
            harnessSetupError = HarnessImporter.fileExists()
                ? nil
                : HarnessImportError.fileMissing.errorDescription
            lastError = nil
            return
        }

        let login: HarnessLogin
        do {
            login = try HarnessImporter.load()
            harnessSetupError = nil
        } catch {
            harnessSetupError = (error as? LocalizedError)?.errorDescription
            snapshot.balance = nil
            snapshot.usage = nil
            snapshot.updatedAt = nil
            snapshot.error = nil
            lastError = nil
            return
        }

        // Account name is fetched once per harness session.
        if accountName == nil {
            if let user = try? await api.fetchProfile(token: login.accountToken, kind: .oauth) {
                accountName = user.displayName ?? user.contact
                defaults.set(accountName, forKey: accountNameKey)
            }
        }

        let preferredCurrency = snapshot.balance?.currency
        async let balanceResult = capture {
            try await Self.fetchBalance(api: api, login: login)
        }
        async let usageResult = capture {
            try await api.fetchUsage(
                token: login.accountToken,
                kind: .oauth,
                preferredCurrency: preferredCurrency)
        }
        let (balanceOutcome, usageOutcome) = await (balanceResult, usageResult)

        var newSnapshot = snapshot
        var errors: [String] = []
        newSnapshot.needsReauth = false

        switch balanceOutcome {
        case let .success(balance):
            newSnapshot.balance = balance
        case let .failure(error):
            if Self.isUnauthorized(error) { newSnapshot.needsReauth = true }
            errors.append("Balance — \(Self.message(for: error))")
        }

        switch usageOutcome {
        case let .success(usage):
            newSnapshot.usage = usage
        case let .failure(error):
            if Self.isUnauthorized(error) { newSnapshot.needsReauth = true }
            errors.append("Usage — \(Self.message(for: error))")
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

    private static func fetchBalance(api: DeepSeekAPI, login: HarnessLogin) async throws -> BalanceSnapshot {
        // The official balance endpoint needs an API key; the Harness file
        // carries one only when DSH created it. Fall back to the platform
        // account summary with the account token.
        if let apiKey = login.apiKey, !apiKey.isEmpty {
            do {
                return try await api.fetchBalance(apiKey: apiKey)
            } catch let error as APIError where !error.isUnauthorized {
                // Network/runtime errors on the official endpoint degrade to
                // the platform wallet instead of failing the whole refresh.
                loggingWarningIfDebug("official balance failed: \(error)")
                return try await api.fetchPlatformBalance(token: login.accountToken, kind: .oauth)
            }
        }
        return try await api.fetchPlatformBalance(token: login.accountToken, kind: .oauth)
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        (error as? APIError)?.isUnauthorized == true
    }

    private static func message(for error: Error) -> String {
        if let error = error as? APIError { return error.errorDescription ?? "DeepSeek error" }
        if let error = error as? HarnessImportError { return error.localizedDescription }
        return error.localizedDescription
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private static func loggingWarningIfDebug(_ text: String) {
        // Values here are endpoint errors, never credentials. No logging in
        // release builds; useful during development only.
        #if DEBUG
        print("⚠️", text)
        #endif
    }

    // MARK: Harness availability (also refreshed on Settings open)

    func checkHarnessAvailability() {
        harnessAvailable = HarnessImporter.fileExists()
    }

    /// Opens the DeepSeek Harness app so the user can sign in or renew there.
    func openHarnessApp() {
        let candidates = [
            URL(fileURLWithPath: "/Applications/DeepSeek Harness.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/DeepSeek Harness.app"),
        ]
        guard let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
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
        launchAtLogin = enabled
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

    // MARK: Preview

    #if DEBUG
    static func preview() -> AppModel {
        let model = AppModel(api: .shared)
        model.harnessAvailable = true
        model.accountName = "dev@opencode.example"
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
}
