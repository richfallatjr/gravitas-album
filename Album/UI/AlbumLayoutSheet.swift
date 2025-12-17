import SwiftUI

public struct AlbumLayoutSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

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
                        selectedID: $model.currentAssetID,
                        mode: model.panelMode,
                        pageLabel: model.panelMode == .memories ? model.memoryLabel : nil,
                        onPrev: model.panelMode == .memories ? { model.memoryPrevPage() } : nil,
                        onNext: model.panelMode == .memories ? { model.memoryNextPage() } : nil,
                        prevEnabled: model.panelMode == .memories ? model.memoryPrevEnabled : true,
                        nextEnabled: model.panelMode == .memories ? model.memoryNextEnabled : true,
                        thumbnailProvider: { id in
                            await model.assetProvider.requestThumbnail(localIdentifier: id, targetSize: CGSize(width: 220, height: 220))
                        },
                        onSelect: { id in
                            model.currentAssetID = id
                        },
                        onPopOut: { id in
                            openWindow(value: AlbumPopOutPayload(assetID: id))
                            model.appendPoppedAsset(id)
                        },
                        onThumbUp: { id in
                            model.sendThumb(.up, assetID: id)
                        },
                        onThumbDown: { id in
                            model.sendThumb(.down, assetID: id)
                        },
                        onHide: { id in
                            model.hideAsset(id)
                        }
                    )
                }
            }
            .padding(18)
            .navigationTitle(model.panelMode == .recommends ? "Recommends" : "Memories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
                mediaType: asset.mediaType,
                title: model.semanticHandle(for: asset),
                isFavorite: asset.isFavorite
            )
        }
    }
}
