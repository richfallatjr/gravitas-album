import SwiftUI

extension View {
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat) -> some View {
        if #available(visionOS 1.0, iOS 17.0, macOS 14.0, *) {
            self.glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

