import Foundation

// MARK: - Credential kinds

enum TokenKind: String, Sendable {
    /// Token returned by the browser PKCE authorization flow. Authenticates Platform calls
    /// through the `x-dsh-auth-token` header, with a Bearer fallback.
    case oauth
    /// The `userToken` copied from the DeepSeek Platform browser session. Authenticates
    /// Platform calls through the standard `Authorization: Bearer` header.
    case web
}

// MARK: - Balance

enum BalanceSource: String, Sendable {
    case apiKey
    case platform
}

struct CurrencyAmount: Equatable, Sendable {
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double
}

struct BalanceSnapshot: Equatable, Sendable {
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double
    let isAvailable: Bool
    let source: BalanceSource
    /// Positive balances in currencies other than the primary one, e.g. a CNY bonus
    /// on an otherwise USD account.
    var extras: [CurrencyAmount] = []
}

// MARK: - Usage

struct DailyUsage: Identifiable, Equatable, Sendable {
    let date: Date
    var cost: Double?
    var tokens: Int
    var requests: Int

    var id: Date { date }
}

enum UsagePeriod: String, Sendable {
    case last30Days
    case thisMonth

    var label: String {
        switch self {
        case .last30Days: return "Last 30 days"
        case .thisMonth: return "This month"
        }
    }
}

struct UsageSnapshot: Equatable, Sendable {
    let currency: String
    var cost: Double?
    var totalTokens: Int
    var cacheHitTokens: Int
    var cacheMissTokens: Int
    var outputTokens: Int
    var requests: Int
    var periodCost: Double?
    var periodTokens: Int
    var daily: [DailyUsage]
    var period: UsagePeriod
    /// True when the monthly endpoint was used because the per-day endpoint was unavailable.
    var approximate: Bool

    static let empty = UsageSnapshot(
        currency: "USD",
        cost: nil,
        totalTokens: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
        outputTokens: 0,
        requests: 0,
        periodCost: nil,
        periodTokens: 0,
        daily: [],
        period: .last30Days,
        approximate: false)

    var cacheHitRate: Int? {
        let total = cacheHitTokens + cacheMissTokens
        guard total > 0 else { return nil }
        return Int((Double(cacheHitTokens) / Double(total) * 100).rounded())
    }
}

// MARK: - App snapshot

struct AppSnapshot: Equatable, Sendable {
    var balance: BalanceSnapshot?
    var usage: UsageSnapshot?
    var updatedAt: Date?
    var error: String?
    var needsReauth: Bool = false
    var isStale: Bool = false
    var isLoading: Bool = false
}

// MARK: - Date window

struct DateWindow: Equatable, Sendable {
    let start: Date
    let end: Date
    let timeZoneOffset: Int

    static func today(now: Date = Date(), calendar: Calendar = .current) -> DateWindow {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return DateWindow(
            start: start,
            end: end,
            timeZoneOffset: calendar.timeZone.secondsFromGMT(for: now))
    }

    static func last30Days(now: Date = Date(), calendar: Calendar = .current) -> DateWindow {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(86_400)
        return DateWindow(
            start: start,
            end: end,
            timeZoneOffset: calendar.timeZone.secondsFromGMT(for: now))
    }
}

// MARK: - Formatting

enum Fmt {
    static func money(_ value: Double, currency: String) -> String {
        let symbol = currency.uppercased() == "CNY" ? "¥" : "$"
        let magnitude = abs(value)
        if magnitude > 0 && magnitude < 0.01 {
            return symbol + String(format: "%.4f", value)
        }
        return symbol + String(format: "%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        if value >= 1_000_000 {
            return trimZero(String(format: "%.1f", number / 1_000_000)) + "M"
        }
        if value >= 1_000 {
            return trimZero(String(format: "%.1f", number / 1_000)) + "K"
        }
        return "\(value)"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MMM d, HH:mm"
        }
        return formatter.string(from: date)
    }

    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE M/d"
        return formatter.string(from: date)
    }

    private static func trimZero(_ value: String) -> String {
        value.hasSuffix(".0") ? String(value.dropLast(2)) : value
    }
}
