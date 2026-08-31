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

  func testEnqueueKeepsTheFirstUploadForAnAsset() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    let firstID = UUID()
    let first = UploadItem(
      clientUploadID: firstID,
      assetLocalIdentifier: "asset-1",
      capturedAt: .now
    )
    let duplicate = UploadItem(
      clientUploadID: UUID(),
      assetLocalIdentifier: "asset-1",
      capturedAt: .now
    )
    let store = UploadQueueStore(fileURL: fileURL)

    try await store.enqueue([first])
    try await store.enqueue([duplicate])

    let stored = try await store.items()
    XCTAssertEqual(stored.count, 1)
    XCTAssertEqual(stored[0].clientUploadID, firstID)
  }

  func testRejectedPhotoRestoresDiagnosticAndRequiresExplicitRetry() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    let clientID = UUID()
    let store = UploadQueueStore(fileURL: fileURL)
    try await store.enqueue([
      UploadItem(
        clientUploadID: clientID,
        assetLocalIdentifier: "asset-1",
        capturedAt: .now
      )
    ])
    let failure = UploadFailure(
      code: "invalid_upload_size",
      field: "size",
      message: "写真のサイズ情報が不正です。もう一度選び直してください。",
      requestID: "request-1",
      automaticallyRetryable: false
    )

    try await store.updateFailure(clientID, failure: failure)

    let restoredStore = UploadQueueStore(fileURL: fileURL)
    let restoredItems = try await restoredStore.items()
    let rejected = try XCTUnwrap(restoredItems.first)
    XCTAssertEqual(rejected.failure, failure)
    XCTAssertFalse(rejected.shouldAttemptAutomatically)

    try await restoredStore.retry(clientID)

    let retriedItems = try await restoredStore.items()
    let retried = try XCTUnwrap(retriedItems.first)
    XCTAssertEqual(retried.stage, .pending)
    XCTAssertNil(retried.failure)
    XCTAssertTrue(retried.shouldAttemptAutomatically)
  }

  func testTransientBackgroundUploadFailuresRemainAutomaticallyRetryable() {
    XCTAssertTrue(
      UploadFailure(error: BackgroundUploadError.invalidResponse).automaticallyRetryable)
    XCTAssertTrue(UploadFailure(error: BackgroundUploadError.status(503)).automaticallyRetryable)
    XCTAssertFalse(UploadFailure(error: BackgroundUploadError.status(403)).automaticallyRetryable)
  }
}
