import Foundation

public enum FaceProcessingState: String, Codable, Sendable, CaseIterable {
    case none
    case computed
    case failed
}

public enum ClusterLabelSource: String, Codable, Sendable, CaseIterable {
    case none
    case contact
    case manual
}

public struct FaceCluster: Codable, Hashable, Sendable, Identifiable {
    public let faceID: String
    public var displayName: String?
    public var labelSource: ClusterLabelSource
    public var linkedContactID: String?
    public var referencePrints: [Data]
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { faceID }

    public init(
        faceID: String,
        displayName: String? = nil,
        labelSource: ClusterLabelSource = .none,
        linkedContactID: String? = nil,
        referencePrints: [Data],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.faceID = faceID
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.labelSource = labelSource
        self.linkedContactID = linkedContactID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.referencePrints = referencePrints
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case faceID
        case displayName
        case labelSource
        case linkedContactID
        case referencePrints
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        faceID = try container.decode(String.self, forKey: .faceID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        labelSource = try container.decodeIfPresent(ClusterLabelSource.self, forKey: .labelSource) ?? .none
        linkedContactID = try container.decodeIfPresent(String.self, forKey: .linkedContactID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        referencePrints = try container.decodeIfPresent([Data].self, forKey: .referencePrints) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(faceID, forKey: .faceID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(labelSource, forKey: .labelSource)
        try container.encode(linkedContactID, forKey: .linkedContactID)
        try container.encode(referencePrints, forKey: .referencePrints)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var preferredDisplayName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch labelSource {
        case .manual:
            if let trimmed, !trimmed.isEmpty { return trimmed }
        case .contact:
            if let trimmed, !trimmed.isEmpty { return trimmed }
        case .none:
            break
        }
        return faceID
    }

    public var hasUserVisibleLabel: Bool {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return false }
        return labelSource == .manual || labelSource == .contact
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

public struct FaceBucketPreviewSummary: Hashable, Sendable, Identifiable {
    public let faceID: String
    public let assetCount: Int
    public let sampleAssetIDs: [String]

    public var id: String { faceID }

    public init(faceID: String, assetCount: Int, sampleAssetIDs: [String]) {
        self.faceID = faceID
        self.assetCount = assetCount
        self.sampleAssetIDs = sampleAssetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct FaceClusterDirectoryEntry: Hashable, Sendable, Identifiable {
    public let faceID: String
    public let displayName: String
    public let rawDisplayName: String?
    public let labelSource: ClusterLabelSource
    public let linkedContactID: String?
    public let assetCount: Int

    public var id: String { faceID }

    public init(
        faceID: String,
        displayName: String,
        rawDisplayName: String?,
        labelSource: ClusterLabelSource,
        linkedContactID: String?,
        assetCount: Int
    ) {
        self.faceID = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawDisplayName = rawDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.labelSource = labelSource
        self.linkedContactID = linkedContactID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assetCount = max(0, assetCount)
    }

    public var isLabeled: Bool {
        let trimmed = rawDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return false }
        return labelSource == .manual || labelSource == .contact
    }
}

public struct FacePromptTokenInfo: Hashable, Sendable {
    public let token: String
    public let isLabeled: Bool

    public init(token: String, isLabeled: Bool) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isLabeled = isLabeled
    }
}

public extension Notification.Name {
    static let albumFaceIndexDidUpdate = Notification.Name("album.faceIndex.didUpdate")
}
