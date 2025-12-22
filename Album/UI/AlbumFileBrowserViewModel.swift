import Foundation
import Photos

@MainActor
final class AlbumFileBrowserViewModel: ObservableObject {
    let imageManager = PHCachingImageManager()

    private var fetchResult: PHFetchResult<PHAsset>? = nil

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String? = nil

    var count: Int { fetchResult?.count ?? 0 }

    func asset(at index: Int) -> PHAsset? {
        guard let fetchResult, index >= 0, index < fetchResult.count else { return nil }
        return fetchResult.object(at: index)
    }

    func load(query: AlbumQuery, excludingAssetIDs hiddenIDs: Set<String>) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        imageManager.stopCachingImagesForAllAssets()

        let canReadPhotos = await requestPhotosAccessIfNeeded()
        guard canReadPhotos else {
            fetchResult = nil
            errorMessage = "Photos access is required to browse files."
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let trimmedHiddenIDs = hiddenIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let hiddenPredicate: NSPredicate? = {
            guard !trimmedHiddenIDs.isEmpty else { return nil }
            // Avoid creating an enormous predicate for unusually large hidden sets.
            guard trimmedHiddenIDs.count <= 512 else { return nil }
            return NSPredicate(format: "NOT (localIdentifier IN %@)", trimmedHiddenIDs)
        }()

        let result: PHFetchResult<PHAsset>
        switch query {
        case .allPhotos:
            if let hiddenPredicate { options.predicate = hiddenPredicate }
            result = PHAsset.fetchAssets(with: options)

        case .favorites:
            let favoritesPredicate = NSPredicate(format: "favorite == YES")
            options.predicate = compoundPredicate(favoritesPredicate, hiddenPredicate)
            result = PHAsset.fetchAssets(with: options)

        case .recents(let days):
            var predicates: [NSPredicate] = []
            if days > 0,
               let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) {
                predicates.append(NSPredicate(format: "creationDate >= %@", cutoff as NSDate))
            }
            if let hiddenPredicate { predicates.append(hiddenPredicate) }
            options.predicate = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            result = PHAsset.fetchAssets(with: options)

        case .year(let year):
            let cal = Calendar(identifier: .gregorian)
            let startComps = DateComponents(year: year, month: 1, day: 1)
            let endComps = DateComponents(year: year + 1, month: 1, day: 1)
            if let start = cal.date(from: startComps), let end = cal.date(from: endComps) {
                let datePredicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
                options.predicate = compoundPredicate(datePredicate, hiddenPredicate)
            } else if let hiddenPredicate {
                options.predicate = hiddenPredicate
            }
            result = PHAsset.fetchAssets(with: options)

        case .day(let year, let month, let day):
            let cal = Calendar(identifier: .gregorian)
            let startComps = DateComponents(year: year, month: month, day: day)
            if let start = cal.date(from: startComps), let end = cal.date(byAdding: .day, value: 1, to: start) {
                let datePredicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
                options.predicate = compoundPredicate(datePredicate, hiddenPredicate)
            } else if let hiddenPredicate {
                options.predicate = hiddenPredicate
            }
            result = PHAsset.fetchAssets(with: options)

        case .userAlbum(let album):
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil)
            guard let collection = collections.firstObject else {
                fetchResult = nil
                errorMessage = "Album not found."
                return
            }
            if let hiddenPredicate { options.predicate = hiddenPredicate }
            result = PHAsset.fetchAssets(in: collection, options: options)
        }

        fetchResult = result
        errorMessage = nil

        let initialCount = min(result.count, 200)
        if initialCount > 0 {
            var assets: [PHAsset] = []
            assets.reserveCapacity(initialCount)
            for idx in 0..<initialCount {
                assets.append(result.object(at: idx))
            }
            let targetSize = CGSize(width: 240, height: 240)
            imageManager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
        }
    }

    private func compoundPredicate(_ base: NSPredicate, _ extra: NSPredicate?) -> NSPredicate {
        guard let extra else { return base }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, extra])
    }

    private func requestPhotosAccessIfNeeded() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }

        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return newStatus == .authorized || newStatus == .limited
    }
}

