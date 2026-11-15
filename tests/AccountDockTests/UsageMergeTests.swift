import XCTest
@testable import AccountDock

final class UsageMergeTests: XCTestCase {
    @MainActor private func sample(_ date: Double, primary: [String: Any], secondary: [String: Any]? = nil) throws -> UsageReport {
        let data = try JSONSerialization.data(withJSONObject: ["limit_id": "codex", "primary": primary, "secondary": secondary as Any? ?? NSNull()])
        return try XCTUnwrap(LocalUsageReport.normalize(LocalLimitSample(data: data, date: Date(timeIntervalSince1970: date))))
    }
    @MainActor func testPartialWeeklySampleDoesNotRemoveFiveHourLimitOrDuplicateWeek() throws {
        let full = try sample(100, primary: ["used_percent": 100, "window_minutes": 300, "resets_at": 300],
                              secondary: ["used_percent": 16, "window_minutes": 10080, "resets_at": 1000])
        let weekly = try sample(200, primary: ["used_percent": 20, "window_minutes": 10080, "resets_at": 1000])
        let merged = UsageReport.merging(weekly, previous: full)
        XCTAssertEqual(merged.windows.count, 2)
        XCTAssertEqual(merged.windows.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(merged.windows.map(\.remainingPercent), [0, 80])
        XCTAssertEqual(merged.windows.map(\.observedAt), [100, 200])
        XCTAssertEqual(merged.checkedAt, 200)
        XCTAssertFalse(merged.windows[0].needsRefresh(at: 250, fallbackObserved: merged.checkedAt))
        XCTAssertTrue(merged.windows[0].needsRefresh(at: 301, fallbackObserved: merged.checkedAt))
        // A delayed older full sample must not roll back the newer weekly value.
        let delayed = UsageReport.merging(full, previous: merged)
        XCTAssertEqual(delayed.windows.map(\.remainingPercent), [0, 80])
        let reset = try sample(310, primary: ["used_percent": 0, "window_minutes": 300, "resets_at": 600])
        let refreshed = UsageReport.merging(reset, previous: delayed)
        XCTAssertEqual(refreshed.windows.map(\.remainingPercent), [100, 80])
        XCTAssertFalse(refreshed.windows[0].needsRefresh(at: 320, fallbackObserved: refreshed.checkedAt))
    }
    @MainActor func testFailedFetchKeepsObservationTimeButLoginFailureClearsReport() throws {
        let known = try sample(100, primary: ["used_percent": 0, "window_minutes": 300])
        let failed = UsageReport(status: "unavailable", windows: [], activity: [:], checkedAt: 200)
        let preserved = UsageReport.merging(failed, previous: known)
        XCTAssertEqual(preserved.checkedAt, 100)
        XCTAssertEqual(preserved.windows.first?.remainingPercent, 100)
        let login = UsageReport(status: "login_required", windows: [], activity: [:], checkedAt: nil)
        XCTAssertTrue(UsageReport.merging(login, previous: known).windows.isEmpty)
    }
}
