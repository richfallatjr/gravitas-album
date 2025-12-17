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
                                Text("\(scene.assetIDs.count) assets")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { indexSet in
                            model.deleteScenes(at: indexSet)
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 220)
                }

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
                    .disabled(model.poppedAssetIDs.isEmpty || sceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack {
                    Button("Load Scene") { loadSelectedScene() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSceneID == nil)
                    Button("Overwrite") { overwriteSelectedScene() }
                        .buttonStyle(.bordered)
                        .disabled(selectedSceneID == nil || model.poppedAssetIDs.isEmpty)
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
        .frame(width: 420, height: 460)
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

        for assetID in scene.assetIDs {
            openWindow(value: AlbumPopOutPayload(assetID: assetID))
            model.appendPoppedAsset(assetID)
        }
    }

    private func overwriteSelectedScene() {
        guard let id = selectedSceneID,
              let scene = model.scenes.first(where: { $0.id == id }) else { return }
        model.updateScene(scene)
    }
}

