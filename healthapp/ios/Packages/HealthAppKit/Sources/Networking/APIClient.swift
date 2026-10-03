import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoreModels

public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }

public struct QueryItem: Hashable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

/// `{ "error": { "code", "message", "details" } }` (docs/03 §3.1 "Errors").
public struct APIErrorEnvelope: Decodable, Sendable {
    public struct Body: Decodable, Sendable {
        public var code: String
        public var message: String
    }
    public var error: Body
}

public enum APIError: Error, Equatable, Sendable, LocalizedError {
    case notAuthenticated
    case http(status: Int, code: String?, message: String?)
    case decoding(String)
    case transport(String)
    case invalidURL(String)

    public var status: Int? { if case .http(let s, _, _) = self { return s }; return nil }
    public var code: String? { if case .http(_, let c, _) = self { return c }; return nil }

    /// User-facing copy for AI/limit errors (docs/03 §3.1): 422 AI_REFUSED, 502 AI_INCOMPLETE, 429 RATE_LIMITED.
    public static func friendlyMessage(status: Int, code: String?) -> String? {
        switch (status, code) {
        case (422, "AI_REFUSED"?): return "We couldn't analyse this photo. Try a clearer photo of the food, or add items by search or barcode."
        case (502, "AI_INCOMPLETE"?): return "The analysis didn't finish. Please try again in a moment — or log the items manually."
        case (429, _): return "You've reached the limit for AI requests for now. You can still log by search, barcode or scale, and try again later."
        case (413, _): return "That photo is too large to upload. Try another photo."
        default: return nil
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .http(let status, _, _): return status == 429 || status == 500 || status == 502 || status == 503 || status == 504
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "You're signed out. Please sign in again."
        case .http(let status, let code, let message):
            if let friendly = APIError.friendlyMessage(status: status, code: code) { return friendly }
            return message ?? "Request failed (\(code ?? "HTTP \(status)"))."
        case .decoding(let d): return "Unexpected response from server. \(d)"
        case .transport(let t): return "Network problem: \(t)"
        case .invalidURL(let u): return "Invalid URL \(u)"
        }
    }
}

/// Marker for endpoints that return no body (202/204).
public struct EmptyResponse: Codable, Sendable, Equatable { public init() {} }

/// A typed description of one HTTP route.
public struct Endpoint<Response: Decodable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [QueryItem]
    public var body: Data?
    /// Sent as `Idempotency-Key` on mutating requests (the client entity UUID).
    public var idempotencyKey: String?
    public var requiresAuth: Bool

    public init(_ method: HTTPMethod, _ path: String, query: [QueryItem] = [], body: Data? = nil,
                idempotencyKey: String? = nil, requiresAuth: Bool = true) {
        self.method = method; self.path = path; self.query = query; self.body = body
        self.idempotencyKey = idempotencyKey; self.requiresAuth = requiresAuth
    }

    public init<Body: Encodable>(_ method: HTTPMethod, _ path: String, query: [QueryItem] = [], json: Body,
                                 idempotencyKey: String? = nil, requiresAuth: Bool = true) throws {
        let data = try JSONCoding.makeEncoder().encode(json)
        self.init(method, path, query: query, body: data, idempotencyKey: idempotencyKey, requiresAuth: requiresAuth)
    }
}

/// Abstracts the HTTP stack so tests can inject canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        #if !canImport(FoundationNetworking)
        config.waitsForConnectivity = false
        #endif
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: APIError.transport(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: APIError.transport("No HTTP response")); return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
        #else
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response") }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        #endif
    }
}

/// Supplies Cognito access tokens. `forceRefresh` is set after a 401.
public typealias AccessTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String?

/// async/await client for the HealthApp HTTP API (docs/03). Adds bearer auth, idempotency keys,
/// JSON coding, error-envelope decoding and retry with exponential backoff for 429/5xx/transport errors.
public final class APIClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport
    private let tokenProvider: AccessTokenProvider
    private let maxRetries: Int
    private let baseDelay: Double

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(), maxRetries: Int = 3,
                baseDelay: Double = 0.5, tokenProvider: @escaping AccessTokenProvider) {
        self.baseURL = baseURL; self.transport = transport; self.maxRetries = maxRetries
        self.baseDelay = baseDelay; self.tokenProvider = tokenProvider
    }

    public func send<Response: Decodable>(_ endpoint: Endpoint<Response>) async throws -> Response {
        var attempt = 0
        var didRefresh = false
        var refreshNext = false
        while true {
            do {
                let request = try await makeRequest(endpoint, forceRefresh: refreshNext)
                refreshNext = false
                let (data, response) = try await transport.send(request)
                return try handle(data: data, response: response)
            } catch let error as APIError {
                if error.status == 401, endpoint.requiresAuth, !didRefresh {
                    didRefresh = true // refresh the token once, then retry
                    refreshNext = true
                    continue
                }
                guard error.isRetryable, attempt < maxRetries, endpoint.method == .get || endpoint.idempotencyKey != nil || endpoint.method == .put || endpoint.method == .delete else {
                    throw error
                }
                attempt += 1
                let jitter = Double.random(in: 0...0.25)
                let delay = baseDelay * pow(2, Double(attempt - 1)) + jitter
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// PUT to an S3 presigned URL (no Authorization header).
    /// - Parameter requiredHeaders: headers returned by `/v1/photos/upload-url`; every one must be sent or the S3 signature fails.
    public func uploadPresigned(to url: URL, data: Data, contentType: String = "image/jpeg", requiredHeaders: [String: String] = [:]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in requiredHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = data
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode, code: "UPLOAD_FAILED", message: "Photo upload failed.")
        }
    }

    func makeRequest<R>(_ endpoint: Endpoint<R>, forceRefresh: Bool) async throws -> URLRequest {
        // `endpoint.path` is already percent-encoded per segment (see `API.segment`).
        let trimmed = endpoint.path.hasPrefix("/") ? String(endpoint.path.dropFirst()) : endpoint.path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(endpoint.path)
        }
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + trimmed
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL(endpoint.path) }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key = endpoint.idempotencyKey { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if endpoint.requiresAuth {
            guard let token = try await tokenProvider(forceRefresh) else { throw APIError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func handle<Response: Decodable>(data: Data, response: HTTPURLResponse) throws -> Response {
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? JSONCoding.makeDecoder().decode(APIErrorEnvelope.self, from: data)
            throw APIError.http(status: response.statusCode, code: envelope?.error.code, message: envelope?.error.message)
        }
        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response { return empty }
        if data.isEmpty, let empty = EmptyResponse() as? Response { return empty }
        do {
            return try JSONCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
