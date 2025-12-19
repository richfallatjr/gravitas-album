import Foundation
import CryptoKit

public enum AlbumSidecarSource: String, Codable, Sendable, CaseIterable {
    case photos
    case demo
}

public struct AlbumSidecarKey: Codable, Hashable, Sendable {
    public var source: AlbumSidecarSource
    public var id: String

    public init(source: AlbumSidecarSource, id: String) {
        self.source = source
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AlbumSidecarRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: Int = 2

    public var schemaVersion: Int
    public var key: AlbumSidecarKey
    public var updatedAt: Date

    public var rating: Int
    public var hidden: Bool

    public enum VisionFillState: String, Codable, Sendable, CaseIterable {
        case none          // no visionSummary
        case autofilled    // inferred/proxy text
        case computed      // actual Vision result
        case failed        // last attempt failed
    }

    public enum AutofillSource: String, Codable, Sendable, CaseIterable {
        case seedNeighbor      // inferred from seed results
        case thumbUpNeighbor   // inferred from thumbs up anchor
        case timelineNeighbor  // inferred from adjacent-by-date
    }

    public struct VisionInfo: Codable, Hashable, Sendable {
        public var state: VisionFillState
        public var summary: String?
        public var tags: [String]?
        public var confidence: Float?
        public var source: AutofillSource?
        public var derivedFromID: String?
        public var computedAt: Date?
        public var modelVersion: String?
        public var lastError: String?
        public var attemptCount: Int?
        public var lastAttemptAt: Date?

        public init(
            state: VisionFillState = .none,
            summary: String? = nil,
            tags: [String]? = nil,
            confidence: Float? = nil,
            source: AutofillSource? = nil,
            derivedFromID: String? = nil,
            computedAt: Date? = nil,
            modelVersion: String? = nil,
            lastError: String? = nil,
            attemptCount: Int? = nil,
            lastAttemptAt: Date? = nil
        ) {
            self.state = state
            self.summary = summary
            self.tags = tags
            self.confidence = confidence
            self.source = source
            self.derivedFromID = derivedFromID
            self.computedAt = computedAt
            self.modelVersion = modelVersion
            self.lastError = lastError
            self.attemptCount = attemptCount
            self.lastAttemptAt = lastAttemptAt
        }
    }

    public var vision: VisionInfo

    public init(
        schemaVersion: Int = AlbumSidecarRecord.currentSchemaVersion,
        key: AlbumSidecarKey,
        updatedAt: Date = Date(),
        rating: Int = 0,
        hidden: Bool = false,
        vision: VisionInfo = VisionInfo()
    ) {
        self.schemaVersion = schemaVersion
        self.key = key
        self.updatedAt = updatedAt
        self.rating = max(-1, min(1, rating))
        self.hidden = hidden
        self.vision = vision
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case key
        case updatedAt
        case rating
        case hidden
        case vision

        // Legacy keys (v1)
        case visionSummary
        case visionTags
        case visionSource
        case visionConfidence
        case visionDerivedFromID
        case visionInferenceMethod
        case visionComputedAt
        case visionModelVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = decodedSchema
        key = try container.decode(AlbumSidecarKey.self, forKey: .key)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        rating = max(-1, min(1, try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0))
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false

        if let vision = try container.decodeIfPresent(VisionInfo.self, forKey: .vision) {
            self.vision = vision
            schemaVersion = AlbumSidecarRecord.currentSchemaVersion
            return
        }

        let legacySummary = try container.decodeIfPresent(String.self, forKey: .visionSummary)
        let legacyTags = try container.decodeIfPresent([String].self, forKey: .visionTags)
        let legacySource = try container.decodeIfPresent(String.self, forKey: .visionSource)
        let legacyConfidence = try container.decodeIfPresent(Float.self, forKey: .visionConfidence)
        let legacyDerivedFromID = try container.decodeIfPresent(String.self, forKey: .visionDerivedFromID)
        let legacyInferenceMethod = try container.decodeIfPresent(String.self, forKey: .visionInferenceMethod)
        let legacyComputedAt = try container.decodeIfPresent(Date.self, forKey: .visionComputedAt)
        let legacyModelVersion = try container.decodeIfPresent(String.self, forKey: .visionModelVersion)

        let trimmed = legacySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = (trimmed?.isEmpty == false)

        let inferredSource: AutofillSource? = {
            guard let method = legacyInferenceMethod?.lowercased() else { return nil }
            if method.contains("thumb") { return .thumbUpNeighbor }
            if method.contains("seed") { return .seedNeighbor }
            if method.contains("timeline") { return .timelineNeighbor }
            return .timelineNeighbor
        }()

        let state: VisionFillState = {
            if !hasSummary { return .none }
            if legacySource == "computed" { return .computed }
            return .autofilled
        }()

        self.vision = VisionInfo(
            state: state,
            summary: hasSummary ? trimmed : nil,
            tags: legacyTags,
            confidence: legacyConfidence,
            source: state == .autofilled ? inferredSource : nil,
            derivedFromID: legacyDerivedFromID,
            computedAt: state == .computed ? legacyComputedAt : nil,
            modelVersion: state == .computed ? legacyModelVersion : nil,
            lastError: nil,
            attemptCount: nil,
            lastAttemptAt: nil
        )

        schemaVersion = AlbumSidecarRecord.currentSchemaVersion
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AlbumSidecarRecord.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(key, forKey: .key)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(rating, forKey: .rating)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(vision, forKey: .vision)
    }
}

public actor AlbumSidecarStore {
    private let storeDirectoryURL: URL
    private let legacyStoreURL: URL
    private let migrationMarkerURL: URL

    private var cache: [AlbumSidecarKey: AlbumSidecarRecord] = [:]

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sidecars = appSupport.appendingPathComponent("Sidecars", isDirectory: true)
        self.storeDirectoryURL = sidecars
        self.migrationMarkerURL = sidecars.appendingPathComponent("legacy_migration_v1.done", isDirectory: false)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.legacyStoreURL = documents.appendingPathComponent("album_sidecar.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
        } catch {
            // Directory creation failures are non-fatal; reads will simply miss.
            print("[AlbumSidecarStore] createDirectory error:", error)
        }
    }

