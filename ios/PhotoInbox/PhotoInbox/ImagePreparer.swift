@preconcurrency import Photos
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct PreparedPhoto: Sendable {
    let fileURL: URL
    let contentType: String
    let size: Int
    let sha256: String
}

enum ImagePreparationError: Error { case unavailable, conversionFailed }

struct ImagePreparer {
    func prepare(asset: PHAsset, directory: URL, id: UUID) async throws -> PreparedPhoto {
        let data = try await imageData(asset: asset)
        return try prepare(data: data, directory: directory, id: id)
    }

    func prepare(data: Data, directory: URL, id: UUID) throws -> PreparedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = sourceProperties[kCGImagePropertyPixelWidth] as? Int,
              let height = sourceProperties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary) else {
            throw ImagePreparationError.conversionFailed
        }
        let hasAlpha = image.alphaInfo == .first || image.alphaInfo == .last ||
            image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let contentType = hasAlpha ? "image/png" : "image/jpeg"
        let fileURL = directory.appending(path: "\(id.uuidString).\(hasAlpha ? "png" : "jpg")")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, type.identifier as CFString, 1, nil
        ) else { throw ImagePreparationError.conversionFailed }
        let properties: CFDictionary = hasAlpha
            ? [:] as CFDictionary
            : [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ImagePreparationError.conversionFailed }
        let output = try Data(contentsOf: fileURL)
        return PreparedPhoto(
            fileURL: fileURL,
            contentType: contentType,
            size: output.count,
            sha256: SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func imageData(asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ImagePreparationError.unavailable)
                }
            }
        }
    }
}
