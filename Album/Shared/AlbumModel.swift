import SwiftUI
import CoreGraphics

public enum AlbumDatasetSource: String, Sendable, Codable, CaseIterable {
    case photos
    case demo
}

@MainActor
public final class AlbumModel: ObservableObject {
    public let assetProvider: AlbumAssetProvider
    private let sidecarStore: AlbumSidecarStore
    public let oracle: AlbumOracle
    private let visionService = AlbumVisionSummaryService.shared

    // MARK: Hub state (required)

    @Published public var panelMode: AlbumPanelMode = .recommends {
        didSet {
            guard panelMode != oldValue else { return }
            if panelMode == .memories {
                if let id = currentItem?.id {
                    memoryAnchorID = id
                    rebuildMemoryWindow(resetToAnchor: true)
                }
            }
        }
    }
    @Published public var selectedQuery: AlbumQuery = .allPhotos
    @Published public var currentItem: AlbumItem? = nil {
        didSet {
            guard currentItem?.id != oldValue?.id else { return }

            if !isSyncingSelection {
                isSyncingSelection = true
                currentAssetID = currentItem?.id
                isSyncingSelection = false
            }

            guard let item = currentItem else { return }

            ensureVisionSummary(for: item.id, reason: "current_item")
            appendToHistory(assetID: item.id)

            neighborsReady = false
            recommendAnchorID = item.id
            recommendItems = []

            if panelMode == .memories {
                memoryAnchorID = item.id
                rebuildMemoryWindow(resetToAnchor: true)
            }
        }
    }
    @Published public var history: [AlbumItem] = []
    @Published public var hiddenIDs: Set<String> = []

    // Recommends mode state
    @Published public var recommendItems: [AlbumItem] = []
    @Published public var recommendAnchorID: String? = nil
    @Published public var neighborsReady: Bool = false

    // Memories mode state
    @Published public var memoryAnchorID: String? = nil
    @Published public var memoryWindowItems: [AlbumItem] = []
    @Published public var memoryPageStartIndex: Int = 0
    @Published public var memoryGroupSize: Int = 24
    @Published public var memoryOverlap: Int = 4
    @Published public var memoryPrevEnabled: Bool = false
    @Published public var memoryNextEnabled: Bool = false
    @Published public var memoryLabel: String = ""

    // Layout presentation state
    @Published public var isLayoutPresented: Bool = false

    // Immersive tuning requests (model decides; immersive applies)
    @Published public var tuningDeltaRequest: AlbumTuningDeltaRequest? = nil

    @Published public var isPaused: Bool = false
    @Published public var absorbInterval: Double = 10
    @Published public var absorbNowRequestID: UUID = UUID()

    @Published public private(set) var datasetSource: AlbumDatasetSource = .photos
    @Published public private(set) var lastAssetFetchCount: Int = 0

    @Published public private(set) var libraryAuthorization: AlbumLibraryAuthorizationStatus = .notDetermined
    @Published public private(set) var items: [AlbumItem] = []
    @Published public private(set) var lastAssetLoadError: String? = nil

    public var assets: [AlbumAsset] { items }

    @Published public var currentAssetID: String? = nil {
        didSet {
            guard currentAssetID != oldValue else { return }
            guard !isSyncingSelection else { return }

            isSyncingSelection = true
            if let id = currentAssetID, let item = item(for: id) {
                currentItem = item
            } else {
                currentItem = nil
            }
            isSyncingSelection = false
        }
    }

    @Published public var historyAssetIDs: [String] = [] {
        didSet {
            guard historyAssetIDs != oldValue else { return }
            history = historyAssetIDs.compactMap { item(for: $0) }
        }
    }
    @Published public var poppedAssetIDs: [String] = []
    @Published public var scenes: [AlbumSceneRecord] = []

    @Published public var aiNextAssetIDs: Set<String> = []
    @Published public var recommendedAssetID: String? = nil
    @Published public var recommendedAssetIDs: [String] = []

    @Published public var thumbRequest: AlbumThumbRequest? = nil
    @Published public var thumbThinkingSince: Date? = nil
    @Published public var thumbThinkingFeedback: AlbumThumbFeedback? = nil
    @Published public var thumbStatusMessage: String? = nil
    @Published public var thumbFeedbackByAssetID: [String: AlbumThumbFeedback] = [:]

