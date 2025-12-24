import RealityKit

public struct BubbleBillboard: Component, Sendable {
    public init() {}
}

public enum BubbleBillboardSystem {
    public static func update(root: Entity, cameraEntity: Entity) {
        let cameraPos = cameraEntity.position(relativeTo: nil)
        var stack: [Entity] = Array(root.children)
        stack.reserveCapacity(256)

        while let current = stack.popLast() {
            if current.components[BubbleBillboard.self] != nil {
                let p = current.position(relativeTo: nil)
                current.look(at: cameraPos, from: p, relativeTo: nil)
            }

            if !current.children.isEmpty {
                stack.append(contentsOf: current.children)
            }
        }
    }
}
