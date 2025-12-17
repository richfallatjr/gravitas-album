import Foundation
import CoreGraphics
import CoreLocation
import Photos
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class PhotosAlbumAssetProvider: AlbumAssetProvider {
    public init() {}

    public func authorizationStatus() -> AlbumLibraryAuthorizationStatus {
        mapAuthorizationStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> AlbumLibraryAuthorizationStatus {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
        return mapAuthorizationStatus(status)
    }

    public func fetchAssets(limit: Int, mode: AlbumSamplingMode) async throws -> [AlbumAsset] {
        if mode != .random {
            return try await fetchAssets(limit: limit, query: mode == .favorites ? .favorites : .allPhotos)
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: fetchOptions)
        let phAssets = randomSample(from: result, limit: limit)
        return mapAlbumAssets(phAssets)
    }

    public func fetchAssets(limit: Int, query: AlbumQuery) async throws -> [AlbumAsset] {
        try await fetchAssets(limit: limit, query: query, sampling: .recent)
    }

    public func fetchAssets(limit: Int, query: AlbumQuery, sampling: AlbumAssetSampling) async throws -> [AlbumAsset] {
        let cappedLimit = max(0, limit)

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        if sampling == .recent {
            fetchOptions.fetchLimit = cappedLimit
        } else {
            fetchOptions.fetchLimit = 0
        }

        let result: PHFetchResult<PHAsset>
        switch query {
        case .allPhotos:
            result = PHAsset.fetchAssets(with: fetchOptions)

        case .favorites:
            fetchOptions.predicate = NSPredicate(format: "favorite == YES")
            result = PHAsset.fetchAssets(with: fetchOptions)

        case .recents(let days):
            if days > 0, let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) {
                fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
            }
            result = PHAsset.fetchAssets(with: fetchOptions)

        case .year(let year):
            let cal = Calendar(identifier: .gregorian)
            let startComps = DateComponents(year: year, month: 1, day: 1)
            let endComps = DateComponents(year: year + 1, month: 1, day: 1)
            if let start = cal.date(from: startComps), let end = cal.date(from: endComps) {
                fetchOptions.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
            }
            result = PHAsset.fetchAssets(with: fetchOptions)

        case .day(let year, let month, let day):
            let cal = Calendar(identifier: .gregorian)
            let startComps = DateComponents(year: year, month: month, day: day)
            if let start = cal.date(from: startComps), let end = cal.date(byAdding: .day, value: 1, to: start) {
                fetchOptions.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
            }
            result = PHAsset.fetchAssets(with: fetchOptions)

        case .userAlbum(let album):
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil)
            guard let collection = collections.firstObject else { return [] }
            result = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        }

        let phAssets: [PHAsset]
        switch sampling {
        case .random:
            phAssets = randomSample(from: result, limit: cappedLimit)
        case .recent:
            var out: [PHAsset] = []
            out.reserveCapacity(min(result.count, cappedLimit))
            result.enumerateObjects { asset, _, stop in
                out.append(asset)
                if cappedLimit > 0, out.count >= cappedLimit {
                    stop.pointee = true
                }
            }
            phAssets = out
        }

        return mapAlbumAssets(phAssets)
    }

    public func fetchUserAlbums() async throws -> [AlbumUserAlbum] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]

        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        var out: [AlbumUserAlbum] = []
        out.reserveCapacity(collections.count)

        collections.enumerateObjects { collection, _, _ in
            let title = (collection.localizedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            out.append(AlbumUserAlbum(id: collection.localIdentifier, title: title))
        }

        return out
    }

    public func requestThumbnail(localIdentifier: String, targetSize: CGSize) async -> AlbumImage? {
        let id = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let pixelTargetSize = CGSize(width: max(1, targetSize.width), height: max(1, targetSize.height))

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: pixelTargetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !didResume else { return }

                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? NSError
                if cancelled || error != nil {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded {
                    return
                }

                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    public func requestVideoURL(localIdentifier: String) async -> URL? {
        let id = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else { return nil }
        guard asset.mediaType == .video else { return nil }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset.url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func mapAuthorizationStatus(_ status: PHAuthorizationStatus) -> AlbumLibraryAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .limited:
            return .limited
        @unknown default:
            return .denied
        }
    }

    private func randomSample(from result: PHFetchResult<PHAsset>, limit: Int) -> [PHAsset] {
        let cappedLimit = max(0, limit)
        if cappedLimit == 0 {
            var phAssets: [PHAsset] = []
            phAssets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                phAssets.append(asset)
            }
            return phAssets
        }

        var phAssets: [PHAsset] = []
        phAssets.reserveCapacity(min(result.count, cappedLimit))

        if result.count > cappedLimit {
            var chosen = Set<Int>()
            chosen.reserveCapacity(cappedLimit)
            while chosen.count < cappedLimit, chosen.count < result.count {
                chosen.insert(Int.random(in: 0..<result.count))
            }
            for idx in chosen {
                phAssets.append(result.object(at: idx))
            }
        } else {
            result.enumerateObjects { asset, _, stop in
                phAssets.append(asset)
                if phAssets.count >= cappedLimit {
                    stop.pointee = true
                }
            }
        }

        return phAssets
    }

    private func mapAlbumAssets(_ phAssets: [PHAsset]) -> [AlbumAsset] {
        var out: [AlbumAsset] = []
        out.reserveCapacity(phAssets.count)

        for asset in phAssets {
            let mediaType: AlbumMediaType?
            switch asset.mediaType {
            case .image:
                mediaType = .photo
            case .video:
                mediaType = .video
            default:
                mediaType = nil
            }
            guard let mediaType else { continue }

            let location: AlbumLocation?
            if let loc = asset.location?.coordinate {
                location = AlbumLocation(latitude: loc.latitude, longitude: loc.longitude)
            } else {
                location = nil
            }

            out.append(
                AlbumAsset(
                    localIdentifier: asset.localIdentifier,
                    mediaType: mediaType,
                    creationDate: asset.creationDate,
                    location: location,
                    duration: asset.mediaType == .video ? asset.duration : nil,
                    isFavorite: asset.isFavorite,
                    pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
                    pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil
                )
            )
        }

        return out
    }
}
