import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers

public enum BubbleMediaSource {
    case photo(source: () async throws -> CGImage)
    case video(source: () async throws -> URL)
}

public struct AtlasConfig: Sendable, Hashable {
    public let frameCount: Int
    public let cols: Int
    public let rows: Int
    public let tilePx: Int
    public let fps: Float

    public init(frameCount: Int, cols: Int, rows: Int, tilePx: Int, fps: Float) {
        self.frameCount = frameCount
        self.cols = cols
        self.rows = rows
        self.tilePx = tilePx
        self.fps = fps
    }
}

public enum BubbleMediaCache {
    private static let cacheVersion: Int = 1

    private static let staticThumbPx: Int = 512
    private static let atlasFrameCount: Int = 8
    private static let atlasCols: Int = 4
    private static let atlasRows: Int = 2
    private static let atlasTilePx: Int = 512
    private static let atlasFPS: Float = 8

    private static let baseDirectoryName: String = "gravitas_bubbles"

    public struct AnimatedAtlasResult: Sendable {
        public let texture: TextureResource
        public let cfg: AtlasConfig
    }

    public static func getOrCreateStaticThumbTexture(
        itemID: String,
        photoSource: () async throws -> CGImage
    ) async throws -> TextureResource {
        let resolved = try await getOrCreateStaticThumbURL(itemID: itemID, photoSource: photoSource)
        do {
            return try TextureResource.load(contentsOf: resolved)
        } catch {
            AlbumLog.immersive.error(
                "BubbleMediaCache static thumb load failed itemID=\(itemID, privacy: .public) url=\(resolved.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            try? FileManager.default.removeItem(at: resolved)
            let regenerated = try await getOrCreateStaticThumbURL(itemID: itemID, photoSource: photoSource)
            return try TextureResource.load(contentsOf: regenerated)
        }
    }

    public static func getOrCreateAnimatedAtlasTexture(
        itemID: String,
        videoSource: () async throws -> URL
    ) async throws -> AnimatedAtlasResult {
        let resolved = try await getOrCreateAnimatedAtlasURL(itemID: itemID, videoSource: videoSource)
        do {
            let tex = try TextureResource.load(contentsOf: resolved.atlasURL)
            return AnimatedAtlasResult(texture: tex, cfg: resolved.cfg)
        } catch {
            AlbumLog.immersive.error(
                "BubbleMediaCache atlas load failed itemID=\(itemID, privacy: .public) url=\(resolved.atlasURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            try? FileManager.default.removeItem(at: resolved.atlasURL)
            let regenerated = try await getOrCreateAnimatedAtlasURL(itemID: itemID, videoSource: videoSource)
            let tex = try TextureResource.load(contentsOf: regenerated.atlasURL)
            return AnimatedAtlasResult(texture: tex, cfg: regenerated.cfg)
        }
    }

    private struct AnimatedAtlasResolved {
        var atlasURL: URL
        var cfg: AtlasConfig
    }

    private static func getOrCreateStaticThumbURL(
        itemID: String,
        photoSource: () async throws -> CGImage
    ) async throws -> URL {
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw BubbleMediaCacheError.invalidItemID }

        let hash = sha256Hex(id)
        let baseURL = try cacheBaseURL()
        let thumbsDir = baseURL.appendingPathComponent("thumbs", isDirectory: true)
        let sidecarsDir = baseURL.appendingPathComponent("sidecars", isDirectory: true)
        try ensureDirectory(thumbsDir)
        try ensureDirectory(sidecarsDir)

        let thumbFileName = "\(hash)_\(staticThumbPx).png"
        let thumbRelativePath = "thumbs/\(thumbFileName)"
        let thumbURL = thumbsDir.appendingPathComponent(thumbFileName, isDirectory: false)
        let sidecarURL = sidecarsDir.appendingPathComponent("\(hash).json", isDirectory: false)

        if let sidecar = try? loadSidecar(from: sidecarURL),
           sidecar.version == cacheVersion,
           let entry = sidecar.staticThumb {
            let resolved = resolveURL(sidecarPath: entry.path512, baseURL: baseURL)
            if FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }

        if FileManager.default.fileExists(atPath: thumbURL.path) {
            try writeSidecar(
                itemID: id,
                staticThumbRelativePath: thumbRelativePath,
                animatedAtlas: nil,
                to: sidecarURL
            )
            return thumbURL
        }

        let source = try await photoSource()
        let thumb = try await renderSquareThumbnail(source: source, sizePx: staticThumbPx)
        try writePNG(thumb, to: thumbURL)
        try writeSidecar(
            itemID: id,
            staticThumbRelativePath: thumbRelativePath,
            animatedAtlas: nil,
            to: sidecarURL
        )
        return thumbURL
    }

    private static func getOrCreateAnimatedAtlasURL(
        itemID: String,
        videoSource: () async throws -> URL
    ) async throws -> AnimatedAtlasResolved {
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw BubbleMediaCacheError.invalidItemID }

        let hash = sha256Hex(id)
        let baseURL = try cacheBaseURL()
        let atlasDir = baseURL.appendingPathComponent("atlas", isDirectory: true)
        let sidecarsDir = baseURL.appendingPathComponent("sidecars", isDirectory: true)
        try ensureDirectory(atlasDir)
        try ensureDirectory(sidecarsDir)

        let atlasFileName = "\(hash)_8f_4x2_512.png"
        let atlasRelativePath = "atlas/\(atlasFileName)"
        let atlasURL = atlasDir.appendingPathComponent(atlasFileName, isDirectory: false)
        let sidecarURL = sidecarsDir.appendingPathComponent("\(hash).json", isDirectory: false)

        let cfg = AtlasConfig(
            frameCount: atlasFrameCount,
            cols: atlasCols,
            rows: atlasRows,
            tilePx: atlasTilePx,
            fps: atlasFPS
        )

        if let sidecar = try? loadSidecar(from: sidecarURL),
           sidecar.version == cacheVersion,
           let entry = sidecar.animatedAtlas,
           entry.frameCount == cfg.frameCount,
           entry.cols == cfg.cols,
           entry.rows == cfg.rows,
           entry.tilePx == cfg.tilePx {
            let resolved = resolveURL(sidecarPath: entry.path, baseURL: baseURL)
            if FileManager.default.fileExists(atPath: resolved.path) {
                return AnimatedAtlasResolved(atlasURL: resolved, cfg: cfg)
            }
        }

        if FileManager.default.fileExists(atPath: atlasURL.path) {
            try writeSidecar(
                itemID: id,
                staticThumbRelativePath: nil,
                animatedAtlas: Sidecar.AnimatedAtlas(
                    path: atlasRelativePath,
                    frameCount: cfg.frameCount,
                    cols: cfg.cols,
                    rows: cfg.rows,
                    tilePx: cfg.tilePx,
                    fps: cfg.fps
                ),
                to: sidecarURL
            )
            return AnimatedAtlasResolved(atlasURL: atlasURL, cfg: cfg)
        }

        let videoURL = try await videoSource()
        _ = try await BubbleAnimatedAtlasGenerator.generateAtlasPNG(videoURL: videoURL, destinationURL: atlasURL)

        try writeSidecar(
            itemID: id,
            staticThumbRelativePath: nil,
            animatedAtlas: Sidecar.AnimatedAtlas(
                path: atlasRelativePath,
                frameCount: cfg.frameCount,
                cols: cfg.cols,
                rows: cfg.rows,
                tilePx: cfg.tilePx,
                fps: cfg.fps
            ),
            to: sidecarURL
        )

        return AnimatedAtlasResolved(atlasURL: atlasURL, cfg: cfg)
    }

