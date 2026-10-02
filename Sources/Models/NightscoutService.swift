import Foundation
import os.log

private let logger = Logger(subsystem: "nightscout.kh", category: "NightscoutService")

enum NightscoutError: LocalizedError {
    case noURL
    case noToken
    case invalidURL
    case invalidToken
    case unauthorized
    case serverError(Int)
    case networkError(String)
    case deleteForbidden

    var errorDescription: String? {
        switch self {
        case .noURL:
            return "Keine Nightscout-URL konfiguriert. Bitte in den Einstellungen hinterlegen."
        case .noToken:
            return "Kein Access Token konfiguriert. Bitte in den Einstellungen hinterlegen."
        case .invalidURL:
            return "Die Nightscout-URL ist ungültig."
        case .invalidToken:
            return "Access Token wird von Nightscout nicht erkannt. Bitte Token prüfen."
        case .unauthorized:
            return "Keine Berechtigung (HTTP 401). Bitte Access Token und dessen Rolle prüfen."
        case .serverError(let code):
            return "Server-Fehler (HTTP \(code)). Bitte URL und Access Token prüfen."
        case .networkError(let msg):
            return "Netzwerkfehler: \(msg)"
        case .deleteForbidden:
            return "Keine Löschberechtigung. Das Access Token braucht das Recht „api:treatments:delete“ (z.B. Rolle „admin“ oder eine eigene Rolle in Nightscout)."
        }
    }
}

/// Result of the connection check in the settings.
struct ConnectionTestResult {
    enum Status { case ok, failed, unknown }

    var reachable: Status = .unknown
    var reachableDetail: String = ""
    var canRead: Status = .unknown
    var readDetail: String = ""
    var canWrite: Status = .unknown
    var writeDetail: String = ""
    var serverInfo: String? = nil
    var subject: String? = nil

    var allOK: Bool { reachable == .ok && canRead == .ok && canWrite == .ok }
}

/// Nightscout authentication with an access token:
/// the access token is exchanged for a short-lived JWT via
/// `GET /api/v2/authorization/request/<accessToken>`; all API calls then send
/// `Authorization: Bearer <jwt>`. The response also contains the token's
/// permission groups, which are used to check read/write rights precisely.
enum NightscoutService {

    static let enteredBy = "Nightscout Remote"
    /// Earlier app versions marked entries with this name; they are shown in the history too.
    static let legacyEnteredBy = ["Nightscout KH App"]
    static let tokenKeychainKey = "access_token"

    // MARK: - JWT session

    private struct AuthSession {
        let base: String
        let accessToken: String
        let jwt: String
        let permissions: [String]
        let subject: String?
        let expires: Date
    }

    private enum AuthOutcome {
        case session(AuthSession)
        case invalidToken(Int)
    }

    private actor SessionCache {
        var session: AuthSession?
        func get(base: String, token: String) -> AuthSession? {
            guard let s = session, s.base == base, s.accessToken == token,
                  s.expires > Date().addingTimeInterval(60) else { return nil }
            return s
        }
        func set(_ s: AuthSession?) { session = s }
    }

    private static let cache = SessionCache()

    private static func authorize(base: String, token: String) async throws -> AuthOutcome {
        // Strict encoding: characters like "/" must not split the path segment.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(base)/api/v2/authorization/request/\(encoded)"),
              url.host != nil else {
            throw NightscoutError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, http) = try await perform(request)
        logger.info("Token exchange (/api/v2/authorization/request): HTTP \(http.statusCode), token length \(token.count), looksValid \(looksLikeAccessToken(token))")

        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jwt = json["token"] as? String, !jwt.isEmpty else {
            if http.statusCode == 401 || http.statusCode == 403 || (200..<300).contains(http.statusCode) {
                return .invalidToken(http.statusCode)
            }
            throw NightscoutError.serverError(http.statusCode)
        }

        let groups = (json["permissionGroups"] as? [[String]]) ?? []
        let permissions = groups.flatMap { $0 }
        let exp = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(3600)
        let session = AuthSession(base: base, accessToken: token, jwt: jwt,
                                  permissions: permissions,
                                  subject: json["sub"] as? String, expires: exp)
        logger.info("Token OK – subject \(session.subject ?? "?"), permissions \(permissions.joined(separator: ","))")
        return .session(session)
    }

