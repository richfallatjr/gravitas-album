import Foundation

public enum AlbumThumbFeedback: String, Sendable, Codable {
    case up = "UP"
    case down = "DOWN"
}

public struct AlbumThumbRequest: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let feedback: AlbumThumbFeedback
    public let assetID: String

    public init(assetID: String, feedback: AlbumThumbFeedback, id: UUID = UUID()) {
        self.id = id
        self.feedback = feedback
        self.assetID = assetID
    }
}

public struct AlbumRecNeighbor: Sendable, Decodable {
    public let id: String
    public let similarity: Double

    public init(id: String, similarity: Double) {
        self.id = id
        self.similarity = similarity
    }
}

public struct AlbumRecResponse: Sendable, Decodable {
    public let nextID: String?
    public let neighbors: [AlbumRecNeighbor]

    public init(nextID: String?, neighbors: [AlbumRecNeighbor]) {
        self.nextID = nextID
        self.neighbors = neighbors
    }
}

public struct AlbumRecOutcome: Sendable {
    public let response: AlbumRecResponse?
    public let errorDescription: String?

    public init(response: AlbumRecResponse?, errorDescription: String?) {
        self.response = response
        self.errorDescription = errorDescription
    }
}

public struct AlbumOracleCandidate: Sendable, Hashable {
    public let key: String
    public let assetID: String
    public let mediaType: AlbumMediaType
    public let createdYearMonth: String?
    public let locationBucket: String?
    public let visionSummary: String

    public init(key: String, assetID: String, mediaType: AlbumMediaType, createdYearMonth: String?, locationBucket: String?, visionSummary: String) {
        self.key = key
        self.assetID = assetID
        self.mediaType = mediaType
        self.createdYearMonth = createdYearMonth
        self.locationBucket = locationBucket
        self.visionSummary = visionSummary
    }
}

public struct AlbumOracleSnapshot: Sendable {
    public let thumbedAssetID: String
    public let thumbedMediaType: AlbumMediaType
    public let thumbedCreatedYearMonth: String?
    public let thumbedLocationBucket: String?
    public let thumbedVisionSummary: String
    public let candidates: [AlbumOracleCandidate]
    public let alreadySeenKeys: Set<String>

    public init(
        thumbedAssetID: String,
        thumbedMediaType: AlbumMediaType,
        thumbedCreatedYearMonth: String?,
        thumbedLocationBucket: String?,
        thumbedVisionSummary: String,
        candidates: [AlbumOracleCandidate],
        alreadySeenKeys: Set<String>
    ) {
        self.thumbedAssetID = thumbedAssetID
        self.thumbedMediaType = thumbedMediaType
        self.thumbedCreatedYearMonth = thumbedCreatedYearMonth
        self.thumbedLocationBucket = thumbedLocationBucket
        self.thumbedVisionSummary = thumbedVisionSummary
        self.candidates = candidates
        self.alreadySeenKeys = alreadySeenKeys
    }
}

public protocol AlbumOracle: Sendable {
    func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome
    func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome
}