    // MARK: Migration

    public func migrateLegacyIfNeeded() async {
        guard !FileManager.default.fileExists(atPath: migrationMarkerURL.path) else { return }
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path) else {
            await markLegacyMigrationComplete()
            return
        }

        do {
            let data = try Data(contentsOf: legacyStoreURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode(AlbumLegacySidecar.self, from: data)

            var allIDs = Set<String>()
            allIDs.formUnion(legacy.hiddenLocalIdentifiers)
            allIDs.formUnion(legacy.thumbFeedbackByLocalIdentifier.keys)
            allIDs.formUnion(legacy.visionSummaryByLocalIdentifier.keys)

            for id in allIDs {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let rating: Int = {
                    switch legacy.thumbFeedbackByLocalIdentifier[trimmed] {
                    case .up: return 1
                    case .down: return -1
                    case nil: return 0
                    }
                }()

                let summary = legacy.visionSummaryByLocalIdentifier[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasSummary = (summary?.isEmpty == false)

                let record = AlbumSidecarRecord(
                    key: AlbumSidecarKey(source: .photos, id: trimmed),
                    updatedAt: legacy.updatedAt,
                    rating: rating,
                    hidden: legacy.hiddenLocalIdentifiers.contains(trimmed),
                    vision: AlbumSidecarRecord.VisionInfo(
                        state: hasSummary ? .computed : .none,
                        summary: hasSummary ? summary : nil,
                        tags: nil,
                        confidence: hasSummary ? 0.65 : nil,
                        source: nil,
                        derivedFromID: nil,
                        computedAt: hasSummary ? legacy.updatedAt : nil,
                        modelVersion: hasSummary ? "legacy" : nil,
                        lastError: nil,
                        attemptCount: nil,
                        lastAttemptAt: nil
                    )
                )

                await upsert(record)
            }

            await markLegacyMigrationComplete()
            print("[AlbumSidecarStore] migrated legacy sidecar ids:", allIDs.count)
        } catch {
            print("[AlbumSidecarStore] legacy migration error:", error)
            await markLegacyMigrationComplete()
        }
    }

    private func markLegacyMigrationComplete() async {
        do {
            try Data("ok".utf8).write(to: migrationMarkerURL, options: [.atomic])
        } catch {
            print("[AlbumSidecarStore] markMigrationComplete error:", error)
        }
    }

    // MARK: API

    public func load(_ key: AlbumSidecarKey) async -> AlbumSidecarRecord? {
        let normalized = AlbumSidecarKey(source: key.source, id: key.id)
        if let cached = cache[normalized] { return cached }

        let url = urlForKey(normalized)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(AlbumSidecarRecord.self, from: data)
            cache[normalized] = record
            return record
        } catch {
            print("[AlbumSidecarStore] load error:", error)
            return nil
        }
    }

