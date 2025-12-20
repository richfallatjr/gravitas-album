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
        .defaultLaunchBehavior(.suppressed)

        WindowGroup(id: "album-scene-manager") {
            AlbumSceneManagerView()
                .environmentObject(model)
        }
        .defaultSize(width: 630, height: 690)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

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

    @State private var activeItemID: UUID? = nil
    @State private var hasGeometryMidX: Bool = false

    init(payload: Binding<AlbumPopOutPayload?>) {
        self._payload = payload
    }

    var body: some View {
        let itemID = payload?.itemID
        let item = itemID.flatMap { model.sceneItem(for: $0) }

        Group {
            if let itemID, let item {
                switch item.kind {
                case .asset:
                    if let assetID = item.assetID, !assetID.isEmpty {
                        AlbumPopOutAssetView(itemID: itemID, assetID: assetID)
                            .environmentObject(model)
                    } else {
                        Text("Missing asset.")
                            .environmentObject(model)
                    }

                case .movie:
                    AlbumMovieDraftView(itemID: itemID)
                        .environmentObject(model)
                }
            } else {
                Text("Loading…")
                    .environmentObject(model)
            }
        }
        .onAppear {
            syncPoppedItem(with: itemID)
        }
        .onChange(of: itemID) { newID in
            syncPoppedItem(with: newID)
        }
        .onDisappear {
            syncPoppedItem(with: nil)
        }
        .background {
            ZStack {
                AlbumWindowAttachmentObserver(
                    onAttach: { syncPoppedItem(with: itemID) },
                    onDetach: { syncPoppedItem(with: nil) },
                    onMidXChange: { midX in
                        guard !hasGeometryMidX else { return }
                        guard let activeItemID else { return }
                        model.updatePoppedItemWindowMidX(itemID: activeItemID, midX: midX)
                    }
                )

                GeometryReader3D { proxy in
                    let rect = proxy.frame(in: .global)
                    let transform = proxy.transform(in: .global)
                    let midX = windowMidX(from: rect, transform: transform)
                    let center = windowWorldCenter(from: rect, transform: transform)

                    Color.clear
                        .onAppear {
                            updateWindowMidX(midX)
                            updateWindowWorldCenter(center)
                        }
                        .onChange(of: midX) { newMidX in
                            updateWindowMidX(newMidX)
                        }
                        .onChange(of: center) { newCenter in
                            updateWindowWorldCenter(newCenter)
                        }
                }
            }
        }
    }

    private func syncPoppedItem(with newItemID: UUID?) {
        if let existing = activeItemID, existing != newItemID {
            model.updatePoppedItemWindowWorldCenter(itemID: existing, center: nil)
            model.removePoppedItem(existing)
        }

        if let newItemID, newItemID != activeItemID, let item = model.sceneItem(for: newItemID) {
            model.ensurePoppedItemExists(item)
        }

        if newItemID != activeItemID {
            hasGeometryMidX = false
        }
        activeItemID = newItemID
    }

    private func windowMidX(from rect: Rect3D, transform: AffineTransform3D?) -> Double? {
        if let transform {
            let x = transform.translation.x
            if x.isFinite { return x }
        }
        let x = rect.origin.x + (rect.size.width / 2)
        return x.isFinite ? x : nil
    }

    private func updateWindowMidX(_ midX: Double?) {
        guard let midX else { return }
        guard let activeItemID else { return }
        hasGeometryMidX = true
        model.updatePoppedItemWindowMidX(itemID: activeItemID, midX: midX)
    }

    private func windowWorldCenter(from rect: Rect3D, transform: AffineTransform3D?) -> AlbumWindowWorldCenter? {
        if let transform {
            let t = transform.translation
            let x = t.x
            let y = t.y
            let z = t.z
            guard x.isFinite, y.isFinite, z.isFinite else { return nil }
            return AlbumWindowWorldCenter(x: x, y: y, z: z)
        }

        let x = rect.origin.x + (rect.size.width / 2)
        let y = rect.origin.y + (rect.size.height / 2)
        let z = rect.origin.z + (rect.size.depth / 2)
        guard x.isFinite, y.isFinite, z.isFinite else { return nil }
        return AlbumWindowWorldCenter(x: x, y: y, z: z)
    }

    private func updateWindowWorldCenter(_ center: AlbumWindowWorldCenter?) {
        guard let activeItemID else { return }
        model.updatePoppedItemWindowWorldCenter(itemID: activeItemID, center: center)
    }
}

private struct AlbumWindowAttachmentObserver: View {
    let onAttach: () -> Void
    let onDetach: () -> Void
    let onMidXChange: (Double?) -> Void

    var body: some View {
#if canImport(UIKit)
        AlbumWindowAttachmentObserverRepresentable(onAttach: onAttach, onDetach: onDetach, onMidXChange: onMidXChange)
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
    let onMidXChange: (Double?) -> Void

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(onAttach: onAttach, onDetach: onDetach, onMidXChange: onMidXChange)
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onAttach = onAttach
        uiView.onDetach = onDetach
        uiView.onMidXChange = onMidXChange
    }

    final class ObserverView: UIView {
        var onAttach: () -> Void
        var onDetach: () -> Void
        var onMidXChange: (Double?) -> Void
        private var hasAttachedOnce: Bool = false
        private weak var observedScene: UIScene?
        private var disconnectObserver: NSObjectProtocol? = nil
        private var framePollTimer: Timer? = nil
        private var lastMidX: Double? = nil

        init(onAttach: @escaping () -> Void, onDetach: @escaping () -> Void, onMidXChange: @escaping (Double?) -> Void) {
            self.onAttach = onAttach
            self.onDetach = onDetach
            self.onMidXChange = onMidXChange
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
                startFramePoll()
                onAttach()
                return
            }

            guard hasAttachedOnce else { return }
            stopFramePoll()
            onMidXChange(nil)
            unregisterSceneDisconnectObserver()
            onDetach()
        }

        deinit {
            stopFramePoll()
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
                self.stopFramePoll()
                self.onMidXChange(nil)
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

        private func startFramePoll() {
            stopFramePoll()
            guard window != nil else { return }
            lastMidX = nil
            emitMidXIfChanged(force: true)

            framePollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.emitMidXIfChanged(force: false)
            }
        }

        private func stopFramePoll() {
            framePollTimer?.invalidate()
            framePollTimer = nil
            lastMidX = nil
        }

        private func emitMidXIfChanged(force: Bool) {
            guard let window else { return }

            let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            let scenePoint: CGPoint = {
                if let scene = window.windowScene {
                    return scene.coordinateSpace.convert(center, from: window.coordinateSpace)
                }
                return window.convert(center, to: nil)
            }()

            let midX = Double(scenePoint.x)
            guard midX.isFinite else { return }

            if force {
                lastMidX = midX
                onMidXChange(midX)
                return
            }

            let previous = lastMidX
            if previous == nil || abs(midX - (previous ?? 0)) > 0.5 {
                lastMidX = midX
                onMidXChange(midX)
            }
        }
    }
}
#endif
