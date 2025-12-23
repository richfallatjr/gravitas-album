import Contacts
import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct ContactLabelReport: Sendable, Hashable {
    public var contactsEnumerated: Int
    public var contactsWithImages: Int
    public var contactsWithFaceDetected: Int
    public var embeddingsComputed: Int
    public var matchedClusters: Int
    public var clustersLabeled: Int
    public var clustersSkipped: Int
    public var failures: Int
    public var finishedAt: Date
    public var errorDescription: String?

    public init(
        contactsEnumerated: Int = 0,
        contactsWithImages: Int = 0,
        contactsWithFaceDetected: Int = 0,
        embeddingsComputed: Int = 0,
        matchedClusters: Int = 0,
        clustersLabeled: Int = 0,
        clustersSkipped: Int = 0,
        failures: Int = 0,
        finishedAt: Date = Date(),
        errorDescription: String? = nil
    ) {
        self.contactsEnumerated = max(0, contactsEnumerated)
        self.contactsWithImages = max(0, contactsWithImages)
        self.contactsWithFaceDetected = max(0, contactsWithFaceDetected)
        self.embeddingsComputed = max(0, embeddingsComputed)
        self.matchedClusters = max(0, matchedClusters)
        self.clustersLabeled = max(0, clustersLabeled)
        self.clustersSkipped = max(0, clustersSkipped)
        self.failures = max(0, failures)
        self.finishedAt = finishedAt
        self.errorDescription = errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public actor ContactClusterLabeler {
    public struct Configuration: Sendable, Hashable {
        public var thumbnailMaxDimension: Int
        public var cropExpandFraction: CGFloat
        public var minFaceSidePixels: Int

        public init(
            thumbnailMaxDimension: Int = 512,
            cropExpandFraction: CGFloat = 0.12,
            minFaceSidePixels: Int = 60
        ) {
            self.thumbnailMaxDimension = max(64, thumbnailMaxDimension)
            self.cropExpandFraction = max(0, cropExpandFraction)
            self.minFaceSidePixels = max(1, minFaceSidePixels)
        }
    }

    private let faceIndexStore: FaceIndexStore
    private let config: Configuration

    public init(faceIndexStore: FaceIndexStore, config: Configuration = Configuration()) {
        self.faceIndexStore = faceIndexStore
        self.config = config
    }

    public func labelClustersFromContacts(
        maxContacts: Int = 200,
        matchThreshold: Float,
        renameOnlyIfUnlabeled: Bool = true
    ) async -> ContactLabelReport {
        let start = Date()
        var report = ContactLabelReport(finishedAt: start)

        do {
            try await ContactsAuth.requestAccessIfNeeded()
        } catch {
            report.errorDescription = error.localizedDescription
            report.finishedAt = Date()
            return report
        }

        let contacts: [CNContact]
        do {
            contacts = try fetchContactsWithImages(limit: maxContacts, report: &report)
        } catch {
            report.errorDescription = error.localizedDescription
            report.finishedAt = Date()
            return report
        }

        for contact in contacts {
            if Task.isCancelled { break }

            guard let imageData = contact.thumbnailImageData, !imageData.isEmpty else { continue }
            guard let name = preferredDisplayName(for: contact) else {
                report.clustersSkipped += 1
                continue
            }

            guard let cgImage = downsampleCGImage(data: imageData, maxDimension: config.thumbnailMaxDimension) else {
                report.failures += 1
                continue
            }

            let faces: [VNFaceObservation]
            do {
                faces = try detectFaces(in: cgImage)
            } catch {
                report.failures += 1
                continue
            }

            guard let bestFace = faces.max(by: { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
            }) else {
                continue
            }

            report.contactsWithFaceDetected += 1

            let facePixelW = CGFloat(cgImage.width) * bestFace.boundingBox.width
            let facePixelH = CGFloat(cgImage.height) * bestFace.boundingBox.height
            if Int(min(facePixelW, facePixelH)) < config.minFaceSidePixels {
                report.clustersSkipped += 1
                continue
            }

            guard let crop = FaceCropper.cropFace(from: cgImage, observation: bestFace, expandBy: config.cropExpandFraction) else {
                report.failures += 1
                continue
            }

            let featurePrintData: Data
            do {
                featurePrintData = try generateFeaturePrintData(for: crop)
            } catch {
                report.failures += 1
                continue
            }

            report.embeddingsComputed += 1

            guard let match = await faceIndexStore.nearestFaceMatch(for: featurePrintData) else { continue }
            guard match.distance < matchThreshold else { continue }
            report.matchedClusters += 1

            let didLabel = await faceIndexStore.setClusterLabelFromContact(
                faceID: match.faceID,
                contactID: contact.identifier,
                displayName: name,
                renameOnlyIfUnlabeled: renameOnlyIfUnlabeled
            )

            if didLabel {
                report.clustersLabeled += 1
            } else {
                report.clustersSkipped += 1
            }

            if report.clustersLabeled.isMultiple(of: 8) {
                await Task.yield()
            }
        }

        report.finishedAt = Date()
        report.errorDescription = nil
        _ = start
        return report
    }

    // MARK: Contacts

    private func fetchContactsWithImages(limit: Int, report: inout ContactLabelReport) throws -> [CNContact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true

        var out: [CNContact] = []
        out.reserveCapacity(min(256, max(0, limit)))

        var enumerated = 0
        try store.enumerateContacts(with: request) { c, stop in
            enumerated += 1
            guard c.imageDataAvailable, c.thumbnailImageData != nil else { return }
            out.append(c)
            if out.count >= limit {
                stop.pointee = true
            }
        }

        report.contactsEnumerated = enumerated
        report.contactsWithImages = out.count
        return out
    }

    private func preferredDisplayName(for contact: CNContact) -> String? {
        let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return family.isEmpty ? nil : family
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
            throw ContactClusterLabelerError.featurePrintMissing
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
}

private enum ContactClusterLabelerError: Error {
    case featurePrintMissing
}
