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
        case .recent:    return SIMD3<Float>(0.0, 0.20, 0)
        case .favorites: return SIMD3<Float>(-0.35, 0.00, 0)
        case .videos:    return SIMD3<Float>(0.35, 0.00, 0)
        case .random:    return SIMD3<Float>(0.0, -0.20, 0)
        }
    }

    static func slot(for asset: AlbumAsset) -> AlbumSlot {
        if asset.isFavorite { return .favorites }
        if asset.mediaType == .video { return .videos }
        if asset.creationDate != nil { return .recent }
        return .random
    }
}

private enum AlbumCurvedWallAttachmentID {
    static func tile(_ assetID: String) -> String { "album-curved-wall-tile|\(assetID)" }

    static let close = "album-curved-wall-close"
    static let prev = "album-curved-wall-prev"
    static let next = "album-curved-wall-next"
}

public struct AlbumImmersiveRootView: View {
    @EnvironmentObject private var sim: AlbumModel
    @State private var scene = AlbumImmersiveSceneState()

    private let anchorOffset = SIMD3<Float>(0, 1.524, -3.0)

    public init() {}

    public var body: some View {
        RealityView { content, attachments in
            scene.ensureBuilt(in: content, model: sim, anchorOffset: anchorOffset)
            scene.syncCurvedWall(in: content, using: attachments, model: sim, panels: curvedWallVisiblePanels)
        } update: { content, attachments in
            scene.syncCurvedWall(in: content, using: attachments, model: sim, panels: curvedWallVisiblePanels)
        } attachments: {
            if sim.curvedCanvasEnabled {
                ForEach(curvedWallVisiblePanels, id: \.id) { panel in
                    Attachment(id: AlbumCurvedWallAttachmentID.tile(panel.assetID)) {
                        AlbumCurvedWallPanelAttachmentView(assetID: panel.assetID, viewHeightPoints: panel.viewHeightPoints)
                            .environmentObject(sim)
                    }
                }

                Attachment(id: AlbumCurvedWallAttachmentID.prev) {
                    AlbumCurvedWallNavCardAttachmentView(direction: .prev, enabled: sim.curvedWallCanPageBack) {
                        AlbumLog.immersive.info("CurvedWall nav prev pressed (enabled=\(self.sim.curvedWallCanPageBack))")
                        sim.curvedWallPageBack()
                    }
                }

                Attachment(id: AlbumCurvedWallAttachmentID.next) {
                    AlbumCurvedWallNavCardAttachmentView(direction: .next, enabled: sim.curvedWallCanPageForward) {
                        AlbumLog.immersive.info("CurvedWall nav next pressed (enabled=\(self.sim.curvedWallCanPageForward))")
                        sim.curvedWallPageForward()
                    }
                }

                Attachment(id: AlbumCurvedWallAttachmentID.close) {
                    AlbumCurvedWallCloseAttachmentView {
                        AlbumLog.immersive.info("CurvedWall close pressed")
                        sim.curvedCanvasEnabled = false
                    }
                }
            }
        }
        .simultaneousGesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in scene.handleTap(on: value.entity, model: sim) }
        )
        .onChange(of: sim.absorbNowRequestID) {
            Task { @MainActor in
                AlbumLog.immersive.info("AbsorbNow requested")
                scene.absorbNow(model: sim)
            }
        }
        .onChange(of: sim.tuningDeltaRequest) {
            guard let req = sim.tuningDeltaRequest else { return }
            Task { @MainActor in
                AlbumLog.immersive.info("Applying tuning deltas: \(req.deltas.count)")
                scene.applyTuningDeltas(req.deltas)
            }
        }
        .onChange(of: sim.assets) {
            Task { @MainActor in
                AlbumLog.immersive.info("Assets changed; respawning entities. assets=\(self.sim.assets.count)")
                scene.respawnFromCurrentAssets(model: sim)
            }
        }
        .onChange(of: sim.isPaused) { _, newValue in
            AlbumLog.immersive.info("Pause state changed: \(newValue ? "paused" : "playing", privacy: .public)")
        }
        .onChange(of: sim.curvedCanvasEnabled) { _, newValue in
            AlbumLog.immersive.info("Curved wall toggled: \(newValue ? "enabled" : "disabled", privacy: .public) mode=\(self.sim.panelMode.rawValue, privacy: .public) panels=\(self.curvedWallVisiblePanels.count)")
        }
        .onDisappear {
            scene.stop()
        }
    }

    private var curvedWallVisiblePanels: [AlbumModel.CurvedWallPanel] {
        let raw = sim.curvedWallVisiblePanels
        guard !raw.isEmpty else { return [] }
        return raw.filter { panel in
            let trimmed = panel.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard !sim.hiddenIDs.contains(trimmed) else { return false }
            guard sim.item(for: trimmed) != nil else { return false }
            return true
        }
    }
}

	@MainActor
	private final class AlbumImmersiveSceneState {
	    private var anchor: AnchorEntity?
	    private var headAnchor: AnchorEntity?
	    private var latestHeadTransform: Transform?
	    private var initialHeadTransform: Transform?
	    private var curvedWallAnchor: AnchorEntity?
	    private var curvedWallSeedMatrix: simd_float4x4?
	    private var pmns: [ModelEntity] = []
	    private var balls: [ModelEntity] = []
	    private var frameTask: Task<Void, Never>?
	    private var lastCurvedWallLogSignature: String?
	    private var lastCurvedWallAttachmentLogSignature: String?

    private var lastTs: Date = Date()
    private var accum: Float = 0
    private var nextPMN: Int = 0

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

    deinit {
        frameTask?.cancel()
    }

	    func stop() {
	        frameTask?.cancel()
	        frameTask = nil
	        anchor = nil
	        headAnchor = nil
	        latestHeadTransform = nil
	        initialHeadTransform = nil
	        curvedWallAnchor = nil
	        curvedWallSeedMatrix = nil
	        pmns.removeAll(keepingCapacity: true)
	        balls.removeAll(keepingCapacity: true)
	        lastCurvedWallLogSignature = nil
	        lastCurvedWallAttachmentLogSignature = nil
	        lastTs = Date()
        accum = 0
        nextPMN = 0
    }

	    func ensureBuilt(in content: RealityViewContent, model: AlbumModel, anchorOffset: SIMD3<Float>) {
	        if let head = headAnchor {
	            if head.parent == nil {
	                content.add(head)
	            }
	        } else {
	            let head = AnchorEntity(.head)
	            head.name = "album-head-anchor"
	            headAnchor = head
	            content.add(head)
	        }

	        updateHeadTransformCache()
	        if initialHeadTransform == nil {
	            initialHeadTransform = latestHeadTransform
	        }

	        if let existingAnchor = anchor {
	            if existingAnchor.parent != nil {
	                startFrameLoopIfNeeded(model: model)
	                return
            }
            AlbumLog.immersive.info("World anchor stale; rebuilding from head pose")
            anchor = nil
            pmns.removeAll(keepingCapacity: true)
            balls.removeAll(keepingCapacity: true)
        }

        AlbumLog.immersive.info("Building immersive scene")
        let seeded = seededWorldAnchorTransform(anchorOffset: anchorOffset)
        let world = AnchorEntity(world: seeded.matrix)
        world.orientation = seeded.rotation
        world.name = "album-world-anchor"
        anchor = world
        content.add(world)

        pmns = makePMNs(parent: world)
        lastTs = Date()
        respawnFromCurrentAssets(model: model)
        startFrameLoopIfNeeded(model: model)
    }

	    private func updateHeadTransformCache() {
	        guard let headAnchor else { return }
	        latestHeadTransform = Transform(matrix: headAnchor.transformMatrix(relativeTo: nil))
	        if initialHeadTransform == nil {
	            initialHeadTransform = latestHeadTransform
	        }
	    }

    private func seededWorldAnchorTransform(anchorOffset: SIMD3<Float>) -> Transform {
        let head = latestHeadTransform ?? Transform(matrix: headAnchor?.transformMatrix(relativeTo: nil) ?? matrix_identity_float4x4)
        let fcol = head.matrix.columns.2
        let forward = normalize(-SIMD3<Float>(fcol.x, fcol.y, fcol.z))
        let left = normalize(cross(SIMD3<Float>(0, 1, 0), forward))
        let distance = -anchorOffset.z

        var pos = head.translation + forward * distance + left * anchorOffset.x
        if !pos.y.isFinite || abs(pos.y) <= 0.001 {
            pos.y = anchorOffset.y
        } else {
            pos.y -= 0.05
        }

        var seeded = head
        seeded.translation = pos
        return seeded
    }

    func respawnFromCurrentAssets(model: AlbumModel) {
        guard let root = anchor else { return }

        for ball in balls {
            ball.removeFromParent()
        }
        balls.removeAll(keepingCapacity: true)

        let assets = model.assets
        AlbumLog.immersive.info("Respawn requested. assets=\(assets.count)")
        guard !assets.isEmpty else { return }

        let dates = assets.compactMap(\.creationDate).sorted()
        let minDate = dates.first
        let maxDate = dates.last
        let denom = max(1, (maxDate?.timeIntervalSinceReferenceDate ?? 1) - (minDate?.timeIntervalSinceReferenceDate ?? 0))

        for asset in assets {
            let slot = AlbumSlot.slot(for: asset)

            model.ensureVisionSummary(for: asset.id, reason: "sim_spawn", priority: .utility)

            let t: Double
            if let d = asset.creationDate, let minDate, let maxDate, minDate != maxDate {
                t = (d.timeIntervalSinceReferenceDate - minDate.timeIntervalSinceReferenceDate) / denom
            } else {
                t = 0.5
            }
            let normalized = Float(max(0, min(1, t)))
            spawn(asset, basePosition: slot.basePosition, recency: normalized, root: root)
        }

        AlbumLog.immersive.info("Respawn complete. entities=\(self.balls.count)")
    }

    func handleTap(on entity: Entity, model: AlbumModel) {
        var cursor: Entity? = entity
        while let current = cursor {
            if let assetID = current.components[AlbumAssetIDComponent.self]?.assetID,
               !assetID.isEmpty {
                AlbumLog.immersive.info("Tap select assetID=\(assetID, privacy: .public)")
                model.currentAssetID = assetID

                if let modelEntity = current as? ModelEntity, balls.contains(where: { $0 == modelEntity }) {
                    let tint = palette.randomElement() ?? .white
                    modelEntity.model?.materials = [UnlitMaterial(color: tint)]

                    if let halo = modelEntity.children.first(where: { $0.name == "halo" }) as? ModelEntity {
                        halo.model?.materials = [makeHaloMaterial(tint)]
                    } else {
                        modelEntity.addChild(makeHalo(tint))
                    }
                }

                return
            }

            cursor = current.parent
        }
    }

    func absorbNow(model: AlbumModel) {
        accum = 0
        absorbOne(model: model)
    }

    func applyTuningDeltas(_ deltas: [AlbumItemTuningDelta]) {
        guard !deltas.isEmpty else { return }

        var assetIDToBall: [String: ModelEntity] = [:]
        assetIDToBall.reserveCapacity(balls.count)

        for ball in balls {
            if let assetID = ball.components[AlbumAssetIDComponent.self]?.assetID {
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

    // MARK: Curved wall placement

    private struct CurvedWallArcLayout: Sendable {
        var radius: Float
        var step: Float
        var angles: [Float]
    }

    private func curvedWallArcLayout(count: Int, desiredChord: Float) -> CurvedWallArcLayout {
        let panelDepthOffset: Float = 0.03
        let targetPanelDistance: Float = 0.25
        let arcSpacingRadians: Float = .pi / 18
        let maxFanRadians: Float = .pi * (160.0 / 180.0)
        let canonicalTotalSlots: Int = 12
        let minRadiusMeters: Float = 0.90
        let maxArcRadius: Float = 2.1

        guard count > 0 else {
            return CurvedWallArcLayout(radius: max(minRadiusMeters, targetPanelDistance + panelDepthOffset), step: 0, angles: [])
        }

        let safeChord = max(0.001, desiredChord)
        let canonicalStep = maxFanRadians / Float(max(1, canonicalTotalSlots - 1))
        let baseRadius = min(
            maxArcRadius,
            max(minRadiusMeters, safeChord / max(0.001, 2 * sinf(canonicalStep / 2)))
        )

        var radius = max(minRadiusMeters, targetPanelDistance + 0.08)
        var slotStep: Float = 0
        var angles: [Float] = []

        func centeredAngles(step: Float) -> [Float] {
            let centeredOffset = Float(count - 1) / 2
            return (0..<count).map { (Float($0) - centeredOffset) * step }
        }

        if count <= canonicalTotalSlots {
            radius = max(radius, baseRadius)
            slotStep = canonicalStep
            angles = centeredAngles(step: canonicalStep)
        } else if count > 1 {
            let allowedStep = maxFanRadians / Float(count - 1)
            let stepAtRadius = 2 * asinf(min(0.999, safeChord / (2 * radius)))
            var step = max(arcSpacingRadians, stepAtRadius)

            if step > allowedStep {
                let requiredR = safeChord / (2 * sinf(allowedStep / 2))
                radius = min(maxArcRadius, max(radius, requiredR))
                step = allowedStep
            } else {
                let requiredR = safeChord / (2 * sinf(step / 2))
                radius = min(maxArcRadius, max(radius, requiredR))
            }

            slotStep = step
            angles = centeredAngles(step: slotStep)
        } else {
            slotStep = canonicalStep
            radius = max(radius, targetPanelDistance + 0.20)
            angles = [0]
        }

        return CurvedWallArcLayout(radius: radius, step: slotStep, angles: angles)
    }

    func syncCurvedWall(in content: RealityViewContent, using attachments: RealityViewAttachments, model: AlbumModel, panels: [AlbumModel.CurvedWallPanel]) {
        updateHeadTransformCache()

        let signature = "enabled=\(model.curvedCanvasEnabled) mode=\(model.panelMode.rawValue) panels=\(panels.count) first=\(panels.first?.assetID ?? "-") last=\(panels.last?.assetID ?? "-") dump=\(model.curvedWallDumpIndex)/\(model.curvedWallDumpPages.count) mem=\(model.memoryPageStartIndex)/\(model.memoryWindowItems.count)"
        if signature != lastCurvedWallLogSignature {
            lastCurvedWallLogSignature = signature
            AlbumLog.immersive.info("CurvedWall sync \(signature, privacy: .public)")
        }

        guard model.curvedCanvasEnabled else {
            if let wallAnchor = curvedWallAnchor {
                removeCurvedWallEntities(from: wallAnchor)
                wallAnchor.removeFromParent()
                curvedWallAnchor = nil
            }
            return
        }

        let root = ensureCurvedWallAnchor(in: content, model: model)

        let pointsPerMeter: Float = 780
        let panelWidthPoints: Float = 620
        let neighborGapMeters: Float = 0.0005
        let panelDepthOffset: Float = 0.03
        let pageSpacing: Float = 0.001
        let columnMaxHeight: Float = 2.4

        let pages = panels
        let layoutColumns = curvedWallColumns(for: pages, maxColumnHeight: columnMaxHeight, pageSpacing: pageSpacing)
        let columns = layoutColumns.columns
        let heights = layoutColumns.heights

        let columnCount = columns.count

        let panelWidthMeters = panelWidthPoints / pointsPerMeter
        let desiredChord = panelWidthMeters + neighborGapMeters
        let layout = curvedWallArcLayout(count: columnCount, desiredChord: desiredChord)

        let validTileAttachmentIDs = Set(pages.map { AlbumCurvedWallAttachmentID.tile($0.assetID) })
        var tilesFound = 0

        for (columnIndex, column) in columns.enumerated() {
            let angle = columnIndex < layout.angles.count ? layout.angles[columnIndex] : (Float(columnIndex) * layout.step)
            let sine = sinf(angle)
            let cosine = cosf(angle)
            let horizontalOffset = sine * layout.radius
            let depthOffset = -cosine * layout.radius - panelDepthOffset
            let totalHeight = columnIndex < heights.count ? heights[columnIndex] : 0

            var yCursor = -totalHeight / 2

            for (itemOffset, pageIndex) in column.enumerated() {
                guard pageIndex >= 0, pageIndex < pages.count else { continue }
                let page = pages[pageIndex]
                let attachmentID = AlbumCurvedWallAttachmentID.tile(page.assetID)
                guard let panel = attachments.entity(for: attachmentID) else { continue }
                tilesFound += 1

                let yMid = yCursor + page.heightMeters / 2

                let forward = normalize(SIMD3<Float>(-horizontalOffset, 0, -depthOffset))
                let right = normalize(cross(SIMD3<Float>(0, 1, 0), forward))
                let up = cross(forward, right)

                var transform = panel.transform
                transform.translation = [horizontalOffset, yMid, depthOffset]
                transform.rotation = simd_quatf(float3x3(columns: (right, up, forward)))
                panel.transform = transform
                panel.name = attachmentID
                panel.components.set(AlbumAssetIDComponent(assetID: page.assetID))

                if panel.components[InputTargetComponent.self] == nil {
                    panel.components.set(InputTargetComponent())
                }
                if panel.components[CollisionComponent.self] == nil {
                    panel.generateCollisionShapes(recursive: true)
                }

                if panel.parent != root {
                    root.addChild(panel)
                }

                yCursor = yMid + page.heightMeters / 2
                if itemOffset != column.count - 1 {
                    yCursor += pageSpacing
                }
            }
        }

        for child in root.children {
            guard child.name.hasPrefix("album-curved-wall-tile|") else { continue }
            guard !validTileAttachmentIDs.contains(child.name) else { continue }
            child.removeFromParent()
        }

        if pages.isEmpty {
            removeTileChildren(from: root)
        }

        let stepForNav = layout.step > 0 ? layout.step : (.pi / 18)
        let firstAngle = layout.angles.first ?? 0
        let lastAngle = layout.angles.last ?? 0

        let prevAngle = firstAngle - stepForNav
        let nextAngle = lastAngle + stepForNav
        let closeAngle = nextAngle + stepForNav

        positionCurvedWallNavCard(
            attachmentID: AlbumCurvedWallAttachmentID.prev,
            name: AlbumCurvedWallAttachmentID.prev,
            angle: prevAngle,
            y: -0.32,
            radius: layout.radius,
            panelDepthOffset: panelDepthOffset,
            attachments: attachments,
            root: root
        )

        positionCurvedWallNavCard(
            attachmentID: AlbumCurvedWallAttachmentID.next,
            name: AlbumCurvedWallAttachmentID.next,
            angle: nextAngle,
            y: -0.32,
            radius: layout.radius,
            panelDepthOffset: panelDepthOffset,
            attachments: attachments,
            root: root
        )

        positionCurvedWallNavCard(
            attachmentID: AlbumCurvedWallAttachmentID.close,
            name: AlbumCurvedWallAttachmentID.close,
            angle: closeAngle,
            y: -0.32,
            radius: layout.radius,
            panelDepthOffset: panelDepthOffset,
            attachments: attachments,
            root: root
        )

        let attachmentSignature = "tiles=\(pages.count) found=\(tilesFound) prev=\(attachments.entity(for: AlbumCurvedWallAttachmentID.prev) != nil) next=\(attachments.entity(for: AlbumCurvedWallAttachmentID.next) != nil) close=\(attachments.entity(for: AlbumCurvedWallAttachmentID.close) != nil)"
        if attachmentSignature != lastCurvedWallAttachmentLogSignature {
            lastCurvedWallAttachmentLogSignature = attachmentSignature
            AlbumLog.immersive.info("CurvedWall attachments \(attachmentSignature, privacy: .public)")
        }
    }

    private struct CurvedWallColumnLayout: Sendable {
        var columns: [[Int]]
        var heights: [Float]
    }

    private func curvedWallColumns(
        for pages: [AlbumModel.CurvedWallPanel],
        maxColumnHeight: Float,
        pageSpacing: Float
    ) -> CurvedWallColumnLayout {
        guard !pages.isEmpty else { return CurvedWallColumnLayout(columns: [], heights: []) }

        var columns: [[Int]] = []
        var heights: [Float] = []
        columns.reserveCapacity(6)
        heights.reserveCapacity(6)

        var currentColumn: [Int] = []
        var currentHeight: Float = 0

        for (index, page) in pages.enumerated() {
            let pageHeight = max(0, page.heightMeters)
            if currentColumn.isEmpty {
                currentColumn = [index]
                currentHeight = pageHeight
                continue
            }

            let proposed = currentHeight + pageSpacing + pageHeight
            if proposed > maxColumnHeight {
                columns.append(currentColumn)
                heights.append(currentHeight)
                currentColumn = [index]
                currentHeight = pageHeight
            } else {
                currentColumn.append(index)
                currentHeight = proposed
            }
        }

        if !currentColumn.isEmpty {
            columns.append(currentColumn)
            heights.append(currentHeight)
        }

        return CurvedWallColumnLayout(columns: columns, heights: heights)
    }

	    private func ensureCurvedWallAnchor(in content: RealityViewContent, model: AlbumModel) -> AnchorEntity {
	        if let existing = curvedWallAnchor {
	            if existing.parent != nil {
	                return existing
	            }
	            AlbumLog.immersive.info("CurvedWall anchor stale; rebuilding from stored seed")
	            curvedWallAnchor = nil
	        }

	        if let stored = curvedWallSeedMatrix {
	            let anchor = AnchorEntity(world: stored)
	            anchor.orientation = Transform(matrix: stored).rotation
	            anchor.name = "album-curved-wall-anchor"
	            curvedWallAnchor = anchor
	            content.add(anchor)
	            return anchor
	        }

	        let head = initialHeadTransform ?? latestHeadTransform ?? Transform(matrix: headAnchor?.transformMatrix(relativeTo: nil) ?? matrix_identity_float4x4)
	        let fcol = head.matrix.columns.2
	        let forward = normalize(-SIMD3<Float>(fcol.x, fcol.y, fcol.z))

	        let headForwardOffset: Float = 0.09
	        var pos = head.translation + forward * headForwardOffset
	        if !pos.y.isFinite || abs(pos.y) <= 0.001 { pos.y = 1.35 } else { pos.y -= 0.05 }

	        var seeded = head
	        seeded.translation = pos

	        curvedWallSeedMatrix = seeded.matrix

	        let anchor = AnchorEntity(world: seeded.matrix)
	        anchor.orientation = seeded.rotation
	        anchor.name = "album-curved-wall-anchor"

	        curvedWallAnchor = anchor
	        content.add(anchor)

	        AlbumLog.immersive.info("CurvedWall anchor seeded (initialHead=\(self.initialHeadTransform != nil)) pos=(\(pos.x), \(pos.y), \(pos.z))")
	        return anchor
	    }

    private func positionCurvedWallNavCard(
        attachmentID: String,
        name: String,
        angle: Float,
        y: Float,
        radius: Float,
        panelDepthOffset: Float,
        attachments: RealityViewAttachments,
        root: Entity
    ) {
        guard let card = attachments.entity(for: attachmentID) else { return }

        let sine = sinf(angle)
        let cosine = cosf(angle)
        let x = sine * radius
        let z = -cosine * radius - panelDepthOffset

        let forward = normalize(SIMD3<Float>(-x, 0, -z))
        let right = normalize(cross(SIMD3<Float>(0, 1, 0), forward))
        let up = cross(forward, right)

        var transform = card.transform
        transform.translation = [x, y, z]
        transform.rotation = simd_quatf(float3x3(columns: (right, up, forward)))
        card.transform = transform
        card.name = name

        if card.components[InputTargetComponent.self] == nil {
            card.components.set(InputTargetComponent())
        }
        if card.components[CollisionComponent.self] == nil {
            card.generateCollisionShapes(recursive: true)
        }

        if card.parent != root {
            root.addChild(card)
        }
    }

    private func removeCurvedWallEntities(from root: Entity) {
        removeTileChildren(from: root)
        for child in root.children {
            if child.name == AlbumCurvedWallAttachmentID.close ||
                child.name == AlbumCurvedWallAttachmentID.prev ||
                child.name == AlbumCurvedWallAttachmentID.next {
                child.removeFromParent()
            }
        }
    }

    private func removeTileChildren(from root: Entity) {
        for child in root.children {
            if child.name.hasPrefix("album-curved-wall-tile|") {
                child.removeFromParent()
            }
        }
    }

    // MARK: Frame loop

    private func startFrameLoopIfNeeded(model: AlbumModel) {
        guard frameTask == nil else { return }

        frameTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.frameStep(model: model)
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }
    }

    private func frameStep(model: AlbumModel) {
        guard let root = anchor else { return }
        var dt = Float(Date().timeIntervalSince(lastTs))
        if dt <= 0 { dt = 1 / 60 }
        dt = min(dt, 1 / 30)
        lastTs = Date()
        guard !model.isPaused else { return }

        accum += dt
        physicsStep(dt: dt, root: root)

        if accum >= Float(model.absorbInterval) {
            accum = 0
            absorbOne(model: model)
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

    private func absorbOne(model: AlbumModel) {
        guard let root = anchor, !balls.isEmpty else { return }
        let pmn = pmns[nextPMN % pmns.count]
        nextPMN += 1

        let centre = pmn.position(relativeTo: root)
        let alreadySeen = Set(model.historyAssetIDs)
        let proximityWindowSize = 5

        struct Candidate {
            let ball: ModelEntity
            let dist: Float
            let speed: Float
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(balls.count)

        for ball in balls {
            let dist = distance(ball.position(relativeTo: root), centre)
            let v = ball.components[AlbumVelocityComponent.self]?.v ?? .zero
            candidates.append(.init(ball: ball, dist: dist, speed: length(v)))
        }

        candidates.sort(by: { $0.dist < $1.dist })

        while !candidates.isEmpty {
            let windowEnd = min(proximityWindowSize, candidates.count)
            let window = candidates[0..<windowEnd]

            guard let chosen = window.min(by: { $0.speed < $1.speed }) else { return }
            guard let chosenIndex = candidates.firstIndex(where: { $0.ball == chosen.ball }) else { return }
            candidates.remove(at: chosenIndex)

            guard let idx = balls.firstIndex(where: { $0 == chosen.ball }) else { continue }
            let victim = balls[idx]
            victim.removeFromParent()
            balls.remove(at: idx)

            guard let assetID = victim.components[AlbumAssetIDComponent.self]?.assetID else { continue }
            if alreadySeen.contains(assetID) { continue }

            model.currentAssetID = assetID
            break
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
        ball.components.set(AlbumAssetIDComponent(assetID: asset.id))

        ball.generateCollisionShapes(recursive: false)
        ball.components.set(InputTargetComponent())

        balls.append(ball)
        root.addChild(ball)

        if isVideo { ball.addChild(makeHalo(videoHaloTint)) }
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
