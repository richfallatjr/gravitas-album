import Foundation

public struct AlbumSceneRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var assetIDs: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, assetIDs: [String], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.assetIDs = assetIDs
        self.createdAt = createdAt
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
