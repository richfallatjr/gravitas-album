import SwiftUI

public enum CurvedCanvasMode: Sendable {
    case arc
}

public struct CurvedCanvasMetrics: Sendable, Hashable {
    public var radius: CGFloat
    public var itemSize: CGSize
    public var itemSpacing: CGFloat
    public var maxAngle: Angle
    public var verticalOffset: CGFloat

    public init(
        radius: CGFloat = 700,
        itemSize: CGSize = CGSize(width: 180, height: 180),
        itemSpacing: CGFloat = 26,
        maxAngle: Angle = .degrees(110),
        verticalOffset: CGFloat = 0
    ) {
        self.radius = radius
        self.itemSize = itemSize
        self.itemSpacing = itemSpacing
        self.maxAngle = maxAngle
        self.verticalOffset = verticalOffset
    }
}

public struct CurvedCanvasView<Item: Identifiable, ItemView: View>: View {
    public let items: [Item]
    @Binding public var selectedID: Item.ID?
    public var mode: CurvedCanvasMode
    public var metrics: CurvedCanvasMetrics
    public var onSelect: ((Item.ID) -> Void)?
    public var content: (Item, Bool) -> ItemView

    public init(
        items: [Item],
        selectedID: Binding<Item.ID?>,
        mode: CurvedCanvasMode = .arc,
        metrics: CurvedCanvasMetrics = .init(),
        onSelect: ((Item.ID) -> Void)? = nil,
        @ViewBuilder content: @escaping (Item, Bool) -> ItemView
    ) {
        self.items = items
        self._selectedID = selectedID
        self.mode = mode
        self.metrics = metrics
        self.onSelect = onSelect
        self.content = content
    }

    public var body: some View {
        GeometryReader { _ in
            let angles = CurvedLayoutMath.angles(
                count: items.count,
                maxAngle: metrics.maxAngle,
                itemSpacing: metrics.itemSpacing,
                itemWidth: metrics.itemSize.width,
                radius: metrics.radius
            )

            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = angles.indices.contains(index) ? angles[index] : .zero
                    let isSelected = (item.id == selectedID)

                    content(item, isSelected)
                        .frame(width: metrics.itemSize.width, height: metrics.itemSize.height)
                        .modifier(CurvedItemTransform(angle: angle, metrics: metrics, isSelected: isSelected))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = item.id
                            onSelect?(item.id)
                        }
                        .animation(.easeInOut(duration: 0.20), value: selectedID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CurvedItemTransform: ViewModifier {
    let angle: Angle
    let metrics: CurvedCanvasMetrics
    let isSelected: Bool

    func body(content: Content) -> some View {
        let theta = CGFloat(angle.radians)
        let x = sin(theta) * metrics.radius
        let z = cos(theta) * metrics.radius - metrics.radius

        let depthScale = max(0.62, min(1.0, 1 + (z / (metrics.radius * 1.6))))
        let selectedScale: CGFloat = isSelected ? 1.06 : 1.0

        return content
            .scaleEffect(depthScale * selectedScale)
            .rotation3DEffect(angle, axis: (x: 0, y: 1, z: 0), perspective: 0.75)
            .offset(x: x, y: metrics.verticalOffset)
            .opacity(isSelected ? 1.0 : max(0.55, Double(depthScale)))
            .zIndex(Double(depthScale))
    }
}
