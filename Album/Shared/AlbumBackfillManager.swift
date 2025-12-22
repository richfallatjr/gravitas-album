import Foundation

#if canImport(Photos)
import Photos
#endif

public struct BackfillStatus: Sendable, Hashable {
    public var totalAssets: Int
    public var computed: Int
    public var autofilled: Int
    public var missing: Int
    public var failed: Int

    public var queued: Int
    public var inflight: Int
    public var running: Bool
    public var paused: Bool

    public var lastProcessedID: String?
    public var lastError: String?

    public init(
        totalAssets: Int = 0,
        computed: Int = 0,
        autofilled: Int = 0,
        missing: Int = 0,
        failed: Int = 0,
        queued: Int = 0,
        inflight: Int = 0,
        running: Bool = false,
        paused: Bool = false,
        lastProcessedID: String? = nil,
        lastError: String? = nil
    ) {
        self.totalAssets = max(0, totalAssets)
        self.computed = max(0, computed)
        self.autofilled = max(0, autofilled)
        self.missing = max(0, missing)
        self.failed = max(0, failed)
        self.queued = max(0, queued)
        self.inflight = max(0, inflight)
        self.running = running
        self.paused = paused
        self.lastProcessedID = lastProcessedID
        self.lastError = lastError
    }
}

private actor AlbumAsyncSignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

public struct AlbumBackfillVisionUpdate: Sendable, Hashable {
    public let assetID: String
    public let summary: String
    public let state: AlbumSidecarRecord.VisionFillState
    public let confidence: Float

    public init(assetID: String, summary: String, state: AlbumSidecarRecord.VisionFillState, confidence: Float) {
        self.assetID = assetID
        self.summary = summary
        self.state = state
        self.confidence = confidence
    }
}

