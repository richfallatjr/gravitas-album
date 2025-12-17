import SwiftUI

enum AlbumCurvedLayoutMath {
    struct ArcLayout: Sendable, Hashable {
        var radius: CGFloat
        var stepRadians: CGFloat
        var angles: [Angle]
    }

    static func arcLayout(
        count: Int,
        maxAngle: Angle,
        desiredChord: CGFloat,
        baseRadius: CGFloat,
        minRadius: CGFloat,
        maxRadius: CGFloat? = nil,
        minimumStep: Angle = .zero
    ) -> ArcLayout {
        guard count > 0 else {
            return ArcLayout(radius: max(minRadius, baseRadius), stepRadians: 0, angles: [])
        }

        let safeDesiredChord = max(1, desiredChord)
        let safeMinR = max(1, minRadius)
        var radius = max(safeMinR, baseRadius)

        let allowedStepRadians: CGFloat = count > 1 ? CGFloat(maxAngle.radians) / CGFloat(count - 1) : 0
        let minimumStepRadians = max(0, CGFloat(minimumStep.radians))

        if allowedStepRadians > 0 {
            let denom = 2 * CGFloat(sin(Double(allowedStepRadians / 2)))
            if denom > 0 {
                let requiredRadius = safeDesiredChord / denom
                radius = max(radius, requiredRadius)
            }
        }

        if let maxRadius {
            radius = min(radius, max(1, maxRadius))
        }

        let chordRatio = min(CGFloat(0.999), safeDesiredChord / (2 * radius))
        let stepAtRadius = 2 * CGFloat(asin(Double(chordRatio)))
        let stepRadians = max(minimumStepRadians, min(stepAtRadius, allowedStepRadians > 0 ? allowedStepRadians : stepAtRadius))

        let centeredOffset = CGFloat(count - 1) / 2
        let angles: [Angle] = (0..<count).map { idx in
            Angle(radians: Double((CGFloat(idx) - centeredOffset) * stepRadians))
        }

        return ArcLayout(radius: radius, stepRadians: stepRadians, angles: angles)
    }
}
