import Foundation

public enum AlbumMovieBackgroundSong: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case none
    case heartfeltMontage
    case fadedPolaroid
    case sunnyMorning
    case birthdayBeat
    case corporateFocus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .heartfeltMontage: return "Heartfelt Montage (Default)"
        case .fadedPolaroid: return "Faded Polaroid"
        case .sunnyMorning: return "Sunny Morning"
        case .birthdayBeat: return "Birthday Beat"
        case .corporateFocus: return "Corporate Focus"
        }
    }

    public var mutesOriginalVideoAudio: Bool { self != .none }

    public func resolveURL(bundle: Bundle = .main) -> URL? {
        func resolve(_ name: String) -> URL? {
            bundle.url(forResource: name, withExtension: "m4a", subdirectory: "Album")
                ?? bundle.url(forResource: name, withExtension: "m4a")
        }

        switch self {
        case .none:
            return nil
        case .heartfeltMontage:
            return resolve("Heartfelt_Montage_Loop_2026-01-18T193700")
        case .fadedPolaroid:
            return resolve("Faded_Polaroid_2026-01-18T195127")
        case .sunnyMorning:
            return resolve("Sunny_Morning_Montage_2026-01-18T194746")
        case .birthdayBeat:
            return resolve("Preteen_Birthday_Beat_2026-01-18T194051")
        case .corporateFocus:
            return resolve("Corporate_Focus_Loop_2026-01-18T194430")
        }
    }
}
