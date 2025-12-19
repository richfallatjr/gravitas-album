import Foundation

public struct AlbumVisionCoverage: Sendable, Hashable {
    public var totalAssets: Int
    public var computed: Int
    public var autofilled: Int
    public var failed: Int
    public var missing: Int
    public var computedPercent: Int
    public var updatedAt: Date?
    public var lastError: String?

    public init(
        totalAssets: Int = 0,
        computed: Int = 0,
        autofilled: Int = 0,
        failed: Int = 0,
        missing: Int = 0,
        computedPercent: Int = 0,
        updatedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.totalAssets = max(0, totalAssets)
        self.computed = max(0, computed)
        self.autofilled = max(0, autofilled)
        self.failed = max(0, failed)
        self.missing = max(0, missing)
        self.computedPercent = max(0, min(100, computedPercent))
        self.updatedAt = updatedAt
        self.lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