    @Published public var visionSummaryByAssetID: [String: String] = [:]
    @Published public var visionPendingAssetIDs: Set<String> = []

    @Published public var curvedCanvasEnabled: Bool = false

    @Published public private(set) var isLoadingItems: Bool = false

    private var sidecar: AlbumSidecar
    private var saveSidecarTask: Task<Void, Never>? = nil
    private var thumbTask: Task<Void, Never>? = nil
    private var latestThumbRequestID: UUID? = nil
    private var isSyncingSelection: Bool = false

    public init(
        assetProvider: (any AlbumAssetProvider)? = nil,
        sidecarStore: AlbumSidecarStore = AlbumSidecarStore(),
        oracle: AlbumOracle = AlbumHeuristicOracle()
    ) {
        self.assetProvider = assetProvider ?? PhotosAlbumAssetProvider()
        self.sidecarStore = sidecarStore
        self.oracle = oracle

        let loaded = sidecarStore.load()
        self.sidecar = loaded
        self.visionSummaryByAssetID = loaded.visionSummaryByLocalIdentifier
        self.thumbFeedbackByAssetID = loaded.thumbFeedbackByLocalIdentifier
        self.hiddenIDs = loaded.hiddenLocalIdentifiers
        self.scenes = AlbumSceneStore.load()
        self.libraryAuthorization = self.assetProvider.authorizationStatus()
    }

    public func requestAbsorbNow() {
        absorbNowRequestID = UUID()
    }

    public func item(for itemID: String) -> AlbumItem? {
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return items.first(where: { $0.id == id })
    }

    public func asset(for assetID: String) -> AlbumAsset? {
        item(for: assetID)
    }

    public func createdYearMonth(for assetID: String) -> String? {
        guard let asset = asset(for: assetID) else { return nil }
        return createdYearMonth(for: asset)
    }

    public func createdYearMonth(for asset: AlbumAsset) -> String? {
        guard let date = asset.creationDate else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        return String(format: "%04d-%02d", year, month)
    }

    public func locationBucket(for assetID: String) -> String? {
        guard let asset = asset(for: assetID) else { return nil }
        return locationBucket(for: asset)
    }

    public func locationBucket(for asset: AlbumAsset) -> String? {
        guard let loc = asset.location else { return nil }
        let quantum = 0.10
        let lat = (loc.latitude / quantum).rounded() * quantum
        let lon = (loc.longitude / quantum).rounded() * quantum
        return String(format: "%.2f,%.2f", lat, lon)
    }

    public func semanticHandle(for assetID: String) -> String {
        guard let asset = asset(for: assetID) else { return "" }
        return semanticHandle(for: asset)
    }

    public func semanticHandle(for asset: AlbumAsset) -> String {
        if let summary = visionSummaryByAssetID[asset.localIdentifier], !summary.isEmpty {
            return summary
        }

        var parts: [String] = []
        parts.reserveCapacity(4)

        parts.append(asset.mediaType == .video ? "video" : "photo")
        if let ym = createdYearMonth(for: asset) { parts.append("date:\(ym)") }
        if let bucket = locationBucket(for: asset) { parts.append("loc:\(bucket)") }
        if asset.isFavorite { parts.append("favorite") }

        return parts.joined(separator: " | ")
    }

    public func loadAssetsIfNeeded(limit: Int = 600, mode: AlbumSamplingMode = .recent) async {
        guard items.isEmpty else { return }
        await loadAssets(limit: limit, mode: mode)
    }