    private static func session(base: String, token: String) async throws -> AuthSession {
        if let cached = await cache.get(base: base, token: token) { return cached }
        switch try await authorize(base: base, token: token) {
        case .session(let s):
            await cache.set(s)
            return s
        case .invalidToken:
            throw NightscoutError.invalidToken
        }
    }

    /// Nightscout access tokens look like `<subjectname>-<16 hex chars>`, e.g. `khapp-1a2b3c4d5e6f7a8b`.
    static func looksLikeAccessToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.range(of: "^[^\\s/]+-[0-9a-fA-F]{16}$", options: .regularExpression) != nil
    }

    // MARK: - Permission matching (Shiro-style, as used by Nightscout)

    /// Returns true if any granted permission implies `target` (e.g. "api:treatments:create").
    static func permits(_ granted: [String], _ target: String) -> Bool {
        let t = target.split(separator: ":").map(String.init)
        return granted.contains { perm in
            let p = perm.split(separator: ":").map(String.init)
            for (i, part) in t.enumerated() {
                if i >= p.count { return true } // shorter permission implies the rest
                let options = p[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !(options.contains("*") || options.contains(part)) { return false }
            }
            return true
        }
    }

    // MARK: - Credentials

    private static func storedCredentials() throws -> (base: String, token: String) {
        guard let urlString = UserDefaults.standard.string(forKey: "nightscout_url"),
              !urlString.isEmpty else {
            throw NightscoutError.noURL
        }
        guard let token = KeychainHelper.read(key: tokenKeychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw NightscoutError.noToken
        }
        return (normalizedBase(urlString), token)
    }

    private static func normalizedBase(_ urlString: String) -> String {
        urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func bearerRequest(_ url: URL, jwt: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    // MARK: - Upload

    /// Uploads one carb treatment. Deliberately WITHOUT absorption time / duration,
    /// marked with `enteredBy` so it is recognizable as a manual entry from this app.
    /// The original `created_at` is kept, so a retried upload lands at the correct time.
    static func postTreatment(_ item: PendingTreatment) async throws {
        let creds = try storedCredentials()
        guard let url = URL(string: "\(creds.base)/api/v1/treatments"), url.host != nil else {
            throw NightscoutError.invalidURL
        }
        let auth = try await session(base: creds.base, token: creds.token)

        var entry: [String: Any]
        if let glucose = item.glucose, let unit = item.glucoseUnit {
            // Blood glucose check as entered in the Nightscout Careportal.
            entry = [
                "eventType": "BG Check",
                "glucose": unit == .mgdl ? glucose.rounded() : glucose,
                "glucoseType": "Finger",
                "units": unit.nightscoutValue,
                "created_at": item.createdAtString,
                "enteredBy": enteredBy
            ]
        } else {
            entry = [
                "eventType": "Carb Correction",
                "carbs": item.carbs,
                "created_at": item.createdAtString,
                "enteredBy": enteredBy
            ]
        }
        // Name of the access token's subject (as in Nightscout API v3), so the history
        // can show who made the entry.
        if let subject = auth.subject, !subject.isEmpty {
            entry["subject"] = subject
        }
        let body: [[String: Any]] = [entry]

        var request = bearerRequest(url, jwt: auth.jwt, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("POST /api/v1/treatments – \(item.displayText), created_at \(item.createdAtString)")

        let (_, response) = try await perform(request)
        logger.info("POST treatments response: \(response.statusCode)")

        switch response.statusCode {
        case 200..<300: return
        case 401, 403:
            await cache.set(nil)
            throw NightscoutError.unauthorized
        default: throw NightscoutError.serverError(response.statusCode)
        }
    }

    // MARK: - History (entries made by this app)

    /// Loads the treatments created by this app (current + legacy `enteredBy`)
    /// within the last `days` days, newest first.
    static func fetchAppTreatments(days: Int = 30, countPerSource: Int = 100) async throws -> [NightscoutTreatment] {
        let creds = try storedCredentials()
        let auth = try await session(base: creds.base, token: creds.token)
        let since = ISO8601DateFormatter.nightscoutFormatter.string(
            from: Date().addingTimeInterval(-Double(days) * 86_400))

        var result: [String: NightscoutTreatment] = [:]
        for name in [enteredBy] + legacyEnteredBy {
            guard var comps = URLComponents(string: "\(creds.base)/api/v1/treatments.json") else {
                throw NightscoutError.invalidURL
            }
            comps.queryItems = [
                URLQueryItem(name: "find[enteredBy]", value: name),
                URLQueryItem(name: "find[created_at][$gte]", value: since),
                URLQueryItem(name: "count", value: String(countPerSource))
            ]
            guard let url = comps.url, url.host != nil else { throw NightscoutError.invalidURL }

            let (data, http) = try await perform(bearerRequest(url, jwt: auth.jwt))
            logger.info("GET treatments (enteredBy \(name)): HTTP \(http.statusCode), \(data.count) bytes")
            switch http.statusCode {
            case 200..<300: break
            case 401, 403:
                await cache.set(nil)
                throw NightscoutError.unauthorized
            default:
                throw NightscoutError.serverError(http.statusCode)
            }
            let array = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            for obj in array {
                if let t = NightscoutTreatment(json: obj) { result[t.id] = t }
            }
        }
        return result.values.sorted { $0.date > $1.date }
    }

    /// Whether the stored access token may delete treatments. Nil if unknown (not configured / offline).
    static func deletePermitted() async -> Bool? {
        guard let creds = try? storedCredentials(),
              let auth = try? await session(base: creds.base, token: creds.token) else { return nil }
        return permits(auth.permissions, "api:treatments:delete")
    }

    /// Deletes one treatment in Nightscout (`DELETE /api/v1/treatments/<_id>`).
    static func deleteTreatment(id: String) async throws {
        let creds = try storedCredentials()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(creds.base)/api/v1/treatments/\(encoded)"), url.host != nil else {
            throw NightscoutError.invalidURL
        }
        let auth = try await session(base: creds.base, token: creds.token)
        let (_, http) = try await perform(bearerRequest(url, jwt: auth.jwt, method: "DELETE"))
        logger.info("DELETE /api/v1/treatments/\(id): HTTP \(http.statusCode)")
        switch http.statusCode {
        case 200..<300: return
        case 401, 403:
            await cache.set(nil)
            if !permits(auth.permissions, "api:treatments:delete") {
                throw NightscoutError.deleteForbidden
            }
            throw NightscoutError.unauthorized
        default:
            throw NightscoutError.serverError(http.statusCode)
        }
    }

    // MARK: - Connection test

    static func testConnection(urlString: String, token rawToken: String) async -> ConnectionTestResult {
        var result = ConnectionTestResult()
        let base = normalizedBase(urlString)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        await cache.set(nil)

        guard let statusURL = URL(string: "\(base)/api/v1/status.json"), statusURL.host != nil else {
            result.reachable = .failed
            result.reachableDetail = "Ungültige URL"
            return result
        }

        // 1) Exchange access token -> JWT (also proves the server is reachable)
        let auth: AuthSession
        do {
            switch try await authorize(base: base, token: token) {
            case .session(let s):
                auth = s
                result.reachable = .ok
                result.reachableDetail = "Server erreichbar, Access Token gültig"
                result.subject = s.subject
            case .invalidToken(let code):
                result.reachable = .ok
                result.reachableDetail = "Server erreichbar – Access Token wird aber nicht erkannt (HTTP \(code))"
                result.canRead = .failed
                result.canWrite = .failed
                result.readDetail = "Access Token ungültig – bitte exakt aus Nightscout (Admin-Werkzeuge) kopieren"
                result.writeDetail = result.readDetail
                return result
            }
        } catch NightscoutError.serverError(let code) {
            result.reachable = .failed
            result.reachableDetail = code == 404
                ? "Keine Nightscout-Instanz (oder zu alte Version ohne API v2) unter dieser URL (HTTP 404)"
                : "Server antwortet mit HTTP \(code)"
            return result
        } catch {
            result.reachable = .failed
            result.reachableDetail = error.localizedDescription
            return result
        }

        // 2) Server info
        if let resp = try? await perform(bearerRequest(statusURL, jwt: auth.jwt)) {
            let (data, http) = resp
            logger.info("Test status.json: \(http.statusCode)")
            if (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = json["name"] as? String ?? "Nightscout"
                let version = json["version"] as? String ?? "?"
                result.serverInfo = "\(name) \(version)"
            }
        }

        // 3) Read: permission + real read of the latest treatment
        let readPermitted = permits(auth.permissions, "api:treatments:read")
        if let readURL = URL(string: "\(base)/api/v1/treatments.json?count=1"),
           let resp = try? await perform(bearerRequest(readURL, jwt: auth.jwt)) {
            let code = resp.1.statusCode
            logger.info("Test read treatments: \(code)")
            result.canRead = (200..<300).contains(code) ? .ok : .failed
        } else {
            result.canRead = readPermitted ? .ok : .failed
        }

        // 4) Write: derived from the token's permissions (nothing is written during the test)
        result.canWrite = permits(auth.permissions, "api:treatments:create") ? .ok : .failed

        let roleText = auth.permissions.isEmpty ? "keine" : auth.permissions.joined(separator: ", ")
        result.readDetail = result.canRead == .ok
            ? "Behandlungen können gelesen werden"
            : "Keine Leseberechtigung – Rolle z.B. „readable“ vergeben (Rechte: \(roleText))"
        result.writeDetail = result.canWrite == .ok
            ? "KH-Einträge können geschrieben werden"
            : "Keine Schreibberechtigung – Rolle z.B. „careportal“ vergeben (Rechte: \(roleText))"
        return result
    }

    // MARK: - Helpers

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NightscoutError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NightscoutError.networkError("Unbekannte Antwort")
        }
        return (data, http)
    }
}

