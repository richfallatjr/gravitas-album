import Contacts
import Combine
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct PeopleTreeView: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    @State private var rootNode: PeopleTreeNode? = nil
    @State private var isLoading: Bool = false
    @State private var buildProgress: FaceHierarchyBuildProgress? = nil

    @State private var editTarget: PeopleTreeNode? = nil
    @State private var scheduledRefreshTask: Task<Void, Never>? = nil
    @State private var pendingRefresh: Bool = false
    @State private var pendingForceRebuild: Bool = false
    @State private var lastRefreshCompletedAt: Date? = nil

    @State private var isLabelingFromContacts: Bool = false
    @State private var lastLabelReport: ContactLabelReport? = nil
    @State private var showLabelReport: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if rootNode == nil {
                    if isLoading, buildProgress != nil {
                        VStack(spacing: 14) {
                            ProgressView(value: buildProgress?.fractionComplete ?? 0)
                                .progressViewStyle(.linear)
                                .tint(model.palette.copyButtonFill)
                                .frame(maxWidth: 240)

                            VStack(spacing: 6) {
                                Text(progressTitle)
                                    .font(.caption.weight(.semibold))

                                Text(progressDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading people…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "No people yet",
                            systemImage: "person.crop.square",
                            description: Text("Browse MEMORIES pages to build face clusters.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let rootNode {
                    List {
                        if isLoading, buildProgress != nil {
                            Section {
                                VStack(alignment: .leading, spacing: 10) {
                                    ProgressView(value: buildProgress?.fractionComplete ?? 0)
                                        .progressViewStyle(.linear)
                                        .tint(model.palette.copyButtonFill)

                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(progressTitle)
                                            .font(.caption.weight(.semibold))

                                        Spacer(minLength: 0)

                                        Text(progressPercentString)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(progressDetail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            } header: {
                                Text("Building")
                            }
                        }

                        OutlineGroup([rootNode], children: \.children) { node in
                            nodeRow(node: node)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button(isLoading ? "Refreshing…" : "Refresh") {
                        scheduleRefresh(forceRebuild: true)
                    }
                    .disabled(isLoading)

                    Button(isLabelingFromContacts ? "Labeling…" : "Label from Contacts") {
                        Task { await labelFromContacts() }
                    }
                    .disabled(isLabelingFromContacts || model.datasetSource != .photos)
                }
            }
        }
        .task { scheduleRefresh() }
        .onDisappear { scheduledRefreshTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .albumFaceIndexDidUpdate).receive(on: RunLoop.main)) { _ in
            scheduleRefresh(delayNanoseconds: 650_000_000)
        }
        .sheet(item: $editTarget) { node in
            FaceHierarchyNodeEditSheet(node: node) { nodeID in
                Task { @MainActor in
                    editTarget = nil
                    scheduleRefresh(delayNanoseconds: 100_000_000)
                }
            }
            .environmentObject(model)
        }
        .alert("Contact labeling", isPresented: $showLabelReport, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(labelReportMessage)
        })
    }

    @MainActor
    private func scheduleRefresh(forceRebuild: Bool = false, delayNanoseconds: UInt64 = 0) {
        var delayNanoseconds = delayNanoseconds

        if delayNanoseconds > 0, let last = lastRefreshCompletedAt {
            let minIntervalSeconds: Double = 8
            let since = Date().timeIntervalSince(last)
            if since < minIntervalSeconds {
                let remaining = minIntervalSeconds - since
                let remainingNS = UInt64(max(0, remaining) * 1_000_000_000)
                delayNanoseconds = max(delayNanoseconds, remainingNS)
            }
        }

        if isLoading {
            pendingRefresh = true
            pendingForceRebuild = pendingForceRebuild || forceRebuild
            return
        }

        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            await refresh(forceRebuild: forceRebuild)
        }
    }

    @MainActor
    private func refresh(forceRebuild: Bool) async {
        if Task.isCancelled { return }
        isLoading = true
        buildProgress = nil
        defer {
            isLoading = false
            buildProgress = nil
        }

        let start = Date()
        AlbumLog.faces.info("PeopleTreeView refresh start dataset=\(model.datasetSource.rawValue, privacy: .public)")

        let needsRebuild: Bool
        if forceRebuild {
            needsRebuild = true
        } else {
            needsRebuild = await model.faceHierarchyNeedsRebuild()
        }
        if needsRebuild {
            let rebuildStart = Date()
            await model.rebuildFaceHierarchy(force: true) { progress in
                buildProgress = progress
            }
            if Task.isCancelled { return }
            AlbumLog.faces.info("PeopleTreeView hierarchy rebuild elapsed=\(Date().timeIntervalSince(rebuildStart), privacy: .public)s")
        } else {
            AlbumLog.faces.info("PeopleTreeView hierarchy rebuild skipped (up-to-date)")
        }

        let snapshotStart = Date()
        let snapshot = await model.faceHierarchySnapshot()
        if Task.isCancelled { return }
        let rootChildCount = snapshot.nodesByID[snapshot.rootID]?.childIDs.count ?? 0
        AlbumLog.faces.info(
            "PeopleTreeView snapshot nodes=\(snapshot.nodesByID.count, privacy: .public) maxLevel=\(snapshot.maxLevel, privacy: .public) rootChildren=\(rootChildCount, privacy: .public) elapsed=\(Date().timeIntervalSince(snapshotStart), privacy: .public)s"
        )

        let summaryStart = Date()
        let summaries = await model.faceBucketPreviewSummaries(sampleAssetLimit: 3)
        if Task.isCancelled { return }
        AlbumLog.faces.info("PeopleTreeView bucket summaries count=\(summaries.count, privacy: .public) elapsed=\(Date().timeIntervalSince(summaryStart), privacy: .public)s")

        var assetCountByLeafID: [String: Int] = [:]
        assetCountByLeafID.reserveCapacity(summaries.count)
        var sampleAssetIDsByLeafID: [String: [String]] = [:]
        sampleAssetIDsByLeafID.reserveCapacity(min(512, summaries.count))
        for s in summaries {
            assetCountByLeafID[s.faceID] = s.assetCount

            let samples = s.sampleAssetIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !model.hiddenIDs.contains($0) }
            if !samples.isEmpty {
                sampleAssetIDsByLeafID[s.faceID] = samples
            }
        }

        let built = PeopleTreeNode.buildRoot(
            snapshot: snapshot,
            assetCountByLeafID: assetCountByLeafID,
            sampleAssetIDsByLeafID: sampleAssetIDsByLeafID
        )
        if let built, built.leafCount > 0 {
            rootNode = built
        } else {
            rootNode = nil
        }

        AlbumLog.faces.info(
            "PeopleTreeView refresh done leafCount=\(built?.leafCount ?? 0, privacy: .public) elapsed=\(Date().timeIntervalSince(start), privacy: .public)s"
        )

        lastRefreshCompletedAt = Date()

        let shouldRefreshAgain = pendingRefresh
        pendingRefresh = false
        let shouldForceRebuild = pendingForceRebuild
        pendingForceRebuild = false

        if shouldRefreshAgain {
            Task { @MainActor in
                scheduleRefresh(forceRebuild: shouldForceRebuild, delayNanoseconds: 250_000_000)
            }
        }
    }

    private func nodeRow(node: PeopleTreeNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if node.isLabeled, let name = node.rawDisplayName, !name.isEmpty {
                    Text(name)
                        .font(.body.weight(.semibold))

                    Text(node.subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text(node.title)
                        .font(node.isLeaf ? .body.monospaced() : .body.weight(.semibold))
                }
            }

            Button {
                editTarget = node
            } label: {
                Image(systemName: "pencil")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Edit label")

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if !node.sampleAssetIDs.isEmpty {
                    PeopleRowThumbnailStack(assetIDs: node.sampleAssetIDs, size: 28)
                }

                Text(node.countLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { @MainActor in
                await openNode(node)
            }
        }
        .contextMenu {
            Button("Open") {
                Task { @MainActor in
                    await openNode(node)
                }
            }

            Button("Rename") {
                editTarget = node
            }

            Button("Clear Label", role: .destructive) {
                Task { @MainActor in
                    await model.setManualFaceHierarchyLabel(nodeID: node.nodeID, name: nil)
                }
            }
        }
    }

    @MainActor
    private func openNode(_ node: PeopleTreeNode) async {
        if node.isLeaf {
            await model.openFaceBucket(faceID: node.nodeID)
            return
        }

        let leafIDs = await model.faceHierarchyLeafDescendants(nodeID: node.nodeID)
        await model.openFaceGroup(faceIDs: leafIDs, title: node.title)
    }

    @MainActor
    private func labelFromContacts() async {
        isLabelingFromContacts = true
        defer { isLabelingFromContacts = false }

        let report = await model.labelClustersFromContacts(
            maxContacts: 200,
            matchThreshold: 0.35,
            renameOnlyIfUnlabeled: true
        )
        lastLabelReport = report
        showLabelReport = true
    }

    private var labelReportMessage: String {
        guard let report = lastLabelReport else { return "No report." }
        if let error = report.errorDescription, !error.isEmpty {
            return error
        }
        return "Contacts scanned: \(report.contactsEnumerated)\nContacts with images: \(report.contactsWithImages)\nFaces detected: \(report.contactsWithFaceDetected)\nEmbeddings: \(report.embeddingsComputed)\nMatches: \(report.matchedClusters)\nLabeled: \(report.clustersLabeled)\nSkipped: \(report.clustersSkipped)\nFailures: \(report.failures)"
    }

    private var progressTitle: String {
        guard let progress = buildProgress else { return "Building people…" }
        switch progress.stage {
        case .fetchingLeaves:
            return "Loading face clusters…"
        case .mergingLevel:
            if let level = progress.level, progress.totalLevels > 0 {
                return "Clustering L\(level) of \(progress.totalLevels)…"
            }
            return "Clustering…"
        case .finalizing:
            return "Finalizing…"
        case .done:
            return "Done"
        case .idle:
            return "Building people…"
        }
    }

    private var progressPercentString: String {
        let percent = Int(((buildProgress?.fractionComplete ?? 0) * 100).rounded())
        return "\(max(0, min(100, percent)))%"
    }

    private var progressDetail: String {
        guard let progress = buildProgress else { return "…" }

        let elapsed = formatDuration(seconds: progress.elapsedSeconds)
        let percent = progressPercentString

        let eta: String = {
            let fraction = progress.fractionComplete
            guard fraction > 0.02, fraction < 0.999 else { return "" }
            let total = progress.elapsedSeconds / max(0.001, fraction)
            let remaining = max(0, total - progress.elapsedSeconds)
            return " • ETA \(formatDuration(seconds: remaining))"
        }()

        return "\(percent) • \(elapsed)\(eta)"
    }

    private func formatDuration(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let minutes = s / 60
        let secs = s % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct PeopleTreeNode: Identifiable, Hashable {
    let nodeID: String
    let level: Int
    let rawDisplayName: String?
    let labelSource: ClusterLabelSource
    let isLeaf: Bool
    let leafCount: Int
    let leafAssetCount: Int
    let sampleAssetIDs: [String]
    var children: [PeopleTreeNode]?

    var id: String { nodeID }

    var isLabeled: Bool {
        let trimmed = rawDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return false }
        return labelSource == .manual || labelSource == .contact
    }

    var title: String {
        if let rawDisplayName, !rawDisplayName.isEmpty {
            return rawDisplayName
        }
        if level <= 0 {
            return nodeID
        }
        return "L\(level) \(Self.baseLeafID(from: nodeID))"
    }

    var subtitle: String {
        if level <= 0 {
            return nodeID
        }
        return "\(nodeID) • L\(level)"
    }

    var countLabel: String {
        if isLeaf {
            return "\(leafAssetCount)"
        }
        return "\(leafCount)"
    }

    static func buildRoot(
        snapshot: FaceHierarchySnapshot,
        assetCountByLeafID: [String: Int],
        sampleAssetIDsByLeafID: [String: [String]]
    ) -> PeopleTreeNode? {
        let rootID = snapshot.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootID.isEmpty else { return nil }
        guard let root = snapshot.nodesByID[rootID] else { return nil }

        let children = buildChildren(
            childIDs: root.childIDs,
            snapshot: snapshot,
            assetCountByLeafID: assetCountByLeafID,
            sampleAssetIDsByLeafID: sampleAssetIDsByLeafID
        )

        let leafCount = children.reduce(0) { $0 + $1.leafCount }
        let rootTitle = root.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (rootTitle?.isEmpty == false) ? rootTitle : "People"
        let sampleAssetIDs = sampleAssetIDs(from: children, limit: 3)

        return PeopleTreeNode(
            nodeID: rootID,
            level: root.level,
            rawDisplayName: displayName,
            labelSource: root.labelSource,
            isLeaf: false,
            leafCount: leafCount,
            leafAssetCount: 0,
            sampleAssetIDs: sampleAssetIDs,
            children: children
        )
    }

    private static func buildChildren(
        childIDs: [String],
        snapshot: FaceHierarchySnapshot,
        assetCountByLeafID: [String: Int],
        sampleAssetIDsByLeafID: [String: [String]]
    ) -> [PeopleTreeNode] {
        var out: [PeopleTreeNode] = []
        out.reserveCapacity(childIDs.count)

        for raw in childIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard let node = snapshot.nodesByID[id] else { continue }

            if node.level == 0 {
                let count = assetCountByLeafID[id] ?? 0
                guard count > 0 else { continue }
                let samples = Array((sampleAssetIDsByLeafID[id] ?? []).prefix(3))
                out.append(
                    PeopleTreeNode(
                        nodeID: id,
                        level: 0,
                        rawDisplayName: node.displayName,
                        labelSource: node.labelSource,
                        isLeaf: true,
                        leafCount: 1,
                        leafAssetCount: count,
                        sampleAssetIDs: samples,
                        children: nil
                    )
                )
                continue
            }

            let children = buildChildren(
                childIDs: node.childIDs,
                snapshot: snapshot,
                assetCountByLeafID: assetCountByLeafID,
                sampleAssetIDsByLeafID: sampleAssetIDsByLeafID
            )
            guard !children.isEmpty else { continue }

            let leafCount = children.reduce(0) { $0 + $1.leafCount }
            let sampleAssetIDs = sampleAssetIDs(from: children, limit: 3)
            out.append(
                PeopleTreeNode(
                    nodeID: id,
                    level: node.level,
                    rawDisplayName: node.displayName,
                    labelSource: node.labelSource,
                    isLeaf: false,
                    leafCount: leafCount,
                    leafAssetCount: 0,
                    sampleAssetIDs: sampleAssetIDs,
                    children: children
                )
            )
        }

        out.sort { lhs, rhs in
            if lhs.isLeaf != rhs.isLeaf { return !lhs.isLeaf }
            if lhs.isLabeled != rhs.isLabeled { return lhs.isLabeled && !rhs.isLabeled }
            if lhs.leafCount != rhs.leafCount { return lhs.leafCount > rhs.leafCount }
            return lhs.title < rhs.title
        }
        return out
    }

    private static func sampleAssetIDs(from children: [PeopleTreeNode], limit: Int) -> [String] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }

        var out: [String] = []
        out.reserveCapacity(limit)
        var seen = Set<String>()
        seen.reserveCapacity(limit)

        for child in children {
            for raw in child.sampleAssetIDs {
                let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                guard seen.insert(id).inserted else { continue }
                out.append(id)
                if out.count >= limit { return out }
            }
        }

        return out
    }

    private static func baseLeafID(from nodeID: String) -> String {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("h") else { return trimmed }
        guard let underscore = trimmed.firstIndex(of: "_") else { return trimmed }
        let after = trimmed.index(after: underscore)
        let base = String(trimmed[after...])
        return base.isEmpty ? trimmed : base
    }
}

