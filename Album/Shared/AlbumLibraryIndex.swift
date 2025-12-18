import Foundation

#if canImport(Photos)
import Photos
#endif

public struct AlbumLibraryIndexSnapshot: Codable, Sendable, Hashable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var builtAt: Date
    public var assetCount: Int
    public var idsByCreationDateAscending: [String]

    public init(
        schemaVersion: Int = AlbumLibraryIndexSnapshot.currentSchemaVersion,
        builtAt: Date = Date(),
        assetCount: Int,
        idsByCreationDateAscending: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.builtAt = builtAt
        self.assetCount = assetCount
        self.idsByCreationDateAscending = idsByCreationDateAscending
    }
}

public struct AlbumLibraryIndex: Sendable {
    public let idsByCreationDateAscending: [String]
    private let idToIndex: [String: Int]

    public init(idsByCreationDateAscending: [String]) {
        self.idsByCreationDateAscending = idsByCreationDateAscending

        var map: [String: Int] = [:]
        map.reserveCapacity(idsByCreationDateAscending.count)

        for (idx, id) in idsByCreationDateAscending.enumerated() {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if map[trimmed] == nil {
                map[trimmed] = idx
            }
        }

        self.idToIndex = map
    }

    public func index(of assetID: String) -> Int? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return idToIndex[id]
    }

    public func neighbors(of assetID: String, radius: Int) -> [String] {
        let r = max(0, radius)
        guard r > 0 else { return [] }
        guard let center = index(of: assetID) else { return [] }
        guard !idsByCreationDateAscending.isEmpty else { return [] }

        let start = max(0, center - r)
        let end = min(idsByCreationDateAscending.count - 1, center + r)

        var out: [String] = []
        out.reserveCapacity((end - start) + 1)

        for idx in start...end {
            if idx == center { continue }
            let id = idsByCreationDateAscending[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            out.append(id)
        }

        return out
    }

    public func stratifiedSample(targetCount: Int) -> [String] {
        let target = max(0, targetCount)
        guard target > 0 else { return [] }
        let total = idsByCreationDateAscending.count
        guard total > 0 else { return [] }
        if total <= target { return idsByCreationDateAscending }

        let step = Double(total) / Double(target)
        let jitter = max(0, Int(step * 0.25))

        var selected: Set<Int> = []
        selected.reserveCapacity(target)

        for i in 0..<target {
            let base = Int(Double(i) * step)
            let offset = jitter > 0 ? Int.random(in: -jitter...jitter) : 0
            let idx = max(0, min(total - 1, base + offset))
            selected.insert(idx)
        }

        let sortedIndices = selected.sorted()
        return sortedIndices.map { idsByCreationDateAscending[$0] }
    }
}

public actor AlbumLibraryIndexStore {
    private let storeURL: URL
    private var cachedSnapshot: AlbumLibraryIndexSnapshot? = nil
    private var cachedIndex: AlbumLibraryIndex? = nil

    public init(fileName: String = "album_library_index_v1.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storeURL = appSupport.appendingPathComponent(fileName, isDirectory: false)
    }

    public func loadSnapshot() async -> AlbumLibraryIndexSnapshot? {
        if let cachedSnapshot { return cachedSnapshot }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(AlbumLibraryIndexSnapshot.self, from: data)
            cachedSnapshot = snapshot
            return snapshot
        } catch {
            print("[AlbumLibraryIndexStore] load error:", error)
            return nil
        }
    }

    public func loadIndex() async -> AlbumLibraryIndex? {
        if let cachedIndex { return cachedIndex }
        guard let snapshot = await loadSnapshot() else { return nil }
        let index = AlbumLibraryIndex(idsByCreationDateAscending: snapshot.idsByCreationDateAscending)
        cachedIndex = index
        return index
    }

    public func saveSnapshot(_ snapshot: AlbumLibraryIndexSnapshot) async {
        var normalized = snapshot
        normalized.schemaVersion = AlbumLibraryIndexSnapshot.currentSchemaVersion
        normalized.builtAt = Date()
        normalized.assetCount = normalized.idsByCreationDateAscending.count

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(normalized)
            try data.write(to: storeURL, options: [.atomic])
            cachedSnapshot = normalized
            cachedIndex = AlbumLibraryIndex(idsByCreationDateAscending: normalized.idsByCreationDateAscending)
        } catch {
            print("[AlbumLibraryIndexStore] save error:", error)
        }
    }

    public func buildIfNeeded() async -> AlbumLibraryIndex? {
        if let existing = await loadIndex() { return existing }
        let snapshot = await Self.buildSnapshotFromPhotos()
        guard let snapshot else { return nil }
        await saveSnapshot(snapshot)
        return await loadIndex()
    }

#if canImport(Photos)
    private static func buildSnapshotFromPhotos() async -> AlbumLibraryIndexSnapshot? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]

        let result = PHAsset.fetchAssets(with: options)
        var rows: [(date: Date?, id: String)] = []
        rows.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            rows.append((asset.creationDate, id))
        }

        rows.sort { a, b in
            let da = a.date ?? .distantPast
            let db = b.date ?? .distantPast
            if da != db { return da < db }
            return a.id < b.id
        }

        let ids = rows.map(\.id)
        return AlbumLibraryIndexSnapshot(assetCount: ids.count, idsByCreationDateAscending: ids)
    }
#else
    private static func buildSnapshotFromPhotos() async -> AlbumLibraryIndexSnapshot? { nil }
#endif
}