    public func loadMany(_ keys: [AlbumSidecarKey]) async -> [AlbumSidecarRecord] {
        guard !keys.isEmpty else { return [] }
        var out: [AlbumSidecarRecord] = []
        out.reserveCapacity(keys.count)

        for key in keys {
            let normalized = AlbumSidecarKey(source: key.source, id: key.id)
            if let record = await load(normalized) {
                out.append(record)
            }
        }

        return out
    }

    public func upsert(_ record: AlbumSidecarRecord) async {
        let normalizedKey = AlbumSidecarKey(source: record.key.source, id: record.key.id)
        var normalized = record
        normalized.key = normalizedKey
        normalized.schemaVersion = AlbumSidecarRecord.currentSchemaVersion
        normalized.updatedAt = Date()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(normalized)
            let url = urlForKey(normalizedKey)
            try data.write(to: url, options: [.atomic])
            cache[normalizedKey] = normalized
        } catch {
            print("[AlbumSidecarStore] upsert error:", error)
        }
    }

    public func mutate(_ key: AlbumSidecarKey, _ edit: (inout AlbumSidecarRecord) -> Void) async {
        let normalizedKey = AlbumSidecarKey(source: key.source, id: key.id)
        var record = await load(normalizedKey) ?? AlbumSidecarRecord(key: normalizedKey)
        edit(&record)
        await upsert(record)
    }

    public func setHidden(_ key: AlbumSidecarKey, hidden: Bool) async {
        await mutate(key) { record in
            record.hidden = hidden
        }
    }

    public func setRating(_ key: AlbumSidecarKey, rating: Int) async {
        await mutate(key) { record in
            record.rating = max(-1, min(1, rating))
        }
    }

    public func setVisionComputed(
        _ key: AlbumSidecarKey,
        summary: String,
        tags: [String]?,
        confidence: Float,
        computedAt: Date,
        modelVersion: String
    ) async {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        await mutate(key) { record in
            record.vision.state = .computed
            record.vision.summary = trimmedSummary
            record.vision.tags = tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            record.vision.confidence = max(0, min(1, confidence))
            record.vision.source = nil
            record.vision.derivedFromID = nil
            record.vision.computedAt = computedAt
            record.vision.modelVersion = modelVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            record.vision.lastError = nil
            record.vision.attemptCount = nil
            record.vision.lastAttemptAt = nil
        }
    }

	    public func setVisionAutofilledIfMissing(
	        _ key: AlbumSidecarKey,
	        summary: String,
	        tags: [String]?,
	        confidence: Float,
	        source: AlbumSidecarRecord.AutofillSource,
	        derivedFromID: String?
	    ) async {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let derived = derivedFromID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedNormalized = (derived?.isEmpty == false) ? derived : nil

	        await mutate(key) { record in
	            guard record.vision.state != .computed else { return }
	            guard record.vision.state == .none else { return }

            record.vision.state = .autofilled
            record.vision.summary = trimmedSummary
            record.vision.tags = tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            record.vision.confidence = max(0, min(1, confidence))
            record.vision.source = source
            record.vision.derivedFromID = derivedNormalized
            record.vision.computedAt = nil
            record.vision.modelVersion = nil
            record.vision.lastError = nil
	        }
	    }

	    public func setVisionAutofilledIfMissingOrAutofilled(
	        _ key: AlbumSidecarKey,
	        summary: String,
	        tags: [String]?,
	        confidence: Float,
	        source: AlbumSidecarRecord.AutofillSource,
	        derivedFromID: String?
	    ) async {
	        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
	        guard !trimmedSummary.isEmpty else { return }

	        let derived = derivedFromID?.trimmingCharacters(in: .whitespacesAndNewlines)
	        let derivedNormalized = (derived?.isEmpty == false) ? derived : nil

	        await mutate(key) { record in
	            guard record.vision.state != .computed else { return }
	            guard record.vision.state == .none || record.vision.state == .autofilled else { return }

	            record.vision.state = .autofilled
	            record.vision.summary = trimmedSummary
	            record.vision.tags = tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
	            record.vision.confidence = max(0, min(1, confidence))
	            record.vision.source = source
	            record.vision.derivedFromID = derivedNormalized
	            record.vision.computedAt = nil
	            record.vision.modelVersion = nil
	            record.vision.lastError = nil
	        }
	    }

	    public func setVisionFailed(
	        _ key: AlbumSidecarKey,
	        error: String,
	        attemptedAt: Date
	    ) async {
        let trimmedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedError.isEmpty else { return }

        await mutate(key) { record in
            guard record.vision.state != .computed else { return }
            record.vision.state = .failed
            record.vision.lastError = trimmedError

            let previousAttempts = record.vision.attemptCount ?? 0
            record.vision.attemptCount = max(0, previousAttempts) + 1
            record.vision.lastAttemptAt = attemptedAt
        }
    }

    public func resetVisionFailures(_ key: AlbumSidecarKey) async {
        await mutate(key) { record in
            guard record.vision.state == .failed else { return }
            record.vision.attemptCount = 0
            record.vision.lastAttemptAt = nil
            record.vision.lastError = nil
        }
    }

    public func unhideAll() async -> Int {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: storeDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            print("[AlbumSidecarStore] unhideAll list error:", error)
            return 0
        }

        guard !urls.isEmpty else { return 0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let now = Date()
        var changed = 0

        for url in urls {
            guard url.pathExtension.lowercased() == "json" else { continue }

            do {
                let data = try Data(contentsOf: url)
                var record = try decoder.decode(AlbumSidecarRecord.self, from: data)
                guard record.hidden else { continue }

                record.hidden = false
                record.updatedAt = now
                record.schemaVersion = AlbumSidecarRecord.currentSchemaVersion
                record.key = AlbumSidecarKey(source: record.key.source, id: record.key.id)

                let normalizedKey = record.key
                let output = try encoder.encode(record)
                try output.write(to: url, options: [.atomic])
                cache[normalizedKey] = record
                changed += 1
            } catch {
                print("[AlbumSidecarStore] unhideAll error:", error)
            }
        }

        return changed
    }

    // MARK: Internals

    private func urlForKey(_ key: AlbumSidecarKey) -> URL {
        storeDirectoryURL.appendingPathComponent(filenameForKey(key), isDirectory: false)
    }

    private func filenameForKey(_ key: AlbumSidecarKey) -> String {
        let input = "\(key.source.rawValue)|\(key.id)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".json"
    }
}

