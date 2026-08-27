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

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 4)
    }

    private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        let pixels = Data(repeating: 0xff, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
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
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
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
}
