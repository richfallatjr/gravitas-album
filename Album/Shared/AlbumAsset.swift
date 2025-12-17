import Foundation

public enum AlbumMediaType: String, Sendable, Codable, CaseIterable {
    case photo
    case video
}

public struct AlbumLocation: Sendable, Codable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct AlbumAsset: Sendable, Identifiable, Codable, Hashable {
    public let id: String
    public let localIdentifier: String
    public let mediaType: AlbumMediaType
    public let creationDate: Date?
    public let location: AlbumLocation?
    public let duration: TimeInterval?
    public let isFavorite: Bool
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        localIdentifier: String,
        mediaType: AlbumMediaType,
        creationDate: Date?,
        location: AlbumLocation?,
        duration: TimeInterval?,
        isFavorite: Bool,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        let trimmed = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localIdentifier = trimmed
        self.id = trimmed
        self.mediaType = mediaType
        self.creationDate = creationDate
        self.location = location
        self.duration = duration
        self.isFavorite = isFavorite
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum AlbumSamplingMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case recent
    case favorites
    case random

    public var id: String { rawValue }
}

