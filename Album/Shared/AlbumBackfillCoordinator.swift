import Foundation

public struct AlbumBackfillProgress: Sendable, Hashable {
    public let targetCount: Int
    public let completedCount: Int
    public let isRunning: Bool

    public init(targetCount: Int, completedCount: Int, isRunning: Bool) {
        self.targetCount = targetCount
        self.completedCount = completedCount
        self.isRunning = isRunning
    }
}

public struct AlbumBackfillState: Codable, Sendable, Hashable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var seedSelectionVersion: Int
    public var targetCount: Int
    public var seedAssetIDs: [String]
    public var completedAssetIDs: Set<String>
    public var attemptedAssetIDs: Set<String>?
    public var seedScanCursor: Int?
    public var lastRunAt: Date?

    public init(
        schemaVersion: Int = AlbumBackfillState.currentSchemaVersion,
        seedSelectionVersion: Int = 1,
        targetCount: Int,
        seedAssetIDs: [String] = [],
        completedAssetIDs: Set<String> = [],
        attemptedAssetIDs: Set<String>? = nil,
        seedScanCursor: Int? = nil,
        lastRunAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.seedSelectionVersion = seedSelectionVersion
        self.targetCount = max(0, targetCount)
        self.seedAssetIDs = seedAssetIDs
        self.completedAssetIDs = completedAssetIDs
        self.attemptedAssetIDs = attemptedAssetIDs
        self.seedScanCursor = seedScanCursor
        self.lastRunAt = lastRunAt
    }
}

