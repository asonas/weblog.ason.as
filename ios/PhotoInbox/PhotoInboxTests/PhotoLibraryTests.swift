import XCTest
@testable import PhotoInbox

@MainActor
final class PhotoLibraryTests: XCTestCase {
    func testRecentPhotoIntervalIncludesTodayAndPreviousSixCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 29, hour: 15, minute: 30
        )))

        let interval = PhotoLibrary.recentPhotoInterval(now: now, calendar: calendar)

        XCTAssertEqual(
            interval.start,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        XCTAssertEqual(
            interval.end,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 30))
        )
    }
}
