import SwiftUI

public struct AlbumSceneManagerView: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var sceneName: String = ""
    @State private var selectedSceneID: AlbumSceneRecord.ID?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                currentWindowsPanel
                makeMoviePanel
                savedScenesPanel

                VStack(alignment: .leading, spacing: 8) {
                    Text("Save current layout")
                        .font(.headline)
                    TextField("Scene name", text: $sceneName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        saveScene()
                    } label: {
                        Label("Save Scene", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.poppedItems.isEmpty || sceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack {
                    Button("Load Scene") { loadSelectedScene() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSceneID == nil)
                    Button("Overwrite") { overwriteSelectedScene() }
                        .buttonStyle(.bordered)
                        .disabled(selectedSceneID == nil || model.poppedItems.isEmpty)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
            .frame(width: 630, height: 690)
    }

    private var makeMoviePanel: some View {
        HStack(spacing: 12) {
            Button {
                makeMovie()
            } label: {
                Label("Make Movie", systemImage: "film")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer(minLength: 0)
        }
    }

    private var currentWindowsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Windows • \(model.poppedItems.count)")
                .font(.headline)

            if model.poppedItems.isEmpty {
                Text("No windows open. Pop out an asset and it will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(model.poppedItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            switch item.kind {
                            case .asset:
                                Text(model.semanticHandle(for: item.assetID ?? ""))
                                    .font(.footnote)
                                    .lineLimit(2)

                                if let assetID = item.assetID, let asset = model.asset(for: assetID) {
                                    Text(asset.mediaType == .video ? "Video" : "Photo")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Asset")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                            case .movie:
                                let title = item.movie?.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                Text(title.isEmpty ? "Movie Draft" : title)
                                    .font(.footnote)
                                    .lineLimit(2)

                                Text("Movie")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 160)
            }
        }
    }

    private var savedScenesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved Scenes")
                .font(.headline)

            if model.scenes.isEmpty {
                Text("No saved scenes yet. Pop out a few assets and tap Save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedSceneID) {
                    ForEach(model.scenes) { scene in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scene.name).font(.headline)
                            Text("\(scene.items.count) windows")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        model.deleteScenes(at: indexSet)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 160)
            }
        }
    }

    private func saveScene() {
        let name = sceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.createScene(named: name)
        sceneName = ""
    }

    private func loadSelectedScene() {
        guard let id = selectedSceneID,
              let scene = model.scenes.first(where: { $0.id == id }) else { return }

        for item in scene.items {
            model.ensurePoppedItemExists(item)
            openWindow(value: AlbumPopOutPayload(itemID: item.id))
        }
    }

    private func overwriteSelectedScene() {
        guard let id = selectedSceneID,
              let scene = model.scenes.first(where: { $0.id == id }) else { return }
        model.updateScene(scene)
    }

    private func makeMovie() {
        let item = model.createPoppedMovieItem()
        openWindow(value: AlbumPopOutPayload(itemID: item.id))
        Task { await model.generateMovieDraftTitle(itemID: item.id) }
    }
}
