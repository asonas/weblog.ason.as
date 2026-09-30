import XCTest

@testable import PhotoInbox

final class MemoStoreTests: XCTestCase {
  @MainActor
  func testLostResponseReplaysThePersistedOperationAfterRestartAndKeepsLaterTyping() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "memos.json")
    let transport = MemoTransport()
    let client = MobileAPIClient(
      baseURL: URL(string: "https://example.test")!, token: "paired", transport: transport)
    let first = MemoStore(file: file)
    let key = first.add(body: "最初のメモ")
    await first.sync(client: client)
    XCTAssertFalse(first.error.isEmpty)
    let operation = try XCTUnwrap(first.memos.first?.flight?.operationID)
    let restored = MemoStore(file: file)
    restored.edit(id: key, body: "最初のメモに追記", previousBody: "最初のメモ")
    await restored.sync(client: client)
    XCTAssertEqual(restored.memos.first?.body, "最初のメモに追記")
    XCTAssertEqual(restored.memos.first?.savedBody, "最初のメモ")
    XCTAssertEqual(restored.memos.first?.serverID, "conflict-copy")
    XCTAssertEqual(restored.memos.first?.id, key)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    for request in requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer paired")
      let payload = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual(payload["operation_id"] as? String, operation)
      XCTAssertEqual(payload["body"] as? String, "最初のメモ")
    }
  }

  @MainActor
  func testUnsentTextSurvivesRestartAndConcurrentEditingPreservesANewMemo() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "memos.json")
    let store = MemoStore(file: file)
    let key = store.add(body: "保存する本文")
    store.edit(id: key, body: "先の編集", previousBody: "保存する本文")
    let copy = store.edit(id: key, body: "別画面の編集", previousBody: "保存する本文")
    XCTAssertNotEqual(copy, key)
    let restored = MemoStore(file: file)
    XCTAssertEqual(Set(restored.memos.map(\.body)), Set(["先の編集", "別画面の編集"]))
  }
}

private actor MemoTransport: HTTPTransport {
  var requests: [URLRequest] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.httpMethod == "PUT" {
      requests.append(request)
      if requests.count == 1 { throw URLError(.networkConnectionLost) }
      return (
        Data(
          #"{"id":"conflict-copy","revision":1,"state":"available","result":"preserved_as_new"}"#
            .utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    return (
      Data(
        #"{"memos":[{"id":"conflict-copy","body":"最初のメモ","revision":1,"updated_at":"2026-10-01T00:00:00Z"}]}"#
          .utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}
