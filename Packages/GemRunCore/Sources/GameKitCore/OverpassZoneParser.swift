import CoreModels
import Foundation

/// The pure half of the Overpass zone source: builds the one query a day's
/// zones need, and classifies the answer into ZonePlacementData. Lives in
/// GameKitCore so fixtures can exercise it without a network — the POST
/// itself is CoreNetworking's OverpassZoneProvider.
///
/// Classification is the backend's, ported: green polygons anchor, strict
/// pedestrian ways score, closed rings matching the no-go tag set veto
/// (walkability.NO_GO_AREA_FILTERS / _is_no_go_tags). Multipolygon
/// relations are not resolved — the same v1 limitation the server accepts;
/// closed ways cover the common private grounds.
public enum OverpassZoneParser {
    /// Tag sets, verbatim from the backend.
    static let parkLeisure: Set<String> = ["park", "nature_reserve", "garden"]
    static let trailHighways: Set<String> = ["footway", "pedestrian", "path"]

    // MARK: - Query

    /// One request for everything zone selection needs in a circle: parks,
    /// strict pedestrian ways, and every no-go polygon — split client-side
    /// by tags and closure, like the backend's placement-data query.
    public static func query(lat: Double, lng: Double,
                             radiusM: Int, timeoutS: Int) -> String {
        let at = String(format: "(around:%d,%.6f,%.6f)", radiusM, lat, lng)
        return """
        [out:json][timeout:\(timeoutS)];
        (
          way\(at)["highway"~"^(footway|pedestrian|path)$"]["foot"!~"^(no|private)$"]["access"!~"^(no|private)$"];
          way\(at)["leisure"~"^(park|nature_reserve|garden)$"];
          way\(at)["landuse"="recreation_ground"];
          way\(at)["access"~"^(private|no)$"];
          way\(at)["leisure"="golf_course"];
          way\(at)["amenity"~"^(school|kindergarten|college|university)$"];
          way\(at)["landuse"~"^(military|industrial|railway)$"];
          way\(at)["aeroway"="aerodrome"];
        );
        out geom 1200;
        """
    }

    // MARK: - Response

    struct Payload: Decodable {
        let elements: [Element]
    }

    struct Element: Decodable {
        let type: String
        let tags: [String: String]?
        let geometry: [Point]?
    }

    struct Point: Decodable {
        let lat: Double
        let lon: Double
    }

    public static func placementData(fromJSON data: Data) throws -> ZonePlacementData {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var result = ZonePlacementData()
        for element in payload.elements where element.type == "way" {
            let tags = element.tags ?? [:]
            guard let geometry = element.geometry, geometry.count >= 2 else { continue }
            let coords = geometry.map { Coordinate(lat: $0.lat, lng: $0.lon) }
            let first = coords[0]
            let last = coords[coords.count - 1]
            let closed = abs(first.lat - last.lat) < 1e-6
                && abs(first.lng - last.lng) < 1e-6
            // No-go wins over park: a private park is no-go land.
            if closed, isNoGo(tags) {
                result.noGoRings.append(coords)
            } else if closed, isPark(tags) {
                result.parks.append(.init(name: tags["name"], ring: coords))
            } else if !closed, isTrail(tags) {
                result.trails.append(coords)
            }
        }
        return result
    }

    static func isNoGo(_ tags: [String: String]) -> Bool {
        if let access = tags["access"], access == "private" || access == "no" {
            return true
        }
        if tags["leisure"] == "golf_course" { return true }
        if let amenity = tags["amenity"],
           ["school", "kindergarten", "college", "university"].contains(amenity) {
            return true
        }
        if let landuse = tags["landuse"],
           ["military", "industrial", "railway"].contains(landuse) {
            return true
        }
        return tags["aeroway"] == "aerodrome"
    }

    static func isPark(_ tags: [String: String]) -> Bool {
        if let leisure = tags["leisure"], parkLeisure.contains(leisure) {
            return true
        }
        return tags["landuse"] == "recreation_ground"
    }

    static func isTrail(_ tags: [String: String]) -> Bool {
        guard let highway = tags["highway"], trailHighways.contains(highway) else {
            return false
        }
        if tags["footway"] == "access_aisle" || tags["indoor"] == "yes" {
            return false
        }
        if let access = tags["access"], access == "no" || access == "private" {
            return false
        }
        if let foot = tags["foot"], foot == "no" || foot == "private" {
            return false
        }
        return true
    }
}
