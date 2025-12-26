import RealityKit
import simd

public enum BubblePlanarUVSphereMesh {
    private struct Key: Hashable, Sendable {
        var radius: Float
        var rings: Int
        var segments: Int
    }

    private static var cached: [Key: MeshResource] = [:]
    private static var didLogFailure: Bool = false

    public static func sphere(radius: Float, rings: Int = 24, segments: Int = 48) -> MeshResource {
        let key = Key(radius: radius, rings: rings, segments: segments)
        if let cached = cached[key] { return cached }

        do {
            let mesh = try generateSphere(radius: radius, rings: rings, segments: segments)
            cached[key] = mesh
            return mesh
        } catch {
            if !didLogFailure {
                didLogFailure = true
                AlbumLog.immersive.error("BubblePlanarUVSphereMesh generate failed error=\(String(describing: error), privacy: .public)")
            }
            return .generateSphere(radius: radius)
        }
    }

    private static func generateSphere(radius rawRadius: Float, rings rawRings: Int, segments rawSegments: Int) throws -> MeshResource {
        let radius = max(0.000_1, rawRadius)
        let rings = max(6, rawRings)
        let segments = max(8, rawSegments)

        let vertCount = (rings + 1) * (segments + 1)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(vertCount)
        normals.reserveCapacity(vertCount)
        uvs.reserveCapacity(vertCount)

        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let theta = v * .pi
            let sinTheta = sin(theta)
            let cosTheta = cos(theta)

            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let phi = u * 2 * .pi
                let sinPhi = sin(phi)
                let cosPhi = cos(phi)

                let nx = cosPhi * sinTheta
                let ny = cosTheta
                let nz = sinPhi * sinTheta

                positions.append([nx * radius, ny * radius, nz * radius])
                normals.append([nx, ny, nz])

                // Planar projection in local X/Y for a stable radial rim mask.
                let uu = nx * 0.5 + 0.5
                let vv = ny * 0.5 + 0.5
                uvs.append([uu, vv])
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(rings * segments * 6)

        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = ring * (segments + 1) + segment
                let b = a + (segments + 1)
                let c = a + 1
                let d = b + 1
                indices += [UInt32(a), UInt32(b), UInt32(c), UInt32(c), UInt32(b), UInt32(d)]
            }
        }

        var md = MeshDescriptor()
        md.positions = .init(positions)
        md.normals = .init(normals)
        md.textureCoordinates = .init(uvs)
        md.primitives = .triangles(indices)

        return try MeshResource.generate(from: [md])
    }
}
