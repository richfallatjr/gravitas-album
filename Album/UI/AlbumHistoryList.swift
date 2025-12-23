import SwiftUI

public struct AlbumHistoryList: View {
    public let historyAssetIDs: [String]
    public let recommendedAssetIDs: [String]
    public let aiNextAssetIDs: Set<String>
    public let feedbackByAssetID: [String: AlbumThumbFeedback]
    public let currentAssetID: String?
    public let onSelect: (String) -> Void
    @EnvironmentObject private var model: AlbumModel
    @State private var lastAutoFocusedAssetID: String? = nil
    @State private var lastHistoryCount: Int = 0

    public init(
        historyAssetIDs: [String],
        recommendedAssetIDs: [String],
        aiNextAssetIDs: Set<String>,
        feedbackByAssetID: [String: AlbumThumbFeedback],
        currentAssetID: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.historyAssetIDs = historyAssetIDs
        self.recommendedAssetIDs = recommendedAssetIDs
        self.aiNextAssetIDs = aiNextAssetIDs
        self.feedbackByAssetID = feedbackByAssetID
        self.currentAssetID = currentAssetID
        self.onSelect = onSelect
    }

    public var body: some View {
        let palette = model.palette
        let recommendationsToShow: [String] = {
            guard !recommendedAssetIDs.isEmpty else { return [] }
            let historyIDs = Set(historyAssetIDs)
            var used = Set<String>()
            used.reserveCapacity(min(recommendedAssetIDs.count, 16))
            var result: [String] = []
            result.reserveCapacity(min(recommendedAssetIDs.count, 16))

            for id in recommendedAssetIDs {
                guard used.insert(id).inserted else { continue }
                guard !historyIDs.contains(id) else { continue }
                result.append(id)
            }
            return result
        }()

        VStack(alignment: .leading, spacing: 10) {
            Text("History")
                .font(.headline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !recommendationsToShow.isEmpty {
                            SectionHeader(title: "Recommended")
                            ForEach(recommendationsToShow, id: \.self) { id in
                                HistoryRow(
                                    assetID: id,
                                    isActive: id == currentAssetID,
                                    isAINext: aiNextAssetIDs.contains(id),
                                    kind: .recommendation,
                                    feedback: feedbackByAssetID[id],
                                    onSelect: { onSelect(id) }
                                )
                                .id(id)
                            }
                        }

                        SectionHeader(title: "Absorbed")
                        ForEach(historyAssetIDs.reversed(), id: \.self) { id in
                            HistoryRow(
                                assetID: id,
                                isActive: id == currentAssetID,
                                isAINext: aiNextAssetIDs.contains(id),
                                kind: .history,
                                feedback: feedbackByAssetID[id],
                                onSelect: { onSelect(id) }
                            )
                            .id(id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    lastHistoryCount = historyAssetIDs.count
                    guard let id = historyAssetIDs.last else { return }
                    focusHistory(assetID: id, proxy: proxy, animated: false)
                }
                .onChange(of: historyAssetIDs) { newIDs in
                    defer { lastHistoryCount = newIDs.count }
                    guard newIDs.count > lastHistoryCount else { return }
                    guard let id = newIDs.last else { return }
                    focusHistory(assetID: id, proxy: proxy, animated: true)
                }
            }
        }
        .foregroundStyle(palette.panelPrimaryText)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func focusHistory(assetID: String, proxy: ScrollViewProxy, animated: Bool) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard lastAutoFocusedAssetID != id else { return }
        lastAutoFocusedAssetID = id

        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(id, anchor: .top)
            }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private struct SectionHeader: View {
        let title: String
        @EnvironmentObject private var model: AlbumModel

        var body: some View {
            Text(title)
                .font(.caption)
                .foregroundStyle(model.palette.panelSecondaryText)
                .padding(.top, 6)
        }
    }

    private struct HistoryRow: View {
        enum Kind {
            case history
            case recommendation
        }

        let assetID: String
        let isActive: Bool
        let isAINext: Bool
        let kind: Kind
        let feedback: AlbumThumbFeedback?
        let onSelect: () -> Void

        @EnvironmentObject private var model: AlbumModel
        @State private var faceTokens: [String] = []

        private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        private var indicatorColor: Color? {
            let palette = model.palette
            switch feedback {
            case .up:
                return palette.readButtonColor
            case .down:
                return palette.toggleFillColor
            case nil:
                return nil
            }
        }

        var body: some View {
            let palette = model.palette
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    historyTitle

                    HStack(spacing: 10) {
                        if let asset = model.asset(for: assetID) {
                            Text(asset.mediaType == .video ? "Video" : "Photo")
                            if asset.isFavorite { Text("★") }
                            if let ym = model.createdYearMonth(for: asset) { Text(ym) }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape
                        .fill(isActive ? palette.copyButtonFill.opacity(0.18) : palette.navBackground)
                        .overlay {
                            if kind == .history, let indicatorColor {
                                shape.fill(indicatorColor.opacity(0.10))
                            }
                        }
                }
                .overlay {
                    if let strokeColor = indicatorColor {
                        shape.strokeBorder(strokeColor, lineWidth: 2)
                    }
                    if kind == .recommendation {
                        shape.strokeBorder(palette.historyButtonColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isAINext {
                        Text("AI")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.navBackground, in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(palette.navBorder.opacity(0.7), lineWidth: 1)
                            )
                            .padding(8)
                    }
                }
            }
            .buttonStyle(.plain)
            .task(id: assetID) {
                faceTokens = await model.faceClusterTokens(for: assetID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .albumFaceIndexDidUpdate).receive(on: RunLoop.main)) { _ in
                Task { @MainActor in
                    faceTokens = await model.faceClusterTokens(for: assetID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .albumFaceHierarchyDidUpdate).receive(on: RunLoop.main)) { _ in
                Task { @MainActor in
                    faceTokens = await model.faceClusterTokens(for: assetID)
                }
            }
        }

        private var historyTitle: some View {
            let summary = model.semanticHandle(for: assetID)
            let title = faceTokens.isEmpty ? summary : "\(facePrefix(faceTokens)) | \(summary)"
            return Text(title)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }

        private func facePrefix(_ faceIDs: [String]) -> String {
            let maxShown = 4
            let shown = Array(faceIDs.prefix(maxShown))
            let overflow = max(0, faceIDs.count - shown.count)
            if overflow > 0 {
                return "faces:\(shown.joined(separator: ","))+\(overflow)"
            }
            return "faces:\(shown.joined(separator: ","))"
        }
    }
}
