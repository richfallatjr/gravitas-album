import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BubbleFresnelMask {
    public static func ensureMaskURL(
        size: Int = 256,
        power: CGFloat = 3.0,
        edgeStart: CGFloat = 0.15,
        edgeEnd: CGFloat = 0.95
    ) throws -> URL {
        let fm = FileManager.default
        let dir = try masksDirectoryURL(fileManager: fm)

        let w = max(2, size)
        let h = w

        let fileName = "bubble_fresnel_\(w)_p\(Int(power * 100))_e\(Int(edgeStart * 100))_E\(Int(edgeEnd * 100)).png"
        let url = dir.appendingPathComponent(fileName, isDirectory: false)
        if fm.fileExists(atPath: url.path) { return url }

        let tmpURL = url.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        var data = [UInt8](repeating: 0, count: w * h * 4)

        func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }

        for y in 0..<h {
            for x in 0..<w {
                // UV in [-1, 1]
                let u = (CGFloat(x) + 0.5) / CGFloat(w) * 2 - 1
                let v = (CGFloat(y) + 0.5) / CGFloat(h) * 2 - 1
                let r = min(1.0, sqrt(u * u + v * v))

                // Sphere-impostor normal.z
                let nz = sqrt(max(0.0, 1.0 - r * r))

                // Fresnel-like term: stronger at rim
                let f = pow(1.0 - nz, power)

                // Feather band control
                let m = smoothstep(edgeStart, edgeEnd, f)
                let a = UInt8(min(max(m * 255.0, 0), 255))

                let i = (y * w + x) * 4
                data[i + 0] = 255 // R
                data[i + 1] = 255 // G
                data[i + 2] = 255 // B
                data[i + 3] = a // Alpha = mask
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 4
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let img = ctx.makeImage() else {
            throw BubbleFresnelMaskError.renderFailed
        }

        guard let dest = CGImageDestinationCreateWithURL(
            tmpURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw BubbleFresnelMaskError.pngEncodeFailed
        }

        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BubbleFresnelMaskError.pngEncodeFailed
        }

        try fm.moveItem(at: tmpURL, to: url)
        return url
    }

    private static func masksDirectoryURL(fileManager fm: FileManager) throws -> URL {
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw BubbleFresnelMaskError.cachesUnavailable
        }
        let dir = caches.appendingPathComponent("gravitas_album/masks", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private enum BubbleFresnelMaskError: Error {
    case cachesUnavailable
    case renderFailed
    case pngEncodeFailed
}
