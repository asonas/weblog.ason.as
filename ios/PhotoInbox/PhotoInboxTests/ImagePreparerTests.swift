import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PhotoInbox

final class ImagePreparerTests: XCTestCase {
  func testPrepareBakesExifOrientationIntoOutputPixels() async throws {
    let input = try jpeg(width: 4, height: 2, orientation: 6)
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    let prepared = try ImagePreparer().prepare(
      data: input,
      directory: directory,
      id: UUID()
    )
    let output = try Data(contentsOf: prepared.fileURL)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

    XCTAssertEqual(prepared.contentType, "image/webp")
    XCTAssertEqual(prepared.fileURL.pathExtension, "webp")
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.webP.identifier)
    XCTAssertEqual(prepared.size, output.count)
    XCTAssertEqual(
      prepared.sha256,
      SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
    )
    XCTAssertEqual(image.width, 2)
    XCTAssertEqual(image.height, 4)
  }

  func testPrepareReducesPixelsToMeetTheByteLimit() throws {
    let input = try noisyJPEG(width: 256, height: 256)
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    let prepared = try ImagePreparer(maxBytes: 15_000).prepare(
      data: input,
      directory: directory,
      id: UUID()
    )
    let output = try Data(contentsOf: prepared.fileURL)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

    XCTAssertLessThanOrEqual(output.count, 15_000)
    XCTAssertLessThan(image.width, 256)
    XCTAssertLessThan(image.height, 256)
  }

  func testPrepareEncodesAlphaInputAsWebP() throws {
    let input = try pngWithAlpha(width: 4, height: 4)
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    let prepared = try ImagePreparer().prepare(
      data: input,
      directory: directory,
      id: UUID()
    )
    let output = try Data(contentsOf: prepared.fileURL)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))

    XCTAssertEqual(prepared.contentType, "image/webp")
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.webP.identifier)
  }

  private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
    let pixels = Data(repeating: 0xff, count: width * height * 4)
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ))
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ))
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImagePropertyOrientation: orientation] as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func noisyJPEG(width: Int, height: Int) throws -> Data {
    var value: UInt32 = 0x1234_5678
    let pixels = Data(
      (0..<(width * height * 4)).map { _ in
        value = 1_664_525 &* value &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: value >> 24)
      })
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ))
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func pngWithAlpha(width: Int, height: Int) throws -> Data {
    let pixels = Data(repeating: 0x7f, count: width * height * 4)
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ))
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }
}
