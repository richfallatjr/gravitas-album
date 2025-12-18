import Foundation

public struct AlbumAutoOracle: AlbumOracle {
    public init() {}

    public func recommendThumbUp(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
#if canImport(FoundationModels)
        if #available(visionOS 26.0, *) {
            return await AlbumFoundationModelsOracle().recommendThumbUp(snapshot: snapshot, requestID: requestID)
        }

        return AlbumRecOutcome(
            backend: .foundationModels,
            response: nil,
            errorDescription: "FoundationModels requires visionOS 26+"
        )
#else
        return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "FoundationModels not available in this build")
#endif
    }

    public func recommendThumbDown(snapshot: AlbumOracleSnapshot, requestID: UUID) async -> AlbumRecOutcome {
#if canImport(FoundationModels)
        if #available(visionOS 26.0, *) {
            return await AlbumFoundationModelsOracle().recommendThumbDown(snapshot: snapshot, requestID: requestID)
        }

        return AlbumRecOutcome(
            backend: .foundationModels,
            response: nil,
            errorDescription: "FoundationModels requires visionOS 26+"
        )
#else
        return AlbumRecOutcome(backend: .foundationModels, response: nil, errorDescription: "FoundationModels not available in this build")
#endif
    }
}
