import SwiftUI

public struct AlbumPopOutAssetView: View {
    public let assetID: String
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var shareItems: [Any] = []
    @State private var isSharePresented: Bool = false
    @State private var isPreparingShare: Bool = false
    @State private var shareStatus: String? = nil

    public init(assetID: String) {
        self.assetID = assetID
    }

    public var body: some View {
        let palette = model.palette

        VStack(alignment: .leading, spacing: 14) {
            AlbumMediaPane(assetID: assetID, showsFocusButton: true)

            HStack(spacing: 12) {
                Button {
                    Task { await prepareAndPresentShare() }
                } label: {
                    Label(isPreparingShare ? "Preparing…" : "Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.copyButtonFill)
                .foregroundStyle(palette.copyIconColor)
                .disabled(isPreparingShare)

                if let shareStatus, !shareStatus.isEmpty {
                    Text(shareStatus)
                        .font(.caption2)
                        .foregroundStyle(palette.panelSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .onAppear {
            model.appendPoppedAsset(assetID)
        }
        .onDisappear {
            model.removePoppedAsset(assetID)
        }
#if canImport(UIKit)
        .sheet(isPresented: $isSharePresented) {
            AlbumShareSheet(items: shareItems)
        }
#endif
    }

    private func prepareAndPresentShare() async {
        guard !isPreparingShare else { return }
        let id = assetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        await MainActor.run {
            isPreparingShare = true
            shareStatus = nil
        }
        defer {
            Task { @MainActor in
                isPreparingShare = false
            }
        }

        guard let asset = await MainActor.run(body: { model.asset(for: id) }) else {
            await MainActor.run { shareStatus = "Share failed (asset missing)" }
            return
        }

        if asset.mediaType == .video {
            if let url = await model.requestVideoURL(assetID: id) {
                await MainActor.run {
                    shareItems = [url]
                    isSharePresented = true
                }
                return
            }
            await MainActor.run { shareStatus = "Share failed (video unavailable)" }
            return
        }

        let target = CGSize(width: 2048, height: 2048)
        guard let image = await model.requestThumbnail(assetID: id, targetSize: target, displayScale: displayScale) else {
            await MainActor.run { shareStatus = "Share failed (image unavailable)" }
            return
        }

#if canImport(UIKit)
        let data: Data
        let fileExt: String
        if let jpg = image.jpegData(compressionQuality: 0.92) {
            data = jpg
            fileExt = "jpg"
        } else if let png = image.pngData() {
            data = png
            fileExt = "png"
        } else {
            await MainActor.run { shareStatus = "Share failed (encode error)" }
            return
        }
#else
        await MainActor.run { shareStatus = "Share unavailable on this platform" }
        return
#endif

        let baseName: String = {
            let raw = (asset.fileName ?? "photo").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = raw.isEmpty ? "photo" : raw
            let noExt = (cleaned as NSString).deletingPathExtension
            let safe = noExt.isEmpty ? "photo" : noExt
            return safe.replacingOccurrences(of: "/", with: "_")
        }()
        let fileName = "\(baseName)_\(UUID().uuidString).\(fileExt)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try data.write(to: url, options: [.atomic])
            await MainActor.run {
                shareItems = [url]
                isSharePresented = true
            }
        } catch {
            await MainActor.run { shareStatus = "Share failed (write error)" }
        }
    }
}
