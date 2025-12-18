import Foundation

public enum AlbumVisionSummaryUtils {
    public static func isPlaceholder(_ summary: String?) -> Bool {
        guard let summary else { return true }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lowered = trimmed.lowercased()
        if lowered == "unlabeled" { return true }
        if lowered.hasPrefix("unlabeled ") { return true }
        if lowered == "unknown" { return true }
        return false
    }

    public static func isMeaningfulComputed(_ record: AlbumSidecarRecord) -> Bool {
        guard record.vision.state == .computed else { return false }
        return !isPlaceholder(record.vision.summary)
    }
}
