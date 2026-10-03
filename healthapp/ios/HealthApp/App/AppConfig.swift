import Foundation

/// Backend configuration injected from `Config.xcconfig` → Info.plist (`API_BASE_URL`, `COGNITO_DOMAIN`,
/// `COGNITO_CLIENT_ID`, `COGNITO_REGION`). Missing/placeholder values mean the app runs in demo mode.
struct AppConfig: Equatable {
    var apiBaseURL: URL?
    var cognitoDomain: String
    var cognitoClientId: String
    var cognitoRegion: String

    static func fromBundle(_ bundle: Bundle = .main) -> AppConfig {
        func value(_ key: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Unexpanded build settings look like "$(API_BASE_URL)".
            return raw.hasPrefix("$(") ? "" : raw
        }
        return AppConfig(apiBaseURL: URL(string: value("API_BASE_URL")).flatMap { $0.scheme == "https" ? $0 : nil },
                         cognitoDomain: value("COGNITO_DOMAIN"),
                         cognitoClientId: value("COGNITO_CLIENT_ID"),
                         cognitoRegion: value("COGNITO_REGION"))
    }

    var isComplete: Bool {
        apiBaseURL != nil && !cognitoDomain.isEmpty && !cognitoClientId.isEmpty && !cognitoRegion.isEmpty
    }
}
