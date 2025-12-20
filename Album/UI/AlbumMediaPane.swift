import SwiftUI
import AVKit

public struct AlbumMediaPane: View {
    public let assetID: String?
    public let showsFocusButton: Bool
    public let sceneItemID: UUID?
    public let showsSceneEditorButtons: Bool

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var image: AlbumImage? = nil
    @State private var player: AVPlayer? = nil
    @State private var currentVideoURL: URL? = nil
    @State private var isLoadingPreview: Bool = false
    @State private var kenBurnsMoveActive: Bool = false
    @State private var isClipperPresented: Bool = false

    public init(
        assetID: String?,
        showsFocusButton: Bool = false,
        sceneItemID: UUID? = nil,
        showsSceneEditorButtons: Bool = false
    ) {
        self.assetID = assetID
        self.showsFocusButton = showsFocusButton
        self.sceneItemID = sceneItemID
        self.showsSceneEditorButtons = showsSceneEditorButtons
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
                        actionButtons(asset: asset)
                    }
                }
                .onAppear {
                    model.ensureVisionSummary(for: assetID, reason: "media_pane")
                }
                .task(id: assetID) {
                    await loadPreview(for: asset)
                }
                .onChange(of: assetID) { _ in
                    kenBurnsMoveActive = false
                    isClipperPresented = false
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
                ZStack {
                    VideoPlayer(player: player)
                        .onDisappear { player.pause() }

                    if showsSceneEditorButtons,
                       kenBurnsMoveActive,
                       let sceneItemID,
                       asset.mediaType == .video {
                        AlbumVideoCropMoveOverlay(asset: asset, itemID: sceneItemID)
                            .environmentObject(model)
                    }
                }
            } else if let image {
#if canImport(UIKit)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                    if showsSceneEditorButtons,
                       kenBurnsMoveActive,
                       let sceneItemID,
                       asset.mediaType == .photo {
                        AlbumKenBurnsMoveOverlay(asset: asset, itemID: sceneItemID)
                            .environmentObject(model)
                    }
                }
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

    private func actionButtons(asset: AlbumAsset) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if showsFocusButton {
                focusButton(assetID: asset.localIdentifier)
            }
            if showsSceneEditorButtons, let sceneItemID {
                if asset.mediaType == .photo {
                    kenBurnsButton()
                } else if asset.mediaType == .video {
                    kenBurnsButton()
                    clipperButton(itemID: sceneItemID, assetID: asset.localIdentifier)
                }
            }
            thumbButtons(assetID: asset.localIdentifier)
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

    private func kenBurnsButton() -> some View {
        let palette = model.palette

        return Button {
            kenBurnsMoveActive.toggle()
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.title3)
                .foregroundStyle(palette.buttonLabelOnColor)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            (kenBurnsMoveActive ? palette.readButtonColor : palette.copyButtonFill),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityLabel(kenBurnsMoveActive ? "Move On" : "Move")
    }

    private func clipperButton(itemID: UUID, assetID: String) -> some View {
        let palette = model.palette

        return Button {
            isClipperPresented = true
        } label: {
            Image(systemName: "scissors")
                .font(.title3)
                .foregroundStyle(palette.buttonLabelOnColor)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(palette.copyButtonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Clip")
        .sheet(isPresented: $isClipperPresented) {
            AlbumVideoClipperSheet(itemID: itemID, assetID: assetID)
                .environmentObject(model)
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

private struct AlbumKenBurnsMoveOverlay: View {
    let asset: AlbumAsset
    let itemID: UUID

    @EnvironmentObject private var model: AlbumModel

    private enum DragTarget {
        case start
        case end
    }

    @State private var dragging: DragTarget? = nil

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let imageRect = fittedRect(container: bounds, imageAspect: imageAspectRatio(asset: asset))

            let allowedNorm = allowedNormalizedRect(asset: asset, renderSize: 1080)
            let allowedRect = rectFromNormalized(allowedNorm, in: imageRect)

            let anchors = effectiveAnchors(assetID: asset.localIdentifier, allowedNorm: allowedNorm)
            let startPt = pointFromNormalized(anchors.start, in: imageRect)
            let endPt = pointFromNormalized(anchors.end, in: imageRect)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .path(in: allowedRect)
                    .stroke(
                        Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [6, 5])
                    )

                Path { path in
                    path.move(to: startPt)
                    path.addLine(to: endPt)
                }
                .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 6]))

                if dragging != nil {
                    thirdsGuides(in: imageRect)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                }

                handle(
                    label: "S",
                    shape: .circle,
                    fill: Color(.sRGB, red: 0.15, green: 0.86, blue: 0.93, opacity: 0.95),
                    center: startPt,
                    dragTarget: .start,
                    imageRect: imageRect,
                    allowedNorm: allowedNorm
                )

                handle(
                    label: "E",
                    shape: .diamond,
                    fill: Color(.sRGB, red: 0.74, green: 0.26, blue: 0.98, opacity: 0.95),
                    center: endPt,
                    dragTarget: .end,
                    imageRect: imageRect,
                    allowedNorm: allowedNorm
                )
            }
            .contentShape(Rectangle())
        }
        .allowsHitTesting(true)
    }

    private func effectiveAnchors(assetID: String, allowedNorm: CGRect) -> (start: CGPoint, end: CGPoint) {
        let stored = model.poppedItem(for: itemID)
        let start = stored?.kenBurnsStartAnchor ?? defaultKenBurnsStart()
        let end = stored?.kenBurnsEndAnchor ?? defaultKenBurnsEnd(assetID: assetID)
        return (clampNormalized(start, to: allowedNorm), clampNormalized(end, to: allowedNorm))
    }

    private func defaultKenBurnsStart() -> CGPoint {
        CGPoint(x: 0.5, y: 0.5)
    }

    private func defaultKenBurnsEnd(assetID: String) -> CGPoint {
        let options: [CGPoint] = [
            CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
            CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0),
            CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
            CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0),
        ]
        return options[stableHashMod4(assetID)]
    }

    private func stableHashMod4(_ input: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % 4)
    }

    private func handle(
        label: String,
        shape: HandleShape,
        fill: Color,
        center: CGPoint,
        dragTarget: DragTarget,
        imageRect: CGRect,
        allowedNorm: CGRect
    ) -> some View {
        let size: CGFloat = 36

        return ZStack {
            switch shape {
            case .circle:
                Circle().fill(fill)
            case .diamond:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
                    .rotationEffect(.degrees(45))
            }

            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.black.opacity(0.78))
                .rotationEffect(shape == .diamond ? .degrees(-45) : .degrees(0))
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .stroke(Color.black.opacity(0.22), lineWidth: 1)
                .opacity(shape == .circle ? 1 : 0)
        )
        .position(center)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = dragTarget
                    let norm = normalizedPoint(from: value.location, in: imageRect)
                    let snapped = snapToThirds(norm, threshold: 0.03)
                    let clamped = clampNormalized(snapped, to: allowedNorm)
                    applyAnchor(dragTarget: dragTarget, normalized: clamped, allowedNorm: allowedNorm)
                }
                .onEnded { _ in
                    dragging = nil
                }
        )
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
    }

    private enum HandleShape {
        case circle
        case diamond
    }

    private func applyAnchor(dragTarget: DragTarget, normalized: CGPoint, allowedNorm: CGRect) {
        let assetID = asset.localIdentifier
        let current = effectiveAnchors(assetID: assetID, allowedNorm: allowedNorm)

        model.updatePoppedItem(itemID) { item in
            item.kenBurnsUserDefined = true
            item.kenBurnsStartAnchor = (dragTarget == .start) ? normalized : current.start
            item.kenBurnsEndAnchor = (dragTarget == .end) ? normalized : current.end
        }
    }

    private func imageAspectRatio(asset: AlbumAsset) -> CGFloat {
        let w = CGFloat(asset.pixelWidth ?? 0)
        let h = CGFloat(asset.pixelHeight ?? 0)
        guard w > 0, h > 0 else { return 1 }
        return w / h
    }

    private func fittedRect(container: CGRect, imageAspect: CGFloat) -> CGRect {
        let containerAspect = container.width / max(0.001, container.height)

        if imageAspect > containerAspect {
            let width = container.width
            let height = width / max(0.001, imageAspect)
            let y = container.midY - (height / 2)
            return CGRect(x: container.minX, y: y, width: width, height: height)
        } else {
            let height = container.height
            let width = height * imageAspect
            let x = container.midX - (width / 2)
            return CGRect(x: x, y: container.minY, width: width, height: height)
        }
    }

    private func allowedNormalizedRect(asset: AlbumAsset, renderSize: Double) -> CGRect {
        let w = Double(asset.pixelWidth ?? 0)
        let h = Double(asset.pixelHeight ?? 0)
        guard w > 0, h > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let scale = max(renderSize / w, renderSize / h)
        let cropSizePx = renderSize / max(0.000_001, scale)
        let halfX = (cropSizePx / 2) / w
        let halfY = (cropSizePx / 2) / h

        let minX = min(max(halfX, 0), 0.5)
        let maxX = max(min(1 - halfX, 1), 0.5)
        let minY = min(max(halfY, 0), 0.5)
        let maxY = max(min(1 - halfY, 1), 0.5)

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func clampNormalized(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func snapToThirds(_ point: CGPoint, threshold: CGFloat) -> CGPoint {
        let thirds: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
        var x = point.x
        var y = point.y

        for t in thirds {
            if abs(point.x - t) < threshold { x = t }
            if abs(point.y - t) < threshold { y = t }
        }
        return CGPoint(x: x, y: y)
    }

    private func normalizedPoint(from location: CGPoint, in rect: CGRect) -> CGPoint {
        let x = (location.x - rect.minX) / max(0.000_001, rect.width)
        let y = (location.y - rect.minY) / max(0.000_001, rect.height)
        return CGPoint(x: x, y: y)
    }

    private func pointFromNormalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func rectFromNormalized(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + rect.minX * bounds.width,
            y: bounds.minY + rect.minY * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
    }

    private func thirdsGuides(in rect: CGRect) -> Path {
        Path { path in
            let x1 = rect.minX + rect.width / 3
            let x2 = rect.minX + (rect.width * 2 / 3)
            let y1 = rect.minY + rect.height / 3
            let y2 = rect.minY + (rect.height * 2 / 3)

            path.move(to: CGPoint(x: x1, y: rect.minY))
            path.addLine(to: CGPoint(x: x1, y: rect.maxY))
            path.move(to: CGPoint(x: x2, y: rect.minY))
            path.addLine(to: CGPoint(x: x2, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y1))
            path.addLine(to: CGPoint(x: rect.maxX, y: y1))
            path.move(to: CGPoint(x: rect.minX, y: y2))
            path.addLine(to: CGPoint(x: rect.maxX, y: y2))
        }
    }
}

private struct AlbumVideoCropMoveOverlay: View {
    let asset: AlbumAsset
    let itemID: UUID

    @EnvironmentObject private var model: AlbumModel
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let imageRect = fittedRect(container: bounds, imageAspect: imageAspectRatio(asset: asset))

            let allowedNorm = allowedNormalizedRect(asset: asset, renderSize: 1080)
            let allowedRect = rectFromNormalized(allowedNorm, in: imageRect)

            let anchor = effectiveAnchor(allowedNorm: allowedNorm)
            let center = pointFromNormalized(anchor, in: imageRect)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .path(in: allowedRect)
                    .stroke(
                        Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [6, 5])
                    )

                if isDragging {
                    thirdsGuides(in: imageRect)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                }

                handle(center: center, imageRect: imageRect, allowedNorm: allowedNorm)
            }
            .contentShape(Rectangle())
        }
        .allowsHitTesting(true)
    }

    private func effectiveAnchor(allowedNorm: CGRect) -> CGPoint {
        let stored = model.poppedItem(for: itemID)
        let anchor = stored?.videoCropAnchor ?? CGPoint(x: 0.5, y: 0.5)
        return clampNormalized(anchor, to: allowedNorm)
    }

    private func handle(center: CGPoint, imageRect: CGRect, allowedNorm: CGRect) -> some View {
        let size: CGFloat = 36

        return ZStack {
            Circle()
                .fill(Color(.sRGB, red: 0.74, green: 0.26, blue: 0.98, opacity: 0.95))

            Text("C")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.black.opacity(0.78))
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .stroke(Color.black.opacity(0.22), lineWidth: 1)
        )
        .position(center)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    let norm = normalizedPoint(from: value.location, in: imageRect)
                    let snapped = snapToThirds(norm, threshold: 0.03)
                    let clamped = clampNormalized(snapped, to: allowedNorm)

                    model.updatePoppedItem(itemID) { item in
                        item.videoCropAnchor = clamped
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
    }

    private func imageAspectRatio(asset: AlbumAsset) -> CGFloat {
        let w = CGFloat(asset.pixelWidth ?? 0)
        let h = CGFloat(asset.pixelHeight ?? 0)
        guard w > 0, h > 0 else { return 1 }
        return w / h
    }

    private func fittedRect(container: CGRect, imageAspect: CGFloat) -> CGRect {
        let containerAspect = container.width / max(0.001, container.height)

        if imageAspect > containerAspect {
            let width = container.width
            let height = width / max(0.001, imageAspect)
            let y = container.midY - (height / 2)
            return CGRect(x: container.minX, y: y, width: width, height: height)
        } else {
            let height = container.height
            let width = height * imageAspect
            let x = container.midX - (width / 2)
            return CGRect(x: x, y: container.minY, width: width, height: height)
        }
    }

    private func allowedNormalizedRect(asset: AlbumAsset, renderSize: Double) -> CGRect {
        let w = Double(asset.pixelWidth ?? 0)
        let h = Double(asset.pixelHeight ?? 0)
        guard w > 0, h > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let scale = max(renderSize / w, renderSize / h)
        let cropSizePx = renderSize / max(0.000_001, scale)
        let halfX = (cropSizePx / 2) / w
        let halfY = (cropSizePx / 2) / h

        let minX = min(max(halfX, 0), 0.5)
        let maxX = max(min(1 - halfX, 1), 0.5)
        let minY = min(max(halfY, 0), 0.5)
        let maxY = max(min(1 - halfY, 1), 0.5)

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func clampNormalized(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func snapToThirds(_ point: CGPoint, threshold: CGFloat) -> CGPoint {
        let thirds: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
        var x = point.x
        var y = point.y

        for t in thirds {
            if abs(point.x - t) < threshold { x = t }
            if abs(point.y - t) < threshold { y = t }
        }
        return CGPoint(x: x, y: y)
    }

    private func normalizedPoint(from location: CGPoint, in rect: CGRect) -> CGPoint {
        let x = (location.x - rect.minX) / max(0.000_001, rect.width)
        let y = (location.y - rect.minY) / max(0.000_001, rect.height)
        return CGPoint(x: x, y: y)
    }

    private func pointFromNormalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func rectFromNormalized(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + rect.minX * bounds.width,
            y: bounds.minY + rect.minY * bounds.height,
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
    }

    private func thirdsGuides(in rect: CGRect) -> Path {
        Path { path in
            let x1 = rect.minX + rect.width / 3
            let x2 = rect.minX + (rect.width * 2 / 3)
            let y1 = rect.minY + rect.height / 3
            let y2 = rect.minY + (rect.height * 2 / 3)

            path.move(to: CGPoint(x: x1, y: rect.minY))
            path.addLine(to: CGPoint(x: x1, y: rect.maxY))
            path.move(to: CGPoint(x: x2, y: rect.minY))
            path.addLine(to: CGPoint(x: x2, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y1))
            path.addLine(to: CGPoint(x: rect.maxX, y: y1))
            path.move(to: CGPoint(x: rect.minX, y: y2))
            path.addLine(to: CGPoint(x: rect.maxX, y: y2))
        }
    }
}

private struct AlbumVideoClipperSheet: View {
    let itemID: UUID
    let assetID: String

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    @State private var videoURL: URL? = nil
    @State private var player: AVPlayer? = nil
    @State private var durationSeconds: Double = 0

    @State private var startSeconds: Double = 0
    @State private var endSeconds: Double = 0

    private let minSpan: Double = 0.5

    var body: some View {
        let palette = model.palette

        VStack(spacing: 16) {
            Text("Clip")
                .font(.headline)

            Group {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.black.opacity(0.06))
                        .frame(height: 360)
                        .overlay {
                            ProgressView()
                        }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Start")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(formatTime(startSeconds))
                        .font(.caption)
                        .foregroundStyle(palette.panelSecondaryText)
                }
                Slider(value: $startSeconds, in: 0...max(0, durationSeconds))
                    .onChange(of: startSeconds) { _ in
                        clampStartChanged()
                    }

                HStack {
                    Text("End")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(formatTime(endSeconds))
                        .font(.caption)
                        .foregroundStyle(palette.panelSecondaryText)
                }
                Slider(value: $endSeconds, in: 0...max(0, durationSeconds))
                    .onChange(of: endSeconds) { _ in
                        clampEndChanged()
                    }
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(durationSeconds <= 0)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .task {
            await prepare()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func prepare() async {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        if let asset = await MainActor.run(body: { model.asset(for: id) }), let dur = asset.duration {
            durationSeconds = max(0, dur)
        }

        if let url = await model.requestVideoURL(assetID: id) {
            videoURL = url
            let p = AVPlayer(url: url)
            player = p
        }

        if durationSeconds <= 0, let url = videoURL {
            let asset = AVURLAsset(url: url)
            if let dur = try? await asset.load(.duration) {
                durationSeconds = max(0, dur.seconds)
            }
        }

        let stored = await MainActor.run(body: { model.poppedItem(for: itemID) })
        let storedStart = stored?.trimStartSeconds ?? 0
        let storedEnd = stored?.trimEndSeconds ?? min(5.0, durationSeconds)

        startSeconds = max(0, min(storedStart, durationSeconds))
        endSeconds = max(0, min(storedEnd, durationSeconds))
        enforceMinimumSpan(preferAdjustingEnd: true)

        seek(to: startSeconds)
        player?.play()
    }

    private func clampStartChanged() {
        startSeconds = max(0, min(startSeconds, durationSeconds))
        enforceMinimumSpan(preferAdjustingEnd: true)
        seek(to: startSeconds)
    }

    private func clampEndChanged() {
        endSeconds = max(0, min(endSeconds, durationSeconds))
        enforceMinimumSpan(preferAdjustingEnd: false)
    }

    private func enforceMinimumSpan(preferAdjustingEnd: Bool) {
        guard durationSeconds > 0 else { return }

        if endSeconds < startSeconds {
            swap(&startSeconds, &endSeconds)
        }

        if endSeconds - startSeconds < minSpan {
            if preferAdjustingEnd {
                endSeconds = min(durationSeconds, startSeconds + minSpan)
            } else {
                startSeconds = max(0, endSeconds - minSpan)
            }
        }

        startSeconds = max(0, min(startSeconds, max(0, durationSeconds - minSpan)))
        endSeconds = max(startSeconds + minSpan, min(endSeconds, durationSeconds))
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func apply() {
        enforceMinimumSpan(preferAdjustingEnd: true)
        model.updatePoppedItem(itemID) { item in
            item.trimStartSeconds = startSeconds
            item.trimEndSeconds = endSeconds
        }
        dismiss()
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        if m > 0 {
            return String(format: "%d:%02d", m, s)
        }
        return "\(s)s"
    }
}
