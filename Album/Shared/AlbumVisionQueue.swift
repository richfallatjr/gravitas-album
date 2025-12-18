import Foundation
import CoreGraphics

actor AlbumAsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = max(0, value)
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            value += 1
        }
    }
}

public struct AlbumVisionUpdate: Sendable, Hashable {
    public let assetID: String
    public let summary: String
    public let source: AlbumVisionSource
    public let confidence: Float

    public init(assetID: String, summary: String, source: AlbumVisionSource, confidence: Float) {
        self.assetID = assetID
        self.summary = summary
        self.source = source
        self.confidence = confidence
    }
}

public actor AlbumVisionQueue {
    public struct Config: Sendable, Hashable {
        public var maxConcurrency: Int
        public var visionThumbnailMaxDimension: Int
        public var neighborInferenceRadius: Int
        public var inferredConfidence: Float

        public init(
            maxConcurrency: Int = 8,
            visionThumbnailMaxDimension: Int = 512,
            neighborInferenceRadius: Int = 12,
            inferredConfidence: Float = 0.30
        ) {
            self.maxConcurrency = max(1, maxConcurrency)
            self.visionThumbnailMaxDimension = max(64, visionThumbnailMaxDimension)
            self.neighborInferenceRadius = max(0, neighborInferenceRadius)
            self.inferredConfidence = max(0, min(1, inferredConfidence))
        }
    }

    private let sidecarStore: AlbumSidecarStore
    private let libraryIndexStore: AlbumLibraryIndexStore
    private let assetProvider: any AlbumAssetProvider
    private let config: Config

    private let semaphore: AlbumAsyncSemaphore
    private var inflight: [String: Task<Void, Never>] = [:]

    private var updateSink: (@MainActor (AlbumVisionUpdate) -> Void)?
    private var completionSink: (@MainActor (String) -> Void)?

    public init(
        sidecarStore: AlbumSidecarStore,
        libraryIndexStore: AlbumLibraryIndexStore,
        assetProvider: any AlbumAssetProvider,
        config: Config = Config()
    ) {
        self.sidecarStore = sidecarStore
        self.libraryIndexStore = libraryIndexStore
        self.assetProvider = assetProvider
        self.config = config
        self.semaphore = AlbumAsyncSemaphore(value: config.maxConcurrency)
    }

    public func setUpdateSink(_ sink: (@MainActor (AlbumVisionUpdate) -> Void)?) {
        updateSink = sink
    }

    public func setCompletionSink(_ sink: (@MainActor (String) -> Void)?) {
        completionSink = sink
    }

    @discardableResult
    public func enqueueVision(for assetID: String, source: AlbumSidecarSource, reason: String, priority: TaskPriority = .utility) async -> Bool {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if inflight[id] != nil { return false }

        let key = AlbumSidecarKey(source: source, id: id)
        if let record = await sidecarStore.load(key),
           record.visionSource == .computed,
           let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return false
        }

        let queue = self
        let sidecarStore = self.sidecarStore
        let libraryIndexStore = self.libraryIndexStore
        let semaphore = self.semaphore
        let config = self.config

        let task = Task.detached(priority: priority) {
            await semaphore.wait()
            defer { Task.detached { await semaphore.signal() } }

            if Task.isCancelled {
                await queue.publishCompletion(assetID: id)
                await queue.finish(assetID: id)
                return
            }

            guard let data = await queue.requestVisionThumbnailData(assetID: id, maxDimension: config.visionThumbnailMaxDimension) else {
                await queue.publishCompletion(assetID: id)
                await queue.finish(assetID: id)
                return
            }

            guard let result = AlbumVisionSummarizer.summarize(imageData: data, maxDimension: config.visionThumbnailMaxDimension) else {
                await queue.publishCompletion(assetID: id)
                await queue.finish(assetID: id)
                return
            }

            let now = Date()
            await sidecarStore.setVisionComputed(
                key,
                summary: result.summary,
                tags: result.tags,
                confidence: result.confidence,
                computedAt: now,
                modelVersion: result.modelVersion
            )

            if config.neighborInferenceRadius > 0 {
                await Self.propagateInference(
                    libraryIndexStore: libraryIndexStore,
                    sidecarStore: sidecarStore,
                    source: source,
                    seedAssetID: id,
                    seedSummary: result.summary,
                    seedTags: result.tags,
                    radius: config.neighborInferenceRadius,
                    inferredConfidence: config.inferredConfidence
                )
            }

            await queue.publishUpdate(
                AlbumVisionUpdate(
                    assetID: id,
                    summary: result.summary,
                    source: .computed,
                    confidence: result.confidence
                ),
                reason: reason
            )

            await queue.publishCompletion(assetID: id)
            await queue.finish(assetID: id)
        }

        inflight[id] = task
        return true
    }

    public func ensureVisionComputed(for assetID: String, source: AlbumSidecarSource, reason: String, priority: TaskPriority = .background) async -> Bool {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }

        let key = AlbumSidecarKey(source: source, id: id)
        if let record = await sidecarStore.load(key),
           record.visionSource == .computed,
           let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return true
        }

        _ = await enqueueVision(for: id, source: source, reason: reason, priority: priority)
        if let task = inflight[id] {
            await task.value
        }

        if let record = await sidecarStore.load(key),
           record.visionSource == .computed,
           let summary = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return true
        }

        return false
    }

    private func requestVisionThumbnailData(assetID: String, maxDimension: Int) async -> Data? {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let size = CGSize(width: max(64, maxDimension), height: max(64, maxDimension))
        let image = await assetProvider.requestThumbnail(localIdentifier: id, targetSize: size)

#if canImport(UIKit)
        return image?.jpegData(compressionQuality: 0.90) ?? image?.pngData()
#elseif canImport(AppKit)
        return image?.tiffRepresentation
#else
        return nil
#endif
    }

    private static func propagateInference(
        libraryIndexStore: AlbumLibraryIndexStore,
        sidecarStore: AlbumSidecarStore,
        source: AlbumSidecarSource,
        seedAssetID: String,
        seedSummary: String,
        seedTags: [String],
        radius: Int,
        inferredConfidence: Float
    ) async {
        guard radius > 0 else { return }
        guard let index = await libraryIndexStore.loadIndex() else { return }
        let neighbors = index.neighbors(of: seedAssetID, radius: radius)
        guard !neighbors.isEmpty else { return }

        for neighborID in neighbors {
            let key = AlbumSidecarKey(source: source, id: neighborID)
            await sidecarStore.setVisionInferred(
                key,
                summary: seedSummary,
                tags: seedTags,
                confidence: inferredConfidence,
                derivedFromID: seedAssetID
            )
        }
    }

    private func publishUpdate(_ update: AlbumVisionUpdate, reason: String) async {
        guard let sink = updateSink else { return }
        await MainActor.run {
            sink(update)
        }
    }

    private func publishCompletion(assetID: String) async {
        guard let sink = completionSink else { return }
        await MainActor.run {
            sink(assetID)
        }
    }

    private func finish(assetID: String) async {
        inflight[assetID] = nil
    }
}
