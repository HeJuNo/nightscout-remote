import Foundation

enum AppConfig {
    /// Backend origin, injected at build time via Config.xcconfig -> Info.plist.
    /// Nil for frontend-only apps (local persistence via SwiftData).
    static var apiBaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
