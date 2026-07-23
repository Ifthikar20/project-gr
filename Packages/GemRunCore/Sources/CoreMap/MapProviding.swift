import CoreModels
import MapKit
import SwiftUI

// The map seam (docs/07): nothing outside CoreMap imports a map SDK.
// Current provider is MapKit (free, native, zero-config — app renders dark
// app-wide which keeps the Night Expedition feel). Swapping to Mapbox v11 for
// the custom Studio style means reimplementing only the views in this module
// and adding the SPM dependency + token from Configs/Secrets.xcconfig.

public extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

public enum MapPalette {
    public static let gold = Color(red: 0.95, green: 0.76, blue: 0.29)
    public static func rarity(_ r: Rarity) -> Color {
        switch r {
        case .common: Color(white: 0.92)
        case .uncommon: Color(red: 0.22, green: 0.78, blue: 0.45)
        case .rare: Color(red: 0.25, green: 0.53, blue: 0.96)
        case .epic: Color(red: 0.64, green: 0.36, blue: 0.94)
        case .legendary: Color(red: 0.98, green: 0.62, blue: 0.18)
        }
    }
}

/// Explore home map: user location + route polylines (docs/03 §2).
public struct ExploreMapView: View {
    let routes: [Route]
    let selectedID: UUID?
    let onSelect: (Route) -> Void

    public init(routes: [Route], selectedID: UUID?, onSelect: @escaping (Route) -> Void) {
        self.routes = routes
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    public var body: some View {
        Map(initialPosition: .userLocation(fallback: .automatic)) {
            UserAnnotation()
            ForEach(routes) { route in
                let coords = PolylineCodec.decode(route.polyline).map(\.cl)
                MapPolyline(coordinates: coords)
                    .stroke(MapPalette.gold.opacity(route.id == selectedID ? 1 : 0.65),
                            lineWidth: route.id == selectedID ? 5 : 3)
                if let start = coords.first {
                    Annotation(route.name, coordinate: start) {
                        Button { onSelect(route) } label: {
                            Image(systemName: "diamond.fill")
                                .font(.caption)
                                .foregroundStyle(.black)
                                .padding(6)
                                .background(MapPalette.gold, in: Circle())
                        }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}

/// Route Detail preview: polyline + gem markers, Rare+ fuzzed (docs/03 §3).
public struct RoutePreviewMap: View {
    let route: Route
    let collectedDropIDs: Set<UUID>

    public init(route: Route, collectedDropIDs: Set<UUID> = []) {
        self.route = route
        self.collectedDropIDs = collectedDropIDs
    }

    public var body: some View {
        let coords = PolylineCodec.decode(route.polyline)
        Map(initialPosition: .region(region(for: coords))) {
            MapPolyline(coordinates: coords.map(\.cl))
                .stroke(MapPalette.gold, lineWidth: 4)
            ForEach(route.gemDrops) { drop in
                let isFuzzed = drop.rarity != .common && drop.rarity != .uncommon
                    && !collectedDropIDs.contains(drop.id)
                if isFuzzed {
                    // The hunt: a hint zone, not the exact spot (docs/03).
                    MapCircle(center: drop.coordinate.cl, radius: 150)
                        .foregroundStyle(MapPalette.rarity(drop.rarity).opacity(0.18))
                        .stroke(MapPalette.rarity(drop.rarity).opacity(0.6),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                } else {
                    Annotation("", coordinate: drop.coordinate.cl) {
                        Image(systemName: collectedDropIDs.contains(drop.id)
                              ? "checkmark.circle.fill" : "diamond.fill")
                            .font(.footnote)
                            .foregroundStyle(MapPalette.rarity(drop.rarity))
                            .shadow(radius: 2)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}

/// Creation Step 1 drawing surface (docs/03 §4): taps come back as coordinates.
public struct DrawingMapView: View {
    let pathCoords: [Coordinate]
    let waypoints: [Coordinate]
    let onTap: (Coordinate) -> Void

    public init(pathCoords: [Coordinate], waypoints: [Coordinate],
                onTap: @escaping (Coordinate) -> Void) {
        self.pathCoords = pathCoords
        self.waypoints = waypoints
        self.onTap = onTap
    }

    public var body: some View {
        MapReader { proxy in
            Map(initialPosition: .userLocation(fallback: .automatic)) {
                UserAnnotation()
                if pathCoords.count > 1 {
                    MapPolyline(coordinates: pathCoords.map(\.cl))
                        .stroke(MapPalette.gold, lineWidth: 4)
                }
                ForEach(Array(waypoints.enumerated()), id: \.offset) { i, wp in
                    Annotation("", coordinate: wp.cl) {
                        Text("\(i + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .frame(width: 20, height: 20)
                            .background(MapPalette.gold, in: Circle())
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture(coordinateSpace: .local) { screenPoint in
                if let coord = proxy.convert(screenPoint, from: .local) {
                    onTap(Coordinate(lat: coord.latitude, lng: coord.longitude))
                }
            }
        }
    }
}

/// Active Run chase map (docs/03 §7): follows the runner, shows gems ahead.
public struct ActiveRunMapView: View {
    let route: Route
    let runnerPosition: Coordinate?
    let collectedDropIDs: Set<UUID>

    public init(route: Route, runnerPosition: Coordinate?, collectedDropIDs: Set<UUID>) {
        self.route = route
        self.runnerPosition = runnerPosition
        self.collectedDropIDs = collectedDropIDs
    }

    public var body: some View {
        Map(position: .constant(camera)) {
            MapPolyline(coordinates: PolylineCodec.decode(route.polyline).map(\.cl))
                .stroke(MapPalette.gold, lineWidth: 4)
            ForEach(route.gemDrops) { drop in
                Annotation("", coordinate: drop.coordinate.cl) {
                    Image(systemName: collectedDropIDs.contains(drop.id)
                          ? "checkmark.circle.fill" : "diamond.fill")
                        .font(.footnote)
                        .foregroundStyle(MapPalette.rarity(drop.rarity))
                }
            }
            if let runner = runnerPosition {
                Annotation("", coordinate: runner.cl) {
                    Circle().fill(.blue)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    private var camera: MapCameraPosition {
        if let runner = runnerPosition {
            .camera(MapCamera(centerCoordinate: runner.cl, distance: 900))
        } else {
            .region(region(for: PolylineCodec.decode(route.polyline)))
        }
    }
}

func region(for coords: [Coordinate]) -> MKCoordinateRegion {
    guard !coords.isEmpty else {
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                  span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))
    }
    let lats = coords.map(\.lat), lngs = coords.map(\.lng)
    let minLat = lats.min()!, maxLat = lats.max()!
    let minLng = lngs.min()!, maxLng = lngs.max()!
    return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                       longitude: (minLng + maxLng) / 2),
        span: MKCoordinateSpan(latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
                               longitudeDelta: max(0.005, (maxLng - minLng) * 1.4)))
}

/// Snap consecutive waypoints to walkable paths via MKDirections (docs/03 §4).
/// Falls back to a straight segment when routing fails.
public enum PathSnapper {
    public static func snap(from a: Coordinate, to b: Coordinate) async -> [Coordinate] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.cl))
        request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let poly = response.routes.first?.polyline else { return [a, b] }
            var coords = [CLLocationCoordinate2D](repeating: .init(), count: poly.pointCount)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
            return coords.map { Coordinate(lat: $0.latitude, lng: $0.longitude) }
        } catch {
            return [a, b]
        }
    }
}
