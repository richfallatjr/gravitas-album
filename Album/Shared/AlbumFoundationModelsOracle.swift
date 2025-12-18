import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(visionOS 26.0, *)
public struct AlbumFoundationModelsOracle: AlbumOracle {
    public init() {}

    public func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
        await AlbumFoundationModelsOracleEngine.shared.recommend(snapshot: snapshot, requestID: requestID, feedback: .up)
    }

    public func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
        await AlbumFoundationModelsOracleEngine.shared.recommend(snapshot: snapshot, requestID: requestID, feedback: .down)
    }
}

@available(visionOS 26.0, *)
actor AlbumFoundationModelsOracleEngine {
    static let shared = AlbumFoundationModelsOracleEngine()

    private var thumbUpSession: LanguageModelSession?
    private var thumbDownSession: LanguageModelSession?

    private var isResponding: Bool = false
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    func recommend(snapshot: AlbumOracleSnapshot, requestID: UUID, feedback: AlbumThumbFeedback) async -> AlbumRecOutcome {
        await acquireResponseLock()
        defer { releaseResponseLock() }

        if Task.isCancelled {
            AlbumLog.model.info("FoundationModels oracle cancelled before start requestID: \(requestID.uuidString, privacy: .public)")
            return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "Cancelled")
        }

        AlbumLog.model.info("FoundationModels oracle start: \(feedback.rawValue, privacy: .public) requestID: \(requestID.uuidString, privacy: .public) candidates: \(snapshot.candidates.count)")
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            AlbumLog.model.info("FoundationModels available")
            break
        case .unavailable(let reason):
            AlbumLog.model.info("FoundationModels unavailable: \(String(describing: reason), privacy: .public)")
            return AlbumRecOutcome(
                backend: .foundationModels,
                response: nil,
                errorDescription: "FoundationModels unavailable: \(reason)"
            )
        }

        let session: LanguageModelSession
        switch feedback {
        case .up:
            if let existing = thumbUpSession {
                session = existing
            } else {
                let created = LanguageModelSession(model: model, instructions: Self.instructions(feedback: feedback))
                thumbUpSession = created
                session = created
            }
        case .down:
            if let existing = thumbDownSession {
                session = existing
            } else {
                let created = LanguageModelSession(model: model, instructions: Self.instructions(feedback: feedback))
                thumbDownSession = created
                session = created
            }
        }

        let candidateCounts = Self.candidateBudgets(total: snapshot.candidates.count)
        var lastError: String? = nil

        for maxCandidates in candidateCounts {
            if Task.isCancelled {
                AlbumLog.model.info("FoundationModels oracle cancelled requestID: \(requestID.uuidString, privacy: .public)")
                return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "Cancelled")
            }

            let prompt = Self.buildPrompt(snapshot: snapshot, feedback: feedback, requestID: requestID, maxCandidates: maxCandidates)

            do {
                AlbumLog.model.info("FoundationModels request: maxCandidates=\(maxCandidates) promptChars=\(prompt.count)")
                var options = GenerationOptions()
                options.sampling = .greedy
                options.temperature = 0
                options.maximumResponseTokens = 1200

                let response = try await session.respond(to: prompt, options: options)
                let candidates = Self.stringFields(from: response)
                if candidates.contains(where: Self.containsError) {
                    lastError = "LLM refused or returned an error"
                    AlbumLog.model.info("FoundationModels refusal detected; retrying with smaller candidate budget")
                    continue
                }

                guard let decoded = Self.decodeResponse(from: response, allowNextPick: feedback == .up) else {
                    lastError = "LLM JSON decode failed"
                    AlbumLog.model.info("FoundationModels decode failed; retrying with smaller candidate budget")
                    continue
                }

                let pruned = Self.prune(response: decoded, snapshot: snapshot, allowNextPick: feedback == .up)
                guard !pruned.neighbors.isEmpty else {
                    lastError = "LLM returned no usable neighbors"
                    AlbumLog.model.info("FoundationModels returned no usable neighbors; retrying with smaller candidate budget")
                    continue
                }

                AlbumLog.model.info("FoundationModels success neighbors=\(pruned.neighbors.count) nextID=\(String(describing: pruned.nextID), privacy: .public)")
                return AlbumRecOutcome(backend: .foundationModels, response: pruned, errorDescription: nil)
            } catch {
                if let generationError = error as? LanguageModelSession.GenerationError {
                    switch generationError {
                    case .exceededContextWindowSize(let context):
                        lastError = "LLM context too large: \(context.debugDescription)"
                        AlbumLog.model.info("FoundationModels context too large; retrying with smaller candidate budget")
                        continue
                    case .assetsUnavailable(let context):
                        lastError = "LLM assets unavailable: \(context.debugDescription)"
                    case .rateLimited(let context):
                        lastError = "LLM rate limited: \(context.debugDescription)"
                    case .concurrentRequests(let context):
                        lastError = "LLM concurrent requests: \(context.debugDescription)"
                    case .refusal(_, let context):
                        lastError = "LLM refusal: \(context.debugDescription)"
                    default:
                        lastError = generationError.localizedDescription
                    }
                } else if error is CancellationError {
                    lastError = "Cancelled"
                    AlbumLog.model.info("FoundationModels cancelled requestID: \(requestID.uuidString, privacy: .public)")
                    return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: lastError)
                } else {
                    lastError = error.localizedDescription
                }
                if let lastError {
                    AlbumLog.model.info("FoundationModels error: \(lastError, privacy: .public)")
                }
            }
        }

        return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: lastError ?? "LLM failed")
    }

    private func acquireResponseLock() async {
        if !isResponding {
            isResponding = true
            return
        }

        await withCheckedContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    private func releaseResponseLock() {
        if !responseWaiters.isEmpty {
            responseWaiters.removeFirst().resume()
            return
        }
        isResponding = false
    }

    private static func candidateBudgets(total: Int) -> [Int] {
        let capped = max(0, total)
        if capped <= 120 { return [capped] }
        if capped <= 240 { return [capped, 120] }
        return [min(capped, 320), 200, 120]
    }

    private static func instructions(feedback: AlbumThumbFeedback) -> String {
        let modeLine = (feedback == .up)
            ? "Goal: pick 20 conceptually similar neighbors; also pick nextID for a good next anchor."
            : "Goal: pick 20 conceptually similar neighbors to suppress/repel; nextID must be null."

        return """
You are a recommendation engine for a private photo/video library.
\(modeLine)

You MUST output JSON only (no markdown, no code fences, no commentary).

Output schema (exact keys):
{"nextID": string or null, "neighbors":[{"id":string,"similarity":number}, ...]}

Rules:
- neighbors MUST contain up to 20 items, ordered from most similar to least similar.
- similarity MUST be in [0, 1].
- Every id MUST be one of the candidate ids provided.
- Do not repeat ids.
- Do not include the anchor id.
- If feedback is DOWN: nextID MUST be null.
- If feedback is UP: nextID MAY be null, but if present it must be a candidate id and must not be in alreadySeenIDs.
"""
    }

    private static func buildPrompt(snapshot: AlbumOracleSnapshot, feedback: AlbumThumbFeedback, requestID: UUID, maxCandidates: Int) -> String {
        let cap = max(0, min(snapshot.candidates.count, maxCandidates))
        let candidates = snapshot.candidates.prefix(cap)

        func safe(_ value: String?, fallback: String = "-") -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? fallback : trimmed
        }

        func title(mediaType: AlbumMediaType, createdYearMonth: String?, locationBucket: String?) -> String {
            var parts: [String] = []
            parts.reserveCapacity(3)

            let datePart = safe(createdYearMonth, fallback: "Unknown")
            if datePart != "-" {
                parts.append(datePart)
            }

            parts.append(mediaType == .video ? "Video" : "Photo")

            let loc = safe(locationBucket)
            if loc != "-" {
                parts.append(loc)
            }

            return parts.joined(separator: " • ")
        }

        func sanitizeText(_ text: String, maxLen: Int) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > maxLen else { return trimmed }
            return String(trimmed.prefix(maxLen))
        }

        let anchorLine = [
            snapshot.thumbedAssetID,
            title(mediaType: snapshot.thumbedMediaType, createdYearMonth: snapshot.thumbedCreatedYearMonth, locationBucket: snapshot.thumbedLocationBucket),
            sanitizeText(snapshot.thumbedVisionSummary, maxLen: 160)
        ].joined(separator: "\t")

        let seen = snapshot.alreadySeenKeys.sorted()
        let seenBlock = seen.prefix(80).joined(separator: ",")

        var candidateLines: [String] = []
        candidateLines.reserveCapacity(cap)

        for c in candidates {
            candidateLines.append([
                c.key,
                title(mediaType: c.mediaType, createdYearMonth: c.createdYearMonth, locationBucket: c.locationBucket),
                sanitizeText(c.visionSummary, maxLen: 140)
            ].joined(separator: "\t"))
        }

        return """
RequestID: \(requestID.uuidString)
Feedback: \(feedback.rawValue)

Anchor (id\\ttitle\\tvisionSummary):
\(anchorLine)

alreadySeenIDs (comma-separated, may be partial): \(seenBlock)

Candidates (id\\ttitle\\tvisionSummary):
\(candidateLines.joined(separator: "\n"))
"""
    }

    private static func decodeResponse(from reply: Any, allowNextPick: Bool) -> AlbumRecResponse? {
        decodeJSON(AlbumRecResponse.self, from: reply)
    }

    private static func prune(response: AlbumRecResponse, snapshot: AlbumOracleSnapshot, allowNextPick: Bool) -> AlbumRecResponse {
        let validIDs = Set(snapshot.candidates.map(\.key))
        let anchor = snapshot.thumbedAssetID

        let nextID: String? = {
            guard allowNextPick else { return nil }
            guard let raw = response.nextID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            guard raw != anchor else { return nil }
            guard validIDs.contains(raw) else { return nil }
            guard !snapshot.alreadySeenKeys.contains(raw) else { return nil }
            return raw
        }()

        var seen = Set<String>()
        seen.insert(anchor)
        if let nextID { seen.insert(nextID) }

        var neighbors: [AlbumRecNeighbor] = []
        neighbors.reserveCapacity(20)

        for n in response.neighbors {
            if neighbors.count >= 20 { break }
            let id = n.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard validIDs.contains(id) else { continue }
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            let sim = max(0.0, min(1.0, n.similarity))
            neighbors.append(.init(id: id, similarity: sim))
        }

        return AlbumRecResponse(nextID: nextID, neighbors: neighbors)
    }

    private static func containsError(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("ERROR:") { return true }

        let lower = trimmed.lowercased()
        let refusalHints = [
            "cannot fulfill",
            "cannot comply",
            "cannot assist",
            "cannot help",
            "i apologize, but i cannot",
            "sorry, i cannot",
            "sorry, i can't",
            "as an llm developed by apple"
        ]
        return refusalHints.contains(where: { lower.contains($0) })
    }

    private static func stripJSONFences(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = trimmed.range(of: "```json", options: .caseInsensitive),
           let end = trimmed.range(of: "```", range: start.upperBound..<trimmed.endIndex) {
            let inner = trimmed[start.upperBound..<end.lowerBound]
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.hasPrefix("```") {
            let afterFence = trimmed.index(trimmed.startIndex, offsetBy: 3)
            if let end = trimmed.range(of: "```", range: afterFence..<trimmed.endIndex) {
                let inner = trimmed[afterFence..<end.lowerBound]
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    private static func flattenStrings(from value: Any, depth: Int = 0) -> [String] {
        if let str = value as? String { return [str] }
        if let arr = value as? [String] { return arr }
        if depth >= 5 { return [] }

        var results: [String] = []
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            results.append(contentsOf: flattenStrings(from: child.value, depth: depth + 1))
            if results.count >= 24 { break }
        }
        return results
    }

    private static func stringFields(from reply: Any) -> [String] {
        var results: [String] = []

        if let str = reply as? String { results.append(str) }
        if let desc = (reply as? CustomStringConvertible)?.description { results.append(desc) }

        let mirror = Mirror(reflecting: reply)
        for child in mirror.children {
            let key = child.label?.lowercased() ?? ""
            if key.contains("content") || key.contains("rawcontent") || key.contains("output") || key.contains("text") {
                if let str = child.value as? String {
                    results.append(str)
                } else if let arr = child.value as? [String] {
                    results.append(contentsOf: arr)
                }
            }
            if results.count >= 24 { break }
        }

        if results.isEmpty {
            results = flattenStrings(from: reply)
        }

        return Array(results.prefix(24))
    }

    private static func extractJSONObjectString(from text: String) -> String {
        let trimmed = stripJSONFences(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.first == "{", trimmed.last == "}" {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }

        return String(trimmed[start...end])
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from reply: Any) -> T? {
        for candidate in stringFields(from: reply) {
            let raw = extractJSONObjectString(from: candidate)
            guard let data = raw.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
        }
        return nil
    }
}
#else
public struct AlbumFoundationModelsOracle: AlbumOracle {
    public init() {}

    public func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
        AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "FoundationModels not available in this build")
    }

    public func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
        AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "FoundationModels not available in this build")
    }
}
#endif
