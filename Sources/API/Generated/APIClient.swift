import Foundation

enum APIError: Error, LocalizedError {
    case noBaseURL
    case invalidURL
    case http(status: Int, message: String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .noBaseURL: return "No backend is configured for this app."
        case .invalidURL: return "Invalid request URL."
        case .http(let status, let message): return message ?? "Request failed (HTTP \(status))."
        case .decoding(let error): return "Failed to decode server response: \(error)"
        }
    }
}

/// URLSession-based client. Generated endpoint methods live in Endpoints.swift
/// (Sources/API/Generated — regenerated from the backend's OpenAPI spec; never edit).
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        // NestJS/Prisma serialize dates with fractional seconds; plain .iso8601 rejects
        // them, so try fractional first and fall back.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractional.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(raw)")
        }
    }

    var authToken: String? {
        get { KeychainHelper.authToken }
        set { KeychainHelper.authToken = newValue }
    }

    // MARK: - Request variants (JSON in/out, JSON out only, fire-and-forget)

    func request<T: Decodable>(path: String, method: String, query: [String: String?] = [:]) async throws -> T {
        try decodeResponse(try await send(path: path, method: method, query: query, bodyData: nil))
    }

    func request<B: Encodable, T: Decodable>(path: String, method: String, query: [String: String?] = [:], body: B) async throws -> T {
        try decodeResponse(try await send(path: path, method: method, query: query, bodyData: try encoder.encode(body)))
    }

    func requestVoid(path: String, method: String, query: [String: String?] = [:]) async throws {
        _ = try await send(path: path, method: method, query: query, bodyData: nil)
    }

    func requestVoid<B: Encodable>(path: String, method: String, query: [String: String?] = [:], body: B) async throws {
        _ = try await send(path: path, method: method, query: query, bodyData: try encoder.encode(body))
    }

    // MARK: - Internals

    private func decodeResponse<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private func send(path: String, method: String, query: [String: String?], bodyData: Data?) async throws -> Data {
        guard let base = AppConfig.apiBaseURL else { throw APIError.noBaseURL }
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = Self.serverMessage(from: data)
            throw APIError.http(status: status, message: message)
        }
        // Empty bodies decode as Void via requestVoid; "{}" placeholder keeps T=EmptyResponse working.
        return data.isEmpty ? Data("{}".utf8) : data
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let messages = object["message"] as? [String] { return messages.joined(separator: "\n") }
        return object["error"] as? String
    }
}

struct EmptyResponse: Codable, Hashable {}
