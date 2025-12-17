import SwiftUI
import RealityKit
import simd
import UIKit

private enum AlbumSlot: CaseIterable {
    case recent
    case favorites
    case videos
    case random

    var basePosition: SIMD3<Float> {
        switch self {
        case .recent:    return SIMD3<Float>( 0.0,  0.20, 0)
        case .favorites: return SIMD3<Float>(-0.35, 0.00, 0)
        case .videos:    return SIMD3<Float>( 0.35, 0.00, 0)
        case .random:    return SIMD3<Float>( 0.0, -0.20, 0)
        }
    }

    static func slot(for asset: AlbumAsset) -> AlbumSlot {
        if asset.isFavorite { return .favorites }
        if asset.mediaType == .video { return .videos }
        if asset.creationDate != nil { return .recent }
        return .random
    }
}

public struct AlbumImmersiveRootView: View {
    @EnvironmentObject private var sim: AlbumModel

    @State private var anchor: AnchorEntity?
    @State private var pmns = [ModelEntity]()
    @State private var balls = [ModelEntity]()
    @State private var assetIDByEntity: [ObjectIdentifier: String] = [:]

    @State private var lastTs: Date = .init()
    @State private var accum: Float = 0
    @State private var nextPMN: Int = 0

    private let G: Float = 1
    private let soft: Float = 0.05
    private let maxA: Float = 1
    private let wander: Float = 0.10
    private let maxS: Float = 1.25
    private let minS: Float = 0.005

