import XCTest
@testable import OpenUsage

/// Shared token/cost aggregation boundaries, including token-only usage with unknown pricing.
final class DailyUsageAccumulatorTests: XCTestCase {
    func testDayKeyUsesInjectedCalendarAndZeroPads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-03-07 23:30 UTC — pads month and day to two digits.
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2024-03-07")

        // The key is local-calendar: one instant, two time zones, two different days.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: tokyo), "2024-03-08")
    }

    func testBuildSortsDaysNewestFirstAndSumsPerModel() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.add(day: "2024-06-03", tokens: 50, cost: 0.5, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 200, cost: 2.0, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 10, cost: 0.1, model: "opus")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.date), ["2024-06-03", "2024-06-01"])
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [50, 310])
        // Every counted day is priced — a real cost, never nil-by-omission.
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 3.1, accuracy: 0.0001)

        let june1 = scan.modelUsage?.daily.first { $0.date == "2024-06-01" }
        let models = Dictionary(uniqueKeysWithValues: (june1?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["sonnet"]?.totalTokens, 300)
        XCTAssertEqual(models["sonnet"]?.costUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(models["opus"]?.totalTokens, 10)
    }

    func testUnpricedUsageSurvivesMergeWithoutInventingCost() throws {
        var unpriced = DailyUsageAccumulator()
        unpriced.addUnpriced(day: "2024-06-02", tokens: 900, model: "new-model")
        unpriced.addUnpriced(day: "2024-06-03", tokens: 120, model: "new-model")
        var priced = DailyUsageAccumulator()
        priced.add(day: "2024-06-02", tokens: 100, cost: 0.5, model: "known-model")

        let scan = try XCTUnwrap(DailyUsageAccumulator.merged([unpriced.build(), priced.build()]))
        let tokenOnly = try XCTUnwrap(scan.series.daily.first { $0.date == "2024-06-03" })
        XCTAssertEqual(tokenOnly.totalTokens, 120)
        XCTAssertNil(tokenOnly.costUSD)
        let mixed = try XCTUnwrap(scan.series.daily.first { $0.date == "2024-06-02" })
        XCTAssertEqual(mixed.totalTokens, 1_000)
        XCTAssertEqual(mixed.costUSD, 0.5)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first { $0.date == "2024-06-02" })
        XCTAssertEqual(models.models.first { $0.model == "new-model" }?.totalTokens, 900)
        XCTAssertNil(models.models.first { $0.model == "new-model" }?.costUSD)
        XCTAssertEqual(scan.unknownModelsByDay["2024-06-02"], ["new-model"])
    }
}
