import Foundation

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    case missingCredentials
    case unauthorized
    case http(Int)
    case network(String)
    case decoding(String)
    case platform(code: Int, message: String?)
    case invalidAuthResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No DeepSeek credentials are configured."
        case .unauthorized:
            return "DeepSeek rejected the credential. Sign in again or update the key."
        case let .http(code):
            return "DeepSeek returned HTTP \(code)."
        case let .network(message):
            return "Network error: \(message)"
        case .decoding:
            return "DeepSeek returned an unexpected response."
        case let .platform(code, message):
            if let message, !message.isEmpty {
                return "DeepSeek error \(code): \(message)"
            }
            return "DeepSeek error \(code)."
        case let .invalidAuthResponse(message):
            return "Invalid sign-in response: \(message)"
        }
    }

    var isUnauthorized: Bool {
        switch self {
        case .unauthorized:
            return true
        case let .platform(code, _):
            return [40001, 40002, 40003].contains(code)
        default:
            return false
        }
    }
}

// MARK: - Scalar

/// DeepSeek's usage endpoints return numbers as strings (`"1234"`), but a few
/// endpoints use JSON numbers. This decodes either form.
struct Scalar: Decodable, Equatable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if try container.decodeNil() {
            self.value = "0"
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let int = try? container.decode(Int64.self) {
            self.value = String(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = String(double)
        } else {
            throw DecodingError.typeMismatch(
                Scalar.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string or numeric scalar"))
        }
    }

    var doubleValue: Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    var intValue: Int {
        let number = doubleValue
        guard number.isFinite else { return 0 }
        return Int(number)
    }
}

// MARK: - Balance payloads

struct BalanceResponse: Decodable, Sendable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]
}

struct BalanceInfo: Decodable, Sendable {
    let currency: String
    let totalBalance: Scalar
    let grantedBalance: Scalar
    let toppedUpBalance: Scalar
}

struct PlatformBalanceResponse: Decodable, Sendable {
    let normalWallets: [PlatformWallet]
    let bonusWallets: [PlatformWallet]
}

struct PlatformWallet: Decodable, Sendable {
    let currency: String
    let balance: Scalar
}

// MARK: - Per-API-key usage payloads

struct UsageAmountBiz: Decodable, Sendable {
    let series: [UsageAmountSeries]?
}

struct UsageAmountSeries: Decodable, Sendable {
    let model: String?
    let buckets: [UsageAmountBucket]?
}

struct UsageAmountBucket: Decodable, Sendable {
    let time: Int
    let usage: [String: Scalar]?
}

struct UsageCostBiz: Decodable, Sendable {
    let data: [UsageCostCurrency]?
}

struct UsageCostCurrency: Decodable, Sendable {
    let currency: String?
    let series: [UsageCostSeries]?
}

struct UsageCostSeries: Decodable, Sendable {
    let model: String?
    let buckets: [UsageCostBucket]?
}

struct UsageCostBucket: Decodable, Sendable {
    let time: Int
    let cost: Scalar?
}

// MARK: - Monthly usage payloads

struct MonthlyAmountBiz: Decodable, Sendable {
    let total: [MonthlyModel]?
    let days: [MonthlyDay]?
}

struct MonthlyModel: Decodable, Sendable {
    let model: String?
    let usage: [MonthlyUsageItem]?
}

struct MonthlyDay: Decodable, Sendable {
    let date: String?
    let data: [MonthlyModel]?
}

struct MonthlyUsageItem: Decodable, Sendable {
    let type: String?
    let amount: Scalar?
}

struct MonthlyCostBiz: Decodable, Sendable {
    let data: [MonthlyCostCurrency]?
}

struct MonthlyCostCurrency: Decodable, Sendable {
    let currency: String?
    let total: [MonthlyModel]?
    let days: [MonthlyCostDay]?
}

struct MonthlyCostDay: Decodable, Sendable {
    let date: String?
    let data: [MonthlyModel]?
}

// MARK: - Auth payloads

struct AuthInitResponse: Decodable, Sendable {
    let authorizeUrl: String
    let authorizeId: String
    let expiresIn: Int
}

struct AuthExchangeResponse: Decodable, Sendable {
    let token: String
    let authorizedUrl: String
    let user: AuthUser?
}

struct AuthUser: Decodable, Sendable {
    let id: String?
    let email: String?
    let mobile: String?
    let mobileNumber: String?
    let idProfile: AuthProfile?

    var displayName: String? {
        let name = idProfile?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty { return email }
        return contact
    }

