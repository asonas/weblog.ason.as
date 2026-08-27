import Foundation

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

    init(
        clientUploadID: UUID = UUID(),
        assetLocalIdentifier: String,
        capturedAt: Date,
        capturedAtSource: String = "photos",
        stage: Stage = .pending,
        preparedFilePath: String? = nil,
        contentType: String? = nil,
        size: Int? = nil,
        sha256: String? = nil
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
        guard let index = current.firstIndex(where: { $0.clientUploadID == item.clientUploadID }) else { return }
        current[index] = item
        try save(current)
    }

    func updateStage(_ id: UUID, stage: UploadItem.Stage) throws {
        var current = try load()
        guard let index = current.firstIndex(where: { $0.clientUploadID == id }) else { return }
        current[index].stage = stage
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
