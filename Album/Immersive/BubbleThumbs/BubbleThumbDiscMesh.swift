import RealityKit
import simd

public enum BubbleThumbDiscMesh {
    private static var cachedUnit: MeshResource?
    private static var cachedAtlasFrames: [AtlasKey: [MeshResource]] = [:]

    public struct AtlasKey: Hashable, Sendable {
        public let cols: Int
        public let rows: Int
        public let segments: Int

        public init(cols: Int, rows: Int, segments: Int) {
            self.cols = cols
            self.rows = rows
            self.segments = segments
        }
    }

    public static func unitDisc(segments: Int = 64) throws -> MeshResource {
        if let cachedUnit { return cachedUnit }
        let mesh = try disc(radius: 0.5, segments: segments, u0: 0, v0: 0, u1: 1, v1: 1)
        cachedUnit = mesh
        return mesh
    }

    public static func atlasFrameDiscs(cols: Int, rows: Int, segments: Int = 64) throws -> [MeshResource] {
        let key = AtlasKey(cols: cols, rows: rows, segments: segments)
        if let cached = cachedAtlasFrames[key] { return cached }

        let c = max(1, cols)
        let r = max(1, rows)
        let du = 1.0 / Float(c)
        let dv = 1.0 / Float(r)

        var meshes: [MeshResource] = []
        meshes.reserveCapacity(c * r)

        for row in 0..<r {
            for col in 0..<c {
                let u0 = du * Float(col)
                let u1 = u0 + du

                let v1 = 1.0 - dv * Float(row)
                let v0 = v1 - dv

                let mesh = try disc(radius: 0.5, segments: segments, u0: u0, v0: v0, u1: u1, v1: v1)
                meshes.append(mesh)
            }
        }

        cachedAtlasFrames[key] = meshes
        return meshes
    }

    private static func disc(radius: Float, segments: Int, u0: Float, v0: Float, u1: Float, v1: Float) throws -> MeshResource {
        let seg = max(3, segments)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        positions.append([0, 0, 0])
        normals.append([0, 0, 1])
        uvs.append([(u0 + u1) * 0.5, (v0 + v1) * 0.5])

        for i in 0...seg {
            let t = Float(i) / Float(seg)
            let a = t * 2 * .pi
            let x = cos(a) * radius
            let y = sin(a) * radius

            positions.append([x, y, 0])
            normals.append([0, 0, 1])

            let pu = (x / (2 * radius)) + 0.5
            let pv = (y / (2 * radius)) + 0.5

            let uu = u0 + pu * (u1 - u0)
            let vv = v0 + pv * (v1 - v0)
            uvs.append([uu, vv])
        }

        for i in 1...seg {
            indices += [0, UInt32(i), UInt32(i + 1)]
        }

        // two-sided: add backface triangles with reversed winding
        for i in 1...seg {
            indices += [0, UInt32(i + 1), UInt32(i)]
        }

        var md = MeshDescriptor()
        md.positions = .init(positions)
        md.normals = .init(normals)
        md.textureCoordinates = .init(uvs)
        md.primitives = .triangles(indices)

        return try MeshResource.generate(from: [md])
    }
}
