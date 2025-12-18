import Foundation

#if canImport(FoundationModels)
@_weakLinked import FoundationModels
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
    private static let maxUserPromptChars = 8_192
    private static let maximumResponseTokens = 512

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
        if !model.supportsLocale() {
            return AlbumRecOutcome(
                backend: .foundationModels,
                response: nil,
                errorDescription: "LLM unsupported language/locale (\(Locale.current.identifier))"
            )
        }

        if Task.isCancelled {
            AlbumLog.model.info("FoundationModels oracle cancelled requestID: \(requestID.uuidString, privacy: .public)")
            return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "Cancelled")
        }

        let system = Self.instructions(feedback: feedback)
        let prompt = Self.buildPrompt(snapshot: snapshot)
        if prompt.count > Self.maxUserPromptChars {
            return AlbumRecOutcome(
                backend: .foundationModels,
                response: nil,
                errorDescription: "LLM prompt too large (\(prompt.count) chars; max \(Self.maxUserPromptChars))"
            )
        }

        AlbumLLMDebugDump.dumpPrompt(
            requestID: requestID,
            feedback: feedback,
            maxCandidates: snapshot.candidates.count,
            prompt: "SYSTEM:\n\(system)\n\nPROMPT:\n\(prompt)\n"
        )

        do {
            AlbumLog.model.info("FoundationModels request: promptChars=\(prompt.count)")
            var options = GenerationOptions()
            options.maximumResponseTokens = Self.maximumResponseTokens

            let session = LanguageModelSession(model: model, instructions: system)
            let response = try await session.respond(to: prompt, options: options)
            let candidates = Self.stringFields(from: response)
            AlbumLLMDebugDump.dumpResponse(
                requestID: requestID,
                feedback: feedback,
                maxCandidates: snapshot.candidates.count,
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
                maxCandidates: snapshot.candidates.count,
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
                maxCandidates: snapshot.candidates.count,
                error: error,
                prompt: "SYSTEM:\n\(system)\n\nPROMPT:\n\(prompt)\n"
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
        let nextIDRule: String = {
            switch feedback {
            case .up:
                return "- nextID MUST be one of the candidate IDs and MUST NOT be in ALREADY_SEEN_IDS."
            case .down:
                return "- nextID MUST be null."
            }
        }()

        return """
You are a recommendation engine for Gravitas Album.
Return JSON only (no markdown, no code fences). Return a SINGLE JSON object on ONE line.

The user prompt provides:
- THUMBED_FILE: the focused item's filename
- THUMBED_VISION: the focused item's vision description
- ALREADY_SEEN_IDS: optional comma-separated list of candidate IDs (small integers)
- CANDIDATES (ID<TAB>FILE<TAB>VISION): tab-separated candidate lines

Response shape:
- nextID: String candidate ID (or null)
- neighbors: Array<{id: String candidate ID, similarity: Int rank (1..20)}>

Rules:
- The ONLY valid IDs are the LEFTMOST column in CANDIDATES (small integers like 0,1,2...). Never output filenames as IDs.
- Never output "..." or placeholder text.
\(nextIDRule)
- neighbors MUST contain the most conceptually related candidates to the thumbed item.
- neighbors MUST be ranked best→worst.
- Pick the top N neighbors (N ≤ 20) and rank them 1..N. Put that rank in similarity (1 = most similar).
- neighbors MUST NOT include nextID and MUST NOT contain duplicate ids.
- Return at most 20 neighbors.
"""
    }

    private static func buildPrompt(snapshot: AlbumOracleSnapshot) -> String {
        func field(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let alreadySeenIDs: [String] = snapshot.candidates.compactMap { c in
            snapshot.alreadySeenAssetIDs.contains(c.assetID) ? c.promptID : nil
        }

        let withoutIDs = "ALREADY_SEEN_IDS:"
        let withIDs = alreadySeenIDs.isEmpty ? withoutIDs : "ALREADY_SEEN_IDS: \(alreadySeenIDs.joined(separator: ","))"

        var lines: [String] = []
        lines.reserveCapacity(8 + snapshot.candidates.count)

        lines.append("THUMBED_FILE: \(field(snapshot.thumbedFileName))")
        lines.append("THUMBED_VISION: \(field(snapshot.thumbedVisionSummary))")
        lines.append(withoutIDs)
        lines.append("CANDIDATES (ID\\tFILE\\tVISION):")

        for c in snapshot.candidates {
            lines.append([
                field(c.promptID),
                field(c.fileName),
                field(c.visionSummary)
            ].joined(separator: "\t"))
        }

        var prompt = lines.joined(separator: "\n")
        if withIDs != withoutIDs {
            var linesWith = lines
            linesWith[2] = withIDs
            let candidate = linesWith.joined(separator: "\n")
            if candidate.count <= Self.maxUserPromptChars {
                prompt = candidate
            }
        }

        return prompt
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

            let rank = max(1.0, min(20.0, n.similarity))
            neighbors.append(.init(id: assetID, similarity: rank))
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
