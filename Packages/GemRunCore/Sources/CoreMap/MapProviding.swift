import CoreModels
import GameKitCore
import MapKit
import SwiftUI
import UIKit

// The map seam (docs/07): nothing outside CoreMap imports a map SDK.
// Current provider is MapKit (free, native, zero-config — app renders dark
// app-wide which keeps the Night Expedition feel). Swapping to Mapbox v11 for
// the custom Studio style means reimplementing only the views in this module
// and adding the SPM dependency + token from Configs/Secrets.xcconfig.

public extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

// Mirrors DesignSystem's "Daybreak Pulse" tokens (CoreMap stays
// independent of DesignSystem by design — docs/07 dependency rule).
// Everything CoreMap draws IS map graphics, so its accent is the landing
// page's map green — with ink ON it (green is too bright to carry white).
public enum MapPalette {
    public static let map = Color(red: 0.380, green: 1.0, blue: 0.0)         // #61FF00 map green
    public static let ink = Color(red: 0.086, green: 0.094, blue: 0.114)     // #16181D
    /// Glyphs/text on a solid map-green background.
    public static let onMap = ink

    public static func rarity(_ r: Rarity) -> Color {
        let step: Double = switch r {
        case .common: 0.30
        case .uncommon: 0.50
        case .rare: 0.70
        case .epic: 0.88
        case .legendary: 1.0
        }
        return map.opacity(step)
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
        // Ancient Relics — organic and rock gemstone materials.
        case "gem.bone": "🦴"
        case "gem.copal": "🟡"
        case "gem.spongecoral": "🧽"
        case "gem.motherofpearl": "🦪"
        case "gem.amber": "🍯"
        case "gem.ammonite": "🐚"
        case "gem.jet": "🖤"
        case "gem.fossilcoral": "🪨"
        case "gem.pearl": "⚪️"
        case "gem.redcoral": "🪸"
        case "gem.tektite": "☄️"
        case "gem.ammolite": "🌈"
        case "gem.dinobone": "🦕"
        case "gem.ivory": "🐘"
        default: "💎"
        }
    }

    /// Convenience: look up the emoji for a specific dropped gem by its ID.
    public static func emoji(forGemID id: UUID) -> String {
        guard let entry = GemCatalog.entry(forGemID: id) else { return "💎" }
        return emoji(forIconRef: entry.gem.iconRef)
    }
}

/// THE gem artwork resolver, used by every surface that draws a gem (map
/// pins, info sheet, run card, share card, stash flight). Prefers a custom
/// PNG from the asset catalog — asset name = the catalog `iconRef`, e.g.
/// "gem.amber" — and falls back to the emoji until one exists. Dropping
/// the PNG collection into Assets.xcassets under those names upgrades the
/// whole app at once, no code changes (scripts/import-gem-art.sh does the
/// drop: downscales GEMS_REPO/*.png once and writes the imagesets).
/// Existence verdicts are cached per launch — see GemArtProbe below.
public struct GemIcon: View {
    let gemID: UUID
    let size: CGFloat

    public init(gemID: UUID, size: CGFloat) {
        self.gemID = gemID
        self.size = size
    }

    public var body: some View {
        if let ref = GemCatalog.entry(forGemID: gemID)?.gem.iconRef,
           GemArtProbe.exists(ref) {
            Image(ref)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Text(MapPalette.emoji(forGemID: gemID))
                .font(.system(size: size * 0.82))
        }
    }
}

/// One bundle probe per icon ref per launch. UIImage(named:) caches
/// decoded HITS system-wide, but a MISS re-searches the bundle on every
/// call — and until the full art set ships most refs are misses, with
/// dozens of pins re-rendering on every map change. The verdict cache
/// makes the miss path a dictionary hit.
@MainActor
private enum GemArtProbe {
    private static var verdicts: [String: Bool] = [:]

    static func exists(_ ref: String) -> Bool {
        if let known = verdicts[ref] { return known }
        let present = UIImage(named: ref) != nil
        verdicts[ref] = present
        return present
    }
}

