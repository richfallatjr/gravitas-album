import SwiftUI

public struct AlbumHistoryList: View {
    public let historyAssetIDs: [String]
    public let recommendedAssetIDs: [String]
    public let aiNextAssetIDs: Set<String>
    public let feedbackByAssetID: [String: AlbumThumbFeedback]
    public let currentAssetID: String?
    public let onSelect: (String) -> Void
    @EnvironmentObject private var model: AlbumModel

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
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .foregroundStyle(palette.panelPrimaryText)
        .frame(maxHeight: .infinity, alignment: .top)
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
                    Text(model.semanticHandle(for: assetID))
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

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
        }
    }
}
