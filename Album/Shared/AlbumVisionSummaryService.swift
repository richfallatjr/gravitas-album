import Foundation
import Vision
import ImageIO
import CoreGraphics

public actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.value = max(0, value)
    }

    public func wait() async {
        if value > 0 {
            value -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            value += 1
        }
    }
}

public actor AlbumVisionSummaryService {
    public static let shared = AlbumVisionSummaryService(maxConcurrency: 6)

    private let semaphore: AsyncSemaphore
    private var cache: [String: String] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    public init(maxConcurrency: Int) {
        self.semaphore = AsyncSemaphore(value: maxConcurrency)
    }

    public func summaryForImageData(_ data: Data, cacheKey: String) async -> String? {
        if let hit = cache[cacheKey] { return hit }
        if let existing = inflight[cacheKey] { return await existing.value }

        let semaphore = semaphore
        let task = Task.detached(priority: .utility) {
            await semaphore.wait()
            let result = await Self.computeSummary(data: data)
            await semaphore.signal()
            return result
        }

        inflight[cacheKey] = task
        let result = await task.value
        inflight[cacheKey] = nil

        if let result, !result.isEmpty {
            cache[cacheKey] = result
        }

        return result
    }

    nonisolated private static func computeSummary(data: Data) async -> String? {
        guard let cgImage = downsampleCGImage(data: data, maxDimension: 384) else { return nil }

        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([classify])
        } catch {
            return nil
        }

        let results = classify.results ?? []
        guard !results.isEmpty else { return nil }

        var labels: [String] = []
        labels.reserveCapacity(8)

        var seen = Set<String>()
        seen.reserveCapacity(8)

        for observation in results.sorted(by: { $0.confidence > $1.confidence }) {
            guard observation.confidence >= 0.20 else { continue }
            let cleaned = cleanLabel(observation.identifier)
            guard !cleaned.isEmpty else { continue }
            guard seen.insert(cleaned).inserted else { continue }
            labels.append(cleaned)
            if labels.count >= 6 { break }
        }

        guard !labels.isEmpty else { return nil }
        return "vision: " + labels.joined(separator: ", ")
    }

    nonisolated private static func cleanLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    nonisolated private static func downsampleCGImage(data: Data, maxDimension: Int) -> CGImage? {
        guard maxDimension > 0 else { return nil }
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
