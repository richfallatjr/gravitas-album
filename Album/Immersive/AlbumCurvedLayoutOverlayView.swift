import SwiftUI
import AVKit
import AVFoundation

enum AlbumCurvedWallNavDirection: Sendable {
    case prev
    case next
}

struct AlbumCurvedWallPanelAttachmentView: View {
    let assetID: String
    let viewHeightPoints: Double

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openWindow) private var openWindow

    @State private var image: AlbumImage? = nil
    @State private var isLoading: Bool = false
    @State private var player: AVQueuePlayer? = nil
    @State private var playerLooper: AVPlayerLooper? = nil
    @State private var currentVideoURL: URL? = nil
    @State private var isLoadingVideo: Bool = false
    @State private var showHideConfirmation: Bool = false

    private let showActionStrip: Bool = false

    private let panelWidthPoints: CGFloat = 620
    private let horizontalPaddingPoints: CGFloat = 4
    private let verticalPaddingPoints: CGFloat = 4
    private let actionRowHeightPoints: CGFloat = 66
    private let actionRowSpacingPoints: CGFloat = 4
    private let cornerRadius: CGFloat = 16

    var body: some View {
        let isSelected = model.currentAssetID == assetID
        let asset = model.asset(for: assetID)
        let innerWidth = max(panelWidthPoints - (horizontalPaddingPoints * 2), 240)
        let contentHeight = max(1, CGFloat(viewHeightPoints) - (verticalPaddingPoints * 2))
        let actionRowHeight = showActionStrip ? actionRowHeightPoints : 0
        let actionRowSpacing = showActionStrip ? actionRowSpacingPoints : 0
        let mediaHeight = max(1, contentHeight - actionRowHeight - actionRowSpacing)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.sRGB, white: 0.04, opacity: 0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isSelected ? model.palette.historyButtonColor : Color.white.opacity(0.14), lineWidth: isSelected ? 2 : 1)
                )

            VStack(alignment: .center, spacing: actionRowSpacing) {
                ZStack {
                    if asset?.mediaType == .video, let player {
                        VideoPlayer(player: player)
                            .onAppear {
                                player.play()
                            }
                            .onDisappear {
                                player.pause()
                            }
                    } else if let image {
#if canImport(UIKit)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
#elseif canImport(AppKit)
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
#else
                        Color.black.opacity(0.10)
#endif
                    } else {
                        Color.white.opacity(0.06)
                        if isLoading || isLoadingVideo {
                            ProgressView()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: innerWidth, height: mediaHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if showActionStrip {
                    actionStrip(width: innerWidth)
                }
            }
            .padding(.horizontal, horizontalPaddingPoints)
            .padding(.vertical, verticalPaddingPoints)
        }
        .frame(width: panelWidthPoints, height: CGFloat(viewHeightPoints))
        .contentShape(Rectangle())
        .onTapGesture {
            model.currentAssetID = assetID
        }
        .onDisappear {
            player?.pause()
            player = nil
            playerLooper = nil
            currentVideoURL = nil
            isLoadingVideo = false
        }
        .task(id: assetID) {
            await loadMedia(innerWidth: innerWidth, mediaHeight: mediaHeight)
        }
    }

    @MainActor
    private func loadMedia(innerWidth: CGFloat, mediaHeight: CGFloat) async {
        guard let asset = model.asset(for: assetID) else { return }

        player?.pause()
        player = nil
        playerLooper = nil
        currentVideoURL = nil

        isLoading = true
        defer { isLoading = false }

        let requestPoints = CGSize(width: innerWidth, height: mediaHeight)
        image = await model.requestThumbnail(assetID: assetID, targetSize: requestPoints, displayScale: displayScale)

        guard asset.mediaType == .video else { return }

        isLoadingVideo = true
        defer { isLoadingVideo = false }

        guard let url = await model.requestVideoURL(assetID: assetID) else { return }
        if currentVideoURL == url, player != nil { return }

        currentVideoURL = url

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.actionAtItemEnd = .none

        let looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLooper = looper
        player = queue
        queue.play()
    }

    @ViewBuilder
    private func actionStrip(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            actionButton(icon: "hand.thumbsup.fill", fill: Color(red: 169.0/255.0, green: 220.0/255.0, blue: 118.0/255.0)) {
                model.sendThumb(.up, assetID: assetID)
            }

            actionButton(icon: "hand.thumbsdown.fill", fill: Color(red: 255.0/255.0, green: 216.0/255.0, blue: 102.0/255.0)) {
                model.sendThumb(.down, assetID: assetID)
            }

            actionButton(icon: "trash.fill", fill: Color(red: 255.0/255.0, green: 97.0/255.0, blue: 136.0/255.0)) {
                showHideConfirmation = true
            }
            .confirmationDialog(
                "Hide this image?",
                isPresented: $showHideConfirmation,
                titleVisibility: .visible
            ) {
                Button("Hide", role: .destructive) {
                    model.hideAsset(assetID)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to hide this from view? You will no longer see this image.")
            }

            actionButton(icon: "rectangle.on.rectangle", fill: Color(red: 120.0/255.0, green: 220.0/255.0, blue: 232.0/255.0)) {
                if let item = model.createPoppedAssetItem(assetID: assetID) {
                    openWindow(value: AlbumPopOutPayload(itemID: item.id))
                }
            }
        }
        .frame(width: width, height: actionRowHeightPoints, alignment: .center)
    }

    private func actionButton(icon: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.90))
                .frame(width: 66, height: 66)
                .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AlbumCurvedWallTileAttachmentView: View {
    let assetID: String

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var image: AlbumImage? = nil
    @State private var isLoading: Bool = false
    @State private var showHideConfirmation: Bool = false

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
                .strokeBorder(isSelected ? model.palette.historyButtonColor : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .confirmationDialog(
            "Hide this image?",
            isPresented: $showHideConfirmation,
            titleVisibility: .visible
        ) {
            Button("Hide", role: .destructive) {
                model.hideAsset(assetID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to hide this from view? You will no longer see this image.")
        }
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
                    showHideConfirmation = true
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
    let action: @MainActor () -> Void

    private let sizePoints = CGSize(width: 118, height: 118)
    private let cornerRadius: CGFloat = 18
    private let panelBackground = Color(.sRGB, white: 0.04, opacity: 0.95)
    private let panelBorder = Color.white.opacity(0.14)

    var body: some View {
        let icon = direction == .prev ? "chevron.left" : "chevron.right"

        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .black))
                .frame(width: sizePoints.width, height: sizePoints.height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.95))
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(panelBorder, lineWidth: 1)
        )
        .opacity(enabled ? 1.0 : 0.35)
    }
}

struct AlbumCurvedWallCloseAttachmentView: View {
    let action: @MainActor () -> Void

    private let sizePoints = CGSize(width: 118, height: 118)
    private let cornerRadius: CGFloat = 18
    private let panelBackground = Color(.sRGB, white: 0.04, opacity: 0.95)
    private let panelBorder = Color.white.opacity(0.14)

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 46, weight: .black))
                .frame(width: sizePoints.width, height: sizePoints.height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.95))
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(panelBorder, lineWidth: 1)
        )
        .accessibilityLabel("Close layout")
    }
}