// MARK: Legacy schema (single JSON file)

private struct AlbumLegacySidecar: Codable, Hashable {
    var visionSummaryByLocalIdentifier: [String: String]
    var thumbFeedbackByLocalIdentifier: [String: AlbumThumbFeedback]
    var hiddenLocalIdentifiers: Set<String>
    var updatedAt: Date

    init(
        visionSummaryByLocalIdentifier: [String: String] = [:],
        thumbFeedbackByLocalIdentifier: [String: AlbumThumbFeedback] = [:],
        hiddenLocalIdentifiers: Set<String> = [],
        updatedAt: Date = Date()
    ) {
        self.visionSummaryByLocalIdentifier = visionSummaryByLocalIdentifier
        self.thumbFeedbackByLocalIdentifier = thumbFeedbackByLocalIdentifier
        self.hiddenLocalIdentifiers = hiddenLocalIdentifiers
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case visionSummaryByLocalIdentifier
        case thumbFeedbackByLocalIdentifier
        case hiddenLocalIdentifiers
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.visionSummaryByLocalIdentifier = try container.decodeIfPresent([String: String].self, forKey: .visionSummaryByLocalIdentifier) ?? [:]
        self.thumbFeedbackByLocalIdentifier = try container.decodeIfPresent([String: AlbumThumbFeedback].self, forKey: .thumbFeedbackByLocalIdentifier) ?? [:]
        self.hiddenLocalIdentifiers = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenLocalIdentifiers) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
