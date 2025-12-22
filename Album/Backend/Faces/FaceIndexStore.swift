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