extension ISO8601DateFormatter {
    static let nightscoutFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let nightscoutFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// A treatment as stored in Nightscout (only the fields this app needs).
struct NightscoutTreatment: Identifiable, Hashable {
    let id: String
    let eventType: String
    let carbs: Double?
    let glucose: Double?
    let units: String?
    let date: Date
    /// Name of the access token (subject) that created the entry; nil for older entries.
    let subject: String?

    init?(json: [String: Any]) {
        guard let id = json["_id"] as? String else { return nil }
        self.id = id
        self.eventType = json["eventType"] as? String ?? ""
        self.carbs = Self.number(json["carbs"])
        self.glucose = Self.number(json["glucose"])
        self.units = json["units"] as? String
        let rawSubject = (json["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = (rawSubject?.isEmpty ?? true) ? nil : rawSubject

        if let s = json["created_at"] as? String,
           let d = ISO8601DateFormatter.nightscoutFormatter.date(from: s)
            ?? ISO8601DateFormatter.nightscoutFormatterNoFraction.date(from: s) {
            self.date = d
        } else if let ms = Self.number(json["mills"]) ?? Self.number(json["date"]) {
            self.date = Date(timeIntervalSince1970: ms / 1000)
        } else {
            return nil
        }
    }

    var isGlucose: Bool { glucose != nil && (carbs ?? 0) == 0 }

    var glucoseUnit: GlucoseUnit {
        guard let u = units?.lowercased() else { return GlucoseUnit.current }
        return u.contains("mmol") ? .mmol : .mgdl
    }

    var displayText: String {
        if isGlucose, let g = glucose {
            return "BZ \(glucoseUnit.format(g)) \(glucoseUnit.label)"
        }
        let c = carbs ?? 0
        let text = c == c.rounded() ? String(Int(c)) : c.formatted(.number.precision(.fractionLength(1)))
        return "\(text) g KH"
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }
}
