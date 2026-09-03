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
    let preparedFileURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).png")
    try Data("oversized png".utf8).write(to: preparedFileURL)
    let clientID = UUID()
    let store = UploadQueueStore(fileURL: fileURL)
    try await store.enqueue([
      UploadItem(
        clientUploadID: clientID,
        assetLocalIdentifier: "asset-1",
        capturedAt: .now,
        preparedFilePath: preparedFileURL.path,
        contentType: "image/png",
        size: 27_516_528,
        sha256: String(repeating: "a", count: 64)
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
    XCTAssertNotEqual(retried.clientUploadID, clientID)
    XCTAssertEqual(retried.stage, .pending)
    XCTAssertNil(retried.failure)
    XCTAssertNil(retried.preparedFilePath)
    XCTAssertNil(retried.contentType)
    XCTAssertNil(retried.size)
    XCTAssertNil(retried.sha256)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preparedFileURL.path))
    XCTAssertTrue(retried.shouldAttemptAutomatically)
  }

  func testChecksumRejectionRepreparesWithANewClientID() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    let preparedFileURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).webp")
    try Data("invalid webp".utf8).write(to: preparedFileURL)
    let clientID = UUID()
    let store = UploadQueueStore(fileURL: fileURL)
    try await store.enqueue([
      UploadItem(
        clientUploadID: clientID,
        assetLocalIdentifier: "asset-1",
        capturedAt: .now,
        preparedFilePath: preparedFileURL.path,
        contentType: "image/webp",
        size: 12,
        sha256: String(repeating: "a", count: 64)
      )
    ])
    try await store.updateFailure(
      clientID,
      failure: UploadFailure(
        code: "invalid_sha256",
        field: "sha256",
        message: "写真データの確認に失敗しました。",
        automaticallyRetryable: false
      )
    )

    try await store.retry(clientID)

    let items = try await store.items()
    let retried = try XCTUnwrap(items.first)
    XCTAssertNotEqual(retried.clientUploadID, clientID)
    XCTAssertNil(retried.preparedFilePath)
    XCTAssertNil(retried.contentType)
    XCTAssertNil(retried.size)
    XCTAssertNil(retried.sha256)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preparedFileURL.path))
  }

  func testRetryKeepsPreparedWebPAfterUnrelatedPermanentFailure() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    let preparedFileURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).webp")
    try Data("prepared webp".utf8).write(to: preparedFileURL)
    let clientID = UUID()
    let store = UploadQueueStore(fileURL: fileURL)
    try await store.enqueue([
      UploadItem(
        clientUploadID: clientID,
        assetLocalIdentifier: "asset-1",
        capturedAt: .now,
        preparedFilePath: preparedFileURL.path,
        contentType: "image/webp",
        size: 13,
        sha256: String(repeating: "b", count: 64)
      )
    ])
    try await store.updateFailure(
      clientID,
      failure: UploadFailure(
        code: "invalid_captured_at_source",
        field: "captured_at_source",
        message: "写真の撮影日時情報が不正です。",
        automaticallyRetryable: false
      )
    )

    try await store.retry(clientID)

    let items = try await store.items()
    let retried = try XCTUnwrap(items.first)
    XCTAssertEqual(retried.clientUploadID, clientID)
    XCTAssertEqual(retried.preparedFilePath, preparedFileURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: preparedFileURL.path))
  }

  func testRetryKeepsPreparedWebPAfterTransientFailure() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    let preparedFileURL = FileManager.default.temporaryDirectory
      .appending(path: "\(UUID().uuidString).webp")
    try Data("prepared webp".utf8).write(to: preparedFileURL)
    let clientID = UUID()
    let store = UploadQueueStore(fileURL: fileURL)
    try await store.enqueue([
      UploadItem(
        clientUploadID: clientID,
        assetLocalIdentifier: "asset-1",
        capturedAt: .now,
        preparedFilePath: preparedFileURL.path,
        contentType: "image/webp",
        size: 13,
        sha256: String(repeating: "b", count: 64)
      )
    ])
    try await store.updateFailure(
      clientID,
      failure: UploadFailure(
        message: "一時的に送信できませんでした。",
        automaticallyRetryable: true
      )
    )

    try await store.retry(clientID)

    let items = try await store.items()
    let retried = try XCTUnwrap(items.first)
    XCTAssertEqual(retried.preparedFilePath, preparedFileURL.path)
    XCTAssertEqual(retried.contentType, "image/webp")
    XCTAssertEqual(retried.size, 13)
    XCTAssertEqual(retried.sha256, String(repeating: "b", count: 64))
    XCTAssertTrue(FileManager.default.fileExists(atPath: preparedFileURL.path))
  }

  func testTransientBackgroundUploadFailuresRemainAutomaticallyRetryable() {
    XCTAssertTrue(
      UploadFailure(error: BackgroundUploadError.invalidResponse).automaticallyRetryable)
    XCTAssertTrue(UploadFailure(error: BackgroundUploadError.status(503)).automaticallyRetryable)
    XCTAssertFalse(UploadFailure(error: BackgroundUploadError.status(403)).automaticallyRetryable)
  }
}
