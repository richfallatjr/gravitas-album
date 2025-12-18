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

        var session: LanguageModelSession
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

        if Task.isCancelled {
            AlbumLog.model.info("FoundationModels oracle cancelled requestID: \(requestID.uuidString, privacy: .public)")
            return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "Cancelled")
        }

        let maxCandidates = snapshot.candidates.count
        let prompt = Self.buildPrompt(snapshot: snapshot, feedback: feedback, requestID: requestID, maxCandidates: maxCandidates)
        AlbumLLMDebugDump.dumpPrompt(requestID: requestID, feedback: feedback, maxCandidates: maxCandidates, prompt: prompt)

        do {
            AlbumLog.model.info("FoundationModels request: maxCandidates=\(maxCandidates) promptChars=\(prompt.count)")
            var options = GenerationOptions()
            options.sampling = .greedy
            options.temperature = 0
            options.maximumResponseTokens = 1200

            let response = try await session.respond(to: prompt, options: options)
            let candidates = Self.stringFields(from: response)
            AlbumLLMDebugDump.dumpResponse(
                requestID: requestID,
                feedback: feedback,
                maxCandidates: maxCandidates,
                responseDescription: String(describing: response),
                stringCandidates: candidates
            )

            if candidates.contains(where: Self.containsError) {
                let error = "LLM refused or returned an error"
                AlbumLog.model.info("FoundationModels error: \(error, privacy: .public)")
                return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: error)
            }

            guard let decoded = Self.decodeResponse(from: response, allowNextPick: feedback == .up) else {
                let error = "LLM JSON decode failed"
                AlbumLog.model.info("FoundationModels error: \(error, privacy: .public)")
                return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: error)
            }

            let mapped = Self.mapResponse(decoded, snapshot: snapshot, allowNextPick: feedback == .up)
            guard !mapped.neighbors.isEmpty else {
                let error = "LLM returned no usable neighbors"
                AlbumLog.model.info("FoundationModels error: \(error, privacy: .public)")
                return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: error)
            }

            AlbumLLMDebugDump.dumpParsedResponse(
                requestID: requestID,
                feedback: feedback,
                maxCandidates: maxCandidates,
                parsed: mapped
            )
            AlbumLog.model.info("FoundationModels success neighbors=\(mapped.neighbors.count) nextID=\(String(describing: mapped.nextID), privacy: .public)")
            return AlbumRecOutcome(backend: .foundationModels, response: mapped, errorDescription: nil)
        } catch {
            if error is CancellationError {
                AlbumLog.model.info("FoundationModels cancelled requestID: \(requestID.uuidString, privacy: .public)")
                return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "Cancelled")
            }

            AlbumLLMDebugDump.dumpError(
                requestID: requestID,
                feedback: feedback,
                maxCandidates: maxCandidates,
                error: error,
                prompt: prompt
            )

            let errorDescription: String
            if let generationError = error as? LanguageModelSession.GenerationError {
                switch generationError {
                case .exceededContextWindowSize(let context):
                    errorDescription = "LLM context too large: \(context.debugDescription)"
                case .unsupportedLanguageOrLocale(let context):
                    errorDescription = "LLM unsupported language/locale (\(Locale.current.identifier)): \(context.debugDescription)"
                case .assetsUnavailable(let context):
                    errorDescription = "LLM assets unavailable: \(context.debugDescription)"
                case .rateLimited(let context):
                    errorDescription = "LLM rate limited: \(context.debugDescription)"
                case .concurrentRequests(let context):
                    errorDescription = "LLM concurrent requests: \(context.debugDescription)"
                case .refusal(_, let context):
                    errorDescription = "LLM refusal: \(context.debugDescription)"
                default:
                    errorDescription = generationError.localizedDescription
                }
            } else {
                errorDescription = error.localizedDescription
            }

            AlbumLog.model.info("FoundationModels error: \(errorDescription, privacy: .public)")
            return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: errorDescription)
        }
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

    private static func instructions(feedback: AlbumThumbFeedback) -> String {
        let modeLine = (feedback == .up)
            ? "Goal: pick up to 20 conceptually similar neighbors; nextID is optional."
            : "Goal: pick up to 20 conceptually similar neighbors to suppress/repel; nextID must be null."

        let nextIDRule = (feedback == .up)
            ? "- nextID MAY be null, but if present it must be a candidate id."
            : "- nextID MUST be null."

        return """
You are a recommendation engine for a private media library.
\(modeLine)

The prompt provides lines in this exact format:
id<TAB>fileName<TAB>visionSummary

The first line is the anchor (id is "A").
All remaining lines are candidates.

You MUST output JSON only (no markdown, no code fences, no commentary).

Output schema (exact keys):
{"nextID": string or null, "neighbors":[{"id":string,"similarity":number}, ...]}

Rules:
- neighbors MUST contain up to 20 items, ordered from most similar to least similar.
- similarity MUST be in [0, 1].
- Every id MUST be one of the candidate ids provided.
- Do not repeat ids.
- Do not include the anchor id ("A").
\(nextIDRule)
"""
    }

    private static func buildPrompt(snapshot: AlbumOracleSnapshot, feedback: AlbumThumbFeedback, requestID: UUID, maxCandidates: Int) -> String {
        let cap = max(0, min(snapshot.candidates.count, maxCandidates))
        let candidates = snapshot.candidates.prefix(cap)

        func field(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let anchorLine = [
            "A",
            field(snapshot.thumbedFileName),
            field(snapshot.thumbedVisionSummary)
        ].joined(separator: "\t")

        var candidateLines: [String] = []
        candidateLines.reserveCapacity(cap)

        for c in candidates {
            candidateLines.append([
                field(c.promptID),
                field(c.fileName),
                field(c.visionSummary)
            ].joined(separator: "\t"))
        }

        return ([anchorLine] + candidateLines).joined(separator: "\n")
    }

    private static func decodeResponse(from reply: Any, allowNextPick: Bool) -> AlbumRecResponse? {
        decodeJSON(AlbumRecResponse.self, from: reply)
    }

    private static func mapResponse(_ response: AlbumRecResponse, snapshot: AlbumOracleSnapshot, allowNextPick: Bool) -> AlbumRecResponse {
        let byPromptID = Dictionary(uniqueKeysWithValues: snapshot.candidates.map { ($0.promptID, $0) })
        let anchorAssetID = snapshot.thumbedAssetID.trimmingCharacters(in: .whitespacesAndNewlines)

        func assetID(forPromptID raw: String?) -> String? {
            guard let raw else { return nil }
            let promptID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !promptID.isEmpty else { return nil }
            guard let candidate = byPromptID[promptID] else { return nil }
            let assetID = candidate.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !assetID.isEmpty else { return nil }
            guard assetID != anchorAssetID else { return nil }
            return assetID
        }

        let nextAssetID: String? = {
            guard allowNextPick else { return nil }
            guard let mapped = assetID(forPromptID: response.nextID) else { return nil }
            guard !snapshot.alreadySeenAssetIDs.contains(mapped) else { return nil }
            return mapped
        }()

        var seenAssetIDs = Set<String>()
        seenAssetIDs.insert(anchorAssetID)
        if let nextAssetID { seenAssetIDs.insert(nextAssetID) }

        var neighbors: [AlbumRecNeighbor] = []
        neighbors.reserveCapacity(20)

        for n in response.neighbors {
            if neighbors.count >= 20 { break }
            guard let assetID = assetID(forPromptID: n.id) else { continue }
            guard !seenAssetIDs.contains(assetID) else { continue }
            seenAssetIDs.insert(assetID)

            let similarity = max(0.0, min(1.0, n.similarity))
            neighbors.append(.init(id: assetID, similarity: similarity))
        }

        return AlbumRecResponse(nextID: nextAssetID, neighbors: neighbors)
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
