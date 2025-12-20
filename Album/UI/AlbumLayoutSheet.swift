import SwiftUI

public struct AlbumLayoutSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var pendingHideID: String? = nil

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if curvedItems.isEmpty {
                    ContentUnavailableView("No items to show", systemImage: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AlbumCurvedLayoutView(
                        items: curvedItems,
                        mode: model.panelMode == .memories ? .memories : .recommends,
                        selectedID: $model.currentAssetID,
                        metrics: .init(baseRadius: 640, minRadius: 280, itemSize: CGSize(width: 190, height: 190), itemSpacing: 24),
                        pageLabel: model.panelMode == .memories ? model.memoryLabel : nil,
                        onPrevPage: model.panelMode == .memories && model.memoryPrevEnabled ? { model.memoryPrevPage() } : nil,
                        onNextPage: model.panelMode == .memories && model.memoryNextEnabled ? { model.memoryNextPage() } : nil,
                        onSelect: { id in
                            model.currentAssetID = id
                        },
                        onPopOut: { id in
                            if let item = model.createPoppedAssetItem(assetID: id) {
                                openWindow(value: AlbumPopOutPayload(itemID: item.id))
                            }
                        },
                        onHide: { id in
                            pendingHideID = id
                        },
                        onThumb: { feedback, id in
                            switch feedback {
                            case .up:
                                model.sendThumb(.up, assetID: id)
                            case .down:
                                model.sendThumb(.down, assetID: id)
                            }
                        },
                        thumbnailViewProvider: { item in
                            AnyView(AlbumCurvedThumbnailView(assetID: item.id))
                        }
                    )
                }
            }
            .padding(18)
            .navigationTitle(model.panelMode == .recommends ? "Recommends" : "Memories")
            .confirmationDialog(
                "Hide this image?",
                isPresented: Binding(
                    get: { pendingHideID != nil },
                    set: { isPresented in
                        if !isPresented { pendingHideID = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Hide", role: .destructive) {
                    guard let id = pendingHideID else { return }
                    pendingHideID = nil
                    model.hideAsset(id)
                }

                Button("Cancel", role: .cancel) {
                    pendingHideID = nil
                }
            } message: {
                Text("Are you sure you want to hide this from view? You will no longer see this image.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .black))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var layoutItems: [AlbumItem] {
        switch model.panelMode {
        case .recommends:
            return model.recommendItems
        case .memories:
            return model.memoryWindowItems
        }
    }

    private var curvedItems: [AlbumCurvedLayoutItem] {
        layoutItems.map { asset in
            AlbumCurvedLayoutItem(
                id: asset.id,
                title: model.semanticHandle(for: asset),
                subtitle: model.createdYearMonth(for: asset),
                isVideo: asset.mediaType == .video,
                duration: asset.duration
            )
        }
    }
}

private struct AlbumCurvedThumbnailView: View {
    let assetID: String

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale
    @State private var image: AlbumImage? = nil
    @State private var isLoadingImage: Bool = true

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        ZStack {
            if let image {
#if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
#elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
#endif
            } else {
                shape.fill(.black.opacity(0.06))
                if isLoadingImage {
                    ProgressView()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: assetID) {
            isLoadingImage = true
            image = nil
            image = await model.requestThumbnail(assetID: assetID, targetSize: CGSize(width: 360, height: 360), displayScale: displayScale)
            isLoadingImage = false
        }
    }
}
