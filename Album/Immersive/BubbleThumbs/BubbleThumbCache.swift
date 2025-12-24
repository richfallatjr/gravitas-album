import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers

public enum BubbleThumbCache {
    public static let version: Int = 1

    private static let thumbDimension: Int = 512
    private static let baseDirectoryName: String = "gravitas_bubbles"

    private struct Sidecar: Codable {
        var itemID: String
        var thumb512Path: String
        var version: Int
        var updatedAt: Date
    }

    public static func getOrCreateThumbTexture(
        itemID: String,
        sourceImage: () async throws -> CGImage
    ) async throws -> TextureResource {
        let resolved = try await getOrCreateThumbURL(itemID: itemID, sourceImage: sourceImage)

        do {
            return try TextureResource.load(contentsOf: resolved)
        } catch {
            AlbumLog.immersive.error(
                "BubbleThumbCache TextureResource.load failed itemID=\(itemID, privacy: .public) url=\(resolved.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private static func getOrCreateThumbURL(
        itemID: String,
        sourceImage: () async throws -> CGImage
    ) async throws -> URL {
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw BubbleThumbCacheError.invalidItemID }

        let hash = sha256Hex(id)
        let baseURL = try cacheBaseURL()
        let thumbsDir = baseURL.appendingPathComponent("thumbs", isDirectory: true)
        let sidecarsDir = baseURL.appendingPathComponent("sidecars", isDirectory: true)
        try ensureDirectory(thumbsDir)
        try ensureDirectory(sidecarsDir)

        let thumbFileName = "\(hash)_\(thumbDimension).png"
        let defaultThumbURL = thumbsDir.appendingPathComponent(thumbFileName, isDirectory: false)
        let sidecarURL = sidecarsDir.appendingPathComponent("\(hash).json", isDirectory: false)

        if let existing = try? loadSidecar(from: sidecarURL) {
            let resolved = resolveThumbURL(sidecarPath: existing.thumb512Path, baseURL: baseURL)
            if FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }

        if FileManager.default.fileExists(atPath: defaultThumbURL.path) {
            try writeSidecar(
                itemID: id,
                thumbRelativePath: "thumbs/\(thumbFileName)",
                sidecarURL: sidecarURL
            )
            return defaultThumbURL
        }

        let source = try await sourceImage()
        let thumb = try renderThumbnail512(from: source)
        try writePNG(thumb, to: defaultThumbURL)
        try writeSidecar(
            itemID: id,
            thumbRelativePath: "thumbs/\(thumbFileName)",
            sidecarURL: sidecarURL
        )

        return defaultThumbURL
    }

    private static func cacheBaseURL() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let caches else { throw BubbleThumbCacheError.cachesUnavailable }
        return caches.appendingPathComponent(baseDirectoryName, isDirectory: true)
    }

    private static func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func loadSidecar(from url: URL) throws -> Sidecar {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Sidecar.self, from: data)
    }

    private static func resolveThumbURL(sidecarPath: String, baseURL: URL) -> URL {
        let trimmed = sidecarPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseURL }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: false)
        }
        return baseURL.appendingPathComponent(trimmed, isDirectory: false)
    }

    private static func writeSidecar(itemID: String, thumbRelativePath: String, sidecarURL: URL) throws {
        let sidecar = Sidecar(
            itemID: itemID,
            thumb512Path: thumbRelativePath,
            version: version,
            updatedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: sidecarURL, options: [.atomic])
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BubbleThumbCacheError.pngEncodeFailed
        }

        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BubbleThumbCacheError.pngEncodeFailed
        }
    }

    private static func renderThumbnail512(from source: CGImage) throws -> CGImage {
        let size = thumbDimension
        let width = size
        let height = size

        guard width > 0, height > 0 else { throw BubbleThumbCacheError.renderFailed }

        let srcW = max(1, source.width)
        let srcH = max(1, source.height)

        let scale = max(Double(width) / Double(srcW), Double(height) / Double(srcH))
        let scaledW = Double(srcW) * scale
        let scaledH = Double(srcH) * scale
        let dx = (Double(width) - scaledW) / 2.0
        let dy = (Double(height) - scaledH) / 2.0

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw BubbleThumbCacheError.renderFailed
        }

        ctx.interpolationQuality = .high
        ctx.draw(
            source,
            in: CGRect(x: dx, y: dy, width: scaledW, height: scaledH)
        )

        guard let out = ctx.makeImage() else { throw BubbleThumbCacheError.renderFailed }
        return out
    }

    private static func sha256Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum BubbleThumbCacheError: Error {
    case invalidItemID
    case cachesUnavailable
    case pngEncodeFailed
    case renderFailed
}
