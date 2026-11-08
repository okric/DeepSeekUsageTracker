import XCTest
@testable import DeepseekUsageTracker

final class CoreParsingTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(
            year: year, month: month, day: day, hour: hour))!
    }

    // MARK: Balance

    func testOfficialBalancePrefersFundedUSDAndKeepsExtras() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {"currency":"USD","total_balance":"12.34","granted_balance":"2.34","topped_up_balance":"10.00"},
            {"currency":"CNY","total_balance":"4.08","granted_balance":"4.08","topped_up_balance":"0"}
          ]
        }
        """
        let balance = try DeepSeekAPI.parseBalance(data: data(json))
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.total, 12.34, accuracy: 0.0001)
        XCTAssertEqual(balance.granted, 2.34, accuracy: 0.0001)
        XCTAssertEqual(balance.toppedUp, 10.00, accuracy: 0.0001)
        XCTAssertTrue(balance.isAvailable)
        XCTAssertEqual(balance.source, .apiKey)
        XCTAssertEqual(balance.extras.count, 1)
        XCTAssertEqual(balance.extras[0].currency, "CNY")
        XCTAssertEqual(balance.extras[0].total, 4.08, accuracy: 0.0001)
    }

    func testPlatformBalanceSumsWalletsAndKeepsCNYBonus() throws {
        let json = """
        {
          "code": 0,
          "msg": "",
          "data": {
            "biz_code": 0,
            "biz_msg": "",
            "biz_data": {
              "normal_wallets": [{"currency":"USD","balance":"7.4172945460000000"}],
              "bonus_wallets": [{"currency":"USD","balance":"0"},{"currency":"CNY","balance":"4.0752576800000000"}]
            }
          }
        }
        """
        let balance = try DeepSeekAPI.parsePlatformBalance(data: data(json))
        XCTAssertEqual(balance.currency, "USD")
        XCTAssertEqual(balance.total, 7.417294546, accuracy: 0.0000001)
        XCTAssertEqual(balance.granted, 0)
        XCTAssertEqual(balance.toppedUp, 7.417294546, accuracy: 0.0000001)
        XCTAssertTrue(balance.isAvailable)
        XCTAssertEqual(balance.source, .platform)
        XCTAssertEqual(balance.extras.count, 1)
        XCTAssertEqual(balance.extras[0].currency, "CNY")
        XCTAssertEqual(balance.extras[0].total, 4.07525768, accuracy: 0.0000001)
    }

    func testPlatformEnvelopeRejectsExpiredToken() {
        let json = #"{"code":40003,"msg":"invalid token"}"#
        XCTAssertThrowsError(try DeepSeekAPI.unwrapPlatform(data(json))) { error in
            guard case APIError.unauthorized = error else {
                return XCTFail("Expected unauthorized, got \(error)")
            }
        }
    }

    // MARK: Usage

    private func usageFixture() -> (now: Date, calendar: Calendar, today10: Int, yesterday10: Int, tooOld: Int) {
        let calendar = calendar()
        let now = date(2026, 11, 7, 12)
        let todayStart = calendar.startOfDay(for: now)
        let today10 = Int(todayStart.addingTimeInterval(10 * 3600).timeIntervalSince1970)
        let yesterday10 = today10 - 86_400
        let tooOld = today10 - 40 * 86_400
        return (now, calendar, today10, yesterday10, tooOld)
    }

    func testPerKeyUsageAggregatesTodayAndThirtyDays() throws {
        let fixture = usageFixture()
        let amountJSON = """
        {
          "series": [{
            "model": "deepseek-chat",
            "buckets": [
              {"time": \(fixture.today10), "usage": {"PROMPT_CACHE_HIT_TOKEN": 1000, "PROMPT_CACHE_MISS_TOKEN": 200, "RESPONSE_TOKEN": 300, "REQUEST": 4}},
              {"time": \(fixture.yesterday10), "usage": {"PROMPT_CACHE_HIT_TOKEN": 500, "PROMPT_CACHE_MISS_TOKEN": 100, "RESPONSE_TOKEN": 50, "REQUEST": 2}},
              {"time": \(fixture.tooOld), "usage": {"PROMPT_CACHE_HIT_TOKEN": 9999, "REQUEST": 1}}
            ]
          }]
        }
        """
        let costJSON = """
        {
          "data": [{
            "currency": "USD",
            "series": [{
              "model": "deepseek-chat",
              "buckets": [
                {"time": \(fixture.today10), "cost": "0.0123"},
                {"time": \(fixture.yesterday10), "cost": "0.005"},
                {"time": \(fixture.tooOld), "cost": "1.0"}
              ]
            }]
          }]
        }
        """
        let amount = try DeepSeekAPI.decodeUsageAmount(data(amountJSON))
        let cost = try DeepSeekAPI.decodeUsageCost(data(costJSON))
        let usage = DeepSeekAPI.parseUsageByAPIKey(
            amount: amount,
            cost: cost,
            now: fixture.now,
            calendar: fixture.calendar,
            preferredCurrency: "USD")

        XCTAssertEqual(usage.currency, "USD")
        XCTAssertEqual(usage.totalTokens, 1_500)
        XCTAssertEqual(usage.cacheHitTokens, 1_000)
        XCTAssertEqual(usage.cacheMissTokens, 200)
        XCTAssertEqual(usage.outputTokens, 300)
        XCTAssertEqual(usage.requests, 4)
        XCTAssertEqual(usage.cost ?? -1, 0.0123, accuracy: 0.00001)
        XCTAssertEqual(usage.periodTokens, 2_150)
        XCTAssertEqual(usage.periodCost ?? -1, 0.0173, accuracy: 0.00001)
        XCTAssertEqual(usage.period, .last30Days)
        XCTAssertFalse(usage.approximate)
        XCTAssertEqual(usage.daily.count, 7)
        XCTAssertEqual(usage.daily.last?.tokens, 1_500)
        XCTAssertEqual(usage.daily.last?.requests, 4)
    }

    func testCostCurrencyFollowsTodaysSpend() throws {
        let fixture = usageFixture()
        let amountJSON = """
        {
          "series": [{
            "model": "deepseek-chat",
            "buckets": [
              {"time": \(fixture.today10), "usage": {"PROMPT_CACHE_HIT_TOKEN": 1000, "REQUEST": 1}}
            ]
          }]
        }
        """
        let costJSON = """
        {
          "data": [
            {"currency": "CNY", "series": [{"buckets": [{"time": \(fixture.today10), "cost": "2.64"}]}]},
            {"currency": "USD", "series": [{"buckets": [{"time": \(fixture.yesterday10), "cost": "1.48"}]}]}
          ]
        }
        """
        let amount = try DeepSeekAPI.decodeUsageAmount(data(amountJSON))
        let cost = try DeepSeekAPI.decodeUsageCost(data(costJSON))
        let usage = DeepSeekAPI.parseUsageByAPIKey(
            amount: amount,
            cost: cost,
            now: fixture.now,
            calendar: fixture.calendar,
            preferredCurrency: "USD")

        // The USD block has older spend but nothing today; today's actual charge
        // is the CNY block and must not be hidden behind a preferred currency.
        XCTAssertEqual(usage.currency, "CNY")
        XCTAssertEqual(usage.cost ?? -1, 2.64, accuracy: 0.0001)
        XCTAssertEqual(usage.periodCost ?? -1, 2.64, accuracy: 0.0001)
        XCTAssertEqual(usage.daily.last?.cost ?? -1, 2.64, accuracy: 0.0001)
    }

    func testMonthlyUsageParsesDatesAndCosts() throws {
        let now = date(2026, 11, 7, 12)
        let amountJSON = """
        {
          "total": [{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"1500"},{"type":"REQUEST","amount":"4"}]}],
          "days": [
            {"date":"2026-11-07","data":[{"model":"deepseek-chat","usage":[
              {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"1000"},
              {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"200"},
              {"type":"RESPONSE_TOKEN","amount":"300"},
              {"type":"REQUEST","amount":"4"}
            ]}]},
            {"date":"2026-11-06","data":[{"model":"deepseek-chat","usage":[
              {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"100"},
              {"type":"REQUEST","amount":"1"}
            ]}]}
          ]
        }
        """
        let costJSON = """
        {
          "data": [{
            "currency": "CNY",
            "total": [{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.0173"}]}],
            "days": [
              {"date":"2026-11-07","data":[{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.0123"}]}]},
              {"date":"2026-11-06","data":[{"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.005"}]}]}
            ]
          }]
        }
        """
        let amount = try DeepSeekAPI.decodeMonthlyAmount(data(amountJSON))
        let cost = try DeepSeekAPI.decodeMonthlyCost(data(costJSON))
        let usage = DeepSeekAPI.parseUsageMonthly(
            amount: amount,
            cost: cost,
            now: now,
            calendar: calendar(),
            preferredCurrency: "USD")

        XCTAssertEqual(usage.currency, "CNY")
        XCTAssertEqual(usage.totalTokens, 1_500)
        XCTAssertEqual(usage.requests, 4)
        XCTAssertEqual(usage.cost ?? -1, 0.0123, accuracy: 0.00001)
        XCTAssertEqual(usage.periodTokens, 1_600)
        XCTAssertEqual(usage.periodCost ?? -1, 0.0173, accuracy: 0.00001)
        XCTAssertEqual(usage.period, .thisMonth)
        XCTAssertTrue(usage.approximate)
        XCTAssertEqual(usage.daily.last?.tokens, 1_500)
    }

    // MARK: Dates

    func testDateWindowUsesLocalMidnight() {
        let calendar = calendar()
        let now = date(2026, 11, 7, 12)
        let day = DateWindow.today(now: now, calendar: calendar)
        XCTAssertEqual(day.start, calendar.startOfDay(for: now))
        XCTAssertEqual(day.end, calendar.date(byAdding: .day, value: 1, to: day.start))
        XCTAssertEqual(day.timeZoneOffset, calendar.timeZone.secondsFromGMT(for: now))

        let month = DateWindow.last30Days(now: now, calendar: calendar)
        XCTAssertEqual(month.start, calendar.date(byAdding: .day, value: -29, to: day.start))
        XCTAssertEqual(month.end, day.end)
    }

    // MARK: Harness import

    func testHarnessYAMLParsing() {
        let yaml = """
        version: 1
        refs:
          DEEPSEEK_API_KEY: "sk-test-123"
        records:
          client-connection/browser-session:
            kind: grant
            payload:
              version: 1
              secret: do-not-read
          deepseek-account-platform/device:
            kind: grant
            payload:
              id: device-1
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: tok_abc
              issuer: https://platform.deepseek.com
        """
        let parsed = HarnessImporter.parse(yaml)
        XCTAssertEqual(parsed?.token, "tok_abc")
        XCTAssertEqual(parsed?.issuer, "https://platform.deepseek.com")
        XCTAssertEqual(parsed?.apiKey, "sk-test-123")
    }

    func testHarnessLoadRejectsMockIssuer() throws {
        let yaml = """
        version: 1
        refs:
          DEEPSEEK_API_KEY: sk-test
        records:
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: tok_abc
              issuer: http://127.0.0.1:8787
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-\(UUID().uuidString).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try HarnessImporter.load(from: url)) { error in
            XCTAssertEqual(error as? HarnessImportError, .invalidLogin)
        }
    }

    func testHarnessParsingWithoutAccountRecordReturnsNil() {
        XCTAssertNil(HarnessImporter.parse("""
        version: 1
        refs:
          DEEPSEEK_API_KEY: sk-test
        """))
    }
}
