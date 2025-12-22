import Photos
import SwiftUI

public struct AlbumFileBrowserSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    public let query: AlbumQuery

    @StateObject private var vm = AlbumFileBrowserViewModel()

    private let columns: [GridItem] = Array(repeating: .init(.flexible(), spacing: 4), count: 5)

    public init(query: AlbumQuery) {
        self.query = query
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let error = vm.errorMessage {
                    ContentUnavailableView(
                        "Photos unavailable",
                        systemImage: "photo.on.rectangle",
                        description: Text(error)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.count == 0 {
                    ContentUnavailableView(
                        "No assets",
                        systemImage: "photo.on.rectangle",
                        description: Text("Try a different dataset.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(0..<vm.count, id: \.self) { idx in
                                if let asset = vm.asset(at: idx) {
                                    Button {
                                        model.loadAssetIntoHistory(asset.localIdentifier)
                                        dismiss()
                                    } label: {
                                        AlbumFileBrowserAssetTile(asset: asset, manager: vm.imageManager)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(query.title)
                            .font(.caption.weight(.semibold))
                        if vm.count > 0 {
                            Text("\(vm.count) items")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: query.id) {
            await vm.load(query: query, excludingAssetIDs: model.hiddenIDs)
        }
    }
}

