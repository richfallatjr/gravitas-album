import SwiftUI

@main
struct GravitasAlbumApp: App {
    @StateObject private var model = AlbumModel()

    var body: some Scene {
        WindowGroup(id: "album-control") {
            AlbumControlView()
                .environmentObject(model)
        }
        .defaultSize(width: 1080, height: 1140)
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
        .defaultSize(width: 1080, height: 780)

        WindowGroup(id: "album-scene-manager") {
            AlbumSceneManagerView()
                .environmentObject(model)
        }
        .defaultSize(width: 630, height: 690)

        ImmersiveSpace(id: "album-space") {
            AlbumImmersiveRootView()
                .environmentObject(model)
        }
        .immersiveEnvironmentBehavior(.coexist)
    }
}
