import CoreModels
import Foundation

/// The API as a zone source — first in the provider chain, filling the
/// seam ZoneProviding was built for (docs/21). Three-valued like every
/// provider: `nil` (unreachable, mock mode, or the server's own map source
/// was down) falls through to OverpassZoneProvider; `[]` is a real answer.
///
/// Server zones use the same (day, centroid) id formula the client
/// computes, so partial mile progress keys identically whichever side
/// answered — switching providers mid-day never orphans a walk.
public struct HTTPZoneProvider: ZoneProviding {
    private let api: any GemRunAPI

    public init(api: any GemRunAPI = API.shared) {
        self.api = api
    }

    public func zones(around center: Coordinate, day: Int) async -> [RunnerZone]? {
        // Mock mode has no zone endpoint worth asking — fall straight
        // through to the on-device providers instead of stopping the chain
        // with the mock's empty answer.
        guard AppConfig.apiBaseURL != nil else { return nil }
        do {
            let page = try await api.zones(lat: center.lat, lng: center.lng,
                                           day: day)
            GemLog.api.info("zones: server answered with \(page.zones.count, privacy: .public)")
            return page.zones
        } catch {
            GemLog.api.info("zones: server unavailable, falling through — \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
