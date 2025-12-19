import SwiftUI

public struct AlbumCurvedLayoutMetrics: Sendable, Hashable {
    public var baseRadius: CGFloat
    public var minRadius: CGFloat
    public var maxRadius: CGFloat?
    public var itemSize: CGSize
    public var itemSpacing: CGFloat
    public var maxAngle: Angle
    public var minimumStep: Angle
    public var verticalOffset: CGFloat
    public var perspective: CGFloat
    public var minDepthScale: CGFloat
    public var selectedScale: CGFloat
    public var minOpacity: Double

    public init(
        baseRadius: CGFloat = 700,
        minRadius: CGFloat = 240,
        maxRadius: CGFloat? = nil,
        itemSize: CGSize = CGSize(width: 180, height: 180),
        itemSpacing: CGFloat = 26,
        maxAngle: Angle = .degrees(110),
        minimumStep: Angle = .degrees(0),
        verticalOffset: CGFloat = 0,
        perspective: CGFloat = 0.75,
        minDepthScale: CGFloat = 0.62,
        selectedScale: CGFloat = 1.06,
        minOpacity: Double = 0.55
    ) {
        self.baseRadius = baseRadius
        self.minRadius = minRadius
        self.maxRadius = maxRadius
        self.itemSize = itemSize
        self.itemSpacing = itemSpacing
        self.maxAngle = maxAngle
        self.minimumStep = minimumStep
        self.verticalOffset = verticalOffset
        self.perspective = perspective
        self.minDepthScale = minDepthScale
        self.selectedScale = selectedScale
        self.minOpacity = minOpacity
    }
}

public struct AlbumCurvedLayoutView: View {
    public let items: [AlbumCurvedLayoutItem]
    public let mode: AlbumCurvedLayoutMode

    private let externalSelectedID: Binding<AlbumCurvedLayoutItem.ID?>?
    @State private var internalSelectedID: AlbumCurvedLayoutItem.ID?

    private let metrics: AlbumCurvedLayoutMetrics
    private let pageLabel: String?
    private let onPrevPage: (() -> Void)?
    private let onNextPage: (() -> Void)?
    private let onSelect: ((AlbumCurvedLayoutItem.ID?) -> Void)?
    private let onPopOut: ((AlbumCurvedLayoutItem.ID) -> Void)?
    private let onHide: ((AlbumCurvedLayoutItem.ID) -> Void)?
    private let onDelete: ((AlbumCurvedLayoutItem.ID) -> Void)?
    private let onThumb: ((AlbumCurvedLayoutThumbFeedback, AlbumCurvedLayoutItem.ID) -> Void)?
    private let thumbnailViewProvider: (AlbumCurvedLayoutItem) -> AnyView

    public init(
        items: [AlbumCurvedLayoutItem],
        mode: AlbumCurvedLayoutMode,
        selectedID: Binding<AlbumCurvedLayoutItem.ID?>? = nil,
        initiallySelectedID: AlbumCurvedLayoutItem.ID? = nil,
        metrics: AlbumCurvedLayoutMetrics = .init(),
        pageLabel: String? = nil,
        onPrevPage: (() -> Void)? = nil,
        onNextPage: (() -> Void)? = nil,
        onSelect: ((AlbumCurvedLayoutItem.ID?) -> Void)? = nil,
        onPopOut: ((AlbumCurvedLayoutItem.ID) -> Void)? = nil,
        onHide: ((AlbumCurvedLayoutItem.ID) -> Void)? = nil,
        onDelete: ((AlbumCurvedLayoutItem.ID) -> Void)? = nil,
        onThumb: ((AlbumCurvedLayoutThumbFeedback, AlbumCurvedLayoutItem.ID) -> Void)? = nil,
        thumbnailViewProvider: @escaping (AlbumCurvedLayoutItem) -> AnyView
    ) {
        self.items = items
        self.mode = mode
        self.externalSelectedID = selectedID
        self._internalSelectedID = State(initialValue: initiallySelectedID)
        self.metrics = metrics
        self.pageLabel = pageLabel
        self.onPrevPage = onPrevPage
        self.onNextPage = onNextPage
        self.onSelect = onSelect
        self.onPopOut = onPopOut
        self.onHide = onHide
        self.onDelete = onDelete
        self.onThumb = onThumb
        self.thumbnailViewProvider = thumbnailViewProvider
    }

    private var selectedID: Binding<AlbumCurvedLayoutItem.ID?> {
        externalSelectedID ?? $internalSelectedID
    }

