import SwiftUI
import CoreGraphics
import simd
import Vision
import ImageIO
import AVFoundation
import AudioToolbox
import CoreLocation
import CoreVideo

#if canImport(UIKit)
import UIKit
#endif

public enum AlbumDatasetSource: String, Sendable, Codable, CaseIterable {
    case photos
    case demo
}

public struct AlbumWindowWorldCenter: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct AlbumHeadFrame: Sendable {
    public var current: simd_float4x4 = matrix_identity_float4x4
    public var initial: simd_float4x4? = nil

    public init() {}
}

@MainActor
public final class AlbumModel: ObservableObject {
    public let assetProvider: AlbumAssetProvider
    private let sidecarStore: AlbumSidecarStore
    private let libraryIndexStore: AlbumLibraryIndexStore
    private let backfillManager: AlbumBackfillManager
    private let faceIndexStore: FaceIndexStore
    private let faceHierarchyStore: FaceHierarchyStore
    private let faceEngine: AlbumFaceEngine
    public let oracle: AlbumOracle

    @Published public var theme: AlbumTheme = .dark
    public var palette: AlbumThemePalette { theme.palette }

    // MARK: Hub state (required)

    @Published public var panelMode: AlbumPanelMode = .memories {
        didSet {
            guard panelMode != oldValue else { return }
            if panelMode == .memories {
                if let id = currentItem?.id {
                    memoryAnchorID = id
                    rebuildMemoryWindow(resetToAnchor: true)
                }
            } else {
                memoryFacesIndexTask?.cancel()
                memoryFacesIndexTask = nil
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
            appendToHistoryIfNew(assetID: item.id)

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
    @Published public var poppedItems: [AlbumSceneItemRecord] = []
    private var windowMidXByItemID: [UUID: Double] = [:]
    private var windowWorldCentersByItemID: [UUID: AlbumWindowWorldCenter] = [:]
    public private(set) var headFrame: AlbumHeadFrame = AlbumHeadFrame()
    @Published private var pinnedAssetsByID: [String: AlbumAsset] = [:]
    @Published public var scenes: [AlbumSceneRecord] = []
    @Published public var movieStatusLinesByItemID: [UUID: [String]] = [:]
    @Published public var movieTitleGenerationInFlightItemIDs: Set<UUID> = []

    @Published public var aiNextAssetIDs: Set<String> = []
    @Published public var recommendedAssetID: String? = nil
    @Published public var recommendedAssetIDs: [String] = []

    @Published public var thumbRequest: AlbumThumbRequest? = nil
    @Published public var thumbThinkingSince: Date? = nil
    @Published public var thumbThinkingFeedback: AlbumThumbFeedback? = nil
    @Published public var thumbStatusMessage: String? = nil
    @Published public var thumbFeedbackByAssetID: [String: AlbumThumbFeedback] = [:]

    @Published public var visionSummaryByAssetID: [String: String] = [:]
    @Published public var visionStateByAssetID: [String: AlbumSidecarRecord.VisionFillState] = [:]
    @Published public var visionConfidenceByAssetID: [String: Float] = [:]
    @Published public var visionPendingAssetIDs: Set<String> = []

    private var preferenceScoreByAssetID: [String: Float] = [:]

    @Published public var backfillStatus: BackfillStatus = BackfillStatus()

    @Published public private(set) var visionCoverage: AlbumVisionCoverage = AlbumVisionCoverage()
    @Published public private(set) var visionCoverageIsRefreshing: Bool = false

		    public struct Settings: Sendable, Hashable, Codable {
		        public var autofillOnThumbUp: Bool
		        public var thumbUpAutofillCount: Int
                public var assetLoadLimit: Int
		        public var showFacesDebugUI: Bool
                public var faceClusterT1: Float
                public var faceClusterT2: Float
                public var faceClusterT3: Float
                public var faceHierarchyRepCap: Int

		        public init(
                    autofillOnThumbUp: Bool = true,
                    thumbUpAutofillCount: Int = 5,
                    assetLoadLimit: Int = 250,
                    showFacesDebugUI: Bool = true,
                    faceClusterT1: Float = 0.42,
                    faceClusterT2: Float = 0.50,
                    faceClusterT3: Float = 0.60,
                    faceHierarchyRepCap: Int = 8
                ) {
		            self.autofillOnThumbUp = autofillOnThumbUp
		            self.thumbUpAutofillCount = max(0, thumbUpAutofillCount)
                    self.assetLoadLimit = max(1, min(300, assetLoadLimit))
		            self.showFacesDebugUI = showFacesDebugUI
                    self.faceClusterT1 = faceClusterT1
                    self.faceClusterT2 = faceClusterT2
                    self.faceClusterT3 = faceClusterT3
                    self.faceHierarchyRepCap = max(1, faceHierarchyRepCap)
		        }

                private enum CodingKeys: String, CodingKey {
                    case autofillOnThumbUp
                    case thumbUpAutofillCount
                    case assetLoadLimit
                    case showFacesDebugUI
                    case faceClusterT1
                    case faceClusterT2
                    case faceClusterT3
                    case faceHierarchyRepCap
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)

                    autofillOnThumbUp = try container.decodeIfPresent(Bool.self, forKey: .autofillOnThumbUp) ?? true
                    thumbUpAutofillCount = max(0, try container.decodeIfPresent(Int.self, forKey: .thumbUpAutofillCount) ?? 5)
                    assetLoadLimit = max(1, min(300, try container.decodeIfPresent(Int.self, forKey: .assetLoadLimit) ?? 250))
                    showFacesDebugUI = try container.decodeIfPresent(Bool.self, forKey: .showFacesDebugUI) ?? true

                    func clamp(_ value: Float) -> Float {
                        guard value.isFinite else { return 0 }
                        return max(0, min(0.95, value))
                    }

                    faceClusterT1 = clamp(try container.decodeIfPresent(Float.self, forKey: .faceClusterT1) ?? 0.42)
                    let rawT2 = clamp(try container.decodeIfPresent(Float.self, forKey: .faceClusterT2) ?? 0.50)
                    let rawT3 = clamp(try container.decodeIfPresent(Float.self, forKey: .faceClusterT3) ?? 0.60)
                    faceClusterT2 = max(faceClusterT1, rawT2)
                    faceClusterT3 = max(faceClusterT2, rawT3)

                    faceHierarchyRepCap = max(1, try container.decodeIfPresent(Int.self, forKey: .faceHierarchyRepCap) ?? 8)
                }

                public func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(autofillOnThumbUp, forKey: .autofillOnThumbUp)
                    try container.encode(thumbUpAutofillCount, forKey: .thumbUpAutofillCount)
                    try container.encode(assetLoadLimit, forKey: .assetLoadLimit)
                    try container.encode(showFacesDebugUI, forKey: .showFacesDebugUI)
                    try container.encode(faceClusterT1, forKey: .faceClusterT1)
                    try container.encode(faceClusterT2, forKey: .faceClusterT2)
                    try container.encode(faceClusterT3, forKey: .faceClusterT3)
                    try container.encode(faceHierarchyRepCap, forKey: .faceHierarchyRepCap)
                }
		    }

    @Published public var settings: Settings = Settings() {
        didSet {
            scheduleSettingsSave()
        }
    }

    @Published public var curvedCanvasEnabled: Bool = false {
        didSet {
            guard curvedCanvasEnabled != oldValue else { return }
            if !curvedCanvasEnabled {
                curvedWallOverride = nil
            }
        }
    }
    @Published public private(set) var curvedWallDumpPages: [CurvedWallDumpPage] = []
    @Published public private(set) var curvedWallDumpIndex: Int = 0
    @Published private var curvedWallPageWindows: [UUID: Int] = [:]
    @Published private var curvedWallOverride: CurvedWallOverride? = nil

    @Published public private(set) var isLoadingItems: Bool = false
    @Published public private(set) var bubbleMediaLoadProgress: BubbleMediaLoadProgress? = nil

    private var thumbTask: Task<Void, Never>? = nil
    private var latestThumbRequestID: UUID? = nil
    private var isSyncingSelection: Bool = false
    private var recommendsCacheByAnchorID: [String: AlbumRecResponse] = [:]
    private var recommendsFeedbackByAnchorID: [String: AlbumThumbFeedback] = [:]
    private var thumbUpAutofillNeighborIDsByAnchorID: [String: [String]] = [:]
    private var memoryRebuildTask: Task<Void, Never>? = nil
    private var memoryFacesIndexTask: Task<Void, Never>? = nil
    private var visionCoverageRefreshTask: Task<Void, Never>? = nil
    private var pinnedAssetLoadsInFlight: Set<String> = []
    private var settingsSaveTask: Task<Void, Never>? = nil

    public struct BubbleMediaLoadProgress: Sendable, Equatable {
        public var total: Int
        public var completed: Int
        public var startedAt: Date
        public var lastUpdatedAt: Date

        public init(total: Int, completed: Int = 0, startedAt: Date = Date(), lastUpdatedAt: Date = Date()) {
            self.total = total
            self.completed = completed
            self.startedAt = startedAt
            self.lastUpdatedAt = lastUpdatedAt
        }

        public var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(completed) / Double(total)
        }
    }

    public func beginBubbleMediaLoad(total: Int) {
        let clamped = max(0, total)
        bubbleMediaLoadProgress = BubbleMediaLoadProgress(total: clamped, completed: 0, startedAt: Date(), lastUpdatedAt: Date())
    }

    public func markBubbleMediaLoadedOne() {
        guard var progress = bubbleMediaLoadProgress else { return }
        progress.completed = min(progress.total, progress.completed + 1)
        progress.lastUpdatedAt = Date()
        bubbleMediaLoadProgress = progress
    }

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

    private struct CurvedWallOverride: Sendable, Equatable {
        var title: String
        var assetIDs: [String]
    }

