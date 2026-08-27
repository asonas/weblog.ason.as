import XCTest
@testable import PhotoInbox

final class UploadQueueStoreTests: XCTestCase {
    func testQueueRestoresClientIDAndProgressAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "queue.json")
        let clientID = UUID()
        let item = UploadItem(
            clientUploadID: clientID,
            assetLocalIdentifier: "asset-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let firstStore = UploadQueueStore(fileURL: fileURL)
        try await firstStore.enqueue([item])
        try await firstStore.updateStage(clientID, stage: .uploading(uploadID: "server-upload"))

        let restored = try await UploadQueueStore(fileURL: fileURL).items()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].clientUploadID, clientID)
        XCTAssertEqual(restored[0].stage, .uploading(uploadID: "server-upload"))
    }

    func testEnqueueDoesNotDuplicateAClientID() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let item = UploadItem(assetLocalIdentifier: "asset-1", capturedAt: .now)
        let store = UploadQueueStore(fileURL: fileURL)

        try await store.enqueue([item, item])

        let stored = try await store.items()
        XCTAssertEqual(stored.count, 1)
    }
}
