import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Builds a representation-independent identity for clipboard images.
///
/// Pasteboard owners can publish the same image more than once using PNG/TIFF data with different
/// metadata or compression. Hashing the encoded bytes treats those representations as different
/// clipboard entries, so render into a fixed 8-bit sRGB RGBA layout before hashing instead.
public enum ClipboardImageIdentity {
    public static func signature(for data: Data) -> String {
        if let pixelDigest = pixelDigest(for: data) {
            return "pixels:\(pixelDigest)"
        }

        // Unsupported image data still needs a deterministic, non-collapsing identity for logs
        // and error paths, so fall back to hashing its encoded bytes.
        return "encoded:\(digest(data))"
    }

    public static func signature(forInvalidBase64 value: String) -> String {
        "invalid-base64:\(digest(Data(value.utf8)))"
    }

    private static func pixelDigest(for data: Data) -> String? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: true] as CFDictionary
            ),
            image.width > 0,
            image.height > 0,
            image.width <= Int.max / 4
        else {
            return nil
        }

        let bytesPerRow = image.width * 4
        guard image.height <= Int.max / bytesPerRow else {
            return nil
        }

        var pixels = Data(count: bytesPerRow * image.height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let baseAddress = bytes.baseAddress,
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else {
                return false
            }

            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }

        guard rendered else {
            return nil
        }

        var hasher = SHA256()
        hasher.update(data: Data("\(image.width)x\(image.height):".utf8))
        hasher.update(data: pixels)
        return hex(hasher.finalize())
    }

    private static func digest(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
