import SwiftUI
#if canImport(Spatial)
import Spatial
#endif
import simd
import Darwin
#if canImport(UIKit)
import UIKit
#endif

@main
struct GravitasAlbumApp: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AlbumAppDelegate.self) private var appDelegate
#endif
    @StateObject private var model = AlbumModel()

    var body: some Scene {
        WindowGroup(id: "album-control") {
            AlbumControlView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 1140)
        .windowResizability(.contentSize)

        WindowGroup(for: AlbumPopOutPayload.self) { binding in
            AlbumPopOutWindowRootView(payload: binding)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 780)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup(for: AlbumSharePayload.self) { binding in
            AlbumShareWindowRootView(payload: binding)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 660, height: 660)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup(id: "album-scene-manager") {
            AlbumSceneManagerView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 630, height: 690)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        ImmersiveSpace(id: "album-space") {
            AlbumImmersiveRootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .immersiveEnvironmentBehavior(.coexist)
    }
}

private struct AlbumPopOutWindowRootView: View {
    @Binding var payload: AlbumPopOutPayload?
    @EnvironmentObject private var model: AlbumModel

    @State private var activeItemID: UUID? = nil

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
                    onAttach: { _ in syncPoppedItem(with: itemID) },
                    onDetach: { syncPoppedItem(with: nil) },
                    onMidXChange: { midX in
                        guard let activeItemID else { return }
                        DispatchQueue.main.async {
                            model.updatePoppedItemWindowMidX(itemID: activeItemID, midX: midX)
                        }
                    }
                )

                GeometryReader3D { proxy in
                    let center = windowWorldCenter(from: proxy)

                    Color.clear
                        .onAppear {
                            updateWindowWorldCenter(center)
                        }
                        .onChange(of: center) { newCenter in
                            updateWindowWorldCenter(newCenter)
                        }
                }
            }
        }
    }

    private func syncPoppedItem(with newItemID: UUID?) {
        let previous = activeItemID
        guard previous != newItemID else { return }
        activeItemID = newItemID

        DispatchQueue.main.async {
            if let previous, previous != newItemID {
                model.updatePoppedItemWindowWorldCenter(itemID: previous, center: nil)
                model.removePoppedItem(previous)
            }

            if let newItemID, newItemID != previous, let item = model.sceneItem(for: newItemID) {
                model.ensurePoppedItemExists(item)
            }
        }
    }

    private func windowWorldCenter(from proxy: GeometryProxy3D) -> AlbumWindowWorldCenter? {
        let rect = proxy.frame(in: .global)

        if #available(visionOS 26.0, *) {
            let centerInSpace = SIMD4<Double>(
                Double(rect.origin.x + (rect.size.width / 2)),
                Double(rect.origin.y + (rect.size.height / 2)),
                Double(rect.origin.z + (rect.size.depth / 2)),
                1.0
            )

            let coordinateSpace = proxy.coordinateSpace3D(for: .global)
            if let t = try? coordinateSpace.ancestorFromSpaceTransform() {
                let transformed = simd_mul(t.matrix, centerInSpace)
                let w = transformed.w.isFinite && transformed.w != 0 ? transformed.w : 1.0
                let x = transformed.x / w
                let y = transformed.y / w
                let z = transformed.z / w
                if x.isFinite, y.isFinite, z.isFinite {
                    return AlbumWindowWorldCenter(x: x, y: y, z: z)
                }
            }
        }

        let transform = proxy.transform(in: .global)
        if let transform {
            let t = transform.translation
            let x = t.x
            let y = t.y
            let z = t.z
            if x.isFinite, y.isFinite, z.isFinite {
                return AlbumWindowWorldCenter(x: x, y: y, z: z)
            }
        }

        let x = rect.origin.x + (rect.size.width / 2)
        let y = rect.origin.y + (rect.size.height / 2)
        let z = rect.origin.z + (rect.size.depth / 2)
        guard x.isFinite, y.isFinite, z.isFinite else { return nil }
        return AlbumWindowWorldCenter(x: x, y: y, z: z)
    }

    private func updateWindowWorldCenter(_ center: AlbumWindowWorldCenter?) {
        guard let activeItemID else { return }
        DispatchQueue.main.async {
            model.updatePoppedItemWindowWorldCenter(itemID: activeItemID, center: center)
        }
    }
}

private struct AlbumShareWindowRootView: View {
    @Binding var payload: AlbumSharePayload?
    @Environment(\.dismiss) private var dismiss

    init(payload: Binding<AlbumSharePayload?>) {
        self._payload = payload
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(titleText)
                    .font(.headline)

                Spacer(minLength: 0)

                Button("Close") { dismiss() }
                    .buttonStyle(AlbumSubtleChromeButtonStyle())
            }
            .padding(16)

            Divider()

