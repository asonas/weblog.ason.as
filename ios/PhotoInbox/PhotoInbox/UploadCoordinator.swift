import BackgroundTasks
import Foundation
import Observation
@preconcurrency import Photos

@MainActor
@Observable
final class UploadCoordinator {
  private(set) var pendingCount = 0
  private(set) var isSending = false
  private(set) var lastError: String?
  private(set) var failuresByAssetID: [String: UploadFailure] = [:]
  private let store: UploadQueueStore
  private let library: PhotoLibrary
  private let selection: PhotoSelectionStore
  private let preparer = ImagePreparer()
  private let uploader = BackgroundUploader.shared
  private let queueDirectory: URL

  init(library: PhotoLibrary, selection: PhotoSelectionStore) {
    self.library = library
    self.selection = selection
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    queueDirectory = support.appending(path: "PhotoInbox", directoryHint: .isDirectory)
    store = UploadQueueStore(fileURL: queueDirectory.appending(path: "queue.json"))
  }

  func restoreAndRetry() async {
    await refreshState()
    guard (try? Credentials.loadToken()) != nil else { return }
    await processQueue()
  }

  func enqueue(_ photos: [LibraryPhoto]) async {
    do {
      try await store.enqueue(
        photos.map {
          UploadItem(
            assetLocalIdentifier: $0.id,
            capturedAt: $0.capturedAt,
            capturedAtSource: $0.capturedAtSource
          )
        })
      await refreshState()
      scheduleRetry()
      await processQueue()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func processQueue() async {
    guard !isSending, let token = try? Credentials.loadToken() else { return }
    isSending = true
    defer { isSending = false }
    let api = MobileAPIClient(baseURL: URL(string: "https://weblog.ason.as")!, token: token)
    let items = (try? await store.items()) ?? []
    for item in items where item.shouldAttemptAutomatically {
      do {
        try await send(item, api: api)
        try await store.remove(item.clientUploadID)
      } catch {
        let failure = UploadFailure(error: error)
        try? await store.updateFailure(item.clientUploadID, failure: failure)
        lastError = failure.message
        if failure.automaticallyRetryable { scheduleRetry() }
      }
      await refreshState()
    }
  }

  func retryFailed(assetID: String) async {
    guard !isSending else { return }
    guard
      let item = try? await store.items().first(where: {
        $0.assetLocalIdentifier == assetID && $0.failure != nil
      })
    else { return }
    try? await store.retry(item.clientUploadID)
    await refreshState()
    await processQueue()
  }

  func excludeFailed(assetID: String) async {
    guard !isSending else { return }
    guard
      let item = try? await store.items().first(where: {
        $0.assetLocalIdentifier == assetID && $0.failure != nil
      })
    else { return }
    try? await store.remove(item.clientUploadID)
    selection.exclude(assetID)
    await refreshState()
  }

  private func send(_ original: UploadItem, api: MobileAPIClient) async throws {
    var item = original
    let prepared: PreparedPhoto
    if let path = item.preparedFilePath,
      let type = item.contentType,
      let size = item.size,
      let sha = item.sha256,
      FileManager.default.fileExists(atPath: path)
    {
      prepared = .init(fileURL: URL(filePath: path), contentType: type, size: size, sha256: sha)
    } else {
      guard let asset = library.asset(identifier: item.assetLocalIdentifier) else {
        throw ImagePreparationError.unavailable
      }
      prepared = try await preparer.prepare(
        asset: asset, directory: queueDirectory.appending(path: "prepared"), id: item.clientUploadID
      )
      item.preparedFilePath = prepared.fileURL.path
      item.contentType = prepared.contentType
      item.size = prepared.size
      item.sha256 = prepared.sha256
      try await store.update(item)
    }
    let signed = try await api.createUpload(
      .init(
        clientUploadID: item.clientUploadID,
        contentType: prepared.contentType,
        size: prepared.size,
        sha256: prepared.sha256,
        capturedAt: item.capturedAt,
        capturedAtSource: item.capturedAtSource
      ))
    try await store.updateStage(item.clientUploadID, stage: .uploading(uploadID: signed.uploadID))
    try await uploader.upload(fileURL: prepared.fileURL, to: signed)
    try await store.updateStage(item.clientUploadID, stage: .completing(uploadID: signed.uploadID))
    try await api.complete(uploadID: signed.uploadID)
    selection.markUploaded([item.assetLocalIdentifier])
    try? FileManager.default.removeItem(at: prepared.fileURL)
  }

  private func refreshState() async {
    let items = (try? await store.items()) ?? []
    pendingCount = items.count
    failuresByAssetID = Dictionary(
      uniqueKeysWithValues: items.compactMap { item in
        item.failure.map { (item.assetLocalIdentifier, $0) }
      })
  }

  private func scheduleRetry() {
    let request = BGProcessingTaskRequest(identifier: "com.asonas.weblog.PhotoInbox.retry-uploads")
    request.requiresNetworkConnectivity = true
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}
