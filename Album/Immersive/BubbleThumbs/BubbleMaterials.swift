import RealityKit
import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum BubbleMaterials {
    private static var cachedRimMask: TextureResource? = nil
    private static var didLogRimMaskFailure: Bool = false

    public static func makeBubbleMaterial() -> PhysicallyBasedMaterial {
#if canImport(UIKit)
        if let rimMask = loadRimMaskTexture() {
            let brand = UIColor(
                red: CGFloat(0x78) / 255.0,
                green: CGFloat(0xDC) / 255.0,
                blue: CGFloat(0xE8) / 255.0,
                alpha: 1.0
            )
            return makeBubbleGlassMaterial(rimMask: rimMask, rimColor: brand)
        }
#endif

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

#if canImport(UIKit)
    public static func makeBubbleGlassMaterial(
        rimMask: TextureResource,
        rimColor: UIColor,
        maxRimAlpha: CGFloat = 0.22,
        coat: Float = 1.0,
        coatRough: Float = 0.03
    ) -> PhysicallyBasedMaterial {
        var pbr = PhysicallyBasedMaterial()

        pbr.baseColor = .init(
            tint: rimColor.withAlphaComponent(maxRimAlpha),
            texture: .init(rimMask)
        )

        pbr.metallic = .init(floatLiteral: 0.0)
        pbr.roughness = .init(floatLiteral: 0.18)
        pbr.clearcoat = .init(floatLiteral: coat)
        pbr.clearcoatRoughness = .init(floatLiteral: coatRough)

        pbr.blending = .transparent(opacity: 1.0)
        return pbr
    }
#endif

    public static func makeThumbMaterial(texture: TextureResource) -> UnlitMaterial {
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        // Opaque avoids transparent sorting/depth issues with the bubble shell.
        m.blending = .opaque
        return m
    }

    private static func loadRimMaskTexture() -> TextureResource? {
        if let cachedRimMask { return cachedRimMask }

        do {
            let url = try BubbleFresnelMask.ensureMaskURL()
            let tex = try TextureResource.load(contentsOf: url)
            cachedRimMask = tex
            return tex
        } catch {
            if !didLogRimMaskFailure {
                didLogRimMaskFailure = true
                AlbumLog.immersive.error("BubbleMaterials rim mask load failed error=\(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }
}
