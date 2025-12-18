import Foundation
import Vision
import ImageIO
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct AlbumVisionResult: Sendable, Hashable {
    public let summary: String
    public let tags: [String]
    public let confidence: Float
    public let modelVersion: String

    public init(summary: String, tags: [String], confidence: Float, modelVersion: String) {
        self.summary = summary
        self.tags = tags
        self.confidence = confidence
        self.modelVersion = modelVersion
    }
}

public enum AlbumVisionSummarizer {
    public static let defaultMaxDimension: Int = 512

    public static func summarize(image: AlbumImage, maxDimension: Int = defaultMaxDimension) -> AlbumVisionResult? {
#if canImport(UIKit)
        if let cgImage = image.cgImage {
            return summarize(cgImage: cgImage)
        }
        if let data = image.jpegData(compressionQuality: 0.90) ?? image.pngData() {
            return summarize(imageData: data, maxDimension: maxDimension)
        }
        return nil
#elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            return nil
        }
        return summarize(cgImage: cgImage)
#else
        return nil
#endif
    }

    public static func summarize(imageData: Data, maxDimension: Int = defaultMaxDimension) -> AlbumVisionResult? {
        guard let cgImage = downsampleCGImage(data: imageData, maxDimension: max(1, maxDimension)) else { return nil }
        return summarize(cgImage: cgImage)
    }

    public static func summarize(cgImage: CGImage) -> AlbumVisionResult? {
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([classify])
        } catch {
            return nil
        }

        let results = classify.results ?? []
        guard !results.isEmpty else { return nil }

        var tags: [String] = []
        tags.reserveCapacity(8)

        var confidences: [Float] = []
        confidences.reserveCapacity(8)

        var seen = Set<String>()
        seen.reserveCapacity(8)

        for observation in results.sorted(by: { $0.confidence > $1.confidence }) {
            guard observation.confidence >= 0.10 else { continue }
            let cleaned = cleanLabel(observation.identifier)
            guard !cleaned.isEmpty else { continue }
            guard seen.insert(cleaned).inserted else { continue }
            tags.append(cleaned)
            confidences.append(observation.confidence)
            if tags.count >= 6 { break }
        }

        guard !tags.isEmpty else { return nil }

        let summary = tags.joined(separator: ", ")
        let avgConfidence = confidences.isEmpty ? 0.0 : (confidences.reduce(0, +) / Float(confidences.count))
        return AlbumVisionResult(
            summary: summary,
            tags: tags,
            confidence: max(0, min(1, avgConfidence)),
            modelVersion: "VNClassifyImageRequest"
        )
    }

    private static func cleanLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    private static func downsampleCGImage(data: Data, maxDimension: Int) -> CGImage? {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
