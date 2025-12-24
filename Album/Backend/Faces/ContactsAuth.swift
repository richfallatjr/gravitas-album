import Contacts
import Foundation

public enum ContactsAuthError: LocalizedError, Sendable {
    case missingUsageDescription
    case denied
    case restricted
    case unknown

    public var errorDescription: String? {
        switch self {
        case .missingUsageDescription:
            return "Missing Info.plist key NSContactsUsageDescription (required before requesting Contacts permission)."
        case .denied:
            return "Contacts access denied. Enable Contacts access in Settings to use this feature."
        case .restricted:
            return "Contacts access is restricted on this device."
        case .unknown:
            return "Contacts access status is unknown."
        }
    }
}

public enum ContactsAuth {
    public static let usageDescriptionKey = "NSContactsUsageDescription"

    public static func isUsageDescriptionConfigured(bundle: Bundle = .main) -> Bool {
        bundle.object(forInfoDictionaryKey: usageDescriptionKey) != nil
    }

    public static func requestAccessIfNeeded() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        AlbumLog.privacy.info("ContactsAuth status=\(String(describing: status), privacy: .public)")
        switch status {
        case .authorized:
            return
        case .notDetermined:
            guard isUsageDescriptionConfigured() else {
                AlbumLog.privacy.error("ContactsAuth missing \(Self.usageDescriptionKey, privacy: .public)")
                throw ContactsAuthError.missingUsageDescription
            }

            let store = CNContactStore()
            AlbumLog.privacy.info("ContactsAuth requesting access")
            let granted = try await requestAccess(store: store)
            AlbumLog.privacy.info("ContactsAuth request result granted=\(granted, privacy: .public)")
            guard granted else { throw ContactsAuthError.denied }
        case .denied:
            throw ContactsAuthError.denied
        case .restricted:
            throw ContactsAuthError.restricted
        @unknown default:
            throw ContactsAuthError.unknown
        }
    }

    private static func requestAccess(store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: granted)
            }
        }
    }
}
