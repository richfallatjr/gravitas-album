import Foundation

public struct AlbumPopOutPayload: Codable, Hashable {
    public let itemID: UUID

    public init(itemID: UUID) {
        self.itemID = itemID
    }
}

public struct AlbumSharePayload: Codable, Hashable {
    public let url: URL
    public let title: String?

    public init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title
    }
}
