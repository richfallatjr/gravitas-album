import Foundation
import CoreGraphics

public enum AlbumSceneItemKind: String, Sendable, Codable, Hashable, CaseIterable {
    case asset
    case movie
}

public struct AlbumMovieArtifactMetadata: Sendable, Codable, Hashable {
    public var durationSeconds: Double?
    public var fileSizeBytes: Int64?
    public var createdAt: Date?
    public var renderWidth: Int
    public var renderHeight: Int
    public var fps: Int

    public init(
        durationSeconds: Double? = nil,
        fileSizeBytes: Int64? = nil,
        createdAt: Date? = nil,
        renderWidth: Int,
        renderHeight: Int,
        fps: Int
    ) {
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.fps = fps
    }
}

public struct AlbumMovieRenderState: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case draft
        case rendering
        case ready
        case failed
    }

    public var kind: Kind
    public var progress: Double?
    public var message: String?

    public init(kind: Kind, progress: Double? = nil, message: String? = nil) {
        self.kind = kind
        self.progress = progress
        self.message = message
    }

    public static let draft = AlbumMovieRenderState(kind: .draft)
    public static func rendering(progress: Double) -> AlbumMovieRenderState {
        AlbumMovieRenderState(kind: .rendering, progress: progress)
    }
    public static let ready = AlbumMovieRenderState(kind: .ready)
    public static func failed(message: String) -> AlbumMovieRenderState {
        AlbumMovieRenderState(kind: .failed, message: message)
    }
}

public struct AlbumMovieDraft: Sendable, Codable, Hashable {
    public var draftTitle: String
    public var draftSubtitle: String?
    public var titleUserEdited: Bool
    public var renderState: AlbumMovieRenderState
    public var artifactRelativePath: String?
    public var artifactMetadata: AlbumMovieArtifactMetadata?

    public init(
        draftTitle: String = "",
        draftSubtitle: String? = nil,
        titleUserEdited: Bool = false,
        renderState: AlbumMovieRenderState = .draft,
        artifactRelativePath: String? = nil,
        artifactMetadata: AlbumMovieArtifactMetadata? = nil
    ) {
        self.draftTitle = draftTitle
        self.draftSubtitle = draftSubtitle
        self.titleUserEdited = titleUserEdited
        self.renderState = renderState
        self.artifactRelativePath = artifactRelativePath
        self.artifactMetadata = artifactMetadata
    }
}

public struct AlbumSceneItemRecord: Identifiable, Sendable, Codable, Hashable {
    public var id: UUID
    public var kind: AlbumSceneItemKind

    // Asset items
    public var assetID: String?
    public var kenBurnsStartAnchor: CGPoint?
    public var kenBurnsEndAnchor: CGPoint?
    public var kenBurnsUserDefined: Bool
    public var trimStartSeconds: Double?
    public var trimEndSeconds: Double?

    // Movie items
    public var movie: AlbumMovieDraft?

    // Spatial sorting hint (best-effort; updated at runtime)
    public var lastKnownWindowMidX: Double?

    public init(
        id: UUID = UUID(),
        kind: AlbumSceneItemKind,
        assetID: String? = nil,
        kenBurnsStartAnchor: CGPoint? = nil,
        kenBurnsEndAnchor: CGPoint? = nil,
        kenBurnsUserDefined: Bool = false,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        movie: AlbumMovieDraft? = nil,
        lastKnownWindowMidX: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.assetID = assetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kenBurnsStartAnchor = kenBurnsStartAnchor
        self.kenBurnsEndAnchor = kenBurnsEndAnchor
        self.kenBurnsUserDefined = kenBurnsUserDefined
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.movie = movie
        self.lastKnownWindowMidX = lastKnownWindowMidX
    }

    public static func asset(id: UUID = UUID(), assetID: String) -> AlbumSceneItemRecord {
        AlbumSceneItemRecord(id: id, kind: .asset, assetID: assetID)
    }

    public static func movie(id: UUID = UUID(), draft: AlbumMovieDraft = AlbumMovieDraft()) -> AlbumSceneItemRecord {
        AlbumSceneItemRecord(id: id, kind: .movie, movie: draft)
    }
}

public struct AlbumSceneRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var items: [AlbumSceneItemRecord]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, items: [AlbumSceneItemRecord], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case items
        case createdAt

        // legacy v1
        case assetIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Scene"
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()

        if let decoded = try container.decodeIfPresent([AlbumSceneItemRecord].self, forKey: .items) {
            self.items = decoded
        } else if let legacyAssetIDs = try container.decodeIfPresent([String].self, forKey: .assetIDs) {
            self.items = legacyAssetIDs.map { AlbumSceneItemRecord.asset(assetID: $0) }
        } else {
            self.items = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(items, forKey: .items)
    }
}

public enum AlbumSceneStore {
    private static var storeURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("album_scenes.json")
    }

    public static func load() -> [AlbumSceneRecord] {
        let url = storeURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AlbumSceneRecord].self, from: data)
        } catch {
            print("[AlbumSceneStore] load error:", error)
            return []
        }
    }

    public static func save(_ scenes: [AlbumSceneRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(scenes)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            print("[AlbumSceneStore] save error:", error)
        }
    }
}