    public func loadAssets(limit: Int = 600, mode: AlbumSamplingMode = .recent) async {
        guard !isLoadingItems else { return }
        isLoadingItems = true
        defer { isLoadingItems = false }

        datasetSource = .photos
        lastAssetLoadError = nil
        let auth = assetProvider.authorizationStatus()
        libraryAuthorization = auth
        AlbumLog.photos.info("loadAssets(mode: \(mode.rawValue, privacy: .public), limit: \(limit)) auth: \(String(describing: auth), privacy: .public)")

        let effectiveAuth: AlbumLibraryAuthorizationStatus
        if auth == .notDetermined {
            effectiveAuth = await assetProvider.requestAuthorization()
        } else {
            effectiveAuth = auth
        }
        libraryAuthorization = effectiveAuth
        AlbumLog.photos.info("loadAssets effectiveAuth: \(String(describing: effectiveAuth), privacy: .public)")

        guard effectiveAuth == .authorized || effectiveAuth == .limited else {
            items = []
            return
        }

        do {
            let fetched = try await assetProvider.fetchAssets(limit: limit, mode: mode)
            lastAssetFetchCount = fetched.count
            items = fetched.filter { !hiddenIDs.contains($0.id) }
            AlbumLog.photos.info("loadAssets fetched: \(fetched.count) filtered: \(self.items.count) hiddenIDs: \(self.hiddenIDs.count)")
            if let id = currentAssetID, let item = item(for: id) {
                currentItem = item
            }
            history = historyAssetIDs.compactMap { item(for: $0) }
        } catch {
            lastAssetLoadError = String(describing: error)
            lastAssetFetchCount = 0
            items = []
            AlbumLog.photos.error("loadAssets error: \(String(describing: error), privacy: .public)")
        }
    }

    public func loadItemsIfNeeded(limit: Int? = nil) async {
        guard items.isEmpty else { return }
        await loadItems(limit: limit)
    }

    public func loadItems(limit: Int? = nil, query: AlbumQuery? = nil) async {
        guard !isLoadingItems else { return }
        isLoadingItems = true
        defer { isLoadingItems = false }

        datasetSource = .photos
        lastAssetLoadError = nil
        let auth = assetProvider.authorizationStatus()
        libraryAuthorization = auth
        let q = query ?? selectedQuery
        AlbumLog.photos.info("loadItems(query: \(q.id, privacy: .public), limit: \(limit ?? -1)) auth: \(String(describing: auth), privacy: .public)")

        let effectiveAuth: AlbumLibraryAuthorizationStatus
        if auth == .notDetermined {
            effectiveAuth = await assetProvider.requestAuthorization()
        } else {
            effectiveAuth = auth
        }
        libraryAuthorization = effectiveAuth
        AlbumLog.photos.info("loadItems effectiveAuth: \(String(describing: effectiveAuth), privacy: .public)")

        guard effectiveAuth == .authorized || effectiveAuth == .limited else {
            items = []
            return
        }

        do {
            let fetched = try await assetProvider.fetchAssets(limit: limit ?? 600, query: q)
            lastAssetFetchCount = fetched.count
            items = fetched.filter { !hiddenIDs.contains($0.id) }
            AlbumLog.photos.info("loadItems fetched: \(fetched.count) filtered: \(self.items.count) hiddenIDs: \(self.hiddenIDs.count)")
            if let id = currentAssetID, let item = item(for: id) {
                currentItem = item
            }
            history = historyAssetIDs.compactMap { item(for: $0) }
            if panelMode == .memories {
                rebuildMemoryWindow(resetToAnchor: memoryWindowItems.isEmpty)
            }
        } catch {
            lastAssetLoadError = String(describing: error)
            lastAssetFetchCount = 0
            items = []
            AlbumLog.photos.error("loadItems error: \(String(describing: error), privacy: .public)")
        }
    }

    public func loadDemoItems(count: Int = 240) {
        AlbumLog.model.info("loadDemoItems(count: \(count))")
        let fetched = AlbumDemoLibrary.makeAssets(count: count)
        lastAssetFetchCount = fetched.count
        datasetSource = .demo
        lastAssetLoadError = nil

        items = fetched.filter { !hiddenIDs.contains($0.id) }
        AlbumLog.model.info("loadDemoItems loaded: \(self.items.count) hiddenIDs: \(self.hiddenIDs.count)")

        if let id = currentAssetID, let item = item(for: id) {
            currentItem = item
        } else {
            currentAssetID = nil
            currentItem = nil
        }

        history = historyAssetIDs.compactMap { item(for: $0) }
        if panelMode == .memories {
            rebuildMemoryWindow(resetToAnchor: memoryWindowItems.isEmpty)
        }
    }

