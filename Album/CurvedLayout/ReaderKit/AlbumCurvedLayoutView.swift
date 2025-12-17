import SwiftUI
import CurvedLayoutKit

public struct AlbumCurvedLayoutItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let mediaType: AlbumMediaType
    public let title: String
    public let isFavorite: Bool

    public init(id: String, mediaType: AlbumMediaType, title: String, isFavorite: Bool) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.isFavorite = isFavorite
    }
}

public struct AlbumCurvedLayoutView: View {
    public let items: [AlbumCurvedLayoutItem]
    @Binding public var selectedID: String?
    public let mode: AlbumPanelMode

    public let pageLabel: String?
    public let onPrev: (() -> Void)?
    public let onNext: (() -> Void)?
    public let prevEnabled: Bool
    public let nextEnabled: Bool

    public let thumbnailProvider: (String) async -> AlbumImage?

    public let onSelect: (String) -> Void
    public let onPopOut: (String) -> Void
    public let onThumbUp: (String) -> Void
    public let onThumbDown: (String) -> Void
    public let onHide: (String) -> Void

    public init(
        items: [AlbumCurvedLayoutItem],
        selectedID: Binding<String?>,
        mode: AlbumPanelMode,
        pageLabel: String? = nil,
        onPrev: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        prevEnabled: Bool = true,
        nextEnabled: Bool = true,
        thumbnailProvider: @escaping (String) async -> AlbumImage?,
        onSelect: @escaping (String) -> Void,
        onPopOut: @escaping (String) -> Void,
        onThumbUp: @escaping (String) -> Void,
        onThumbDown: @escaping (String) -> Void,
        onHide: @escaping (String) -> Void
    ) {
        self.items = items
        self._selectedID = selectedID
        self.mode = mode
        self.pageLabel = pageLabel
        self.onPrev = onPrev
        self.onNext = onNext
        self.prevEnabled = prevEnabled
        self.nextEnabled = nextEnabled
        self.thumbnailProvider = thumbnailProvider
        self.onSelect = onSelect
        self.onPopOut = onPopOut
        self.onThumbUp = onThumbUp
        self.onThumbDown = onThumbDown
        self.onHide = onHide
    }

    public var body: some View {
        VStack(spacing: 14) {
            if mode == .memories, (onPrev != nil || onNext != nil || pageLabel != nil) {
                HStack(spacing: 12) {
                    if let onPrev {
                        Button("Prev", action: onPrev)
                            .buttonStyle(.bordered)
                            .disabled(!prevEnabled)
                    }

                    if let pageLabel {
                        Text(pageLabel.isEmpty ? " " : pageLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let onNext {
                        Button("Next", action: onNext)
                            .buttonStyle(.bordered)
                            .disabled(!nextEnabled)
                    }

                    Spacer(minLength: 0)
                }
            }

            CurvedCanvasView(items: items, selectedID: $selectedID, mode: .arc, onSelect: { id in
                onSelect(id)
            }) { item, isSelected in
                AlbumCurvedLayoutCard(
                    item: item,
                    isSelected: isSelected,
                    thumbnailProvider: thumbnailProvider,
                    onPopOut: onPopOut,
                    onThumbUp: onThumbUp,
                    onThumbDown: onThumbDown,
                    onHide: onHide
                )
            }
        }
    }
}

private struct AlbumCurvedLayoutCard: View {
    let item: AlbumCurvedLayoutItem
    let isSelected: Bool
    let thumbnailProvider: (String) async -> AlbumImage?
    let onPopOut: (String) -> Void
    let onThumbUp: (String) -> Void
    let onThumbDown: (String) -> Void
    let onHide: (String) -> Void

    @State private var image: AlbumImage? = nil

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack {
            if let image {
#if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
#elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
#endif
            } else {
                shape.fill(.black.opacity(0.08))
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                if item.mediaType == .video {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            Text(item.title)
                .font(.caption2)
                .lineLimit(2)
                .foregroundStyle(.primary)
                .shadow(radius: 8)
                .padding(10)
        }
        .background {
            shape
                .fill(.black.opacity(0.06))
                .overlay {
                    if isSelected {
                        shape.strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .clipShape(shape)
        .contextMenu {
            Button("Pop Out") { onPopOut(item.id) }
            Button("Thumb Up") { onThumbUp(item.id) }
            Button("Thumb Down") { onThumbDown(item.id) }
            Button("Hide", role: .destructive) { onHide(item.id) }
        }
        .task(id: item.id) {
            image = await thumbnailProvider(item.id)
        }
    }
}
