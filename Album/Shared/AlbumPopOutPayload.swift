import Foundation

public struct AlbumPopOutPayload: Codable, Hashable {
    public let assetID: String

    public init(assetID: String) {
        self.assetID = assetID
    }
}

