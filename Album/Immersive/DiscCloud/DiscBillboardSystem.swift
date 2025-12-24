import RealityKit
import simd

public struct WeakEntityRef {
    private final class Box {
        weak var entity: Entity?
        init(_ entity: Entity?) { self.entity = entity }
    }

    private let box: Box

    public init(_ entity: Entity?) {
        self.box = Box(entity)
    }

    public var entity: Entity? { box.entity }
}

/// Runtime-only component: make a disc follow a target and face the head.
public struct DiscBillboard: Component {
    public var follow: WeakEntityRef
    public var diameterMeters: Float
    public var zBiasTowardHead: Float
    public var flipFacing: Bool

    public init(
        follow: WeakEntityRef,
        diameterMeters: Float,
        zBiasTowardHead: Float = 0,
        flipFacing: Bool = false
    ) {
        self.follow = follow
        self.diameterMeters = diameterMeters
        self.zBiasTowardHead = zBiasTowardHead
        self.flipFacing = flipFacing
    }
}

public enum DiscBillboardSystem {
    /// Update order requirement:
    /// - Call AFTER the simulation updates positions.
    /// - Call BEFORE any mesh swap/flipbook (optional).
    @MainActor
    public static func update(root: Entity, head: Entity, dt: Float) {
        // Use world space for head + targets to avoid anchor-space mismatches.
        let headPos = head.position(relativeTo: nil)

        var stack: [Entity] = [root]
        stack.reserveCapacity(512)

        while let e = stack.popLast() {
            if var bb = e.components[DiscBillboard.self],
               let target = bb.follow.entity {
                let pinPos = target.position(relativeTo: nil)

                var toHead = headPos - pinPos
                let l2 = simd_length_squared(toHead)
                if l2 > 1e-8 {
                    toHead = simd_normalize(toHead)

                    let biasedPos = pinPos + (toHead * bb.zBiasTowardHead)
                    e.setPosition(biasedPos, relativeTo: nil)

                    let forward = toHead
                    let worldUp = SIMD3<Float>(0, 1, 0)

                    var right = simd_cross(worldUp, forward)
                    if simd_length_squared(right) < 1e-8 {
                        right = simd_cross(SIMD3<Float>(1, 0, 0), forward)
                    }
                    right = simd_normalize(right)
                    let up = simd_normalize(simd_cross(forward, right))

                    let rot = simd_float3x3(columns: (right, up, forward))
                    var q = simd_quatf(rot)

                    if bb.flipFacing {
                        let fix = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
                        q = q * fix
                    }

                    e.setOrientation(q, relativeTo: nil)

                    let d = max(0.0001, bb.diameterMeters)
                    e.scale = SIMD3<Float>(d, d, 1)
                } else {
                    e.setPosition(pinPos, relativeTo: nil)
                }

                e.components.set(bb)
            }

            if !e.children.isEmpty {
                stack.append(contentsOf: e.children)
            }
        }
    }
}
