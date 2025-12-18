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

public enum AlbumVisionSource: String, Codable, Sendable, CaseIterable {
    case computed
    case inferred
}

public struct AlbumSidecarRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var key: AlbumSidecarKey
    public var updatedAt: Date

    public var rating: Int
    public var hidden: Bool

    public var visionSummary: String?
    public var visionTags: [String]?
    public var visionSource: AlbumVisionSource?
    public var visionConfidence: Float?
    public var visionDerivedFromID: String?
    public var visionComputedAt: Date?
    public var visionModelVersion: String?

    public init(
        schemaVersion: Int = AlbumSidecarRecord.currentSchemaVersion,
        key: AlbumSidecarKey,
        updatedAt: Date = Date(),
        rating: Int = 0,
        hidden: Bool = false,
        visionSummary: String? = nil,
        visionTags: [String]? = nil,
        visionSource: AlbumVisionSource? = nil,
        visionConfidence: Float? = nil,
        visionDerivedFromID: String? = nil,
        visionComputedAt: Date? = nil,
        visionModelVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.key = key
        self.updatedAt = updatedAt
        self.rating = max(-1, min(1, rating))
        self.hidden = hidden
        self.visionSummary = visionSummary
        self.visionTags = visionTags
        self.visionSource = visionSource
        self.visionConfidence = visionConfidence
        self.visionDerivedFromID = visionDerivedFromID
        self.visionComputedAt = visionComputedAt
        self.visionModelVersion = visionModelVersion
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
                    visionSummary: hasSummary ? summary : nil,
                    visionTags: nil,
                    visionSource: hasSummary ? .computed : nil,
                    visionConfidence: hasSummary ? 0.65 : nil,
                    visionDerivedFromID: nil,
                    visionComputedAt: hasSummary ? legacy.updatedAt : nil,
                    visionModelVersion: hasSummary ? "legacy" : nil
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
            record.visionSummary = trimmedSummary
            record.visionTags = tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            record.visionSource = .computed
            record.visionConfidence = max(0, min(1, confidence))
            record.visionDerivedFromID = nil
            record.visionComputedAt = computedAt
            record.visionModelVersion = modelVersion
        }
    }

    public func setVisionInferred(
        _ key: AlbumSidecarKey,
        summary: String,
        tags: [String]?,
        confidence: Float,
        derivedFromID: String?
    ) async {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let derived = derivedFromID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedNormalized = (derived?.isEmpty == false) ? derived : nil

        await mutate(key) { record in
            if let existing = record.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                return
            }

            record.visionSummary = trimmedSummary
            record.visionTags = tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            record.visionSource = .inferred
            record.visionConfidence = max(0, min(1, confidence))
            record.visionDerivedFromID = derivedNormalized
            if record.visionComputedAt != nil {
                record.visionComputedAt = nil
            }
            if record.visionModelVersion != nil {
                record.visionModelVersion = nil
            }
        }
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