public actor AlbumBackfillCoordinator {
    public struct Config: Sendable, Hashable {
        public var targetSeedCount: Int
        public var chunkSize: Int

        public init(targetSeedCount: Int = 1000, chunkSize: Int = 200) {
            self.targetSeedCount = max(0, targetSeedCount)
            self.chunkSize = max(1, chunkSize)
        }
    }

    private let config: Config
    private let sidecarStore: AlbumSidecarStore
    private let libraryIndexStore: AlbumLibraryIndexStore
    private let visionQueue: AlbumVisionQueue

    private let stateURL: URL
    private var state: AlbumBackfillState? = nil
    private var runTask: Task<Void, Never>? = nil

    private var progressSink: (@MainActor (AlbumBackfillProgress) -> Void)?

    public init(
        config: Config = Config(),
        sidecarStore: AlbumSidecarStore,
        libraryIndexStore: AlbumLibraryIndexStore,
        visionQueue: AlbumVisionQueue,
        fileName: String = "album_backfill_state_v1.json"
    ) {
        self.config = config
        self.sidecarStore = sidecarStore
        self.libraryIndexStore = libraryIndexStore
        self.visionQueue = visionQueue

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.stateURL = appSupport.appendingPathComponent(fileName, isDirectory: false)
    }

    public func setProgressSink(_ sink: (@MainActor (AlbumBackfillProgress) -> Void)?) {
        progressSink = sink
    }

    public func startIfNeeded(source: AlbumSidecarSource) async {
        guard config.targetSeedCount > 0 else { return }
        guard runTask == nil else { return }

        let hasIndex = await libraryIndexStore.buildIfNeeded() != nil
        guard hasIndex else {
            AlbumLog.model.info("Backfill: index unavailable; skipping")
            return
        }

        await loadOrCreateStateIfNeeded(source: source)

        guard var state else { return }
        if state.seedAssetIDs.isEmpty || state.targetCount != config.targetSeedCount {
            await resetSeeds(source: source)
        }

        await reconcileCompletionFromDisk(source: source)

        state = await loadState() ?? state
        await publishProgress(isRunning: true)

        runTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runBackfill(source: source)
        }
    }

    public func pause() async {
        runTask?.cancel()
        runTask = nil
        await publishProgress(isRunning: false)
    }

    public func currentProgress() async -> AlbumBackfillProgress {
        let state = await loadState() ?? AlbumBackfillState(targetCount: config.targetSeedCount)
        return AlbumBackfillProgress(
            targetCount: state.targetCount,
            completedCount: state.completedAssetIDs.count,
            isRunning: runTask != nil
        )
    }

    // MARK: Internals

    private func runBackfill(source: AlbumSidecarSource) async {
        defer {
            Task { [weak self] in
                guard let self else { return }
                await self.finishRun()
            }
        }

        guard var state = await loadState() else { return }
        guard state.targetCount > 0 else { return }
        guard let index = await libraryIndexStore.loadIndex() else { return }

        while !Task.isCancelled {
            state = await loadState() ?? state
            if state.completedAssetIDs.count >= state.targetCount { return }

            let attempted = state.attemptedAssetIDs ?? []
            let pending = state.seedAssetIDs.filter { id in
                !state.completedAssetIDs.contains(id) && !attempted.contains(id)
            }

            if pending.isEmpty {
                let added = await appendMoreSeedsIfNeeded(source: source, index: index, state: &state)
                if added == 0 {
                    AlbumLog.model.info("Backfill: no additional seeds available; stopping at \(state.completedAssetIDs.count)/\(state.targetCount)")
                    await publishProgress(isRunning: runTask != nil)
                    return
                }
                continue
            }

            let chunkSize = config.chunkSize
            let chunk = Array(pending.prefix(chunkSize))

            var attemptedBatch: [String] = []
            attemptedBatch.reserveCapacity(chunk.count)
            var completedBatch: [String] = []
            completedBatch.reserveCapacity(min(64, chunk.count))

            await withTaskGroup(of: (String, Bool).self) { group in
                for assetID in chunk {
                    group.addTask(priority: .background) { [sidecarStore, visionQueue] in
                        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !id.isEmpty else { return (assetID, false) }

                        let key = AlbumSidecarKey(source: source, id: id)
                        if let record = await sidecarStore.load(key),
                           let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !summary.isEmpty {
                            return (id, record.visionSource == .computed)
                        }

                        let ok = await visionQueue.ensureVisionComputed(
                            for: id,
                            source: source,
                            reason: "backfill_seed",
                            priority: .background
                        )
                        return (id, ok)
                    }
                }

                for await (assetID, ok) in group {
                    let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { continue }
                    attemptedBatch.append(id)
                    if ok { completedBatch.append(id) }
                }
            }

            await markAttempted(attemptedBatch, completed: completedBatch, state: &state)
        }
    }

    private func finishRun() async {
        runTask = nil
        await publishProgress(isRunning: false)
    }

    private func markCompleted(assetID: String) async {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        guard var state = await loadState() else { return }
        guard !state.completedAssetIDs.contains(id) else { return }

        state.completedAssetIDs.insert(id)
        state.lastRunAt = Date()
        await saveState(state)
        await publishProgress(isRunning: runTask != nil)
    }

    private func markAttempted(_ attempted: [String], completed: [String], state: inout AlbumBackfillState) async {
        if state.attemptedAssetIDs == nil {
            state.attemptedAssetIDs = []
        }

        if let currentAttempted = state.attemptedAssetIDs, currentAttempted.count > 50_000 {
            AlbumLog.model.info("Backfill: attempted set is very large (\(currentAttempted.count)); continuing anyway")
        }

        for id in attempted {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            state.attemptedAssetIDs?.insert(trimmed)
        }

        for id in completed {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            state.completedAssetIDs.insert(trimmed)
        }

        state.lastRunAt = Date()
        await saveState(state)
        await publishProgress(isRunning: runTask != nil)
    }

    private func loadOrCreateStateIfNeeded(source: AlbumSidecarSource) async {
        if state != nil { return }
        state = await loadState()
        if state == nil {
            let created = AlbumBackfillState(targetCount: config.targetSeedCount)
            state = created
            await saveState(created)
        }
    }

    private func resetSeeds(source: AlbumSidecarSource) async {
        guard let index = await libraryIndexStore.loadIndex() else { return }
        let seeds = await selectUnlabeledSeeds(index: index, source: source, targetCount: config.targetSeedCount)

        var newState = AlbumBackfillState(
            seedSelectionVersion: 1,
            targetCount: config.targetSeedCount,
            seedAssetIDs: seeds,
            completedAssetIDs: [],
            attemptedAssetIDs: [],
            seedScanCursor: nil,
            lastRunAt: nil
        )

        newState.seedAssetIDs = seeds
        await saveState(newState)
        state = newState

        AlbumLog.model.info("Backfill: seeded \(seeds.count) items")
        await publishProgress(isRunning: runTask != nil)
    }

    private func selectUnlabeledSeeds(index: AlbumLibraryIndex, source: AlbumSidecarSource, targetCount: Int) async -> [String] {
        let total = index.idsByCreationDateAscending.count
        let target = max(0, targetCount)
        guard total > 0, target > 0 else { return [] }

        let baseSample = index.stratifiedSample(targetCount: min(total, target * 2))

        var selected: [String] = []
        selected.reserveCapacity(min(target, baseSample.count))

        for rawID in baseSample {
            if selected.count >= target { break }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }

            let key = AlbumSidecarKey(source: source, id: id)
            if let record = await sidecarStore.load(key),
               let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                continue
            }
            selected.append(id)
        }

        if selected.count >= target { return selected }

        var cursor = Int.random(in: 0..<total)
        var scanned = 0
        var seen = Set<String>(selected)
        seen.reserveCapacity(selected.count + 256)

        while selected.count < target, scanned < total {
            let rawID = index.idsByCreationDateAscending[cursor]
            cursor = (cursor + 1) % total
            scanned += 1

            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard seen.insert(id).inserted else { continue }

            let key = AlbumSidecarKey(source: source, id: id)
            if let record = await sidecarStore.load(key),
               let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                continue
            }

            selected.append(id)
        }

        return selected
    }

    private func appendMoreSeedsIfNeeded(source: AlbumSidecarSource, index: AlbumLibraryIndex, state: inout AlbumBackfillState) async -> Int {
        let total = index.idsByCreationDateAscending.count
        guard total > 0 else { return 0 }

        let attempted = state.attemptedAssetIDs ?? []
        var exclude = Set(state.seedAssetIDs)
            .union(state.completedAssetIDs)
            .union(attempted)

        let remainingNeeded = max(0, state.targetCount - state.completedAssetIDs.count)
        let desiredAdd = min(total, max(config.chunkSize, min(remainingNeeded, config.chunkSize * 2)))
        guard desiredAdd > 0 else { return 0 }

        var cursor = state.seedScanCursor ?? Int.random(in: 0..<total)
        var scanned = 0
        var added = 0

        while added < desiredAdd, scanned < total {
            let rawID = index.idsByCreationDateAscending[cursor]
            cursor = (cursor + 1) % total
            scanned += 1

            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard !exclude.contains(id) else { continue }

            let key = AlbumSidecarKey(source: source, id: id)
            if let record = await sidecarStore.load(key),
               let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                continue
            }

            state.seedAssetIDs.append(id)
            exclude.insert(id)
            added += 1
        }

        state.seedScanCursor = cursor
        if added > 0 {
            await saveState(state)
            self.state = state
            let seedCount = state.seedAssetIDs.count
            let completedCount = state.completedAssetIDs.count
            let attemptedCount = state.attemptedAssetIDs?.count ?? 0
            AlbumLog.model.info("Backfill: appended \(added) new seeds; seeds=\(seedCount) completed=\(completedCount) attempted=\(attemptedCount)")
            await publishProgress(isRunning: runTask != nil)
        }

        return added
    }

    private func reconcileCompletionFromDisk(source: AlbumSidecarSource) async {
        guard var state = await loadState() else { return }
        guard !state.seedAssetIDs.isEmpty else { return }

        var updated = false
        for id in state.seedAssetIDs {
            if state.completedAssetIDs.contains(id) { continue }
            let key = AlbumSidecarKey(source: source, id: id)
            if let record = await sidecarStore.load(key),
               record.visionSource == .computed,
               let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                state.completedAssetIDs.insert(id)
                updated = true
            }
        }

        if updated {
            await saveState(state)
            self.state = state
            await publishProgress(isRunning: runTask != nil)
        }
    }

    private func loadState() async -> AlbumBackfillState? {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(AlbumBackfillState.self, from: data)
            self.state = decoded
            return decoded
        } catch {
            AlbumLog.model.error("Backfill: load error \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func saveState(_ state: AlbumBackfillState) async {
        var normalized = state
        normalized.schemaVersion = AlbumBackfillState.currentSchemaVersion
        normalized.targetCount = max(0, normalized.targetCount)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(normalized)
            try data.write(to: stateURL, options: [.atomic])
            self.state = normalized
        } catch {
            AlbumLog.model.error("Backfill: save error \(String(describing: error), privacy: .public)")
        }
    }

    private func publishProgress(isRunning: Bool) async {
        guard let sink = progressSink else { return }
        guard let state = await loadState() else {
            await MainActor.run {
                sink(.init(targetCount: config.targetSeedCount, completedCount: 0, isRunning: isRunning))
            }
            return
        }

        let progress = AlbumBackfillProgress(
            targetCount: state.targetCount,
            completedCount: state.completedAssetIDs.count,
            isRunning: isRunning
        )

        await MainActor.run {
            sink(progress)
        }
    }
}
