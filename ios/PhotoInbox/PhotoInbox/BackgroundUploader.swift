import Foundation

enum BackgroundUploadError: Error { case invalidResponse, status(Int) }

final class BackgroundUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private lazy var session = URLSession(
        configuration: URLSessionConfiguration.background(
            withIdentifier: "com.asonas.weblog.PhotoInbox.uploads"
        ),
        delegate: self,
        delegateQueue: nil
    )

    func upload(fileURL: URL, to signedUpload: SignedUpload) async throws {
        let bodyURL = try multipartFile(fileURL: fileURL, fields: signedUpload.fields)
        var request = URLRequest(url: signedUpload.uploadURL)
        request.httpMethod = "POST"
        let boundary = bodyURL.deletingPathExtension().lastPathComponent
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            lock.withLock { continuations[task.taskIdentifier] = continuation }
            task.taskDescription = bodyURL.path
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let path = task.taskDescription { try? FileManager.default.removeItem(atPath: path) }
        let continuation = lock.withLock { continuations.removeValue(forKey: task.taskIdentifier) }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error); return }
        guard let response = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: BackgroundUploadError.invalidResponse)
            return
        }
        guard (200...299).contains(response.statusCode) else {
            continuation.resume(throwing: BackgroundUploadError.status(response.statusCode))
            return
        }
        continuation.resume()
    }

    private func multipartFile(fileURL: URL, fields: [String: String]) throws -> URL {
        let boundary = "PhotoInbox-\(UUID().uuidString)"
        let target = FileManager.default.temporaryDirectory.appending(path: "\(boundary).multipart")
        var body = Data()
        for key in fields.keys.sorted() {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo\"\r\nContent-Type: \(fields["Content-Type"] ?? "application/octet-stream")\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try body.write(to: target, options: .atomic)
        return target
    }
}
