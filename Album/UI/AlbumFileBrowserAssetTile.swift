import Photos
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AlbumFileBrowserAssetTile: View {
    let asset: PHAsset
    let manager: PHCachingImageManager

#if canImport(UIKit)
    @State private var image: UIImage? = nil
#endif
    @State private var requestID: PHImageRequestID? = nil

    var body: some View {
        ZStack {
#if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.thinMaterial)
            }
#else
            Rectangle()
                .fill(.thinMaterial)
#endif

            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule(style: .continuous))
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: asset.localIdentifier) {
            loadThumbnail()
        }
        .onDisappear {
            cancelRequest()
#if canImport(UIKit)
            image = nil
#endif
        }
    }

    private func cancelRequest() {
        if let requestID {
            manager.cancelImageRequest(requestID)
            self.requestID = nil
        }
    }

    private func loadThumbnail() {
        cancelRequest()

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.version = .current
        options.isSynchronous = false

        let targetSize = CGSize(width: 240, height: 240)

        requestID = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { img, info in
#if canImport(UIKit)
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = info?[PHImageErrorKey] as? NSError
            guard !cancelled, error == nil else { return }

            guard let img else { return }
            Task { @MainActor in
                self.image = img
            }
#endif
        }
    }
}
