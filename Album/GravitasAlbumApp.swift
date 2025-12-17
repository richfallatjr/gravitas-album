import SwiftUI

@main
struct GravitasAlbumApp: App {
    @StateObject private var model = AlbumModel()

    var body: some Scene {
        WindowGroup {
            AlbumControlView()
                .environmentObject(model)
        }
        .defaultSize(width: 720, height: 760)
        .windowResizability(.contentSize)

        WindowGroup(for: AlbumPopOutPayload.self) { binding in
            if let payload = binding.wrappedValue {
                AlbumPopOutAssetView(assetID: payload.assetID)
                    .environmentObject(model)
            } else {
                Text("Loading…")
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 720, height: 520)

        WindowGroup(id: "album-scene-manager") {
            AlbumSceneManagerView()
                .environmentObject(model)
        }
        .defaultSize(width: 420, height: 460)

        ImmersiveSpace(id: "album-space") {
            AlbumImmersiveRootView()
                .environmentObject(model)
        }
    }
}