/// The 200 ft capture zone drawn around an uncollected gem — a real
/// geographic circle at the SAME radius the collection engines award at
/// (CollectionRules.dropCollectRadiusM), so the glow on the map is a
/// promise: cross into it and the gem is yours, even ~200 ft out. A soft
/// map-green fill with a hairline rim; it grows and shrinks with zoom
/// because it is ground truth, not decoration.
public struct CaptureZone: MapContent {
    let center: Coordinate

    public init(center: Coordinate) {
        self.center = center
    }

    public var body: some MapContent {
        MapCircle(center: center.cl,
                  radius: CollectionRules.dropCollectRadiusM)
            .foregroundStyle(MapPalette.map.opacity(0.16))
            .stroke(MapPalette.map.opacity(0.65), lineWidth: 1.5)
    }
}

/// A gem pin that falls onto the map with a spring (the pin-drop animation).
/// Renders the gem's artwork (GemIcon) when given a gemID; otherwise falls
/// back to a rarity-tier emoji.
public struct DropPin: View {
    let gemID: UUID?
    let fallbackEmoji: String
    @State private var dropped = false

    public init(gemID: UUID) {
        self.gemID = gemID
        self.fallbackEmoji = MapPalette.emoji(forGemID: gemID)
    }

    public init(rarity: Rarity) {
        self.gemID = nil
        self.fallbackEmoji = MapPalette.emoji(rarity)
    }

    public var body: some View {
        Group {
            if let gemID {
                GemIcon(gemID: gemID, size: 26)
            } else {
                Text(fallbackEmoji)
                    .font(.title2)
            }
        }
        .shadow(color: MapPalette.ink.opacity(0.5), radius: 1, y: 1)
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

/// One-shot sparkle burst shown at a gem's map location the moment it's
/// captured mid-run: six sparkles fly outward and fade over ~1.2 s.
struct SparkleBurst: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Text("✨")
                    .font(.system(size: 13))
                    .offset(x: animate ? 24 * cos(Double(i) * .pi / 3) : 0,
                            y: animate ? 24 * sin(Double(i) * .pi / 3) : 0)
                    .scaleEffect(animate ? 1.3 : 0.4)
                    .opacity(animate ? 0 : 1)
            }
            Text("✨")
                .font(.title2)
                .scaleEffect(animate ? 2.0 : 0.6)
                .opacity(animate ? 0 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) { animate = true }
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
    let onSelect: (Route) -> Void
    let onTapCoordinate: ((Coordinate) -> Void)?
    /// Tap on a gem pin — the caller shows the gem-info card.
    let onSelectDrop: ((GemDrop) -> Void)?
    /// Bump to snap the camera back to the user (the location capsule's
    /// tap). A counter instead of a bool so repeat taps keep working.
    let recenterTick: Int

    @State private var cameraPosition: MapCameraPosition =
        .userLocation(fallback: .automatic)

    public init(routes: [Route], standaloneDrops: [GemDrop] = [], selectedID: UUID?,
                previewPath: [Coordinate] = [],
                destinationPin: Coordinate? = nil,
                userCoordinate: Coordinate? = nil,
                onSelect: @escaping (Route) -> Void,
                onTapCoordinate: ((Coordinate) -> Void)? = nil,
                onSelectDrop: ((GemDrop) -> Void)? = nil,
                recenterTick: Int = 0) {
        self.routes = routes
        self.standaloneDrops = standaloneDrops
        self.selectedID = selectedID
        self.previewPath = previewPath
        self.destinationPin = destinationPin
        self.userCoordinate = userCoordinate
        self.onSelect = onSelect
        self.onTapCoordinate = onTapCoordinate
        self.onSelectDrop = onSelectDrop
        self.recenterTick = recenterTick
    }

