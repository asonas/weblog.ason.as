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

enum MobileAPIError: Error, Equatable {
    case invalidResponse
    case server(Int)
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
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else { throw MobileAPIError.server(response.statusCode) }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
}

private struct EmptyResponse: Codable {}