    private static func cacheBaseURL() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let caches else { throw BubbleMediaCacheError.cachesUnavailable }
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

    private static func resolveURL(sidecarPath: String, baseURL: URL) -> URL {
        let trimmed = sidecarPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseURL }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: false)
        }
        return baseURL.appendingPathComponent(trimmed, isDirectory: false)
    }

    private static func writeSidecar(
        itemID: String,
        staticThumbRelativePath: String?,
        animatedAtlas: Sidecar.AnimatedAtlas?,
        to url: URL
    ) throws {
        var sidecar = Sidecar(
            version: cacheVersion,
            itemID: itemID,
            updatedAt: Date(),
            staticThumb: nil,
            animatedAtlas: nil
        )

        if let staticThumbRelativePath {
            sidecar.staticThumb = Sidecar.StaticThumb(path512: staticThumbRelativePath)
        }
        if let animatedAtlas {
            sidecar.animatedAtlas = animatedAtlas
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: url, options: [.atomic])
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BubbleMediaCacheError.pngEncodeFailed
        }

        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BubbleMediaCacheError.pngEncodeFailed
        }
    }

    private static func renderSquareThumbnail(source: CGImage, sizePx: Int) async throws -> CGImage {
        try await Task.detached(priority: .utility) {
            try renderSquareThumbnailSync(source: source, sizePx: sizePx)
        }.value
    }

    private static func renderSquareThumbnailSync(source: CGImage, sizePx: Int) throws -> CGImage {
        let size = max(1, sizePx)
        let width = size
        let height = size

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
            throw BubbleMediaCacheError.renderFailed
        }

        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: dx, y: dy, width: scaledW, height: scaledH))

        guard let out = ctx.makeImage() else { throw BubbleMediaCacheError.renderFailed }
        return out
    }

    private static func sha256Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct Sidecar: Codable, Sendable {
        var version: Int
        var itemID: String
        var updatedAt: Date
        var staticThumb: StaticThumb?
        var animatedAtlas: AnimatedAtlas?

        struct StaticThumb: Codable, Sendable {
            var path512: String
        }

        struct AnimatedAtlas: Codable, Sendable {
            var path: String
            var frameCount: Int
            var cols: Int
            var rows: Int
            var tilePx: Int
            var fps: Float
        }
    }
}

private enum BubbleMediaCacheError: Error {
    case invalidItemID
    case cachesUnavailable
    case pngEncodeFailed
    case renderFailed
}
