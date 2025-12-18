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
    private let libraryIndexStore: AlbumLibraryIndexStore
    private let visionQueue: AlbumVisionQueue
    private let backfillCoordinator: AlbumBackfillCoordinator
    public let oracle: AlbumOracle

    @Published public var theme: AlbumTheme = .dark
    public var palette: AlbumThemePalette { theme.palette }

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

            ensureVisionSummary(for: item.id, reason: "current_item", priority: .userInitiated)
            appendToHistory(assetID: item.id)

            if panelMode == .memories {
                memoryAnchorID = item.id
                rebuildMemoryWindow(resetToAnchor: true)
            }

            restoreCachedRecommendsIfAvailable(for: item.id)
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
    @Published public var memoryGroupSize: Int = 21
    @Published public var memoryOverlap: Int = 1
    @Published public var memoryPrevEnabled: Bool = false
    @Published public var memoryNextEnabled: Bool = false
    @Published public var memoryLabel: String = ""

    // Layout presentation state
    @Published public var isLayoutPresented: Bool = false

    // Immersive tuning requests (model decides; immersive applies)
    @Published public var tuningDeltaRequest: AlbumTuningDeltaRequest? = nil

    @Published public var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            AlbumLog.model.info("Pause toggled: \(self.isPaused ? "paused" : "playing", privacy: .public)")

            if isPaused {
                latestThumbRequestID = nil
                thumbTask?.cancel()
                thumbTask = nil
                thumbThinkingSince = nil
                thumbThinkingFeedback = nil
                thumbStatusMessage = "Paused"
            }
        }
    }
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
    @Published public var visionSourceByAssetID: [String: AlbumVisionSource] = [:]
    @Published public var visionConfidenceByAssetID: [String: Float] = [:]
    @Published public var visionPendingAssetIDs: Set<String> = []

    @Published public private(set) var backfillTargetCount: Int = 0
    @Published public private(set) var backfillCompletedCount: Int = 0
    @Published public private(set) var backfillIsRunning: Bool = false

    @Published public var curvedCanvasEnabled: Bool = false
    @Published public private(set) var curvedWallDumpPages: [CurvedWallDumpPage] = []
    @Published public private(set) var curvedWallDumpIndex: Int = 0
    @Published private var curvedWallPageWindows: [UUID: Int] = [:]

    @Published public private(set) var isLoadingItems: Bool = false

    private var thumbTask: Task<Void, Never>? = nil
    private var latestThumbRequestID: UUID? = nil
    private var isSyncingSelection: Bool = false
    private var recommendsCacheByAnchorID: [String: AlbumRecResponse] = [:]
    private var recommendsFeedbackByAnchorID: [String: AlbumThumbFeedback] = [:]
    private var memoryRebuildTask: Task<Void, Never>? = nil

    public struct CurvedWallDumpPage: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let anchorID: String
        public let neighborIDs: [String]
        public let createdAt: Date

        public init(anchorID: String, neighborIDs: [String], createdAt: Date = Date(), id: UUID = UUID()) {
            self.id = id
            self.anchorID = anchorID
            self.neighborIDs = neighborIDs
            self.createdAt = createdAt
        }
    }

    public struct CurvedWallPanel: Identifiable, Sendable, Equatable {
        public let id: String
        public let assetID: String
        public let heightMeters: Float
        public let viewHeightPoints: Double

        public init(assetID: String, heightMeters: Float, viewHeightPoints: Double) {
            let trimmed = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.assetID = trimmed
            self.id = trimmed
            self.heightMeters = heightMeters
            self.viewHeightPoints = viewHeightPoints
        }
    }

    public init(
        assetProvider: (any AlbumAssetProvider)? = nil,
        sidecarStore: AlbumSidecarStore = AlbumSidecarStore(),
        oracle: AlbumOracle = AlbumAutoOracle()
    ) {
        let provider = assetProvider ?? PhotosAlbumAssetProvider()
        let indexStore = AlbumLibraryIndexStore()
        let visionQueue = AlbumVisionQueue(sidecarStore: sidecarStore, libraryIndexStore: indexStore, assetProvider: provider)
        let backfillCoordinator = AlbumBackfillCoordinator(
            sidecarStore: sidecarStore,
            libraryIndexStore: indexStore,
            visionQueue: visionQueue
        )

        self.assetProvider = provider
        self.sidecarStore = sidecarStore
        self.libraryIndexStore = indexStore
        self.visionQueue = visionQueue
        self.backfillCoordinator = backfillCoordinator
        self.oracle = oracle
        self.scenes = AlbumSceneStore.load()
        self.libraryAuthorization = self.assetProvider.authorizationStatus()
        AlbumLog.model.info("AlbumModel init oracle: \(String(describing: type(of: self.oracle)), privacy: .public)")

        Task(priority: .utility) { [sidecarStore] in
            await sidecarStore.migrateLegacyIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }

            await visionQueue.setUpdateSink { [weak self] update in
                self?.applyVisionUpdate(update)
            }

            await visionQueue.setCompletionSink { [weak self] assetID in
                self?.visionPendingAssetIDs.remove(assetID)
            }

            await backfillCoordinator.setProgressSink { [weak self] progress in
                self?.backfillTargetCount = progress.targetCount
                self?.backfillCompletedCount = progress.completedCount
                self?.backfillIsRunning = progress.isRunning
            }
        }
    }

    public func requestAbsorbNow() {
        absorbNowRequestID = UUID()
    }

    public func item(for itemID: String) -> AlbumItem? {
        let id = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if let hit = items.first(where: { $0.id == id }) {
            return hit
        }
        if let hit = memoryWindowItems.first(where: { $0.id == id }) {
            return hit
        }
        if let hit = recommendItems.first(where: { $0.id == id }) {
            return hit
        }
        return nil
    }

    public func asset(for assetID: String) -> AlbumAsset? {
        item(for: assetID)
    }

    private func sidecarKey(for assetID: String) -> AlbumSidecarKey {
        let source: AlbumSidecarSource = (datasetSource == .demo) ? .demo : .photos
        return AlbumSidecarKey(source: source, id: assetID)
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
        await sidecarStore.migrateLegacyIfNeeded()
        let auth = assetProvider.authorizationStatus()
        libraryAuthorization = auth
        let q = query ?? selectedQuery
        let rawLimit = limit ?? 300
        let cappedLimit = min(max(1, rawLimit), 300)
        AlbumLog.photos.info("loadItems(query: \(q.id, privacy: .public), limit: \(cappedLimit)) auth: \(String(describing: auth), privacy: .public)")

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
            let fetched = try await assetProvider.fetchAssets(limit: cappedLimit, query: q, sampling: .random)
            lastAssetFetchCount = fetched.count
            let filtered = await hydrateSidecars(for: fetched, source: .photos)
            items = filtered
            AlbumLog.photos.info("loadItems fetched: \(fetched.count) filtered: \(self.items.count) hiddenIDs: \(self.hiddenIDs.count)")
            if let id = currentAssetID, let item = item(for: id) {
                currentItem = item
            }
            history = historyAssetIDs.compactMap { item(for: $0) }
            if panelMode == .memories {
                rebuildMemoryWindow(resetToAnchor: memoryWindowItems.isEmpty)
            }

            enqueueVisionForActiveSet(assetIDs: filtered.map(\.id), reason: "active_set_load")
            Task(priority: .background) { [backfillCoordinator] in
                await backfillCoordinator.startIfNeeded(source: .photos)
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

    private func hydrateSidecars(for fetched: [AlbumItem], source: AlbumSidecarSource) async -> [AlbumItem] {
        guard !fetched.isEmpty else {
            hiddenIDs = []
            thumbFeedbackByAssetID = [:]
            visionSummaryByAssetID = [:]
            visionSourceByAssetID = [:]
            visionConfidenceByAssetID = [:]
            return []
        }

        let keys = fetched.map { AlbumSidecarKey(source: source, id: $0.id) }
        let records = await sidecarStore.loadMany(keys)

        var hidden: Set<String> = []
        var feedback: [String: AlbumThumbFeedback] = [:]
        var vision: [String: String] = [:]
        var visionSource: [String: AlbumVisionSource] = [:]
        var visionConfidence: [String: Float] = [:]

        hidden.reserveCapacity(records.count / 4)
        feedback.reserveCapacity(records.count / 3)
        vision.reserveCapacity(records.count / 2)

        for record in records {
            let id = record.key.id
            guard !id.isEmpty else { continue }

            if record.hidden {
                hidden.insert(id)
            }

            switch record.rating {
            case 1:
                feedback[id] = .up
            case -1:
                feedback[id] = .down
            default:
                break
            }

            if let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                vision[id] = summary
            }
            if let src = record.visionSource {
                visionSource[id] = src
            }
            if let conf = record.visionConfidence {
                visionConfidence[id] = conf
            }
        }

        hiddenIDs = hidden
        thumbFeedbackByAssetID = feedback
        visionSummaryByAssetID = vision
        visionSourceByAssetID = visionSource
        visionConfidenceByAssetID = visionConfidence

        return fetched.filter { !hidden.contains($0.id) }
    }

    public func requestThumbnail(assetID: String, targetSize: CGSize, displayScale: CGFloat = 1) async -> AlbumImage? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        ensureVisionSummary(for: id, reason: "thumbnail", priority: .utility)

        if datasetSource == .demo || AlbumDemoLibrary.isDemoID(id) {
            let mediaType = asset(for: id)?.mediaType
            return AlbumDemoLibrary.requestThumbnail(localIdentifier: id, targetSize: targetSize, mediaType: mediaType)
        }

        let scale = max(1, displayScale)
        let pixelSize = CGSize(width: max(1, targetSize.width * scale), height: max(1, targetSize.height * scale))
        return await assetProvider.requestThumbnail(localIdentifier: id, targetSize: pixelSize)
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

    private var curvedWallWindowSize: Int { 10 }
    private var curvedWallPointsPerMeter: Double { 780 }

    private static let curvedWallRecommendsPlacementID = UUID(uuidString: "D2DCA22B-0D3E-4D48-9A6B-3B0D2D7E7A1A")!
    private static let curvedWallMemoriesPlacementID = UUID(uuidString: "7CF31D5B-4C65-48D7-8E15-2E01B7D2D9AC")!

    private var curvedWallPlacementID: UUID? {
        switch panelMode {
        case .recommends:
            return Self.curvedWallRecommendsPlacementID
        case .memories:
            return Self.curvedWallMemoriesPlacementID
        }
    }

    private var curvedWallRecommendsAllAssetIDs: [String] {
        guard !curvedWallDumpPages.isEmpty else { return [] }

        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(curvedWallDumpPages.count * 20)

        for page in curvedWallDumpPages {
            for rawID in page.neighborIDs {
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                guard !hiddenIDs.contains(id) else { continue }
                guard item(for: id) != nil else { continue }
                guard seen.insert(id).inserted else { continue }
                result.append(id)
            }
        }

        return result
    }

    private var curvedWallMemoriesAllAssetIDs: [String] {
        guard !memoryWindowItems.isEmpty else { return [] }
        return memoryWindowItems
            .map(\.id)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !hiddenIDs.contains($0) && item(for: $0) != nil }
    }

    private var curvedWallAllAssetIDsForPaging: [String] {
        switch panelMode {
        case .recommends:
            return curvedWallRecommendsAllAssetIDs
        case .memories:
            return curvedWallMemoriesAllAssetIDs
        }
    }

    private func curvedWallCurrentPageIndex(for placementID: UUID, total: Int) -> Int {
        let rawIndex = curvedWallPageWindows[placementID] ?? 0
        let maxIndex = curvedWallMaxPageIndex(total: total)
        return max(0, min(rawIndex, maxIndex))
    }

    private func curvedWallCurrentPageStart(for placementID: UUID, total: Int) -> Int {
        let index = curvedWallCurrentPageIndex(for: placementID, total: total)
        return index * curvedWallWindowSize
    }

    private func curvedWallMaxPageIndex(total: Int) -> Int {
        return max(0, (total - 1) / curvedWallWindowSize)
    }

    public var curvedWallCanPageBack: Bool {
        guard let placementID = curvedWallPlacementID else { return false }
        let ids = curvedWallAllAssetIDsForPaging
        let total = ids.count
        guard total > 0 else { return false }
        let index = curvedWallCurrentPageIndex(for: placementID, total: total)
        if panelMode == .memories {
            return index > 0 || memoryPrevEnabled
        }
        return index > 0
    }

    public var curvedWallCanPageForward: Bool {
        guard let placementID = curvedWallPlacementID else { return false }
        let ids = curvedWallAllAssetIDsForPaging
        let total = ids.count
        guard total > 0 else { return false }
        let index = curvedWallCurrentPageIndex(for: placementID, total: total)
        let maxIndex = curvedWallMaxPageIndex(total: total)
        if panelMode == .memories {
            return index < maxIndex || memoryNextEnabled
        }
        return index < maxIndex
    }

    public var curvedWallVisibleAssetIDs: [String] {
        guard let placementID = curvedWallPlacementID else { return [] }
        let ids = curvedWallAllAssetIDsForPaging
        guard !ids.isEmpty else { return [] }
        let start = curvedWallCurrentPageStart(for: placementID, total: ids.count)
        let end = min(start + curvedWallWindowSize, ids.count)
        return Array(ids[start..<end])
    }

    public var curvedWallVisiblePanels: [CurvedWallPanel] {
        let ids = curvedWallVisibleAssetIDs
        guard !ids.isEmpty else { return [] }

        let panelWidthPoints: Double = 620
        let horizontalPaddingPoints: Double = 8
        let innerWidth = max(panelWidthPoints - horizontalPaddingPoints, 240)
        let minHeight: Double = 220
        let panelVerticalPaddingPoints: Double = 8
        let actionRowHeightPoints: Double = 44
        let actionRowSpacingPoints: Double = 4

        return ids.compactMap { id in
            guard let asset = asset(for: id) else { return nil }

            let w = Double(asset.pixelWidth ?? 0)
            let h = Double(asset.pixelHeight ?? 0)

            let mediaHeight: Double = {
                guard w > 0, h > 0 else {
                    return max(minHeight, innerWidth * 0.6)
                }

                let aspect = h / w
                var computed = innerWidth * aspect
                if aspect <= 1 {
                    if computed < minHeight { computed = minHeight }
                } else {
                    computed = min(computed, innerWidth * 1.8)
                }
                return computed
            }()

            let viewHeightPoints = mediaHeight + actionRowSpacingPoints + actionRowHeightPoints + panelVerticalPaddingPoints
            let heightMeters = Float(viewHeightPoints / curvedWallPointsPerMeter)
            return CurvedWallPanel(assetID: id, heightMeters: heightMeters, viewHeightPoints: viewHeightPoints)
        }
    }

    public func dumpFocusedNeighborsToCurvedWall() {
        guard panelMode == .recommends else {
            AlbumLog.model.info("CurvedWall dump (memories): open anchor=\(self.memoryAnchorID ?? "nil", privacy: .public) window=\(self.memoryWindowItems.count) start=\(self.memoryPageStartIndex) label=\(self.memoryLabel, privacy: .public)")
            if let placementID = curvedWallPlacementID {
                let ids = curvedWallMemoriesAllAssetIDs
                if let anchorID = memoryAnchorID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let anchorIndex = ids.firstIndex(of: anchorID) {
                    curvedWallPageWindows[placementID] = anchorIndex / curvedWallWindowSize
                } else {
                    curvedWallPageWindows[placementID] = 0
                }
            }
            curvedCanvasEnabled = true
            return
        }

        guard let anchorID = currentAssetID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchorID.isEmpty else {
            thumbStatusMessage = "No focused asset"
            return
        }

        if recommendAnchorID != anchorID {
            restoreCachedRecommendsIfAvailable(for: anchorID)
        }

        guard recommendAnchorID == anchorID else {
            thumbStatusMessage = "No neighbors for focused asset"
            return
        }

        let neighborIDs = recommendItems.map(\.id)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != anchorID && !hiddenIDs.contains($0) }

        guard !neighborIDs.isEmpty else {
            thumbStatusMessage = "No neighbors for focused asset"
            return
        }

        let capped = Array(neighborIDs.prefix(20))
        let maxStoredPages = 10

        let priorVisible = curvedWallRecommendsAllAssetIDs
        let priorSet = Set(priorVisible)

        if let last = curvedWallDumpPages.last, last.anchorID == anchorID {
            let updated = CurvedWallDumpPage(anchorID: anchorID, neighborIDs: capped, createdAt: last.createdAt, id: last.id)
            curvedWallDumpPages[curvedWallDumpPages.count - 1] = updated
            curvedWallDumpIndex = curvedWallDumpPages.count - 1
        } else {
            let newPage = CurvedWallDumpPage(anchorID: anchorID, neighborIDs: capped)
            curvedWallDumpPages.append(newPage)
            if curvedWallDumpPages.count > maxStoredPages {
                let overflow = curvedWallDumpPages.count - maxStoredPages
                curvedWallDumpPages.removeFirst(overflow)
            }
            curvedWallDumpIndex = max(0, curvedWallDumpPages.count - 1)
        }

        let all = curvedWallRecommendsAllAssetIDs
        let total = all.count

        if let placementID = curvedWallPlacementID {
            let jumpIndex: Int = {
                let preferred = capped
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !hiddenIDs.contains($0) && item(for: $0) != nil && !priorSet.contains($0) }

                if let first = preferred.first, let idx = all.firstIndex(of: first) { return idx }

                let fallback = capped
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty && !hiddenIDs.contains($0) && item(for: $0) != nil })

                if let fallback, let idx = all.firstIndex(of: fallback) { return idx }
                return max(0, total - 1)
            }()

            let jumpPage = jumpIndex / curvedWallWindowSize
            curvedWallPageWindows[placementID] = jumpPage
            AlbumLog.model.info("CurvedWall dump anchor=\(anchorID, privacy: .public) neighbors=\(capped.count) dumps=\(self.curvedWallDumpPages.count) totalItems=\(total) jumpPage=\(jumpPage)")
        } else {
            AlbumLog.model.info("CurvedWall dump anchor=\(anchorID, privacy: .public) neighbors=\(capped.count) dumps=\(self.curvedWallDumpPages.count) totalItems=\(total)")
        }

        curvedCanvasEnabled = true
    }

    public func curvedWallPageBack() {
        guard let placementID = curvedWallPlacementID else { return }
        let ids = curvedWallAllAssetIDsForPaging
        let total = ids.count
        guard total > 0 else { return }

        let oldIndex = curvedWallCurrentPageIndex(for: placementID, total: total)
        if oldIndex > 0 {
            let newIndex = oldIndex - 1
            curvedWallPageWindows[placementID] = newIndex
            AlbumLog.model.info("CurvedWall pageBack placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> \(newIndex) totalPages=\(self.curvedWallMaxPageIndex(total: total) + 1)")
            curvedCanvasEnabled = true
            return
        }

        guard panelMode == .memories, memoryPrevEnabled else { return }
        memoryPrevPage()
        let updatedIDs = curvedWallMemoriesAllAssetIDs
        let updatedTotal = updatedIDs.count
        guard updatedTotal > 0 else { return }
        let newIndex = curvedWallMaxPageIndex(total: updatedTotal)
        curvedWallPageWindows[placementID] = newIndex
        AlbumLog.model.info("CurvedWall pageBack (windowShift) placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> \(newIndex) totalPages=\(self.curvedWallMaxPageIndex(total: updatedTotal) + 1) memoryStart=\(self.memoryPageStartIndex)")
        curvedCanvasEnabled = true
    }

    public func curvedWallPageForward() {
        guard let placementID = curvedWallPlacementID else { return }
        let ids = curvedWallAllAssetIDsForPaging
        let total = ids.count
        guard total > 0 else { return }

        let oldIndex = curvedWallCurrentPageIndex(for: placementID, total: total)
        let maxIndex = curvedWallMaxPageIndex(total: total)
        if oldIndex < maxIndex {
            let newIndex = oldIndex + 1
            curvedWallPageWindows[placementID] = newIndex
            AlbumLog.model.info("CurvedWall pageForward placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> \(newIndex) totalPages=\(self.curvedWallMaxPageIndex(total: total) + 1)")
            curvedCanvasEnabled = true
            return
        }

        guard panelMode == .memories, memoryNextEnabled else { return }
        memoryNextPage()
        curvedWallPageWindows[placementID] = 0
        AlbumLog.model.info("CurvedWall pageForward (windowShift) placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> 0 totalPages=\(self.curvedWallMaxPageIndex(total: max(1, self.curvedWallMemoriesAllAssetIDs.count)) + 1) memoryStart=\(self.memoryPageStartIndex)")
        curvedCanvasEnabled = true
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
        let rating = feedback == .up ? 1 : -1
        let key = sidecarKey(for: id)
        Task(priority: .utility) { [sidecarStore] in
            await sidecarStore.setRating(key, rating: rating)
        }

        guard !isPaused else {
            thumbThinkingSince = nil
            thumbThinkingFeedback = nil
            thumbStatusMessage = "Paused (rating saved)"
            return
        }

        thumbThinkingSince = Date()
        thumbThinkingFeedback = feedback
        thumbStatusMessage = nil

        let requestID = UUID()
        latestThumbRequestID = requestID

        thumbTask?.cancel()
        thumbTask = Task(priority: .userInitiated) { [weak self] in
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
        let key = sidecarKey(for: id)
        Task(priority: .utility) { [sidecarStore] in
            await sidecarStore.setHidden(key, hidden: true)
        }

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
        visionSourceByAssetID[assetID] = .computed
        visionConfidenceByAssetID[assetID] = 0.75
        visionPendingAssetIDs.remove(assetID)

        let key = sidecarKey(for: assetID)
        Task(priority: .utility) { [sidecarStore] in
            await sidecarStore.setVisionComputed(
                key,
                summary: trimmed,
                tags: nil,
                confidence: 0.75,
                computedAt: Date(),
                modelVersion: "VNClassifyImageRequest"
            )
        }
    }

    private func applyVisionUpdate(_ update: AlbumVisionUpdate) {
        let assetID = update.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetID.isEmpty else { return }
        let trimmed = update.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if visionSourceByAssetID[assetID] == .computed, update.source != .computed {
            return
        }

        visionSummaryByAssetID[assetID] = trimmed
        visionSourceByAssetID[assetID] = update.source
        visionConfidenceByAssetID[assetID] = update.confidence
        visionPendingAssetIDs.remove(assetID)
    }

    public func ensureVisionSummary(for assetID: String, reason: String, priority: TaskPriority = .utility) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        if datasetSource == .demo || AlbumDemoLibrary.isDemoID(id) {
            if visionSummaryByAssetID[id] == nil {
                visionSummaryByAssetID[id] = AlbumDemoLibrary.placeholderTitle(for: id, mediaType: asset(for: id)?.mediaType)
                visionSourceByAssetID[id] = .computed
                visionConfidenceByAssetID[id] = 1.0
            }
            return
        }

        if let summary = visionSummaryByAssetID[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty,
           visionSourceByAssetID[id] == .computed {
            return
        }

        Task(priority: priority) { [visionQueue] in
            let scheduled = await visionQueue.enqueueVision(for: id, source: .photos, reason: reason, priority: priority)
            if scheduled {
                await MainActor.run {
                    self.visionPendingAssetIDs.insert(id)
                }
            }
        }
    }

    private func enqueueVisionForActiveSet(assetIDs: [String], reason: String) {
        guard datasetSource == .photos else { return }
        guard !assetIDs.isEmpty else { return }

        let ids = assetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !ids.isEmpty else { return }

        Task(priority: .background) { [visionQueue] in
            for id in ids {
                _ = await visionQueue.enqueueVision(for: id, source: .photos, reason: reason, priority: .background)
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

        let snapshot = await buildOracleSnapshot(thumbed: thumbed)
        let oracle = self.oracle

        let outcome: AlbumRecOutcome
        switch feedback {
        case .up:
            outcome = await oracle.recommendThumbUp(snapshot: snapshot, requestID: requestID)
        case .down:
            outcome = await oracle.recommendThumbDown(snapshot: snapshot, requestID: requestID)
        }

        guard latestThumbRequestID == requestID else { return }

        thumbThinkingSince = nil
        thumbThinkingFeedback = nil

        guard let result = outcome.response else {
            thumbStatusMessage = outcome.errorDescription ?? "Scoring failed"
            return
        }

        applyOracleResult(feedback: feedback, snapshot: snapshot, result: result)

        var status = "\(feedback == .up ? "👍" : "👎") Neighbors ready (\(recommendItems.count)) • \(outcome.backend.rawValue)"
        if let note = outcome.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            let capped = note.count > 140 ? "\(note.prefix(140))…" : note
            status.append(" (\(capped))")
        }

        AlbumLog.model.info("Thumb outcome backend: \(outcome.backend.rawValue, privacy: .public) neighbors: \(self.recommendItems.count)")
        thumbStatusMessage = status
    }

    private func buildOracleSnapshot(thumbed: AlbumItem) async -> AlbumOracleSnapshot {
        if datasetSource == .demo {
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

        let candidateItems = items.filter { item in
            if item.id == thumbed.id { return false }
            if hiddenIDs.contains(item.id) { return false }
            return true
        }

        let allIDs = ([thumbed.id] + candidateItems.map(\.id))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let records = await sidecarStore.loadMany(allIDs.map { AlbumSidecarKey(source: .photos, id: $0) })
        var recordByID: [String: AlbumSidecarRecord] = [:]
        recordByID.reserveCapacity(records.count)

        for record in records {
            let id = record.key.id
            guard !id.isEmpty else { continue }
            recordByID[id] = record

            if let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty,
               visionSummaryByAssetID[id] == nil {
                visionSummaryByAssetID[id] = summary
            }
            if let src = record.visionSource, visionSourceByAssetID[id] == nil {
                visionSourceByAssetID[id] = src
            }
            if let conf = record.visionConfidence, visionConfidenceByAssetID[id] == nil {
                visionConfidenceByAssetID[id] = conf
            }
        }

        func oracleVisionSummary(assetID: String, mediaType: AlbumMediaType) -> String {
            let trimmedID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let summary = visionSummaryByAssetID[trimmedID]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return summary
            }

            if let record = recordByID[trimmedID],
               let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return summary
            }

            return mediaType == .video ? "unlabeled video" : "unlabeled photo"
        }

        var idsNeedingCompute: Set<String> = []
        idsNeedingCompute.reserveCapacity(32)

        func noteIfNeedsCompute(assetID: String) {
            let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }

            if visionSourceByAssetID[id] == .computed { return }
            if recordByID[id]?.visionSource == .computed { return }
            idsNeedingCompute.insert(id)
        }

        noteIfNeedsCompute(assetID: thumbed.id)

        let candidates: [AlbumOracleCandidate] = candidateItems.map { item in
            let summary = oracleVisionSummary(assetID: item.id, mediaType: item.mediaType)
            if summary.hasPrefix("unlabeled ") {
                noteIfNeedsCompute(assetID: item.id)
            } else if recordByID[item.id]?.visionSource == .inferred {
                noteIfNeedsCompute(assetID: item.id)
            }

            return AlbumOracleCandidate(
                key: item.id,
                assetID: item.id,
                mediaType: item.mediaType,
                createdYearMonth: createdYearMonth(for: item),
                locationBucket: locationBucket(for: item),
                visionSummary: summary
            )
        }

        if !idsNeedingCompute.isEmpty {
            enqueueVisionForActiveSet(assetIDs: Array(idsNeedingCompute), reason: "oracle_snapshot")
        }

        let alreadySeen = Set(history.map(\.id)).union([thumbed.id])

        return AlbumOracleSnapshot(
            thumbedAssetID: thumbed.id,
            thumbedMediaType: thumbed.mediaType,
            thumbedCreatedYearMonth: createdYearMonth(for: thumbed),
            thumbedLocationBucket: locationBucket(for: thumbed),
            thumbedVisionSummary: oracleVisionSummary(assetID: thumbed.id, mediaType: thumbed.mediaType),
            candidates: candidates,
            alreadySeenKeys: alreadySeen
        )
    }

    private func applyOracleResult(feedback: AlbumThumbFeedback, snapshot: AlbumOracleSnapshot, result: AlbumRecResponse) {
        let anchorID = snapshot.thumbedAssetID.trimmingCharacters(in: .whitespacesAndNewlines)
        recommendAnchorID = anchorID

        let pruned = pruneRecommendsResponse(anchorID: anchorID, raw: result)
        recommendsCacheByAnchorID[anchorID] = pruned
        recommendsFeedbackByAnchorID[anchorID] = feedback

        recommendItems = pruned.neighbors.compactMap { item(for: $0.id) }
            .filter { $0.id != anchorID && !hiddenIDs.contains($0.id) }
        neighborsReady = !recommendItems.isEmpty

        switch feedback {
        case .up:
            let nextUpID = chooseNextUpAssetID(snapshot: snapshot, pruned: pruned)
            recommendedAssetID = nextUpID
            if let nextUpID {
                aiNextAssetIDs = [nextUpID]
                pushRecommendedAsset(nextUpID)
            } else {
                aiNextAssetIDs.removeAll()
            }
        case .down:
            recommendedAssetID = nil
            aiNextAssetIDs.removeAll()
        }

        tuningDeltaRequest = AlbumTuningDeltaRequest(deltas: computeTuningDeltas(feedback: feedback, anchorID: anchorID, neighbors: pruned.neighbors))
    }

    private func pruneRecommendsResponse(anchorID: String, raw: AlbumRecResponse) -> AlbumRecResponse {
        let trimmedAnchor = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)

        let prunedNextID: String? = {
            guard let rawNext = raw.nextID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawNext.isEmpty else { return nil }
            guard rawNext != trimmedAnchor else { return nil }
            guard !hiddenIDs.contains(rawNext) else { return nil }
            guard item(for: rawNext) != nil else { return nil }
            return rawNext
        }()

        var seen = Set<String>()
        seen.insert(trimmedAnchor)

        var neighbors: [AlbumRecNeighbor] = []
        neighbors.reserveCapacity(20)

        for n in raw.neighbors {
            if neighbors.count >= 20 { break }
            let id = n.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard !seen.contains(id) else { continue }
            guard id != trimmedAnchor else { continue }
            guard !hiddenIDs.contains(id) else { continue }
            guard item(for: id) != nil else { continue }
            seen.insert(id)
            neighbors.append(n)
        }

        return AlbumRecResponse(nextID: prunedNextID, neighbors: neighbors)
    }

    private func chooseNextUpAssetID(snapshot: AlbumOracleSnapshot, pruned: AlbumRecResponse) -> String? {
        let anchorID = snapshot.thumbedAssetID.trimmingCharacters(in: .whitespacesAndNewlines)

        let orderedCandidates = [pruned.nextID].compactMap { $0 } + pruned.neighbors.map(\.id)

        for id in orderedCandidates {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed != anchorID else { continue }
            guard !hiddenIDs.contains(trimmed) else { continue }
            guard item(for: trimmed) != nil else { continue }
            guard !snapshot.alreadySeenKeys.contains(trimmed) else { continue }
            return trimmed
        }

        for id in orderedCandidates {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed != anchorID else { continue }
            guard !hiddenIDs.contains(trimmed) else { continue }
            guard item(for: trimmed) != nil else { continue }
            return trimmed
        }

        return nil
    }

    private func restoreCachedRecommendsIfAvailable(for assetID: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard let cached = recommendsCacheByAnchorID[id] else { return }

        recommendAnchorID = id

        recommendItems = cached.neighbors.compactMap { item(for: $0.id) }
            .filter { $0.id != id && !hiddenIDs.contains($0.id) }
        neighborsReady = !recommendItems.isEmpty

        guard recommendsFeedbackByAnchorID[id] == .up else {
            recommendedAssetID = nil
            aiNextAssetIDs.removeAll()
            return
        }

        let nextUp: String? = {
            if let next = cached.nextID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !next.isEmpty,
               next != id,
               !hiddenIDs.contains(next),
               item(for: next) != nil {
                return next
            }
            if let firstNeighbor = cached.neighbors.first?.id,
               !hiddenIDs.contains(firstNeighbor),
               firstNeighbor != id,
               item(for: firstNeighbor) != nil {
                return firstNeighbor
            }
            return nil
        }()

        recommendedAssetID = nextUp
        if let nextUp {
            aiNextAssetIDs = [nextUp]
        } else {
            aiNextAssetIDs.removeAll()
        }
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

        if datasetSource == .photos {
            memoryRebuildTask?.cancel()
            memoryRebuildTask = Task { [weak self] in
                guard let self else { return }
                await self.shiftMemoryPageFromLibrary(delta: delta)
            }
            return
        }

        let groupSize = max(1, memoryGroupSize)
        let overlap = max(0, min(memoryOverlap, groupSize - 1))
        let step = max(1, groupSize - overlap)

        let timelineCount = items.count
        let maxStart = max(0, timelineCount - groupSize)
        let proposed = memoryPageStartIndex + delta * step
        memoryPageStartIndex = max(0, min(proposed, maxStart))
        rebuildMemoryWindow(resetToAnchor: false)
    }

    private func shiftMemoryPageFromLibrary(delta: Int) async {
        guard delta != 0 else { return }
        guard memoryAnchorID != nil else { return }
        guard let index = await libraryIndexStore.buildIfNeeded() else { return }

        let groupSize = max(1, memoryGroupSize)
        let overlap = max(0, min(memoryOverlap, groupSize - 1))
        let step = max(1, groupSize - overlap)

        let total = index.idsByCreationDateAscending.count
        let maxStart = max(0, total - groupSize)
        let proposed = memoryPageStartIndex + delta * step
        memoryPageStartIndex = max(0, min(proposed, maxStart))
        await rebuildMemoryWindowFromLibrary(resetToAnchor: false, index: index)
    }

    private func rebuildMemoryWindow(resetToAnchor: Bool) {
        if datasetSource == .photos {
            memoryRebuildTask?.cancel()
            memoryRebuildTask = Task { [weak self] in
                guard let self else { return }
                await self.rebuildMemoryWindowFromLibrary(resetToAnchor: resetToAnchor)
            }
            return
        }

        guard let anchorID = memoryAnchorID else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            return
        }

        let timeline = items
            .filter { !hiddenIDs.contains($0.id) }
            .sorted { (a, b) in
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

    private func rebuildMemoryWindowFromLibrary(resetToAnchor: Bool) async {
        guard let index = await libraryIndexStore.buildIfNeeded() else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            AlbumLog.model.info("Memories: library index unavailable")
            return
        }

        await rebuildMemoryWindowFromLibrary(resetToAnchor: resetToAnchor, index: index)
    }

    private func rebuildMemoryWindowFromLibrary(resetToAnchor: Bool, index: AlbumLibraryIndex) async {
        guard let anchorID = memoryAnchorID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchorID.isEmpty else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            return
        }

        let total = index.idsByCreationDateAscending.count
        guard total > 0 else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            return
        }

        let groupSize = max(1, memoryGroupSize)
        let maxStart = max(0, total - groupSize)

        let anchorIndex = index.index(of: anchorID) ?? 0

        if resetToAnchor {
            let centered = max(0, anchorIndex - (groupSize / 2))
            memoryPageStartIndex = min(centered, maxStart)
        } else {
            memoryPageStartIndex = max(0, min(memoryPageStartIndex, maxStart))
        }

        let start = memoryPageStartIndex
        let end = min(total, start + groupSize)
        let windowIDsRaw = Array(index.idsByCreationDateAscending[start..<end])
        let windowIDs = windowIDsRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        await mergeSidecars(for: windowIDs, source: .photos)

        let fetched: [AlbumAsset]
        do {
            fetched = try await assetProvider.fetchAssets(localIdentifiers: windowIDs)
        } catch {
            AlbumLog.photos.error("Memories: fetchAssets(localIdentifiers:) error: \(String(describing: error), privacy: .public)")
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = start > 0
            memoryNextEnabled = end < total
            return
        }

        var byID: [String: AlbumAsset] = [:]
        byID.reserveCapacity(fetched.count)
        for asset in fetched {
            byID[asset.id] = asset
        }

        let ordered = windowIDs.compactMap { byID[$0] }.filter { !hiddenIDs.contains($0.id) }
        memoryWindowItems = ordered

        memoryPrevEnabled = start > 0
        memoryNextEnabled = end < total
        memoryLabel = formatMemoryLabel(items: memoryWindowItems)
        AlbumLog.model.info("Memories window (library): anchorIndex=\(anchorIndex) start=\(start) end=\(end) loaded=\(self.memoryWindowItems.count) total=\(total)")

        if resetToAnchor {
            let placementID = Self.curvedWallMemoriesPlacementID
            let indexInWindow = max(0, min(groupSize - 1, anchorIndex - start))
            curvedWallPageWindows[placementID] = max(0, indexInWindow / curvedWallWindowSize)
        }
    }

    private func mergeSidecars(for assetIDs: [String], source: AlbumSidecarSource) async {
        guard !assetIDs.isEmpty else { return }

        let keys = assetIDs.map { AlbumSidecarKey(source: source, id: $0) }
        let records = await sidecarStore.loadMany(keys)
        guard !records.isEmpty else { return }

        for record in records {
            let id = record.key.id
            guard !id.isEmpty else { continue }

            if record.hidden {
                hiddenIDs.insert(id)
            }

            switch record.rating {
            case 1:
                thumbFeedbackByAssetID[id] = .up
            case -1:
                thumbFeedbackByAssetID[id] = .down
            default:
                break
            }

            if let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                if visionSourceByAssetID[id] == .computed, record.visionSource != .computed {
                    continue
                }
                visionSummaryByAssetID[id] = summary
            }
            if let src = record.visionSource {
                if visionSourceByAssetID[id] == .computed, src != .computed {
                    continue
                }
                visionSourceByAssetID[id] = src
            }
            if let conf = record.visionConfidence {
                visionConfidenceByAssetID[id] = conf
            }
        }
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