private struct PeopleRowThumbnailStack: View {
    let assetIDs: [String]
    let size: CGFloat

    var body: some View {
        let ids = Array(assetIDs.prefix(3))
        HStack(spacing: -10) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, assetID in
                PeopleRowThumbnail(assetID: assetID, size: size)
                    .zIndex(Double(ids.count - index))
            }
        }
    }
}

private struct PeopleRowThumbnail: View {
    let assetID: String
    let size: CGFloat

    @EnvironmentObject private var model: AlbumModel
    @Environment(\.displayScale) private var displayScale

    @State private var image: AlbumImage? = nil
    @State private var isLoading: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(6, size * 0.22), style: .continuous)
    }

    var body: some View {
        ZStack {
            if let image {
#if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
#elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
#endif
            } else {
                shape.fill(model.palette.navBackground)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(model.palette.copyButtonFill)
                } else {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(model.palette.navBorder.opacity(0.65), lineWidth: 1))
        .task(id: assetID) {
            isLoading = true
            image = nil
            image = await model.requestThumbnail(
                assetID: assetID,
                targetSize: CGSize(width: size, height: size),
                displayScale: displayScale,
                triggerVision: false
            )
            isLoading = false
        }
    }
}

private struct FaceHierarchyNodeEditSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    let node: PeopleTreeNode
    let onClose: (String) -> Void

    @State private var name: String
    @State private var showContactPicker: Bool = false

    @FocusState private var focused: Bool

    init(node: PeopleTreeNode, onClose: @escaping (String) -> Void) {
        self.node = node
        self.onClose = onClose
        self._name = State(initialValue: node.rawDisplayName ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Sydney"))
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    Text(node.nodeID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("Level \(node.level)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Cluster")
                }

                Section {
                    Button("Assign Contact…") {
                        showContactPicker = true
                    }
                    .disabled(node.labelSource == .manual && node.isLabeled)
                } header: {
                    Text("Contacts")
                } footer: {
                    if node.labelSource == .manual && node.isLabeled {
                        Text("Clear the manual label before assigning a contact.")
                    } else {
                        Text("Assigning a contact applies a contact label to this folder.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { @MainActor in
                            await model.setManualFaceHierarchyLabel(nodeID: node.nodeID, name: nil)
                            dismiss()
                            onClose(node.nodeID)
                        }
                    } label: {
                        Text("Clear Label")
                    }
                }
            }
            .navigationTitle("Edit Label")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onClose(node.nodeID)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { @MainActor in
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            await model.setManualFaceHierarchyLabel(nodeID: node.nodeID, name: trimmed.isEmpty ? nil : trimmed)
                            dismiss()
                            onClose(node.nodeID)
                        }
                    }
                }
            }
        }
        .onAppear { focused = true }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerSheet { picked in
                Task { @MainActor in
                    await model.setContactFaceHierarchyLabel(nodeID: node.nodeID, contactID: picked.id, name: picked.displayName)
                    showContactPicker = false
                    dismiss()
                    onClose(node.nodeID)
                }
            }
        }
    }
}

