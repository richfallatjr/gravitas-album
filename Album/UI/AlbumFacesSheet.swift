import SwiftUI

public struct AlbumFacesSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    @State private var buckets: [FaceBucketSummary] = []
    @State private var isLoading: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if buckets.isEmpty {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Scanning faces…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "No faces yet",
                            systemImage: "person.crop.square",
                            description: Text("Browse MEMORIES pages to build face buckets.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List(buckets) { bucket in
                        Button {
                            Task { @MainActor in
                                await model.openFaceBucket(faceID: bucket.faceID)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(bucket.faceID)
                                    .font(.body.monospaced())
                                Spacer(minLength: 0)
                                Text("\(bucket.assetCount)")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Faces")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") {
                        Task { await refresh() }
                    }
                }
            }
        }
        .task {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .albumFaceIndexDidUpdate)) { _ in
            Task { await refresh() }
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        buckets = await model.faceBucketSummaries()
    }
}

