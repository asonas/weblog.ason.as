import XCTest
@testable import PhotoInbox

final class MobileAPIClientTests: XCTestCase {
    func testCreateUploadUsesBearerTokenAndStableClientID() async throws {
        let transport = RecordingTransport(response: """
          {"upload_id":"upload-1","upload_url":"https://uploads.example.test/","fields":{"key":"assets/inbox/a.jpg"},"expires_at":"2026-08-27T12:00:00Z"}
          """.data(using: .utf8)!)
        let client = MobileAPIClient(
            baseURL: URL(string: "https://weblog.ason.as")!, token: "secret", transport: transport
        )
        let id = UUID(uuidString: "B4D7F677-E49C-4D39-9A6B-4A847B5E2661")!

        _ = try await client.createUpload(.init(
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
        let payload = try XCTUnwrap(request.httpBody)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains(id.uuidString.lowercased()))
    }
}

private actor RecordingTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?
    let response: Data

    init(response: Data) { self.response = response }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        return (response, HTTPURLResponse(
            url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
        )!)
    }
}
