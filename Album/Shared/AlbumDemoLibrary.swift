import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

public enum AlbumDemoLibrary {
    public static let assetIDPrefix = "demo-"

    public static func isDemoID(_ id: String) -> Bool {
        id.hasPrefix(assetIDPrefix)
    }

    public static func makeAssets(count: Int, now: Date = Date()) -> [AlbumAsset] {
        let capped = max(0, count)
        guard capped > 0 else { return [] }

        var out: [AlbumAsset] = []
        out.reserveCapacity(capped)

        let secondsPerStep: TimeInterval = 6 * 60 * 60
        let base = now.addingTimeInterval(-TimeInterval(capped - 1) * secondsPerStep)

        for idx in 0..<capped {
            let id = "\(assetIDPrefix)\(idx)"
            let isVideo = idx % 9 == 0
            let mediaType: AlbumMediaType = isVideo ? .video : .photo
            let isFavorite = idx % 7 == 0

            let created = base.addingTimeInterval(TimeInterval(idx) * secondsPerStep)
            let duration: TimeInterval? = isVideo ? TimeInterval(8 + (idx % 110)) : nil

            out.append(
                AlbumAsset(
                    localIdentifier: id,
                    mediaType: mediaType,
                    creationDate: created,
                    location: nil,
                    duration: duration,
                    isFavorite: isFavorite,
                    pixelWidth: isVideo ? 1920 : 3024,
                    pixelHeight: isVideo ? 1080 : 4032
                )
            )
        }

        return out
    }

    public static func demoIndex(for assetID: String) -> Int? {
        guard isDemoID(assetID) else { return nil }
        let suffix = assetID.dropFirst(assetIDPrefix.count)
        return Int(suffix)
    }

    public static func placeholderTitle(for assetID: String, mediaType: AlbumMediaType?) -> String {
        if let idx = demoIndex(for: assetID) {
            return "Demo \(mediaType == .video ? "Video" : "Photo") #\(idx + 1)"
        }
        return "Demo Item"
    }

    public static func requestThumbnail(localIdentifier: String, targetSize: CGSize, mediaType: AlbumMediaType?) -> AlbumImage? {
#if canImport(UIKit)
        let clamped = CGSize(width: max(1, targetSize.width), height: max(1, targetSize.height))

        let idx = demoIndex(for: localIdentifier) ?? 0
        let palette: [UIColor] = [
            UIColor(red: 1.00, green: 0.38, blue: 0.53, alpha: 1),
            UIColor(red: 0.66, green: 0.86, blue: 0.46, alpha: 1),
            UIColor(red: 1.00, green: 0.85, blue: 0.40, alpha: 1),
            UIColor(red: 0.47, green: 0.86, blue: 0.91, alpha: 1),
            UIColor(red: 0.67, green: 0.62, blue: 0.95, alpha: 1)
        ]

        let c0 = palette[abs(idx) % palette.count]
        let c1 = palette[(abs(idx) + 2) % palette.count]

        let renderer = UIGraphicsImageRenderer(size: clamped)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: clamped)

            let colors = [c0.cgColor, c1.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: rect.maxX, y: rect.maxY),
                    options: []
                )
            } else {
                ctx.cgContext.setFillColor(c0.cgColor)
                ctx.cgContext.fill(rect)
            }

            ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.10).cgColor)
            ctx.cgContext.fill(rect)

            let symbolName = (mediaType == .video) ? "video.fill" : "photo.fill"
            if let symbol = UIImage(systemName: symbolName) {
                let iconSide = min(rect.width, rect.height) * 0.28
                let iconRect = CGRect(
                    x: rect.midX - iconSide / 2,
                    y: rect.midY - iconSide / 2,
                    width: iconSide,
                    height: iconSide
                )
                symbol.withTintColor(.white.withAlphaComponent(0.90), renderingMode: .alwaysOriginal)
                    .draw(in: iconRect)
            }

            let title = placeholderTitle(for: localIdentifier, mediaType: mediaType)
            let fontSize = max(12, min(rect.width, rect.height) * 0.10)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
                    shadow.shadowOffset = CGSize(width: 0, height: 2)
                    shadow.shadowBlurRadius = 8
                    return shadow
                }()
            ]

            let inset: CGFloat = max(10, min(rect.width, rect.height) * 0.08)
            let textRect = rect.insetBy(dx: inset, dy: inset)
            (title as NSString).draw(in: textRect, withAttributes: attributes)
        }
#else
        return nil
#endif
    }
}

