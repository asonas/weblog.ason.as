import CryptoKit
import ImageIO
@preconcurrency import Photos
import SDWebImage
import SDWebImageWebPCoder
import UIKit

struct PreparedPhoto: Sendable {
  let fileURL: URL
  let contentType: String
  let size: Int
  let sha256: String
}

enum ImagePreparationError: Error { case unavailable, conversionFailed }

struct ImagePreparer {
  private let maxBytes: Int

  init(maxBytes: Int = 25 * 1024 * 1024) {
    self.maxBytes = maxBytes
  }

  func prepare(asset: PHAsset, directory: URL, id: UUID) async throws -> PreparedPhoto {
    let data = try await imageData(asset: asset)
    return try prepare(data: data, directory: directory, id: id)
  }

  func prepare(data: Data, directory: URL, id: UUID) throws -> PreparedPhoto {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = sourceProperties[kCGImagePropertyPixelWidth] as? Int,
      let height = sourceProperties[kCGImagePropertyPixelHeight] as? Int
    else {
      throw ImagePreparationError.conversionFailed
    }
    let fileURL = directory.appending(path: "\(id.uuidString).webp")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for scale in [1.0, 0.85, 0.7, 0.55] {
      guard
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize:
              max(1, Int((Double(max(width, height)) * scale).rounded())),
          ] as CFDictionary)
      else { throw ImagePreparationError.conversionFailed }

      for quality in [0.82, 0.7, 0.58] {
        guard
          let output = SDImageWebPCoder.shared.encodedData(
            with: UIImage(cgImage: image),
            format: .webP,
            options: [.encodeCompressionQuality: quality]
          )
        else {
          throw ImagePreparationError.conversionFailed
        }
        guard output.count <= maxBytes else { continue }

        try output.write(to: fileURL, options: .atomic)
        return PreparedPhoto(
          fileURL: fileURL,
          contentType: "image/webp",
          size: output.count,
          sha256: SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
        )
      }
    }
    throw ImagePreparationError.conversionFailed
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
