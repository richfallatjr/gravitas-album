import Foundation

enum AlbumSettingsStore {
    private static let key = "album.settings.v1"

    static func load(userDefaults: UserDefaults = .standard) -> AlbumModel.Settings? {
        guard let data = userDefaults.data(forKey: key) else { return nil }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(AlbumModel.Settings.self, from: data)
        } catch {
            AlbumLog.model.error("AlbumSettingsStore load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func save(_ settings: AlbumModel.Settings, userDefaults: UserDefaults = .standard) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: key)
        } catch {
            AlbumLog.model.error("AlbumSettingsStore save failed: \(String(describing: error), privacy: .public)")
        }
    }
}

