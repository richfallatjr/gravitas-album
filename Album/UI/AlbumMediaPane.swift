import SwiftUI
import AVKit

public struct AlbumMediaPane: View {
    public let assetID: String?
    public let showsFocusButton: Bool

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var image: AlbumImage? = nil
    @State private var player: AVPlayer? = nil
    @State private var currentVideoURL: URL? = nil
    @State private var isLoadingPreview: Bool = false

    public init(assetID: String?, showsFocusButton: Bool = false) {
        self.assetID = assetID
        self.showsFocusButton = showsFocusButton
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
                        actionButtons(assetID: assetID)
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
                    .foregroundStyle(model.palette.panelSecondaryText)
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
        let palette = model.palette

        return VStack(alignment: .leading, spacing: 8) {
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
            .foregroundStyle(palette.panelSecondaryText)

            thumbStatus

            nextUpRow(currentAssetID: asset.localIdentifier)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.cardBorder.opacity(0.65), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func nextUpRow(currentAssetID: String) -> some View {
        let palette = model.palette

        if let nextID = model.recommendedAssetID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nextID.isEmpty,
           nextID != currentAssetID,
           model.asset(for: nextID) != nil {
            Button {
                model.currentAssetID = nextID
            } label: {
                HStack(spacing: 10) {
                    Text("Next Up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.panelSecondaryText)

                    Text(model.semanticHandle(for: nextID))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.panelSecondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.navBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.navBorder.opacity(0.7), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var thumbStatus: some View {
        let palette = model.palette

        if let startedAt = model.thumbThinkingSince,
           let feedback = model.thumbThinkingFeedback {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text("\(feedback == .up ? "👍" : "👎") Thinking… \(elapsed)s")
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)
                    .lineLimit(1)
            }
        } else if let message = model.thumbStatusMessage {
            Text(message)
                .font(.caption2)
                .foregroundStyle(palette.panelSecondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func thumbButtons(assetID: String) -> some View {
        let palette = model.palette

        return HStack(alignment: .center, spacing: 10) {
            Button {
                model.sendThumb(.up, assetID: assetID)
            } label: {
                Image(systemName: "hand.thumbsup")
                    .font(.title3)
                    .foregroundStyle(palette.buttonLabelOnColor)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .background(palette.readButtonColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                model.sendThumb(.down, assetID: assetID)
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.title3)
                    .foregroundStyle(palette.buttonLabelOnColor)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .background(palette.toggleFillColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func actionButtons(assetID: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if showsFocusButton {
                focusButton(assetID: assetID)
            }
            thumbButtons(assetID: assetID)
        }
    }

    private func focusButton(assetID: String) -> some View {
        let palette = model.palette

        return Button {
            Task { await model.focusAssetInHistory(assetID: assetID) }
        } label: {
            Image(systemName: "scope")
                .font(.title3)
                .foregroundStyle(palette.buttonLabelOnColor)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(palette.historyButtonColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Focus")
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