    public func requestThumbnail(assetID: String, targetSize: CGSize) async -> AlbumImage? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if datasetSource == .demo || AlbumDemoLibrary.isDemoID(id) {
            let mediaType = asset(for: id)?.mediaType
            return AlbumDemoLibrary.requestThumbnail(localIdentifier: id, targetSize: targetSize, mediaType: mediaType)
        }

        return await assetProvider.requestThumbnail(localIdentifier: id, targetSize: targetSize)
    }

    public func requestVideoURL(assetID: String) async -> URL? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if datasetSource == .demo || AlbumDemoLibrary.isDemoID(id) {
            return nil
        }

        return await assetProvider.requestVideoURL(localIdentifier: id)
    }

    public func refreshRecommends() {
        guard let id = currentAssetID else { return }
        let feedback = thumbFeedbackByAssetID[id] ?? .up
        sendThumb(feedback, assetID: id)
    }

    public func memoryPrevPage() {
        shiftMemoryPage(delta: -1)
    }

    public func memoryNextPage() {
        shiftMemoryPage(delta: 1)
    }

    public func sendThumb(_ feedback: AlbumThumbFeedback, assetID: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        thumbFeedbackByAssetID[id] = feedback
        scheduleSidecarSave()

        thumbThinkingSince = Date()
        thumbThinkingFeedback = feedback
        thumbStatusMessage = nil

        let requestID = UUID()
        latestThumbRequestID = requestID

        thumbTask?.cancel()
        thumbTask = Task { [weak self] in
            await self?.processThumb(feedback: feedback, assetID: id, requestID: requestID)
        }
    }

    @discardableResult
    public func appendToHistoryIfNew(assetID: String) -> Bool {
        guard !historyAssetIDs.contains(assetID) else { return false }
        historyAssetIDs.append(assetID)
        return true
    }

    public func appendToHistory(assetID: String) {
        if let idx = historyAssetIDs.firstIndex(of: assetID) {
            historyAssetIDs.remove(at: idx)
        }
        historyAssetIDs.append(assetID)
    }

    public func clearHistory() {
        historyAssetIDs.removeAll()
        aiNextAssetIDs.removeAll()
    }

    public func createScene(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let record = AlbumSceneRecord(name: trimmed, assetIDs: poppedAssetIDs)
        scenes.append(record)
        AlbumSceneStore.save(scenes)
    }

    public func deleteScenes(at offsets: IndexSet) {
        scenes.remove(atOffsets: offsets)
        AlbumSceneStore.save(scenes)
    }

    public func updateScene(_ scene: AlbumSceneRecord) {
        guard let idx = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[idx].assetIDs = poppedAssetIDs
        scenes[idx].createdAt = Date()
        AlbumSceneStore.save(scenes)
    }

    public func appendPoppedAsset(_ assetID: String) {
        if !poppedAssetIDs.contains(assetID) {
            poppedAssetIDs.append(assetID)
        }
    }

    public func hideAsset(_ assetID: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        guard hiddenIDs.insert(id).inserted else { return }
        scheduleSidecarSave()

        items.removeAll(where: { $0.id == id })
        recommendItems.removeAll(where: { $0.id == id })
        memoryWindowItems.removeAll(where: { $0.id == id })

        historyAssetIDs.removeAll(where: { $0 == id })

        if currentAssetID == id {
            currentAssetID = nil
        }

        if panelMode == .memories {
            rebuildMemoryWindow(resetToAnchor: false)
        }
    }

    public func pushRecommendedAsset(_ assetID: String) {
        let maxStored = 12
        recommendedAssetIDs.removeAll(where: { $0 == assetID })
        recommendedAssetIDs.insert(assetID, at: 0)
        if recommendedAssetIDs.count > maxStored {
            recommendedAssetIDs.removeSubrange(maxStored..<recommendedAssetIDs.count)
        }
    }

    public func setVisionSummary(_ summary: String, for assetID: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        visionSummaryByAssetID[assetID] = trimmed
        sidecar.visionSummaryByLocalIdentifier[assetID] = trimmed
        scheduleSidecarSave()
    }

    public func ensureVisionSummary(for assetID: String, reason: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        if visionSummaryByAssetID[id] != nil { return }
        if visionPendingAssetIDs.contains(id) { return }

        if datasetSource == .demo || AlbumDemoLibrary.isDemoID(id) {
            visionSummaryByAssetID[id] = AlbumDemoLibrary.placeholderTitle(for: id, mediaType: asset(for: id)?.mediaType)
            return
        }

        visionPendingAssetIDs.insert(id)

        Task { [assetProvider, visionService] in
            defer {
                Task { @MainActor in
                    visionPendingAssetIDs.remove(id)
                }
            }

            let image = await assetProvider.requestThumbnail(localIdentifier: id, targetSize: CGSize(width: 384, height: 384))

#if canImport(UIKit)
            let data = image?.jpegData(compressionQuality: 0.82) ?? image?.pngData()
#else
            let data: Data? = nil
#endif

            guard let data else { return }
            guard let summary = await visionService.summaryForImageData(data, cacheKey: id) else { return }

            await MainActor.run {
                setVisionSummary(summary, for: id)
            }
        }
    }

    private func scheduleSidecarSave() {
        sidecar.thumbFeedbackByLocalIdentifier = thumbFeedbackByAssetID
        sidecar.hiddenLocalIdentifiers = hiddenIDs
        sidecar.updatedAt = Date()

        saveSidecarTask?.cancel()
        saveSidecarTask = Task { [sidecarStore] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await MainActor.run {
                sidecarStore.save(sidecar)
            }
        }
    }

    private func processThumb(feedback: AlbumThumbFeedback, assetID: String, requestID: UUID) async {
        guard let thumbed = item(for: assetID) else {
            if latestThumbRequestID == requestID {
                thumbThinkingSince = nil
                thumbThinkingFeedback = nil
                thumbStatusMessage = "No selected item"
            }
            return
        }

        let snapshot = buildOracleSnapshot(thumbed: thumbed)
        let oracle = self.oracle

        let outcome: AlbumRecOutcome = await Task.detached(priority: .userInitiated) {
            switch feedback {
            case .up:
                return await oracle.recommendThumbUp(snapshot: snapshot, requestID: requestID)
            case .down:
                return await oracle.recommendThumbDown(snapshot: snapshot, requestID: requestID)
            }
        }.value

        guard latestThumbRequestID == requestID else { return }

        thumbThinkingSince = nil
        thumbThinkingFeedback = nil

        guard let result = outcome.response else {
            thumbStatusMessage = outcome.errorDescription ?? "Scoring failed"
            return
        }

        applyOracleResult(feedback: feedback, snapshot: snapshot, result: result)
        thumbStatusMessage = "\(feedback == .up ? "👍" : "👎") Neighbors ready (\(recommendItems.count))"
    }

    private func buildOracleSnapshot(thumbed: AlbumItem) -> AlbumOracleSnapshot {
        let thumbedHandle = semanticHandle(for: thumbed)

        let candidates: [AlbumOracleCandidate] = items.compactMap { item in
            if item.id == thumbed.id { return nil }
            if hiddenIDs.contains(item.id) { return nil }
            return AlbumOracleCandidate(
                key: item.id,
                assetID: item.id,
                mediaType: item.mediaType,
                createdYearMonth: createdYearMonth(for: item),
                locationBucket: locationBucket(for: item),
                visionSummary: semanticHandle(for: item)
            )
        }

        let alreadySeen = Set(history.map(\.id)).union([thumbed.id])

        return AlbumOracleSnapshot(
            thumbedAssetID: thumbed.id,
            thumbedMediaType: thumbed.mediaType,
            thumbedCreatedYearMonth: createdYearMonth(for: thumbed),
            thumbedLocationBucket: locationBucket(for: thumbed),
            thumbedVisionSummary: thumbedHandle,
            candidates: candidates,
            alreadySeenKeys: alreadySeen
        )
    }

    private func applyOracleResult(feedback: AlbumThumbFeedback, snapshot: AlbumOracleSnapshot, result: AlbumRecResponse) {
        recommendAnchorID = snapshot.thumbedAssetID

        let neighborIDs: [String] = result.neighbors.prefix(20).compactMap { neighbor in
            let id = neighbor.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            return id
        }

        recommendItems = neighborIDs.compactMap { item(for: $0) }
            .filter { $0.id != snapshot.thumbedAssetID && !hiddenIDs.contains($0.id) }

        neighborsReady = !recommendItems.isEmpty

        tuningDeltaRequest = AlbumTuningDeltaRequest(deltas: computeTuningDeltas(feedback: feedback, anchorID: snapshot.thumbedAssetID, neighbors: result.neighbors))
    }

    private func computeTuningDeltas(feedback: AlbumThumbFeedback, anchorID: String, neighbors: [AlbumRecNeighbor]) -> [AlbumItemTuningDelta] {
        let trimmedAnchor = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxNeighbors = 20

        let maxSim = neighbors.prefix(maxNeighbors).map(\.similarity).max() ?? 0
        let denom = max(maxSim, 0.0001)

        var deltas: [AlbumItemTuningDelta] = []
        deltas.reserveCapacity(min(neighbors.count, maxNeighbors))

        for neighbor in neighbors.prefix(maxNeighbors) {
            let id = neighbor.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if id == trimmedAnchor { continue }
            if hiddenIDs.contains(id) { continue }

            let w0 = max(0.0, min(1.0, neighbor.similarity / denom))
            let w = pow(Float(w0), 1.25)

            let massMul: Float
            let accelMul: Float

            switch feedback {
            case .up:
                massMul = min(1.70, max(0.60, 1.0 + 0.35 * w))
                accelMul = min(1.40, max(0.60, 1.0 - 0.12 * w))
            case .down:
                massMul = min(1.40, max(0.60, 1.0 - 0.25 * w))
                accelMul = min(1.90, max(0.60, 1.0 + 0.40 * w))
            }

            deltas.append(.init(itemID: id, massMultiplier: massMul, accelerationMultiplier: accelMul))
        }

        return deltas
    }

    private func shiftMemoryPage(delta: Int) {
        guard delta != 0 else { return }
        guard memoryAnchorID != nil else { return }

        let groupSize = max(1, memoryGroupSize)
        let overlap = max(0, min(memoryOverlap, groupSize - 1))
        let step = max(1, groupSize - overlap)

        let timelineCount = items.count
        let maxStart = max(0, timelineCount - groupSize)
        let proposed = memoryPageStartIndex + delta * step
        memoryPageStartIndex = max(0, min(proposed, maxStart))
        rebuildMemoryWindow(resetToAnchor: false)
    }

    private func rebuildMemoryWindow(resetToAnchor: Bool) {
        guard let anchorID = memoryAnchorID else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            return
        }

        let timeline = items.sorted { (a, b) in
            let da = a.creationDate ?? .distantPast
            let db = b.creationDate ?? .distantPast
            if da != db { return da < db }
            return a.id < b.id
        }

        guard !timeline.isEmpty else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            return
        }

        let groupSize = max(1, memoryGroupSize)
        let maxStart = max(0, timeline.count - groupSize)

        if resetToAnchor {
            let anchorIndex = timeline.firstIndex(where: { $0.id == anchorID }) ?? 0
            let centered = max(0, anchorIndex - (groupSize / 2))
            memoryPageStartIndex = min(centered, maxStart)
        } else {
            memoryPageStartIndex = max(0, min(memoryPageStartIndex, maxStart))
        }

        let start = memoryPageStartIndex
        let end = min(timeline.count, start + groupSize)
        memoryWindowItems = Array(timeline[start..<end])

        memoryPrevEnabled = start > 0
        memoryNextEnabled = end < timeline.count
        memoryLabel = formatMemoryLabel(items: memoryWindowItems)
    }

    private func formatMemoryLabel(items: [AlbumItem]) -> String {
        let dates = items.compactMap(\.creationDate)
        guard let first = dates.min(), let last = dates.max() else { return "Unknown dates" }

        let fmt = DateFormatter()
        fmt.locale = Locale.current
        fmt.dateStyle = .medium
        fmt.timeStyle = .none

        if Calendar.current.isDate(first, inSameDayAs: last) {
            return fmt.string(from: first)
        }

        return "\(fmt.string(from: first)) – \(fmt.string(from: last))"
    }
}
