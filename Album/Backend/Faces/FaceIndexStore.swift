import Foundation
import Vision

public actor FaceIndexStore {
    public struct Configuration: Sendable, Hashable {
        public var similarityThreshold: Float
        public var linkThreshold: Float
        public var maxReferencePrintsPerFace: Int
        public var maxMergesPerUpdate: Int

        public init(
            similarityThreshold: Float = 0.35,
            linkThreshold: Float = 0.42,
            maxReferencePrintsPerFace: Int = 10,
            maxMergesPerUpdate: Int = 2
        ) {
            let hard = max(0, similarityThreshold)
            let soft = max(hard, max(0, linkThreshold))

            self.similarityThreshold = hard
            self.linkThreshold = soft
            self.maxReferencePrintsPerFace = max(1, maxReferencePrintsPerFace)
            self.maxMergesPerUpdate = max(0, maxMergesPerUpdate)
        }
    }

    public struct LeafClusterSignature: Codable, Sendable, Hashable {
        public var clusterCount: Int
        public var usedReferencePrints: Int

        public init(clusterCount: Int, usedReferencePrints: Int) {
            self.clusterCount = max(0, clusterCount)
            self.usedReferencePrints = max(0, usedReferencePrints)
        }
    }

    private struct PersistedStore: Codable {
        var schemaVersion: Int
        var nextFaceNumber: Int
        var clusters: [FaceCluster]
        var assetToFaceIDs: [String: [String]]
        var updatedAt: Date
    }

    public static let currentSchemaVersion: Int = 1

    private let config: Configuration
    private let storeURL: URL

    private var loaded: Bool = false
    private var store: PersistedStore = PersistedStore(
        schemaVersion: FaceIndexStore.currentSchemaVersion,
        nextFaceNumber: 1,
        clusters: [],
        assetToFaceIDs: [:],
        updatedAt: Date()
    )

    private var saveTask: Task<Void, Never>? = nil
    private var isDirty: Bool = false

    public init(config: Configuration = Configuration()) {
        self.config = config

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("Faces", isDirectory: true)
        self.storeURL = directory.appendingPathComponent("face_index_v1.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AlbumLog.faces.error("FaceIndexStore createDirectory error: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Public API

    public func configuration() -> Configuration {
        config
    }

    public func leafClusterSignature(repCap: Int) async -> LeafClusterSignature {
        await ensureLoaded()

        let cap = max(1, repCap)
        let used = store.clusters.reduce(into: 0) { partial, cluster in
            partial += min(cap, cluster.referencePrints.count)
        }
        return LeafClusterSignature(clusterCount: store.clusters.count, usedReferencePrints: used)
    }

    public func leafClusters(repCap: Int) async -> [FaceCluster] {
        await ensureLoaded()

        let cap = max(1, repCap)

        var out: [FaceCluster] = []
        out.reserveCapacity(store.clusters.count)

        for existing in store.clusters {
            var cluster = existing
            if cluster.referencePrints.count > cap {
                cluster.referencePrints = Array(cluster.referencePrints.prefix(cap))
            }
            out.append(cluster)
        }

        out.sort { $0.faceID < $1.faceID }
        return out
    }

    public func matchOrCreateFaceID(for featurePrintData: Data) async -> (faceID: String, distance: Float?) {
        await ensureLoaded()

        guard !featurePrintData.isEmpty else {
            let faceID = nextFaceID()
            store.updatedAt = Date()
            markDirty()
            return (faceID: faceID, distance: nil)
        }

        let now = Date()

        let incomingPrint: VNFeaturePrintObservation
        do {
            incomingPrint = try unarchiveFeaturePrint(featurePrintData)
        } catch {
            AlbumLog.faces.error("FaceIndexStore unarchive incoming feature print failed: \(String(describing: error), privacy: .public)")
            let faceID = nextFaceID()
            store.updatedAt = now
            markDirty()
            return (faceID: faceID, distance: nil)
        }

        struct ClusterCandidate {
            let index: Int
            let faceID: String
            let distance: Float
        }

        var candidates: [ClusterCandidate] = []
        candidates.reserveCapacity(store.clusters.count)

        for (idx, cluster) in store.clusters.enumerated() {
            var bestDistance: Float? = nil
            for refData in cluster.referencePrints {
                guard !refData.isEmpty else { continue }
                do {
                    let refPrint = try unarchiveFeaturePrint(refData)
                    var distance: Float = 0
                    try incomingPrint.computeDistance(&distance, to: refPrint)
                    if let current = bestDistance {
                        if distance < current { bestDistance = distance }
                    } else {
                        bestDistance = distance
                    }
                } catch {
                    AlbumLog.faces.debug("FaceIndexStore computeDistance skipped: \(String(describing: error), privacy: .public)")
                }
            }

            guard let bestDistance else { continue }
            candidates.append(ClusterCandidate(index: idx, faceID: cluster.faceID, distance: bestDistance))
        }

        if candidates.isEmpty {
            let newFaceID = nextFaceID()
            let newCluster = FaceCluster(
                faceID: newFaceID,
                referencePrints: [featurePrintData],
                createdAt: now,
                updatedAt: now
            )
            store.clusters.append(newCluster)
            store.updatedAt = now
            markDirty()
            FaceDebugLog.created(faceID: newFaceID, closestDistance: nil)
            return (faceID: newFaceID, distance: nil)
        }

        candidates.sort { $0.distance < $1.distance }
        let best = candidates[0]

        if best.distance <= config.linkThreshold {
            let isStrongMatch = best.distance <= config.similarityThreshold
            var didUpdateCluster = false

            var cluster = store.clusters[best.index]
            let minGrowthCount = min(3, config.maxReferencePrintsPerFace)
            if cluster.referencePrints.count < config.maxReferencePrintsPerFace {
                if isStrongMatch || cluster.referencePrints.count < minGrowthCount {
                    cluster.referencePrints.append(featurePrintData)
                    didUpdateCluster = true
                }
            }

            if didUpdateCluster {
                cluster.updatedAt = now
                store.clusters[best.index] = cluster
                store.updatedAt = now
                markDirty()
            }

            if isStrongMatch {
                FaceDebugLog.match(faceID: best.faceID, distance: best.distance)
            } else {
                FaceDebugLog.weakMatch(faceID: best.faceID, distance: best.distance)
            }

            if config.maxMergesPerUpdate > 0 {
                var mergesRemaining = config.maxMergesPerUpdate
                for other in candidates.dropFirst() {
                    if mergesRemaining <= 0 { break }
                    if other.distance > config.linkThreshold { break }
                    guard let mergeDistance = clusterDistance(faceID: best.faceID, otherFaceID: other.faceID) else { continue }
                    guard mergeDistance <= config.linkThreshold else { continue }
                    mergeFaceID(from: other.faceID, into: best.faceID, mergedAt: now)
                    FaceDebugLog.merged(into: best.faceID, from: other.faceID, distance: mergeDistance)
                    mergesRemaining -= 1
                }
            }

            return (faceID: best.faceID, distance: best.distance)
        }

        let newFaceID = nextFaceID()
        let newCluster = FaceCluster(
            faceID: newFaceID,
            referencePrints: [featurePrintData],
            createdAt: now,
            updatedAt: now
        )
        store.clusters.append(newCluster)
        store.updatedAt = now
        markDirty()
        FaceDebugLog.created(faceID: newFaceID, closestDistance: best.distance)
        return (faceID: newFaceID, distance: nil)
    }

    public func nearestFaceMatch(for featurePrintData: Data) async -> FaceMatchResult? {
        await ensureLoaded()

        guard !featurePrintData.isEmpty else { return nil }

        let incomingPrint: VNFeaturePrintObservation
        do {
            incomingPrint = try unarchiveFeaturePrint(featurePrintData)
        } catch {
            AlbumLog.faces.error("FaceIndexStore unarchive nearest feature print failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        var best: FaceMatchResult? = nil

        for cluster in store.clusters {
            var bestDistance: Float? = nil
            for refData in cluster.referencePrints {
                guard !refData.isEmpty else { continue }
                do {
                    let refPrint = try unarchiveFeaturePrint(refData)
                    var distance: Float = 0
                    try incomingPrint.computeDistance(&distance, to: refPrint)
                    if let current = bestDistance {
                        if distance < current { bestDistance = distance }
                    } else {
                        bestDistance = distance
                    }
                } catch {
                    AlbumLog.faces.debug("FaceIndexStore nearest computeDistance skipped: \(String(describing: error), privacy: .public)")
                }
            }

            guard let bestDistance else { continue }
            if let currentBest = best {
                if bestDistance < currentBest.distance {
                    best = FaceMatchResult(faceID: cluster.faceID, distance: bestDistance)
                }
            } else {
                best = FaceMatchResult(faceID: cluster.faceID, distance: bestDistance)
            }
        }

        return best
    }

    public func record(assetID: String, faceIDs: [String]) async {
        await ensureLoaded()

        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let normalizedFaceIDs = normalizeFaceIDs(faceIDs)
        if normalizedFaceIDs.isEmpty {
            store.assetToFaceIDs[id] = nil
        } else {
            store.assetToFaceIDs[id] = normalizedFaceIDs
        }

        store.updatedAt = Date()
        markDirty()
        await saveIfDirty()
    }

    public func faceIDs(for assetID: String) async -> [String] {
        await ensureLoaded()
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        return store.assetToFaceIDs[id] ?? []
    }

    public func faceIDsByAssetID(for assetIDs: [String]) async -> [String: [String]] {
        await ensureLoaded()
        guard !assetIDs.isEmpty else { return [:] }

        var out: [String: [String]] = [:]
        out.reserveCapacity(min(256, assetIDs.count))

        for raw in assetIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if let faceIDs = store.assetToFaceIDs[id], !faceIDs.isEmpty {
                out[id] = faceIDs
            }
        }

        return out
    }

    public func assets(for faceID: String) async -> [String] {
        await ensureLoaded()
        let target = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }

        var out: [String] = []
        out.reserveCapacity(32)

        for (assetID, faceIDs) in store.assetToFaceIDs {
            if faceIDs.contains(target) {
                out.append(assetID)
            }
        }

        out.sort()
        return out
    }

    public func assets(forFaceIDs faceIDs: [String]) async -> [String] {
        await ensureLoaded()

        let trimmed = faceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return [] }

        let targets = Set(trimmed)
        guard !targets.isEmpty else { return [] }

        var out: [String] = []
        out.reserveCapacity(64)

        for (assetID, assetFaceIDs) in store.assetToFaceIDs {
            if assetFaceIDs.contains(where: { targets.contains($0) }) {
                out.append(assetID)
            }
        }

        out.sort()
        return out
    }

    public func bucketSummaries() async -> [FaceBucketSummary] {
        await ensureLoaded()

        var counts: [String: Int] = [:]
        counts.reserveCapacity(store.clusters.count)

        for (_, faceIDs) in store.assetToFaceIDs {
            for faceID in faceIDs {
                counts[faceID, default: 0] += 1
            }
        }

        var out: [FaceBucketSummary] = []
        out.reserveCapacity(counts.count)
        for (faceID, count) in counts {
            guard count > 0 else { continue }
            out.append(FaceBucketSummary(faceID: faceID, assetCount: count))
        }

        out.sort { lhs, rhs in
            if lhs.assetCount == rhs.assetCount { return lhs.faceID < rhs.faceID }
            return lhs.assetCount > rhs.assetCount
        }

        return out
    }

    public func faceGroups(faceIDs: [String], distanceThreshold: Float) async -> [[String]] {
        let groupings = await faceGroupings(faceIDs: faceIDs, distanceThresholds: [distanceThreshold])
        return groupings.first ?? []
    }

    public func faceGroupings(faceIDs: [String], distanceThresholds: [Float]) async -> [[[String]]] {
        await ensureLoaded()

        let thresholds = distanceThresholds.map { max(0, $0) }
        guard !thresholds.isEmpty else { return [] }

        let uniqueFaceIDs = normalizeFaceIDs(faceIDs)
        if uniqueFaceIDs.isEmpty {
            return Array(repeating: [], count: thresholds.count)
        }
        if uniqueFaceIDs.count == 1 {
            return Array(repeating: [uniqueFaceIDs], count: thresholds.count)
        }

        let maxThreshold = thresholds.max() ?? 0

        var clusterByID: [String: FaceCluster] = [:]
        clusterByID.reserveCapacity(store.clusters.count)
        for cluster in store.clusters {
            clusterByID[cluster.faceID] = cluster
        }

        struct ClusterPrintPack {
            let faceID: String
            let prints: [VNFeaturePrintObservation]
        }

        var packs: [ClusterPrintPack] = []
        packs.reserveCapacity(uniqueFaceIDs.count)

        for faceID in uniqueFaceIDs {
            guard let cluster = clusterByID[faceID] else {
                packs.append(ClusterPrintPack(faceID: faceID, prints: []))
                continue
            }

            var prints: [VNFeaturePrintObservation] = []
            prints.reserveCapacity(min(8, cluster.referencePrints.count))

            for refData in cluster.referencePrints {
                guard !refData.isEmpty else { continue }
                if let obs = try? unarchiveFeaturePrint(refData) {
                    prints.append(obs)
                }
            }

            packs.append(ClusterPrintPack(faceID: faceID, prints: prints))
        }

        struct Edge {
            let i: Int
            let j: Int
            let distance: Float
        }

        var edges: [Edge] = []
        edges.reserveCapacity(min(50_000, (packs.count * (packs.count - 1)) / 2))

        var pairCount = 0

        for i in 0..<packs.count {
            if Task.isCancelled { break }
            let lhs = packs[i].prints
            guard !lhs.isEmpty else { continue }

            for j in (i + 1)..<packs.count {
                if Task.isCancelled { break }
                let rhs = packs[j].prints
                guard !rhs.isEmpty else { continue }

                pairCount += 1

                var best: Float = .greatestFiniteMagnitude

                for l in lhs {
                    for r in rhs {
                        do {
                            var distance: Float = 0
                            try l.computeDistance(&distance, to: r)
                            if distance < best { best = distance }
                        } catch {
                            continue
                        }
                    }
                }

                if best.isFinite, best <= maxThreshold {
                    edges.append(Edge(i: i, j: j, distance: best))
                }

                if pairCount.isMultiple(of: 192) {
                    await Task.yield()
                }
            }
        }

        edges.sort { $0.distance < $1.distance }

        let indexedThresholds: [(value: Float, originalIndex: Int)] = thresholds.enumerated()
            .map { (value: $0.element, originalIndex: $0.offset) }
            .sorted { $0.value < $1.value }

        var parent = Array(0..<packs.count)
        var rank = Array(repeating: 0, count: packs.count)

        func find(_ x: Int) -> Int {
            var i = x
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }

        func union(_ x: Int, _ y: Int) {
            let rx = find(x)
            let ry = find(y)
            guard rx != ry else { return }

            if rank[rx] < rank[ry] {
                parent[rx] = ry
            } else if rank[rx] > rank[ry] {
                parent[ry] = rx
            } else {
                parent[ry] = rx
                rank[rx] += 1
            }
        }

        func snapshotGroups() -> [[String]] {
            var groupsByRoot: [Int: [String]] = [:]
            groupsByRoot.reserveCapacity(packs.count)

            for (idx, pack) in packs.enumerated() {
                let root = find(idx)
                groupsByRoot[root, default: []].append(pack.faceID)
            }

            var out: [[String]] = []
            out.reserveCapacity(groupsByRoot.count)

            for (_, ids) in groupsByRoot {
                let normalized = normalizeFaceIDs(ids)
                guard !normalized.isEmpty else { continue }
                out.append(normalized)
            }

            out.sort { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                let a = lhs.first ?? ""
                let b = rhs.first ?? ""
                return a < b
            }

            return out
        }

        var results = Array(repeating: [[String]](), count: thresholds.count)
        var edgeIndex = 0

        for threshold in indexedThresholds {
            while edgeIndex < edges.count && edges[edgeIndex].distance <= threshold.value {
                let edge = edges[edgeIndex]
                union(edge.i, edge.j)
                edgeIndex += 1
            }

            results[threshold.originalIndex] = snapshotGroups()
        }

        return results
    }

    public func directoryEntries() async -> [FaceClusterDirectoryEntry] {
        await ensureLoaded()

        var counts: [String: Int] = [:]
        counts.reserveCapacity(store.clusters.count)

        for (_, faceIDs) in store.assetToFaceIDs {
            for faceID in faceIDs {
                counts[faceID, default: 0] += 1
            }
        }

        var clustersByID: [String: FaceCluster] = [:]
        clustersByID.reserveCapacity(store.clusters.count)
        for c in store.clusters {
            clustersByID[c.faceID] = c
        }

        var out: [FaceClusterDirectoryEntry] = []
        out.reserveCapacity(counts.count)

        for (faceID, count) in counts {
            guard count > 0 else { continue }
            if let cluster = clustersByID[faceID] {
                out.append(
                    FaceClusterDirectoryEntry(
                        faceID: cluster.faceID,
                        displayName: cluster.preferredDisplayName,
                        rawDisplayName: cluster.displayName,
                        labelSource: cluster.labelSource,
                        linkedContactID: cluster.linkedContactID,
                        assetCount: count
                    )
                )
            } else {
                let trimmed = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                out.append(
                    FaceClusterDirectoryEntry(
                        faceID: trimmed,
                        displayName: trimmed,
                        rawDisplayName: nil,
                        labelSource: .none,
                        linkedContactID: nil,
                        assetCount: count
                    )
                )
            }
        }

        out.sort { lhs, rhs in
            if lhs.assetCount == rhs.assetCount {
                if lhs.displayName == rhs.displayName { return lhs.faceID < rhs.faceID }
                return lhs.displayName < rhs.displayName
            }
            return lhs.assetCount > rhs.assetCount
        }

        return out
    }

    public func displayName(for faceID: String) async -> String {
        await ensureLoaded()
        let trimmed = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let cluster = store.clusters.first(where: { $0.faceID == trimmed }) else { return trimmed }
        return cluster.preferredDisplayName
    }

    public func promptTokenInfoByFaceID(for faceIDs: [String]) async -> [String: FacePromptTokenInfo] {
        await ensureLoaded()

        guard !faceIDs.isEmpty else { return [:] }

        var clustersByID: [String: FaceCluster] = [:]
        clustersByID.reserveCapacity(store.clusters.count)
        for c in store.clusters {
            clustersByID[c.faceID] = c
        }

        var out: [String: FacePromptTokenInfo] = [:]
        out.reserveCapacity(min(256, faceIDs.count))

        for raw in faceIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if out[id] != nil { continue }

            if let cluster = clustersByID[id] {
                out[id] = FacePromptTokenInfo(token: cluster.preferredDisplayName, isLabeled: cluster.hasUserVisibleLabel)
            } else {
                out[id] = FacePromptTokenInfo(token: id, isLabeled: false)
            }
        }

        return out
    }

    public func setManualLabel(faceID: String, displayName: String) async {
        await ensureLoaded()

        let id = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !name.isEmpty else { return }
        guard let idx = store.clusters.firstIndex(where: { $0.faceID == id }) else { return }

        let now = Date()
        var cluster = store.clusters[idx]

        cluster.displayName = name
        cluster.labelSource = .manual
        cluster.updatedAt = now

        store.clusters[idx] = cluster
        store.updatedAt = now
        markDirty()
        await saveIfDirty()
    }

    public func clearLabel(faceID: String) async {
        await ensureLoaded()

        let id = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard let idx = store.clusters.firstIndex(where: { $0.faceID == id }) else { return }

        let now = Date()
        var cluster = store.clusters[idx]
        cluster.displayName = nil
        cluster.labelSource = .none
        cluster.linkedContactID = nil
        cluster.updatedAt = now

        store.clusters[idx] = cluster
        store.updatedAt = now
        markDirty()
        await saveIfDirty()
    }

    public func setClusterLabelFromContact(
        faceID: String,
        contactID: String,
        displayName: String,
        renameOnlyIfUnlabeled: Bool = true
    ) async -> Bool {
        await ensureLoaded()

        let id = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = contactID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !cid.isEmpty, !name.isEmpty else { return false }
        guard let idx = store.clusters.firstIndex(where: { $0.faceID == id }) else { return false }

        var cluster = store.clusters[idx]

        let existingName = cluster.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasManual = (cluster.labelSource == .manual && (existingName?.isEmpty == false))
        if hasManual { return false }

        if renameOnlyIfUnlabeled {
            if cluster.labelSource == .contact {
                if cluster.linkedContactID == cid {
                    // Same contact; allow refreshing the name.
                } else {
                    return false
                }
            }
        }

        let now = Date()
        cluster.displayName = name
        cluster.labelSource = .contact
        cluster.linkedContactID = cid
        cluster.updatedAt = now

        store.clusters[idx] = cluster
        store.updatedAt = now
        markDirty()
        await saveIfDirty()
        return true
    }

    // MARK: Internal

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true

        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PersistedStore.self, from: data)
            if decoded.schemaVersion == FaceIndexStore.currentSchemaVersion {
                store = decoded
            } else {
                AlbumLog.faces.error("FaceIndexStore schema mismatch found=\(decoded.schemaVersion, privacy: .public) expected=\(FaceIndexStore.currentSchemaVersion, privacy: .public)")
            }
        } catch {
            AlbumLog.faces.error("FaceIndexStore load error: \(String(describing: error), privacy: .public)")
        }
    }

    private func markDirty() {
        isDirty = true
        scheduleSave()
        NotificationCenter.default.post(name: .albumFaceIndexDidUpdate, object: nil)
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
            AlbumLog.faces.error("FaceIndexStore save error: \(String(describing: error), privacy: .public)")
        }
    }

    private func nextFaceID() -> String {
        let n = max(1, store.nextFaceNumber)
        store.nextFaceNumber = n + 1
        return String(format: "face_%04d", n)
    }

    private func normalizeFaceIDs(_ faceIDs: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(faceIDs.count)
        var seen: Set<String> = []
        seen.reserveCapacity(faceIDs.count)

        for raw in faceIDs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }

        out.sort()
        return out
    }

    private func clusterDistance(faceID: String, otherFaceID: String) -> Float? {
        guard faceID != otherFaceID else { return nil }

        guard let lhs = store.clusters.first(where: { $0.faceID == faceID }),
              let rhs = store.clusters.first(where: { $0.faceID == otherFaceID }) else {
            return nil
        }

        var best: Float? = nil

        for lhsData in lhs.referencePrints {
            guard !lhsData.isEmpty else { continue }
            do {
                let lhsPrint = try unarchiveFeaturePrint(lhsData)
                for rhsData in rhs.referencePrints {
                    guard !rhsData.isEmpty else { continue }
                    do {
                        let rhsPrint = try unarchiveFeaturePrint(rhsData)
                        var distance: Float = 0
                        try lhsPrint.computeDistance(&distance, to: rhsPrint)
                        if let current = best {
                            if distance < current { best = distance }
                        } else {
                            best = distance
                        }
                    } catch {
                        AlbumLog.faces.debug("FaceIndexStore clusterDistance skipped: \(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                AlbumLog.faces.debug("FaceIndexStore clusterDistance skipped: \(String(describing: error), privacy: .public)")
            }
        }

        return best
    }

    private func mergeFaceID(from sourceFaceID: String, into targetFaceID: String, mergedAt: Date) {
        let source = sourceFaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetFaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty else { return }
        guard source != target else { return }

        guard let targetIndex = store.clusters.firstIndex(where: { $0.faceID == target }),
              let sourceIndex = store.clusters.firstIndex(where: { $0.faceID == source }) else {
            return
        }

        var targetCluster = store.clusters[targetIndex]
        let sourceCluster = store.clusters[sourceIndex]

        func hasManualLabel(_ cluster: FaceCluster) -> Bool {
            guard cluster.labelSource == .manual else { return false }
            let trimmed = cluster.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        }

        func hasContactLabel(_ cluster: FaceCluster) -> Bool {
            guard cluster.labelSource == .contact else { return false }
            let trimmed = cluster.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        }

        if !hasManualLabel(targetCluster) {
            if hasManualLabel(sourceCluster) {
                targetCluster.displayName = sourceCluster.displayName
                targetCluster.labelSource = .manual
                targetCluster.linkedContactID = sourceCluster.linkedContactID
            } else if !hasContactLabel(targetCluster), hasContactLabel(sourceCluster) {
                targetCluster.displayName = sourceCluster.displayName
                targetCluster.labelSource = .contact
                targetCluster.linkedContactID = sourceCluster.linkedContactID
            }
        }

        if targetCluster.referencePrints.count < config.maxReferencePrintsPerFace {
            var mergedRefs = targetCluster.referencePrints
            mergedRefs.reserveCapacity(min(config.maxReferencePrintsPerFace, mergedRefs.count + sourceCluster.referencePrints.count))
            for ref in sourceCluster.referencePrints {
                if mergedRefs.count >= config.maxReferencePrintsPerFace { break }
                mergedRefs.append(ref)
            }
            targetCluster.referencePrints = mergedRefs
        }

        targetCluster.updatedAt = mergedAt
        store.clusters[targetIndex] = targetCluster
        store.clusters.remove(at: sourceIndex)

        var updatedMappings: [String: [String]] = [:]
        updatedMappings.reserveCapacity(store.assetToFaceIDs.count)

        for (assetID, faceIDs) in store.assetToFaceIDs {
            if !faceIDs.contains(source) {
                updatedMappings[assetID] = faceIDs
                continue
            }

            let replaced = faceIDs.map { $0 == source ? target : $0 }
            let normalized = normalizeFaceIDs(replaced)
            updatedMappings[assetID] = normalized.isEmpty ? nil : normalized
        }

        store.assetToFaceIDs = updatedMappings
        store.updatedAt = mergedAt
        markDirty()
    }

    private func unarchiveFeaturePrint(_ data: Data) throws -> VNFeaturePrintObservation {
        guard let obs = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
            throw FaceIndexUnarchiveError.invalidPayload
        }
        return obs
    }
}

private enum FaceIndexUnarchiveError: Error {
    case invalidPayload
}
