import Foundation

public enum AlbumPanelMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case recommends
    case memories

    public var id: String { rawValue }
}

