import Foundation

public struct AlbumSidecar: Codable, Hashable {
    public var visionSummaryByLocalIdentifier: [String: String]
    public var thumbFeedbackByLocalIdentifier: [String: AlbumThumbFeedback]
    public var hiddenLocalIdentifiers: Set<String>
    public var updatedAt: Date

    public init(
        visionSummaryByLocalIdentifier: [String: String] = [:],
        thumbFeedbackByLocalIdentifier: [String: AlbumThumbFeedback] = [:],
        hiddenLocalIdentifiers: Set<String> = [],
        updatedAt: Date = Date()
    ) {
        self.visionSummaryByLocalIdentifier = visionSummaryByLocalIdentifier
        self.thumbFeedbackByLocalIdentifier = thumbFeedbackByLocalIdentifier
        self.hiddenLocalIdentifiers = hiddenLocalIdentifiers
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case visionSummaryByLocalIdentifier
        case thumbFeedbackByLocalIdentifier
        case hiddenLocalIdentifiers
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.visionSummaryByLocalIdentifier = try container.decodeIfPresent([String: String].self, forKey: .visionSummaryByLocalIdentifier) ?? [:]
        self.thumbFeedbackByLocalIdentifier = try container.decodeIfPresent([String: AlbumThumbFeedback].self, forKey: .thumbFeedbackByLocalIdentifier) ?? [:]
        self.hiddenLocalIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenLocalIdentifiers) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public final class AlbumSidecarStore {
    private let storeURL: URL

    public init(fileName: String = "album_sidecar.json") {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.storeURL = directory.appendingPathComponent(fileName)
    }

    public func load() -> AlbumSidecar {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return AlbumSidecar() }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AlbumSidecar.self, from: data)
        } catch {
            print("[AlbumSidecarStore] load error:", error)
            return AlbumSidecar()
        }
    }

    public func save(_ sidecar: AlbumSidecar) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sidecar)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            print("[AlbumSidecarStore] save error:", error)
        }
    }
}