    private let steelMat = SimpleMaterial(
        color: UIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1),
        roughness: 0.24,
        isMetallic: true
    )

    private let videoGlowMat = UnlitMaterial(
        color: UIColor(red: 1.0, green: 0.92, blue: 0.30, alpha: 1)
    )

    private let palette: [UIColor] = [
        .init(red: 1.00, green: 0.38, blue: 0.53, alpha: 1),
        .init(red: 0.66, green: 0.86, blue: 0.46, alpha: 1),
        .init(red: 1.00, green: 0.85, blue: 0.40, alpha: 1),
        .init(red: 0.47, green: 0.86, blue: 0.91, alpha: 1),
        .init(red: 0.67, green: 0.62, blue: 0.95, alpha: 1)
    ]

    private let videoHaloTint = UIColor(red: 1, green: 0.6, blue: 0, alpha: 1)

    private let baseDnRadius: Float = 0.02
    private let maxDnScaleMultiplier: Float = 2.5

    private let simulationOrigin = SIMD3<Float>(0, 1.5, -2.5)

    public init() {}

    public var body: some View {
        RealityView { content in
            if anchor == nil { buildScene(in: content) }
        }
        .gesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in handleTap(on: value.entity) }
        )
        .onChange(of: sim.absorbNowRequestID) {
            Task { @MainActor in
                accum = 0
                absorbOne()
            }
        }
        .onChange(of: sim.tuningDeltaRequest) {
            guard let req = sim.tuningDeltaRequest else { return }
            Task { @MainActor in
                applyTuningDeltas(req.deltas)
            }
        }
        .onChange(of: sim.assets) {
            Task { @MainActor in
                respawnFromCurrentAssets()
            }
        }
    }

    // MARK: Scene setup

    @MainActor
    private func buildScene(in content: RealityViewContent) {
        let world = AnchorEntity(world: simulationOrigin)
        anchor = world
        content.add(world)

        pmns = makePMNs(parent: world)
        lastTs = Date()

        Task { @MainActor in
            respawnFromCurrentAssets()
        }

        Task.detached { [weak world] in
            while world != nil {
                await MainActor.run { frameStep() }
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }
    }

    @MainActor
    private func respawnFromCurrentAssets() {
        guard let root = anchor else { return }

        for ball in balls {
            ball.removeFromParent()
        }
        balls.removeAll(keepingCapacity: true)
        assetIDByEntity.removeAll(keepingCapacity: true)

        let assets = sim.assets
        guard !assets.isEmpty else { return }

        let dates = assets.compactMap(\.creationDate).sorted()
        let minDate = dates.first
        let maxDate = dates.last
        let denom = max(1, (maxDate?.timeIntervalSinceReferenceDate ?? 1) - (minDate?.timeIntervalSinceReferenceDate ?? 0))

        for asset in assets {
            let slot = AlbumSlot.slot(for: asset)

            let t: Double
            if let d = asset.creationDate, let minDate, let maxDate, minDate != maxDate {
                t = (d.timeIntervalSinceReferenceDate - minDate.timeIntervalSinceReferenceDate) / denom
            } else {
                t = 0.5
            }
            let normalized = Float(max(0, min(1, t)))
            spawn(asset, basePosition: slot.basePosition, recency: normalized, root: root)
        }
    }

    @MainActor
    private func spawn(_ asset: AlbumAsset, basePosition: SIMD3<Float>, recency: Float, root: Entity) {
        let isVideo = asset.mediaType == .video
        let mats: [RealityKit.Material] = isVideo ? [videoGlowMat] : [steelMat]

        let ball = ModelEntity(mesh: .generateSphere(radius: baseDnRadius), materials: mats)
        let jitter = SIMD3<Float>(
            .random(in: -0.15...0.15),
            .random(in: -0.15...0.15),
            .random(in: -0.15...0.15)
        )

        ball.position = basePosition + jitter
        ball.components.set(AlbumVelocityComponent(v: SIMD3<Float>(
            .random(in: -0.3...0.3),
            .random(in: -0.3...0.3),
            .random(in: -0.3...0.3)
        )))

        let favoriteBonus: Float = asset.isFavorite ? 0.25 : 0
        let scaleMultiplier = 1 + (recency + favoriteBonus) * (maxDnScaleMultiplier - 1)
        ball.scale = SIMD3<Float>(repeating: scaleMultiplier)

        let baseMass: Float = 1.0 + recency * 1.5 + favoriteBonus
        ball.components.set(AlbumDataNodeTuningComponent(mass: baseMass, accelerationMultiplier: 1.0))

        ball.generateCollisionShapes(recursive: false)
        ball.components.set(InputTargetComponent())

        balls.append(ball)
        root.addChild(ball)
        assetIDByEntity[ObjectIdentifier(ball)] = asset.localIdentifier

        if isVideo { ball.addChild(makeHalo(videoHaloTint)) }
    }

    // MARK: Tap handling

    @MainActor
    private func handleTap(on entity: Entity) {
        if let assetID = assetIDByEntity[ObjectIdentifier(entity)] {
            sim.currentAssetID = assetID
        }

        guard let model = entity as? ModelEntity, balls.contains(model) else { return }

        let tint = palette.randomElement() ?? .white
        model.model?.materials = [UnlitMaterial(color: tint)]

        if let halo = model.children.first(where: { $0.name == "halo" }) as? ModelEntity {
            halo.model?.materials = [makeHaloMaterial(tint)]
        } else {
            model.addChild(makeHalo(tint))
        }
    }

    // MARK: Frame loop

    @MainActor
    private func frameStep() {
        guard let root = anchor else { return }
        var dt = Float(Date().timeIntervalSince(lastTs))
        if dt <= 0 { dt = 1 / 60 }
        dt = min(dt, 1 / 30)
        lastTs = Date()
        accum += dt

        if !sim.isPaused {
            physicsStep(dt: dt, root: root)
        }

        if accum >= Float(sim.absorbInterval) {
            accum = 0
            absorbOne()
        }
    }

    private func physicsStep(dt: Float, root: Entity) {
        let sources = pmns.compactMap { e -> (SIMD3<Float>, Float)? in
            guard let m = e.components[AlbumPMNComponent.self]?.mass else { return nil }
            return (e.position(relativeTo: root), m)
        }

        let softSquared = soft * soft

        for b in balls {
            var v = b.components[AlbumVelocityComponent.self]?.v ?? .zero
            let p = b.position(relativeTo: root)

            let tuning = b.components[AlbumDataNodeTuningComponent.self] ?? .init()
            let mass = max(tuning.mass, 0.05)
            let accelMul = max(tuning.accelerationMultiplier, 0.05)

            let accelFactor = sqrt(accelMul)
            let baselineMassForCaps: Float = 3.0
            let massFactor = sqrt(max(mass / baselineMassForCaps, 1.0))
            let maxAForBall = min(maxA * 12, (maxA * accelFactor) / massFactor)
            let maxSForBall = min(maxS * 12, (maxS * accelFactor) / massFactor)

            var force = SIMD3<Float>.zero
            for (src, m) in sources {
                let r = src - p
                let r2 = max(simd_length_squared(r), softSquared)
                let invR = 1 / sqrt(r2)
                let invR3 = invR / r2
                force += r * (G * m * invR3)
            }
            var a = (force / mass) * accelMul
            if length(a) > maxAForBall { a = normalize(a) * maxAForBall }

            a += SIMD3<Float>(
                .random(in: -wander...wander),
                .random(in: -wander...wander),
                .random(in: -wander...wander)
            )

            v += a * dt
            let s = length(v)
            if s < minS {
                v = normalize(SIMD3<Float>(
                    .random(in: -1...1),
                    .random(in: -1...1),
                    .random(in: -1...1)
                )) * minS
            } else if s > maxSForBall {
                v *= maxSForBall / s
            }

            b.position += v * dt
            b.components.set(AlbumVelocityComponent(v: v))
        }
    }

    // MARK: Absorb

    @MainActor
    private func absorbOne() {
        guard let root = anchor, !balls.isEmpty else { return }
        let pmn = pmns[nextPMN % pmns.count]
        nextPMN += 1

        let centre = pmn.position(relativeTo: root)
        let alreadySeen = Set(sim.historyAssetIDs)
        let proximityWindowSize = 5

        struct Candidate {
            let id: ObjectIdentifier
            let dist: Float
            let speed: Float
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(balls.count)

        for ball in balls {
            let id = ObjectIdentifier(ball)
            let dist = distance(ball.position(relativeTo: root), centre)
            let v = ball.components[AlbumVelocityComponent.self]?.v ?? .zero
            candidates.append(.init(id: id, dist: dist, speed: length(v)))
        }

        candidates.sort(by: { $0.dist < $1.dist })

        while !candidates.isEmpty {
            let windowEnd = min(proximityWindowSize, candidates.count)
            let window = candidates[0..<windowEnd]

            guard let chosen = window.min(by: { $0.speed < $1.speed }) else { return }
            guard let chosenIndex = candidates.firstIndex(where: { $0.id == chosen.id }) else { return }
            candidates.remove(at: chosenIndex)

            guard let idx = balls.firstIndex(where: { ObjectIdentifier($0) == chosen.id }) else { continue }
            let victim = balls[idx]
            victim.removeFromParent()
            balls.remove(at: idx)

            guard let assetID = assetIDByEntity.removeValue(forKey: chosen.id) else { continue }
            if alreadySeen.contains(assetID) { continue }

            sim.currentAssetID = assetID
            break
        }
    }

    // MARK: Tuning deltas

    @MainActor
    private func applyTuningDeltas(_ deltas: [AlbumItemTuningDelta]) {
        guard !deltas.isEmpty else { return }

        var assetIDToBall: [String: ModelEntity] = [:]
        assetIDToBall.reserveCapacity(balls.count)

        for ball in balls {
            if let assetID = assetIDByEntity[ObjectIdentifier(ball)] {
                assetIDToBall[assetID] = ball
            }
        }

        let minMass: Float = 0.05
        let maxMass: Float = 80.0
        let minAccelMul: Float = 0.05
        let maxAccelMul: Float = 120.0

        for delta in deltas {
            guard let ball = assetIDToBall[delta.itemID] else { continue }
            var tuning = ball.components[AlbumDataNodeTuningComponent.self] ?? .init()
            tuning.mass = min(maxMass, max(minMass, tuning.mass * delta.massMultiplier))
            tuning.accelerationMultiplier = min(maxAccelMul, max(minAccelMul, tuning.accelerationMultiplier * delta.accelerationMultiplier))
            ball.components.set(tuning)
        }
    }

    // MARK: Helpers

    private func makePMNs(parent: Entity) -> [ModelEntity] {
        let spec: [(AlbumSlot, Float)] = [
            (.recent, 20),
            (.favorites, 12),
            (.videos, 15),
            (.random, 14)
        ]
        return spec.map { slot, mass in
            let e = ModelEntity(
                mesh: .generateSphere(radius: 0.03),
                materials: [SimpleMaterial(color: .white, roughness: 0.8, isMetallic: false)]
            )
            e.position = slot.basePosition
            e.components.set(AlbumPMNComponent(mass: mass))
            parent.addChild(e)
            return e
        }
    }

    private func makeHaloMaterial(_ tint: UIColor) -> UnlitMaterial {
        var mat = UnlitMaterial(color: tint.withAlphaComponent(0.22))
        mat.blending = .transparent(opacity: 0.33)
        return mat
    }

    private func makeHalo(_ tint: UIColor) -> ModelEntity {
        let e = ModelEntity(mesh: .generateSphere(radius: 0.027), materials: [makeHaloMaterial(tint)])
        e.name = "halo"
        return e
    }
}
