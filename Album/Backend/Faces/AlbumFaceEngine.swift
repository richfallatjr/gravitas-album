import CoreGraphics
import Foundation
import ImageIO
import Vision

public actor AlbumFaceEngine {
    public struct Configuration: Sendable, Hashable {
        public var thumbnailMaxDimension: Int
        public var cropExpandFraction: CGFloat
        public var minFaceSidePixels: Int
        public var maxFacesPerAsset: Int

        public init(
            thumbnailMaxDimension: Int = 768,
            cropExpandFraction: CGFloat = 0.12,
            minFaceSidePixels: Int = 60,
            maxFacesPerAsset: Int = 12
        ) {
            self.thumbnailMaxDimension = max(64, thumbnailMaxDimension)
            self.cropExpandFraction = max(0, cropExpandFraction)
            self.minFaceSidePixels = max(1, minFaceSidePixels)
            self.maxFacesPerAsset = max(1, maxFacesPerAsset)
        }
    }

    private let sidecarStore: AlbumSidecarStore
    private let indexStore: FaceIndexStore
    private let config: Configuration

    public init(
        sidecarStore: AlbumSidecarStore,
        indexStore: FaceIndexStore,
        config: Configuration = Configuration()
    ) {
        self.sidecarStore = sidecarStore
        self.indexStore = indexStore
        self.config = config
    }

    public func ensureFacesComputed(
        assetID: String,
        thumbnailData: Data,
        source: AlbumSidecarSource
    ) async -> [String] {
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }

        let key = AlbumSidecarKey(source: source, id: id)
        if let record = await sidecarStore.load(key), record.faces.state == .computed {
            return record.faces.faceIDs
        }

        let now = Date()

        guard let cgImage = downsampleCGImage(data: thumbnailData, maxDimension: config.thumbnailMaxDimension) else {
            await sidecarStore.setFacesFailed(key, error: "Face thumbnail decode failed", attemptedAt: now)
            return []
        }

        let faces: [VNFaceObservation]
        do {
            faces = try detectFaces(in: cgImage)
        } catch {
            await sidecarStore.setFacesFailed(key, error: "Face detect failed: \(error.localizedDescription)", attemptedAt: now)
            return []
        }

        let detectedCount = faces.count
        if detectedCount == 0 {
            await indexStore.record(assetID: id, faceIDs: [])
            await sidecarStore.setFacesComputed(key, detectedCount: 0, faceIDs: [], computedAt: now)
            return []
        }

        var faceIDs: [String] = []
        faceIDs.reserveCapacity(min(detectedCount, config.maxFacesPerAsset))

        let maxFaces = max(1, config.maxFacesPerAsset)
        let sortedFaces = faces
            .sorted(by: { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) > (rhs.boundingBox.width * rhs.boundingBox.height)
            })
            .prefix(maxFaces)

        for face in sortedFaces {
            let facePixelW = CGFloat(cgImage.width) * face.boundingBox.width
            let facePixelH = CGFloat(cgImage.height) * face.boundingBox.height
            if Int(min(facePixelW, facePixelH)) < config.minFaceSidePixels {
                continue
            }

            guard let crop = FaceCropper.cropFace(from: cgImage, observation: face, expandBy: config.cropExpandFraction) else {
                continue
            }

            let featurePrintData: Data
            do {
                featurePrintData = try generateFeaturePrintData(for: crop)
            } catch {
                FaceDebugLog.warning("FeaturePrint failed asset=\(id) error=\(error.localizedDescription)")
                continue
            }

            let match = await indexStore.matchOrCreateFaceID(for: featurePrintData)
            faceIDs.append(match.faceID)
        }

        let uniqueFaceIDs = normalizeFaceIDs(faceIDs)
        await indexStore.record(assetID: id, faceIDs: uniqueFaceIDs)
        await sidecarStore.setFacesComputed(key, detectedCount: detectedCount, faceIDs: uniqueFaceIDs, computedAt: now)
        return uniqueFaceIDs
    }

    // MARK: Vision

    private func detectFaces(in cgImage: CGImage) throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return (request.results as? [VNFaceObservation]) ?? []
    }

    private func generateFeaturePrintData(for cgImage: CGImage) throws -> Data {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let obs = (request.results as? [VNFeaturePrintObservation])?.first else {
            throw AlbumFaceEngineError.featurePrintMissing
        }

        return try NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
    }

    private func downsampleCGImage(data: Data, maxDimension: Int) -> CGImage? {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxDimension),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func normalizeFaceIDs(_ faceIDs: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(faceIDs.count)

        var seen: Set<String> = []
        seen.reserveCapacity(faceIDs.count)

        for raw in faceIDs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }

        out.sort()
        return out
    }
}

private enum AlbumFaceEngineError: Error {
    case featurePrintMissing
}
