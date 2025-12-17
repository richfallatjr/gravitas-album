import Foundation

public enum AlbumCurvedLayoutMode: String, Sendable {
    case recommends
    case memories
}

public enum AlbumCurvedLayoutThumbFeedback: String, Sendable {
    case up
    case down
}

public struct AlbumCurvedLayoutItem: Identifiable, Hashable, Sendable {
    public typealias ID = String

    public let id: ID
    public var title: String?
    public var subtitle: String?
    public var isVideo: Bool
    public var duration: TimeInterval?

    public init(
        id: ID,
        title: String? = nil,
        subtitle: String? = nil,
        isVideo: Bool = false,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isVideo = isVideo
        self.duration = duration
    }
}

