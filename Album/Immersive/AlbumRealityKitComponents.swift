import RealityKit
import simd

public struct AlbumPMNComponent: Component, Codable {
    public var mass: Float
    public init(mass: Float) { self.mass = mass }
}

public struct AlbumVelocityComponent: Component {
    public var v: SIMD3<Float> = .zero
    public init(v: SIMD3<Float> = .zero) { self.v = v }
}

public struct AlbumDataNodeTuningComponent: Component, Codable {
    public var mass: Float
    public var accelerationMultiplier: Float

    public init(mass: Float = 1, accelerationMultiplier: Float = 1) {
        self.mass = mass
        self.accelerationMultiplier = accelerationMultiplier
    }
}