    public var body: some View {
        MapReader { proxy in
            mapContent
                .onTapGesture(coordinateSpace: .local) { screenPoint in
                    guard let onTapCoordinate,
                          let coord = proxy.convert(screenPoint, from: .local) else { return }
                    onTapCoordinate(Coordinate(lat: coord.latitude, lng: coord.longitude))
                }
                .onChange(of: recenterTick) { _, _ in
                    guard let here = userCoordinate else { return }
                    withAnimation(.easeInOut(duration: 0.6)) {
                        cameraPosition = .region(MKCoordinateRegion(
                            center: here.cl,
                            latitudinalMeters: 1_200, longitudinalMeters: 1_200))
                    }
                }
        }
    }

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            if let userCoordinate {
                Annotation("You", coordinate: userCoordinate.cl) {
                    Text("🏃")
                        .font(.title)
                        .shadow(color: MapPalette.ink.opacity(0.5), radius: 1, y: 1)
                }
            }
            // No UserAnnotation fallback: its accuracy halo reads as a big
            // translucent circle on the map. Once we have a live fix (usually
            // within a second of opening), the 🏃 emoji above takes over.
            ForEach(standaloneDrops) { drop in
                // The gem's capture zone: walk anywhere inside the green
                // circle and the claim fires — the circle IS the rule.
                CaptureZone(center: drop.coordinate)
                Annotation("", coordinate: drop.coordinate.cl) {
                    Button {
                        onSelectDrop?(drop)
                    } label: {
                        DropPin(gemID: drop.gemID)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Point-to-point preview: dashed pulse line from the user to the
            // dropped destination pin, so runners see the path before starting.
            if previewPath.count > 1 {
                MapPolyline(coordinates: previewPath.map(\.cl))
                    .stroke(MapPalette.map,
                            style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
            }
            if let destinationPin {
                Annotation("", coordinate: destinationPin.cl) {
                    DestinationPin()
                }
            }
            ForEach(routes) { route in
                let coords = PolylineCodec.decode(route.polyline).map(\.cl)
                // The resting map shows only start pills + gems; a route's
                // line draws once the runner picks it (like tapping a
                // suggestion in Apple Maps).
                if route.id == selectedID {
                    MapPolyline(coordinates: coords)
                        .stroke(MapPalette.map, lineWidth: 5)
                }
                if let start = coords.first {
                    Annotation(route.name, coordinate: start) {
                        Button { onSelect(route) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "diamond.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("\(route.gemDrops.count)")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(MapPalette.onMap)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(MapPalette.map, in: Capsule())
                            .shadow(color: MapPalette.ink.opacity(0.2), radius: 4, y: 1)
                        }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // A real, always-on compass (top-trailing): shows which way is
        // north, and tapping it after a two-finger rotation snaps the map
        // back to north-up — native MapKit behavior, always tappable.
        .mapControls {
            MapCompass()
                .mapControlVisibility(.visible)
        }
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
                .stroke(MapPalette.map, lineWidth: 4)
            ForEach(route.gemDrops) { drop in
                Annotation("", coordinate: drop.coordinate.cl) {
                    if collectedDropIDs.contains(drop.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(MapPalette.ink.opacity(0.35))
                    } else {
                        GemIcon(gemID: drop.gemID, size: 22)
                            .shadow(color: MapPalette.ink.opacity(0.5), radius: 1, y: 1)
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
                        .stroke(MapPalette.map, lineWidth: 4)
                }
                ForEach(Array(waypoints.enumerated()), id: \.offset) { i, wp in
                    Annotation("", coordinate: wp.cl) {
                        Text("\(i + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(MapPalette.onMap)
                            .frame(width: 20, height: 20)
                            .background(MapPalette.map, in: Circle())
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
                .foregroundStyle(MapPalette.onMap, MapPalette.map)
                .shadow(color: MapPalette.ink.opacity(0.3), radius: 4, y: 2)
            Triangle()
                .fill(MapPalette.map)
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

/// Publishes the device's compass heading (degrees clockwise from north) so
/// the run map rotates with the phone — Apple Maps walking-navigation feel.
@MainActor
@Observable
final class CompassProvider {
    private(set) var headingDeg: Double?
    private var manager: CLLocationManager?
    private var proxy: Proxy?

    // Nonisolated so `@State private var compass = CompassProvider()` can
    // build the instance outside the main actor; the manager is created
    // in start(), which always runs on it.
    nonisolated init() {}

    func start() {
        let proxy = Proxy { [weak self] deg in self?.headingDeg = deg }
        self.proxy = proxy
        let manager = CLLocationManager()
        manager.delegate = proxy
        manager.headingFilter = 4
        manager.startUpdatingHeading()
        self.manager = manager
    }

    func stop() {
        manager?.stopUpdatingHeading()
    }

    private final class Proxy: NSObject, CLLocationManagerDelegate {
        private let onHeading: @MainActor (Double) -> Void

        init(onHeading: @escaping @MainActor (Double) -> Void) {
            self.onHeading = onHeading
        }

        func locationManager(_ manager: CLLocationManager,
                             didUpdateHeading newHeading: CLHeading) {
            let deg = newHeading.trueHeading >= 0
                ? newHeading.trueHeading : newHeading.magneticHeading
            guard deg >= 0 else { return }
            Task { @MainActor in self.onHeading(deg) }
        }
    }
}

/// Active Run chase map (docs/03 §7): follows the runner, shows gems ahead.
/// `route` is nil on a free run — only standalone drops render.
/// Camera is a fixed north-up bird's-eye view (Google-Maps style — the map
/// never rotates). The runner marker carries a compass arrowhead that turns
/// with the phone, so direction lives on the marker, not the map.
@MainActor
public struct ActiveRunMapView: View {
    let route: Route?
    let freeDrops: [GemDrop]
    /// Planned walking line for free runs launched from a recommended route
    /// (client-side only — there's no backend route to decode it from).
    let plannedPath: [Coordinate]
    let runnerPosition: Coordinate?
    let collectedDropIDs: Set<UUID>
    /// Breadcrumb of positions actually traveled this run, drawn behind
    /// the runner so every step taken is visible on the map.
    let traveledPath: [Coordinate]

    /// Anchor of the last heading update — kept until the runner moves far
    /// enough from it, so short per-sample steps still accumulate into
    /// live rotation instead of freezing the camera north-up.
    @State private var previousRunner: Coordinate?
    @State private var heading: CLLocationDirection = 0
    /// Follow mode: camera tracks the runner. Users can pan away to inspect
    /// the map; a floating "Recenter" button snaps back to follow (Apple-Maps
    /// walking-nav feel). We only push new camera positions while following;
    /// once panned, the runner-update watchers no-op so the user's view sticks.
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    /// Live compass — rotates the follow camera and the runner emoji.
    @State private var compass = CompassProvider()
    /// The map's current rotation, so the emoji's rotation stays accurate
    /// even after the user pans/rotates the map by hand.
    @State private var cameraHeadingDeg: Double = 0
    /// Drops currently playing their capture sparkle (cleared ~1.6 s after
    /// the collection lands, leaving the muted checkmark behind).
    @State private var sparklingDropIDs: Set<UUID> = []
    /// Furthest progress (meters) along the guide line the runner has
    /// covered. The line is drawn from here onward only, so it visibly
    /// disappears behind you as you advance. Monotonic: it never refills.
    @State private var coveredM: Double = 0
    /// How far off the line you can be while still "covering" it. Snapped
    /// paths follow road centerlines while people walk the sidewalk beside
    /// them, so this stays generous: walking parallel to the line consumes
    /// it; wandering off on a detour does not.
    private let guideCorridorM: Double = 75

    public init(route: Route?, freeDrops: [GemDrop] = [],
                plannedPath: [Coordinate] = [], runnerPosition: Coordinate?,
                collectedDropIDs: Set<UUID>, traveledPath: [Coordinate] = []) {
        self.route = route
        self.freeDrops = freeDrops
        self.plannedPath = plannedPath
        self.runnerPosition = runnerPosition
        self.collectedDropIDs = collectedDropIDs
        self.traveledPath = traveledPath
    }

    private var drops: [GemDrop] {
        route?.gemDrops ?? freeDrops
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $cameraPosition) {
                // Only the not-yet-covered remainder of the guide line is
                // drawn — the part behind the runner disappears, and the
                // ink breadcrumb below takes over as the record of where
                // you actually went.
                let remaining = remainderOf(guideLine, fromM: coveredM)
                if remaining.count > 1 {
                    MapPolyline(coordinates: remaining.map(\.cl))
                        .stroke(MapPalette.map, lineWidth: 4)
                }
                // The trail of steps actually taken this run — smoothed with
                // a 3-sample moving average so it reads as a clean stroke,
                // not a jitter-scribbled raw GPS line.
                if traveledPath.count > 1 {
                    MapPolyline(coordinates: smoothedTrail(traveledPath).map(\.cl))
                        .stroke(MapPalette.ink.opacity(0.55),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                                   lineJoin: .round))
                }
                ForEach(drops) { drop in
                    // Capture zone stays visible until the gem is taken —
                    // mid-run this is the target ring you're running for.
                    if !collectedDropIDs.contains(drop.id) {
                        CaptureZone(center: drop.coordinate)
                    }
                    Annotation("", coordinate: drop.coordinate.cl) {
                        if sparklingDropIDs.contains(drop.id) {
                            SparkleBurst()
                        } else if collectedDropIDs.contains(drop.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(MapPalette.ink.opacity(0.35))
                        } else {
                            GemIcon(gemID: drop.gemID, size: 22)
                                .shadow(color: MapPalette.ink.opacity(0.5), radius: 1, y: 1)
                        }
                    }
                }
                if let runner = runnerPosition {
                    Annotation("", coordinate: runner.cl) {
                        // Top-down runner: the emoji stays upright; an
                        // orbiting arrowhead points where the phone points
                        // (compass heading, corrected for any manual map
                        // rotation the user did with two fingers).
                        ZStack {
                            Image(systemName: "arrowtriangle.up.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(MapPalette.map)
                                .shadow(color: MapPalette.ink.opacity(0.4),
                                        radius: 1, y: 1)
                                .offset(y: -26)
                                .rotationEffect(.degrees(
                                    (compass.headingDeg ?? heading) - cameraHeadingDeg))
                                .animation(.easeInOut(duration: 0.3),
                                           value: compass.headingDeg)
                            Text("🏃")
                                .font(.title)
                                .shadow(color: MapPalette.ink.opacity(0.5),
                                        radius: 1, y: 1)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            // Always-on compass: north indicator while running, and the
            // native tap-to-reset after any two-finger rotation.
            .mapControls {
                MapCompass()
                    .mapControlVisibility(.visible)
            }
            .onChange(of: collectedDropIDs) { old, new in
                let fresh = new.subtracting(old)
                guard !fresh.isEmpty else { return }
                sparklingDropIDs.formUnion(fresh)
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    sparklingDropIDs.subtract(fresh)
                }
            }
            .onChange(of: runnerPosition?.lat) { _, _ in
                updateHeading()
                pushCameraIfFollowing()
                consumeGuideLine()
            }
            .onChange(of: runnerPosition?.lng) { _, _ in
                updateHeading()
                pushCameraIfFollowing()
                consumeGuideLine()
            }
            // Detect user pan: if the camera drifts far from the runner while
            // we're supposed to be following, they dragged it — release follow.
            .onMapCameraChange(frequency: .onEnd) { context in
                cameraHeadingDeg = context.camera.heading
                guard isFollowing, let runner = runnerPosition else { return }
                let center = context.camera.centerCoordinate
                let mPerDegLat = 111_320.0
                let dy = (center.latitude - runner.lat) * mPerDegLat
                let dx = (center.longitude - runner.lng) * mPerDegLat
                        * cos(runner.lat * .pi / 180)
                if (dx * dx + dy * dy).squareRoot() > 60 {
                    isFollowing = false
                }
            }
            .onAppear {
                compass.start()
                // Seed the camera so the run opens focused on the runner
                // (or the route bounds), not zoomed out to the whole world.
                if let runner = runnerPosition {
                    cameraPosition = .camera(MapCamera(centerCoordinate: runner.cl,
                                                       distance: 600, heading: 0, pitch: 0))
                } else if let route {
                    cameraPosition = .region(region(for: PolylineCodec.decode(route.polyline)))
                } else {
                    cameraPosition = .userLocation(fallback: .automatic)
                }
            }
            .onDisappear {
                compass.stop()
            }

            if !isFollowing {
                Button {
                    isFollowing = true
                    pushCameraIfFollowing()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(MapPalette.onMap)
                        .frame(width: 44, height: 44)
                        .background(MapPalette.map, in: Circle())
                        .overlay(Circle().stroke(MapPalette.ink.opacity(0.35), lineWidth: 1))
                        .shadow(color: MapPalette.ink.opacity(0.2), radius: 4, y: 2)
                }
                // Below the map's compass (top-trailing) so neither control
                // covers the other.
                .padding(.top, 112)
                .padding(.trailing, 16)
                .accessibilityLabel("Recenter on runner")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFollowing)
    }

    /// Push a fresh follow-camera when the runner moves — only while the user
    /// hasn't panned away. Stops writing to `cameraPosition` when they have,
    /// so their inspection view sticks until they tap Recenter.
    private func pushCameraIfFollowing() {
        guard isFollowing, let runner = runnerPosition else { return }
        // North-up, no rotation — the marker's arrowhead carries direction.
        cameraHeadingDeg = 0
        cameraPosition = .camera(MapCamera(centerCoordinate: runner.cl,
                                           distance: 600, heading: 0, pitch: 0))
    }

    /// Simple 3-sample moving average — keeps the trail visually clean without
    /// the cost/latency of re-running MKDirections on the traveled path.
    /// The pulse guide line for this run: the route's polyline, or the
    /// snapped planned path on a free run. Empty when neither exists.
    private var guideLine: [Coordinate] {
        if let route { return PolylineCodec.decode(route.polyline) }
        return plannedPath
    }

    /// Advance `coveredM` to the runner's furthest on-line progress. Only
    /// positions within `guideCorridorM` of the line count — walking the
    /// sidewalk beside a road-snapped line still consumes it, but leaving
    /// the line (a shortcut, a detour) freezes it until you rejoin.
    private func consumeGuideLine() {
        guard let runner = runnerPosition else { return }
        let line = guideLine
        guard line.count > 1,
              let hit = projectOntoGuide(runner, line: line),
              hit.crossM <= guideCorridorM else { return }
        coveredM = max(coveredM, hit.alongM)
    }

    /// Planar projection of a point onto the polyline: distance along the
    /// line of the nearest point, and how far off the line the point sits.
    private func projectOntoGuide(_ p: Coordinate,
                                  line: [Coordinate]) -> (alongM: Double, crossM: Double)? {
        let kLat = 111_320.0
        let kLng = kLat * max(0.1, cos(line[0].lat * .pi / 180))
        var best: (alongM: Double, crossM: Double)?
        var cum = 0.0
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let px = (p.lng - a.lng) * kLng, py = (p.lat - a.lat) * kLat
            let sx = (b.lng - a.lng) * kLng, sy = (b.lat - a.lat) * kLat
            let len2 = sx * sx + sy * sy
            let segLen = len2.squareRoot()
            let t = len2 > 0 ? min(1, max(0, (px * sx + py * sy) / len2)) : 0
            let cross = ((px - t * sx) * (px - t * sx)
                + (py - t * sy) * (py - t * sy)).squareRoot()
            if best == nil || cross < best!.crossM {
                best = (cum + t * segLen, cross)
            }
            cum += segLen
        }
        return best
    }

    /// The polyline from `fromM` meters onward — the cut point interpolated
    /// on its segment so the line shrinks smoothly, not node by node.
    private func remainderOf(_ line: [Coordinate], fromM: Double) -> [Coordinate] {
        guard line.count > 1, fromM > 0 else { return line }
        let kLat = 111_320.0
        let kLng = kLat * max(0.1, cos(line[0].lat * .pi / 180))
        var cum = 0.0
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let segLen = ((b.lat - a.lat) * kLat * (b.lat - a.lat) * kLat
                + (b.lng - a.lng) * kLng * (b.lng - a.lng) * kLng).squareRoot()
            if cum + segLen > fromM, segLen > 0 {
                let t = (fromM - cum) / segLen
                let cut = Coordinate(lat: a.lat + t * (b.lat - a.lat),
                                     lng: a.lng + t * (b.lng - a.lng))
                return [cut] + line[(i + 1)...]
            }
            cum += segLen
        }
        return []          // fully covered — nothing left to draw
    }

    private func smoothedTrail(_ raw: [Coordinate]) -> [Coordinate] {
        guard raw.count >= 3 else { return raw }
        var out: [Coordinate] = [raw[0]]
        for i in 1..<(raw.count - 1) {
            let a = raw[i - 1], b = raw[i], c = raw[i + 1]
            out.append(Coordinate(lat: (a.lat + b.lat + c.lat) / 3,
                                  lng: (a.lng + b.lng + c.lng) / 3))
        }
        out.append(raw[raw.count - 1])
        return out
    }

    /// Live direction: bearing from the last heading anchor to the current
    /// position, clockwise from north. The anchor only advances once the
    /// runner is > 5 m from it — per-second samples at running pace move
    /// ~3 m, so anchoring per-sample froze the heading; accumulating from
    /// a fixed anchor keeps the camera rotating like turn-by-turn nav
    /// while still ignoring GPS jitter.
    private func updateHeading() {
        guard let curr = runnerPosition else { return }
        guard let prev = previousRunner else {
            previousRunner = curr
            return
        }
        let mPerDegLat = 111_320.0
        let dy = (curr.lat - prev.lat) * mPerDegLat
        let dx = (curr.lng - prev.lng) * mPerDegLat * cos(curr.lat * .pi / 180)
        guard (dx * dx + dy * dy).squareRoot() > 5 else { return }
        let bearing = atan2(dx, dy) * 180 / .pi
        heading = (bearing + 360).truncatingRemainder(dividingBy: 360)
        previousRunner = curr
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
/// Every caller must honor the `snapped` flag: `false` means the returned
/// pair is a straight-line placeholder, NOT a walkable path — never draw it
/// (it may cross water, highways, private land; docs/13 §2). There is
/// deliberately no unchecked convenience API.
public enum PathSnapper {
    /// The snapped path plus whether MKDirections actually confirmed it as a
    /// walking route (`false` = straight-line placeholder, NOT a walkable path).
    public static func snapVerified(from a: Coordinate,
                                    to b: Coordinate) async -> (path: [Coordinate],
                                                                snapped: Bool) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.cl))
        request.transportType = .walking
        let started = Date()
        do {
            let response = try await MKDirections(request: request).calculate()
            let ms = Int(Date().timeIntervalSince(started) * 1_000)
            guard let poly = response.routes.first?.polyline else {
                GemLog.map.debug("MKDirections walk (\(a.lat, privacy: .private), \(a.lng, privacy: .private)) -> (\(b.lat, privacy: .private), \(b.lng, privacy: .private)): no route in \(ms) ms")
                return ([a, b], false)
            }
            var coords = [CLLocationCoordinate2D](repeating: .init(), count: poly.pointCount)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
            GemLog.map.debug("MKDirections walk (\(a.lat, privacy: .private), \(a.lng, privacy: .private)) -> (\(b.lat, privacy: .private), \(b.lng, privacy: .private)): \(poly.pointCount) pts in \(ms) ms")
            return (coords.map { Coordinate(lat: $0.latitude, lng: $0.longitude) }, true)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1_000)
            GemLog.map.error("MKDirections walk FAILED after \(ms) ms: \(error.localizedDescription, privacy: .public)")
            return ([a, b], false)
        }
    }

    /// Every alternate walking path MKDirections offers between two points,
    /// best-first, deduplicated. Empty = NO confirmed walking route (or the
    /// request failed) — this API deliberately has no straight-line
    /// fallback, so callers can refuse unwalkable segments outright.
    /// Alternates arrive in the same single request: no extra quota.
    public static func snapAlternates(from a: Coordinate,
                                      to b: Coordinate) async -> [[Coordinate]] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.cl))
        request.transportType = .walking
        request.requestsAlternateRoutes = true
        let started = Date()
        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            GemLog.map.error("MKDirections alternates FAILED after \(Int(Date().timeIntervalSince(started) * 1_000)) ms: \(error.localizedDescription, privacy: .public)")
            return []
        }
        GemLog.map.debug("MKDirections alternates (\(a.lat, privacy: .private), \(a.lng, privacy: .private)) -> (\(b.lat, privacy: .private), \(b.lng, privacy: .private)): \(response.routes.count) route(s) in \(Int(Date().timeIntervalSince(started) * 1_000)) ms")
        var options: [[Coordinate]] = []
        for route in response.routes {
            let poly = route.polyline
            var coords = [CLLocationCoordinate2D](repeating: .init(),
                                                  count: poly.pointCount)
            poly.getCoordinates(&coords, range: NSRange(location: 0,
                                                        length: poly.pointCount))
            let path = coords.map { Coordinate(lat: $0.latitude, lng: $0.longitude) }
            if path.count >= 2, !options.contains(path) {
                options.append(path)
            }
        }
        return options
    }
}
