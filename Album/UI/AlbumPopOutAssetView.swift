import SwiftUI
import AVKit

public struct AlbumPopOutAssetView: View {
    public let itemID: UUID
    public let assetID: String
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var shareItems: [Any] = []
    @State private var isSharePresented: Bool = false
    @State private var isPreparingShare: Bool = false
    @State private var shareStatus: String? = nil

    public init(itemID: UUID, assetID: String) {
        self.itemID = itemID
        self.assetID = assetID
    }

    public var body: some View {
        let palette = model.palette

        VStack(alignment: .leading, spacing: 14) {
            AlbumMediaPane(
                assetID: assetID,
                showsFocusButton: true,
                sceneItemID: itemID,
                showsSceneEditorButtons: true
            )

            HStack(spacing: 12) {
                Button {
                    Task { await prepareAndPresentShare() }
                } label: {
                    Label(isPreparingShare ? "Preparing…" : "Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.copyButtonFill)
                .foregroundStyle(palette.copyIconColor)
                .disabled(isPreparingShare)

                if let shareStatus, !shareStatus.isEmpty {
                    Text(shareStatus)
                        .font(.caption2)
                        .foregroundStyle(palette.panelSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
#if canImport(UIKit)
        .sheet(isPresented: $isSharePresented) {
            AlbumShareSheet(items: shareItems)
        }
#endif
    }

    private func prepareAndPresentShare() async {
        guard !isPreparingShare else { return }
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        await MainActor.run {
            isPreparingShare = true
            shareStatus = nil
        }
        defer {
            Task { @MainActor in
                isPreparingShare = false
            }
        }

        guard let asset = await MainActor.run(body: { model.asset(for: id) }) else {
            await MainActor.run { shareStatus = "Share failed (asset missing)" }
            return
        }

        if asset.mediaType == .video {
            if let url = await model.requestVideoURL(assetID: id) {
                await MainActor.run {
                    shareItems = [url]
                    isSharePresented = true
                }
                return
            }
            await MainActor.run { shareStatus = "Share failed (video unavailable)" }
            return
        }

        let target = CGSize(width: 2048, height: 2048)
        guard let image = await model.requestThumbnail(assetID: id, targetSize: target, displayScale: displayScale) else {
            await MainActor.run { shareStatus = "Share failed (image unavailable)" }
            return
        }

#if canImport(UIKit)
        let data: Data
        let fileExt: String
        if let jpg = image.jpegData(compressionQuality: 0.92) {
            data = jpg
            fileExt = "jpg"
        } else if let png = image.pngData() {
            data = png
            fileExt = "png"
        } else {
            await MainActor.run { shareStatus = "Share failed (encode error)" }
            return
        }
#else
        await MainActor.run { shareStatus = "Share unavailable on this platform" }
        return
#endif

        let baseName: String = {
            let raw = (asset.fileName ?? "photo").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = raw.isEmpty ? "photo" : raw
            let noExt = (cleaned as NSString).deletingPathExtension
            let safe = noExt.isEmpty ? "photo" : noExt
            return safe.replacingOccurrences(of: "/", with: "_")
        }()
        let fileName = "\(baseName)_\(UUID().uuidString).\(fileExt)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try data.write(to: url, options: [.atomic])
            await MainActor.run {
                shareItems = [url]
                isSharePresented = true
            }
        } catch {
            await MainActor.run { shareStatus = "Share failed (write error)" }
        }
    }
}

public struct AlbumMovieDraftView: View {
    public let itemID: UUID

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.openWindow) private var openWindow
    @State private var player: AVPlayer? = nil
    @State private var renderStartDate: Date? = nil
    @State private var renderEndDate: Date? = nil
    @State private var lastRenderKind: AlbumMovieRenderState.Kind? = nil
    @State private var isPreparingShare: Bool = false
    @State private var shareStatus: String? = nil

    public init(itemID: UUID) {
        self.itemID = itemID
    }

    public var body: some View {
        let palette = model.palette
        let draft = model.poppedItem(for: itemID)?.movie ?? AlbumMovieDraft()
        let subtitle = draft.draftSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusLines = model.movieStatusLinesByItemID[itemID] ?? []
        let exportableCount = model.poppedItems.filter { $0.kind == .asset }.count
        let isGeneratingTitle = model.movieTitleGenerationInFlightItemIDs.contains(itemID)

        VStack(spacing: 14) {
            TextField(
                "Title",
                text: Binding(
                    get: { model.poppedItem(for: itemID)?.movie?.draftTitle ?? "" },
                    set: { newValue in
                        model.updatePoppedItem(itemID) { item in
                            var movie = item.movie ?? AlbumMovieDraft()
                            movie.draftTitle = newValue
                            movie.titleUserEdited = true
                            item.movie = movie
                        }
                    }
                )
            )
            .font(.title.weight(.semibold))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(palette.panelSecondaryText)
                    .lineLimit(2)
            } else if isGeneratingTitle {
                Text("Generating title…")
                    .font(.callout)
                    .foregroundStyle(palette.panelSecondaryText)
                    .lineLimit(1)
            }

            movieControls(draft: draft, exportableCount: exportableCount)

            switch draft.renderState.kind {
            case .draft:
                if exportableCount == 0 {
                    Text("Add images or videos to the Scene to generate a movie.")
                        .font(.caption)
                        .foregroundStyle(palette.panelSecondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

            case .rendering:
                ProgressView(value: draft.renderState.progress ?? 0, total: 1)
                    .tint(palette.historyButtonColor)

                if !statusLines.isEmpty {
                    statusLogView(statusLines: statusLines, palette: palette)
                }
                elapsedTimerView(renderKind: draft.renderState.kind, palette: palette)

            case .ready:
                moviePreview(draft: draft)

                Button {
                    Task { await prepareAndOpenShareWindowIfReady(draft: draft) }
                } label: {
                    Label(isPreparingShare ? "Preparing…" : "Share Movie", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.copyButtonFill)
                .foregroundStyle(palette.copyIconColor)
                .disabled(isPreparingShare)

                if let shareStatus, !shareStatus.isEmpty {
                    Text(shareStatus)
                        .font(.caption2)
                        .foregroundStyle(palette.panelSecondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

            case .failed:
                if let message = draft.renderState.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(palette.panelSecondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                if !statusLines.isEmpty {
                    statusLogView(statusLines: statusLines, palette: palette)
                }
                elapsedTimerView(renderKind: draft.renderState.kind, palette: palette)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .onChange(of: draft.artifactRelativePath) { _ in
            configurePlayerIfReady()
        }
        .onChange(of: draft.renderState.kind) { newKind in
            let previous = lastRenderKind
            lastRenderKind = newKind

            if newKind == .rendering {
                renderStartDate = Date()
                renderEndDate = nil
            } else if previous == .rendering {
                renderEndDate = Date()
            } else if newKind == .draft {
                renderStartDate = nil
                renderEndDate = nil
            }
        }
        .onAppear {
            configurePlayerIfReady()
            lastRenderKind = draft.renderState.kind
            if draft.renderState.kind == .rendering, renderStartDate == nil {
                renderStartDate = Date()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(palette.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(palette.cardBorder.opacity(0.75), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func movieControls(draft: AlbumMovieDraft, exportableCount: Int) -> some View {
        let palette = model.palette

        let generateDisabled = (exportableCount == 0) || (draft.renderState.kind == .rendering)

        HStack(spacing: 12) {
            Button {
                Task { await model.generateMovie(itemID: itemID) }
            } label: {
                Label("Generate Movie", systemImage: "sparkles.tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.historyButtonColor)
            .foregroundStyle(palette.buttonLabelOnColor)
            .disabled(generateDisabled)
        }
    }

    @ViewBuilder
    private func moviePreview(draft: AlbumMovieDraft) -> some View {
        if let player {
            VideoPlayer(player: player)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.06))
                .frame(height: 420)
                .overlay {
                    Text("Preview unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func configurePlayerIfReady() {
        guard let draft = model.poppedItem(for: itemID)?.movie else { return }
        guard draft.renderState.kind == .ready else {
            player = nil
            return
        }
        guard let url = resolveArtifactURL(draft: draft) else {
            player = nil
            return
        }
        player = AVPlayer(url: url)
        player?.play()
    }

    private func prepareAndOpenShareWindowIfReady(draft: AlbumMovieDraft) async {
#if canImport(UIKit)
        let alreadyPreparing = await MainActor.run { isPreparingShare }
        guard !alreadyPreparing else { return }
        guard draft.renderState.kind == .ready else { return }
        guard let sourceURL = resolveArtifactURL(draft: draft) else { return }

        let fm = FileManager.default
        guard fm.isReadableFile(atPath: sourceURL.path) else {
            await MainActor.run {
                shareStatus = "Share failed (file missing)"
            }
            return
        }

        await MainActor.run {
            isPreparingShare = true
            shareStatus = nil
        }
        defer {
            Task { @MainActor in
                isPreparingShare = false
            }
        }

        let baseName: String = {
            let rawTitle = draft.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = rawTitle.isEmpty ? "Movie" : rawTitle
            let safe = cleaned.replacingOccurrences(of: "/", with: "_")
            return safe.isEmpty ? "Movie" : safe
        }()

        let tempURL = fm.temporaryDirectory.appendingPathComponent("\(baseName)_\(UUID().uuidString).mp4", isDirectory: false)

        do {
            try? fm.removeItem(at: tempURL)
            do {
                try fm.linkItem(at: sourceURL, to: tempURL)
            } catch {
                try fm.copyItem(at: sourceURL, to: tempURL)
            }

            await MainActor.run {
                openWindow(value: AlbumSharePayload(url: tempURL, title: baseName))
            }
        } catch {
            await MainActor.run {
                shareStatus = "Share failed (prepare error)"
            }
        }
#else
        return
#endif
    }

    private func resolveArtifactURL(draft: AlbumMovieDraft) -> URL? {
        guard let relative = draft.artifactRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relative.isEmpty else { return nil }

        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(relative, isDirectory: false)
    }

    private static let statusLogBottomID = "album-movie-status-log-bottom"

    @ViewBuilder
    private func statusLogView(statusLines: [String], palette: AlbumThemePalette) -> some View {
        let indexedLines = Array(statusLines.enumerated())

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(indexedLines, id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.statusLogBottomID)
                }
                .padding(10)
            }
            .onAppear {
                scrollStatusLogToBottom(proxy, statusLines: statusLines)
            }
            .onChange(of: statusLines.count) { _ in
                scrollStatusLogToBottom(proxy, statusLines: statusLines)
            }
        }
        .frame(maxHeight: 220)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.cardBorder.opacity(0.65), lineWidth: 1)
        )
    }

    private func scrollStatusLogToBottom(_ proxy: ScrollViewProxy, statusLines: [String]) {
        guard !statusLines.isEmpty else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.statusLogBottomID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func elapsedTimerView(renderKind: AlbumMovieRenderState.Kind, palette: AlbumThemePalette) -> some View {
        switch renderKind {
        case .rendering:
            if let renderStartDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(renderStartDate))
                    Text("Elapsed: \(formatElapsed(elapsed))")
                        .font(.caption2)
                        .foregroundStyle(palette.panelSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .failed:
            if let renderStartDate, let renderEndDate {
                let elapsed = max(0, renderEndDate.timeIntervalSince(renderStartDate))
                Text("Elapsed: \(formatElapsed(elapsed))")
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .draft, .ready:
            EmptyView()
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(0, seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
