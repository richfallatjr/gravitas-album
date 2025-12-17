import SwiftUI

enum CurvedLayoutMath {
    static func angles(count: Int, maxAngle: Angle, itemSpacing: CGFloat, itemWidth: CGFloat, radius: CGFloat) -> [Angle] {
        guard count > 0 else { return [] }

        let safeRadius = max(radius, 1)
        let stepRadians = (itemWidth + itemSpacing) / safeRadius
        let totalRadians = stepRadians * CGFloat(max(0, count - 1))
        let clampedTotal = min(totalRadians, CGFloat(maxAngle.radians))
        let actualStep = count > 1 ? (clampedTotal / CGFloat(count - 1)) : 0
        let start = -clampedTotal / 2

        return (0..<count).map { idx in
            Angle(radians: Double(start + actualStep * CGFloat(idx)))
        }
    }
}

