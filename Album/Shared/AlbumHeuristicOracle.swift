import Foundation

public struct AlbumHeuristicOracle: AlbumOracle {
    public init() {}

    public func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
        AlbumRecOutcome(backend: .heuristic, response: buildResponse(snapshot: snapshot, allowNextPick: true), errorDescription: nil)
    }

    public func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
        AlbumRecOutcome(backend: .heuristic, response: buildResponse(snapshot: snapshot, allowNextPick: false), errorDescription: nil)
    }

    private func buildResponse(snapshot: AlbumOracleSnapshot, allowNextPick: Bool) -> AlbumRecResponse {
        struct Scored: Sendable {
            let key: String
            let score: Double
        }

        let thumbTokens = tokenize(snapshot.thumbedVisionSummary)

        var scored: [Scored] = []
        scored.reserveCapacity(snapshot.candidates.count)

        for c in snapshot.candidates {
            let base = jaccardSimilarity(thumbTokens: thumbTokens, candidateText: c.visionSummary)

            var bonus: Double = 0
            if c.mediaType == snapshot.thumbedMediaType { bonus += 0.15 }
            if let a = c.createdYearMonth, let b = snapshot.thumbedCreatedYearMonth, a == b { bonus += 0.10 }
            if let a = c.locationBucket, let b = snapshot.thumbedLocationBucket, a == b { bonus += 0.10 }

            let score = min(1.0, base + bonus)
            scored.append(.init(key: c.key, score: score))
        }

        scored.sort { $0.score > $1.score }

        let nextID: String?
        if allowNextPick {
            nextID = scored.first(where: { !snapshot.alreadySeenKeys.contains($0.key) })?.key
        } else {
            nextID = nil
        }

        var neighbors: [AlbumRecNeighbor] = []
        neighbors.reserveCapacity(20)

        for s in scored {
            if neighbors.count >= 20 { break }
            if s.key == nextID { continue }
            neighbors.append(.init(id: s.key, similarity: s.score))
        }

        return AlbumRecResponse(nextID: nextID, neighbors: neighbors)
    }

    private func tokenize(_ text: String) -> Set<String> {
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

    private func jaccardSimilarity(thumbTokens: Set<String>, candidateText: String) -> Double {
        guard !thumbTokens.isEmpty else { return 0 }
        let candidateTokens = tokenize(candidateText)
        guard !candidateTokens.isEmpty else { return 0 }
        let intersection = thumbTokens.intersection(candidateTokens).count
        if intersection == 0 { return 0 }
        let union = thumbTokens.union(candidateTokens).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}
