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

// Mirrors DesignSystem's 3-color "Daybreak Pulse" tokens (CoreMap stays
// independent of DesignSystem by design — docs/07 dependency rule).
public enum MapPalette {
    public static let pulse = Color(red: 0.988, green: 0.298, blue: 0.008)   // #FC4C02
    public static let ink = Color(red: 0.086, green: 0.094, blue: 0.114)     // #16181D

    public static func rarity(_ r: Rarity) -> Color {
        let step: Double = switch r {
        case .common: 0.30
        case .uncommon: 0.50
        case .rare: 0.70
        case .epic: 0.88
        case .legendary: 1.0
        }
        return pulse.opacity(step)
    }

    public static func glyph(_ r: Rarity) -> String {
        switch r {
        case .common: "diamond"
        case .uncommon: "diamond.fill"
        case .rare: "rhombus.fill"
        case .epic: "seal.fill"
        case .legendary: "crown.fill"
        }
    }

    /// Gem-shaped emoji tier — fallback when we only know rarity, not type.
    public static func emoji(_ r: Rarity) -> String {
        switch r {
        case .common: "🔹"
        case .uncommon: "🔷"
        case .rare: "💎"
        case .epic: "💠"
        case .legendary: "👑"
        }
    }

    /// Named-gem emoji: each catalog iconRef gets a distinct color so runners
    /// see "there's a ruby over there" not "there's a rare gem over there."
    public static func emoji(forIconRef ref: String) -> String {
        switch ref {
        case "gem.quartz": "💎"
        case "gem.emerald": "💚"
        case "gem.sapphire": "💙"
        case "gem.ruby": "❤️"
        case "gem.topaz": "💛"
        case "gem.amethyst": "💜"
        case "gem.ember": "🔥"
        default: "💎"
        }
    }

    /// Convenience: look up the emoji for a specific dropped gem by its ID.
    public static func emoji(forGemID id: UUID) -> String {
        guard let entry = GemCatalog.entry(forGemID: id) else { return "💎" }
        return emoji(forIconRef: entry.gem.iconRef)
    }
}

/// A gem pin that falls onto the map with a spring (the pin-drop animation).
/// Renders the specific gem type's emoji when given a gemID; otherwise falls
/// back to a rarity-tier emoji.
public struct DropPin: View {
    let emoji: String
    @State private var dropped = false

    public init(gemID: UUID) {
        self.emoji = MapPalette.emoji(forGemID: gemID)
    }

    public init(rarity: Rarity) {
        self.emoji = MapPalette.emoji(rarity)
    }

    public var body: some View {
        Text(emoji)
            .font(.title2)
            .shadow(color: .white, radius: 2)
            .shadow(color: MapPalette.ink.opacity(0.35), radius: 3, y: 1)
            .offset(y: dropped ? 0 : -30)
            .scaleEffect(dropped ? 1 : 1.3, anchor: .bottom)
            .opacity(dropped ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                    dropped = true
                }
            }
    }
}

/// Explore home map: user location, route polylines, and standalone gem
/// drops other runners left behind (docs/03 §2). When `onTapCoordinate` is
/// set (drop mode), map taps come back as coordinates.
public struct ExploreMapView: View {
    let routes: [Route]
    let standaloneDrops: [GemDrop]
    let selectedID: UUID?
    /// Snapped preview polyline (destination mode: user → dropped pin).
    let previewPath: [Coordinate]
    /// A destination pin the user just dropped for a point-to-point run.
    let destinationPin: Coordinate?
    /// The runner's live location — when present, renders as an emoji marker
    /// (in place of MapKit's default blue dot) so "here I am" is unmissable.
    let userCoordinate: Coordinate?
    /// A dotted "run this and you'll collect gems" line: user → nearest gems
    /// stitched together, drawn under everything else.
    let suggestedPath: [Coordinate]
    let onSelect: (Route) -> Void
    let onTapCoordinate: ((Coordinate) -> Void)?

    public init(routes: [Route], standaloneDrops: [GemDrop] = [], selectedID: UUID?,
                previewPath: [Coordinate] = [],
                destinationPin: Coordinate? = nil,
                userCoordinate: Coordinate? = nil,
                suggestedPath: [Coordinate] = [],
                onSelect: @escaping (Route) -> Void,
                onTapCoordinate: ((Coordinate) -> Void)? = nil) {
        self.routes = routes
        self.standaloneDrops = standaloneDrops
        self.selectedID = selectedID
        self.previewPath = previewPath
        self.destinationPin = destinationPin
        self.userCoordinate = userCoordinate
        self.suggestedPath = suggestedPath
        self.onSelect = onSelect
        self.onTapCoordinate = onTapCoordinate
    }

