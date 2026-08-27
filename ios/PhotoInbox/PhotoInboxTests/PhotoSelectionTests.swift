import XCTest
@testable import PhotoInbox

@MainActor
final class PhotoSelectionTests: XCTestCase {
    func testTodayPhotosStartSelectedAndCanBeExcluded() {
        let suiteName = "PhotoSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = PhotoSelectionStore(defaults: defaults)
        selection.updatePhotos(["first", "second"])

        XCTAssertEqual(selection.selectedIDs, Set(["first", "second"]))

        selection.toggle("second")
        XCTAssertEqual(selection.selectedIDs, Set(["first"]))

        selection.toggle("second")
        XCTAssertEqual(selection.selectedIDs, Set(["first", "second"]))
    }

    func testExcludedAndUploadedPhotosRemainUnselectedAfterRelaunch() {
        let suiteName = "PhotoSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = PhotoSelectionStore(defaults: defaults)
        firstLaunch.updatePhotos(["first", "second", "third"])
        firstLaunch.toggle("second")
        firstLaunch.markUploaded(["third"])

        let nextLaunch = PhotoSelectionStore(defaults: defaults)
        nextLaunch.updatePhotos(["first", "second", "third"])

        XCTAssertEqual(nextLaunch.status(of: "first"), .selected)
        XCTAssertEqual(nextLaunch.status(of: "second"), .excluded)
        XCTAssertEqual(nextLaunch.status(of: "third"), .uploaded)
        XCTAssertEqual(nextLaunch.selectedIDs, Set(["first"]))
    }
}
