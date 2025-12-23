import Foundation
import Dispatch
import Vision

public actor FaceHierarchyStore {
    private struct PersistedStore: Codable {
        var schemaVersion: Int
        var rootID: String
        var nodesByID: [String: FaceClusterNode]
        var updatedAt: Date
        var lastBuiltThresholds: [Float]
        var lastBuiltAt: Date?
        var lastBuiltRepCap: Int?
        var lastBuiltLeafSignature: FaceIndexStore.LeafClusterSignature?
    }

    public static let currentSchemaVersion: Int = 1
    public static let rootNodeID: String = "people_root"

    private let faceIndexStore: FaceIndexStore
    private let storeURL: URL

    private var loaded: Bool = false
    private var store: PersistedStore = PersistedStore(
        schemaVersion: FaceHierarchyStore.currentSchemaVersion,
        rootID: FaceHierarchyStore.rootNodeID,
        nodesByID: [:],
        updatedAt: Date(),
        lastBuiltThresholds: [],
        lastBuiltAt: nil,
        lastBuiltRepCap: nil,
        lastBuiltLeafSignature: nil
    )

    private var saveTask: Task<Void, Never>? = nil
    private var isDirty: Bool = false

    public init(faceIndexStore: FaceIndexStore) {
        self.faceIndexStore = faceIndexStore

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Faces", isDirectory: true)
        self.storeURL = directory.appendingPathComponent("face_hierarchy_v1.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AlbumLog.faces.error("FaceHierarchyStore createDirectory error: \(String(describing: error), privacy: .public)")
        }
    }

    public func snapshot() async -> FaceHierarchySnapshot {
        await ensureLoaded()
        return FaceHierarchySnapshot(rootID: store.rootID, nodesByID: store.nodesByID)
    }

    public func needsRebuild(levelThresholds: [Float], repCap: Int) async -> Bool {
        await ensureLoaded()

        let thresholds = normalizeThresholds(levelThresholds)
        let cap = max(1, repCap)

        guard let root = store.nodesByID[store.rootID], !root.childIDs.isEmpty else { return true }
        guard store.lastBuiltAt != nil else { return true }
        if store.lastBuiltThresholds != thresholds { return true }
        if store.lastBuiltRepCap != cap { return true }

        guard let lastSignature = store.lastBuiltLeafSignature else { return true }
        let currentSignature = await faceIndexStore.leafClusterSignature(repCap: cap)
        return currentSignature != lastSignature
    }

    public func node(nodeID: String) async -> FaceClusterNode? {
        await ensureLoaded()
        let id = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return store.nodesByID[id]
    }

    public func upsertLeafCluster(leafID: String, representatives: [FaceEmbedding]) async {
        await ensureLoaded()

        let id = leafID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let now = Date()

        var existing = store.nodesByID[id]
        if existing == nil {
            existing = FaceClusterNode(
                id: id,
                level: 0,
                parentID: nil,
                childIDs: [],
                displayName: nil,
                labelSource: .none,
                linkedContactID: nil,
                representativeEmbeddings: representatives,
                updatedAt: now
            )
        }

        var node = existing!
        node.level = 0
        node.childIDs = []
        node.representativeEmbeddings = representatives
        node.updatedAt = now

        store.nodesByID[id] = node
        store.updatedAt = now
        markDirty()
        await saveIfDirty()
    }

    public func rebuildHierarchy(
        levelThresholds: [Float],
        repCap: Int,
        progress: (@MainActor (FaceHierarchyBuildProgress) -> Void)? = nil
    ) async {
        await ensureLoaded()

        let thresholds = normalizeThresholds(levelThresholds)
        let cap = max(1, repCap)

        let rebuildStart = Date()
        await publishProgress(
            progress,
            FaceHierarchyBuildProgress(
                stage: .fetchingLeaves,
                totalLevels: max(0, thresholds.count - 1),
                fractionComplete: 0,
                startedAt: rebuildStart,
                updatedAt: rebuildStart
            )
        )
        AlbumLog.faces.info(
            "FaceHierarchy rebuild start thresholds=\(String(describing: thresholds), privacy: .public) repCap=\(cap, privacy: .public)"
        )

        let now = Date()
        let previousNodesByID = store.nodesByID

        let fetchStart = Date()
        let leafClusters = await faceIndexStore.leafClusters(repCap: cap)
        AlbumLog.faces.info(
            "FaceHierarchy leaf clusters fetched count=\(leafClusters.count, privacy: .public) elapsed=\(Date().timeIntervalSince(fetchStart), privacy: .public)s"
        )

        let leafSignature = FaceIndexStore.LeafClusterSignature(
            clusterCount: leafClusters.count,
            usedReferencePrints: leafClusters.reduce(into: 0) { partial, cluster in
                partial += cluster.referencePrints.count
            }
        )

        var newNodesByID: [String: FaceClusterNode] = [:]
        newNodesByID.reserveCapacity(leafClusters.count * 2)

        var leafIDs: [String] = []
        leafIDs.reserveCapacity(leafClusters.count)

        for leaf in leafClusters {
            let leafID = leaf.faceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !leafID.isEmpty else { continue }

            var displayName: String? = nil
            var labelSource: ClusterLabelSource = .none
            var linkedContactID: String? = nil

            if let existing = previousNodesByID[leafID], existing.hasDisplayName {
                displayName = existing.displayName
                labelSource = existing.labelSource
                linkedContactID = existing.linkedContactID
            } else if let name = leaf.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      leaf.labelSource != .none {
                displayName = name
                labelSource = leaf.labelSource
                linkedContactID = leaf.linkedContactID
            }

            let reps = leaf.referencePrints
                .prefix(cap)
                .map { FaceEmbedding(data: $0, elementCount: 0, elementType: "vnfeatureprint") }

            let node = FaceClusterNode(
                id: leafID,
                level: 0,
                parentID: nil,
                childIDs: [],
                displayName: displayName,
                labelSource: labelSource,
                linkedContactID: linkedContactID,
                representativeEmbeddings: reps,
                updatedAt: now
            )

            newNodesByID[leafID] = node
            leafIDs.append(leafID)
        }

        leafIDs.sort()
        AlbumLog.faces.info("FaceHierarchy leaf nodes prepared count=\(leafIDs.count, privacy: .public)")

        let maxLevel = max(0, thresholds.count - 1)
        var nodeIDsByLevel: [[String]] = Array(repeating: [], count: maxLevel + 1)
        nodeIDsByLevel[0] = leafIDs

        if maxLevel > 0 {
            for level in 1...maxLevel {
                if Task.isCancelled { break }

                let childIDs = nodeIDsByLevel[level - 1]
                if childIDs.isEmpty {
                    nodeIDsByLevel[level] = []
                    continue
                }

                let threshold = thresholds.indices.contains(level) ? thresholds[level] : thresholds.last ?? 0

                let levelStart = Date()
                AlbumLog.faces.info(
                    "FaceHierarchy build level=\(level, privacy: .public) threshold=\(threshold, privacy: .public) children=\(childIDs.count, privacy: .public)"
                )

                let parentGroups = try? await mergedGroups(
                    childIDs: childIDs,
                    nodesByID: newNodesByID,
                    distanceThreshold: threshold,
                    buildStartedAt: rebuildStart,
                    totalLevels: maxLevel,
                    level: level,
                    progress: progress
                )

                let groups = parentGroups ?? childIDs.map { [$0] }
                AlbumLog.faces.info(
                    "FaceHierarchy level=\(level, privacy: .public) mergedGroups=\(groups.count, privacy: .public) elapsed=\(Date().timeIntervalSince(levelStart), privacy: .public)s"
                )

                var parentIDs: [String] = []
                parentIDs.reserveCapacity(groups.count)

                for members in groups {
                    if Task.isCancelled { break }
                    let normalizedMembers = members
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .sorted()
                    guard !normalizedMembers.isEmpty else { continue }

                    let canonicalBase = canonicalBaseLeafID(
                        level: level,
                        memberIDs: normalizedMembers,
                        currentNodesByID: newNodesByID,
                        previousNodesByID: previousNodesByID
                    )
                    let parentID = hierarchicalNodeID(level: level, canonicalBaseLeafID: canonicalBase)

                    let existingParent = previousNodesByID[parentID]
                    let existingName = existingParent?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existingHasLabel = (existingName?.isEmpty == false) && (existingParent?.labelSource == .manual || existingParent?.labelSource == .contact)

                    let canonicalChildID = canonicalMemberID(memberIDs: normalizedMembers, currentNodesByID: newNodesByID)
                    let canonicalChild = canonicalChildID.flatMap { newNodesByID[$0] }

                    let (displayName, labelSource, linkedContactID): (String?, ClusterLabelSource, String?) = {
                        if existingHasLabel, let existingParent {
                            return (existingParent.displayName, existingParent.labelSource, existingParent.linkedContactID)
                        }
                        if let child = canonicalChild, child.isManuallyLabeled {
                            return (child.displayName, .manual, child.linkedContactID)
                        }
                        if let child = canonicalChild, child.isContactLabeled {
                            return (child.displayName, .contact, child.linkedContactID)
                        }
                        return (nil, .none, nil)
                    }()

                    let repEmbeddings = mergedRepresentatives(memberIDs: normalizedMembers, nodesByID: newNodesByID, cap: cap)

                    let parentNode = FaceClusterNode(
                        id: parentID,
                        level: level,
                        parentID: nil,
                        childIDs: normalizedMembers,
                        displayName: displayName,
                        labelSource: labelSource,
                        linkedContactID: linkedContactID,
                        representativeEmbeddings: repEmbeddings,
                        updatedAt: now
                    )

                    newNodesByID[parentID] = parentNode
                    parentIDs.append(parentID)

                    for childID in normalizedMembers {
                        guard var childNode = newNodesByID[childID] else { continue }
                        childNode.parentID = parentID
                        childNode.updatedAt = now
                        newNodesByID[childID] = childNode
                    }
                }

                parentIDs.sort()
                nodeIDsByLevel[level] = parentIDs

                AlbumLog.faces.info(
                    "FaceHierarchy level=\(level, privacy: .public) parents=\(parentIDs.count, privacy: .public) elapsed=\(Date().timeIntervalSince(levelStart), privacy: .public)s"
                )
            }
        }

        let topLevelIDs: [String] = {
            if maxLevel > 0 { return nodeIDsByLevel[maxLevel] }
            return leafIDs
        }()

        let rootID = FaceHierarchyStore.rootNodeID
        for topID in topLevelIDs {
            guard var node = newNodesByID[topID] else { continue }
            node.parentID = rootID
            node.updatedAt = now
            newNodesByID[topID] = node
        }

        let rootNode = FaceClusterNode(
            id: rootID,
            level: maxLevel + 1,
            parentID: nil,
            childIDs: topLevelIDs,
            displayName: "People",
            labelSource: .none,
            linkedContactID: nil,
            representativeEmbeddings: [],
            updatedAt: now
        )

        newNodesByID[rootID] = rootNode

        store.nodesByID = newNodesByID
        store.rootID = rootID
        store.updatedAt = now
        store.lastBuiltThresholds = thresholds
        store.lastBuiltAt = now
        store.lastBuiltRepCap = cap
        store.lastBuiltLeafSignature = leafSignature
        markDirty()
        await saveIfDirty()

        AlbumLog.faces.info(
            "FaceHierarchy rebuild done nodes=\(newNodesByID.count, privacy: .public) maxLevel=\(maxLevel, privacy: .public) elapsed=\(Date().timeIntervalSince(rebuildStart), privacy: .public)s"
        )

        await publishProgress(
            progress,
            FaceHierarchyBuildProgress(
                stage: .done,
                totalLevels: maxLevel,
                fractionComplete: 1,
                startedAt: rebuildStart,
                updatedAt: Date(),
                etaSeconds: 0
            )
        )
    }

    public func leafDescendants(of nodeID: String) async -> [String] {
        await ensureLoaded()

        let id = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        guard let start = store.nodesByID[id] else { return [] }

        var out: [String] = []
        out.reserveCapacity(32)

        var stack: [String] = [start.id]
        var visited: Set<String> = [start.id]

        while let currentID = stack.popLast() {
            guard let node = store.nodesByID[currentID] else { continue }

            if node.level == 0 {
                out.append(node.id)
                continue
            }

            for childID in node.childIDs {
                guard visited.insert(childID).inserted else { continue }
                stack.append(childID)
            }
        }

        out.sort()
        return out
    }

    public func ancestorChain(from leafID: String) async -> [FaceClusterNode] {
        await ensureLoaded()

        let id = leafID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }

        var out: [FaceClusterNode] = []
        out.reserveCapacity(6)

        var currentID: String? = id
        var visited: Set<String> = []
        visited.reserveCapacity(8)

        while let nextID = currentID {
            guard visited.insert(nextID).inserted else { break }
            guard let node = store.nodesByID[nextID] else { break }
            out.append(node)
            currentID = node.parentID
        }

        return out
    }

    public func displayNamePreferred(for leafID: String) async -> String? {
        await ensureLoaded()

        let id = leafID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        var foundContact: String? = nil

        var currentID: String? = id
        var visited: Set<String> = []
        visited.reserveCapacity(8)

        while let nextID = currentID {
            guard visited.insert(nextID).inserted else { break }
            guard let node = store.nodesByID[nextID] else { break }

            if node.isManuallyLabeled {
                return node.displayName
            }

            if foundContact == nil, node.isContactLabeled {
                foundContact = node.displayName
            }

            currentID = node.parentID
        }

        return foundContact
    }

    public func displayNamePreferredByLeafID(for leafIDs: [String]) async -> [String: String] {
        await ensureLoaded()

        guard !leafIDs.isEmpty else { return [:] }

        var out: [String: String] = [:]
        out.reserveCapacity(min(512, leafIDs.count))

        for raw in leafIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if out[id] != nil { continue }
            if let name = await displayNamePreferred(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                out[id] = name
            }
        }

        return out
    }

    public func clusterTokenPreferred(for leafID: String) async -> String? {
        await ensureLoaded()
        return clusterTokenPreferredLocked(for: leafID)
    }

    public func clusterTokenPreferredByLeafID(for leafIDs: [String]) async -> [String: String] {
        await ensureLoaded()

        guard !leafIDs.isEmpty else { return [:] }

        var out: [String: String] = [:]
        out.reserveCapacity(min(512, leafIDs.count))

        for raw in leafIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if out[id] != nil { continue }
            if let token = clusterTokenPreferredLocked(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                out[id] = token
            }
        }

        return out
    }

    private func clusterTokenPreferredLocked(for leafID: String) -> String? {
        let id = leafID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard store.nodesByID[id] != nil else { return nil }

        var foundContact: String? = nil
        var highestClusterID: String? = nil

        var currentID: String? = id
        var visited: Set<String> = []
        visited.reserveCapacity(8)

        while let nextID = currentID {
            guard visited.insert(nextID).inserted else { break }
            guard let node = store.nodesByID[nextID] else { break }

            if node.id != store.rootID, node.level > 0 {
                highestClusterID = node.id
            }

            if node.isManuallyLabeled {
                return node.displayName
            }

            if foundContact == nil, node.isContactLabeled {
                foundContact = node.displayName
            }

            currentID = node.parentID
        }

        if let foundContact, !foundContact.isEmpty {
            return foundContact
        }

        if let highestClusterID, !highestClusterID.isEmpty {
            return highestClusterID
        }

        return id
    }

    public func setManualLabel(nodeID: String, name: String?) async {
        await ensureLoaded()

        let id = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard var node = store.nodesByID[id] else { return }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            node.displayName = nil
            node.labelSource = .none
            node.linkedContactID = nil
        } else {
            node.displayName = trimmed
            node.labelSource = .manual
        }

        node.updatedAt = Date()
        store.nodesByID[id] = node
        store.updatedAt = node.updatedAt
        markDirty()
        await saveIfDirty()
    }

    public func setContactLabel(nodeID: String, contactID: String, name: String) async {
        await ensureLoaded()

        let id = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = contactID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !cid.isEmpty, !trimmed.isEmpty else { return }
        guard var node = store.nodesByID[id] else { return }

        if node.isManuallyLabeled {
            return
        }

        node.displayName = trimmed
        node.labelSource = .contact
        node.linkedContactID = cid
        node.updatedAt = Date()

        store.nodesByID[id] = node
        store.updatedAt = node.updatedAt
        markDirty()
        await saveIfDirty()
    }

    // MARK: - Internals

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            ensureRootNodeExists()
            return
        }

        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PersistedStore.self, from: data)
            if decoded.schemaVersion == FaceHierarchyStore.currentSchemaVersion {
                store = decoded
            } else {
                AlbumLog.faces.error("FaceHierarchyStore schema mismatch found=\(decoded.schemaVersion, privacy: .public) expected=\(FaceHierarchyStore.currentSchemaVersion, privacy: .public)")
            }
        } catch {
            AlbumLog.faces.error("FaceHierarchyStore load error: \(String(describing: error), privacy: .public)")
        }

        ensureRootNodeExists()
    }

    private func ensureRootNodeExists() {
        let rootID = FaceHierarchyStore.rootNodeID
        guard store.nodesByID[rootID] == nil else { return }
        store.nodesByID[rootID] = FaceClusterNode(
            id: rootID,
            level: 1,
            parentID: nil,
            childIDs: [],
            displayName: "People",
            labelSource: .none,
            linkedContactID: nil,
            representativeEmbeddings: [],
            updatedAt: Date()
        )
        store.rootID = rootID
        store.updatedAt = Date()
        markDirty()
    }

    private func markDirty() {
        isDirty = true
        scheduleSave()
        NotificationCenter.default.post(name: .albumFaceHierarchyDidUpdate, object: nil)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            await saveIfDirty()
        }
    }

    private func saveIfDirty() async {
        guard isDirty else { return }
        isDirty = false

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            AlbumLog.faces.error("FaceHierarchyStore save error: \(String(describing: error), privacy: .public)")
        }
    }

    private func normalizeThresholds(_ thresholds: [Float]) -> [Float] {
        let cleaned = thresholds.map { raw -> Float in
            if raw.isFinite {
                return max(0, min(0.95, raw))
            }
            return 0
        }

        if cleaned.isEmpty {
            return [0]
        }
        return cleaned
    }

    private func hierarchicalNodeID(level: Int, canonicalBaseLeafID: String) -> String {
        let base = canonicalBaseLeafID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "h\(max(1, level))_\(base)"
    }

    private func baseLeafID(from nodeID: String) -> String {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("h") else { return trimmed }
        guard let underscore = trimmed.firstIndex(of: "_") else { return trimmed }
        let after = trimmed.index(after: underscore)
        let base = String(trimmed[after...])
        return base.isEmpty ? trimmed : base
    }

    private func canonicalMemberID(memberIDs: [String], currentNodesByID: [String: FaceClusterNode]) -> String? {
        guard !memberIDs.isEmpty else { return nil }

        func rank(for node: FaceClusterNode) -> Int {
            if node.isManuallyLabeled { return 2 }
            if node.isContactLabeled { return 1 }
            return 0
        }

        var bestID: String? = nil
        var bestRank: Int = -1

        for id in memberIDs {
            guard let node = currentNodesByID[id] else { continue }
            let r = rank(for: node)
            if r > bestRank {
                bestRank = r
                bestID = id
            } else if r == bestRank {
                if let current = bestID, id < current {
                    bestID = id
                }
            }
        }

        return bestID ?? memberIDs.sorted().first
    }

    private func canonicalBaseLeafID(
        level: Int,
        memberIDs: [String],
        currentNodesByID: [String: FaceClusterNode],
        previousNodesByID: [String: FaceClusterNode]
    ) -> String {
        let bases = Array(Set(memberIDs.map { baseLeafID(from: $0) })).sorted()
        guard !bases.isEmpty else { return memberIDs.sorted().first ?? "" }

        func bestExistingBase(where predicate: (FaceClusterNode) -> Bool) -> String? {
            for base in bases {
                let candidateID = hierarchicalNodeID(level: level, canonicalBaseLeafID: base)
                if let existing = previousNodesByID[candidateID], predicate(existing) {
                    return base
                }
            }
            return nil
        }

        if let manualBase = bestExistingBase(where: { $0.isManuallyLabeled }) {
            return manualBase
        }

        if let manualMember = memberIDs.compactMap({ id -> String? in
            guard let node = currentNodesByID[id], node.isManuallyLabeled else { return nil }
            return baseLeafID(from: id)
        }).sorted().first {
            return manualMember
        }

        if let contactBase = bestExistingBase(where: { $0.isContactLabeled }) {
            return contactBase
        }

        if let contactMember = memberIDs.compactMap({ id -> String? in
            guard let node = currentNodesByID[id], node.isContactLabeled else { return nil }
            return baseLeafID(from: id)
        }).sorted().first {
            return contactMember
        }

        return bases.first ?? memberIDs.sorted().first ?? ""
    }

    private func mergedRepresentatives(memberIDs: [String], nodesByID: [String: FaceClusterNode], cap: Int) -> [FaceEmbedding] {
        let limit = max(1, cap)

        var out: [FaceEmbedding] = []
        out.reserveCapacity(limit)

        var seen = Set<Data>()
        seen.reserveCapacity(limit)

        for id in memberIDs {
            guard let node = nodesByID[id] else { continue }
            for emb in node.representativeEmbeddings {
                guard !emb.data.isEmpty else { continue }
                guard seen.insert(emb.data).inserted else { continue }
                out.append(emb)
                if out.count >= limit {
                    return out
                }
            }
        }

        return out
    }

    private func mergedGroups(
        childIDs: [String],
        nodesByID: [String: FaceClusterNode],
        distanceThreshold: Float,
        buildStartedAt: Date,
        totalLevels: Int,
        level: Int,
        progress: (@MainActor (FaceHierarchyBuildProgress) -> Void)?
    ) async throws -> [[String]] {
        let threshold = max(0, distanceThreshold)
        if threshold <= 0 {
            AlbumLog.faces.info("FaceHierarchy merge skipped threshold<=0 children=\(childIDs.count, privacy: .public)")
            await publishProgress(
                progress,
                FaceHierarchyBuildProgress(
                    stage: .mergingLevel,
                    totalLevels: totalLevels,
                    level: level,
                    threshold: threshold,
                    processedPairs: 0,
                    totalPairs: 0,
                    unions: 0,
                    fractionComplete: overallFraction(totalLevels: totalLevels, currentLevel: level, levelFraction: 1),
                    startedAt: buildStartedAt,
                    updatedAt: Date(),
                    etaSeconds: 0
                )
            )
            return childIDs.map { [$0] }
        }

        let start = Date()

        struct NodePrints {
            let id: String
            let prints: [VNFeaturePrintObservation]
        }

        var packs: [NodePrints] = []
        packs.reserveCapacity(childIDs.count)

        var missingNodes = 0
        var nodesWithPrints = 0
        var totalPrints = 0

        for id in childIDs {
            guard let node = nodesByID[id] else {
                missingNodes += 1
                packs.append(NodePrints(id: id, prints: []))
                continue
            }

            var prints: [VNFeaturePrintObservation] = []
            prints.reserveCapacity(min(12, node.representativeEmbeddings.count))

            for emb in node.representativeEmbeddings {
                guard !emb.data.isEmpty else { continue }
                if let obs = try? unarchiveFeaturePrint(emb.data) {
                    prints.append(obs)
                }
            }

            if !prints.isEmpty {
                nodesWithPrints += 1
                totalPrints += prints.count
            }

            packs.append(NodePrints(id: id, prints: prints))
        }

        AlbumLog.faces.info(
            "FaceHierarchy merge start threshold=\(threshold, privacy: .public) nodes=\(packs.count, privacy: .public) withPrints=\(nodesWithPrints, privacy: .public) totalPrints=\(totalPrints, privacy: .public) missingNodes=\(missingNodes, privacy: .public)"
        )

        let n = packs.count
        var parent = Array(0..<n)
        var rank = Array(repeating: 0, count: n)

        func find(_ x: Int) -> Int {
            var i = x
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }

        func union(_ x: Int, _ y: Int) -> Bool {
            let rx = find(x)
            let ry = find(y)
            guard rx != ry else { return false }

            if rank[rx] < rank[ry] {
                parent[rx] = ry
            } else if rank[rx] > rank[ry] {
                parent[ry] = rx
            } else {
                parent[ry] = rx
                rank[rx] += 1
            }
            return true
        }

        func linkable(_ lhs: [VNFeaturePrintObservation], _ rhs: [VNFeaturePrintObservation]) -> Bool {
            guard !lhs.isEmpty, !rhs.isEmpty else { return false }

            for l in lhs {
                for r in rhs {
                    do {
                        var distance: Float = 0
                        try l.computeDistance(&distance, to: r)
                        if distance <= threshold {
                            return true
                        }
                    } catch {
                        continue
                    }
                }
            }

            return false
        }

        var processedPairs: Int64 = 0
        var unionCount: Int64 = 0
        let totalPairs: Int64 = {
            let nn = Int64(n)
            return nn > 1 ? ((nn * (nn - 1)) / 2) : 0
        }()

        await publishProgress(
            progress,
            FaceHierarchyBuildProgress(
                stage: .mergingLevel,
                totalLevels: totalLevels,
                level: level,
                threshold: threshold,
                processedPairs: 0,
                totalPairs: totalPairs,
                unions: 0,
                fractionComplete: overallFraction(totalLevels: totalLevels, currentLevel: level, levelFraction: 0),
                startedAt: buildStartedAt,
                updatedAt: start,
                etaSeconds: nil
            )
        )

        var lastProgressLogNS = DispatchTime.now().uptimeNanoseconds
        var lastProgressPairs: Int64 = 0
        var lastUIProgressNS = lastProgressLogNS

        for i in 0..<n {
            if Task.isCancelled { break }
            if packs[i].prints.isEmpty { continue }

            for j in (i + 1)..<n {
                if Task.isCancelled { break }
                if packs[j].prints.isEmpty { continue }
                if find(i) == find(j) { continue }

                processedPairs += 1
                if linkable(packs[i].prints, packs[j].prints) {
                    if union(i, j) {
                        unionCount += 1
                    }
                }

                let nowNS = DispatchTime.now().uptimeNanoseconds
                if nowNS - lastProgressLogNS >= 5_000_000_000 {
                    let seconds = Double(nowNS - lastProgressLogNS) / 1_000_000_000
                    let deltaPairs = max(0, processedPairs - lastProgressPairs)
                    let rate = seconds > 0 ? Double(deltaPairs) / seconds : 0
                    let pct = totalPairs > 0 ? (Double(processedPairs) / Double(totalPairs) * 100) : 0

                    AlbumLog.faces.info(
                        "FaceHierarchy merge progress processed=\(processedPairs, privacy: .public)/\(totalPairs, privacy: .public) (\(pct, privacy: .public)%) unions=\(unionCount, privacy: .public) rate=\(rate, privacy: .public)pairs/s elapsed=\(Date().timeIntervalSince(start), privacy: .public)s"
                    )

                    lastProgressLogNS = nowNS
                    lastProgressPairs = processedPairs
                }

                if nowNS - lastUIProgressNS >= 250_000_000 {
                    let elapsed = Date().timeIntervalSince(start)
                    let done = totalPairs > 0 ? Double(processedPairs) / Double(totalPairs) : 0
                    let rate = elapsed > 0 ? Double(processedPairs) / elapsed : 0
                    let remainingPairs = max(0, totalPairs - processedPairs)
                    let eta = rate > 0 ? Double(remainingPairs) / rate : nil

                    await publishProgress(
                        progress,
                        FaceHierarchyBuildProgress(
                            stage: .mergingLevel,
                            totalLevels: totalLevels,
                            level: level,
                            threshold: threshold,
                            processedPairs: processedPairs,
                            totalPairs: totalPairs,
                            unions: unionCount,
                            fractionComplete: overallFraction(totalLevels: totalLevels, currentLevel: level, levelFraction: done),
                            startedAt: buildStartedAt,
                            updatedAt: Date(),
                            etaSeconds: eta
                        )
                    )
                    lastUIProgressNS = nowNS
                }

                if processedPairs.isMultiple(of: 192) {
                    await Task.yield()
                }
            }
        }

        var groupsByRoot: [Int: [String]] = [:]
        groupsByRoot.reserveCapacity(n)

        for (idx, pack) in packs.enumerated() {
            let root = find(idx)
            groupsByRoot[root, default: []].append(pack.id)
        }

        var out: [[String]] = []
        out.reserveCapacity(groupsByRoot.count)

        for (_, ids) in groupsByRoot {
            let normalized = ids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            guard !normalized.isEmpty else { continue }
            out.append(normalized)
        }

        out.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first ?? "") < (rhs.first ?? "")
        }

        AlbumLog.faces.info(
            "FaceHierarchy merge done groups=\(out.count, privacy: .public) processed=\(processedPairs, privacy: .public)/\(totalPairs, privacy: .public) unions=\(unionCount, privacy: .public) elapsed=\(Date().timeIntervalSince(start), privacy: .public)s"
        )

        let elapsed = Date().timeIntervalSince(start)
        let done = totalPairs > 0 ? Double(processedPairs) / Double(totalPairs) : 1
        let rate = elapsed > 0 ? Double(processedPairs) / elapsed : 0
        let remainingPairs = max(0, totalPairs - processedPairs)
        let eta = rate > 0 ? Double(remainingPairs) / rate : 0

        await publishProgress(
            progress,
            FaceHierarchyBuildProgress(
                stage: .mergingLevel,
                totalLevels: totalLevels,
                level: level,
                threshold: threshold,
                processedPairs: processedPairs,
                totalPairs: totalPairs,
                unions: unionCount,
                fractionComplete: overallFraction(totalLevels: totalLevels, currentLevel: level, levelFraction: done),
                startedAt: buildStartedAt,
                updatedAt: Date(),
                etaSeconds: eta
            )
        )

        return out
    }

    private func unarchiveFeaturePrint(_ data: Data) throws -> VNFeaturePrintObservation {
        guard let obs = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
            throw FaceHierarchyUnarchiveError.invalidPayload
        }
        return obs
    }

    private func publishProgress(
        _ sink: (@MainActor (FaceHierarchyBuildProgress) -> Void)?,
        _ progress: FaceHierarchyBuildProgress
    ) async {
        guard let sink else { return }
        await MainActor.run {
            sink(progress)
        }
    }

    private func overallFraction(totalLevels: Int, currentLevel: Int, levelFraction: Double) -> Double {
        let total = max(1, totalLevels)
        let levelIndex = max(0, min(total, currentLevel - 1))
        let fraction = (Double(levelIndex) + max(0, min(1, levelFraction))) / Double(total)
        return max(0, min(1, fraction))
    }
}

private enum FaceHierarchyUnarchiveError: Error {
    case invalidPayload
}