            Group {
                if let payload {
                    VStack(spacing: 16) {
                        ShareLink(item: payload.url, preview: SharePreview(titleText)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AlbumSubtleChromeButtonStyle())

                        Text(payload.url.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)
                } else {
                    Text("Nothing to share.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var titleText: String {
        let raw = payload?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Share" : raw
    }
}

struct AlbumWindowAttachmentObserver: View {
    let onAttach: (UIWindow?) -> Void
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
    let onAttach: (UIWindow?) -> Void
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
        var onAttach: (UIWindow?) -> Void
        var onDetach: () -> Void
        var onMidXChange: (Double?) -> Void
        private var hasAttachedOnce: Bool = false
        private var didDetach: Bool = false
        private weak var observedWindow: UIWindow?
        private weak var observedScene: UIScene?
        private var disconnectObserver: NSObjectProtocol? = nil
        private var windowHiddenObserver: NSObjectProtocol? = nil
        private var framePollTimer: Timer? = nil
        private var lastMidX: Double? = nil

        init(
            onAttach: @escaping (UIWindow?) -> Void,
            onDetach: @escaping () -> Void,
            onMidXChange: @escaping (Double?) -> Void
        ) {
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
                didDetach = false
                registerWindowHiddenObserverIfNeeded()
                registerSceneDisconnectObserverIfNeeded()
                startFramePoll()
                onAttach(window)
                return
            }

            guard hasAttachedOnce else { return }
            emitDetach()
        }

        deinit {
            guard hasAttachedOnce else {
                stopFramePoll()
                unregisterSceneDisconnectObserver()
                unregisterWindowHiddenObserver()
                return
            }
            emitDetach()
        }

        private func registerWindowHiddenObserverIfNeeded() {
            guard let window else { return }
            guard observedWindow !== window else { return }

            unregisterWindowHiddenObserver()
            observedWindow = window

            windowHiddenObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeHiddenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.emitDetach()
            }
        }

        private func unregisterWindowHiddenObserver() {
            if let token = windowHiddenObserver {
                NotificationCenter.default.removeObserver(token)
                windowHiddenObserver = nil
            }
            observedWindow = nil
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
                self.emitDetach()
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

        private func emitDetach() {
            if didDetach { return }
            didDetach = true
            stopFramePoll()
            onMidXChange(nil)
            unregisterSceneDisconnectObserver()
            unregisterWindowHiddenObserver()
            onDetach()
        }

        private func emitMidXIfChanged(force: Bool) {
            guard let window else { return }

            let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            let scenePoint: CGPoint = {
                if let scene = window.windowScene {
                    if #available(visionOS 26.0, *) {
                        return scene.effectiveGeometry.coordinateSpace.convert(center, from: window.coordinateSpace)
                    }
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

#if canImport(UIKit)
final class AlbumControlWindowKillSwitch {
    static let shared = AlbumControlWindowKillSwitch()

    private var controlWindowSessionIDs: Set<String> = []
    private var hasTriggeredTermination: Bool = false

    private init() {}

    func registerControlWindow(window: UIWindow?) {
        guard let sessionID = window?.windowScene?.session.persistentIdentifier else { return }
        let (inserted, _) = controlWindowSessionIDs.insert(sessionID)
        if inserted {
            AlbumLog.ui.info("Registered control window scene session id: \(sessionID, privacy: .public)")
        }
    }

    func handleDiscardedSceneSessions(_ sceneSessions: Set<UISceneSession>, reason: String) {
        guard !hasTriggeredTermination else { return }

        if let match = sceneSessions.first(where: { controlWindowSessionIDs.contains($0.persistentIdentifier) }) {
            terminateNow(reason: "control_window_discarded(\(match.persistentIdentifier)):\(reason)")
        }
    }

    func handleSceneDidDisconnect(_ scene: UIScene, reason: String) {
        guard !hasTriggeredTermination else { return }

        let sessionID = scene.session.persistentIdentifier
        guard controlWindowSessionIDs.contains(sessionID) else { return }

        terminateNow(reason: "control_window_disconnected(\(sessionID)):\(reason)")
    }

    private func terminateNow(reason: String) {
        guard !hasTriggeredTermination else { return }
        hasTriggeredTermination = true
        AlbumLog.ui.info("Kill switch terminating app (\(reason, privacy: .public))")
        exit(0)
    }
}
#endif

#if canImport(UIKit)
private final class AlbumAppDelegate: NSObject, UIApplicationDelegate {
    private var sceneDisconnectObserver: NSObjectProtocol? = nil

    override init() {
        super.init()
        sceneDisconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let scene = notification.object as? UIScene else { return }
            AlbumControlWindowKillSwitch.shared.handleSceneDidDisconnect(scene, reason: "notification")
        }
    }

    deinit {
        if let token = sceneDisconnectObserver {
            NotificationCenter.default.removeObserver(token)
        }
        sceneDisconnectObserver = nil
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        AlbumControlWindowKillSwitch.shared.handleDiscardedSceneSessions(sceneSessions, reason: "didDiscardSceneSessions")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: UIApplication) -> Bool {
        true
    }
}
#endif