    private var selectedItem: AlbumCurvedLayoutItem? {
        guard let id = selectedID.wrappedValue else { return nil }
        return items.first(where: { $0.id == id })
    }

    public var body: some View {
        VStack(spacing: 14) {
            curvedCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            actionBar

            if mode == .memories {
                pageControls
            }
        }
    }

    private var curvedCanvas: some View {
        GeometryReader { _ in
            let layout = AlbumCurvedLayoutMath.arcLayout(
                count: items.count,
                maxAngle: metrics.maxAngle,
                desiredChord: metrics.itemSize.width + metrics.itemSpacing,
                baseRadius: metrics.baseRadius,
                minRadius: metrics.minRadius,
                maxRadius: metrics.maxRadius,
                minimumStep: metrics.minimumStep
            )

            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = layout.angles.indices.contains(index) ? layout.angles[index] : .zero
                    let isSelected = (item.id == selectedID.wrappedValue)

                    AlbumCurvedLayoutTileView(item: item, isSelected: isSelected, thumbnailView: thumbnailViewProvider(item))
                        .frame(width: metrics.itemSize.width, height: metrics.itemSize.height)
                        .modifier(AlbumCurvedLayoutItemTransform(angle: angle, radius: layout.radius, metrics: metrics, isSelected: isSelected))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID.wrappedValue = item.id
                            onSelect?(item.id)
                        }
                        .animation(.easeInOut(duration: 0.20), value: selectedID.wrappedValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedItem?.title?.isEmpty == false ? (selectedItem?.title ?? "") : "Select an item")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let subtitle = selectedItem?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let item = selectedItem {
                if let onPopOut {
                    Button {
                        onPopOut(item.id)
                    } label: {
                        Label("Pop Out", systemImage: "rectangle.on.rectangle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let onHide {
                    Button {
                        onHide(item.id)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let onDelete {
                    Button(role: .destructive) {
                        onDelete(item.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let onThumb {
                    Button {
                        onThumb(.up, item.id)
                    } label: {
                        Label("Thumbs up", systemImage: "hand.thumbsup")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button {
                        onThumb(.down, item.id)
                    } label: {
                        Label("Thumbs down", systemImage: "hand.thumbsdown")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var pageControls: some View {
        let hasControls = (onPrevPage != nil) || (onNextPage != nil) || (pageLabel?.isEmpty == false)
        if hasControls {
            let buttonSize: CGFloat = 62
            let cornerRadius: CGFloat = 14
            let backgroundShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            HStack(spacing: 12) {
                Button {
                    onPrevPage?()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 26, weight: .black))
                        .frame(width: buttonSize, height: buttonSize)
                }
                .buttonStyle(.plain)
                .disabled(onPrevPage == nil)
                .background(backgroundShape.fill(.black.opacity(0.06)))
                .overlay {
                    backgroundShape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
                .opacity(onPrevPage == nil ? 0.35 : 1)

                if let label = pageLabel, !label.isEmpty {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    onNextPage?()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 26, weight: .black))
                        .frame(width: buttonSize, height: buttonSize)
                }
                .buttonStyle(.plain)
                .disabled(onNextPage == nil)
                .background(backgroundShape.fill(.black.opacity(0.06)))
                .overlay {
                    backgroundShape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
                .opacity(onNextPage == nil ? 0.35 : 1)
            }
            .padding(.bottom, 2)
        }
    }
}

private struct AlbumCurvedLayoutItemTransform: ViewModifier {
    let angle: Angle
    let radius: CGFloat
    let metrics: AlbumCurvedLayoutMetrics
    let isSelected: Bool

    func body(content: Content) -> some View {
        let theta = angle.radians
        let x = CGFloat(sin(theta)) * radius
        let z = CGFloat(cos(theta)) * radius - radius

        let denom = max(1, radius * 1.6)
        let depthScale = max(metrics.minDepthScale, min(1.0, 1 + (z / denom)))
        let selectedScale: CGFloat = isSelected ? metrics.selectedScale : 1.0

        return content
            .scaleEffect(depthScale * selectedScale)
            .rotation3DEffect(angle, axis: (x: 0, y: 1, z: 0), perspective: metrics.perspective)
            .offset(x: x, y: metrics.verticalOffset)
            .opacity(isSelected ? 1.0 : max(metrics.minOpacity, Double(depthScale)))
            .zIndex(Double(depthScale))
    }
}
