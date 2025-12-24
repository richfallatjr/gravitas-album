import RealityKit

public enum BubbleThumbFactory {
    private static let discName: String = "BubbleThumbDisc"
    private static let revealDelayNs: UInt64 = 100_000_000

    @MainActor
    public static func upgradeBall(
        ball: ModelEntity,
        itemID: String,
        sphereRadiusMeters: Float,
        media: BubbleMediaSource
    ) async {
        if var model = ball.model {
            model.materials = [BubbleMaterials.makeBubbleMaterial()]
            ball.model = model
        }

        let disc: ModelEntity = {
            if let existing = ball.children.first(where: { $0.name == discName }) as? ModelEntity {
                return existing
            }

            let mesh: MeshResource = {
                do {
                    return try BubbleThumbDiscMesh.unitDisc(segments: 64)
                } catch {
                    AlbumLog.immersive.error("BubbleThumbFactory disc mesh failed itemID=\(itemID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    return .generatePlane(width: 1, depth: 1)
                }
            }()

            var placeholder = UnlitMaterial(color: .white)
            placeholder.blending = .transparent(opacity: 0.0)
            let entity = ModelEntity(mesh: mesh, materials: [placeholder])
            entity.name = discName
            entity.position = .zero
            ball.addChild(entity)
            return entity
        }()

        let discDiameter = max(0.001, sphereRadiusMeters * 2 * 0.92)
        disc.scale = SIMD3<Float>(discDiameter, discDiameter, 1)
        disc.components[BubbleBillboard.self] = nil
        disc.components.set(
            DiscBillboard(
                follow: WeakEntityRef(ball),
                diameterMeters: discDiameter,
                zBiasTowardHead: 0,
                flipFacing: false
            )
        )

        switch media {
        case .photo(let source):
            do {
                let texture = try await BubbleMediaCache.getOrCreateStaticThumbTexture(itemID: itemID, photoSource: source)
                guard ball.parent != nil, disc.parent != nil else { return }

                var mat = BubbleMaterials.makeThumbMaterial(texture: texture)
                mat.blending = .transparent(opacity: 0.0)
                if var model = disc.model {
                    model.materials = [mat]
                    if let full = try? BubbleThumbDiscMesh.unitDisc(segments: 64) {
                        model.mesh = full
                    }
                    disc.model = model
                }
                disc.components[BubbleFlipbook.self] = nil

                Task { @MainActor [weak disc] in
                    try? await Task.sleep(nanoseconds: revealDelayNs)
                    guard let disc, disc.parent != nil else { return }
                    if var model = disc.model {
                        model.materials = [BubbleMaterials.makeThumbMaterial(texture: texture)]
                        disc.model = model
                    }
                }
            } catch {
                AlbumLog.immersive.error(
                    "BubbleThumbFactory static thumb failed itemID=\(itemID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }

        case .video(let source):
            do {
                let result = try await BubbleMediaCache.getOrCreateAnimatedAtlasTexture(itemID: itemID, videoSource: source)
                guard ball.parent != nil, disc.parent != nil else { return }

                var mat = BubbleMaterials.makeThumbMaterial(texture: result.texture)
                mat.blending = .transparent(opacity: 0.0)

                if var model = disc.model {
                    model.materials = [mat]
                    if let frames = try? BubbleThumbDiscMesh.atlasFrameDiscs(cols: result.cfg.cols, rows: result.cfg.rows, segments: 64),
                       !frames.isEmpty {
                        model.mesh = frames[0]
                    }
                    disc.model = model
                }

                disc.components.set(BubbleFlipbook(fps: result.cfg.fps, frameCount: result.cfg.frameCount))

                Task { @MainActor [weak disc] in
                    try? await Task.sleep(nanoseconds: revealDelayNs)
                    guard let disc, disc.parent != nil else { return }
                    if var model = disc.model {
                        model.materials = [BubbleMaterials.makeThumbMaterial(texture: result.texture)]
                        disc.model = model
                    }
                }
            } catch {
                AlbumLog.immersive.error(
                    "BubbleThumbFactory animated atlas failed itemID=\(itemID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
