import Foundation

enum FaceDebugLog {
    static func match(faceID: String, distance: Float) {
        AlbumLog.faces.debug("Face match faceID=\(faceID, privacy: .public) dist=\(distance, privacy: .public)")
    }

    static func weakMatch(faceID: String, distance: Float) {
        AlbumLog.faces.debug("Face weak_match faceID=\(faceID, privacy: .public) dist=\(distance, privacy: .public)")
    }

    static func merged(into targetFaceID: String, from sourceFaceID: String, distance: Float) {
        AlbumLog.faces.debug(
            "Face merged into=\(targetFaceID, privacy: .public) from=\(sourceFaceID, privacy: .public) dist=\(distance, privacy: .public)"
        )
    }

    static func created(faceID: String, closestDistance: Float?) {
        if let closestDistance {
            AlbumLog.faces.debug("Face created faceID=\(faceID, privacy: .public) closest=\(closestDistance, privacy: .public)")
        } else {
            AlbumLog.faces.debug("Face created faceID=\(faceID, privacy: .public)")
        }
    }

    static func warning(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AlbumLog.faces.debug("Face warn: \(trimmed, privacy: .public)")
    }
}
