import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardSyncCore

final class ClipboardImageIdentityTests: XCTestCase {
    func testDifferentPNGEncodingsOfSamePixelsHaveSameSignature() throws {
        let image = try makeImage(lastBlueValue: 90)
        let compact = try encode(image, as: .png, dpi: 72)
        let metadataVariant = try encode(image, as: .png, dpi: 144)

        XCTAssertNotEqual(compact, metadataVariant)
        XCTAssertEqual(
            ClipboardImageIdentity.signature(for: compact),
            ClipboardImageIdentity.signature(for: metadataVariant)
        )
    }

    func testPNGAndTIFFRepresentationsOfSamePixelsHaveSameSignature() throws {
        let image = try makeImage(lastBlueValue: 90)
        let png = try encode(image, as: .png, dpi: 72)
        let tiff = try encode(image, as: .tiff, dpi: 72)

        XCTAssertEqual(
            ClipboardImageIdentity.signature(for: png),
            ClipboardImageIdentity.signature(for: tiff)
        )
    }

    func testPixelChangeProducesDifferentSignature() throws {
        let first = try encode(makeImage(lastBlueValue: 90), as: .png, dpi: 72)
        let second = try encode(makeImage(lastBlueValue: 91), as: .png, dpi: 72)

        XCTAssertNotEqual(
            ClipboardImageIdentity.signature(for: first),
            ClipboardImageIdentity.signature(for: second)
        )
    }

    func testInvalidImageDataUsesStableDistinctByteIdentity() {
        let first = Data("not-image-a".utf8)
        let second = Data("not-image-b".utf8)

        XCTAssertEqual(
            ClipboardImageIdentity.signature(for: first),
            ClipboardImageIdentity.signature(for: first)
        )
        XCTAssertNotEqual(
            ClipboardImageIdentity.signature(for: first),
            ClipboardImageIdentity.signature(for: second)
        )
    }

    private func makeImage(lastBlueValue: UInt8) throws -> CGImage {
        let pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            40, 50, lastBlueValue, 128,
        ]
        let data = Data(pixels)
        guard
            let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private func encode(_ image: CGImage, as type: UTType, dpi: Int) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw TestError.destinationCreationFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.encodingFailed
        }
        return output as Data
    }

    private enum TestError: Error {
        case imageCreationFailed
        case destinationCreationFailed
        case encodingFailed
    }
}
