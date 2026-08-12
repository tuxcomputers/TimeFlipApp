import AppAuth
import Foundation
import OSLog
import Security

private struct GoogleOAuthKeychainPayload: Codable {
    var clientSecret: String?
    var authStateData: Data?
}

final class GoogleOAuthKeychainStore: @unchecked Sendable {
    static let shared = GoogleOAuthKeychainStore()

    private let service: String
    private let account: String
    private let lock = NSLock()
    private var hasLoaded = false
    private var cachedPayload: GoogleOAuthKeychainPayload?
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "google-oauth-keychain")

    init(
        service: String = "\(AppIdentifiers.subsystem).google.oauth",
        account: String = "bundle"
    ) {
        self.service = service
        self.account = account
    }

    func loadClientSecret() throws -> String? {
        let payload = try loadPayload()
        let trimmed = payload.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveClientSecret(_ secret: String?) throws {
        let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? nil : trimmed
        try updatePayload { payload in
            payload.clientSecret = value
        }
    }

    func loadAuthState() throws -> OIDAuthState? {
        let payload = try loadPayload()
        guard let data = payload.authStateData else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        } catch {
            // Don't clearAuthState() here: that would permanently wipe the stored auth on what
            // could be a transient/one-off unarchiving failure, forcing a full reauthorization.
            // Leave the stored bytes alone and just report nil for this read.
            logger.error("Failed to unarchive stored Google auth state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveAuthState(_ state: OIDAuthState) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        try updatePayload { payload in
            payload.authStateData = data
        }
    }

    func clearAuthState() throws {
        try updatePayload { payload in
            payload.authStateData = nil
        }
    }

    private func loadPayload() throws -> GoogleOAuthKeychainPayload {
        lock.lock()
        if hasLoaded, let cachedPayload {
            lock.unlock()
            return cachedPayload
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let payload: GoogleOAuthKeychainPayload
        if status == errSecItemNotFound {
            payload = GoogleOAuthKeychainPayload()
        } else if status == errSecSuccess, let data = item as? Data {
            payload = decodePayload(data) ?? GoogleOAuthKeychainPayload()
        } else if status != errSecSuccess {
            throw GoogleAuthError.keychain(status)
        } else {
            payload = GoogleOAuthKeychainPayload()
        }

        lock.lock()
        cachedPayload = payload
        hasLoaded = true
        lock.unlock()

        return payload
    }

    private func updatePayload(_ update: (inout GoogleOAuthKeychainPayload) -> Void) throws {
        var payload = try loadPayload()
        update(&payload)
        try persist(payload)
        lock.lock()
        cachedPayload = payload
        hasLoaded = true
        lock.unlock()
    }

    private func persist(_ payload: GoogleOAuthKeychainPayload) throws {
        let shouldDelete = (payload.clientSecret?.isEmpty ?? true) && payload.authStateData == nil
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if shouldDelete {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return
            }
            throw GoogleAuthError.keychain(status)
        }

        let encoded = try encodePayload(payload)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw GoogleAuthError.keychain(status)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = encoded
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GoogleAuthError.keychain(addStatus)
        }
    }

    private func encodePayload(_ payload: GoogleOAuthKeychainPayload) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(payload)
    }

    private func decodePayload(_ data: Data) -> GoogleOAuthKeychainPayload? {
        do {
            return try PropertyListDecoder().decode(GoogleOAuthKeychainPayload.self, from: data)
        } catch {
            logger.error("Failed to decode stored Google OAuth Keychain payload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // No legacy migration needed yet; keep the store minimal.
}
