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

@MainActor
public protocol AlbumAssetProvider {
    func authorizationStatus() -> AlbumLibraryAuthorizationStatus
    func requestAuthorization() async -> AlbumLibraryAuthorizationStatus

    func fetchAssets(limit: Int, mode: AlbumSamplingMode) async throws -> [AlbumAsset]
    func fetchAssets(limit: Int, query: AlbumQuery) async throws -> [AlbumAsset]
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
            return try await fetchAssets(limit: limit, query: .allPhotos)
        }
    }

    func fetchUserAlbums() async throws -> [AlbumUserAlbum] { [] }
}
