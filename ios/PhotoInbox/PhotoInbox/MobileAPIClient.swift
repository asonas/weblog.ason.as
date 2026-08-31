import Foundation

protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw MobileAPIError.invalidResponse }
    return (data, response)
  }
}

struct ProblemDetails: Decodable, Equatable, Sendable {
  let type: URL
  let title: String
  let status: Int
  let detail: String?
  let instance: URL?
  let code: String?
  let field: String?
  let requestID: String?

  enum CodingKeys: String, CodingKey {
    case type, title, status, detail, instance, code, field
    case requestID = "request_id"
  }
}

enum MobileAPIError: Error, Equatable {
  case invalidResponse
  case server(status: Int, problem: ProblemDetails?)

  var automaticallyRetryable: Bool {
    switch self {
    case .invalidResponse:
      true
    case .server(let status, _):
      status == 408 || status == 429 || status >= 500
    }
  }
}

extension MobileAPIError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "サーバーからの応答を確認できませんでした。"
    case .server(_, let problem):
      switch problem?.code {
      case "invalid_client_upload_id":
        "写真の送信情報が不正です。もう一度選び直してください。"
      case "unsupported_content_type":
        "この写真形式には対応していません。"
      case "invalid_upload_size":
        "写真のサイズ情報が不正です。もう一度選び直してください。"
      case "invalid_sha256":
        "写真データの確認に失敗しました。もう一度選び直してください。"
      case "invalid_captured_at_source":
        "写真の撮影日時情報が不正です。"
      case "invalid_json_body", "invalid_content_type":
        "写真の送信情報を作成できませんでした。"
      default:
        "写真を送信できませんでした。"
      }
    }
  }
}

struct CreateUploadRequest: Encodable, Sendable {
  let clientUploadID: UUID
  let contentType: String
  let size: Int
  let sha256: String
  let capturedAt: Date
  let capturedAtSource: String

  enum CodingKeys: String, CodingKey {
    case clientUploadID = "client_upload_id"
    case contentType = "content_type"
    case size, sha256
    case capturedAt = "captured_at"
    case capturedAtSource = "captured_at_source"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(clientUploadID.uuidString.lowercased(), forKey: .clientUploadID)
    try container.encode(contentType, forKey: .contentType)
    try container.encode(size, forKey: .size)
    try container.encode(sha256, forKey: .sha256)
    try container.encode(capturedAt, forKey: .capturedAt)
    try container.encode(capturedAtSource, forKey: .capturedAtSource)
  }
}

struct SignedUpload: Decodable, Sendable {
  let uploadID: String
  let uploadURL: URL
  let fields: [String: String]
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case uploadID = "upload_id"
    case uploadURL = "upload_url"
    case fields
    case expiresAt = "expires_at"
  }
}

struct PairedDevice: Decodable, Sendable {
  let token: String
}

struct MobileAPIClient: Sendable {
  let baseURL: URL
  let token: String?
  let transport: any HTTPTransport

  init(baseURL: URL, token: String? = nil, transport: any HTTPTransport = URLSessionTransport()) {
    self.baseURL = baseURL
    self.token = token
    self.transport = transport
  }

  func exchangePairing(code: String, deviceName: String) async throws -> PairedDevice {
    try await send(
      path: "/api/mobile/pairings/exchange",
      body: ["code": code.uppercased(), "device_name": deviceName],
      authenticated: false
    )
  }

  func createUpload(_ payload: CreateUploadRequest) async throws -> SignedUpload {
    try await send(path: "/api/mobile/uploads", body: payload, authenticated: true)
  }

  func complete(uploadID: String) async throws {
    let _: EmptyResponse = try await send(
      path: "/api/mobile/uploads/\(uploadID)/complete",
      body: [String: String](),
      authenticated: true
    )
  }

  private func send<Body: Encodable, Response: Decodable>(
    path: String, body: Body, authenticated: Bool
  ) async throws -> Response {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "application/json, application/problem+json", forHTTPHeaderField: "Accept"
    )
    if authenticated, let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    request.httpBody = try encoder.encode(body)
    let (data, response) = try await transport.data(for: request)
    guard (200...299).contains(response.statusCode) else {
      let problem = try? JSONDecoder().decode(ProblemDetails.self, from: data)
      throw MobileAPIError.server(status: response.statusCode, problem: problem)
    }
    if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Response.self, from: data)
  }
}

private struct EmptyResponse: Codable {}
