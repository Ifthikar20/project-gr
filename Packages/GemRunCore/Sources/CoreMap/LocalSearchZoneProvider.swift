import CoreModels
import Foundation
import GameKitCore
import MapKit

/// Fallback zone source for when Overpass is down: MKLocalSearch park
/// anchors instead of OSM polygons. Apple gives points, not geometry, so
/// each clean anchor gets a synthesized ring and a fixed-size zone, and the
/// count is capped harder — with no no-go polygons to veto against, park
/// pedigree plus a forbidden-POI sweep is the whole safety argument, and
/// fewer zones beat wrong zones.
///
/// The forbidden-category and name-hint sweeps mirror FeatureExplore's
/// DropValidator (internal there, so the small lists are duplicated here
/// on purpose — keep them in step).
public struct LocalSearchZoneProvider: ZoneProviding {
    static let anchorCategories: [MKPointOfInterestCategory] = [
        .park, .nationalPark, .beach,
    ]
    static let forbiddenCategories: [MKPointOfInterestCategory] = [
        .hospital, .school, .university, .airport,
    ]
    static let bannedNameHints = [
        "private", "residence", "apartment", "condominium", "hospital",
        "clinic", "school",
    ]

    /// Fallback zones are conservative: at most three.
    static let maxZones = 3

    public init() {}

    public func zones(around center: Coordinate, day: Int) async -> [RunnerZone]? {
        let request = MKLocalPointsOfInterestRequest(
            center: center.cl, radius: ZoneRules.searchRadiusM * 2)
        request.pointOfInterestFilter =
            MKPointOfInterestFilter(including: Self.anchorCategories)
        guard let response = try? await MKLocalSearch(request: request).start() else {
            // MKLocalSearch needs Apple's servers too — a throw here is
            // "unreachable", not "no parks".
            return nil
        }

        // Nearest six candidate anchors, screened one by one.
        let anchors = response.mapItems
            .map { item in (item, RouteGeometry.planarDistance(
                from: Coordinate(lat: item.placemark.coordinate.latitude,
                                 lng: item.placemark.coordinate.longitude),
                to: center)) }
            .filter { $0.1 <= ZoneRules.searchRadiusM }
            .sorted { $0.1 < $1.1 }
            .prefix(6)

        var parks: [ZonePlacementData.Park] = []
        for (item, _) in anchors {
            let name = item.name ?? "Park"
            let lowered = name.lowercased()
            if Self.bannedNameHints.contains(where: lowered.contains) { continue }
            let coordinate = Coordinate(lat: item.placemark.coordinate.latitude,
                                        lng: item.placemark.coordinate.longitude)
            if await hasForbiddenNeighbor(at: coordinate) { continue }
            parks.append(.init(name: name,
                               ring: Self.syntheticRing(around: coordinate)))
        }
        guard !parks.isEmpty else { return [] }

        // No trails and no no-go rings — the selector switches to park-only
        // scoring and the seeded pick/separation still apply.
        let zones = ZoneSelector.select(data: ZonePlacementData(parks: parks),
                                        around: center, day: day,
                                        source: "localsearch")
        return Array(zones.prefix(Self.maxZones))
    }

    private func hasForbiddenNeighbor(at coordinate: Coordinate) async -> Bool {
        let request = MKLocalPointsOfInterestRequest(center: coordinate.cl,
                                                     radius: 60)
        request.pointOfInterestFilter =
            MKPointOfInterestFilter(including: Self.forbiddenCategories)
        guard let response = try? await MKLocalSearch(request: request).start() else {
            // Can't verify → don't anchor here. Fail closed, like placement.
            return true
        }
        return !response.mapItems.isEmpty
    }

    /// A ~180 m square around the anchor: enough area to clear the
    /// selector's park floor, honest about how little geometry Apple gives.
    static func syntheticRing(around center: Coordinate) -> [Coordinate] {
        let halfM = 90.0
        let mPerDegLat = 111_320.0
        let mPerDegLng = mPerDegLat * cos(center.lat * .pi / 180)
        let dLat = halfM / mPerDegLat
        let dLng = halfM / mPerDegLng
        return [
            Coordinate(lat: center.lat - dLat, lng: center.lng - dLng),
            Coordinate(lat: center.lat - dLat, lng: center.lng + dLng),
            Coordinate(lat: center.lat + dLat, lng: center.lng + dLng),
            Coordinate(lat: center.lat + dLat, lng: center.lng - dLng),
            Coordinate(lat: center.lat - dLat, lng: center.lng - dLng),
        ]
    }
}
