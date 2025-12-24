import RealityKit

public struct BubbleFlipbook: Component, Sendable {
    public var fps: Float
    public var frameCount: Int
    public var frame: Int
    public var acc: Float

    public init(fps: Float, frameCount: Int = 8) {
        self.fps = max(0, fps)
        self.frameCount = 8
        self.frame = 0
        self.acc = 0
    }
}

public enum BubbleFlipbookSystem {
    public static func update(root: Entity, dt: Float) {
        let frames: [MeshResource]
        do {
            frames = try BubbleThumbDiscMesh.atlasFrameDiscs(cols: 4, rows: 2, segments: 64)
        } catch {
            AlbumLog.immersive.error("BubbleFlipbookSystem atlasFrameDiscs failed error=\(String(describing: error), privacy: .public)")
            return
        }

        var stack: [Entity] = Array(root.children)
        stack.reserveCapacity(256)

        while let current = stack.popLast() {
            if var fb = current.components[BubbleFlipbook.self],
               fb.fps > 0,
               let me = current as? ModelEntity {
                fb.acc += dt * fb.fps
                let steps = Int(fb.acc.rounded(.down))
                if steps > 0 {
                    fb.acc -= Float(steps)
                    fb.frame = (fb.frame + steps) % 8

                    if var model = me.model, fb.frame >= 0, fb.frame < frames.count {
                        model.mesh = frames[fb.frame]
                        me.model = model
                    }
                    current.components.set(fb)
                }
            }

            if !current.children.isEmpty {
                stack.append(contentsOf: current.children)
            }
        }
    }
}
