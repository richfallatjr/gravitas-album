import Foundation

public struct FaceEmbedding: Codable, Sendable, Hashable {
    public var data: Data
    public var elementCount: Int
    public var elementType: String

    public init(data: Data, elementCount: Int = 0, elementType: String = "vnfeatureprint") {
        self.data = data
        self.elementCount = max(0, elementCount)
        self.elementType = elementType.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FaceClusterNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var level: Int
    public var parentID: String?
    public var childIDs: [String]
    public var displayName: String?
    public var labelSource: ClusterLabelSource
    public var linkedContactID: String?
    public var representativeEmbeddings: [FaceEmbedding]
    public var updatedAt: Date

    public init(
        id: String,
        level: Int,
        parentID: String?,
        childIDs: [String],
        displayName: String? = nil,
        labelSource: ClusterLabelSource = .none,
        linkedContactID: String? = nil,
        representativeEmbeddings: [FaceEmbedding] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.level = max(0, level)
        let parent = parentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parentID = (parent?.isEmpty == false) ? parent : nil
        self.childIDs = childIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false) ? trimmedName : nil
        self.labelSource = labelSource
        let trimmedContact = linkedContactID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.linkedContactID = (trimmedContact?.isEmpty == false) ? trimmedContact : nil
        self.representativeEmbeddings = representativeEmbeddings
        self.updatedAt = updatedAt
    }

    public var hasDisplayName: Bool {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false
    }

    public var isManuallyLabeled: Bool {
        labelSource == .manual && hasDisplayName
    }

    public var isContactLabeled: Bool {
        labelSource == .contact && hasDisplayName
    }
}

public struct FaceHierarchySnapshot: Sendable, Hashable {
    public var rootID: String
    public var nodesByID: [String: FaceClusterNode]

    public init(rootID: String, nodesByID: [String: FaceClusterNode]) {
        self.rootID = rootID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nodesByID = nodesByID
    }

    public var maxLevel: Int {
        nodesByID.values.map(\.level).max() ?? 0
    }
}

public enum FaceHierarchyBuildStage: String, Sendable, Hashable {
    case idle
    case fetchingLeaves
    case mergingLevel
    case finalizing
    case done
}

public struct FaceHierarchyBuildProgress: Sendable, Hashable {
    public var stage: FaceHierarchyBuildStage
    public var totalLevels: Int
    public var level: Int?
    public var threshold: Float?
    public var processedPairs: Int64?
    public var totalPairs: Int64?
    public var unions: Int64?
    public var fractionComplete: Double
    public var startedAt: Date
    public var updatedAt: Date
    public var etaSeconds: Double?

    public init(
        stage: FaceHierarchyBuildStage,
        totalLevels: Int,
        level: Int? = nil,
        threshold: Float? = nil,
        processedPairs: Int64? = nil,
        totalPairs: Int64? = nil,
        unions: Int64? = nil,
        fractionComplete: Double,
        startedAt: Date,
        updatedAt: Date = Date(),
        etaSeconds: Double? = nil
    ) {
        self.stage = stage
        self.totalLevels = max(0, totalLevels)
        self.level = level
        self.threshold = threshold
        self.processedPairs = processedPairs
        self.totalPairs = totalPairs
        self.unions = unions
        self.fractionComplete = max(0, min(1, fractionComplete))
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.etaSeconds = etaSeconds
    }

    public var elapsedSeconds: Double {
        max(0, updatedAt.timeIntervalSince(startedAt))
    }
}

public extension Notification.Name {
    static let albumFaceHierarchyDidUpdate = Notification.Name("album.faceHierarchy.didUpdate")
}
