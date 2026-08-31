import XCTest

@testable import PhotoInbox

final class MobileAPIClientTests: XCTestCase {
  func testCreateUploadUsesBearerTokenAndStableClientID() async throws {
    let transport = RecordingTransport(
      response: """
        {"upload_id":"upload-1","upload_url":"https://uploads.example.test/","fields":{"key":"assets/inbox/a.jpg"},"expires_at":"2026-08-27T12:00:00Z"}
        """.data(using: .utf8)!)
    let client = MobileAPIClient(
      baseURL: URL(string: "https://weblog.ason.as")!, token: "secret", transport: transport
    )
    let id = UUID(uuidString: "B4D7F677-E49C-4D39-9A6B-4A847B5E2661")!

    _ = try await client.createUpload(
      .init(
        clientUploadID: id,
        contentType: "image/jpeg",
        size: 42,
        sha256: String(repeating: "a", count: 64),
        capturedAt: Date(timeIntervalSince1970: 0),
        capturedAtSource: "photos"
      ))

    let recordedRequest = await transport.lastRequest
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.url?.path, "/api/mobile/uploads")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept"),
      "application/json, application/problem+json"
    )
    let payload = try XCTUnwrap(request.httpBody)
    XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains(id.uuidString.lowercased()))
  }

  func testCreateUploadDecodesProblemDetailsForRejectedPhoto() async throws {
    let transport = RecordingTransport(
      response: """
        {
          "type":"https://weblog.ason.as/problems/mobile-upload/invalid-upload-size",
          "title":"Invalid upload size",
          "status":422,
          "detail":"size must be a positive integer",
          "instance":"https://weblog.ason.as/problems/instances/request-1",
          "code":"invalid_upload_size",
          "field":"size",
          "request_id":"request-1",
          "future_extension":"ignored"
        }
        """.data(using: .utf8)!,
      statusCode: 422
    )
    let client = MobileAPIClient(
      baseURL: URL(string: "https://weblog.ason.as")!, token: "secret", transport: transport
    )

    do {
      _ = try await client.createUpload(makeUploadRequest())
      XCTFail("Expected the upload request to be rejected")
    } catch let MobileAPIError.server(status, problem) {
      XCTAssertEqual(status, 422)
      XCTAssertEqual(problem?.code, "invalid_upload_size")
      XCTAssertEqual(problem?.field, "size")
      XCTAssertEqual(problem?.requestID, "request-1")
      XCTAssertEqual(
        MobileAPIError.server(status: status, problem: problem).errorDescription,
        "写真のサイズ情報が不正です。もう一度選び直してください。"
      )
    }
  }

  func testUnknownProblemCodeUsesGenericMessageAndKeepsRequestID() async throws {
    let transport = RecordingTransport(
      response: """
        {
          "type":"https://weblog.ason.as/problems/mobile-upload/future-problem",
          "title":"Future problem",
          "status":422,
          "detail":"A future diagnostic",
          "code":"future_problem",
          "request_id":"request-2"
        }
        """.data(using: .utf8)!,
      statusCode: 422
    )
    let client = MobileAPIClient(
      baseURL: URL(string: "https://weblog.ason.as")!, token: "secret", transport: transport
    )

    do {
      _ = try await client.createUpload(makeUploadRequest())
      XCTFail("Expected the upload request to be rejected")
    } catch let error as MobileAPIError {
      XCTAssertEqual(error.errorDescription, "写真を送信できませんでした。")
      guard case .server(_, let problem) = error else { return XCTFail("Expected server error") }
      XCTAssertEqual(problem?.requestID, "request-2")
    }
  }

  private func makeUploadRequest() -> CreateUploadRequest {
    .init(
      clientUploadID: UUID(uuidString: "B4D7F677-E49C-4D39-9A6B-4A847B5E2661")!,
      contentType: "image/jpeg",
      size: 42,
      sha256: String(repeating: "a", count: 64),
      capturedAt: Date(timeIntervalSince1970: 0),
      capturedAtSource: "photos"
    )
  }
}

private actor RecordingTransport: HTTPTransport {
  private(set) var lastRequest: URLRequest?
  let response: Data
  let statusCode: Int

  init(response: Data, statusCode: Int = 201) {
    self.response = response
    self.statusCode = statusCode
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lastRequest = request
    return (
      response,
      HTTPURLResponse(
        url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
      )!
    )
  }
}
