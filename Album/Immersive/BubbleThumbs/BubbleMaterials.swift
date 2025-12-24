import RealityKit

#if canImport(UIKit)
import UIKit
#endif

public enum BubbleMaterials {
    public static func makeBubbleMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()

#if canImport(UIKit)
        m.baseColor = .init(tint: UIColor.white.withAlphaComponent(0.03))
#else
        m.baseColor = .init(tint: .white.withAlphaComponent(0.03))
#endif
        m.metallic = .init(floatLiteral: 0.0)
        m.roughness = .init(floatLiteral: 0.18)

        m.clearcoat = .init(floatLiteral: 1.0)
        m.clearcoatRoughness = .init(floatLiteral: 0.03)

        m.blending = .transparent(opacity: 1.0)
        return m
    }

    public static func makeThumbMaterial(texture: TextureResource) -> UnlitMaterial {
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        // Opaque avoids transparent sorting/depth issues with the bubble shell.
        m.blending = .opaque
        return m
    }
}
