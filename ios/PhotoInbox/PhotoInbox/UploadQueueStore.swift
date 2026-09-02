import Foundation

struct UploadFailure: Codable, Equatable, Sendable {
  let code: String?
  let field: String?
  let message: String
  let requestID: String?
  let automaticallyRetryable: Bool

  var requiresRepreparation: Bool {
    code == "invalid_upload_size" || code == "unsupported_content_type"
      || (code == nil && !automaticallyRetryable)
  }

  init(
    code: String? = nil,
    field: String? = nil,
    message: String,
    requestID: String? = nil,
    automaticallyRetryable: Bool
  ) {
    self.code = code
    self.field = field
    self.message = message
    self.requestID = requestID
    self.automaticallyRetryable = automaticallyRetryable
  }

  init(error: Error) {
    if let apiError = error as? MobileAPIError {
      switch apiError {
      case .invalidResponse:
        self.init(message: apiError.localizedDescription, automaticallyRetryable: true)
      case .server(_, let problem):
        self.init(
          code: problem?.code,
          field: problem?.field,
          message: apiError.localizedDescription,
          requestID: problem?.requestID,
          automaticallyRetryable: apiError.automaticallyRetryable
        )
      }
    } else if let uploadError = error as? BackgroundUploadError {
      let retryable =
        switch uploadError {
        case .invalidResponse: true
        case .status(let status): status == 408 || status == 429 || status >= 500
        }
      self.init(message: error.localizedDescription, automaticallyRetryable: retryable)
    } else {
      self.init(
        message: error.localizedDescription,
        automaticallyRetryable: error is URLError
      )
    }
  }
}

struct UploadItem: Codable, Equatable, Identifiable, Sendable {
  enum Stage: Codable, Equatable, Sendable {
    case pending
    case uploading(uploadID: String)
    case completing(uploadID: String)
    case failed(message: String)
  }

  var id: UUID { clientUploadID }
  let clientUploadID: UUID
  let assetLocalIdentifier: String
  let capturedAt: Date
  let capturedAtSource: String
  var stage: Stage
  var preparedFilePath: String?
  var contentType: String?
  var size: Int?
  var sha256: String?
  var failure: UploadFailure?

  var shouldAttemptAutomatically: Bool {
    failure?.automaticallyRetryable ?? true
  }

  init(
    clientUploadID: UUID = UUID(),
    assetLocalIdentifier: String,
    capturedAt: Date,
    capturedAtSource: String = "photos",
    stage: Stage = .pending,
    preparedFilePath: String? = nil,
    contentType: String? = nil,
    size: Int? = nil,
    sha256: String? = nil,
    failure: UploadFailure? = nil
  ) {
    self.clientUploadID = clientUploadID
    self.assetLocalIdentifier = assetLocalIdentifier
    self.capturedAt = capturedAt
    self.capturedAtSource = capturedAtSource
    self.stage = stage
    self.preparedFilePath = preparedFilePath
    self.contentType = contentType
    self.size = size
    self.sha256 = sha256
    self.failure = failure
  }
}

actor UploadQueueStore {
  private let fileURL: URL
  private var values: [UploadItem]?

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func items() throws -> [UploadItem] {
    try load()
  }

  func enqueue(_ newItems: [UploadItem]) throws {
    var current = try load()
    var existing = Set(current.map(\.assetLocalIdentifier))
    for item in newItems where existing.insert(item.assetLocalIdentifier).inserted {
      current.append(item)
    }
    try save(current)
  }

  func update(_ item: UploadItem) throws {
    var current = try load()
    guard let index = current.firstIndex(where: { $0.clientUploadID == item.clientUploadID }) else {
      return
    }
    current[index] = item
    try save(current)
  }

  func updateStage(_ id: UUID, stage: UploadItem.Stage) throws {
    var current = try load()
    guard let index = current.firstIndex(where: { $0.clientUploadID == id }) else { return }
    current[index].stage = stage
    try save(current)
  }

  func updateFailure(_ id: UUID, failure: UploadFailure) throws {
    var current = try load()
    guard let index = current.firstIndex(where: { $0.clientUploadID == id }) else { return }
    current[index].stage = .failed(message: failure.message)
    current[index].failure = failure
    try save(current)
  }

  func retry(_ id: UUID) throws {
    var current = try load()
    guard let index = current.firstIndex(where: { $0.clientUploadID == id }) else { return }
    if current[index].failure?.requiresRepreparation == true {
      if let path = current[index].preparedFilePath,
        FileManager.default.fileExists(atPath: path)
      {
        try FileManager.default.removeItem(atPath: path)
      }
      current[index].preparedFilePath = nil
      current[index].contentType = nil
      current[index].size = nil
      current[index].sha256 = nil
    }
    current[index].stage = .pending
    current[index].failure = nil
    try save(current)
  }

  func remove(_ id: UUID) throws {
    try save(try load().filter { $0.clientUploadID != id })
  }

  private func load() throws -> [UploadItem] {
    if let values { return values }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      values = []
      return []
    }
    let decoded = try JSONDecoder().decode([UploadItem].self, from: Data(contentsOf: fileURL))
    values = decoded
    return decoded
  }

  private func save(_ items: [UploadItem]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
    values = items
  }
}
