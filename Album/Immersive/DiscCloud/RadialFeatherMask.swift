import Foundation
import CoreGraphics

public enum RadialFeatherMask {
    /// Creates a grayscale mask suitable for `CGContext.clip(to:mask:)`.
    /// - Parameters:
    ///   - size: Mask size in pixels (square).
    ///   - feather: Fraction of radius [0..1]. `0.12` means last 12% fades out.
    public static func makeMask(size: Int, feather: CGFloat) -> CGImage? {
        let s = max(8, size)
        let f = min(max(feather, 0.0), 0.45)
        let inner = max(0, 1.0 - f)

        func smoothstep(_ x: CGFloat) -> CGFloat {
            let t = min(max(x, 0), 1)
            return t * t * (3 - 2 * t)
        }

        var bytes = Data(count: s * s)
        bytes.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<s {
                for x in 0..<s {
                    let fx = (CGFloat(x) + 0.5) / CGFloat(s) * 2 - 1
                    let fy = (CGFloat(y) + 0.5) / CGFloat(s) * 2 - 1
                    let r = sqrt(fx * fx + fy * fy)

                    let a: CGFloat
                    if r <= inner {
                        a = 1
                    } else if r >= 1 {
                        a = 0
                    } else {
                        let t = (r - inner) / max(0.0001, f)
                        a = 1 - smoothstep(t)
                    }

                    ptr[y * s + x] = UInt8((a * 255).rounded())
                }
            }
        }

        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            maskWidth: s,
            height: s,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: s,
            provider: provider,
            decode: nil,
            shouldInterpolate: false
        )
    }
}

