import Foundation

public struct AlbumUserAlbum: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum AlbumQuery: Sendable, Hashable, Identifiable, Codable {
    case allPhotos
    case favorites
    case recents(days: Int)
    case year(Int)
    case day(year: Int, month: Int, day: Int)
    case userAlbum(AlbumUserAlbum)

    public var id: String {
        switch self {
        case .allPhotos:
            return "all_photos"
        case .favorites:
            return "favorites"
        case .recents(let days):
            return "recents_\(days)"
        case .year(let year):
            return "year_\(year)"
        case .day(let year, let month, let day):
            return String(format: "day_%04d_%02d_%02d", year, month, day)
        case .userAlbum(let album):
            return "album_\(album.id)"
        }
    }

    public var title: String {
        switch self {
        case .allPhotos:
            return "All Photos"
        case .favorites:
            return "Favorites"
        case .recents(let days):
            return "Recents (\(days)d)"
        case .year(let year):
            return "\(year)"
        case .day(let year, let month, let day):
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .userAlbum(let album):
            return album.title
        }
    }
}

