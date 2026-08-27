import XCTest
@testable import PhotoInbox

final class PhotoSelectionTests: XCTestCase {
    func testTodayPhotosStartSelectedAndCanBeExcluded() {
        var selection = PhotoSelection(assetIDs: ["first", "second"])

        XCTAssertEqual(selection.selectedIDs, Set(["first", "second"]))

        selection.toggle("second")
        XCTAssertEqual(selection.selectedIDs, Set(["first"]))

        selection.toggle("second")
        XCTAssertEqual(selection.selectedIDs, Set(["first", "second"]))
    }
}
