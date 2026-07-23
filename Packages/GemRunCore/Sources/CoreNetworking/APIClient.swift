import CoreModels
import Foundation

// The /v1 client (docs/06). The app is local-first until the FastAPI backend
// exists: `APIClient.configured` is nil without a base URL, and all call sites
// treat that as "offline mode". Wire a URL in AppConfig to go live.

public enum AppConfig {
    /// Set to the deployed backend URL to enable networking (Phase F).
    public static let apiBaseURL: URL? = nil
}

public struct APIError: Error, Decodable {
    public let title: String
    public let detail: String?
    public let code: String?
}

public struct RunVerdictDTO: Decodable, Sendable {
    public let validationStatus: String
    public let awarded: [AwardDTO]
    public let revoked: [UUID]
    public let xpEarned: Int

    public struct AwardDTO: Decodable, Sendable {
        public let gemDropID: UUID
        public let xp: Int
    }
}

public final class APIClient: Sendable {
    public static let configured: APIClient? = AppConfig.apiBaseURL.map(APIClient.init)

    private let baseURL: URL
    private let session = URLSession.shared
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL) {
        self.baseURL = baseURL
        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Endpoints (docs/06)

    public func nearbyRoutes(lat: Double, lng: Double, radiusM: Int) async throws -> [Route] {
        try await get("routes", query: [
            "lat": "\(lat)", "lng": "\(lng)", "radius_m": "\(radiusM)",
        ])
    }

    public func route(id: UUID) async throws -> Route {
        try await get("routes/\(id.uuidString)")
    }

    public func publish(route: Route) async throws -> Route {
        try await send("POST", "routes", body: route)
    }

    public struct CompletionRequest: Encodable, Sendable {
        public let idempotencyKey: String
        public let startedAt: Date
        public let endedAt: Date
        public let track: [TrackSample]
        public let claimedCollections: [UUID]
        public let clientFlags: [String]

        public init(idempotencyKey: String, startedAt: Date, endedAt: Date,
                    track: [TrackSample], claimedCollections: [UUID], clientFlags: [String]) {
            self.idempotencyKey = idempotencyKey
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.track = track
            self.claimedCollections = claimedCollections
            self.clientFlags = clientFlags
        }
    }

    /// The authoritative verdict call — client collection is optimistic and
    /// this response may revoke (docs/06). App Attest attachment: TODO when
    /// the backend exists to verify it.
    public func completeRun(routeID: UUID, request: CompletionRequest) async throws -> RunVerdictDTO {
        try await send("POST", "runs/\(routeID.uuidString)/complete", body: request)
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: "v1/\(path)"),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let (data, response) = try await session.data(from: components.url!)
        return try decode(data, response)
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String,
                                                  body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "v1/\(path)"))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw (try? decoder.decode(APIError.self, from: data))
                ?? APIError(title: "HTTP \(http.statusCode)", detail: nil, code: nil)
        }
        return try decoder.decode(T.self, from: data)
    }
}
