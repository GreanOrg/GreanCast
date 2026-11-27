// MCPImage.swift
// Screenshots handed to MCP clients. The image size is a pure function of the screen size in
// points, so a client can send tap coordinates in image pixels and the server can convert them
// back without remembering which screenshot they came from.
//
// 1.5 px per point (603 × 1311 for an iPhone 17 Pro) is exactly the MJPEG frame at the default
// 50 % video quality, so the frame is forwarded as received. The long edge is capped at 1568 px:
// above that, Claude downscales the image and coordinates would no longer match.

import Foundation
import CoreGraphics
import ImageIO

enum MCPImage {
    static let pixelsPerPoint: CGFloat = 1.5
    static let maxLongEdge: CGFloat = 1568

    /// Image pixels per iOS point for a screen of `deviceSize` points.
    static func scale(for deviceSize: CGSize) -> CGFloat {
        let long = max(deviceSize.width, deviceSize.height)
        guard long > 0 else { return pixelsPerPoint }
        return min(pixelsPerPoint, maxLongEdge / long)
    }

    static func size(for deviceSize: CGSize) -> (width: Int, height: Int) {
        let s = scale(for: deviceSize)
        return (Int((deviceSize.width * s).rounded()), Int((deviceSize.height * s).rounded()))
    }

    /// Image pixel → iOS point.
    static func point(x: Double, y: Double, deviceSize: CGSize) -> CGPoint {
        let s = scale(for: deviceSize)
        return CGPoint(x: x / s, y: y / s)
    }

    /// JPEG of exactly `size(for: deviceSize)` pixels made from a JPEG or PNG of the screen.
    /// A JPEG that already has that size (±2 px of rounding) is returned untouched.
    static func jpeg(from data: Data, deviceSize: CGSize) -> Data? {
        let target = size(for: deviceSize)
        guard target.width > 0, target.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let isJPEG = data.starts(with: [0xFF, 0xD8])
        if isJPEG, abs(image.width - target.width) <= 2, abs(image.height - target.height) <= 2 { return data }

        guard let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
