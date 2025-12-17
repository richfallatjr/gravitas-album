import SwiftUI

public struct AlbumQueryPickerSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    @Binding private var limit: Int

    @State private var userAlbums: [AlbumUserAlbum] = []
    @State private var isLoadingAlbums: Bool = false
    @State private var albumsError: String? = nil

    @State private var selectedDay: Date = Date()

    public init(limit: Binding<Int>) {
        self._limit = limit
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Quick") {
                    queryRow(.allPhotos)
                    queryRow(.favorites)
                    queryRow(.recents(days: 30))
                    queryRow(.recents(days: 90))
                    queryRow(.recents(days: 365))
                }

                Section("By Year") {
                    ForEach(recentYears, id: \.self) { year in
                        queryRow(.year(year))
                    }
                }

                Section("By Day") {
                    DatePicker("Day", selection: $selectedDay, displayedComponents: .date)
                    Button("Use \(formatDay(selectedDay))") {
                        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: selectedDay)
                        let year = comps.year ?? Calendar.current.component(.year, from: selectedDay)
                        let month = comps.month ?? 1
                        let day = comps.day ?? 1
                        select(.day(year: year, month: month, day: day))
                    }
                }

                Section("User Albums") {
                    if isLoadingAlbums {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading albums…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let albumsError {
                        Text(albumsError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if userAlbums.isEmpty {
                        Text("No albums found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(userAlbums) { album in
                            queryRow(.userAlbum(album))
                        }
                    }
                }
            }
            .navigationTitle("Choose Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadUserAlbums()
        }
    }

    private var recentYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return (0..<12).map { currentYear - $0 }
    }

    @ViewBuilder
    private func queryRow(_ query: AlbumQuery) -> some View {
        Button {
            select(query)
        } label: {
            HStack {
                Text(query.title)
                Spacer()
                if model.selectedQuery.id == query.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func select(_ query: AlbumQuery) {
        model.selectedQuery = query
        Task { await model.loadItems(limit: limit, query: query) }
        dismiss()
    }

    private func loadUserAlbums() async {
        guard !isLoadingAlbums else { return }
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }

        do {
            userAlbums = try await model.assetProvider.fetchUserAlbums()
            albumsError = nil
        } catch {
            userAlbums = []
            albumsError = "Failed to load albums: \(String(describing: error))"
        }
    }

    private func formatDay(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}

