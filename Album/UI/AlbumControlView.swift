import SwiftUI

public struct AlbumControlView: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    @State private var launched = false
    @State private var assetLimit: Int = 600
    @State private var isQueryPickerPresented: Bool = false

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
        .task {
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
                            if case .opened = await openImmersiveSpace(id: "album-space") {
                                launched = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 12) {
                Button {
                    isQueryPickerPresented = true
                } label: {
                    Label(model.selectedQuery.title, systemImage: "photo.on.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)

                Stepper("Limit \(assetLimit)", value: $assetLimit, in: 200...1000, step: 100)
                    .labelsHidden()

                Button("Reload") {
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
        switch status {
        case .authorized, .limited:
            Text("Library: \(model.items.count) items loaded (\(status == .limited ? "Limited Access" : "Full Access"))")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .notDetermined:
            Text("Library: permission not requested yet")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 6) {
                Text("Library access is blocked (\(status == .denied ? "Denied" : "Restricted")).")
                Text("Enable Photos access in Settings to load your library.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let err = model.lastAssetLoadError, !err.isEmpty {
            Text("Load error: \(err)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
