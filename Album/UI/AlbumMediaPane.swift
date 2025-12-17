import SwiftUI
import AVKit

public struct AlbumMediaPane: View {
    public let assetID: String?

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var image: AlbumImage? = nil
    @State private var player: AVPlayer? = nil
    @State private var currentVideoURL: URL? = nil
    @State private var isLoadingPreview: Bool = false

    public init(assetID: String?) {
        self.assetID = assetID
    }

    public var body: some View {
        Group {
            if let assetID, let asset = model.asset(for: assetID) {
                VStack(alignment: .leading, spacing: 12) {
                    preview(asset: asset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    HStack(alignment: .bottom, spacing: 12) {
                        metaCard(asset: asset)
                        Spacer(minLength: 0)
                        thumbButtons(assetID: assetID)
                    }
                }
                .onAppear {
                    model.ensureVisionSummary(for: assetID, reason: "media_pane")
                }
                .task(id: assetID) {
                    await loadPreview(for: asset)
                }
            } else {
                Text("Absorbed asset appears here")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func preview(asset: AlbumAsset) -> some View {
        ZStack {
            if asset.mediaType == .video, let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else if let image {
#if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
#elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
#endif
            } else {
                Color.black.opacity(0.06)
                if isLoadingPreview {
                    ProgressView()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: asset.mediaType == .video ? "video" : "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)

                        Text("No preview available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.visionPendingAssetIDs.contains(asset.localIdentifier) {
                VStack {
                    Spacer()
                    Label("Vision tagging…", systemImage: "eye")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                        .padding(12)
                }
                .transition(.opacity)
            }
        }
    }

    private func metaCard(asset: AlbumAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.semanticHandle(for: asset))
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            HStack(spacing: 10) {
                Text(asset.mediaType == .video ? "Video" : "Photo")
                if asset.isFavorite { Text("★") }
                if let ym = model.createdYearMonth(for: asset) { Text(ym) }
                if asset.mediaType == .video, let duration = asset.duration {
                    Text(formatDuration(duration))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            thumbStatus
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var thumbStatus: some View {
        if let startedAt = model.thumbThinkingSince,
           let feedback = model.thumbThinkingFeedback {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text("\(feedback == .up ? "👍" : "👎") Thinking… \(elapsed)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let message = model.thumbStatusMessage {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func thumbButtons(assetID: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                model.sendThumb(.up, assetID: assetID)
            } label: {
                Image(systemName: "hand.thumbsup")
                    .font(.title3)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                model.sendThumb(.down, assetID: assetID)
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.title3)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @MainActor
    private func loadPreview(for asset: AlbumAsset) async {
        currentVideoURL = nil
        player = nil
        image = nil
        isLoadingPreview = true
        image = await model.requestThumbnail(assetID: asset.localIdentifier, targetSize: CGSize(width: 1200, height: 960), displayScale: displayScale)

        if asset.mediaType == .video {
            if let url = await model.requestVideoURL(assetID: asset.localIdentifier) {
                currentVideoURL = url
                player = AVPlayer(url: url)
                player?.play()
            }
        }
        isLoadingPreview = false
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let m = total / 60
        let s = total % 60
        if m > 0 { return String(format: "%dm%02ds", m, s) }
        return "\(s)s"
    }
}
