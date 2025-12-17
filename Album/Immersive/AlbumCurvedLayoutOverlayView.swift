import SwiftUI

enum AlbumCurvedWallNavDirection: Sendable {
    case prev
    case next
}

struct AlbumCurvedWallTileAttachmentView: View {
    let assetID: String

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var image: AlbumImage? = nil
    @State private var isLoading: Bool = false

    private let tileSizePoints = CGSize(width: 260, height: 340)
    private let cornerRadius: CGFloat = 18

    var body: some View {
        let isSelected = model.currentAssetID == assetID
        let feedback = model.thumbFeedbackByAssetID[assetID]
        let asset = model.asset(for: assetID)

        ZStack {
            preview

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .opacity(asset != nil ? 1 : 0)

            overlayBadges(asset: asset, feedback: feedback)
        }
        .frame(width: tileSizePoints.width, height: tileSizePoints.height)
        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: assetID) {
            await loadThumbnail()
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
#if canImport(UIKit)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
                .background(.black.opacity(0.06))
#elseif canImport(AppKit)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
                .background(.black.opacity(0.06))
#else
            Color.black.opacity(0.06)
#endif
        } else {
            ZStack {
                Color.black.opacity(0.06)
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func overlayBadges(asset: AlbumAsset?, feedback: AlbumThumbFeedback?) -> some View {
        VStack {
            HStack {
                if let asset, asset.mediaType == .video {
                    Label("Video", systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                }

                Spacer(minLength: 0)

                if let feedback {
                    Text(feedback == .up ? "👍" : "👎")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                }
            }
            .padding(10)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    model.sendThumb(.up, assetID: assetID)
                } label: {
                    Image(systemName: "hand.thumbsup.fill")
                }

                Button {
                    model.sendThumb(.down, assetID: assetID)
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                }

                Button(role: .destructive) {
                    model.hideAsset(assetID)
                } label: {
                    Image(systemName: "eye.slash.fill")
                }

                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(10)
        }
    }

    @MainActor
    private func loadThumbnail() async {
        guard model.asset(for: assetID) != nil else { return }
        isLoading = true
        defer { isLoading = false }

        let requestPoints = CGSize(width: tileSizePoints.width * 2, height: tileSizePoints.height * 2)
        image = await model.requestThumbnail(assetID: assetID, targetSize: requestPoints, displayScale: displayScale)
    }
}

struct AlbumCurvedWallNavCardAttachmentView: View {
    let direction: AlbumCurvedWallNavDirection
    let enabled: Bool

    private let sizePoints = CGSize(width: 240, height: 110)
    private let cornerRadius: CGFloat = 18

    var body: some View {
        let label = direction == .prev ? "Prev" : "Next"
        let icon = direction == .prev ? "chevron.left" : "chevron.right"

        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.headline)
                Text(enabled ? "Page" : "End")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: sizePoints.width, height: sizePoints.height)
        .glassBackground(cornerRadius: cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .opacity(enabled ? 1.0 : 0.35)
        .allowsHitTesting(false)
    }
}

struct AlbumCurvedWallCloseAttachmentView: View {
    private let sizePoints = CGSize(width: 240, height: 110)
    private let cornerRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
            Text("Close Layout")
                .font(.headline)
        }
        .frame(width: sizePoints.width, height: sizePoints.height)
        .glassBackground(cornerRadius: cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