    var contact: String? {
        let mobile = (mobile ?? mobileNumber)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mobile, !mobile.isEmpty { return mobile }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty { return email }
        return nil
    }
}

struct AuthProfile: Decodable, Sendable {
    let name: String?
    let picture: String?
}

// MARK: - HTTP

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward credentials to a redirect target.
        completionHandler(nil)
    }
}

// MARK: - Client

final class DeepSeekAPI: @unchecked Sendable {
    static let shared = DeepSeekAPI()

    private let session: URLSession
    private let redirectDelegate = NoRedirectDelegate()
    private let clientVersion = "1.0.0"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil)
    }

    // MARK: Public API

    func fetchBalance(apiKey: String) async throws -> BalanceSnapshot {
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        let data = try await get(url, headers: ["Authorization": "Bearer \(apiKey)"])
        return try Self.parseBalance(data: data)
    }

    func fetchPlatformBalance(token: String, kind: TokenKind) async throws -> BalanceSnapshot {
        let url = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
        let payload = try await getPlatformPayload(url, token: token, kind: kind)
        return try Self.parsePlatformBalance(payload: payload)
    }

    func fetchProfile(token: String, kind: TokenKind) async throws -> AuthUser {
        let url = URL(string: "https://platform.deepseek.com/auth-api/v0/users/current")!
        let payload = try await getPlatformPayload(url, token: token, kind: kind)
        return try decodePayload(AuthUser.self, from: payload)
    }

    func fetchUsage(
        token: String,
        kind: TokenKind,
        preferredCurrency: String?,
        now: Date = Date()
    ) async throws -> UsageSnapshot {
        let window = DateWindow.last30Days(now: now)
        do {
            async let amountRaw = getPlatformPayload(
                usageURL(path: "by_api_key/amount", window: window),
                token: token,
                kind: kind)
            async let costRaw = getPlatformPayload(
                usageURL(path: "by_api_key/cost", window: window),
                token: token,
                kind: kind)
            let (amountData, costData) = try await (amountRaw, costRaw)
            let amount = try Self.decodeUsageAmount(amountData)
            let cost = try Self.decodeUsageCost(costData)
            return Self.parseUsageByAPIKey(
                amount: amount,
                cost: cost,
                now: now,
                calendar: .current,
                preferredCurrency: preferredCurrency)
        } catch let error as APIError where error.isUnauthorized {
            throw error
        } catch {
            // The per-key dashboard endpoint can change or be unavailable. The monthly
            // endpoint still gives us a usable today figure, marked as approximate.
            do {
                let comps = Calendar.current.dateComponents([.month, .year], from: now)
                let month = comps.month ?? 1
                let year = comps.year ?? 2000
                async let amountRaw = getPlatformPayload(
                    monthlyURL(path: "amount", month: month, year: year),
                    token: token,
                    kind: kind)
                async let costRaw = getPlatformPayload(
                    monthlyURL(path: "cost", month: month, year: year),
                    token: token,
                    kind: kind)
                let (amountData, costData) = try await (amountRaw, costRaw)
                let amount = try Self.decodeMonthlyAmount(amountData)
                let cost = try Self.decodeMonthlyCost(costData)
                return Self.parseUsageMonthly(
                    amount: amount,
                    cost: cost,
                    now: now,
                    calendar: .current,
                    preferredCurrency: preferredCurrency)
            } catch let fallbackError as APIError where fallbackError.isUnauthorized {
                throw fallbackError
            } catch {
                throw error
            }
        }
    }

    func authInit(challenge: String, state: String, redirectURI: String) async throws -> AuthInitResponse {
        let url = URL(string: "https://platform.deepseek.com/auth-api/v0/dsh/auth_init")!
        let body: [String: Any] = [
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
            "redirect_uri": redirectURI,
            "locale": "en_US",
            "login_source": "desktop",
        ]
        let data = try await postJSON(url, body: body, headers: clientHeaders())
        return try decodePlatform(AuthInitResponse.self, from: data)
    }

    func authExchange(
        code: String,
        verifier: String,
        redirectURI: String,
        deviceID: String,
        deviceModel: String,
        osVersion: String
    ) async throws -> AuthExchangeResponse {
        let url = URL(string: "https://platform.deepseek.com/auth-api/v0/dsh/auth_exchange")!
        let body: [String: Any] = [
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "device_id": deviceID,
            "device_model": deviceModel,
            "os_version": osVersion,
        ]
        let data = try await postJSON(url, body: body, headers: clientHeaders())
        return try decodePlatform(AuthExchangeResponse.self, from: data)
    }

    /// Best-effort cancellation of a pending authorization attempt.
    func authCancel(authorizeID: String, verifier: String) async {
        let url = URL(string: "https://platform.deepseek.com/auth-api/v0/dsh/auth_cancel")!
        let body: [String: Any] = [
            "authorize_id": authorizeID,
            "code_verifier": verifier,
        ]
        _ = try? await postJSON(url, body: body, headers: clientHeaders())
    }

    // MARK: HTTP helpers

    private func clientHeaders() -> [String: String] {
        [
            "x-client-platform": "desktop-mac",
            "x-client-bundle-id": "",
            "x-client-version": clientVersion,
            "x-client-locale": "en_US",
            "x-client-timezone-offset": String(TimeZone.current.secondsFromGMT()),
        ]
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request)
    }

    private func postJSON(_ url: URL, body: [String: Any], headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw APIError.decoding("Could not encode request")
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.network("Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.network("Cancelled")
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    private func platformHeaders(token: String, kind: TokenKind) -> [String: String] {
        var headers = clientHeaders()
        if kind == .oauth {
            headers["x-dsh-auth-token"] = token
        } else {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    /// Platform endpoints accept the PKCE token in `x-dsh-auth-token`; the web
    /// `userToken` uses Bearer. Try the expected header first, then the other one
    /// once, so either credential kind works. Returns the validated `biz_data` JSON.
    private func getPlatformPayload(_ url: URL, token: String, kind: TokenKind) async throws -> Data {
        do {
            let raw = try await get(url, headers: platformHeaders(token: token, kind: kind))
            return try Self.unwrapPlatform(raw)
        } catch let error as APIError where error.isUnauthorized {
            var alternate = clientHeaders()
            if kind == .oauth {
                alternate["Authorization"] = "Bearer \(token)"
            } else {
                alternate["x-dsh-auth-token"] = token
            }
            let raw = try await get(url, headers: alternate)
            return try Self.unwrapPlatform(raw)
        }
    }

    private func usageURL(path: String, window: DateWindow) -> URL {
        var components = URLComponents(string: "https://platform.deepseek.com/api/v0/usage/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "start", value: String(Int(window.start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int(window.end.timeIntervalSince1970))),
            URLQueryItem(name: "tz", value: String(window.timeZoneOffset)),
        ]
        return components.url!
    }

    private func monthlyURL(path: String, month: Int, year: Int) -> URL {
        var components = URLComponents(string: "https://platform.deepseek.com/api/v0/usage/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year)),
        ]
        return components.url!
    }

    // MARK: Decoding

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func decodePlatform<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decodePayload(type, from: try Self.unwrapPlatform(data))
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.makeDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding("Unexpected response")
        }
    }

    /// Validates the `{ code, data: { biz_code, biz_data } }` platform envelope and
    /// returns the JSON data for `biz_data`.
    static func unwrapPlatform(_ data: Data) throws -> Data {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw APIError.decoding("Invalid JSON")
        }
        guard let dictionary = root as? [String: Any] else {
            throw APIError.decoding("Missing response envelope")
        }

        if let code = intValue(dictionary["code"]), code != 0 {
            if [40001, 40002, 40003].contains(code) {
                throw APIError.unauthorized
            }
            throw APIError.platform(code: code, message: sanitizedMessage(dictionary["msg"]))
        }

        guard let dataDictionary = dictionary["data"] as? [String: Any] else {
            throw APIError.decoding("Missing data")
        }
        if let bizCode = intValue(dataDictionary["biz_code"]), bizCode != 0 {
            if [40001, 40002, 40003].contains(bizCode) {
                throw APIError.unauthorized
            }
            throw APIError.platform(code: bizCode, message: sanitizedMessage(dataDictionary["biz_msg"]))
        }
        guard let bizData = dataDictionary["biz_data"], !(bizData is NSNull) else {
            throw APIError.decoding("Missing biz_data")
        }
        do {
            return try JSONSerialization.data(withJSONObject: bizData, options: [])
        } catch {
            throw APIError.decoding("Invalid biz_data")
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func sanitizedMessage(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let cleaned = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(120))
    }

    // MARK: Balance parsing

    static func parseBalance(data: Data) throws -> BalanceSnapshot {
        let response: BalanceResponse
        do {
            response = try makeDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw APIError.decoding("Unexpected balance response")
        }
        let infos = response.balanceInfos
        guard !infos.isEmpty else {
            return BalanceSnapshot(
                currency: "USD",
                total: 0,
                granted: 0,
                toppedUp: 0,
                isAvailable: false,
                source: .apiKey)
        }
        let selected = infos.first { $0.currency.uppercased() == "USD" && $0.totalBalance.doubleValue > 0 }
            ?? infos.first { $0.totalBalance.doubleValue > 0 }
            ?? infos.first { $0.currency.uppercased() == "USD" }
            ?? infos[0]
        let selectedCurrency = selected.currency.uppercased()
        let extras = infos.compactMap { info -> CurrencyAmount? in
            let currency = info.currency.uppercased()
            guard currency != selectedCurrency else { return nil }
            let total = info.totalBalance.doubleValue
            guard total > 0 else { return nil }
            return CurrencyAmount(
                currency: currency,
                total: total,
                granted: info.grantedBalance.doubleValue,
                toppedUp: info.toppedUpBalance.doubleValue)
        }
        return BalanceSnapshot(
            currency: selectedCurrency,
            total: selected.totalBalance.doubleValue,
            granted: selected.grantedBalance.doubleValue,
            toppedUp: selected.toppedUpBalance.doubleValue,
            isAvailable: response.isAvailable,
            source: .apiKey,
            extras: extras)
    }

    static func parsePlatformBalance(data: Data) throws -> BalanceSnapshot {
        try parsePlatformBalance(payload: try unwrapPlatform(data))
    }

    static func parsePlatformBalance(payload: Data) throws -> BalanceSnapshot {
        let response: PlatformBalanceResponse
        do {
            response = try makeDecoder().decode(PlatformBalanceResponse.self, from: payload)
        } catch {
            throw APIError.decoding("Unexpected platform balance response")
        }

        var paid: [String: Double] = [:]
        var granted: [String: Double] = [:]
        for wallet in response.normalWallets {
            paid[wallet.currency.uppercased(), default: 0] += wallet.balance.doubleValue
        }
        for wallet in response.bonusWallets {
            granted[wallet.currency.uppercased(), default: 0] += wallet.balance.doubleValue
        }
        let currencies = Set(paid.keys).union(granted.keys)
        guard !currencies.isEmpty else {
            return BalanceSnapshot(
                currency: "USD",
                total: 0,
                granted: 0,
                toppedUp: 0,
                isAvailable: false,
                source: .platform)
        }
        let selected = currencies.first { $0 == "USD" && (paid[$0] ?? 0) + (granted[$0] ?? 0) > 0 }
            ?? currencies.first { (paid[$0] ?? 0) + (granted[$0] ?? 0) > 0 }
            ?? currencies.first { $0 == "USD" }
            ?? currencies.sorted()[0]
        let paidValue = paid[selected, default: 0]
        let grantedValue = granted[selected, default: 0]
        let total = paidValue + grantedValue
        let extras = currencies
            .filter { $0 != selected }
            .compactMap { currency -> CurrencyAmount? in
                let total = (paid[currency] ?? 0) + (granted[currency] ?? 0)
                guard total > 0 else { return nil }
                return CurrencyAmount(
                    currency: currency,
                    total: total,
                    granted: granted[currency] ?? 0,
                    toppedUp: paid[currency] ?? 0)
            }
            .sorted { $0.currency < $1.currency }
        return BalanceSnapshot(
            currency: selected,
            total: total,
            granted: grantedValue,
            toppedUp: paidValue,
            isAvailable: total > 0,
            source: .platform,
            extras: extras)
    }

    // MARK: Usage parsing

    static func decodeUsageAmount(_ data: Data) throws -> UsageAmountBiz {
        do {
            return try makeDecoder().decode(UsageAmountBiz.self, from: data)
        } catch {
            throw APIError.decoding("Unexpected usage amount response")
        }
    }

    static func decodeUsageCost(_ data: Data) throws -> UsageCostBiz {
        do {
            return try makeDecoder().decode(UsageCostBiz.self, from: data)
        } catch {
            throw APIError.decoding("Unexpected usage cost response")
        }
    }

    static func decodeMonthlyAmount(_ data: Data) throws -> MonthlyAmountBiz {
        do {
            return try makeDecoder().decode(MonthlyAmountBiz.self, from: data)
        } catch {
            throw APIError.decoding("Unexpected monthly usage response")
        }
    }

    static func decodeMonthlyCost(_ data: Data) throws -> MonthlyCostBiz {
        do {
            return try makeDecoder().decode(MonthlyCostBiz.self, from: data)
        } catch {
            throw APIError.decoding("Unexpected monthly cost response")
        }
    }

    private struct DayTotals {
        var tokens = 0
        var cacheHit = 0
        var cacheMiss = 0
        var output = 0
        var requests = 0
        var cost: Double?
    }

    static func parseUsageByAPIKey(
        amount: UsageAmountBiz,
        cost: UsageCostBiz,
        now: Date,
        calendar: Calendar,
        preferredCurrency: String?
    ) -> UsageSnapshot {
        let window = DateWindow.last30Days(now: now, calendar: calendar)
        let start = Int(window.start.timeIntervalSince1970)
        let end = Int(window.end.timeIntervalSince1970)
        var days: [Date: DayTotals] = [:]

        for series in amount.series ?? [] {
            for bucket in series.buckets ?? [] where bucket.time >= start && bucket.time < end {
                let date = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(bucket.time)))
                var totals = days[date] ?? DayTotals()
                for (type, scalar) in bucket.usage ?? [:] {
                    let value = max(0, scalar.intValue)
                    switch type.uppercased() {
                    case "REQUEST":
                        totals.requests += value
                    case "PROMPT_CACHE_HIT_TOKEN":
                        totals.cacheHit += value
                        totals.tokens += value
                    case "PROMPT_CACHE_MISS_TOKEN":
                        totals.cacheMiss += value
                        totals.tokens += value
                    case "RESPONSE_TOKEN":
                        totals.output += value
                        totals.tokens += value
                    case "PROMPT_TOKEN":
                        totals.tokens += value
                    default:
                        break
                    }
                }
                days[date] = totals
            }
        }

        let todayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let tomorrow = Int((calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)).timeIntervalSince1970)
        let selectedBlock = selectCostBlock(
            cost.data ?? [],
            preferredCurrency: preferredCurrency,
            todayStart: todayStart,
            tomorrow: tomorrow)
        let currency = selectedBlock?.currency?.uppercased() ?? preferredCurrency?.uppercased() ?? "USD"
        if let selectedBlock {
            for series in selectedBlock.series ?? [] {
                for bucket in series.buckets ?? [] where bucket.time >= start && bucket.time < end {
                    let date = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(bucket.time)))
                    var totals = days[date] ?? DayTotals()
                    let value = max(0, bucket.cost?.doubleValue ?? 0)
                    totals.cost = (totals.cost ?? 0) + value
                    days[date] = totals
                }
            }
        }

        return summarize(
            days: days,
            today: calendar.startOfDay(for: now),
            now: now,
            calendar: calendar,
            currency: currency,
            period: .last30Days,
            approximate: false)
    }

    static func parseUsageMonthly(
        amount: MonthlyAmountBiz,
        cost: MonthlyCostBiz,
        now: Date,
        calendar: Calendar,
        preferredCurrency: String?
    ) -> UsageSnapshot {
        var days: [Date: DayTotals] = [:]
        let formatter = dayFormatter(calendar: calendar)

        for day in amount.days ?? [] {
            guard let dateString = day.date, let date = formatter.date(from: dateString) else { continue }
            var totals = days[calendar.startOfDay(for: date)] ?? DayTotals()
            for model in day.data ?? [] {
                for item in model.usage ?? [] {
                    let value = max(0, item.amount?.intValue ?? 0)
                    switch (item.type ?? "").uppercased() {
                    case "REQUEST":
                        totals.requests += value
                    case "PROMPT_CACHE_HIT_TOKEN":
                        totals.cacheHit += value
                        totals.tokens += value
                    case "PROMPT_CACHE_MISS_TOKEN":
                        totals.cacheMiss += value
                        totals.tokens += value
                    case "RESPONSE_TOKEN":
                        totals.output += value
                        totals.tokens += value
                    case "PROMPT_TOKEN":
                        totals.tokens += value
                    default:
                        break
                    }
                }
            }
            days[calendar.startOfDay(for: date)] = totals
        }

        let todayString = dayFormatter(calendar: calendar).string(from: now)
        let selectedBlock = selectMonthlyCostBlock(
            cost.data ?? [],
            preferredCurrency: preferredCurrency,
            todayString: todayString)
        let currency = selectedBlock?.currency?.uppercased() ?? preferredCurrency?.uppercased() ?? "USD"
        if let selectedBlock {
            for day in selectedBlock.days ?? [] {
                guard let dateString = day.date, let date = formatter.date(from: dateString) else { continue }
                let key = calendar.startOfDay(for: date)
                var totals = days[key] ?? DayTotals()
                let dailyCost = (day.data ?? []).reduce(0.0) { partial, model in
                    partial + (model.usage ?? []).reduce(0.0) { inner, item in
                        guard (item.type ?? "").uppercased() != "REQUEST" else { return inner }
                        return inner + max(0, item.amount?.doubleValue ?? 0)
                    }
                }
                totals.cost = (totals.cost ?? 0) + dailyCost
                days[key] = totals
            }
        }

        return summarize(
            days: days,
            today: calendar.startOfDay(for: now),
            now: now,
            calendar: calendar,
            currency: currency,
            period: .thisMonth,
            approximate: true)
    }

    private static func summarize(
        days: [Date: DayTotals],
        today: Date,
        now: Date,
        calendar: Calendar,
        currency: String,
        period: UsagePeriod,
        approximate: Bool
    ) -> UsageSnapshot {
        let todayTotals = days[today] ?? DayTotals()

        var periodTokens = 0
        var periodCost = 0.0
        var hasPeriodCost = false
        for (date, totals) in days where date <= now {
            periodTokens += totals.tokens
            if let cost = totals.cost {
                periodCost += cost
                hasPeriodCost = true
            }
        }

        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var daily: [DailyUsage] = []
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let totals = days[date] ?? DayTotals()
            daily.append(DailyUsage(
                date: date,
                cost: totals.cost,
                tokens: totals.tokens,
                requests: totals.requests))
        }

        return UsageSnapshot(
            currency: currency,
            cost: todayTotals.cost,
            totalTokens: todayTotals.tokens,
            cacheHitTokens: todayTotals.cacheHit,
            cacheMissTokens: todayTotals.cacheMiss,
            outputTokens: todayTotals.output,
            requests: todayTotals.requests,
            periodCost: hasPeriodCost ? periodCost : nil,
            periodTokens: periodTokens,
            daily: daily,
            period: period,
            approximate: approximate)
    }

    private static func spend(
        _ block: UsageCostCurrency,
        from start: Int,
        to end: Int
    ) -> Double {
        (block.series ?? []).reduce(0.0) { total, series in
            total + (series.buckets ?? []).reduce(0.0) { inner, bucket in
                guard bucket.time >= start && bucket.time < end else { return inner }
                return inner + max(0, bucket.cost?.doubleValue ?? 0)
            }
        }
    }

    /// A DeepSeek account can have wallets and cost data in more than one currency.
    /// Pick the block that actually spent money today, so a CNY bonus charge does not
    /// get hidden behind an older USD block. Fall back to the balance currency.
    private static func selectCostBlock(
        _ blocks: [UsageCostCurrency],
        preferredCurrency: String?,
        todayStart: Int,
        tomorrow: Int
    ) -> UsageCostCurrency? {
        let preferred = preferredCurrency?.uppercased()
        let today = blocks.map { ($0, spend($0, from: todayStart, to: tomorrow)) }
        if let best = today.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return blocks.first { $0.currency?.uppercased() == preferred }
            ?? blocks.first { $0.currency?.uppercased() == "USD" }
            ?? blocks.first
    }

    private static func selectMonthlyCostBlock(
        _ blocks: [MonthlyCostCurrency],
        preferredCurrency: String?,
        todayString: String
    ) -> MonthlyCostCurrency? {
        let preferred = preferredCurrency?.uppercased()
        func todaySpend(_ block: MonthlyCostCurrency) -> Double {
            (block.days ?? []).filter { $0.date == todayString }.reduce(0.0) { total, day in
                total + (day.data ?? []).reduce(0.0) { inner, model in
                    inner + (model.usage ?? []).reduce(0.0) { itemTotal, item in
                        guard (item.type ?? "").uppercased() != "REQUEST" else { return itemTotal }
                        return itemTotal + max(0, item.amount?.doubleValue ?? 0)
                    }
                }
            }
        }
        let today = blocks.map { ($0, todaySpend($0)) }
        if let best = today.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return best.0
        }
        return blocks.first { $0.currency?.uppercased() == preferred }
            ?? blocks.first { $0.currency?.uppercased() == "USD" }
            ?? blocks.first
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    // MARK: Device identity

    static func deviceInfo() -> (id: String, model: String, osVersion: String) {
        let defaults = UserDefaults.standard
        let key = "deepseek.deviceId"
        let id: String
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            id = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: key)
            id = created
        }

        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let release = withUnsafeBytes(of: &info.release) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return (id, "darwin-\(machine)", "darwin \(release)")
    }
}
