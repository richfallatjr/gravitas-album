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
    public var lockRoll: Bool

    public init(
        follow: WeakEntityRef,
        diameterMeters: Float,
        zBiasTowardHead: Float = 0,
        flipFacing: Bool = false,
        lockRoll: Bool = false
    ) {
        self.follow = follow
        self.diameterMeters = diameterMeters
        self.zBiasTowardHead = zBiasTowardHead
        self.flipFacing = flipFacing
        self.lockRoll = lockRoll
    }
}

public enum DiscBillboardSystem {
    /// Update order requirement:
    /// - Call AFTER the simulation updates positions.
    /// - Call BEFORE any mesh swap/flipbook (optional).
    @MainActor
    public static func update(root: Entity, head: Entity, dt: Float) -> Int {
        let headPos = head.position(relativeTo: root)
        let headQ = head.orientation(relativeTo: root)

        let noRollQ: simd_quatf = {
            let worldUp = SIMD3<Float>(0, 1, 0)

            // Camera forward is local -Z.
            var fwd = headQ.act(SIMD3<Float>(0, 0, -1))
            if simd_length_squared(fwd) < 1e-8 { fwd = SIMD3<Float>(0, 0, -1) }
            fwd = simd_normalize(fwd)

            var right = simd_cross(worldUp, fwd)
            if simd_length_squared(right) < 1e-8 {
                right = simd_cross(SIMD3<Float>(1, 0, 0), fwd)
            }
            right = simd_normalize(right)
            let up = simd_normalize(simd_cross(fwd, right))

            // Ensure local -Z points forward by making local +Z point backward.
            let back = -fwd
            let m = simd_float3x3(columns: (right, up, back))
            return simd_quatf(m)
        }()

        var stack: [Entity] = [root]
        stack.reserveCapacity(512)
        var updatedCount = 0

        while let e = stack.popLast() {
            if var bb = e.components[DiscBillboard.self],
               let target = bb.follow.entity {
                updatedCount += 1
                let pinPos = target.position(relativeTo: root)

                var toHead = headPos - pinPos
                let l2 = simd_length_squared(toHead)
                if l2 > 1e-8 {
                    toHead = simd_normalize(toHead)

                    let biasedPos = pinPos + (toHead * bb.zBiasTowardHead)
                    e.setPosition(biasedPos, relativeTo: root)

                    var q = bb.lockRoll ? noRollQ : headQ
                    if bb.flipFacing {
                        let fix = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
                        q = q * fix
                    }
                    e.setOrientation(q, relativeTo: root)

                    let d = max(0.0001, bb.diameterMeters)
                    e.scale = SIMD3<Float>(d, d, 1)
                } else {
                    e.setPosition(pinPos, relativeTo: root)

                    var q = bb.lockRoll ? noRollQ : headQ
                    if bb.flipFacing {
                        let fix = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
                        q = q * fix
                    }
                    e.setOrientation(q, relativeTo: root)

                    let d = max(0.0001, bb.diameterMeters)
                    e.scale = SIMD3<Float>(d, d, 1)
                }

                e.components.set(bb)
            }

            if !e.children.isEmpty {
                stack.append(contentsOf: e.children)
            }
        }

        return updatedCount
    }
}
