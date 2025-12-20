import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
            AlbumPopOutWindowRootView(payload: binding)
                .environmentObject(model)
        }
        .defaultSize(width: 1080, height: 780)
        .restorationBehavior(.disabled)

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

private struct AlbumPopOutWindowRootView: View {
    @Binding var payload: AlbumPopOutPayload?
    @EnvironmentObject private var model: AlbumModel

    @State private var activeAssetID: String? = nil

    init(payload: Binding<AlbumPopOutPayload?>) {
        self._payload = payload
    }

    var body: some View {
        let assetID = payload?.assetID.trimmingCharacters(in: .whitespacesAndNewlines)

        Group {
            if let assetID, !assetID.isEmpty {
                AlbumPopOutAssetView(assetID: assetID)
                    .environmentObject(model)
            } else {
                Text("Loading…")
                    .environmentObject(model)
            }
        }
        .onAppear {
            syncPoppedAsset(with: assetID)
        }
        .onChange(of: assetID) { newID in
            syncPoppedAsset(with: newID)
        }
        .onDisappear {
            syncPoppedAsset(with: nil)
        }
        .background {
            AlbumWindowAttachmentObserver(
                onAttach: { syncPoppedAsset(with: assetID) },
                onDetach: { syncPoppedAsset(with: nil) }
            )
        }
    }

    private func syncPoppedAsset(with newAssetID: String?) {
        let id = newAssetID?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = activeAssetID, existing != id {
            model.removePoppedAsset(existing)
        }

        if let id, !id.isEmpty, id != activeAssetID {
            model.appendPoppedAsset(id)
        }

        activeAssetID = id
    }
}

private struct AlbumWindowAttachmentObserver: View {
    let onAttach: () -> Void
    let onDetach: () -> Void

    var body: some View {
#if canImport(UIKit)
        AlbumWindowAttachmentObserverRepresentable(onAttach: onAttach, onDetach: onDetach)
            .frame(width: 0, height: 0)
#else
        EmptyView()
#endif
    }
}

#if canImport(UIKit)
private struct AlbumWindowAttachmentObserverRepresentable: UIViewRepresentable {
    let onAttach: () -> Void
    let onDetach: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(onAttach: onAttach, onDetach: onDetach)
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onAttach = onAttach
        uiView.onDetach = onDetach
    }

    final class ObserverView: UIView {
        var onAttach: () -> Void
        var onDetach: () -> Void
        private var hasAttachedOnce: Bool = false
        private weak var observedScene: UIScene?
        private var disconnectObserver: NSObjectProtocol? = nil

        init(onAttach: @escaping () -> Void, onDetach: @escaping () -> Void) {
            self.onAttach = onAttach
            self.onDetach = onDetach
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                hasAttachedOnce = true
                registerSceneDisconnectObserverIfNeeded()
                onAttach()
                return
            }

            guard hasAttachedOnce else { return }
            unregisterSceneDisconnectObserver()
            onDetach()
        }

        deinit {
            unregisterSceneDisconnectObserver()
        }

        private func registerSceneDisconnectObserverIfNeeded() {
            guard let scene = window?.windowScene else { return }
            guard observedScene !== scene else { return }

            unregisterSceneDisconnectObserver()
            observedScene = scene

            disconnectObserver = NotificationCenter.default.addObserver(
                forName: UIScene.didDisconnectNotification,
                object: scene,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.unregisterSceneDisconnectObserver()
                self.onDetach()
            }
        }

        private func unregisterSceneDisconnectObserver() {
            if let token = disconnectObserver {
                NotificationCenter.default.removeObserver(token)
                disconnectObserver = nil
            }
            observedScene = nil
        }
    }
}
#endif
