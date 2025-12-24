import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BubbleAnimatedAtlasGenerator {
    public static let frameCount: Int = 8
    public static let cols: Int = 4
    public static let rows: Int = 2
    public static let tilePx: Int = 512

    public static func generateAtlasPNG(videoURL: URL, destinationURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = max(0, duration.seconds.isFinite ? duration.seconds : 0)
        let spanSeconds = min(1.0, durationSeconds)

        let times: [CMTime] = (0..<frameCount).map { idx in
            let t: Double
            if frameCount <= 1 || spanSeconds <= 0 {
                t = 0
            } else {
                t = spanSeconds * Double(idx) / Double(frameCount - 1)
            }
            return CMTime(seconds: t, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)

        let extracted = try await generateFrames(generator: generator, requestedTimes: times)
        let frames = try fillFrames(extracted: extracted)

        try await Task.detached(priority: .utility) {
            let atlas = try renderAtlas(frames: frames)
            try writePNG(atlas, to: destinationURL)
        }.value
        return destinationURL
    }

    private static func generateFrames(
        generator: AVAssetImageGenerator,
        requestedTimes: [CMTime]
    ) async throws -> [CGImage?] {
        guard !requestedTimes.isEmpty else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var completed = 0
            var didResume = false
            var output = Array<CGImage?>(repeating: nil, count: requestedTimes.count)

            let timeValues = requestedTimes.map { NSValue(time: $0) }
            generator.generateCGImagesAsynchronously(forTimes: timeValues) { requestedTime, cgImage, _, _, error in
                lock.lock()
                defer { lock.unlock() }

                guard !didResume else { return }
                if let idx = requestedTimes.firstIndex(where: { $0 == requestedTime }) {
                    if let cgImage {
                        output[idx] = cgImage
                    } else if let error {
                        AlbumLog.immersive.error(
                            "BubbleAnimatedAtlasGenerator frame extract failed idx=\(idx, privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                    }
                }

                completed += 1
                if completed >= timeValues.count {
                    didResume = true
                    continuation.resume(returning: output)
                }
            }
        }
    }

    private static func fillFrames(extracted: [CGImage?]) throws -> [CGImage] {
        guard extracted.count == frameCount else {
            throw BubbleAnimatedAtlasGeneratorError.noFrames
        }

        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        var lastGood: CGImage?

        for img in extracted {
            if let img {
                frames.append(img)
                lastGood = img
            } else if let lastGood {
                frames.append(lastGood)
            }
        }

        if frames.count < frameCount, let last = frames.last {
            frames.append(contentsOf: Array(repeating: last, count: frameCount - frames.count))
        }

        guard frames.count == frameCount else {
            throw BubbleAnimatedAtlasGeneratorError.noFrames
        }
        return frames
    }

    private static func renderAtlas(frames: [CGImage]) throws -> CGImage {
        let atlasWidth = cols * tilePx
        let atlasHeight = rows * tilePx

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw BubbleAnimatedAtlasGeneratorError.renderFailed
        }

        ctx.interpolationQuality = .high

        for idx in 0..<frameCount {
            let row = idx / cols
            let col = idx % cols

            let x = col * tilePx
            let y = (rows - 1 - row) * tilePx // top-left origin layout on a bottom-left CGContext
            let rect = CGRect(x: x, y: y, width: tilePx, height: tilePx)
            drawAspectFill(source: frames[idx], in: ctx, rect: rect)
        }

        guard let out = ctx.makeImage() else {
            throw BubbleAnimatedAtlasGeneratorError.renderFailed
        }
        return out
    }

    private static func drawAspectFill(source: CGImage, in ctx: CGContext, rect: CGRect) {
        let srcW = max(1, source.width)
        let srcH = max(1, source.height)

        let scale = max(rect.width / Double(srcW), rect.height / Double(srcH))
        let scaledW = Double(srcW) * scale
        let scaledH = Double(srcH) * scale
        let dx = rect.origin.x + (rect.width - scaledW) / 2.0
        let dy = rect.origin.y + (rect.height - scaledH) / 2.0

        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.draw(source, in: CGRect(x: dx, y: dy, width: scaledW, height: scaledH))
        ctx.restoreGState()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BubbleAnimatedAtlasGeneratorError.pngEncodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BubbleAnimatedAtlasGeneratorError.pngEncodeFailed
        }
    }
}

private enum BubbleAnimatedAtlasGeneratorError: Error {
    case noFrames
    case renderFailed
    case pngEncodeFailed
}