    public init(
        assetProvider: (any AlbumAssetProvider)? = nil,
        sidecarStore: AlbumSidecarStore = AlbumSidecarStore(),
        oracle: AlbumOracle = AlbumAutoOracle()
    ) {
        let provider = assetProvider ?? PhotosAlbumAssetProvider()
        let indexStore = AlbumLibraryIndexStore()
        let faceIndexStore = FaceIndexStore()
        let faceHierarchyStore = FaceHierarchyStore(faceIndexStore: faceIndexStore)
        let faceEngine = AlbumFaceEngine(sidecarStore: sidecarStore, indexStore: faceIndexStore)
        let backfillManager = AlbumBackfillManager(sidecarStore: sidecarStore, libraryIndexStore: indexStore, assetProvider: provider, faceEngine: faceEngine)

        self.assetProvider = provider
        self.sidecarStore = sidecarStore
        self.libraryIndexStore = indexStore
        self.backfillManager = backfillManager
        self.faceIndexStore = faceIndexStore
        self.faceHierarchyStore = faceHierarchyStore
        self.faceEngine = faceEngine
        self.oracle = oracle
        self.scenes = AlbumSceneStore.load()
        self.libraryAuthorization = self.assetProvider.authorizationStatus()
        if let saved = AlbumSettingsStore.load() {
            self.settings = saved
        }
        AlbumLog.model.info("AlbumModel init oracle: \(String(describing: type(of: self.oracle)), privacy: .public)")

        Task(priority: .utility) { [sidecarStore] in
            await sidecarStore.migrateLegacyIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }

            await backfillManager.setVisionUpdateSink { [weak self] update in
                self?.applyVisionUpdate(update)
            }

            await backfillManager.setVisionCompletionSink { [weak self] assetID in
                self?.visionPendingAssetIDs.remove(assetID)
            }

            await backfillManager.setStatusSink { [weak self] status in
                self?.backfillStatus = status
            }

            await backfillManager.bootstrapOnLaunch()
        }
    }

    public func requestAbsorbNow() {
        absorbNowRequestID = UUID()
    }

    public func startLibraryAnalysis() {
        guard datasetSource == .photos else {
            AlbumLog.model.info("Analyze Library pressed, but datasetSource is not photos")
            return
        }

        guard libraryAuthorization == .authorized || libraryAuthorization == .limited else {
            AlbumLog.model.info("Analyze Library pressed, but Photos access is not authorized")
            return
        }

        AlbumLog.model.info("Analyze Library pressed; resuming backfill")
        Task(priority: .background) { [backfillManager] in
            await backfillManager.resume()
        }
    }

    public func pauseLibraryAnalysis() {
        AlbumLog.model.info("Pause Analysis pressed; pausing backfill")
        Task(priority: .background) { [backfillManager] in
            await backfillManager.pause()
        }
    }

    public func pauseBackfill() {
        Task(priority: .background) { [backfillManager] in
            await backfillManager.pause()
        }
    }

    public func resumeBackfill() {
        Task(priority: .background) { [backfillManager] in
            await backfillManager.resume()
        }
    }

    public func restartIndexing() {
        Task(priority: .background) { [backfillManager] in
            await backfillManager.restart()
        }
    }

    public func refreshVisionCoverage() {
        guard datasetSource == .photos else {
            visionCoverage = AlbumVisionCoverage(
                totalAssets: 0,
                computed: 0,
                autofilled: 0,
                failed: 0,
                missing: 0,
                computedPercent: 0,
                updatedAt: Date(),
                lastError: "Vision coverage is only available for the Photos library."
            )
            return
        }

        if visionCoverageIsRefreshing { return }
        visionCoverageIsRefreshing = true

        visionCoverageRefreshTask?.cancel()

        let sidecarStore = self.sidecarStore
        let libraryIndexStore = self.libraryIndexStore

        visionCoverageRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                visionCoverageIsRefreshing = false
                visionCoverageRefreshTask = nil
            }

            let index = await libraryIndexStore.buildIfNeeded()
            let allowedIDs = index.map { Set($0.idsByCreationDateAscending) }
            let coverage = await sidecarStore.computeVisionCoverage(source: .photos, allowedIDs: allowedIDs)
            if Task.isCancelled { return }
            visionCoverage = coverage
        }
    }

	    public func retryFailedBackfill() {
	        Task(priority: .background) { [backfillManager] in
	            await backfillManager.retryFailed()
	        }
	    }

	    public func applySeedAutofillPass() {
	        Task(priority: .background) { [backfillManager] in
	            await backfillManager.applySeedTimelineAutofillPass()
	        }
	    }

    public func shutdownForQuit() {
        AlbumLog.model.info("Shutdown requested (quit button)")
        isPaused = true
        curvedCanvasEnabled = false

        latestThumbRequestID = nil
        thumbTask?.cancel()
        thumbTask = nil
        thumbThinkingSince = nil
        thumbThinkingFeedback = nil

        memoryRebuildTask?.cancel()
        memoryRebuildTask = nil
        memoryFacesIndexTask?.cancel()
        memoryFacesIndexTask = nil

        Task(priority: .userInitiated) { [backfillManager] in
            await backfillManager.pause()
        }
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
        if let hit = pinnedAssetsByID[id] {
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

    public func preferenceScore(for assetID: String) -> Float {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return 0 }
        return preferenceScoreByAssetID[id] ?? 0
    }

    public func preferenceBaselineTuningMultipliers(for assetID: String) -> (massMultiplier: Float, accelerationMultiplier: Float) {
        baselineTuningMultipliers(forPreferenceScore: preferenceScore(for: assetID))
    }

    private enum ThumbTuning {
        // Debug-tuned: strong deltas so effects are unmistakable.
        static let upMassGain: Float = 75.0
        static let downMassLoss: Float = 105.0
        static let downAccelGain: Float = 525.0

        static var upTopMassMultiplier: Double { Double(1.0 + upMassGain) }
        static let upTopAccelerationMultiplier: Double = 1.0

        static var downTopMassMultiplier: Double { Double(1.0 / (1.0 + downMassLoss)) }
        static var downTopAccelerationMultiplier: Double { Double(1.0 + downAccelGain) }
    }

    private func baselineTuningMultipliers(forPreferenceScore scoreRaw: Float) -> (massMultiplier: Float, accelerationMultiplier: Float) {
        guard scoreRaw.isFinite else { return (1.0, 1.0) }
        guard scoreRaw != 0 else { return (1.0, 1.0) }

        if scoreRaw > 0 {
            let exponent = Double(scoreRaw)
            return (
                powFloat(base: ThumbTuning.upTopMassMultiplier, exponent: exponent, fallback: Float.greatestFiniteMagnitude),
                powFloat(base: ThumbTuning.upTopAccelerationMultiplier, exponent: exponent, fallback: 1.0)
            )
        }

        let exponent = Double(-scoreRaw)
        return (
            powFloat(base: ThumbTuning.downTopMassMultiplier, exponent: exponent, fallback: Float.leastNonzeroMagnitude),
            powFloat(base: ThumbTuning.downTopAccelerationMultiplier, exponent: exponent, fallback: Float.greatestFiniteMagnitude)
        )
    }

    private func powFloat(base: Double, exponent: Double, fallback: Float) -> Float {
        guard base.isFinite, exponent.isFinite else { return fallback }
        if base == 0 { return 0 }
        if exponent == 0 { return 1 }

        let raw = pow(base, exponent)
        guard raw.isFinite else { return fallback }

        let asFloat = Float(raw)
        if asFloat.isFinite {
            if asFloat == 0 { return Float.leastNonzeroMagnitude }
            return asFloat
        }
        return fallback
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
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return "" }

        if let summary = visionSummaryByAssetID[id], !summary.isEmpty {
            return summary
        }

        if let asset = asset(for: id) {
            return semanticHandle(for: asset)
        }

        if let state = visionStateByAssetID[id] {
            return "(\(state.rawValue)) \(id)"
        }

        return id
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

    public func faceIDs(for assetID: String) async -> [String] {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        guard datasetSource == .photos else { return [] }
        return await faceIndexStore.faceIDs(for: id)
    }

    public func faceClusterTokens(for assetID: String) async -> [String] {
        let leafIDs = await faceIDs(for: assetID)
        guard !leafIDs.isEmpty else { return [] }

        let tokenByLeafID = await faceHierarchyStore.clusterTokenPreferredByLeafID(for: leafIDs)

        var out: [String] = []
        out.reserveCapacity(min(8, leafIDs.count))

        var seen = Set<String>()
        seen.reserveCapacity(min(8, leafIDs.count))

        for raw in leafIDs {
            let leafID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !leafID.isEmpty else { continue }
            let token = (tokenByLeafID[leafID] ?? leafID).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard seen.insert(token).inserted else { continue }
            out.append(token)
        }

        return out
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

            Task(priority: .background) { [backfillManager] in
                await backfillManager.bootstrapOnLaunch()
            }
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
        let rawLimit = limit ?? settings.assetLoadLimit
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

            Task(priority: .background) { [backfillManager] in
                await backfillManager.bootstrapOnLaunch()
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
            visionStateByAssetID = [:]
            visionConfidenceByAssetID = [:]
            preferenceScoreByAssetID = [:]
            return []
        }

        let keys = fetched.map { AlbumSidecarKey(source: source, id: $0.id) }
        let records = await sidecarStore.loadMany(keys)

        var hidden: Set<String> = []
        var feedback: [String: AlbumThumbFeedback] = [:]
        var vision: [String: String] = [:]
        var visionState: [String: AlbumSidecarRecord.VisionFillState] = [:]
        var visionConfidence: [String: Float] = [:]
        var preferenceScores: [String: Float] = [:]

        hidden.reserveCapacity(records.count / 4)
        feedback.reserveCapacity(records.count / 3)
        vision.reserveCapacity(records.count / 2)
        preferenceScores.reserveCapacity(records.count / 3)

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

            if record.preferenceScore != 0 {
                preferenceScores[id] = record.preferenceScore
            }

            if let summary = record.vision.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                vision[id] = summary
            }
            if record.vision.state != .none {
                visionState[id] = record.vision.state
            }
            if let conf = record.vision.confidence {
                visionConfidence[id] = conf
            }
        }

        hiddenIDs = hidden
        thumbFeedbackByAssetID = feedback
        visionSummaryByAssetID = vision
        visionStateByAssetID = visionState
        visionConfidenceByAssetID = visionConfidence
        preferenceScoreByAssetID = preferenceScores

        return fetched.filter { !hidden.contains($0.id) }
    }

    public func requestThumbnail(
        assetID: String,
        targetSize: CGSize,
        displayScale: CGFloat = 1,
        triggerVision: Bool = true
    ) async -> AlbumImage? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if triggerVision {
            ensureVisionSummary(for: id, reason: "thumbnail", priority: .userInitiated)
        }

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
        sendThumb(feedback, assetID: id, persistPreference: false)
    }

    private var curvedWallMaxColumns: Int { 8 }
    private var curvedWallColumnMaxHeightMeters: Float { 1.8 }
    private var curvedWallColumnSpacingMeters: Float { 0.001 }
    private var curvedWallPointsPerMeter: Double { 780 }

    private static let curvedWallRecommendsPlacementID = UUID(uuidString: "D2DCA22B-0D3E-4D48-9A6B-3B0D2D7E7A1A")!
    private static let curvedWallMemoriesPlacementID = UUID(uuidString: "7CF31D5B-4C65-48D7-8E15-2E01B7D2D9AC")!
    private static let curvedWallOverridePlacementID = UUID(uuidString: "7BE0E0CE-6FB9-47C7-974C-3E209729B500")!

    private var curvedWallPlacementID: UUID? {
        if curvedWallOverride != nil {
            return Self.curvedWallOverridePlacementID
        }
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
        if let curvedWallOverride {
            return curvedWallOverride.assetIDs
        }
        switch panelMode {
        case .recommends:
            return curvedWallRecommendsAllAssetIDs
        case .memories:
            return curvedWallMemoriesAllAssetIDs
        }
    }

    private struct CurvedWallPredictedPanelMetrics: Sendable {
        var viewHeightPoints: Double
        var heightMeters: Float
    }

    private func curvedWallPredictedPanelMetrics(assetID: String) -> CurvedWallPredictedPanelMetrics {
        let panelWidthPoints: Double = 620
        let horizontalPaddingPoints: Double = 4
        let innerWidth = max(panelWidthPoints - (horizontalPaddingPoints * 2), 240)
        let minHeight: Double = 220
        let panelVerticalPaddingPoints: Double = 8

        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return CurvedWallPredictedPanelMetrics(viewHeightPoints: 0, heightMeters: 0) }

        let defaultMediaHeight = max(minHeight, innerWidth * 0.6)
        guard let asset = asset(for: id) else {
            let viewHeightPoints = defaultMediaHeight + panelVerticalPaddingPoints
            let heightMeters = Float(viewHeightPoints / curvedWallPointsPerMeter)
            return CurvedWallPredictedPanelMetrics(viewHeightPoints: viewHeightPoints, heightMeters: heightMeters)
        }

        let w = Double(asset.pixelWidth ?? 0)
        let h = Double(asset.pixelHeight ?? 0)
        let mediaHeight: Double = {
            guard w > 0, h > 0 else { return defaultMediaHeight }

            let aspect = h / w
            var computed = innerWidth * aspect
            if aspect <= 1 {
                if computed < minHeight { computed = minHeight }
            } else {
                computed = min(computed, innerWidth * 1.8)
            }
            return computed
        }()

        let viewHeightPoints = mediaHeight + panelVerticalPaddingPoints
        let heightMeters = Float(viewHeightPoints / curvedWallPointsPerMeter)
        return CurvedWallPredictedPanelMetrics(viewHeightPoints: viewHeightPoints, heightMeters: heightMeters)
    }

    private func curvedWallPageStartIndices(for assetIDs: [String]) -> [Int] {
        let maxColumns = max(1, curvedWallMaxColumns)
        let maxHeight = max(0, curvedWallColumnMaxHeightMeters)
        let spacing = max(0, curvedWallColumnSpacingMeters)

        guard !assetIDs.isEmpty else { return [] }

        var starts: [Int] = [0]
        starts.reserveCapacity(max(1, assetIDs.count / 12))

        var idx = 0
        while idx < assetIDs.count {
            var columnsUsed = 1
            var currentHeight: Float = 0
            var isFirstInColumn = true

            while idx < assetIDs.count {
                let height = max(0, curvedWallPredictedPanelMetrics(assetID: assetIDs[idx]).heightMeters)

                if isFirstInColumn {
                    currentHeight = height
                    isFirstInColumn = false
                    idx += 1
                    continue
                }

                let proposed = currentHeight + spacing + height
                if proposed > maxHeight {
                    columnsUsed += 1
                    if columnsUsed > maxColumns {
                        starts.append(idx)
                        break
                    }
                    currentHeight = height
                    isFirstInColumn = false
                    idx += 1
                } else {
                    currentHeight = proposed
                    idx += 1
                }
            }
        }

        return starts
    }

    private func curvedWallPageIndex(for itemIndex: Int, pageStarts: [Int]) -> Int {
        guard !pageStarts.isEmpty else { return 0 }
        let target = max(0, itemIndex)

        var result = 0
        for (idx, start) in pageStarts.enumerated() {
            if start <= target {
                result = idx
            } else {
                break
            }
        }
        return result
    }

    private func curvedWallMaxPageIndex(for assetIDs: [String]) -> Int {
        let starts = curvedWallPageStartIndices(for: assetIDs)
        return max(0, starts.count - 1)
    }

    private func curvedWallCurrentPageIndex(for placementID: UUID, maxIndex: Int) -> Int {
        let rawIndex = curvedWallPageWindows[placementID] ?? 0
        let clampedMax = max(0, maxIndex)
        return max(0, min(rawIndex, clampedMax))
    }

    public var curvedWallCanPageBack: Bool {
        guard let placementID = curvedWallPlacementID else { return false }
        let ids = curvedWallAllAssetIDsForPaging
        guard !ids.isEmpty else { return false }
        let maxIndex = curvedWallMaxPageIndex(for: ids)
        let index = curvedWallCurrentPageIndex(for: placementID, maxIndex: maxIndex)
        if curvedWallOverride != nil {
            return index > 0
        }
        if panelMode == .memories {
            return index > 0 || memoryPrevEnabled
        }
        return index > 0
    }

    public var curvedWallCanPageForward: Bool {
        guard let placementID = curvedWallPlacementID else { return false }
        let ids = curvedWallAllAssetIDsForPaging
        guard !ids.isEmpty else { return false }
        let maxIndex = curvedWallMaxPageIndex(for: ids)
        let index = curvedWallCurrentPageIndex(for: placementID, maxIndex: maxIndex)
        if curvedWallOverride != nil {
            return index < maxIndex
        }
        if panelMode == .memories {
            return index < maxIndex || memoryNextEnabled
        }
        return index < maxIndex
    }

    public var curvedWallVisibleAssetIDs: [String] {
        guard let placementID = curvedWallPlacementID else { return [] }
        let ids = curvedWallAllAssetIDsForPaging
        guard !ids.isEmpty else { return [] }

        let pageStarts = curvedWallPageStartIndices(for: ids)
        let maxIndex = max(0, pageStarts.count - 1)
        let pageIndex = curvedWallCurrentPageIndex(for: placementID, maxIndex: maxIndex)
        let start = pageStarts.indices.contains(pageIndex) ? pageStarts[pageIndex] : 0
        let end = pageStarts.indices.contains(pageIndex + 1) ? pageStarts[pageIndex + 1] : ids.count
        guard start >= 0, end >= start, end <= ids.count else { return [] }
        return Array(ids[start..<end])
    }

    public var curvedWallVisiblePanels: [CurvedWallPanel] {
        let ids = curvedWallVisibleAssetIDs
        guard !ids.isEmpty else { return [] }

        return ids.compactMap { id in
            guard let asset = asset(for: id) else { return nil }
            let predicted = curvedWallPredictedPanelMetrics(assetID: id)
            return CurvedWallPanel(assetID: asset.id, heightMeters: predicted.heightMeters, viewHeightPoints: predicted.viewHeightPoints)
        }
    }

    public func faceBucketSummaries() async -> [FaceBucketSummary] {
        await faceIndexStore.bucketSummaries()
    }

    public func faceBucketPreviewSummaries(sampleAssetLimit: Int) async -> [FaceBucketPreviewSummary] {
        await faceIndexStore.bucketPreviewSummaries(sampleAssetLimit: sampleAssetLimit)
    }

    public func faceDirectoryEntries() async -> [FaceClusterDirectoryEntry] {
        await faceIndexStore.directoryEntries()
    }

    public func faceIndexConfiguration() async -> FaceIndexStore.Configuration {
        await faceIndexStore.configuration()
    }

    public func faceGroups(faceIDs: [String], distanceThreshold: Float) async -> [[String]] {
        await faceIndexStore.faceGroups(faceIDs: faceIDs, distanceThreshold: distanceThreshold)
    }

    public func faceGroupings(faceIDs: [String], distanceThresholds: [Float]) async -> [[[String]]] {
        await faceIndexStore.faceGroupings(faceIDs: faceIDs, distanceThresholds: distanceThresholds)
    }

    public func faceHierarchyNeedsRebuild() async -> Bool {
        let (thresholds, repCap) = faceHierarchyBuildSettings()
        return await faceHierarchyStore.needsRebuild(levelThresholds: thresholds, repCap: repCap)
    }

    public func rebuildFaceHierarchy(
        force: Bool = false,
        progress: (@MainActor (FaceHierarchyBuildProgress) -> Void)? = nil
    ) async {
        let (thresholds, repCap) = faceHierarchyBuildSettings()

        if !force {
            let needs = await faceHierarchyStore.needsRebuild(levelThresholds: thresholds, repCap: repCap)
            if !needs { return }
        }

        await faceHierarchyStore.rebuildHierarchy(levelThresholds: thresholds, repCap: repCap, progress: progress)
    }

    public func faceHierarchySnapshot() async -> FaceHierarchySnapshot {
        await faceHierarchyStore.snapshot()
    }

    public func faceHierarchyLeafDescendants(nodeID: String) async -> [String] {
        await faceHierarchyStore.leafDescendants(of: nodeID)
    }

    public func setManualFaceHierarchyLabel(nodeID: String, name: String?) async {
        await faceHierarchyStore.setManualLabel(nodeID: nodeID, name: name)

        if let node = await faceHierarchyStore.node(nodeID: nodeID), node.level == 0 {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                await faceIndexStore.clearLabel(faceID: node.id)
            } else {
                await faceIndexStore.setManualLabel(faceID: node.id, displayName: trimmed)
            }
        }
    }

    public func setContactFaceHierarchyLabel(nodeID: String, contactID: String, name: String) async {
        await faceHierarchyStore.setContactLabel(nodeID: nodeID, contactID: contactID, name: name)

        if let node = await faceHierarchyStore.node(nodeID: nodeID), node.level == 0 {
            _ = await faceIndexStore.setClusterLabelFromContact(
                faceID: node.id,
                contactID: contactID,
                displayName: name,
                renameOnlyIfUnlabeled: false
            )
        }
    }

    public func setManualFaceLabel(faceID: String, name: String) async {
        let id = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !trimmed.isEmpty else { return }
        await faceIndexStore.setManualLabel(faceID: id, displayName: trimmed)
    }

    public func clearFaceLabel(faceID: String) async {
        let id = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        await faceIndexStore.clearLabel(faceID: id)
    }

    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            AlbumSettingsStore.save(settings)
        }
    }

    private func faceHierarchyBuildSettings() -> (thresholds: [Float], repCap: Int) {
        func clamp(_ value: Float) -> Float {
            guard value.isFinite else { return 0 }
            return max(0, min(0.95, value))
        }

        let t1 = clamp(settings.faceClusterT1)
        let t2 = max(t1, clamp(settings.faceClusterT2))
        let t3 = max(t2, clamp(settings.faceClusterT3))
        let repCap = max(1, min(32, settings.faceHierarchyRepCap))

        return (thresholds: [0, t1, t2, t3], repCap: repCap)
    }

    public func labelClustersFromContacts(
        maxContacts: Int = 200,
        matchThreshold: Float,
        renameOnlyIfUnlabeled: Bool = true
    ) async -> ContactLabelReport {
        guard datasetSource == .photos else {
            return ContactLabelReport(errorDescription: "Contacts labeling requires Photos dataset source.")
        }

        let labeler = ContactClusterLabeler(faceIndexStore: faceIndexStore)
        return await labeler.labelClustersFromContacts(
            maxContacts: maxContacts,
            matchThreshold: matchThreshold,
            renameOnlyIfUnlabeled: renameOnlyIfUnlabeled
        )
    }

    public func openFaceBucket(faceID: String) async {
        let normalizedFaceID = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFaceID.isEmpty else { return }
        guard datasetSource == .photos else { return }

        let bucketAssetIDsRaw = await faceIndexStore.assets(for: normalizedFaceID)
        let bucketAssetIDs = bucketAssetIDsRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !hiddenIDs.contains($0) }

        guard !bucketAssetIDs.isEmpty else { return }

        let fetched: [AlbumAsset]
        do {
            fetched = try await assetProvider.fetchAssets(localIdentifiers: bucketAssetIDs)
        } catch {
            AlbumLog.photos.error("Face bucket fetchAssets error faceID=\(normalizedFaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }

        var byID: [String: AlbumAsset] = [:]
        byID.reserveCapacity(fetched.count)
        for asset in fetched {
            byID[asset.id] = asset
            pinnedAssetsByID[asset.id] = asset
        }

        let availableIDs = bucketAssetIDs.filter { byID[$0] != nil }
        guard !availableIDs.isEmpty else { return }

        let orderedIDs = availableIDs.sorted { a, b in
            let da = byID[a]?.creationDate ?? .distantPast
            let db = byID[b]?.creationDate ?? .distantPast
            if da != db { return da < db }
            return a < b
        }

        let title = await faceIndexStore.displayName(for: normalizedFaceID)
        curvedWallOverride = CurvedWallOverride(title: title.isEmpty ? normalizedFaceID : title, assetIDs: orderedIDs)
        curvedWallPageWindows[Self.curvedWallOverridePlacementID] = 0
        curvedCanvasEnabled = true
    }

    public func openFaceGroup(faceIDs: [String], title: String) async {
        let normalizedFaceIDs = faceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedFaceIDs.isEmpty else { return }
        guard datasetSource == .photos else { return }

        let titleTrimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = titleTrimmed.isEmpty ? "People" : titleTrimmed

        let bucketAssetIDsRaw = await faceIndexStore.assets(forFaceIDs: normalizedFaceIDs)
        let bucketAssetIDs = bucketAssetIDsRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !hiddenIDs.contains($0) }

        guard !bucketAssetIDs.isEmpty else { return }

        let fetched: [AlbumAsset]
        do {
            fetched = try await assetProvider.fetchAssets(localIdentifiers: bucketAssetIDs)
        } catch {
            AlbumLog.photos.error("Face group fetchAssets error faces=\(normalizedFaceIDs.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }

        var byID: [String: AlbumAsset] = [:]
        byID.reserveCapacity(fetched.count)
        for asset in fetched {
            byID[asset.id] = asset
            pinnedAssetsByID[asset.id] = asset
        }

        let availableIDs = bucketAssetIDs.filter { byID[$0] != nil }
        guard !availableIDs.isEmpty else { return }

        let orderedIDs = availableIDs.sorted { a, b in
            let da = byID[a]?.creationDate ?? .distantPast
            let db = byID[b]?.creationDate ?? .distantPast
            if da != db { return da < db }
            return a < b
        }

        curvedWallOverride = CurvedWallOverride(title: resolvedTitle, assetIDs: orderedIDs)
        curvedWallPageWindows[Self.curvedWallOverridePlacementID] = 0
        curvedCanvasEnabled = true
    }

    public func dumpFocusedNeighborsToCurvedWall() {
        curvedWallOverride = nil
        guard panelMode == .recommends else {
            AlbumLog.model.info("CurvedWall dump (memories): open anchor=\(self.memoryAnchorID ?? "nil", privacy: .public) window=\(self.memoryWindowItems.count) start=\(self.memoryPageStartIndex) label=\(self.memoryLabel, privacy: .public)")
            if let placementID = curvedWallPlacementID {
                let ids = curvedWallMemoriesAllAssetIDs
                if let anchorID = memoryAnchorID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let anchorIndex = ids.firstIndex(of: anchorID) {
                    let starts = curvedWallPageStartIndices(for: ids)
                    curvedWallPageWindows[placementID] = curvedWallPageIndex(for: anchorIndex, pageStarts: starts)
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

        dumpRecommendsNeighborsToCurvedWall(anchorID: anchorID, neighborIDs: recommendItems.map(\.id), openCanvas: true, jumpToNewContent: true)
    }

    private func dumpRecommendsNeighborsToCurvedWall(anchorID: String, neighborIDs rawNeighborIDs: [String], openCanvas: Bool, jumpToNewContent: Bool) {
        let anchorID = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anchorID.isEmpty else { return }

        let neighborIDs = rawNeighborIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != anchorID && !hiddenIDs.contains($0) && item(for: $0) != nil }

        guard !neighborIDs.isEmpty else { return }

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

        let placementID = Self.curvedWallRecommendsPlacementID
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

        let starts = curvedWallPageStartIndices(for: all)
        if jumpToNewContent {
            let jumpPage = curvedWallPageIndex(for: jumpIndex, pageStarts: starts)
            curvedWallPageWindows[placementID] = jumpPage
            AlbumLog.model.info("CurvedWall dump anchor=\(anchorID, privacy: .public) neighbors=\(capped.count) dumps=\(self.curvedWallDumpPages.count) totalItems=\(total) jumpPage=\(jumpPage)")
        } else {
            AlbumLog.model.info("CurvedWall dump anchor=\(anchorID, privacy: .public) neighbors=\(capped.count) dumps=\(self.curvedWallDumpPages.count) totalItems=\(total)")
        }

        if openCanvas {
            curvedCanvasEnabled = true
        }
    }

    public func curvedWallPageBack() {
        guard let placementID = curvedWallPlacementID else { return }
        let ids = curvedWallAllAssetIDsForPaging
        guard !ids.isEmpty else { return }

        let maxIndex = curvedWallMaxPageIndex(for: ids)
        let oldIndex = curvedWallCurrentPageIndex(for: placementID, maxIndex: maxIndex)
        if oldIndex > 0 {
            let newIndex = oldIndex - 1
            curvedWallPageWindows[placementID] = newIndex
            AlbumLog.model.info("CurvedWall pageBack placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> \(newIndex) totalPages=\(maxIndex + 1)")
            curvedCanvasEnabled = true
            return
        }

        guard curvedWallOverride == nil else { return }
        guard panelMode == .memories, memoryPrevEnabled else { return }
        memoryPrevPage()
        let updatedIDs = curvedWallMemoriesAllAssetIDs
        guard !updatedIDs.isEmpty else { return }
        let updatedMaxIndex = curvedWallMaxPageIndex(for: updatedIDs)
        let newIndex = updatedMaxIndex
        curvedWallPageWindows[placementID] = newIndex
        AlbumLog.model.info("CurvedWall pageBack (windowShift) placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> \(newIndex) totalPages=\(updatedMaxIndex + 1) memoryStart=\(self.memoryPageStartIndex)")
        curvedCanvasEnabled = true
    }

    public func curvedWallPageForward() {
        guard let placementID = curvedWallPlacementID else { return }
        let ids = curvedWallAllAssetIDsForPaging
        guard !ids.isEmpty else { return }

        let maxIndex = curvedWallMaxPageIndex(for: ids)
        let oldIndex = curvedWallCurrentPageIndex(for: placementID, maxIndex: maxIndex)
        if oldIndex < maxIndex {
            let newIndex = oldIndex + 1
            curvedWallPageWindows[placementID] = newIndex
            AlbumLog.model.info("CurvedWall pageForward placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> \(newIndex) totalPages=\(maxIndex + 1)")
            curvedCanvasEnabled = true
            return
        }

        guard curvedWallOverride == nil else { return }
        guard panelMode == .memories, memoryNextEnabled else { return }
        memoryNextPage()
        curvedWallPageWindows[placementID] = 0
        let updatedMaxIndex = curvedWallMaxPageIndex(for: curvedWallMemoriesAllAssetIDs)
        AlbumLog.model.info("CurvedWall pageForward (windowShift) placement=\(placementID.uuidString, privacy: .public) page=\(oldIndex) -> 0 totalPages=\(updatedMaxIndex + 1) memoryStart=\(self.memoryPageStartIndex)")
        curvedCanvasEnabled = true
    }

    public func memoryPrevPage() {
        shiftMemoryPage(delta: -1)
    }

    public func memoryNextPage() {
        shiftMemoryPage(delta: 1)
    }

    public func sendThumb(_ feedback: AlbumThumbFeedback, assetID: String, persistPreference: Bool = true) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        thumbFeedbackByAssetID[id] = feedback
        if persistPreference {
            let rating = feedback == .up ? 1 : -1

            let priorScore = preferenceScoreByAssetID[id] ?? 0
            let delta: Float = (feedback == .up) ? 1 : -1
            let newScore = priorScore + delta

            if newScore != 0 {
                preferenceScoreByAssetID[id] = newScore
            } else {
                preferenceScoreByAssetID[id] = nil
            }

            let oldBase = baselineTuningMultipliers(forPreferenceScore: priorScore)
            let newBase = baselineTuningMultipliers(forPreferenceScore: newScore)

            let massMultiplier = newBase.massMultiplier / max(0.000_001, oldBase.massMultiplier)
            let accelerationMultiplier = newBase.accelerationMultiplier / max(0.000_001, oldBase.accelerationMultiplier)
            tuningDeltaRequest = AlbumTuningDeltaRequest(
                deltas: [
                    AlbumItemTuningDelta(
                        itemID: id,
                        massMultiplier: massMultiplier,
                        accelerationMultiplier: accelerationMultiplier
                    )
                ]
            )

            let key = sidecarKey(for: id)
            Task(priority: .utility) { [sidecarStore] in
                await sidecarStore.setRatingAndPreferenceScore(key, rating: rating, preferenceScore: newScore)
            }
        }

#if DEBUG
        if feedback == .up, settings.autofillOnThumbUp {
            ensureVisionSummary(for: id, reason: "thumb_up", priority: .userInitiated)
        }
#endif

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

    private func maybeAutofillThumbUpNeighbors(anchorID: String) {
#if !DEBUG
        return
#else
        let id = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard settings.autofillOnThumbUp else { return }

        let desired = max(0, settings.thumbUpAutofillCount)
        guard desired > 0 else { return }

        guard let neighborIDs = thumbUpAutofillNeighborIDsByAnchorID[id], !neighborIDs.isEmpty else { return }

        if visionStateByAssetID[id] != .computed || AlbumVisionSummaryUtils.isPlaceholder(visionSummaryByAssetID[id]) {
            ensureVisionSummary(for: id, reason: "thumb_up_anchor_compute", priority: .userInitiated)
            return
        }

        thumbUpAutofillNeighborIDsByAnchorID[id] = nil

        Task(priority: .background) { [backfillManager] in
            await backfillManager.autofillNeighbors(anchorID: id, neighborIDs: Array(neighborIDs.prefix(desired)), source: .thumbUpNeighbor)
        }
#endif
    }

    @discardableResult
    public func appendToHistoryIfNew(assetID: String) -> Bool {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        guard !historyAssetIDs.contains(id) else { return false }
        historyAssetIDs.append(id)

        if pinnedAssetsByID[id] == nil, let asset = item(for: id) {
            pinnedAssetsByID[id] = asset
        }

        return true
    }

    public func appendToHistory(assetID: String) {
        _ = appendToHistoryIfNew(assetID: assetID)
    }

    public func loadAssetIntoHistory(_ assetID: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !hiddenIDs.contains(id) else { return }

        Task { @MainActor in
            await self.focusAssetInHistory(assetID: id)
        }
    }

    public func focusAssetInHistory(assetID: String) async {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let isAlreadyMemories = (panelMode == .memories)
        let pinned = await ensurePinnedAssetAvailable(assetID: id, reason: "focus_history")
        guard pinned, item(for: id) != nil else {
            AlbumLog.model.info("Focus ignored (asset unavailable) id=\(id, privacy: .public)")
            return
        }

        _ = appendToHistoryIfNew(assetID: id)
        currentAssetID = id

        if panelMode != .memories {
            panelMode = .memories
        } else if isAlreadyMemories {
            memoryAnchorID = id
            rebuildMemoryWindow(resetToAnchor: true)
        }
    }

    public func clearHistory() {
        historyAssetIDs.removeAll()
        aiNextAssetIDs.removeAll()
    }

    public func createScene(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let record = AlbumSceneRecord(name: trimmed, items: poppedItems)
        scenes.append(record)
        AlbumSceneStore.save(scenes)
    }

    public func deleteScenes(at offsets: IndexSet) {
        scenes.remove(atOffsets: offsets)
        AlbumSceneStore.save(scenes)
    }

    public func updateScene(_ scene: AlbumSceneRecord) {
        guard let idx = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[idx].items = poppedItems
        scenes[idx].createdAt = Date()
        AlbumSceneStore.save(scenes)
    }

    @discardableResult
    public func bookmarkCurrentAsset(into sceneID: AlbumSceneRecord.ID) -> Bool {
        guard let assetID = currentAssetID else { return false }
        return bookmarkAsset(assetID, into: sceneID)
    }

    @discardableResult
    public func bookmarkAsset(_ assetID: String, into sceneID: AlbumSceneRecord.ID) -> Bool {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        guard !hiddenIDs.contains(id) else { return false }
        guard item(for: id) != nil else { return false }

        guard let idx = scenes.firstIndex(where: { $0.id == sceneID }) else { return false }

        let alreadyInScene = scenes[idx].items.contains(where: { $0.kind == .asset && $0.assetID == id })
        guard !alreadyInScene else { return false }

        scenes[idx].items.append(.asset(assetID: id))
        scenes[idx].createdAt = Date()
        AlbumSceneStore.save(scenes)
        return true
    }

    @discardableResult
    public func createPoppedAssetItem(assetID: String) -> AlbumSceneItemRecord? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let item = AlbumSceneItemRecord.asset(assetID: id)
        poppedItems.append(item)
        pinAssetForPopOut(id)
        return item
    }

    @discardableResult
    public func createPoppedMovieItem() -> AlbumSceneItemRecord {
        let item = AlbumSceneItemRecord.movie(draft: AlbumMovieDraft())
        poppedItems.append(item)
        return item
    }

    public func updatePoppedItemWindowMidX(itemID: UUID, midX: Double?) {
        if let midX, midX.isFinite {
            windowMidXByItemID[itemID] = midX
        } else {
            windowMidXByItemID[itemID] = nil
        }
    }

    public func windowMidX(for itemID: UUID) -> Double? {
        windowMidXByItemID[itemID]
    }

    public func updatePoppedItemWindowWorldCenter(itemID: UUID, center: AlbumWindowWorldCenter?) {
        if let center {
            windowWorldCentersByItemID[itemID] = center
        } else {
            windowWorldCentersByItemID[itemID] = nil
        }
    }

    public func windowWorldCenter(for itemID: UUID) -> AlbumWindowWorldCenter? {
        windowWorldCentersByItemID[itemID]
    }

    public func updateHeadWorldTransform(_ m: simd_float4x4) {
        headFrame.current = m
        if headFrame.initial == nil {
            headFrame.initial = m
        }
    }

    public func resetInitialHeadAnchor() {
        headFrame.initial = headFrame.current
    }

    private func headBasisForOrdering() -> (pos: SIMD3<Float>, right: SIMD3<Float>)? {
        let m = headFrame.initial ?? headFrame.current
        let pos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        guard pos.x.isFinite, pos.y.isFinite, pos.z.isFinite else { return nil }

        let fcol = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let flen = simd_length(fcol)
        guard flen.isFinite, flen > 0.000_001 else { return nil }
        let forward = (-fcol) / flen

        let up = SIMD3<Float>(0, 1, 0)
        let rawRight = simd_cross(forward, up)
        let rlen = simd_length(rawRight)
        guard rlen.isFinite, rlen > 0.000_001 else { return nil }
        let right = rawRight / rlen
        return (pos, right)
    }

    private func sortKeyForItem(_ itemID: UUID) -> Float? {
        guard let basis = headBasisForOrdering() else { return nil }
        guard let c = windowWorldCentersByItemID[itemID] else { return nil }
        let p = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        let v = p - basis.pos
        return simd_dot(v, basis.right)
    }

    public func ensurePoppedItemExists(_ item: AlbumSceneItemRecord) {
        guard poppedItems.contains(where: { $0.id == item.id }) == false else { return }
        poppedItems.append(item)
        if item.kind == .asset, let assetID = item.assetID, !assetID.isEmpty {
            pinAssetForPopOut(assetID)
        }
    }

    public func sceneItem(for itemID: UUID) -> AlbumSceneItemRecord? {
        if let hit = poppedItems.first(where: { $0.id == itemID }) {
            return hit
        }
        for scene in scenes {
            if let hit = scene.items.first(where: { $0.id == itemID }) {
                return hit
            }
        }
        return nil
    }

    public func poppedItem(for itemID: UUID) -> AlbumSceneItemRecord? {
        poppedItems.first(where: { $0.id == itemID })
    }

    public func updatePoppedItem(_ itemID: UUID, _ update: (inout AlbumSceneItemRecord) -> Void) {
        guard let idx = poppedItems.firstIndex(where: { $0.id == itemID }) else { return }
        update(&poppedItems[idx])
    }

    public func generateMovie(itemID: UUID) async {
        guard let movieItem = poppedItem(for: itemID), movieItem.kind == .movie else { return }

        if movieItem.movie?.renderState.kind == .rendering {
            return
        }

        let exportablesRaw = poppedItems
            .filter { $0.kind == .asset && ($0.assetID?.isEmpty == false) }

        AlbumLog.model.info("Movie export window positions: \(exportablesRaw.count, privacy: .public)")
        for item in exportablesRaw {
            let midX = windowMidXByItemID[item.id]
            let center = windowWorldCentersByItemID[item.id]
            if let center {
                AlbumLog.model.info("Movie export item id=\(item.id.uuidString, privacy: .public) asset=\(item.assetID ?? "nil", privacy: .public) midX=\(midX ?? 0, privacy: .public) center=(\(center.x, privacy: .public), \(center.y, privacy: .public), \(center.z, privacy: .public))")
            } else {
                AlbumLog.model.info("Movie export item id=\(item.id.uuidString, privacy: .public) asset=\(item.assetID ?? "nil", privacy: .public) midX=\(midX ?? 0, privacy: .public) center=nil")
            }
        }

        if let basis = headBasisForOrdering() {
            AlbumLog.model.info("Movie ordering head pos=(\(basis.pos.x, privacy: .public), \(basis.pos.y, privacy: .public), \(basis.pos.z, privacy: .public)) right=(\(basis.right.x, privacy: .public), \(basis.right.y, privacy: .public), \(basis.right.z, privacy: .public))")
        } else {
            AlbumLog.model.info("Movie ordering head basis unavailable; falling back to world center.x / midX")
        }
        for item in exportablesRaw {
            let midX = windowMidXByItemID[item.id]
            let center = windowWorldCentersByItemID[item.id]
            let key = sortKeyForItem(item.id)
            if let center {
                AlbumLog.model.info("Movie ordering item id=\(item.id.uuidString, privacy: .public) key=\(key ?? -999, privacy: .public) center=(\(center.x, privacy: .public), \(center.y, privacy: .public), \(center.z, privacy: .public)) midX=\(midX ?? 0, privacy: .public)")
            } else {
                AlbumLog.model.info("Movie ordering item id=\(item.id.uuidString, privacy: .public) key=\(key ?? -999, privacy: .public) center=nil midX=\(midX ?? 0, privacy: .public)")
            }
        }

        let exportables = exportablesRaw.sorted { a, b in
            let ak = sortKeyForItem(a.id)
            let bk = sortKeyForItem(b.id)

            switch (ak, bk) {
            case let (ak?, bk?):
                if ak == bk { return a.id.uuidString < b.id.uuidString }
                return ak < bk
            case (nil, nil):
                let ax = windowWorldCentersByItemID[a.id]?.x ?? windowMidXByItemID[a.id] ?? 0
                let bx = windowWorldCentersByItemID[b.id]?.x ?? windowMidXByItemID[b.id] ?? 0
                if ax == bx { return a.id.uuidString < b.id.uuidString }
                return ax < bx
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }

        guard !exportables.isEmpty else {
            updatePoppedItem(itemID) { item in
                var movie = item.movie ?? AlbumMovieDraft()
                movie.renderState = .failed(message: "Add images or videos to the Scene to generate a movie.")
                item.movie = movie
            }
            return
        }

        movieStatusLinesByItemID[itemID] = []
        updatePoppedItem(itemID) { item in
            var movie = item.movie ?? AlbumMovieDraft()
            movie.renderState = .rendering(progress: 0)
            item.movie = movie
        }

        let titleRaw = movieItem.movie?.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleClamped = AlbumMovieDraft.clampedTitle(titleRaw)
        if titleClamped != titleRaw {
            updatePoppedItem(itemID) { item in
                var movie = item.movie ?? AlbumMovieDraft()
                movie.draftTitle = titleClamped
                item.movie = movie
            }
        }
        let title = titleClamped.isEmpty ? "Untitled Movie" : titleClamped
        let subtitle = movieItem.movie?.draftSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        appendMovieStatusLine(itemID: itemID, line: "Analyzing media…")

        var segments: [AlbumMovieExportSegment] = []
        segments.reserveCapacity(exportables.count)

#if canImport(UIKit)
        func cgImage(from image: UIImage) -> CGImage? {
            let pixelSize = CGSize(
                width: image.size.width * image.scale,
                height: image.size.height * image.scale
            )

            guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true

            let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
            let rendered = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
            return rendered.cgImage
        }
#endif

        var missingCount = 0

        for (index, item) in exportables.enumerated() {
            guard let assetID = item.assetID else { continue }

            if Task.isCancelled {
                updatePoppedItem(itemID) { item in
                    var movie = item.movie ?? AlbumMovieDraft()
                    movie.renderState = .failed(message: "Cancelled")
                    item.movie = movie
                }
                return
            }

            let pinned = await ensurePinnedAssetAvailable(assetID: assetID, reason: "movie_export")
            guard pinned, let asset = asset(for: assetID) else {
                missingCount += 1
                appendMovieStatusLine(itemID: itemID, line: "Skipping missing asset (\(assetID)).")
                continue
            }

            switch asset.mediaType {
            case .photo:
                appendMovieStatusLine(itemID: itemID, line: "Preparing image (\(index + 1)/\(exportables.count))…")
                let img = await requestThumbnail(
                    assetID: assetID,
                    targetSize: CGSize(width: 2400, height: 2400),
                    displayScale: 1
                )
#if canImport(UIKit)
                guard let img, let cg = cgImage(from: img) else {
                    missingCount += 1
                    appendMovieStatusLine(itemID: itemID, line: "Skipping image (\(assetID)) (unavailable).")
                    continue
                }

                let size = CGSize(width: cg.width, height: cg.height)
                let anchors = effectiveKenBurnsAnchorsForExport(item: item, assetID: assetID, imageSize: size)
                segments.append(.image(instanceID: item.id, assetID: assetID, cgImage: cg, startAnchor: anchors.start, endAnchor: anchors.end))
#else
                missingCount += 1
                appendMovieStatusLine(itemID: itemID, line: "Skipping image (\(assetID)) (unsupported platform).")
#endif

            case .video:
                appendMovieStatusLine(itemID: itemID, line: "Preparing video (\(index + 1)/\(exportables.count))…")
                guard let url = await requestVideoURL(assetID: assetID) else {
                    missingCount += 1
                    appendMovieStatusLine(itemID: itemID, line: "Skipping video (\(assetID)) (unavailable).")
                    continue
                }

                let duration = max(0, asset.duration ?? 0)
                let defaultEnd = min(5.0, duration > 0 ? duration : 5.0)

                var start = max(0, item.trimStartSeconds ?? 0)
                var end = item.trimEndSeconds ?? defaultEnd
                if duration > 0 {
                    end = min(end, duration)
                }
                if end - start < 0.5 {
                    end = min(max(start + 0.5, end), duration > 0 ? duration : start + 0.5)
                }

                let cropAnchor = effectiveVideoCropAnchorForExport(item: item, asset: asset)
                segments.append(.video(instanceID: item.id, assetID: assetID, url: url, trimStart: start, trimEnd: end, cropAnchor: cropAnchor))
            }
        }

        if segments.isEmpty {
            updatePoppedItem(itemID) { item in
                var movie = item.movie ?? AlbumMovieDraft()
                movie.renderState = .failed(message: "No usable media items to export.")
                item.movie = movie
            }
            return
        }

        if missingCount > 0 {
            appendMovieStatusLine(itemID: itemID, line: "Skipped \(missingCount) missing items.")
        }

        do {
            let request = AlbumMovieExportRequest(
                title: title,
                subtitle: subtitle?.isEmpty ?? true ? nil : subtitle,
                segments: segments
            )

            let result = try await AlbumMovieExportPipeline.export(
                request: request,
                progress: { [weak self] progress in
                    guard let self else { return }
                    self.updatePoppedItem(itemID) { item in
                        var movie = item.movie ?? AlbumMovieDraft()
                        movie.renderState = .rendering(progress: max(0, min(1, progress)))
                        item.movie = movie
                    }
                },
                status: { [weak self] line in
                    self?.appendMovieStatusLine(itemID: itemID, line: line)
                }
            )

            updatePoppedItem(itemID) { item in
                var movie = item.movie ?? AlbumMovieDraft()
                movie.renderState = .ready
                movie.artifactRelativePath = result.relativePath
                movie.artifactMetadata = AlbumMovieArtifactMetadata(
                    durationSeconds: result.durationSeconds,
                    fileSizeBytes: result.fileSizeBytes,
                    createdAt: result.createdAt,
                    renderWidth: 1080,
                    renderHeight: 1080,
                    fps: 30
                )
                item.movie = movie
            }
            appendMovieStatusLine(itemID: itemID, line: "Done.")
        } catch {
            appendMovieStatusLine(itemID: itemID, line: "Export failed.")
            updatePoppedItem(itemID) { item in
                var movie = item.movie ?? AlbumMovieDraft()
                movie.renderState = .failed(message: String(describing: error))
                item.movie = movie
            }
        }
    }

    private func effectiveKenBurnsAnchorsForExport(item: AlbumSceneItemRecord, assetID: String, imageSize: CGSize) -> (start: CGPoint, end: CGPoint) {
        let start = item.kenBurnsStartAnchor ?? CGPoint(x: 0.5, y: 0.5)
        let end = item.kenBurnsEndAnchor ?? defaultKenBurnsEndAnchor(assetID: assetID)
        let allowed = allowedKenBurnsNormalizedRect(imageSize: imageSize, renderSize: 1080)
        return (clampKenBurnsAnchor(start, to: allowed), clampKenBurnsAnchor(end, to: allowed))
    }

    private func effectiveVideoCropAnchorForExport(item: AlbumSceneItemRecord, asset: AlbumAsset) -> CGPoint {
        let anchor = item.videoCropAnchor ?? CGPoint(x: 0.5, y: 0.5)
        let w = CGFloat(asset.pixelWidth ?? 0)
        let h = CGFloat(asset.pixelHeight ?? 0)
        guard w > 0, h > 0 else { return anchor }
        let allowed = allowedKenBurnsNormalizedRect(imageSize: CGSize(width: w, height: h), renderSize: 1080)
        return clampKenBurnsAnchor(anchor, to: allowed)
    }

    private func allowedKenBurnsNormalizedRect(imageSize: CGSize, renderSize: Double) -> CGRect {
        let w = Double(imageSize.width)
        let h = Double(imageSize.height)
        guard w > 0, h > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let scale = max(renderSize / w, renderSize / h)
        let cropSizePx = renderSize / max(0.000_001, scale)
        let halfX = (cropSizePx / 2) / w
        let halfY = (cropSizePx / 2) / h

        let minX = min(max(halfX, 0), 0.5)
        let maxX = max(min(1 - halfX, 1), 0.5)
        let minY = min(max(halfY, 0), 0.5)
        let maxY = max(min(1 - halfY, 1), 0.5)

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func clampKenBurnsAnchor(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func defaultKenBurnsEndAnchor(assetID: String) -> CGPoint {
        let options: [CGPoint] = [
            CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
            CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0),
            CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
            CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0),
        ]
        return options[stableHashMod4(assetID)]
    }

    private func stableHashMod4(_ input: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % 4)
    }

    public func generateMovieDraftTitle(itemID: UUID) async {
        guard let existing = poppedItem(for: itemID), existing.kind == .movie else { return }
        guard !movieTitleGenerationInFlightItemIDs.contains(itemID) else { return }

        movieTitleGenerationInFlightItemIDs.insert(itemID)
        defer { movieTitleGenerationInFlightItemIDs.remove(itemID) }

        appendMovieStatusLine(itemID: itemID, line: "Generating title…")

        let exportables = poppedItems.filter { $0.kind == .asset }
        let assets: [AlbumAsset] = exportables.compactMap { item in
            guard let assetID = item.assetID, !assetID.isEmpty else { return nil }
            return asset(for: assetID)
        }

        let dateText = movieDateSubtitle(from: assets)
        let locationText = await movieLocationSubtitle(from: assets)
        let subtitleSeed = [dateText, locationText].compactMap { $0 }.joined(separator: " • ").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = subtitleSeed.isEmpty ? nil : subtitleSeed

        let labels = await movieTopLabels(for: exportables)

        let generated: (title: String, subtitle: String?) = {
            let fallbackTitle = movieFallbackTitle(topLabels: labels)
            return (title: fallbackTitle, subtitle: subtitle)
        }()

#if canImport(FoundationModels)
        if !labels.isEmpty, #available(visionOS 26.0, *) {
            let requestID = UUID()
            let context = subtitle
            let llm = await AlbumFoundationModelsOracleEngine.shared.generateMovieTitle(topLabels: labels, context: context, requestID: requestID)
            if let title = llm.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                let sub = llm.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalSubtitle = (sub?.isEmpty ?? true) ? subtitle : sub
                applyGeneratedMovieTitle(itemID: itemID, title: title, subtitle: finalSubtitle)
                appendMovieStatusLine(itemID: itemID, line: "Title ready.")
                return
            }
        }
#endif

        applyGeneratedMovieTitle(itemID: itemID, title: generated.title, subtitle: generated.subtitle)
        appendMovieStatusLine(itemID: itemID, line: "Title ready.")
    }

    private func applyGeneratedMovieTitle(itemID: UUID, title: String, subtitle: String?) {
        updatePoppedItem(itemID) { item in
            var movie = item.movie ?? AlbumMovieDraft()

            let currentTitle = movie.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !movie.titleUserEdited || currentTitle.isEmpty {
                movie.draftTitle = AlbumMovieDraft.clampedTitle(title.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if let subtitle {
                let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    movie.draftSubtitle = trimmed
                }
            }

            item.movie = movie
        }
    }

    private func appendMovieStatusLine(itemID: UUID, line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var lines = movieStatusLinesByItemID[itemID] ?? []
        lines.append(trimmed)
        if lines.count > 60 {
            lines.removeFirst(lines.count - 60)
        }
        movieStatusLinesByItemID[itemID] = lines
    }

    private func movieFallbackTitle(topLabels: [String]) -> String {
        let joined = topLabels.map { $0.lowercased() }.joined(separator: " ")
        func hasAny(_ terms: [String]) -> Bool {
            terms.contains(where: { joined.contains($0) })
        }

        if hasAny(["beach", "ocean", "sand", "sea"]) { return "Beachside Days" }
        if hasAny(["mountain", "hiking", "forest", "lake"]) { return "Mountain Mornings" }
        if hasAny(["snow", "ski", "winter"]) { return "Winter Days" }
        if hasAny(["city", "skyline", "street"]) { return "City Lights" }
        if hasAny(["dog", "puppy"]) { return "Days With Our Pup" }
        if hasAny(["cat", "kitten"]) { return "Days With Our Cat" }
        return "Golden Afternoons"
    }

    private func movieDateSubtitle(from assets: [AlbumAsset]) -> String? {
        let dates = assets.compactMap(\.creationDate).sorted()
        guard let minDate = dates.first, let maxDate = dates.last else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = cal

        if cal.isDate(minDate, inSameDayAs: maxDate) {
            fmt.dateFormat = "MMM d, yyyy"
            return fmt.string(from: minDate)
        }

        let minYear = cal.component(.year, from: minDate)
        let maxYear = cal.component(.year, from: maxDate)

        if minYear != maxYear {
            return "\(minYear)–\(maxYear)"
        }

        let minMonth = cal.component(.month, from: minDate)
        let maxMonth = cal.component(.month, from: maxDate)

        if minMonth == maxMonth {
            fmt.dateFormat = "MMM d"
            let left = fmt.string(from: minDate)
            fmt.dateFormat = "d, yyyy"
            let right = fmt.string(from: maxDate)
            return "\(left)–\(right)"
        }

        fmt.dateFormat = "MMM d"
        let left = fmt.string(from: minDate)
        fmt.dateFormat = "MMM d, yyyy"
        let right = fmt.string(from: maxDate)
        return "\(left)–\(right)"
    }

    private func movieLocationSubtitle(from assets: [AlbumAsset]) async -> String? {
        guard let loc = assets.compactMap(\.location).first else { return nil }
        let location = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        return await withTimeout(seconds: 0.45) {
            await self.reverseGeocode(location: location)
        }
    }

    private func reverseGeocode(location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                let place = placemarks?.first
                let parts = [place?.locality, place?.administrativeArea, place?.country]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if parts.isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: parts.prefix(2).joined(separator: ", "))
                }
            }
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T?) async -> T? {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func movieTopLabels(for items: [AlbumSceneItemRecord]) async -> [String] {
        var weights: [String: Double] = [:]
        weights.reserveCapacity(24)

        for item in items {
            guard let assetID = item.assetID, !assetID.isEmpty else { continue }
            guard let asset = asset(for: assetID) else { continue }

            let durationWeight: Double = {
                switch asset.mediaType {
                case .photo:
                    return 5.0
                case .video:
                    let duration = asset.duration ?? 0
                    if let s = item.trimStartSeconds, let e = item.trimEndSeconds, e > s {
                        return max(0.5, e - s)
                    }
                    return min(5.0, max(0, duration))
                }
            }()

            let labels: [AlbumVisionLabel]
            switch asset.mediaType {
            case .photo:
                labels = await movieLabelsForImage(assetID: assetID)
            case .video:
                let start = item.trimStartSeconds ?? 0
                let sampleTime = max(0, start + 0.25)
                labels = await movieLabelsForVideo(assetID: assetID, sampleTime: sampleTime)
            }

            for label in labels {
                let cleaned = normalizeVisionLabel(label.text)
                guard !cleaned.isEmpty else { continue }
                let w = Double(label.confidence) * durationWeight
                weights[cleaned, default: 0] += w
            }
        }

        return weights
            .sorted(by: { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            })
            .prefix(8)
            .map(\.key)
    }

    private func normalizeVisionLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func movieLabelsForImage(assetID: String) async -> [AlbumVisionLabel] {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        guard datasetSource == .photos else { return [] }

        if let cached = await AlbumMovieVisionLabeler.shared.cachedImageLabels(assetID: id) {
            return cached
        }

        let data = await assetProvider.requestVisionThumbnailData(localIdentifier: id, maxDimension: 512)
        guard let data else { return [] }
        let labels = await AlbumMovieVisionLabeler.shared.classifyImage(assetID: id, imageData: data, maxDimension: 512)
        return labels
    }

    private func movieLabelsForVideo(assetID: String, sampleTime: Double) async -> [AlbumVisionLabel] {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }
        guard datasetSource == .photos else { return [] }

        let bucket = Int(max(0, sampleTime).rounded(.down))
        if let cached = await AlbumMovieVisionLabeler.shared.cachedVideoLabels(assetID: id, bucket: bucket) {
            return cached
        }

        guard let url = await requestVideoURL(assetID: id) else { return [] }
        let labels = await AlbumMovieVisionLabeler.shared.classifyVideo(assetID: id, url: url, sampleTime: sampleTime, bucket: bucket)
        return labels
    }

    public func removePoppedItem(_ itemID: UUID) {
        guard let item = poppedItems.first(where: { $0.id == itemID }) else { return }
        poppedItems.removeAll(where: { $0.id == itemID })
        windowMidXByItemID[itemID] = nil
        windowWorldCentersByItemID[itemID] = nil

        guard item.kind == .asset, let assetID = item.assetID, !assetID.isEmpty else { return }

        let stillPopped = poppedItems.contains(where: { $0.kind == .asset && $0.assetID == assetID })
        if !stillPopped, !historyAssetIDs.contains(assetID), currentAssetID != assetID {
            pinnedAssetsByID[assetID] = nil
        }
        pinnedAssetLoadsInFlight.remove(assetID)
    }

    private func ensurePinnedAssetAvailable(assetID: String, reason: String) async -> Bool {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }

        if let existing = item(for: id) {
            if pinnedAssetsByID[id] == nil {
                pinnedAssetsByID[id] = existing
            }
            return true
        }

        guard datasetSource == .photos else { return false }

        if pinnedAssetLoadsInFlight.contains(id) {
            let pollLimitNanos: UInt64 = 4_500_000_000
            let pollIntervalNanos: UInt64 = 150_000_000
            var waited: UInt64 = 0

            while waited < pollLimitNanos {
                if let existing = item(for: id) {
                    if pinnedAssetsByID[id] == nil {
                        pinnedAssetsByID[id] = existing
                    }
                    return true
                }
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                waited &+= pollIntervalNanos
            }
        }

        guard !pinnedAssetLoadsInFlight.contains(id) else { return false }
        pinnedAssetLoadsInFlight.insert(id)
        defer { pinnedAssetLoadsInFlight.remove(id) }

        AlbumLog.model.info("Pin requesting fetch id=\(id, privacy: .public) reason=\(reason, privacy: .public)")

        do {
            let fetched = try await assetProvider.fetchAssets(localIdentifiers: [id])
            guard let asset = fetched.first(where: { $0.id == id }) else {
                AlbumLog.photos.info("Pin fetchAssets returned no results id=\(id, privacy: .public)")
                return false
            }
            pinnedAssetsByID[id] = asset
            return true
        } catch {
            AlbumLog.photos.error("Pin fetchAssets error id=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func pinAssetForPopOut(_ assetID: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard pinnedAssetsByID[id] == nil else { return }

        if let existing = items.first(where: { $0.id == id })
            ?? memoryWindowItems.first(where: { $0.id == id })
            ?? recommendItems.first(where: { $0.id == id }) {
            pinnedAssetsByID[id] = existing
            return
        }

        guard datasetSource == .photos else { return }
        guard !pinnedAssetLoadsInFlight.contains(id) else { return }
        pinnedAssetLoadsInFlight.insert(id)

        AlbumLog.model.info("PopOut pin requesting asset fetch id=\(id, privacy: .public)")
        Task { @MainActor in
            defer { self.pinnedAssetLoadsInFlight.remove(id) }
            do {
                let fetched = try await assetProvider.fetchAssets(localIdentifiers: [id])
                guard let asset = fetched.first(where: { $0.id == id }) else {
                    AlbumLog.photos.info("PopOut pin fetchAssets returned no results id=\(id, privacy: .public)")
                    return
                }
                self.pinnedAssetsByID[id] = asset
                self.ensureVisionSummary(for: id, reason: "popout_pin", priority: .userInitiated)
            } catch {
                AlbumLog.photos.error("PopOut pin fetchAssets error id=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
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

    @discardableResult
    public func unhideAllAssets() async -> Int {
        let changed = await sidecarStore.unhideAll()
        hiddenIDs.removeAll()

        if datasetSource == .demo {
            loadDemoItems(count: max(1, lastAssetFetchCount))
            return changed
        }

        let limit = max(1, lastAssetFetchCount > 0 ? lastAssetFetchCount : settings.assetLoadLimit)
        await loadItems(limit: limit, query: selectedQuery)
        return changed
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
        visionStateByAssetID[assetID] = .computed
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

    private func applyVisionUpdate(_ update: AlbumBackfillVisionUpdate) {
        let assetID = update.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetID.isEmpty else { return }
        let trimmed = update.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if visionStateByAssetID[assetID] == .computed, update.state != .computed {
            return
        }

        visionSummaryByAssetID[assetID] = trimmed
        visionStateByAssetID[assetID] = update.state
        visionConfidenceByAssetID[assetID] = update.confidence
        visionPendingAssetIDs.remove(assetID)

        if update.state == .computed {
            maybeAutofillThumbUpNeighbors(anchorID: assetID)
        }
    }

    public func ensureVisionSummary(for assetID: String, reason: String, priority: TaskPriority = .utility) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        if datasetSource == .demo || AlbumDemoLibrary.isDemoID(id) {
            if visionSummaryByAssetID[id] == nil {
                visionSummaryByAssetID[id] = AlbumDemoLibrary.placeholderTitle(for: id, mediaType: asset(for: id)?.mediaType)
                visionStateByAssetID[id] = .computed
                visionConfidenceByAssetID[id] = 1.0
            }
            return
        }

        let backfillPriority: AlbumBackfillManager.Priority = {
            switch priority {
            case .userInitiated:
                return .interactive
            case .utility:
                return .visible
            default:
                return .background
            }
        }()

        if visionStateByAssetID[id] == .computed,
           !AlbumVisionSummaryUtils.isPlaceholder(visionSummaryByAssetID[id]) {
            Task(priority: priority) { [backfillManager] in
                await backfillManager.ensureVision(for: id, priority: backfillPriority)
            }
            return
        }

        visionPendingAssetIDs.insert(id)

        Task(priority: priority) { [backfillManager] in
            await backfillManager.ensureVision(for: id, priority: backfillPriority)
        }
    }

    private func enqueueVisionForActiveSet(assetIDs: [String], reason: String) {
        guard datasetSource == .photos else { return }
        guard !assetIDs.isEmpty else { return }

        let ids = assetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !ids.isEmpty else { return }

        // Avoid flooding the vision queue; backfill handles the broad library scan.
        let maxBurst = 40
        let burst = Array(ids.prefix(maxBurst))
        if ids.count > burst.count {
            AlbumLog.model.info("Vision enqueue burst capped reason=\(reason, privacy: .public) requested=\(ids.count, privacy: .public) using=\(burst.count, privacy: .public)")
        }

        Task(priority: .background) { [backfillManager] in
            for id in burst {
                await backfillManager.ensureVision(for: id, priority: .background)
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

        var status: String
        switch feedback {
        case .up:
            status = "👍 Neighbors ready (\(recommendItems.count)) • \(outcome.backend.rawValue)"
        case .down:
            status = "👎 nextID ignored • Neighbors ready (\(recommendItems.count)) • \(outcome.backend.rawValue)"
        }
        if let note = outcome.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            let capped = note.count > 140 ? "\(note.prefix(140))…" : note
            status.append(" (\(capped))")
        }

        AlbumLog.model.info("Thumb outcome backend: \(outcome.backend.rawValue, privacy: .public) neighbors: \(self.recommendItems.count)")
        thumbStatusMessage = status
    }

    private func buildOracleSnapshot(thumbed: AlbumItem) async -> AlbumOracleSnapshot {
        // Keep prompts comfortably under the model context window.
        let maxCandidates = 240
        let maxPromptChars = 4_000

        func promptField(_ value: String, maxLen: Int? = nil) -> String {
            let normalized = value
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let ascii = String(
                normalized.unicodeScalars.map { scalar in
                    scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F ? Character(scalar) : " "
                }
            )

            let collapsed = ascii.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let maxLen, maxLen > 0, trimmed.count > maxLen else { return trimmed }

            let suffixLen = min(12, max(4, maxLen / 3))
            let prefixLen = max(1, maxLen - suffixLen - 1)
            return "\(trimmed.prefix(prefixLen))…\(trimmed.suffix(suffixLen))"
        }

        func promptFileName(_ asset: AlbumAsset) -> String {
            promptField(fileNameOrFallback(for: asset), maxLen: 56)
                .replacingOccurrences(of: " ", with: "_")
        }

	        func promptVisionSummary(_ summary: String) -> String {
	            promptField(summary, maxLen: 96)
	        }

	        func promptFaces(_ faceIDs: [String]) -> String {
	            let trimmed = faceIDs
	                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
	                .filter { !$0.isEmpty }
	            guard !trimmed.isEmpty else { return "none" }
	            let maxShown = 4
	            let shown = Array(trimmed.prefix(maxShown))
	            let overflow = max(0, trimmed.count - shown.count)
	            if overflow > 0 {
	                return "\(shown.joined(separator: ","))+\(overflow)"
	            }
	            return shown.joined(separator: ",")
	        }

	        func tokenize(_ text: String) -> Set<String> {
	            let lowered = text.lowercased()
	            let parts = lowered.split { ch in
	                !(ch.isLetter || ch.isNumber)
            }
            var tokens = Set<String>()
            tokens.reserveCapacity(min(parts.count, 32))
            for p in parts {
                guard p.count >= 3 else { continue }
                tokens.insert(String(p))
            }
            return tokens
        }

        func jaccardSimilarity(thumbTokens: Set<String>, candidateText: String) -> Double {
            guard !thumbTokens.isEmpty else { return 0 }
            let candidateTokens = tokenize(candidateText)
            guard !candidateTokens.isEmpty else { return 0 }
            let intersection = thumbTokens.intersection(candidateTokens).count
            if intersection == 0 { return 0 }
            let union = thumbTokens.union(candidateTokens).count
            return union > 0 ? Double(intersection) / Double(union) : 0
        }

        func fileNameOrFallback(for asset: AlbumAsset) -> String {
            let trimmed = asset.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "unknown" : trimmed
        }

	        if datasetSource == .demo {
	            let thumbedHandle = promptVisionSummary(semanticHandle(for: thumbed))
	            let thumbTokens = tokenize(thumbedHandle)
	            let thumbedFaceIDs: [String] = []

	            let candidateItems: [AlbumAsset] = items.compactMap { item in
	                if item.id == thumbed.id { return nil }
	                if hiddenIDs.contains(item.id) { return nil }
                return item
            }

            struct ScoredCandidate {
                let asset: AlbumAsset
                let summary: String
                let score: Double
            }

            var scored: [ScoredCandidate] = []
            scored.reserveCapacity(candidateItems.count)

            for item in candidateItems {
                let summary = promptVisionSummary(semanticHandle(for: item))
                let score = jaccardSimilarity(thumbTokens: thumbTokens, candidateText: summary)
                scored.append(.init(asset: item, summary: summary, score: score))
            }

	            scored.sort {
	                if $0.score != $1.score { return $0.score > $1.score }
	                return $0.asset.id < $1.asset.id
	            }

	            let baseLines: [String] = [
	                "THUMBED_FILE: \(promptFileName(thumbed))",
	                "THUMBED_VISION: \(thumbedHandle)",
	                "THUMBED_FACES: \(promptFaces(thumbedFaceIDs))",
	                "ALREADY_SEEN_IDS:",
	                "CANDIDATES (ID\\tFILE\\tVISION\\tFACES):"
	            ]
	            var promptChars = baseLines.reduce(0) { $0 + $1.count } + (baseLines.count - 1)

	            var candidates: [AlbumOracleCandidate] = []
            candidates.reserveCapacity(min(scored.count, maxCandidates))

	            for entry in scored {
	                guard candidates.count < maxCandidates else { break }
	                let key = "c\(candidates.count)"
	                let faces = promptFaces([])
	                let line = "\(key)\t\(promptFileName(entry.asset))\t\(entry.summary)\t\(faces)"

	                let projected = promptChars + line.count + 1
	                guard projected <= maxPromptChars else { break }
	                promptChars = projected

	                candidates.append(
	                    AlbumOracleCandidate(
	                        assetID: entry.asset.id,
	                        promptID: key,
	                        fileName: promptFileName(entry.asset),
	                        visionSummary: entry.summary,
	                        faceIDs: [],
	                        mediaType: entry.asset.mediaType,
	                        createdYearMonth: createdYearMonth(for: entry.asset),
	                        locationBucket: locationBucket(for: entry.asset)
	                    )
                )
            }

	            let alreadySeen = Set(history.map(\.id)).union([thumbed.id])

	            return AlbumOracleSnapshot(
	                thumbedAssetID: thumbed.id,
	                thumbedFileName: promptFileName(thumbed),
	                thumbedMediaType: thumbed.mediaType,
	                thumbedCreatedYearMonth: createdYearMonth(for: thumbed),
	                thumbedLocationBucket: locationBucket(for: thumbed),
	                thumbedVisionSummary: thumbedHandle,
	                thumbedFaceIDs: thumbedFaceIDs,
	                candidates: candidates,
	                alreadySeenAssetIDs: alreadySeen
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

	        let faceIDsByAssetID = await faceIndexStore.faceIDsByAssetID(for: allIDs)
	        let records = await sidecarStore.loadMany(allIDs.map { AlbumSidecarKey(source: .photos, id: $0) })
	        var recordByID: [String: AlbumSidecarRecord] = [:]
	        recordByID.reserveCapacity(records.count)

        for record in records {
            let id = record.key.id
            guard !id.isEmpty else { continue }
            recordByID[id] = record

            if let summary = record.vision.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty,
               visionSummaryByAssetID[id] == nil {
                visionSummaryByAssetID[id] = summary
            }
            if record.vision.state != .none, visionStateByAssetID[id] == nil {
                visionStateByAssetID[id] = record.vision.state
            }
            if let conf = record.vision.confidence, visionConfidenceByAssetID[id] == nil {
                visionConfidenceByAssetID[id] = conf
            }
        }

        var allFaceIDs: [String] = []
        allFaceIDs.reserveCapacity(min(2048, allIDs.count * 2))
        for (_, faceIDs) in faceIDsByAssetID {
            allFaceIDs.append(contentsOf: faceIDs)
        }
        for record in records {
            allFaceIDs.append(contentsOf: record.faces.faceIDs)
        }
        let hierarchyTokensByLeafID = await faceHierarchyStore.clusterTokenPreferredByLeafID(for: allFaceIDs)
        let faceTokenInfoByID = await faceIndexStore.promptTokenInfoByFaceID(for: allFaceIDs)

	        func oracleVisionSummary(assetID: String, mediaType: AlbumMediaType) -> String {
	            let trimmedID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
	            if let summary = visionSummaryByAssetID[trimmedID]?.trimmingCharacters(in: .whitespacesAndNewlines),
	               !summary.isEmpty {
                return normalizeVisionSummary(summary)
            }

            if let record = recordByID[trimmedID],
               let summary = record.vision.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return normalizeVisionSummary(summary)
            }

	            return "unlabeled"
	        }

	        func oracleFaceIDs(assetID: String) -> [String] {
	            let trimmedID = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            let faceIDs: [String] = {
                if let faceIDs = faceIDsByAssetID[trimmedID], !faceIDs.isEmpty {
                    return faceIDs
                }
                if let record = recordByID[trimmedID] {
                    return record.faces.faceIDs
                }
                return []
            }()

            let normalized = faceIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !normalized.isEmpty else { return [] }

            var tokens: [String] = []
            tokens.reserveCapacity(min(8, normalized.count))

            for id in normalized {
                if let preferred = hierarchyTokensByLeafID[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !preferred.isEmpty {
                    tokens.append(preferred)
                    continue
                }

                if let info = faceTokenInfoByID[id], info.isLabeled {
                    tokens.append(info.token)
                    continue
                }

                tokens.append(id)
            }

            var out: [String] = []
            out.reserveCapacity(tokens.count)

            var seen = Set<String>()
            seen.reserveCapacity(tokens.count)

            for raw in tokens {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed).inserted else { continue }
                out.append(trimmed)
            }

            return out
	        }

        func normalizeVisionSummary(_ summary: String) -> String {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("vision:") {
                let dropped = trimmed.dropFirst("vision:".count)
                let cleaned = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? trimmed : cleaned
            }
            return trimmed
        }

        var idsNeedingCompute: Set<String> = []
        idsNeedingCompute.reserveCapacity(32)

        func noteIfNeedsCompute(assetID: String) {
            let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }

            if visionStateByAssetID[id] == .computed,
               !AlbumVisionSummaryUtils.isPlaceholder(visionSummaryByAssetID[id]) { return }
            if let record = recordByID[id], AlbumVisionSummaryUtils.isMeaningfulComputed(record) { return }
            idsNeedingCompute.insert(id)
        }

	        let thumbedVisionRaw = oracleVisionSummary(assetID: thumbed.id, mediaType: thumbed.mediaType)
	        let thumbedVision = promptVisionSummary(thumbedVisionRaw)
	        let thumbedFaceIDs = oracleFaceIDs(assetID: thumbed.id)
	        noteIfNeedsCompute(assetID: thumbed.id)

	        let thumbTokens = tokenize(thumbedVisionRaw)

        struct ScoredCandidate {
            let asset: AlbumAsset
            let summary: String
            let score: Double
        }

        var scored: [ScoredCandidate] = []
        scored.reserveCapacity(candidateItems.count)

        for item in candidateItems {
            let summary = oracleVisionSummary(assetID: item.id, mediaType: item.mediaType)
            let score = jaccardSimilarity(thumbTokens: thumbTokens, candidateText: summary)
            scored.append(.init(asset: item, summary: promptVisionSummary(summary), score: score))
        }

	        scored.sort {
	            if $0.score != $1.score { return $0.score > $1.score }
	            return $0.asset.id < $1.asset.id
	        }

	        let baseLines: [String] = [
	            "THUMBED_FILE: \(promptFileName(thumbed))",
	            "THUMBED_VISION: \(thumbedVision)",
	            "THUMBED_FACES: \(promptFaces(thumbedFaceIDs))",
	            "ALREADY_SEEN_IDS:",
	            "CANDIDATES (ID\\tFILE\\tVISION\\tFACES):"
	        ]
	        var promptChars = baseLines.reduce(0) { $0 + $1.count } + (baseLines.count - 1)

	        var candidates: [AlbumOracleCandidate] = []
        candidates.reserveCapacity(min(scored.count, maxCandidates))

	        for entry in scored {
	            guard candidates.count < maxCandidates else { break }
	            let key = "c\(candidates.count)"
	            let faceIDs = oracleFaceIDs(assetID: entry.asset.id)
	            let facesColumn = promptFaces(faceIDs)
	            let line = "\(key)\t\(promptFileName(entry.asset))\t\(entry.summary)\t\(facesColumn)"

	            let projected = promptChars + line.count + 1
	            guard projected <= maxPromptChars else { break }
	            promptChars = projected

            if entry.summary.lowercased().hasPrefix("unlabeled") {
                noteIfNeedsCompute(assetID: entry.asset.id)
            } else if recordByID[entry.asset.id]?.vision.state == .autofilled {
                noteIfNeedsCompute(assetID: entry.asset.id)
            }

	            candidates.append(
	                AlbumOracleCandidate(
	                    assetID: entry.asset.id,
	                    promptID: key,
	                    fileName: promptFileName(entry.asset),
	                    visionSummary: entry.summary,
	                    faceIDs: faceIDs,
	                    mediaType: entry.asset.mediaType,
	                    createdYearMonth: createdYearMonth(for: entry.asset),
	                    locationBucket: locationBucket(for: entry.asset)
	                )
            )
        }

        if !idsNeedingCompute.isEmpty {
            enqueueVisionForActiveSet(assetIDs: Array(idsNeedingCompute), reason: "oracle_snapshot")
        }

	        let alreadySeen = Set(history.map(\.id)).union([thumbed.id])

	        return AlbumOracleSnapshot(
	            thumbedAssetID: thumbed.id,
	            thumbedFileName: promptFileName(thumbed),
	            thumbedMediaType: thumbed.mediaType,
	            thumbedCreatedYearMonth: createdYearMonth(for: thumbed),
	            thumbedLocationBucket: locationBucket(for: thumbed),
	            thumbedVisionSummary: thumbedVision,
	            thumbedFaceIDs: thumbedFaceIDs,
	            candidates: candidates,
	            alreadySeenAssetIDs: alreadySeen
	        )
	    }

    private func applyOracleResult(feedback: AlbumThumbFeedback, snapshot: AlbumOracleSnapshot, result: AlbumRecResponse) {
        let anchorID = snapshot.thumbedAssetID.trimmingCharacters(in: .whitespacesAndNewlines)
        recommendAnchorID = anchorID

        recommendsCacheByAnchorID[anchorID] = result
        recommendsFeedbackByAnchorID[anchorID] = feedback

        recommendItems = result.neighbors.compactMap { item(for: $0.id) }
            .filter { $0.id != anchorID && !hiddenIDs.contains($0.id) }
        neighborsReady = !recommendItems.isEmpty

        if feedback == .up, neighborsReady {
            let isShowingRecommendsInCurvedWall = (curvedCanvasEnabled && panelMode == .recommends)
            dumpRecommendsNeighborsToCurvedWall(
                anchorID: anchorID,
                neighborIDs: result.neighbors.map(\.id),
                openCanvas: false,
                jumpToNewContent: !isShowingRecommendsInCurvedWall
            )
        }

        switch feedback {
        case .up:
            if let nextUpID = result.nextID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !nextUpID.isEmpty,
               nextUpID != anchorID,
               !hiddenIDs.contains(nextUpID),
               item(for: nextUpID) != nil,
               !snapshot.alreadySeenAssetIDs.contains(nextUpID) {
                recommendedAssetID = nextUpID
                pushRecommendedAsset(nextUpID)
                appendToHistoryIfNew(assetID: nextUpID)
                aiNextAssetIDs.insert(nextUpID)
            }
        case .down:
            break
        }

	#if DEBUG
	        if feedback == .up, settings.autofillOnThumbUp {
	            let desired = max(0, settings.thumbUpAutofillCount)
	            if desired > 0 {
	                let neighborIDs = result.neighbors
	                    .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
	                    .filter { !$0.isEmpty && $0 != anchorID && !hiddenIDs.contains($0) }
	                if !neighborIDs.isEmpty {
	                    thumbUpAutofillNeighborIDsByAnchorID[anchorID] = Array(neighborIDs.prefix(desired))
	                    maybeAutofillThumbUpNeighbors(anchorID: anchorID)
	                }
	            }
	        }
	#endif

        tuningDeltaRequest = AlbumTuningDeltaRequest(deltas: computeTuningDeltas(feedback: feedback, anchorID: anchorID, neighbors: result.neighbors))
    }

    private func restoreCachedRecommendsIfAvailable(for assetID: String) {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard let cached = recommendsCacheByAnchorID[id] else { return }

        recommendAnchorID = id

        recommendItems = cached.neighbors.compactMap { item(for: $0.id) }
            .filter { $0.id != id && !hiddenIDs.contains($0.id) }
        neighborsReady = !recommendItems.isEmpty
    }

    private func computeTuningDeltas(feedback: AlbumThumbFeedback, anchorID: String, neighbors: [AlbumRecNeighbor]) -> [AlbumItemTuningDelta] {
        let trimmedAnchor = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxNeighbors = 20
        let similarityExponent: Float = 1.0

        let massGain: Float = ThumbTuning.upMassGain
        let massLoss: Float = ThumbTuning.downMassLoss
        let accelGain: Float = ThumbTuning.downAccelGain

        var deltas: [AlbumItemTuningDelta] = []
        deltas.reserveCapacity(min(neighbors.count, maxNeighbors))

        var used = Set<String>()
        used.reserveCapacity(min(neighbors.count, maxNeighbors) + 1)
        used.insert(trimmedAnchor)

        for neighbor in neighbors.prefix(maxNeighbors) {
            let rawID = neighbor.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = rawID
            guard !id.isEmpty else { continue }
            if id == trimmedAnchor { continue }
            if hiddenIDs.contains(id) { continue }
            guard used.insert(id).inserted else { continue }

            let rank = max(1, deltas.count + 1)
            let rankWeight = 1.0 / Float(rank)
            let w = pow(rankWeight, similarityExponent)

            let massMul: Float
            let accelMul: Float

            switch feedback {
            case .up:
                massMul = 1.0 + massGain * w
                accelMul = 1.0
            case .down:
                massMul = 1.0 / (1.0 + massLoss * w)
                accelMul = 1.0 + accelGain * w
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
            memoryFacesIndexTask?.cancel()
            memoryFacesIndexTask = nil
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
            memoryFacesIndexTask?.cancel()
            memoryFacesIndexTask = nil
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
            memoryFacesIndexTask?.cancel()
            memoryFacesIndexTask = nil
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
            memoryFacesIndexTask?.cancel()
            memoryFacesIndexTask = nil
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
            memoryFacesIndexTask?.cancel()
            memoryFacesIndexTask = nil
            return
        }

        let total = index.idsByCreationDateAscending.count
        guard total > 0 else {
            memoryWindowItems = []
            memoryLabel = ""
            memoryPrevEnabled = false
            memoryNextEnabled = false
            memoryFacesIndexTask?.cancel()
            memoryFacesIndexTask = nil
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
            let ids = curvedWallMemoriesAllAssetIDs
            if let anchorID = memoryAnchorID?.trimmingCharacters(in: .whitespacesAndNewlines),
               let idx = ids.firstIndex(of: anchorID) {
                let starts = curvedWallPageStartIndices(for: ids)
                curvedWallPageWindows[placementID] = curvedWallPageIndex(for: idx, pageStarts: starts)
            } else {
                curvedWallPageWindows[placementID] = 0
            }
        }

        kickoffFacesIndexingForMemoryWindow(assetIDs: memoryWindowItems.map(\.id), source: .photos)
    }

    private func kickoffFacesIndexingForMemoryWindow(assetIDs rawAssetIDs: [String], source: AlbumSidecarSource) {
        guard datasetSource == .photos else { return }

        let assetIDs = rawAssetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !hiddenIDs.contains($0) }

        guard !assetIDs.isEmpty else { return }

        memoryFacesIndexTask?.cancel()

        let sidecarStore = self.sidecarStore
        let assetProvider = self.assetProvider
        let faceEngine = self.faceEngine

        memoryFacesIndexTask = Task(priority: .utility) {
            for assetID in assetIDs {
                if Task.isCancelled { break }

                let key = AlbumSidecarKey(source: source, id: assetID)
                if let record = await sidecarStore.load(key) {
                    if record.faces.state == .computed || record.faces.state == .failed {
                        continue
                    }
                }

                let data = await assetProvider.requestVisionThumbnailData(localIdentifier: assetID, maxDimension: 768)
                guard let data else { continue }
                _ = await faceEngine.ensureFacesComputed(assetID: assetID, thumbnailData: data, source: source)
            }
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

            if record.preferenceScore != 0 {
                preferenceScoreByAssetID[id] = record.preferenceScore
            } else {
                preferenceScoreByAssetID[id] = nil
            }

            if let summary = record.vision.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                if visionStateByAssetID[id] == .computed, record.vision.state != .computed {
                    continue
                }
                visionSummaryByAssetID[id] = summary
            }
            if record.vision.state != .none {
                if visionStateByAssetID[id] == .computed, record.vision.state != .computed {
                    continue
                }
                visionStateByAssetID[id] = record.vision.state
            }
            if let conf = record.vision.confidence {
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

private struct AlbumVisionLabel: Sendable, Hashable {
    let text: String
    let confidence: Float
}

private actor AlbumMovieVisionLabeler {
    static let shared = AlbumMovieVisionLabeler()

    private var cache: [String: [AlbumVisionLabel]] = [:]

    func cachedImageLabels(assetID: String) -> [AlbumVisionLabel]? {
        cache[imageKey(assetID)]
    }

    func cachedVideoLabels(assetID: String, bucket: Int) -> [AlbumVisionLabel]? {
        cache[videoKey(assetID, bucket: bucket)]
    }

    func classifyImage(assetID: String, imageData: Data, maxDimension: Int) -> [AlbumVisionLabel] {
        let key = imageKey(assetID)
        if let cached = cache[key] { return cached }

        guard let cgImage = downsampleCGImage(data: imageData, maxDimension: max(64, maxDimension)) else {
            cache[key] = []
            return []
        }

        let labels = classify(cgImage: cgImage)
        cache[key] = labels
        return labels
    }

    func classifyVideo(assetID: String, url: URL, sampleTime: Double, bucket: Int) async -> [AlbumVisionLabel] {
        let key = videoKey(assetID, bucket: bucket)
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 768, height: 768)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: max(0, sampleTime), preferredTimescale: 600)

        let frame: CGImage? = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                continuation.resume(returning: cgImage)
            }
        }

        guard let frame else {
            cache[key] = []
            return []
        }

        let labels = classify(cgImage: frame)
        cache[key] = labels
        return labels
    }

    private func imageKey(_ assetID: String) -> String {
        "img:\(assetID)"
    }

    private func videoKey(_ assetID: String, bucket: Int) -> String {
        "vid:\(assetID):\(bucket)"
    }

    private func classify(cgImage: CGImage) -> [AlbumVisionLabel] {
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([classify])
        } catch {
            return []
        }

        let results = classify.results ?? []
        guard !results.isEmpty else { return [] }

        let minConfidence: Float = 0.20
        var labels: [AlbumVisionLabel] = []
        labels.reserveCapacity(8)

        var seen: Set<String> = []
        seen.reserveCapacity(12)

        for obs in results.sorted(by: { $0.confidence > $1.confidence }) {
            guard obs.confidence >= minConfidence else { continue }
            let cleaned = cleanLabel(obs.identifier)
            guard !cleaned.isEmpty else { continue }
            guard seen.insert(cleaned).inserted else { continue }
            labels.append(AlbumVisionLabel(text: cleaned, confidence: obs.confidence))
            if labels.count >= 8 { break }
        }

        return labels
    }

    private func cleanLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    private func downsampleCGImage(data: Data, maxDimension: Int) -> CGImage? {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private enum AlbumMovieExportSegment {
    case image(instanceID: UUID, assetID: String, cgImage: CGImage, startAnchor: CGPoint, endAnchor: CGPoint)
    case video(instanceID: UUID, assetID: String, url: URL, trimStart: Double, trimEnd: Double, cropAnchor: CGPoint)
}

private struct AlbumMovieExportRequest {
    let title: String
    let subtitle: String?
    let segments: [AlbumMovieExportSegment]
}

private struct AlbumMovieExportResult {
    let relativePath: String
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let createdAt: Date
}

private enum AlbumMovieExportPipeline {
    private static let renderSize = CGSize(width: 1080, height: 1080)
    private static let fps: Int32 = 30
    private static let stillDurationSeconds: Double = 5.0
    private static let titleCardDurationSeconds: Double = 2.0

    private enum ExportError: Error, LocalizedError {
        case exportSessionUnavailable
        case unsupportedOutputType
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .exportSessionUnavailable:
                return "Movie export session unavailable"
            case .unsupportedOutputType:
                return "Movie export does not support mp4 output"
            case .failed(let message):
                return message
            }
        }
    }

    static func export(
        request: AlbumMovieExportRequest,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        status: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AlbumMovieExportResult {
        await status("Analyzing media…")
        await progress(0.02)

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ExportError.failed("Application Support directory unavailable")
        }

        let moviesDir = appSupport.appendingPathComponent("Movies", isDirectory: true)
        try fm.createDirectory(at: moviesDir, withIntermediateDirectories: true)

        let createdAt = Date()

        let safeBase = sanitizeFileBase(request.title)
        let finalURL = uniqueOutputURL(in: moviesDir, baseName: safeBase, ext: "mp4")
        let relativePath = "Movies/\(finalURL.lastPathComponent)"

        let tempDir = fm.temporaryDirectory.appendingPathComponent("album_movie_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        await status("Rendering title card…")
        await progress(0.06)

        let titleCardImage = makeTitleCardImage(title: request.title, subtitle: request.subtitle)
        let titleCardURL = tempDir.appendingPathComponent("title_card.mp4", isDirectory: false)
        try await renderImageClip(
            cgImage: titleCardImage,
            to: titleCardURL,
            durationSeconds: titleCardDurationSeconds,
            fps: fps,
            startAnchor: CGPoint(x: 0.5, y: 0.5),
            endAnchor: CGPoint(x: 0.5, y: 0.5),
            startZoom: 1.0,
            endZoom: 1.0
        )

        var renderedImageClipURLByID: [UUID: URL] = [:]
        renderedImageClipURLByID.reserveCapacity(request.segments.count)

        let images = request.segments.compactMap { seg -> (id: UUID, cgImage: CGImage, start: CGPoint, end: CGPoint)? in
            if case .image(let instanceID, _, let cgImage, let start, let end) = seg {
                return (id: instanceID, cgImage: cgImage, start: start, end: end)
            }
            return nil
        }

        if !images.isEmpty {
            await status("Rendering images (0/\(images.count))…")

            struct ImageRenderJob: Sendable {
                let index: Int
                let instanceID: UUID
                let cgImage: CGImage
                let startAnchor: CGPoint
                let endAnchor: CGPoint
            }

            let jobs: [ImageRenderJob] = images.enumerated().map { idx, image in
                ImageRenderJob(
                    index: idx,
                    instanceID: image.id,
                    cgImage: image.cgImage,
                    startAnchor: image.start,
                    endAnchor: image.end
                )
            }

            let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let maxConcurrency = min(8, jobs.count, max(1, cpuCount / 2))
            var nextJobIndex = 0
            var completedCount = 0

            try await withThrowingTaskGroup(of: (UUID, URL).self) { group in
                func enqueue(_ job: ImageRenderJob) {
                    group.addTask {
                        let clipURL = tempDir.appendingPathComponent("img_\(job.index).mp4", isDirectory: false)
                        try await renderImageClip(
                            cgImage: job.cgImage,
                            to: clipURL,
                            durationSeconds: stillDurationSeconds,
                            fps: fps,
                            startAnchor: job.startAnchor,
                            endAnchor: job.endAnchor,
                            startZoom: 1.02,
                            endZoom: 1.06
                        )
                        return (job.instanceID, clipURL)
                    }
                }

                for _ in 0..<maxConcurrency {
                    guard nextJobIndex < jobs.count else { break }
                    enqueue(jobs[nextJobIndex])
                    nextJobIndex += 1
                }

                while let (instanceID, clipURL) = try await group.next() {
                    renderedImageClipURLByID[instanceID] = clipURL
                    completedCount += 1

                    await status("Rendering images (\(completedCount)/\(jobs.count))…")
                    let p = 0.08 + (0.52 * (Double(completedCount) / Double(max(1, jobs.count))))
                    await progress(p)

                    if nextJobIndex < jobs.count {
                        enqueue(jobs[nextJobIndex])
                        nextJobIndex += 1
                    }
                }
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        await status("Assembling timeline…")
        await progress(0.62)

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed("Failed to create composition video track")
        }

        let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        struct SegmentInfo {
            let startTime: CMTime
            let duration: CMTime
            let sourceTrack: AVAssetTrack
            let cropAnchor: CGPoint?
            let zoomStart: CGFloat?
            let zoomEnd: CGFloat?
        }

        var segmentInfos: [SegmentInfo] = []
        segmentInfos.reserveCapacity(request.segments.count + 1)

        var cursor = CMTime.zero

        func insertClipAsset(url: URL) async throws {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.failed("Clip missing video track")
            }
            let duration = (try? await asset.load(.duration)) ?? .zero
            let range = CMTimeRange(start: .zero, duration: duration)
            try compVideoTrack.insertTimeRange(range, of: track, at: cursor)
            segmentInfos.append(SegmentInfo(startTime: cursor, duration: range.duration, sourceTrack: track, cropAnchor: nil, zoomStart: nil, zoomEnd: nil))
            cursor = cursor + range.duration
        }

        try await insertClipAsset(url: titleCardURL)

        var nextVideoZoomIn = true
        for seg in request.segments {
            switch seg {
            case .image(let instanceID, _, _, _, _):
                guard let clipURL = renderedImageClipURLByID[instanceID] else { continue }
                try await insertClipAsset(url: clipURL)

            case .video(_, _, let url, let trimStart, let trimEnd, let cropAnchor):
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let assetDuration = ((try? await asset.load(.duration)) ?? .zero).seconds

                let startSeconds = min(max(0, trimStart), max(0, assetDuration))
                let endSeconds = min(max(startSeconds + 0.5, trimEnd), max(startSeconds + 0.5, assetDuration))
                let durationSeconds = max(0.5, endSeconds - startSeconds)

                let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
                let dur = CMTime(seconds: durationSeconds, preferredTimescale: 600)
                let range = CMTimeRange(start: start, duration: dur)

                try compVideoTrack.insertTimeRange(range, of: track, at: cursor)

                if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
                   let sourceAudio = audioTracks.first,
                   let compAudioTrack {
                    try? compAudioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                }

                let zoomStart: CGFloat = nextVideoZoomIn ? 1.0 : 1.1
                let zoomEnd: CGFloat = nextVideoZoomIn ? 1.1 : 1.0
                nextVideoZoomIn.toggle()

                segmentInfos.append(SegmentInfo(
                    startTime: cursor,
                    duration: range.duration,
                    sourceTrack: track,
                    cropAnchor: cropAnchor,
                    zoomStart: zoomStart,
                    zoomEnd: zoomEnd
                ))
                cursor = cursor + range.duration
            }
        }

        let totalDuration = cursor

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)

        for info in segmentInfos {
            let baseTransform = aspectFillTransform(for: info.sourceTrack, renderSize: renderSize, cropAnchor: info.cropAnchor)
            if let zoomStart = info.zoomStart, let zoomEnd = info.zoomEnd {
                let startTransform = zoomTransform(baseTransform, scale: zoomStart, renderSize: renderSize)
                let endTransform = zoomTransform(baseTransform, scale: zoomEnd, renderSize: renderSize)
                let range = CMTimeRange(start: info.startTime, duration: info.duration)
                layerInstruction.setTransformRamp(fromStart: startTransform, toEnd: endTransform, timeRange: range)
            } else {
                layerInstruction.setTransform(baseTransform, at: info.startTime)
            }
        }

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        await status("Encoding mp4…")
        await progress(0.68)

        let tempOutURL = tempDir.appendingPathComponent("movie.mp4", isDirectory: false)
        if fm.fileExists(atPath: tempOutURL.path) {
            try? fm.removeItem(at: tempOutURL)
        }

        func containsOSStatus(_ error: NSError, code: Int) -> Bool {
            if error.domain == NSOSStatusErrorDomain, error.code == code { return true }
            if error.code == code { return true }

            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, containsOSStatus(underlying, code: code) {
                return true
            }

            if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                for entry in multiple where containsOSStatus(entry, code: code) { return true }
            }

            return false
        }

        func isPresetNotCompatible(_ error: Error) -> Bool {
            let nsError = error as NSError
            if containsOSStatus(nsError, code: -16_976) { return true }
            let message = String(describing: error).lowercased()
            return message.contains("preset") && message.contains("compat")
        }

        func runExport(attempt: Int) async throws {
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.exportSessionUnavailable
            }
            guard exportSession.supportedFileTypes.contains(.mp4) else {
                throw ExportError.unsupportedOutputType
            }

            if fm.fileExists(atPath: tempOutURL.path) {
                try? fm.removeItem(at: tempOutURL)
            }

            exportSession.outputURL = tempOutURL
            exportSession.outputFileType = .mp4
            exportSession.videoComposition = videoComposition
            exportSession.shouldOptimizeForNetworkUse = true

            let pollTask = Task {
                while exportSession.status == .exporting || exportSession.status == .waiting {
                    let p = Double(exportSession.progress)
                    await progress(0.68 + (0.30 * max(0, min(1, p))))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { pollTask.cancel() }

            do {
                try await export(exportSession)
            } catch {
                let sessionError = exportSession.error ?? error
                AlbumLog.model.error("Movie export failed attempt=\(attempt, privacy: .public) error=\(String(describing: sessionError), privacy: .public)")
                throw sessionError
            }
        }

        let exportBackoffNanos: [UInt64] = [
            0,
            450_000_000,
            1_200_000_000,
        ]

        func exportViaReaderWriter() async throws {
            if fm.fileExists(atPath: tempOutURL.path) {
                try? fm.removeItem(at: tempOutURL)
            }

            let reader = try AVAssetReader(asset: composition)

            let readerVideoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [compVideoTrack],
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                ]
            )
            readerVideoOutput.videoComposition = videoComposition

            guard reader.canAdd(readerVideoOutput) else {
                throw ExportError.failed("Movie export fallback: cannot read video track")
            }
            reader.add(readerVideoOutput)

            let shouldIncludeAudio: Bool = {
                guard let compAudioTrack else { return false }
                return !compAudioTrack.segments.isEmpty
            }()

            var readerAudioOutput: AVAssetReaderTrackOutput? = nil
            if shouldIncludeAudio, let compAudioTrack {
                let audioOutput = AVAssetReaderTrackOutput(
                    track: compAudioTrack,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ]
                )
                if reader.canAdd(audioOutput) {
                    reader.add(audioOutput)
                    readerAudioOutput = audioOutput
                }
            }

            let writer = try AVAssetWriter(outputURL: tempOutURL, fileType: .mp4)

            let writerVideoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(renderSize.width),
                    AVVideoHeightKey: Int(renderSize.height),
                ]
            )
            writerVideoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerVideoInput) else {
                throw ExportError.failed("Movie export fallback: cannot write video track")
            }
            writer.add(writerVideoInput)

            var writerAudioInput: AVAssetWriterInput? = nil
            if let readerAudioOutput {
                var sampleRate: Double = 44_100
                var channelCount: Int = 2

                if let compAudioTrack,
                   let rawDescs = try? await compAudioTrack.load(.formatDescriptions) {
                    for entry in rawDescs {
                        if let desc = entry as? CMAudioFormatDescription,
                           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                            let sr = asbd.pointee.mSampleRate
                            let ch = Int(asbd.pointee.mChannelsPerFrame)
                            if sr.isFinite, sr > 0 { sampleRate = sr }
                            if ch > 0 { channelCount = ch }
                            break
                        }
                    }
                }

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                    AVEncoderBitRateKey: 192_000,
                ]

                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    writerAudioInput = input
                } else {
                    AlbumLog.model.error("Movie export fallback: cannot add audio input; exporting silent audio track")
                }
            }

            let durationSeconds = max(0.000_001, totalDuration.seconds)

            let errorLock = NSLock()
            var firstError: Error? = nil

            func recordError(_ error: Error) {
                errorLock.lock()
                if firstError == nil {
                    firstError = error
                    reader.cancelReading()
                    writer.cancelWriting()
                }
                errorLock.unlock()
            }

            func currentError() -> Error? {
                errorLock.lock()
                defer { errorLock.unlock() }
                return firstError
            }

            let progressLock = NSLock()
            var lastProgressSeconds: Double = 0

            func maybeReportProgress(_ seconds: Double) {
                guard seconds.isFinite else { return }
                let clamped = max(0, min(durationSeconds, seconds))

                progressLock.lock()
                let delta = clamped - lastProgressSeconds
                if delta < 0.35 {
                    progressLock.unlock()
                    return
                }
                lastProgressSeconds = clamped
                progressLock.unlock()

                let fraction = max(0, min(1, clamped / durationSeconds))
                Task { await progress(0.68 + (0.30 * fraction)) }
            }

            guard reader.startReading() else {
                throw reader.error ?? ExportError.failed("Movie export fallback: reader failed to start")
            }
            guard writer.startWriting() else {
                throw writer.error ?? ExportError.failed("Movie export fallback: writer failed to start")
            }
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()

            group.enter()
            let videoQueue = DispatchQueue(label: "album.movie.exportFallback.video")
            var videoDone = false
            writerVideoInput.requestMediaDataWhenReady(on: videoQueue) {
                while writerVideoInput.isReadyForMoreMediaData {
                    if videoDone { return }

                    if currentError() != nil {
                        videoDone = true
                        writerVideoInput.markAsFinished()
                        group.leave()
                        return
                    }

                    if reader.status == .failed {
                        recordError(reader.error ?? ExportError.failed("Movie export fallback: reader failed"))
                        videoDone = true
                        writerVideoInput.markAsFinished()
                        group.leave()
                        return
                    }

                    guard let sample = readerVideoOutput.copyNextSampleBuffer() else {
                        videoDone = true
                        writerVideoInput.markAsFinished()
                        group.leave()
                        return
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if pts.isNumeric {
                        maybeReportProgress(pts.seconds)
                    }

                    if !writerVideoInput.append(sample) {
                        recordError(writer.error ?? ExportError.failed("Movie export fallback: failed to append video samples"))
                        videoDone = true
                        writerVideoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let readerAudioOutput, let writerAudioInput {
                group.enter()
                let audioQueue = DispatchQueue(label: "album.movie.exportFallback.audio")
                var audioDone = false
                writerAudioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while writerAudioInput.isReadyForMoreMediaData {
                        if audioDone { return }

                        if currentError() != nil {
                            audioDone = true
                            writerAudioInput.markAsFinished()
                            group.leave()
                            return
                        }

                        if reader.status == .failed {
                            recordError(reader.error ?? ExportError.failed("Movie export fallback: reader failed"))
                            audioDone = true
                            writerAudioInput.markAsFinished()
                            group.leave()
                            return
                        }

                        guard let sample = readerAudioOutput.copyNextSampleBuffer() else {
                            audioDone = true
                            writerAudioInput.markAsFinished()
                            group.leave()
                            return
                        }

                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        if pts.isNumeric {
                            maybeReportProgress(pts.seconds)
                        }

                        if !writerAudioInput.append(sample) {
                            recordError(writer.error ?? ExportError.failed("Movie export fallback: failed to append audio samples"))
                            audioDone = true
                            writerAudioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    if let error = currentError() {
                        continuation.resume(throwing: error)
                        return
                    }

                    writer.finishWriting {
                        if writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: writer.error ?? ExportError.failed("Movie export fallback: writer failed"))
                        }
                    }
                }
            }
        }

        var exportFailure: Error? = nil
        for attempt in 1...exportBackoffNanos.count {
            if attempt > 1 {
                await status("Encoder reset…")
                try? await Task.sleep(nanoseconds: exportBackoffNanos[attempt - 1])
            }

            do {
                try await runExport(attempt: attempt)
                exportFailure = nil
                break
            } catch {
                exportFailure = error
                if !isPresetNotCompatible(error) {
                    throw error
                }
            }
        }

        if let exportFailure {
            AlbumLog.model.error("Movie export session repeatedly failed; falling back to reader/writer. error=\(String(describing: exportFailure), privacy: .public)")
            await status("Encoding mp4 (fallback)…")
            try await exportViaReaderWriter()
        }

        await progress(0.98)

        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: tempOutURL, to: finalURL)

        let exportedAsset = AVURLAsset(url: finalURL)
        let exportedAudioTracks = (try? await exportedAsset.loadTracks(withMediaType: .audio)) ?? []
        if !exportedAudioTracks.isEmpty {
            await status("Normalizing audio…")
            let fixedURL = tempDir.appendingPathComponent("movie_audio_fixed.mp4", isDirectory: false)

            let audioProgress: @MainActor @Sendable (Double) -> Void = { fraction in
                progress(0.98 + (0.01 * max(0, min(1, fraction))))
            }

            do {
                let normalizedURL = try await normalizeAudioForSocialIfNeeded(
                    inputURL: finalURL,
                    outputURL: fixedURL,
                    progress: audioProgress
                )

                if normalizedURL != finalURL {
                    do {
                        _ = try fm.replaceItemAt(finalURL, withItemAt: normalizedURL)
                    } catch {
                        AlbumLog.model.error("Movie audio replace failed: \(String(describing: error), privacy: .public)")
                        let details = String(describing: error).replacingOccurrences(of: "\n", with: " ")
                        await status("Audio normalize replace failed; keeping original audio. (\(details))")
                    }
                }
            } catch {
                AlbumLog.model.error("Movie audio normalization failed: \(String(describing: error), privacy: .public)")
                let details = String(describing: error).replacingOccurrences(of: "\n", with: " ")
                await status("Audio normalization failed; keeping original audio. (\(details))")
            }
        }

        await progress(0.99)

        let fileSizeBytes: Int64 = {
            let attrs = (try? fm.attributesOfItem(atPath: finalURL.path)) ?? [:]
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }()

        let durationSeconds: Double = {
            let asset = AVURLAsset(url: finalURL)
            return asset.duration.seconds
        }()

        await progress(1.0)
        return AlbumMovieExportResult(
            relativePath: relativePath,
            durationSeconds: max(0, durationSeconds),
            fileSizeBytes: fileSizeBytes,
            createdAt: createdAt
        )
    }

    private static func export(_ session: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: session.error ?? ExportError.failed("Movie export failed"))
                case .cancelled:
                    continuation.resume(throwing: ExportError.failed("Movie export cancelled"))
                default:
                    continuation.resume(throwing: session.error ?? ExportError.failed("Movie export failed"))
                }
            }
        }
    }

    private static func normalizeAudioForSocialIfNeeded(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.failed("Audio normalize: missing video track")
        }

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return inputURL
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }

        let totalSeconds = max(0.000_001, ((try? await asset.load(.duration)) ?? asset.duration).seconds)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.failed("Audio normalize: cannot read video track")
        }
        reader.add(videoOutput)

        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: 8_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]

        let videoInputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: videoCompression,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.failed("Audio normalize: cannot write video track")
        }
        writer.add(videoInput)

        let targetSampleRate: Double = 48_000
        let targetChannels: Int = 2

        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioOutputSettings)
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw ExportError.failed("Audio normalize: cannot decode audio track")
        }
        reader.add(audioOutput)

        let audioInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVEncoderBitRateKey: 192_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioInputSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw ExportError.failed("Audio normalize: cannot encode audio track")
        }
        writer.add(audioInput)

        guard reader.startReading() else {
            throw reader.error ?? ExportError.failed("Audio normalize: reader failed to start")
        }
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.failed("Audio normalize: writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        await progress(0)

        let progressLock = NSLock()
        var lastProgressWallTime = CFAbsoluteTimeGetCurrent()
        var lastProgressSeconds: Double = 0

        func maybeReportProgress(presentationSeconds: Double) {
            guard presentationSeconds.isFinite else { return }

            let now = CFAbsoluteTimeGetCurrent()

            progressLock.lock()
            let shouldReport = (now - lastProgressWallTime) >= 0.2
                || (presentationSeconds - lastProgressSeconds) >= 1.0
                || presentationSeconds >= totalSeconds
            if shouldReport {
                lastProgressWallTime = now
                lastProgressSeconds = presentationSeconds
            }
            progressLock.unlock()

            guard shouldReport else { return }
            let fraction = max(0, min(1, presentationSeconds / totalSeconds))
            Task { await progress(fraction) }
        }

        let errorLock = NSLock()
        var firstError: Error? = nil
        func recordError(_ error: Error) {
            errorLock.lock()
            if firstError == nil {
                firstError = error
            }
            errorLock.unlock()
        }
        func currentError() -> Error? {
            errorLock.lock()
            defer { errorLock.unlock() }
            return firstError
        }

        let group = DispatchGroup()

        group.enter()
        let videoQueue = DispatchQueue(label: "album.movie.audioNormalize.video")
        var videoDone = false
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if videoDone { return }

                if currentError() != nil {
                    videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }

                if reader.status == .failed {
                    recordError(reader.error ?? ExportError.failed("Audio normalize: reader failed"))
                    videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }

                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isNumeric {
                    maybeReportProgress(presentationSeconds: pts.seconds)
                }

                if !videoInput.append(sample) {
                    recordError(writer.error ?? ExportError.failed("Audio normalize: failed to append video samples"))
                    videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        group.enter()
        let audioQueue = DispatchQueue(label: "album.movie.audioNormalize.audio")
        var audioDone = false
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if audioDone { return }

                if currentError() != nil {
                    audioDone = true
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }

                if reader.status == .failed {
                    recordError(reader.error ?? ExportError.failed("Audio normalize: reader failed"))
                    audioDone = true
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }

                guard let sample = audioOutput.copyNextSampleBuffer() else {
                    audioDone = true
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isNumeric {
                    maybeReportProgress(presentationSeconds: pts.seconds)
                }

                if !audioInput.append(sample) {
                    recordError(writer.error ?? ExportError.failed("Audio normalize: failed to append audio samples"))
                    audioDone = true
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                if let error = currentError() {
                    reader.cancelReading()
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                    return
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writer.error ?? ExportError.failed("Audio normalize: writer failed"))
                    }
                }
            }
        }

        await progress(1)
        return outputURL
    }

    private static func renderImageClip(
        cgImage: CGImage,
        to url: URL,
        durationSeconds: Double,
        fps: Int32,
        startAnchor: CGPoint,
        endAnchor: CGPoint,
        startZoom: Double,
        endZoom: Double
    ) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else {
            throw ExportError.failed("Movie clip writer cannot add input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? ExportError.failed("Movie clip writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int((durationSeconds * Double(fps)).rounded(.up)))
        let w = Double(cgImage.width)
        let h = Double(cgImage.height)

        let baseScale = max(Double(renderSize.width) / w, Double(renderSize.height) / h)
        let baseCropSize = Double(renderSize.width) / max(0.000_001, baseScale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

        for frameIndex in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.failed("Pixel buffer pool unavailable")
            }

            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
                throw ExportError.failed("Failed to allocate pixel buffer")
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            let t = totalFrames <= 1 ? CGFloat(0) : CGFloat(frameIndex) / CGFloat(totalFrames - 1)
            let anchor = CGPoint(
                x: lerp(startAnchor.x, endAnchor.x, t),
                y: lerp(startAnchor.y, endAnchor.y, t)
            )
            let zoom = Double(lerp(CGFloat(startZoom), CGFloat(endZoom), t))
            let cropSize = baseCropSize / max(0.000_001, zoom)

            var cx = Double(anchor.x) * w
            var cy = Double(anchor.y) * h
            cx = min(max(cx, cropSize / 2), max(cropSize / 2, w - cropSize / 2))
            cy = min(max(cy, cropSize / 2), max(cropSize / 2, h - cropSize / 2))

            var originX = cx - (cropSize / 2)
            var originY = cy - (cropSize / 2)
            originX = min(max(0, originX), max(0, w - cropSize))
            originY = min(max(0, originY), max(0, h - cropSize))

            let scale = Double(renderSize.width) / max(0.000_001, cropSize)
            let originYBottom = (h - cropSize) - originY
            let drawRect = CGRect(
                x: -originX * scale,
                y: -originYBottom * scale,
                width: w * scale,
                height: h * scale
            )

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw ExportError.failed("Pixel buffer base address unavailable")
            }

            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(
                data: baseAddress,
                width: Int(renderSize.width),
                height: Int(renderSize.height),
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                throw ExportError.failed("Failed to create pixel buffer context")
            }

            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: renderSize))

            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: drawRect)

            let presentationTime = CMTime(value: Int64(frameIndex), timescale: fps)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ExportError.failed("Failed to append frame")
            }
        }

        input.markAsFinished()

        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? ExportError.failed("Movie clip writer failed"))
                }
            }
        }
    }

    private static func aspectFillTransform(for track: AVAssetTrack, renderSize: CGSize, cropAnchor: CGPoint?) -> CGAffineTransform {
        let natural = track.naturalSize
        guard natural.width > 0, natural.height > 0 else { return .identity }

        let preferred = track.preferredTransform
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let orientedSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return .identity }

        let normalize = CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y)
        var transform = preferred.concatenating(normalize)

        let scale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)

        func allowedCropRect(source: CGSize, renderSize: CGSize, scale: CGFloat) -> CGRect {
            let w = Double(source.width)
            let h = Double(source.height)
            guard w > 0, h > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

            let s = Double(renderSize.width)
            let cropSizePx = s / max(0.000_001, Double(scale))
            let halfX = (cropSizePx / 2) / w
            let halfY = (cropSizePx / 2) / h

            let minX = min(max(halfX, 0), 0.5)
            let maxX = max(min(1 - halfX, 1), 0.5)
            let minY = min(max(halfY, 0), 0.5)
            let maxY = max(min(1 - halfY, 1), 0.5)

            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }

        func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
            CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY)
            )
        }

        let requestedAnchor = cropAnchor ?? CGPoint(x: 0.5, y: 0.5)
        let allowedNorm = allowedCropRect(source: orientedSize, renderSize: renderSize, scale: scale)
        let anchor = clamp(requestedAnchor, to: allowedNorm)

        let tx = (renderSize.width / 2) - (scaledSize.width * anchor.x)
        let ty = (renderSize.height / 2) - (scaledSize.height * anchor.y)
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
        return transform
    }

    private static func zoomTransform(_ transform: CGAffineTransform, scale: CGFloat, renderSize: CGSize) -> CGAffineTransform {
        let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
        var zoom = CGAffineTransform.identity
        zoom = zoom.translatedBy(x: center.x, y: center.y)
        zoom = zoom.scaledBy(x: scale, y: scale)
        zoom = zoom.translatedBy(x: -center.x, y: -center.y)
        return transform.concatenating(zoom)
    }

    private static func sanitizeFileBase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Movie" }

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let squashed = String(filtered)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let underscored = squashed.replacingOccurrences(of: " ", with: "_")
        if underscored.isEmpty { return "Movie" }
        return String(underscored.prefix(64))
    }

    private static func uniqueOutputURL(in dir: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let base = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Movie" : baseName
        var candidate = dir.appendingPathComponent("\(base).\(ext)", isDirectory: false)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        for n in 2...999 {
            let name = "\(base)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(name, isDirectory: false)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)", isDirectory: false)
    }

    private static func makeTitleCardImage(title: String, subtitle: String?) -> CGImage {
#if canImport(UIKit)
        let width = Int(renderSize.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let titleFont = UIFont.systemFont(ofSize: 72, weight: .semibold)
        let subtitleFont = UIFont.systemFont(ofSize: 34, weight: .regular)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]

        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.82),
            .paragraphStyle: paragraph,
        ]

        let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitleText = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let titleRect = CGRect(x: 80, y: 420, width: width - 160, height: 160)
        (safeTitle as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        if !subtitleText.isEmpty {
            let subtitleRect = CGRect(x: 120, y: 560, width: width - 240, height: 90)
            (subtitleText as NSString).draw(in: subtitleRect, withAttributes: subtitleAttrs)
        }
        }

        if let cg = image.cgImage { return cg }
#endif
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
