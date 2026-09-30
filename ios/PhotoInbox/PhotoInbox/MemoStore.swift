import Foundation
import Observation

struct InboxMemo: Codable, Identifiable, Sendable {
  var id: String
  var remoteID: String?
  var serverID: String { remoteID ?? id }
  var body: String
  var revision: Int
  var savedBody: String = ""
  var updatedAt: String
  var flight: MemoSave?
  var needsSave: Bool { revision == 0 || body != savedBody }
}

struct MemoSave: Codable, Sendable {
  var operationID: String
  var expectedRevision: Int
  var body: String
  var deleting = false

  var payload: Data {
    get throws {
      var value: [String: Any] = [
        "operation_id": operationID, "expected_revision": expectedRevision,
      ]
      if !deleting { value["body"] = body }
      return try JSONSerialization.data(withJSONObject: value)
    }
  }
}

struct MemoReceipt: Decodable, Sendable {
  let id: String
  let revision: Int
  let state: String
  let result: String
}

struct RemoteMemo: Decodable, Sendable {
  let id: String
  let body: String
  let revision: Int
  let updated_at: String
}

extension MobileAPIClient {
  func memos() async throws -> [RemoteMemo] {
    struct Response: Decodable { let memos: [RemoteMemo] }
    let response: Response = try await memoRequest(path: "/api/mobile/memos", method: "GET")
    return response.memos
  }

  func saveMemo(id: String, operation: MemoSave) async throws -> MemoReceipt {
    try await memoRequest(
      path: "/api/mobile/memos/\(id)", method: operation.deleting ? "DELETE" : "PUT",
      body: operation.payload)
  }

  private func memoRequest<Response: Decodable>(path: String, method: String, body: Data? = nil)
    async throws -> Response
  {
    guard let token else { throw MemoError.pairing }
    var request = URLRequest(
      url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 15)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await transport.data(for: request)
    guard (200...299).contains(response.statusCode) else {
      if response.statusCode == 401 { throw MemoError.pairing }
      throw MemoError.server(response.statusCode)
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}

enum MemoError: LocalizedError {
  case pairing
  case server(Int)
  var errorDescription: String? {
    switch self {
    case .pairing: "メモは端末に保持しています。設定から接続を確認してください。"
    case .server(let status): "メモの保存を確認できません（\(status)）。端末に文章を保持しています。"
    }
  }
}

@MainActor @Observable
final class MemoStore {
  private(set) var memos: [InboxMemo] = []
  private(set) var isSyncing = false
  private(set) var error = ""
  private(set) var notice = ""
  private(set) var isAvailable = true
  private let file: URL
  private var retry: Task<Void, Never>?

  init(file: URL? = nil) {
    self.file = file ?? URL.applicationSupportDirectory.appending(path: "inbox-memos.json")
    do {
      if FileManager.default.fileExists(atPath: self.file.path) {
        memos = try JSONDecoder().decode([InboxMemo].self, from: Data(contentsOf: self.file))
      }
    } catch {
      isAvailable = false
      self.error = "端末のメモを読み込めません。\(error.localizedDescription)"
    }
  }

  private func persist() throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(memos).write(
      to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  @discardableResult
  func add(body: String = "") -> String {
    guard isAvailable else { return "" }
    let id = UUID().uuidString.lowercased()
    memos.insert(
      InboxMemo(id: id, body: body, revision: 0, updatedAt: Date().ISO8601Format()), at: 0)
    saveLocally()
    return id
  }

  @discardableResult
  func edit(id: String, body: String, previousBody: String) -> String {
    guard isAvailable else { return id }
    guard let index = memos.firstIndex(where: { $0.id == id }) else { return add(body: body) }
    if memos[index].flight?.deleting == true || memos[index].body != previousBody {
      return add(body: body)
    }
    memos[index].body = body
    memos[index].updatedAt = Date().ISO8601Format()
    saveLocally()
    return id
  }

  private func saveLocally() {
    do {
      try persist()
      error = ""
    } catch {
      self.error = "端末に保存できません。文章を退避してください。\(error.localizedDescription)"
      return
    }
    retry?.cancel()
    retry = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      await self?.sync()
    }
  }

  func sync(client: MobileAPIClient? = nil) async {
    guard isAvailable, !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }
    do {
      let api =
        try client
        ?? MobileAPIClient(
          baseURL: URL(string: "https://weblog.ason.as")!, token: Credentials.loadToken())
      try persist()
      for id in memos.map(\.id) {
        guard let index = memos.firstIndex(where: { $0.id == id }),
          memos[index].needsSave || memos[index].flight != nil
        else { continue }
        guard memos[index].body.utf8.count <= 512 * 1024 else { throw MemoError.server(413) }
        if memos[index].flight == nil {
          memos[index].flight = MemoSave(
            operationID: UUID().uuidString.lowercased(), expectedRevision: memos[index].revision,
            body: memos[index].body)
          try persist()
        }
        guard let flight = memos[index].flight else { continue }
        let receipt: MemoReceipt
        do {
          receipt = try await api.saveMemo(id: memos[index].serverID, operation: flight)
        } catch MemoError.server(409) where flight.deleting {
          if let current = memos.firstIndex(where: { $0.id == id }) {
            memos[current].flight = nil
            try persist()
          }
          throw MemoError.server(409)
        }
        guard let current = memos.firstIndex(where: { $0.id == id }) else { continue }
        if flight.deleting {
          memos.remove(at: current)
        } else {
          memos[current].remoteID = receipt.id
          memos[current].revision = receipt.revision
          memos[current].savedBody = flight.body
          memos[current].flight = nil
          if receipt.result == "preserved_as_new" { notice = "別の編集があったため、新しいメモとして保存しました。" }
        }
        try persist()
      }
      let remote = try await api.memos()
      for memo in remote {
        if let index = memos.firstIndex(where: { $0.serverID == memo.id }) {
          if memos[index].needsSave || memos[index].flight != nil { continue }
          memos[index] = InboxMemo(
            id: memos[index].id, remoteID: memo.id, body: memo.body, revision: memo.revision,
            savedBody: memo.body, updatedAt: memo.updated_at)
        } else {
          memos.append(
            InboxMemo(
              id: memo.id, body: memo.body, revision: memo.revision, savedBody: memo.body,
              updatedAt: memo.updated_at))
        }
      }
      memos.removeAll { memo in
        !memo.needsSave && memo.flight == nil && !remote.contains(where: { $0.id == memo.serverID })
      }
      memos.sort { $0.updatedAt > $1.updatedAt }
      try persist()
      error = ""
    } catch { self.error = error.localizedDescription }
  }

  func delete(id: String) async {
    await sync()
    guard error.isEmpty, let index = memos.firstIndex(where: { $0.id == id }),
      !memos[index].needsSave, memos[index].flight == nil
    else { return }
    memos[index].flight = MemoSave(
      operationID: UUID().uuidString.lowercased(), expectedRevision: memos[index].revision,
      body: "", deleting: true)
    do { try persist() } catch {
      self.error = error.localizedDescription
      return
    }
    await sync()
  }
}
