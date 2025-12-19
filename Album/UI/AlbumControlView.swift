import SwiftUI
import UIKit
import Darwin

public struct AlbumControlView: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    private enum PresentedSheet: Identifiable {
        case queryPicker
        case settings

        var id: Int {
            switch self {
            case .queryPicker: return 0
            case .settings: return 1
            }
        }
    }

    @State private var launched = false
    @State private var assetLimit: Int = 300
    @State private var presentedSheet: PresentedSheet? = nil
    @State private var immersiveOpenStatus: String? = nil
    @State private var showQuitConfirmation: Bool = false
    @State private var showHideConfirmation: Bool = false
    @State private var pendingHideAssetID: String? = nil

    public init() {}

    public var body: some View {
        let palette = model.palette

        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 18) {
                header
                controlsRow
                modePanel
                Divider().padding(.vertical, 6)
                mainBody
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 72)

            bottomRightButtons
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(palette.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(palette.cardBorder.opacity(0.75), lineWidth: 1)
        )
        .preferredColorScheme(model.theme == .dark ? .dark : .light)
        .foregroundStyle(palette.panelPrimaryText)
        .onDisappear {
            AlbumLog.ui.info("AlbumControlView disappeared (main control panel closed); closing all scenes")
            let popoutIDs = model.poppedAssetIDs
            Task { @MainActor in
                let result = await dismissImmersiveSpace()
                AlbumLog.immersive.info("dismissImmersiveSpace result: \(String(describing: result), privacy: .public)")

                dismissWindow(id: "album-scene-manager")

                for assetID in popoutIDs {
                    dismissWindow(value: AlbumPopOutPayload(assetID: assetID))
                }
            }
        }
        .task {
            AlbumLog.ui.info("AlbumControlView task: loadItemsIfNeeded(limit: \(self.assetLimit))")
            await model.loadItemsIfNeeded(limit: assetLimit)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .queryPicker:
                AlbumQueryPickerSheet(limit: $assetLimit)
                    .environmentObject(model)
            case .settings:
                AlbumSettingsSheet()
                    .environmentObject(model)
            }
        }
    }

    private var header: some View {
        let palette = model.palette

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Gravitas Album")
                    .font(.title2.weight(.semibold))

                Spacer(minLength: 0)

                if !launched {
                    Button("Recommendation Engine") {
                        Task { @MainActor in
                            AlbumLog.immersive.info("Recommendation Engine pressed; requesting immersive space open")
                            immersiveOpenStatus = nil
                            immersiveOpenStatus = "Opening immersive space…"
                            let result = await openImmersiveSpace(id: "album-space")
                            AlbumLog.immersive.info("openImmersiveSpace result: \(String(describing: result), privacy: .public)")
                            if case .opened = result {
                                launched = true
                                immersiveOpenStatus = nil
                            } else {
                                immersiveOpenStatus = "Immersive open failed: \(String(describing: result))"
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.readButtonColor)
                    .foregroundStyle(palette.buttonLabelOnColor)
                }
            }

            if let immersiveOpenStatus {
                Text(immersiveOpenStatus)
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Button {
                    presentedSheet = .queryPicker
                } label: {
                    Label(model.selectedQuery.title, systemImage: "photo.on.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .tint(palette.historyButtonColor)
                .foregroundStyle(palette.buttonLabelOnColor)

                Stepper("Limit \(assetLimit)", value: $assetLimit, in: 50...300, step: 50)
                    .labelsHidden()

                Button("Reload") {
                    AlbumLog.ui.info("Reload pressed; loadItems(limit: \(self.assetLimit), query: \(self.model.selectedQuery.id, privacy: .public))")
                    Task { await model.loadItems(limit: assetLimit, query: model.selectedQuery) }
                }
                .buttonStyle(.bordered)
                .tint(palette.copyButtonFill)
                .foregroundStyle(palette.buttonLabelOnColor)

                Spacer(minLength: 0)

                Picker("Mode", selection: $model.panelMode) {
                    Text("MEMORIES").tag(AlbumPanelMode.memories)
                    Text("RECOMMENDS").tag(AlbumPanelMode.recommends)
                }
                .pickerStyle(.segmented)
                .tint(palette.toggleFillColor)
                .frame(maxWidth: 360)
            }
            .font(.footnote)

            authorizationStatus
        }
    }

    @ViewBuilder
    private var authorizationStatus: some View {
        let palette = model.palette

        let status = model.libraryAuthorization
        let accessLabel: String = {
            switch status {
            case .authorized:
                return "Full Access"
            case .limited:
                return "Limited Access"
            case .notDetermined:
                return "Not Determined"
            case .denied:
                return "Denied"
            case .restricted:
                return "Restricted"
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            Text("Dataset: \(model.datasetSource == .demo ? "Demo" : "Photos") • \(model.items.count) items")
                .font(.caption)
                .foregroundStyle(palette.panelSecondaryText)

            if model.datasetSource == .photos {
                Text("Fetched: \(model.lastAssetFetchCount) • Hidden: \(model.hiddenIDs.count) • \(accessLabel)")
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)

                libraryAnalysisStatus
            } else {
                Text("Photos access: \(accessLabel)")
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)
            }

            switch status {
            case .authorized, .limited:
                if model.isLoadingItems {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    }
                } else if model.items.isEmpty, model.lastAssetLoadError == nil, model.datasetSource == .photos {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Photos returned. If you’re on Simulator, add photos to the simulator Photos library (or run on device).")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Load Demo Items") {
                            model.loadDemoItems(count: assetLimit)
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.historyButtonColor)
                        .foregroundStyle(palette.buttonLabelOnColor)
                    }
                }

            case .notDetermined:
                Text("Library: permission not requested yet")
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)

                if model.items.isEmpty, !model.isLoadingItems {
                    Button("Load Demo Items") {
                        model.loadDemoItems(count: assetLimit)
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.historyButtonColor)
                    .foregroundStyle(palette.buttonLabelOnColor)
                }

            case .denied, .restricted:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Library access is blocked (\(status == .denied ? "Denied" : "Restricted")).")
                    Text("Enable Photos access in Settings to load your library.")
                }
                .font(.caption2)
                .foregroundStyle(palette.panelSecondaryText)

                if model.items.isEmpty, !model.isLoadingItems {
                    Button("Load Demo Items") {
                        model.loadDemoItems(count: assetLimit)
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.historyButtonColor)
                    .foregroundStyle(palette.buttonLabelOnColor)
                }
            }

            if let err = model.lastAssetLoadError, !err.isEmpty {
                Text("Load error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(palette.panelSecondaryText)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var libraryAnalysisStatus: some View {
        let palette = model.palette

        if model.libraryAuthorization == .authorized || model.libraryAuthorization == .limited {
            let status = model.backfillStatus
            let total = max(0, status.totalAssets)
            let computed = max(0, status.computed)
            let analysisComplete = total > 0 && computed >= total
            let computedPercent = total > 0 ? Int((Double(computed) / Double(total) * 100).rounded()) : 0

            if analysisComplete {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        presentedSheet = .settings
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.historyButtonColor)
                    .foregroundStyle(palette.buttonLabelOnColor)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button(status.paused ? "Resume" : "Pause") {
                            if status.paused {
                                model.resumeBackfill()
                            } else {
                                model.pauseBackfill()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.historyButtonColor)
                        .foregroundStyle(palette.buttonLabelOnColor)

                        Button("Restart Indexing") {
                            model.restartIndexing()
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.copyButtonFill)
                        .foregroundStyle(palette.buttonLabelOnColor)

                        Button("Retry Failed") {
                            model.retryFailedBackfill()
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.historyButtonColor)
                        .foregroundStyle(palette.buttonLabelOnColor)
                        .disabled(status.failed <= 0)

                        Spacer(minLength: 0)

                        Text(status.paused ? "Paused" : (status.running ? "Running" : "Idle"))
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    }

                    if total > 0 {
                        ProgressView(value: Double(computed), total: Double(total))
                            .progressViewStyle(.linear)
                            .tint(palette.copyButtonFill)

                        Text("Computed \(computed)/\(total) (\(computedPercent)%) • Autofilled \(status.autofilled) • Missing \(status.missing) • Failed \(status.failed) • Queued \(status.queued) • Inflight \(status.inflight)")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    } else {
                        Text("Queue: \(status.queued) queued • \(status.inflight) inflight • Failed \(status.failed)")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    }

                    if let err = status.lastError, !err.isEmpty {
                        Text("Last error: \(err)")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var controlsRow: some View {
        let palette = model.palette

        return HStack(spacing: 12) {
            Button(model.isPaused ? "Play" : "Pause") { model.isPaused.toggle() }
                .buttonStyle(.borderedProminent)
                .tint(palette.toggleFillColor)
                .foregroundStyle(palette.buttonLabelOnColor)

            HStack(spacing: 10) {
                Text("Absorb every")
                Slider(value: $model.absorbInterval, in: 1...20, step: 1)
                    .frame(width: 180)
                Text("\(Int(model.absorbInterval))s")
                Button("Absorb Now") { model.requestAbsorbNow() }
                    .buttonStyle(.bordered)
                    .tint(palette.copyButtonFill)
                    .foregroundStyle(palette.buttonLabelOnColor)
            }
            .font(.footnote)

            Spacer(minLength: 0)

            Button {
                openWindow(id: "album-scene-manager")
            } label: {
                    Label("Scenes", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .tint(palette.historyButtonColor)
            .foregroundStyle(palette.buttonLabelOnColor)
        }
    }

    @ViewBuilder
    private var modePanel: some View {
        let palette = model.palette

        switch model.panelMode {
        case .recommends:
            HStack(spacing: 12) {
                if model.neighborsReady {
                    Label("Neighbors ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(palette.readButtonColor)
                } else {
                    Label("Neighbors not ready", systemImage: "circle")
                        .foregroundStyle(palette.panelSecondaryText)
                }

                Spacer(minLength: 0)

                Button("Refresh recommends") {
                    model.refreshRecommends()
                }
                .buttonStyle(.bordered)
                .tint(palette.historyButtonColor)
                .foregroundStyle(palette.buttonLabelOnColor)
                .disabled(model.currentAssetID == nil)
            }
            .font(.footnote)

        case .memories:
            HStack(spacing: 12) {
                Button("Prev") { model.memoryPrevPage() }
                    .buttonStyle(.bordered)
                    .disabled(!model.memoryPrevEnabled)
                    .tint(palette.copyButtonFill)
                    .foregroundStyle(palette.buttonLabelOnColor)

                Text(model.memoryLabel.isEmpty ? " " : model.memoryLabel)
                    .font(.caption)
                    .foregroundStyle(palette.panelSecondaryText)
                    .lineLimit(1)

                Button("Next") { model.memoryNextPage() }
                    .buttonStyle(.bordered)
                    .disabled(!model.memoryNextEnabled)
                    .tint(palette.copyButtonFill)
                    .foregroundStyle(palette.buttonLabelOnColor)

                Spacer(minLength: 0)
            }
        }
    }

    private var mainBody: some View {
        let palette = model.palette

        return HStack(alignment: .top, spacing: 16) {
            AlbumMediaPane(assetID: model.currentAssetID)
                .padding(16)
                .frame(minHeight: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(palette.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(palette.cardBorder.opacity(0.65), lineWidth: 1)
                )
                .layoutPriority(1)

            AlbumHistoryList(
                historyAssetIDs: model.historyAssetIDs,
                recommendedAssetIDs: model.recommendedAssetIDs,
                aiNextAssetIDs: model.aiNextAssetIDs,
                feedbackByAssetID: model.thumbFeedbackByAssetID,
                currentAssetID: model.currentAssetID,
                onSelect: { assetID in
                    model.currentAssetID = assetID
                }
            )
            .padding(14)
            .frame(width: 280)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(palette.cardBorder.opacity(0.65), lineWidth: 1)
            )
        }
    }

    private var bottomRightButtons: some View {
        let palette = model.palette

        return HStack(spacing: 12) {
            Button {
                let current = self.model.currentAssetID ?? "nil"
                let anchor = self.model.recommendAnchorID ?? "nil"
                AlbumLog.ui.info("Layout pressed; mode=\(self.model.panelMode.rawValue, privacy: .public) current=\(current, privacy: .public) anchor=\(anchor, privacy: .public) neighbors=\(self.model.recommendItems.count)")
                model.dumpFocusedNeighborsToCurvedWall()
            } label: {
                Label("Layout", systemImage: "square.grid.2x2")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.copyButtonFill)
            .foregroundStyle(palette.buttonLabelOnColor)
            .disabled(!layoutEnabled)

            Button {
                if let id = model.currentAssetID {
                    openWindow(value: AlbumPopOutPayload(assetID: id))
                    model.appendPoppedAsset(id)
                }
            } label: {
                Label("Pop Out", systemImage: "rectangle.on.rectangle")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.historyButtonColor)
            .foregroundStyle(palette.buttonLabelOnColor)
            .disabled(model.currentAssetID == nil)

            Button {
                pendingHideAssetID = model.currentAssetID
                showHideConfirmation = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.openButtonColor)
            .foregroundStyle(palette.buttonLabelOnColor)
            .disabled(model.currentAssetID == nil)
            .confirmationDialog(
                "Hide this image?",
                isPresented: $showHideConfirmation,
                titleVisibility: .visible
            ) {
                Button("Hide", role: .destructive) {
                    if let id = pendingHideAssetID {
                        model.hideAsset(id)
                    }
                    pendingHideAssetID = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingHideAssetID = nil
                }
            } message: {
                Text("Are you sure you want to hide this from view? You will no longer see this image.")
            }

            Button {
                showQuitConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.openButtonColor)
            .foregroundStyle(palette.buttonLabelOnColor)
            .confirmationDialog(
                "Quit Gravitas Album?",
                isPresented: $showQuitConfirmation,
                titleVisibility: .visible
            ) {
                Button("Quit", role: .destructive) {
                    AlbumLog.ui.info("Quit pressed; tearing down immersive + windows then exiting")
                    let popoutIDs = model.poppedAssetIDs
                    model.shutdownForQuit()

                    Task.detached(priority: .userInitiated) {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        exit(0)
                    }

                    UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                    Task { @MainActor in
                        let result = await dismissImmersiveSpace()
                        AlbumLog.immersive.info("dismissImmersiveSpace result: \(String(describing: result), privacy: .public)")

                        dismissWindow(id: "album-scene-manager")
                        for assetID in popoutIDs {
                            dismissWindow(value: AlbumPopOutPayload(assetID: assetID))
                        }
                        dismissWindow(id: "album-control")

                        try? await Task.sleep(nanoseconds: 250_000_000)
                        exit(0)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any ongoing processing or playback will stop.")
            }
        }
        .padding(.bottom, 26)
        .padding(.trailing, 26)
    }

    private var layoutEnabled: Bool {
        switch model.panelMode {
        case .recommends:
            guard let current = model.currentAssetID else { return false }
            return model.recommendAnchorID == current && !model.recommendItems.isEmpty
        case .memories:
            return model.currentAssetID != nil
        }
    }
}
