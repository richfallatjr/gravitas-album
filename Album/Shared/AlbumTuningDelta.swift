import Foundation

public struct AlbumItemTuningDelta: Sendable, Hashable {
    public let itemID: AlbumItemID
    public let massMultiplier: Float
    public let accelerationMultiplier: Float

    public init(itemID: AlbumItemID, massMultiplier: Float, accelerationMultiplier: Float) {
        self.itemID = itemID
        self.massMultiplier = massMultiplier
        self.accelerationMultiplier = accelerationMultiplier
    }
}

public struct AlbumTuningDeltaRequest: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let deltas: [AlbumItemTuningDelta]

    public init(id: UUID = UUID(), deltas: [AlbumItemTuningDelta]) {
        self.id = id
        self.deltas = deltas
    }
}

