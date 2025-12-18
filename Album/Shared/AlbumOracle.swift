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

    private enum CodingKeys: String, CodingKey {
        case id
        case similarity
    }

    private static func decodeStringOrInt(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let s = try? container.decode(String.self, forKey: key) {
            return s
        }
        if let i = try? container.decode(Int.self, forKey: key) {
            return String(i)
        }
        if let d = try? container.decode(Double.self, forKey: key) {
            if d.rounded() == d { return String(Int(d)) }
            return String(d)
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.decodeStringOrInt(container: container, key: .id) ?? ""

        if let value = try? container.decode(Double.self, forKey: .similarity) {
            similarity = value
        } else if let value = try? container.decode(Float.self, forKey: .similarity) {
            similarity = Double(value)
        } else if let value = try? container.decode(Int.self, forKey: .similarity) {
            similarity = Double(value)
        } else if let raw = try? container.decode(String.self, forKey: .similarity),
                  let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            similarity = value
        } else {
            similarity = 0
        }
    }
}

public struct AlbumRecResponse: Sendable, Decodable {
    public let nextID: String?
    public let neighbors: [AlbumRecNeighbor]

    public init(nextID: String?, neighbors: [AlbumRecNeighbor]) {
        self.nextID = nextID
        self.neighbors = neighbors
    }

    private enum CodingKeys: String, CodingKey {
        case nextID
        case neighbors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let nextString = try? container.decode(String.self, forKey: .nextID) {
            nextID = nextString
        } else if let nextInt = try? container.decode(Int.self, forKey: .nextID) {
            nextID = String(nextInt)
        } else if let nextDouble = try? container.decode(Double.self, forKey: .nextID) {
            if nextDouble.rounded() == nextDouble {
                nextID = String(Int(nextDouble))
            } else {
                nextID = String(nextDouble)
            }
        } else {
            nextID = nil
        }

        neighbors = (try? container.decode([AlbumRecNeighbor].self, forKey: .neighbors)) ?? []
    }
}

public enum AlbumOracleBackend: String, Sendable {
    case foundationModels = "FoundationModels"
    case heuristic = "Heuristic"
}

public struct AlbumRecOutcome: Sendable {
    public let backend: AlbumOracleBackend
    public let response: AlbumRecResponse?
    public let errorDescription: String?
    public let note: String?

    public init(backend: AlbumOracleBackend, response: AlbumRecResponse?, errorDescription: String?, note: String? = nil) {
        self.backend = backend
        self.response = response
        self.errorDescription = errorDescription
        self.note = note
    }
}

public struct AlbumOracleCandidate: Sendable, Hashable {
    public let assetID: String
    public let promptID: String
    public let fileName: String
    public let visionSummary: String
    public let mediaType: AlbumMediaType
    public let createdYearMonth: String?
    public let locationBucket: String?

    public init(
        assetID: String,
        promptID: String,
        fileName: String,
        visionSummary: String,
        mediaType: AlbumMediaType,
        createdYearMonth: String?,
        locationBucket: String?
    ) {
        self.assetID = assetID
        self.promptID = promptID
        self.fileName = fileName
        self.visionSummary = visionSummary
        self.mediaType = mediaType
        self.createdYearMonth = createdYearMonth
        self.locationBucket = locationBucket
    }
}

public struct AlbumOracleSnapshot: Sendable {
    public let thumbedAssetID: String
    public let thumbedFileName: String
    public let thumbedMediaType: AlbumMediaType
    public let thumbedCreatedYearMonth: String?
    public let thumbedLocationBucket: String?
    public let thumbedVisionSummary: String
    public let candidates: [AlbumOracleCandidate]
    public let alreadySeenAssetIDs: Set<String>

    public init(
        thumbedAssetID: String,
        thumbedFileName: String,
        thumbedMediaType: AlbumMediaType,
        thumbedCreatedYearMonth: String?,
        thumbedLocationBucket: String?,
        thumbedVisionSummary: String,
        candidates: [AlbumOracleCandidate],
        alreadySeenAssetIDs: Set<String>
    ) {
        self.thumbedAssetID = thumbedAssetID
        self.thumbedFileName = thumbedFileName
        self.thumbedMediaType = thumbedMediaType
        self.thumbedCreatedYearMonth = thumbedCreatedYearMonth
        self.thumbedLocationBucket = thumbedLocationBucket
        self.thumbedVisionSummary = thumbedVisionSummary
        self.candidates = candidates
        self.alreadySeenAssetIDs = alreadySeenAssetIDs
    }
}

public protocol AlbumOracle: Sendable {
    func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome
    func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome
}
