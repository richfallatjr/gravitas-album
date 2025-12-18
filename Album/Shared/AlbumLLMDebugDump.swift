import Foundation

enum AlbumLLMDebugDump {
    private static let dirName = "LLMDebug"

    static var isEnabled: Bool {
#if DEBUG
        return ProcessInfo.processInfo.environment["ALBUM_LLM_DEBUG"] != "0"
#else
        return false
#endif
    }

    static func dumpPrompt(
        requestID: UUID,
        feedback: AlbumThumbFeedback,
        maxCandidates: Int,
        prompt: String
    ) {
        dump(
            kind: "prompt",
            requestID: requestID,
            feedback: feedback,
            maxCandidates: maxCandidates,
            content: prompt
        )
    }

    static func dumpResponse(
        requestID: UUID,
        feedback: AlbumThumbFeedback,
        maxCandidates: Int,
        responseDescription: String,
        stringCandidates: [String]
    ) {
        var body = "responseDescription:\n\(responseDescription)\n\n"
        body.append("stringCandidates.count=\(stringCandidates.count)\n\n")
        for (idx, candidate) in stringCandidates.enumerated() {
            body.append("----- stringCandidate[\(idx)] BEGIN -----\n")
            body.append(candidate)
            if !candidate.hasSuffix("\n") { body.append("\n") }
            body.append("----- stringCandidate[\(idx)] END -----\n\n")
        }

        dump(
            kind: "response",
            requestID: requestID,
            feedback: feedback,
            maxCandidates: maxCandidates,
            content: body
        )
    }

    static func dumpParsedResponse(
        requestID: UUID,
        feedback: AlbumThumbFeedback,
        maxCandidates: Int,
        parsed: AlbumRecResponse
    ) {
        var body = ""
        body.append("nextID: \(parsed.nextID ?? "null")\n")
        body.append("neighbors.count=\(parsed.neighbors.count)\n\n")

        for (idx, n) in parsed.neighbors.enumerated() {
            body.append("\(idx)\t\(n.id)\t\(String(format: "%.3f", n.similarity))\n")
        }

        dump(
            kind: "parsed",
            requestID: requestID,
            feedback: feedback,
            maxCandidates: maxCandidates,
            content: body
        )
    }

    static func dumpError(
        requestID: UUID,
        feedback: AlbumThumbFeedback,
        maxCandidates: Int,
        error: Error,
        prompt: String
    ) {
        let body = """
error:
\(String(describing: error))

prompt:
\(prompt)
"""

        dump(
            kind: "error",
            requestID: requestID,
            feedback: feedback,
            maxCandidates: maxCandidates,
            content: body
        )
    }

    private static func dump(
        kind: String,
        requestID: UUID,
        feedback: AlbumThumbFeedback,
        maxCandidates: Int,
        content: String
    ) {
        guard isEnabled else { return }

        let url = writeToDisk(
            kind: kind,
            requestID: requestID,
            feedback: feedback,
            maxCandidates: maxCandidates,
            content: content
        )

        let prefix = "[LLM DEBUG] \(feedback.rawValue) \(kind) maxCandidates=\(maxCandidates) chars=\(content.count)"
        if let url {
            print("\(prefix) wrote: \(url.path)")
        } else {
            print("\(prefix) (write failed)")
        }

        let snippet = consoleSnippet(for: content, maxChars: 12_000)
        print("----- \(prefix) BEGIN -----")
        print(snippet)
        print("----- \(prefix) END -----")
    }

    private static func writeToDisk(
        kind: String,
        requestID: UUID,
        feedback: AlbumThumbFeedback,
        maxCandidates: Int,
        content: String
    ) -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent(dirName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let stamp = safeTimestamp()
        let file = "\(stamp)_\(feedback.rawValue)_\(requestID.uuidString)_\(kind)_c\(maxCandidates).txt"
        let url = dir.appendingPathComponent(file, isDirectory: false)
        do {
            try Data(content.utf8).write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static func safeTimestamp() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let raw = fmt.string(from: Date())
        return raw.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static func consoleSnippet(for text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        if text.count <= maxChars { return text }

        let headCount = maxChars / 2
        let tailCount = maxChars - headCount

        let head = String(text.prefix(headCount))
        let tail = String(text.suffix(tailCount))
        return """
\(head)

… (truncated; totalChars=\(text.count)) …

\(tail)
"""
    }
}
