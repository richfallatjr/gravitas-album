import Foundation

public struct AlbumPopOutPayload: Codable, Hashable {
    public let itemID: UUID

    public init(itemID: UUID) {
        self.itemID = itemID
    }
}
