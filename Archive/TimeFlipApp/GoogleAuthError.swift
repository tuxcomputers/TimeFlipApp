import Foundation

enum GoogleAuthError: Error, LocalizedError {
    case missingEnvironmentVariable(String)
    case missingClientID
    case missingClientSecret
    case invalidIssuer(String)
    case missingServiceConfiguration
    case authorizationFailed
    case missingStoredState
    case missingAccessToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingEnvironmentVariable(let name):
            return "Missing environment variable: \(name)"
        case .missingClientID:
            return "Add a Google OAuth client ID in Settings → Report."
        case .missingClientSecret:
            return "Add a Google OAuth client secret in Settings → Report."
        case .invalidIssuer(let value):
            return "Invalid issuer URL: \(value)"
        case .missingServiceConfiguration:
            return "Unable to load Google OAuth configuration."
        case .authorizationFailed:
            return "Google authorization failed."
        case .missingStoredState:
            return "No stored Google authorization."
        case .missingAccessToken:
            return "Missing Google access token."
        case .keychain(let status):
            return "Keychain error (status \(status))"
        }
    }
}