    public var body: some View {
        MapReader { proxy in
            mapContent
                .onTapGesture(coordinateSpace: .local) { screenPoint in
                    guard let onTapCoordinate,
                          let coord = proxy.convert(screenPoint, from: .local) else { return }
                    onTapCoordinate(Coordinate(lat: coord.latitude, lng: coord.longitude))
                }
        }
    }

    private var mapContent: some View {
        Map(initialPosition: .userLocation(fallback: .automatic)) {
            // Suggested path: draw first so gem pins + user marker sit on top.
            // Dotted (very short dashes) reads as "a suggestion, not committed."
            if suggestedPath.count > 1 {
                MapPolyline(coordinates: suggestedPath.map(\.cl))
                    .stroke(MapPalette.pulse.opacity(0.75),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                               dash: [1, 9]))
            }
            if let userCoordinate {
                Annotation("You", coordinate: userCoordinate.cl) {
                    Text("🏃")
                        .font(.title)
                        .shadow(color: .white, radius: 2)
                        .shadow(color: MapPalette.ink.opacity(0.35), radius: 3, y: 1)
                }
            }
            // No UserAnnotation fallback: its accuracy halo reads as a big
            // translucent circle on the map. Once we have a live fix (usually
            // within a second of opening), the 🏃 emoji above takes over.
            ForEach(standaloneDrops) { drop in
                Annotation("", coordinate: drop.coordinate.cl) {
                    DropPin(gemID: drop.gemID)
                }
            }
            // Point-to-point preview: dashed pulse line from the user to the
            // dropped destination pin, so runners see the path before starting.
            if previewPath.count > 1 {
                MapPolyline(coordinates: previewPath.map(\.cl))
                    .stroke(MapPalette.pulse,
                            style: StrokeStyle(lineWidth: 4, dash: [8, 5]))
            }
            if let destinationPin {
                Annotation("", coordinate: destinationPin.cl) {
                    DestinationPin()
                }
            }
            ForEach(routes) { route in
                let coords = PolylineCodec.decode(route.polyline).map(\.cl)
                MapPolyline(coordinates: coords)
                    .stroke(MapPalette.pulse.opacity(route.id == selectedID ? 1 : 0.65),
                            lineWidth: route.id == selectedID ? 5 : 3)
                if let start = coords.first {
                    Annotation(route.name, coordinate: start) {
                        Button { onSelect(route) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "diamond.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("\(route.gemDrops.count)")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(MapPalette.pulse, in: Capsule())
                            .shadow(color: MapPalette.ink.opacity(0.2), radius: 4, y: 1)
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
                .stroke(MapPalette.pulse, lineWidth: 4)
            ForEach(route.gemDrops) { drop in
                Annotation("", coordinate: drop.coordinate.cl) {
                    if collectedDropIDs.contains(drop.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(MapPalette.ink.opacity(0.35))
                    } else {
                        Text(MapPalette.emoji(forGemID: drop.gemID))
                            .font(.callout)
                            .shadow(color: .white, radius: 2)
                            .shadow(color: MapPalette.ink.opacity(0.25), radius: 2)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}

/// Creation Step 1 drawing surface (docs/03 §4): taps come back as
/// coordinates. `destination` renders a large animated destination pin.
public struct DrawingMapView: View {
    let pathCoords: [Coordinate]
    let waypoints: [Coordinate]
    let destination: Coordinate?
    let onTap: (Coordinate) -> Void

    public init(pathCoords: [Coordinate], waypoints: [Coordinate],
                destination: Coordinate? = nil,
                onTap: @escaping (Coordinate) -> Void) {
        self.pathCoords = pathCoords
        self.waypoints = waypoints
        self.destination = destination
        self.onTap = onTap
    }

    public var body: some View {
        MapReader { proxy in
            Map(initialPosition: .userLocation(fallback: .automatic)) {
                if pathCoords.count > 1 {
                    MapPolyline(coordinates: pathCoords.map(\.cl))
                        .stroke(MapPalette.pulse, lineWidth: 4)
                }
                ForEach(Array(waypoints.enumerated()), id: \.offset) { i, wp in
                    Annotation("", coordinate: wp.cl) {
                        Text("\(i + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(MapPalette.pulse, in: Circle())
                            .shadow(color: MapPalette.ink.opacity(0.2), radius: 3, y: 1)
                            .transition(.scale(scale: 1.3, anchor: .bottom)
                                .combined(with: .opacity))
                    }
                }
                if let destination {
                    Annotation("", coordinate: destination.cl) {
                        DestinationPin()
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

/// A tall destination pin that drops in with a spring.
public struct DestinationPin: View {
    @State private var dropped = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "mappin.circle.fill")
                .font(.title)
                .foregroundStyle(.white, MapPalette.pulse)
                .shadow(color: MapPalette.ink.opacity(0.3), radius: 4, y: 2)
            Triangle()
                .fill(MapPalette.pulse)
                .frame(width: 10, height: 8)
        }
        .offset(y: dropped ? -4 : -44)
        .opacity(dropped ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                dropped = true
            }
        }
    }

    struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }
}

/// Active Run chase map (docs/03 §7): follows the runner, shows gems ahead.
/// `route` is nil on a free run — only standalone drops render.
/// Camera behaves like Google Maps nav: low altitude, 60° pitch, rotated to
/// the current direction of travel so the runner is always heading "up."
public struct ActiveRunMapView: View {
    let route: Route?
    let freeDrops: [GemDrop]
    let runnerPosition: Coordinate?
    let collectedDropIDs: Set<UUID>

    /// Remembers the previous sample so we can compute bearing frame-to-frame.
    @State private var previousRunner: Coordinate?
    @State private var heading: CLLocationDirection = 0

    public init(route: Route?, freeDrops: [GemDrop] = [], runnerPosition: Coordinate?,
                collectedDropIDs: Set<UUID>) {
        self.route = route
        self.freeDrops = freeDrops
        self.runnerPosition = runnerPosition
        self.collectedDropIDs = collectedDropIDs
    }

    private var drops: [GemDrop] {
        route?.gemDrops ?? freeDrops
    }

    public var body: some View {
        Map(position: .constant(camera)) {
            if let route {
                MapPolyline(coordinates: PolylineCodec.decode(route.polyline).map(\.cl))
                    .stroke(MapPalette.pulse, lineWidth: 4)
            }
            ForEach(drops) { drop in
                Annotation("", coordinate: drop.coordinate.cl) {
                    if collectedDropIDs.contains(drop.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(MapPalette.ink.opacity(0.35))
                    } else {
                        Text(MapPalette.emoji(forGemID: drop.gemID))
                            .font(.callout)
                            .shadow(color: .white, radius: 2)
                            .shadow(color: MapPalette.ink.opacity(0.25), radius: 2)
                    }
                }
            }
            if let runner = runnerPosition {
                Annotation("", coordinate: runner.cl) {
                    // Chevron pointing "up" matches the camera's heading so it
                    // always reads as "forward" in the perspective view.
                    Image(systemName: "location.north.fill")
                        .font(.title2)
                        .foregroundStyle(MapPalette.pulse)
                        .shadow(color: .white, radius: 2)
                        .shadow(color: MapPalette.ink.opacity(0.4), radius: 3, y: 1)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onChange(of: runnerPosition?.lat) { _, _ in updateHeading() }
        .onChange(of: runnerPosition?.lng) { _, _ in updateHeading() }
    }

    /// Bearing from the previous sample to the current one, in degrees clockwise
    /// from north. Ignores GPS jitter below ~5 m so the camera doesn't spin.
    private func updateHeading() {
        guard let curr = runnerPosition else { return }
        defer { previousRunner = curr }
        guard let prev = previousRunner else { return }
        let mPerDegLat = 111_320.0
        let dy = (curr.lat - prev.lat) * mPerDegLat
        let dx = (curr.lng - prev.lng) * mPerDegLat * cos(curr.lat * .pi / 180)
        guard (dx * dx + dy * dy).squareRoot() > 5 else { return }
        let bearing = atan2(dx, dy) * 180 / .pi
        heading = (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    private var camera: MapCameraPosition {
        if let runner = runnerPosition {
            // Google-Maps-nav feel: low altitude, tilted, rotated to travel dir.
            .camera(MapCamera(centerCoordinate: runner.cl,
                              distance: 350, heading: heading, pitch: 60))
        } else if let route {
            .region(region(for: PolylineCodec.decode(route.polyline)))
        } else {
            .userLocation(fallback: .automatic)
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
