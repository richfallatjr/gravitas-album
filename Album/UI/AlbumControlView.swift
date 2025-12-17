import SwiftUI

public struct AlbumControlView: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var launched = false
    @State private var assetLimit: Int = 300
    @State private var isQueryPickerPresented: Bool = false
    @State private var immersiveOpenStatus: String? = nil

    public init() {}

    public var body: some View {
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
        .glassBackground(cornerRadius: 28)
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
        .sheet(isPresented: $isQueryPickerPresented) {
            AlbumQueryPickerSheet(limit: $assetLimit)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isLayoutPresented) {
            AlbumLayoutSheet()
                .environmentObject(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Gravitas Album")
                    .font(.title2.weight(.semibold))

                Spacer(minLength: 0)

                if !launched {
                    Button("Run Simulation") {
                        Task { @MainActor in
                            AlbumLog.immersive.info("Run Simulation pressed; requesting immersive space open")
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
                }
            }

            if let immersiveOpenStatus {
                Text(immersiveOpenStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Button {
                    isQueryPickerPresented = true
                } label: {
                    Label(model.selectedQuery.title, systemImage: "photo.on.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)

                Stepper("Limit \(assetLimit)", value: $assetLimit, in: 50...300, step: 50)
                    .labelsHidden()

                Button("Reload") {
                    AlbumLog.ui.info("Reload pressed; loadItems(limit: \(self.assetLimit), query: \(self.model.selectedQuery.id, privacy: .public))")
                    Task { await model.loadItems(limit: assetLimit, query: model.selectedQuery) }
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Picker("Mode", selection: $model.panelMode) {
                    Text("RECOMMENDS").tag(AlbumPanelMode.recommends)
                    Text("MEMORIES").tag(AlbumPanelMode.memories)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            .font(.footnote)

            authorizationStatus
        }
    }

    @ViewBuilder
    private var authorizationStatus: some View {
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
                .foregroundStyle(.secondary)

            if model.datasetSource == .photos {
                Text("Fetched: \(model.lastAssetFetchCount) • Hidden: \(model.hiddenIDs.count) • \(accessLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Photos access: \(accessLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            switch status {
            case .authorized, .limited:
                if model.isLoadingItems {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if model.items.isEmpty, model.lastAssetLoadError == nil, model.datasetSource == .photos {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Photos returned. If you’re on Simulator, add photos to the simulator Photos library (or run on device).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Load Demo Items") {
                            model.loadDemoItems(count: assetLimit)
                        }
                        .buttonStyle(.bordered)
                    }
                }

            case .notDetermined:
                Text("Library: permission not requested yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if model.items.isEmpty, !model.isLoadingItems {
                    Button("Load Demo Items") {
                        model.loadDemoItems(count: assetLimit)
                    }
                    .buttonStyle(.bordered)
                }

            case .denied, .restricted:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Library access is blocked (\(status == .denied ? "Denied" : "Restricted")).")
                    Text("Enable Photos access in Settings to load your library.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if model.items.isEmpty, !model.isLoadingItems {
                    Button("Load Demo Items") {
                        model.loadDemoItems(count: assetLimit)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let err = model.lastAssetLoadError, !err.isEmpty {
                Text("Load error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button(model.isPaused ? "Play" : "Pause") { model.isPaused.toggle() }
                .buttonStyle(.borderedProminent)

            HStack(spacing: 10) {
                Text("Absorb every")
                Slider(value: $model.absorbInterval, in: 1...20, step: 1)
                    .frame(width: 180)
                Text("\(Int(model.absorbInterval))s")
                Button("Absorb Now") { model.requestAbsorbNow() }
                    .buttonStyle(.bordered)
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
            .tint(.yellow)
        }
    }

    @ViewBuilder
    private var modePanel: some View {
        switch model.panelMode {
        case .recommends:
            HStack(spacing: 12) {
                if model.neighborsReady {
                    Label("Neighbors ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Neighbors not ready", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button("Refresh recommends") {
                    model.refreshRecommends()
                }
                .buttonStyle(.bordered)
                .disabled(model.currentAssetID == nil)
            }
            .font(.footnote)

        case .memories:
            HStack(spacing: 12) {
                Button("Prev") { model.memoryPrevPage() }
                    .buttonStyle(.bordered)
                    .disabled(!model.memoryPrevEnabled)

                Text(model.memoryLabel.isEmpty ? " " : model.memoryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Next") { model.memoryNextPage() }
                    .buttonStyle(.bordered)
                    .disabled(!model.memoryNextEnabled)

                Spacer(minLength: 0)
            }
        }
    }

    private var mainBody: some View {
        HStack(alignment: .top, spacing: 16) {
            AlbumMediaPane(assetID: model.currentAssetID)
            .frame(minHeight: 380)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(width: 260)
        }
    }

    private var bottomRightButtons: some View {
        HStack(spacing: 12) {
            Button {
                model.isLayoutPresented = true
            } label: {
                Label("Layout", systemImage: "square.grid.2x2")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.bordered)
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
            .buttonStyle(.bordered)
            .disabled(model.currentAssetID == nil)
        }
        .padding(.bottom, 26)
        .padding(.trailing, 26)
    }

    private var layoutEnabled: Bool {
        switch model.panelMode {
        case .recommends:
            return !model.recommendItems.isEmpty
        case .memories:
            return model.currentAssetID != nil
        }
    }
}
