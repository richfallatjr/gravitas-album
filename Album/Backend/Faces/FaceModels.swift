import Foundation

public enum FaceProcessingState: String, Codable, Sendable, CaseIterable {
    case none
    case computed
    case failed
}

public struct FaceCluster: Codable, Hashable, Sendable, Identifiable {
    public let faceID: String
    public var referencePrints: [Data]
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { faceID }

    public init(faceID: String, referencePrints: [Data], createdAt: Date, updatedAt: Date) {
        self.faceID = faceID
        self.referencePrints = referencePrints
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct FaceMatchResult: Hashable, Sendable {
    public let faceID: String
    public let distance: Float

    public init(faceID: String, distance: Float) {
        self.faceID = faceID
        self.distance = distance
    }
}

public struct FaceBucketSummary: Hashable, Sendable, Identifiable {
    public let faceID: String
    public let assetCount: Int

    public var id: String { faceID }

    public init(faceID: String, assetCount: Int) {
        self.faceID = faceID
        self.assetCount = assetCount
    }
}

public extension Notification.Name {
    static let albumFaceIndexDidUpdate = Notification.Name("album.faceIndex.didUpdate")
}