private struct ContactPickerSheet: View {
    struct Entry: Identifiable, Hashable {
        let id: String
        let displayName: String
        let thumbnailData: Data?
    }

    @Environment(\.dismiss) private var dismiss

    let onPick: (Entry) -> Void

    @State private var isLoading: Bool = false
    @State private var contacts: [Entry] = []
    @State private var query: String = ""
    @State private var loadError: String? = nil

    init(onPick: @escaping (Entry) -> Void) {
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError, contacts.isEmpty {
                    ContentUnavailableView(
                        "Contacts unavailable",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text(loadError)
                    )
                } else {
                    List {
                        if isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading contacts…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(filteredContacts) { entry in
                            Button {
                                onPick(entry)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    avatar(for: entry)

                                    Text(entry.displayName)
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Pick Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .task { await loadContactsIfNeeded() }
    }

    private var filteredContacts: [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        let needle = trimmed.lowercased()
        return contacts.filter { $0.displayName.lowercased().contains(needle) }
    }

    @MainActor
    private func loadContactsIfNeeded() async {
        guard contacts.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try await ContactsAuth.requestAccessIfNeeded()
            let fetched = try fetchContactsWithImages(limit: 500)
            contacts = fetched
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func fetchContactsWithImages(limit: Int) throws -> [Entry] {
        let store = CNContactStore()

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true

        var out: [Entry] = []
        out.reserveCapacity(min(256, limit))

        try store.enumerateContacts(with: request) { contact, stop in
            guard contact.imageDataAvailable, contact.thumbnailImageData != nil else { return }

            let name = preferredDisplayName(contact: contact)
            guard !name.isEmpty else { return }

            out.append(Entry(id: contact.identifier, displayName: name, thumbnailData: contact.thumbnailImageData))

            if out.count >= limit {
                stop.pointee = true
            }
        }

        out.sort { $0.displayName < $1.displayName }
        return out
    }

    private func preferredDisplayName(contact: CNContact) -> String {
        let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        let full = [contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full
    }

    @ViewBuilder
    private func avatar(for entry: Entry) -> some View {
#if canImport(UIKit)
        if let data = entry.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
#else
        Image(systemName: "person.crop.circle")
            .font(.title2)
            .foregroundStyle(.secondary)
#endif
    }
}
