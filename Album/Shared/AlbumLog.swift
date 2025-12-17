import Foundation
import os

public enum AlbumLog {
    public static let subsystem: String = {
        Bundle.main.bundleIdentifier ?? "com.gravitas.GravitasAlbum"
    }()

    public static let ui = Logger(subsystem: subsystem, category: "UI")
    public static let model = Logger(subsystem: subsystem, category: "Model")
    public static let photos = Logger(subsystem: subsystem, category: "Photos")
    public static let immersive = Logger(subsystem: subsystem, category: "Immersive")
}

