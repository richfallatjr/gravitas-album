import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
public typealias AlbumImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias AlbumImage = NSImage
#endif

public enum AlbumLibraryAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case limited
    case authorized
}

public enum AlbumAssetSampling: String, Sendable, Codable, CaseIterable, Identifiable {
    case recent
    case random

    public var id: String { rawValue }
}

@MainActor
public protocol AlbumAssetProvider {
    func authorizationStatus() -> AlbumLibraryAuthorizationStatus
    func requestAuthorization() async -> AlbumLibraryAuthorizationStatus

    func fetchAssets(limit: Int, mode: AlbumSamplingMode) async throws -> [AlbumAsset]
    func fetchAssets(limit: Int, query: AlbumQuery) async throws -> [AlbumAsset]
    func fetchAssets(limit: Int, query: AlbumQuery, sampling: AlbumAssetSampling) async throws -> [AlbumAsset]
    func fetchAssets(localIdentifiers: [String]) async throws -> [AlbumAsset]
    func fetchUserAlbums() async throws -> [AlbumUserAlbum]

    func requestThumbnail(localIdentifier: String, targetSize: CGSize) async -> AlbumImage?
    func requestVideoURL(localIdentifier: String) async -> URL?
}

public extension AlbumAssetProvider {
    func fetchAssets(limit: Int, mode: AlbumSamplingMode) async throws -> [AlbumAsset] {
        switch mode {
        case .recent:
            return try await fetchAssets(limit: limit, query: .allPhotos)
        case .favorites:
            return try await fetchAssets(limit: limit, query: .favorites)
        case .random:
            return try await fetchAssets(limit: limit, query: .allPhotos, sampling: .random)
        }
    }

    func fetchAssets(limit: Int, query: AlbumQuery, sampling: AlbumAssetSampling) async throws -> [AlbumAsset] {
        switch sampling {
        case .recent:
            return try await fetchAssets(limit: limit, query: query)
        case .random:
            let cappedLimit = max(0, limit)
            let all = try await fetchAssets(limit: 0, query: query)
            guard cappedLimit > 0, all.count > cappedLimit else { return all }
            return Array(all.shuffled().prefix(cappedLimit))
        }
    }

    func fetchUserAlbums() async throws -> [AlbumUserAlbum] { [] }

    func fetchAssets(localIdentifiers: [String]) async throws -> [AlbumAsset] { [] }
}
