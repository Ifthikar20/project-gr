import CoreModels
import Foundation

/// URLSession client for the /v1 contract (docs/06). Fully wired in Phase F;
/// until then feature code talks to `RouteProviding`-style protocols backed by fixtures.
public struct APIClient: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // TODO(Phase F): auth exchange + refresh, DTO mapping, RFC 7807 error decoding,
    // idempotent run completion (docs/06).
}
