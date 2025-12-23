import Foundation
import SwiftUI

public struct PeopleDirectoryView: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [FaceClusterDirectoryEntry] = []
    @State private var looseGroupsTitle: String = "Loose Groups"
    @State private var looseGroupNodes: [ClusterTreeNode] = []
    @State private var singleEntries: [FaceClusterDirectoryEntry] = []
    @State private var isLoading: Bool = false

    @State private var renameTarget: FaceClusterDirectoryEntry? = nil

    @State private var isLabelingFromContacts: Bool = false
    @State private var lastLabelReport: ContactLabelReport? = nil
    @State private var showLabelReport: Bool = false
    @State private var scheduledRefreshTask: Task<Void, Never>? = nil

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if isLoading {
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
                } else {
                    List {
                        if !looseGroupNodes.isEmpty {
                            Section {
                                OutlineGroup(looseGroupNodes, children: \.children) { node in
                                    Group {
                                        switch node.kind {
                                        case .group:
                                            groupRow(node: node)
                                        case .cluster:
                                            if let entry = node.entry {
                                                clusterRow(entry: entry)
                                            }
                                        case .root, .section:
                                            EmptyView()
                                        }
                                    }
                                }
                            } header: {
                                Text(looseGroupsTitle)
                            }
                        }

                        if !singleEntries.isEmpty {
                            Section("Singles") {
                                ForEach(singleEntries) { entry in
                                    clusterRow(entry: entry)
                                }
                            }
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
                    Button("Refresh") {
                        scheduleRefresh()
                    }

                    Button("Label from Contacts") {
                        Task { await labelFromContacts() }
                    }
                    .disabled(isLabelingFromContacts || model.datasetSource != .photos)
                }
            }
        }
        .task { scheduleRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .albumFaceIndexDidUpdate).receive(on: RunLoop.main)) { _ in
            scheduleRefresh(delayNanoseconds: 650_000_000)
        }
        .sheet(item: $renameTarget) { entry in
            ClusterRenameSheet(faceID: entry.faceID, initialName: entry.rawDisplayName)
                .environmentObject(model)
        }
        .alert("Contact labeling", isPresented: $showLabelReport, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(labelReportMessage)
        })
    }

    @MainActor
    private func scheduleRefresh(delayNanoseconds: UInt64 = 0) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            await refresh()
        }
    }

    private func clusterRow(entry: FaceClusterDirectoryEntry) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                Task { @MainActor in
                    await model.openFaceBucket(faceID: entry.faceID)
                    dismiss()
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if entry.isLabeled {
                            Text(entry.displayName)
                                .font(.body.weight(.semibold))
                            Text(entry.faceID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(entry.faceID)
                                .font(.body.monospaced())
                        }
                    }

                    Spacer(minLength: 0)

                    Text("\(entry.assetCount)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 30)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                renameTarget = entry
            } label: {
                Image(systemName: "pencil")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Rename")
        }
        .contextMenu {
            Button("Rename") {
                renameTarget = entry
            }

            Button("Clear Name", role: .destructive) {
                Task { @MainActor in
                    await model.clearFaceLabel(faceID: entry.faceID)
                }
            }
        }
    }

    private func groupRow(node: ClusterTreeNode) -> some View {
        let faceIDs = node.faceIDs ?? []

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title)
                    .font(.body.weight(.semibold))
                Text("\(faceIDs.count) clusters")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                Task { @MainActor in
                    await model.openFaceGroup(faceIDs: faceIDs, title: node.title)
                    dismiss()
                }
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open group")
        }
        .contextMenu {
            Button("Open") {
                Task { @MainActor in
                    await model.openFaceGroup(faceIDs: faceIDs, title: node.title)
                    dismiss()
                }
            }
        }
    }

    @MainActor
    private func refresh() async {
        if Task.isCancelled { return }
        isLoading = true
        defer { isLoading = false }
        let loaded = await model.faceDirectoryEntries()
        if Task.isCancelled { return }
        entries = loaded
        let hierarchy = await buildHierarchy(entries: loaded)
        if Task.isCancelled { return }
        looseGroupsTitle = hierarchy.looseTitle
        looseGroupNodes = hierarchy.looseGroups
        singleEntries = hierarchy.singles
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

    private struct PeopleHierarchy {
        var looseTitle: String
        var looseGroups: [ClusterTreeNode]
        var singles: [FaceClusterDirectoryEntry]
    }

    private func buildHierarchy(entries: [FaceClusterDirectoryEntry]) async -> PeopleHierarchy {
        guard !entries.isEmpty else {
            return PeopleHierarchy(looseTitle: looseGroupsTitle, looseGroups: [], singles: [])
        }

        let maxHierarchyClusters = 240
        let sortedByCount = entries.sorted { lhs, rhs in
            if lhs.assetCount != rhs.assetCount { return lhs.assetCount > rhs.assetCount }
            return lhs.faceID < rhs.faceID
        }
        let hierarchyEntries = Array(sortedByCount.prefix(maxHierarchyClusters))
        let overflowEntries = Array(sortedByCount.dropFirst(maxHierarchyClusters))

        let config = await model.faceIndexConfiguration()
        let base = config.linkThreshold
        let mediumThreshold = min(0.85, base + 0.10)
        let looseThreshold = min(0.85, base + 0.22)

        let faceIDs = hierarchyEntries.map(\.faceID)
        let groupings = await model.faceGroupings(faceIDs: faceIDs, distanceThresholds: [mediumThreshold, looseThreshold])
        let mediumGroups = groupings.indices.contains(0) ? groupings[0] : []
        let looseGroups = groupings.indices.contains(1) ? groupings[1] : []

        if looseGroups.isEmpty {
            return PeopleHierarchy(
                looseTitle: "Loose Groups (≤\(String(format: "%.2f", looseThreshold)))",
                looseGroups: [],
                singles: sortedByCount
            )
        }

        var entryByID: [String: FaceClusterDirectoryEntry] = [:]
        entryByID.reserveCapacity(hierarchyEntries.count)
        for entry in hierarchyEntries {
            entryByID[entry.faceID] = entry
        }

        func groupTitle(for faceIDs: [String]) -> String {
            let names = faceIDs.compactMap { id -> String? in
                guard let entry = entryByID[id], entry.isLabeled else { return nil }
                return entry.displayName
            }
            let uniqueNames = Array(Set(names)).sorted()
            if !uniqueNames.isEmpty {
                let shown = Array(uniqueNames.prefix(2))
                let overflow = max(0, uniqueNames.count - shown.count)
                if overflow > 0 {
                    return "\(shown.joined(separator: ", ")) + \(overflow)"
                }
                return shown.joined(separator: ", ")
            }
            return "Group (\(faceIDs.count))"
        }

        func groupAssetCountSum(_ faceIDs: [String]) -> Int {
            faceIDs.reduce(0) { $0 + (entryByID[$1]?.assetCount ?? 0) }
        }

        var mediumIndexByFaceID: [String: Int] = [:]
        mediumIndexByFaceID.reserveCapacity(entries.count)
        for (idx, group) in mediumGroups.enumerated() {
            for id in group {
                mediumIndexByFaceID[id] = idx
            }
        }

        var looseGroupNodes: [ClusterTreeNode] = []
        var singleEntries: [FaceClusterDirectoryEntry] = overflowEntries

        for looseGroup in looseGroups {
            guard !looseGroup.isEmpty else { continue }

            if looseGroup.count <= 1 {
                if let only = looseGroup.first, let entry = entryByID[only] {
                    singleEntries.append(entry)
                }
                continue
            }

            var mediumBuckets: [Int: [String]] = [:]
            mediumBuckets.reserveCapacity(min(16, looseGroup.count))
            for id in looseGroup {
                if let mediumIndex = mediumIndexByFaceID[id] {
                    mediumBuckets[mediumIndex, default: []].append(id)
                } else {
                    mediumBuckets[-1, default: []].append(id)
                }
            }

            var mediumGroupsInLoose: [[String]] = mediumBuckets.values.map { ids in
                ids.sorted()
            }
            mediumGroupsInLoose.sort { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.first ?? "") < (rhs.first ?? "")
            }

            var children: [ClusterTreeNode] = []
            children.reserveCapacity(mediumGroupsInLoose.count)

            for subgroup in mediumGroupsInLoose {
                let leafNodes = subgroup.compactMap { entryByID[$0] }.map { ClusterTreeNode.cluster(entry: $0) }
                if subgroup.count > 1 {
                    let subgroupID = "people_group_medium_\(subgroup.joined(separator: ","))"
                    children.append(
                        .group(
                            id: subgroupID,
                            title: groupTitle(for: subgroup),
                            faceIDs: subgroup,
                            children: leafNodes
                        )
                    )
                } else if let leaf = leafNodes.first {
                    children.append(leaf)
                }
            }

            let groupID = "people_group_loose_\(looseGroup.joined(separator: ","))"
            looseGroupNodes.append(
                ClusterTreeNode.group(
                    id: groupID,
                    title: groupTitle(for: looseGroup),
                    faceIDs: looseGroup,
                    children: children
                )
            )
        }

        looseGroupNodes.sort { lhs, rhs in
            let lCount = groupAssetCountSum(lhs.faceIDs ?? [])
            let rCount = groupAssetCountSum(rhs.faceIDs ?? [])
            if lCount != rCount { return lCount > rCount }
            return lhs.title < rhs.title
        }

        singleEntries.sort { lhs, rhs in
            if lhs.isLabeled != rhs.isLabeled { return lhs.isLabeled && !rhs.isLabeled }
            if lhs.assetCount != rhs.assetCount { return lhs.assetCount > rhs.assetCount }
            return lhs.faceID < rhs.faceID
        }

        return PeopleHierarchy(
            looseTitle: "Loose Groups (≤\(String(format: "%.2f", looseThreshold))) · Top \(min(maxHierarchyClusters, hierarchyEntries.count))",
            looseGroups: looseGroupNodes,
            singles: singleEntries
        )
    }

    private var labelReportMessage: String {
        guard let report = lastLabelReport else { return "No report available." }
        if let error = report.errorDescription, !error.isEmpty {
            return error
        }
        return "Contacts scanned: \(report.contactsEnumerated)\nContacts with images: \(report.contactsWithImages)\nFaces detected: \(report.contactsWithFaceDetected)\nEmbeddings: \(report.embeddingsComputed)\nMatches: \(report.matchedClusters)\nLabeled: \(report.clustersLabeled)\nSkipped: \(report.clustersSkipped)\nFailures: \(report.failures)"
    }
}
