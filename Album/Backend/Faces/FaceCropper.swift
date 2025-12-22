import CoreGraphics
import Vision

enum FaceCropper {
    static func cropFace(
        from cgImage: CGImage,
        observation: VNFaceObservation,
        expandBy fraction: CGFloat
    ) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 1, h > 1 else { return nil }

        let bbox = observation.boundingBox
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        let rect = CGRect(
            x: bbox.origin.x * w,
            y: (1 - bbox.origin.y - bbox.height) * h,
            width: bbox.width * w,
            height: bbox.height * h
        )

        let expanded = rect.insetBy(dx: -rect.width * fraction, dy: -rect.height * fraction)

        let maxSide = max(expanded.width, expanded.height)
        let side = min(maxSide, min(w, h))
        guard side >= 2 else { return nil }

        let midX = expanded.midX
        let midY = expanded.midY

        var x = midX - side / 2
        var y = midY - side / 2

        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x + side > w { x = w - side }
        if y + side > h { y = h - side }

        let clamped = CGRect(x: x, y: y, width: side, height: side).integral
        guard clamped.width >= 2, clamped.height >= 2 else { return nil }

        return cgImage.cropping(to: clamped)
    }
}