public actor AlbumBackfillManager {
    public enum Priority: Int, Sendable, Codable, CaseIterable, Comparable {
        case interactive = 3   // selected asset / visible in curved layout
        case visible = 2       // in sim / on screen
        case background = 1    // seed + new assets scanning

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Job: Sendable, Hashable {
        var assetID: String
        var priority: Priority
        var notBefore: Date
        var reason: String
        var isSeed: Bool
        var enqueuedAt: Date
    }

    private struct LibraryScanState: Codable, Sendable, Hashable {
        var lastScanAt: Date
        var newestSeenCreationDate: Date?
        var newestSeenAssetID: String?

        init(lastScanAt: Date = Date(), newestSeenCreationDate: Date? = nil, newestSeenAssetID: String? = nil) {
            self.lastScanAt = lastScanAt
            self.newestSeenCreationDate = newestSeenCreationDate
            self.newestSeenAssetID = newestSeenAssetID
        }
    }

    private struct SeedPlanState: Codable, Sendable, Hashable {
        var seedIDs: [String]
        var targetCount: Int
        var createdAt: Date

        init(seedIDs: [String], targetCount: Int, createdAt: Date = Date()) {
            self.seedIDs = seedIDs
            self.targetCount = max(0, targetCount)
            self.createdAt = createdAt
        }
    }

    private let sidecarStore: AlbumSidecarStore
    private let libraryIndexStore: AlbumLibraryIndexStore
    private let assetProvider: any AlbumAssetProvider
    private let faceEngine: AlbumFaceEngine?

    private let seedPlanURL: URL
    private let libraryScanURL: URL
    private let legacyBackfillStateURL: URL

    private let workSignal = AlbumAsyncSignal()

    private var seedPlan: SeedPlanState?
    private var seedSet: Set<String> = []
    private var seedTargetCount: Int = 0
    private var seedComputedCount: Int = 0
    private var seedAutofilledCount: Int = 0
    private var seedFailedCount: Int = 0

    private var queueByID: [String: Job] = [:]
    private var inflightID: String? = nil
    private var workerTask: Task<Void, Never>?
    private var paused: Bool = false

    private var lastProcessedID: String?
    private var lastError: String?

    private var statusSink: (@MainActor (BackfillStatus) -> Void)?
    private var visionUpdateSink: (@MainActor (AlbumBackfillVisionUpdate) -> Void)?
    private var visionCompletionSink: (@MainActor (String) -> Void)?

    private let maxAttempts: Int = 5
    private let visionThumbnailMaxDimension: Int = 512
    private let scanBufferSeconds: TimeInterval = 48 * 60 * 60

    public init(
        sidecarStore: AlbumSidecarStore,
        libraryIndexStore: AlbumLibraryIndexStore,
        assetProvider: any AlbumAssetProvider,
        faceEngine: AlbumFaceEngine? = nil,
        seedPlanFileName: String = "album_seed_plan_v2.json",
        libraryScanFileName: String = "album_library_scan_state_v2.json",
        legacyBackfillStateFileName: String = "album_backfill_state_v1.json"
    ) {
        self.sidecarStore = sidecarStore
        self.libraryIndexStore = libraryIndexStore
        self.assetProvider = assetProvider
        self.faceEngine = faceEngine

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.seedPlanURL = appSupport.appendingPathComponent(seedPlanFileName, isDirectory: false)
        self.libraryScanURL = appSupport.appendingPathComponent(libraryScanFileName, isDirectory: false)
        self.legacyBackfillStateURL = appSupport.appendingPathComponent(legacyBackfillStateFileName, isDirectory: false)
    }

    public func setStatusSink(_ sink: (@MainActor (BackfillStatus) -> Void)?) {
        statusSink = sink
    }

    public func setVisionUpdateSink(_ sink: (@MainActor (AlbumBackfillVisionUpdate) -> Void)?) {
        visionUpdateSink = sink
    }

    public func setVisionCompletionSink(_ sink: (@MainActor (String) -> Void)?) {
        visionCompletionSink = sink
    }

    // MARK: Public API (v2)

    public func bootstrapOnLaunch() async {
        deleteLegacyBackfillStateIfPresent()

        guard await ensureLibraryIndexAvailable() != nil else {
            await publishStatus()
            return
        }

        await scanForNewAssetsOnLaunch()
        await ensureSeedPlanExistsIfPossible()
        await rebuildSeedQueueFromSidecars()
        startWorkerIfNeeded()
        await publishStatus()
    }

	    public func scanForNewAssetsOnLaunch() async {
	#if canImport(Photos)
	        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
	        guard status == .authorized || status == .limited else { return }

	        let previous = loadLibraryScanState() ?? LibraryScanState()

	        let options = PHFetchOptions()
	        options.sortDescriptors = [
	            NSSortDescriptor(key: "creationDate", ascending: false)
	        ]

	        let results = PHAsset.fetchAssets(with: options)
	        guard results.count > 0 else {
	            saveLibraryScanState(LibraryScanState(lastScanAt: Date(), newestSeenCreationDate: previous.newestSeenCreationDate, newestSeenAssetID: previous.newestSeenAssetID))
	            return
	        }

	        if previous.newestSeenCreationDate == nil {
	            // First run: establish a baseline so we don't enqueue the entire library as "new".
	            let probeCount = min(results.count, 25)
	            var newestDate: Date = Date()
	            var newestID: String? = nil

	            for idx in 0..<probeCount {
	                let asset = results.object(at: idx)
	                if let date = asset.creationDate {
	                    newestDate = date
	                    let id = asset.localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
	                    newestID = id.isEmpty ? nil : id
	                    break
	                }
	            }

	            if newestID == nil {
	                let asset = results.object(at: 0)
	                newestDate = asset.creationDate ?? Date()
	                let id = asset.localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
	                newestID = id.isEmpty ? nil : id
	            }

	            saveLibraryScanState(LibraryScanState(lastScanAt: Date(), newestSeenCreationDate: newestDate, newestSeenAssetID: newestID))
	            return
	        }

	        let cutoff = (previous.newestSeenCreationDate ?? .distantPast).addingTimeInterval(-scanBufferSeconds)

	        var newestDate: Date? = previous.newestSeenCreationDate
	        var newestID: String? = previous.newestSeenAssetID
	        var newIDs: [String] = []
	        newIDs.reserveCapacity(min(256, results.count))

        results.enumerateObjects { asset, _, stop in
            let date = asset.creationDate ?? .distantPast
            if date <= cutoff {
                stop.pointee = true
                return
            }

            let id = asset.localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            newIDs.append(id)

            if newestDate == nil || date > (newestDate ?? .distantPast) {
                newestDate = date
                newestID = id
            }
        }

        let now = Date()
        saveLibraryScanState(LibraryScanState(lastScanAt: now, newestSeenCreationDate: newestDate, newestSeenAssetID: newestID))

        guard !newIDs.isEmpty else { return }
        for id in newIDs {
            _ = await ensureVisionScheduled(
                for: id,
                priority: .background,
                reason: "launch_scan_new_asset",
                isSeed: false,
                notBefore: now,
                shouldPublishStatus: false
            )
        }

        await publishStatus()
#else
        return
#endif
    }

    public func ensureVision(for id: String, priority: Priority) async {
        _ = await ensureVisionScheduled(for: id, priority: priority, reason: "ensure", isSeed: false, notBefore: Date(), shouldPublishStatus: true)
    }

	    public func autofillNeighbors(anchorID: String, neighborIDs: [String], source: AlbumSidecarRecord.AutofillSource) async {
	        let anchor = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
	        guard !anchor.isEmpty else { return }
	        guard !neighborIDs.isEmpty else { return }

	        let anchorKey = AlbumSidecarKey(source: .photos, id: anchor)
	        guard let anchorRecord = await sidecarStore.load(anchorKey),
	              anchorRecord.vision.state == .computed,
	              let summary = anchorRecord.vision.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
	              !summary.isEmpty,
	              !AlbumVisionSummaryUtils.isPlaceholder(summary)
	        else { return }

	        let tags = anchorRecord.vision.tags
	        let confidence: Float = 0.30
	        let now = Date()

        for neighborIDRaw in neighborIDs {
            let neighborID = neighborIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !neighborID.isEmpty else { continue }
            guard neighborID != anchor else { continue }

	            let key = AlbumSidecarKey(source: .photos, id: neighborID)
	            let existingState = (await sidecarStore.load(key))?.vision.state ?? .none
	            guard existingState == .none || existingState == .autofilled else { continue }

	            await sidecarStore.setVisionAutofilledIfMissingOrAutofilled(
	                key,
	                summary: summary,
	                tags: tags,
	                confidence: confidence,
	                source: source,
	                derivedFromID: anchor
	            )

            await publishVisionUpdateIfAvailable(assetID: neighborID, summary: summary, state: .autofilled, confidence: confidence)
            applySeedVisionCountDelta(assetID: neighborID, from: existingState, to: .autofilled)

            _ = await ensureVisionScheduled(
                for: neighborID,
                priority: .background,
                reason: "thumb_up_autofill_neighbor",
                isSeed: false,
                notBefore: now,
                shouldPublishStatus: false
            )
        }

        await publishStatus()
    }

    public func pause() async {
        paused = true
        workerTask?.cancel()
        workerTask = nil
        await publishStatus()
    }

    public func resume() async {
        paused = false
        startWorkerIfNeeded()
        await workSignal.signal()
        await publishStatus()
    }

    public func restart() async {
        workerTask?.cancel()
        workerTask = nil
        inflightID = nil
        queueByID.removeAll(keepingCapacity: true)

        guard await ensureLibraryIndexAvailable() != nil else {
            await publishStatus()
            return
        }

        await scanForNewAssetsOnLaunch()
        await ensureSeedPlanExistsIfPossible()
        await rebuildSeedQueueFromSidecars()
        startWorkerIfNeeded()
        await publishStatus()
    }

	    public func retryFailed() async {
	        guard let plan = seedPlan, !plan.seedIDs.isEmpty else { return }

        let now = Date()

        for idRaw in plan.seedIDs {
            let id = idRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }

            let key = AlbumSidecarKey(source: .photos, id: id)
            if let record = await sidecarStore.load(key),
               record.vision.state == .failed {
                await sidecarStore.resetVisionFailures(key)
                _ = await ensureVisionScheduled(for: id, priority: .background, reason: "retry_failed", isSeed: true, notBefore: now, shouldPublishStatus: false)
            }
        }

	        await publishStatus()
	    }

	    public func applySeedTimelineAutofillPass() async {
	        guard await ensureLibraryIndexAvailable() != nil else { return }
	        await ensureSeedPlanExistsIfPossible()
	        guard let plan = seedPlan, !plan.seedIDs.isEmpty else { return }

	        for idRaw in plan.seedIDs {
	            let id = idRaw.trimmingCharacters(in: .whitespacesAndNewlines)
	            guard !id.isEmpty else { continue }

	            let key = AlbumSidecarKey(source: .photos, id: id)
	            guard let record = await sidecarStore.load(key),
	                  AlbumVisionSummaryUtils.isMeaningfulComputed(record),
	                  let summary = record.vision.summary
	            else { continue }

	            await autofillSeedTimelineNeighborsIfEnabled(anchorID: id, summary: summary, tags: record.vision.tags ?? [])
	        }

	        await publishStatus()
	    }

	    // MARK: Internals

    @discardableResult
    private func ensureVisionScheduled(
        for assetID: String,
        priority: Priority,
        reason: String,
        isSeed: Bool,
        notBefore: Date,
        shouldPublishStatus: Bool
    ) async -> Bool {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }

        let key = AlbumSidecarKey(source: .photos, id: id)
        let record = await sidecarStore.load(key)
        if let record,
           record.vision.state == .computed,
           !AlbumVisionSummaryUtils.isPlaceholder(record.vision.summary) {
            let facesNeeded = (faceEngine != nil && record.faces.state == .none)
            if !facesNeeded {
                await publishVisionCompletionIfAvailable(assetID: id)
                return false
            }
        }

        var effectiveNotBefore: Date = notBefore
        if let record, record.vision.state == .failed {
            let attempts = max(0, record.vision.attemptCount ?? 0)
            if attempts >= maxAttempts {
                effectiveNotBefore = .distantFuture
            } else if let lastAttempt = record.vision.lastAttemptAt {
                effectiveNotBefore = max(notBefore, lastAttempt.addingTimeInterval(Self.backoffSeconds(forAttempt: attempts)))
            }
        }

        guard effectiveNotBefore != .distantFuture else {
            await publishVisionCompletionIfAvailable(assetID: id)
            return false
        }

        let now = Date()
        let existing = queueByID[id]
        let merged = Job(
            assetID: id,
            priority: max(priority, existing?.priority ?? .background),
            notBefore: max(effectiveNotBefore, existing?.notBefore ?? .distantPast),
            reason: reason,
            isSeed: isSeed || (existing?.isSeed ?? false),
            enqueuedAt: existing?.enqueuedAt ?? now
        )

        queueByID[id] = merged
        startWorkerIfNeeded()
        await workSignal.signal()
        if shouldPublishStatus {
            await publishStatus()
        }
        return true
    }

    private func startWorkerIfNeeded() {
        guard !paused else { return }
        guard workerTask == nil else { return }

        workerTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.workerLoop()
        }
    }

    private func workerLoop() async {
        while !Task.isCancelled {
            if paused {
                await waitForWorkOrNextReadyTime()
                continue
            }

            let now = Date()
            guard let next = pickNextReadyJob(now: now) else {
                await waitForWorkOrNextReadyTime()
                continue
            }

            queueByID[next.assetID] = nil
            inflightID = next.assetID
            await publishStatus()

            await process(job: next)

            inflightID = nil
            await publishStatus()
        }
    }

    private func pickNextReadyJob(now: Date) -> Job? {
        var best: Job?

        for job in queueByID.values {
            guard job.notBefore <= now else { continue }
            if let currentBest = best {
                if job.priority != currentBest.priority {
                    if job.priority > currentBest.priority {
                        best = job
                    }
                    continue
                }

                if job.enqueuedAt < currentBest.enqueuedAt {
                    best = job
                }
            } else {
                best = job
            }
        }

        return best
    }

    private func waitForWorkOrNextReadyTime() async {
        let now = Date()
        let earliestNotBefore = queueByID.values.map(\.notBefore).min()

        let ns: UInt64? = {
            guard let earliestNotBefore else { return nil }
            let delta = max(0, earliestNotBefore.timeIntervalSince(now))
            let capped = min(delta, 30)
            return UInt64(capped * 1_000_000_000)
        }()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [workSignal] in
                await workSignal.wait()
            }
            if let ns {
                group.addTask {
                    try? await Task.sleep(nanoseconds: ns)
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func process(job: Job) async {
        let id = job.assetID
        let key = AlbumSidecarKey(source: .photos, id: id)

        let beforeRecord = await sidecarStore.load(key)
        let rawState = beforeRecord?.vision.state ?? .none
        let beforeStateForCounts = Self.seedCountedState(state: rawState, summary: beforeRecord?.vision.summary)

        let visionAlreadyComputed = (rawState == .computed && !AlbumVisionSummaryUtils.isPlaceholder(beforeRecord?.vision.summary))
        let facesState = beforeRecord?.faces.state ?? .none
        let shouldComputeFaces = (faceEngine != nil && facesState != .computed && facesState != .failed)
        let shouldComputeVision = !visionAlreadyComputed

        if !shouldComputeVision && !shouldComputeFaces {
            lastProcessedID = id
            await publishVisionCompletionIfAvailable(assetID: id)
            return
        }

        let now = Date()
        guard let data = await assetProvider.requestVisionThumbnailData(localIdentifier: id, maxDimension: visionThumbnailMaxDimension) else {
            if shouldComputeVision {
                await handleFailure(assetID: id, key: key, beforeState: beforeStateForCounts, error: "vision_thumbnail_data_missing", attemptedAt: now, retryPriority: job.priority, isSeed: job.isSeed)
            } else if shouldComputeFaces {
                await sidecarStore.setFacesFailed(key, error: "face_thumbnail_data_missing", attemptedAt: now)
                lastProcessedID = id
                await publishVisionCompletionIfAvailable(assetID: id)
            }
            return
        }

        if shouldComputeFaces, let faceEngine {
            _ = await faceEngine.ensureFacesComputed(assetID: id, thumbnailData: data, source: .photos)
        }

        if !shouldComputeVision {
            lastProcessedID = id
            await publishVisionCompletionIfAvailable(assetID: id)
            return
        }

        guard let result = AlbumVisionSummarizer.summarize(imageData: data, maxDimension: visionThumbnailMaxDimension) else {
            await handleFailure(assetID: id, key: key, beforeState: beforeStateForCounts, error: "vision_summarizer_failed", attemptedAt: now, retryPriority: job.priority, isSeed: job.isSeed)
            return
        }

        let trimmed = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await handleFailure(assetID: id, key: key, beforeState: beforeStateForCounts, error: "vision_summary_empty", attemptedAt: now, retryPriority: job.priority, isSeed: job.isSeed)
            return
        }

        await sidecarStore.setVisionComputed(
            key,
            summary: trimmed,
            tags: result.tags,
            confidence: result.confidence,
            computedAt: now,
            modelVersion: result.modelVersion
        )

        lastProcessedID = id
        lastError = nil
        applySeedVisionCountDelta(assetID: id, from: beforeStateForCounts, to: .computed)
        await publishVisionUpdateIfAvailable(assetID: id, summary: trimmed, state: .computed, confidence: result.confidence)
        await publishVisionCompletionIfAvailable(assetID: id)

        if job.isSeed {
            await autofillSeedTimelineNeighborsIfEnabled(anchorID: id, summary: trimmed, tags: result.tags)
        }
    }

    private func handleFailure(
        assetID: String,
        key: AlbumSidecarKey,
        beforeState: AlbumSidecarRecord.VisionFillState,
        error: String,
        attemptedAt: Date,
        retryPriority: Priority,
        isSeed: Bool
    ) async {
        await sidecarStore.setVisionFailed(key, error: error, attemptedAt: attemptedAt)
        lastProcessedID = assetID
        lastError = error

        applySeedVisionCountDelta(assetID: assetID, from: beforeState, to: .failed)
        await publishVisionCompletionIfAvailable(assetID: assetID)

        guard let record = await sidecarStore.load(key) else { return }
        let attempts = max(0, record.vision.attemptCount ?? 0)
        guard attempts > 0, attempts < maxAttempts else { return }

        let retryAt = attemptedAt.addingTimeInterval(Self.backoffSeconds(forAttempt: attempts))
        _ = await ensureVisionScheduled(
            for: assetID,
            priority: retryPriority,
            reason: "retry_after_failure",
            isSeed: isSeed,
            notBefore: retryAt,
            shouldPublishStatus: false
        )
    }

	    private func autofillSeedTimelineNeighborsIfEnabled(anchorID: String, summary: String, tags: [String]) async {
	        let radius: Int = 10
	        guard radius > 0 else { return }
	        guard !AlbumVisionSummaryUtils.isPlaceholder(summary) else { return }
	        guard let index = await libraryIndexStore.loadIndex() else { return }

	        let neighbors = index.neighbors(of: anchorID, radius: radius)
	        guard !neighbors.isEmpty else { return }

        let confidence: Float = 0.30

        for neighborID in neighbors {
            let key = AlbumSidecarKey(source: .photos, id: neighborID)
            let existingState = (await sidecarStore.load(key))?.vision.state ?? .none
            guard existingState == .none else { continue }

	            await sidecarStore.setVisionAutofilledIfMissing(
	                key,
	                summary: summary,
	                tags: tags,
	                confidence: confidence,
	                source: .seedNeighbor,
	                derivedFromID: anchorID
	            )

            await publishVisionUpdateIfAvailable(assetID: neighborID, summary: summary, state: .autofilled, confidence: confidence)
            applySeedVisionCountDelta(assetID: neighborID, from: existingState, to: .autofilled)
        }
    }

    private func applySeedVisionCountDelta(assetID: String, from: AlbumSidecarRecord.VisionFillState, to: AlbumSidecarRecord.VisionFillState) {
        guard seedSet.contains(assetID) else { return }
        if from == to { return }

        func decrement(_ state: AlbumSidecarRecord.VisionFillState) {
            switch state {
            case .computed: seedComputedCount = max(0, seedComputedCount - 1)
            case .autofilled: seedAutofilledCount = max(0, seedAutofilledCount - 1)
            case .failed: seedFailedCount = max(0, seedFailedCount - 1)
            case .none: break
            }
        }

        func increment(_ state: AlbumSidecarRecord.VisionFillState) {
            switch state {
            case .computed: seedComputedCount += 1
            case .autofilled: seedAutofilledCount += 1
            case .failed: seedFailedCount += 1
            case .none: break
            }
        }

        decrement(from)
        increment(to)
    }

    private func ensureSeedPlanExistsIfPossible() async {
        if seedPlan != nil { return }
        if let loaded = loadSeedPlanState() {
            let normalizedSeedIDs = loaded.seedIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let normalized = SeedPlanState(seedIDs: normalizedSeedIDs, targetCount: normalizedSeedIDs.count, createdAt: loaded.createdAt)

            seedPlan = normalized
            seedTargetCount = normalized.targetCount
            seedSet = Set(normalized.seedIDs)
            if normalized != loaded {
                saveSeedPlanState(normalized)
            }

            await recomputeSeedCountsFromSidecars()
            return
        }

        guard let index = await libraryIndexStore.loadIndex() else { return }
        let desiredTarget = 1000
        let target = min(desiredTarget, index.idsByCreationDateAscending.count)
        let selected = index
            .stratifiedSample(targetCount: target)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !selected.isEmpty else { return }

        let plan = SeedPlanState(seedIDs: selected, targetCount: selected.count, createdAt: Date())
        seedPlan = plan
        seedTargetCount = plan.targetCount
        seedSet = Set(plan.seedIDs)
        saveSeedPlanState(plan)
        await recomputeSeedCountsFromSidecars()
    }

    private func rebuildSeedQueueFromSidecars() async {
        guard let plan = seedPlan else { return }
        guard !plan.seedIDs.isEmpty else { return }

        let now = Date()

        for idRaw in plan.seedIDs {
            let id = idRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }

            let key = AlbumSidecarKey(source: .photos, id: id)
            if let record = await sidecarStore.load(key),
               record.vision.state == .computed,
               !AlbumVisionSummaryUtils.isPlaceholder(record.vision.summary) {
                guard let _ = faceEngine else { continue }
                if record.faces.state == .computed || record.faces.state == .failed { continue }
            }

            _ = await ensureVisionScheduled(for: id, priority: .background, reason: "seed_backfill", isSeed: true, notBefore: now, shouldPublishStatus: false)
        }
    }

    private func recomputeSeedCountsFromSidecars() async {
        seedComputedCount = 0
        seedAutofilledCount = 0
        seedFailedCount = 0

        guard let plan = seedPlan, !plan.seedIDs.isEmpty else { return }
        let keys = plan.seedIDs.map { AlbumSidecarKey(source: .photos, id: $0) }
        let records = await sidecarStore.loadMany(keys)

        for record in records {
            guard seedSet.contains(record.key.id) else { continue }
            switch record.vision.state {
            case .computed:
                if !AlbumVisionSummaryUtils.isPlaceholder(record.vision.summary) {
                    seedComputedCount += 1
                }
            case .autofilled:
                seedAutofilledCount += 1
            case .failed:
                seedFailedCount += 1
            case .none:
                break
            }
        }
    }

    private func ensureLibraryIndexAvailable() async -> AlbumLibraryIndex? {
        if let index = await libraryIndexStore.loadIndex() {
            return index
        }
        return await libraryIndexStore.buildIfNeeded()
    }

    private func publishStatus() async {
        guard let sink = statusSink else { return }

        let total = max(0, seedTargetCount)
        let computed = max(0, seedComputedCount)
        let autofilled = max(0, seedAutofilledCount)
        let failed = max(0, seedFailedCount)
        let missing = max(0, total - computed - autofilled - failed)

	        let status = BackfillStatus(
	            totalAssets: total,
	            computed: computed,
	            autofilled: autofilled,
	            missing: missing,
	            failed: failed,
	            queued: queueByID.count,
	            inflight: inflightID == nil ? 0 : 1,
	            running: !paused && (inflightID != nil || !queueByID.isEmpty),
	            paused: paused,
	            lastProcessedID: lastProcessedID,
	            lastError: lastError
	        )

        await MainActor.run {
            sink(status)
        }
    }

    private func publishVisionUpdateIfAvailable(assetID: String, summary: String, state: AlbumSidecarRecord.VisionFillState, confidence: Float) async {
        guard let sink = visionUpdateSink else { return }
        await MainActor.run {
            sink(.init(assetID: assetID, summary: summary, state: state, confidence: confidence))
        }
    }

    private func publishVisionCompletionIfAvailable(assetID: String) async {
        guard let sink = visionCompletionSink else { return }
        await MainActor.run {
            sink(assetID)
        }
    }

    private func deleteLegacyBackfillStateIfPresent() {
        guard FileManager.default.fileExists(atPath: legacyBackfillStateURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacyBackfillStateURL)
        } catch {
            // Non-fatal.
            print("[AlbumBackfillManager] legacy backfill state delete error:", error)
        }
    }

    private static func backoffSeconds(forAttempt attemptCount: Int) -> TimeInterval {
        switch max(0, attemptCount) {
        case 0:
            return 0
        case 1:
            return 30
        case 2:
            return 2 * 60
        case 3:
            return 10 * 60
        default:
            let exponent = max(0, attemptCount - 3)
            let base: Double = 10 * 60
            return base * pow(2, Double(exponent))
        }
    }

    private static func seedCountedState(state: AlbumSidecarRecord.VisionFillState, summary: String?) -> AlbumSidecarRecord.VisionFillState {
        if state == .computed, AlbumVisionSummaryUtils.isPlaceholder(summary) {
            return .none
        }
        return state
    }

    // MARK: Disk

    private func loadSeedPlanState() -> SeedPlanState? {
        guard FileManager.default.fileExists(atPath: seedPlanURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: seedPlanURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SeedPlanState.self, from: data)
        } catch {
            print("[AlbumBackfillManager] loadSeedPlan error:", error)
            return nil
        }
    }

    private func saveSeedPlanState(_ state: SeedPlanState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: seedPlanURL, options: [.atomic])
        } catch {
            print("[AlbumBackfillManager] saveSeedPlan error:", error)
        }
    }

    private func loadLibraryScanState() -> LibraryScanState? {
        guard FileManager.default.fileExists(atPath: libraryScanURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: libraryScanURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LibraryScanState.self, from: data)
        } catch {
            print("[AlbumBackfillManager] loadLibraryScanState error:", error)
            return nil
        }
    }

    private func saveLibraryScanState(_ state: LibraryScanState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: libraryScanURL, options: [.atomic])
        } catch {
            print("[AlbumBackfillManager] saveLibraryScanState error:", error)
        }
    }
}
