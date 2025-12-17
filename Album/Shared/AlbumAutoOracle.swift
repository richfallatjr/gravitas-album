import Foundation

public struct AlbumAutoOracle: AlbumOracle {
    private let heuristic = AlbumHeuristicOracle()

    public init() {}

    public func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
#if canImport(FoundationModels)
        if #available(visionOS 26.0, *) {
            let llmOutcome = await AlbumFoundationModelsOracle().recommendThumbUp(snapshot: snapshot, requestID: requestID)
            if llmOutcome.response != nil {
                return llmOutcome
            }

            let fallback = await heuristic.recommendThumbUp(snapshot: snapshot, requestID: requestID)
            return AlbumRecOutcome(
                backend: fallback.backend,
                response: fallback.response,
                errorDescription: fallback.errorDescription,
                note: llmOutcome.errorDescription
            )
        }

        let fallback = await heuristic.recommendThumbUp(snapshot: snapshot, requestID: requestID)
        return AlbumRecOutcome(
            backend: fallback.backend,
            response: fallback.response,
            errorDescription: fallback.errorDescription,
            note: "FoundationModels requires visionOS 26+"
        )
#else
        return await heuristic.recommendThumbUp(snapshot: snapshot, requestID: requestID)
#endif
    }

    public func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
#if canImport(FoundationModels)
        if #available(visionOS 26.0, *) {
            let llmOutcome = await AlbumFoundationModelsOracle().recommendThumbDown(snapshot: snapshot, requestID: requestID)
            if llmOutcome.response != nil {
                return llmOutcome
            }

            let fallback = await heuristic.recommendThumbDown(snapshot: snapshot, requestID: requestID)
            return AlbumRecOutcome(
                backend: fallback.backend,
                response: fallback.response,
                errorDescription: fallback.errorDescription,
                note: llmOutcome.errorDescription
            )
        }

        let fallback = await heuristic.recommendThumbDown(snapshot: snapshot, requestID: requestID)
        return AlbumRecOutcome(
            backend: fallback.backend,
            response: fallback.response,
            errorDescription: fallback.errorDescription,
            note: "FoundationModels requires visionOS 26+"
        )
#else
        return await heuristic.recommendThumbDown(snapshot: snapshot, requestID: requestID)
#endif
    }
}
