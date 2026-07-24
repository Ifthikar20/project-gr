import CoreLocation
import CoreMap
import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import GameKitCore
import MapKit
import SwiftData
import SwiftUI

/// Map home (docs/03 §2): routes, standalone gem drops left by other
/// runners, drop mode (place a wallet gem anywhere with a pin-drop
/// animation), and free runs to collect nearby drops.
@MainActor
public struct ExploreRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredRoute.createdAt) private var storedRoutes: [StoredRoute]
    @State private var selectedID: UUID?
    @State private var detailRoute: Route?
    @State private var nearbyDrops: [GemDrop] = []
    @State private var isDropMode = false
    @State private var pendingDropSpot: TappedSpot?
    // Destination mode: tap a spot to build a run from here → there.
    @State private var isDestinationMode = false
    @State private var destination: Coordinate?
    @State private var destinationPath: [Coordinate] = []
    @State private var isPlanningPath = false
    @State private var planError: String?
    // Live GPS fix drives the runner emoji on the map + park seeding.
    @State private var live = LiveLocation()
    @State private var seededParksForCenter: Coordinate?
    // The dotted "run this to collect gems" line, auto-recomputed as gems +
    // location change. Snapped through nearest N drops from the user.
    @State private var suggestedPath: [Coordinate] = []
    @State private var suggestedFrom: Coordinate?

    public init() {}

    private var routes: [Route] {
        storedRoutes
            .filter { $0.statusRaw == RouteStatus.published.rawValue }
            .map { $0.toRoute() }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ExploreMapView(
                    routes: routes,
                    standaloneDrops: nearbyDrops,
                    selectedID: selectedID,
                    previewPath: destinationPath,
                    destinationPin: destination,
                    userCoordinate: live.coordinate,
                    suggestedPath: suggestedPath,
                    onSelect: { detailRoute = $0 },
                    onTapCoordinate: mapTapHandler
                )
                .ignoresSafeArea()

                VStack(alignment: .trailing, spacing: 12) {
                    actionButtons
                    if isDropMode {
                        dropModeBanner
                    } else if isDestinationMode {
                        destinationBanner
                    } else if routes.isEmpty {
                        emptyBanner
                    } else {
                        routeCards
                    }
                    if isDestinationMode {
                        startDestinationButton
                    } else if !isDropMode {
                        startRunButton
                    }
                }
                .padding(.bottom, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $detailRoute) { route in
                RouteDetailView(route: route)
            }
            .sheet(item: $pendingDropSpot) { spot in
                DropGemSheet(coordinate: spot.coordinate) { newDrop in
                    withAnimation { nearbyDrops.append(newDrop) }
                    isDropMode = false
                }
                .presentationDetents([.height(320)])
            }
            .task {
                live.start()
                await loadNearby()
            }
            .onChange(of: live.coordinate) { _, new in
                // As soon as we have a real fix (or it drifts far from the last
                // seed center), place gems at safe public POIs nearby — parks,
                // gas stations, cafes, libraries, transit hubs, post offices —
                // and skip anything near parking or private buildings.
                guard let new else { return }
                Task { await rebuildSuggestedPath(from: new) }
                if let seed = seededParksForCenter,
                   RouteGeometry.planarDistance(from: seed, to: new) < 1_500 {
                    return
                }
                Task { await seedSafeZoneDrops(around: new) }
            }
            .onChange(of: nearbyDrops.count) { _, _ in
                guard let here = live.coordinate else { return }
                Task { await rebuildSuggestedPath(from: here) }
            }
            .onChange(of: session.pendingDeepLinkRouteID) { _, id in
                guard let id else { return }
                if let stored = storedRoutes.first(where: { $0.id == id }) {
                    detailRoute = stored.toRoute()
                }
                session.pendingDeepLinkRouteID = nil
            }
        }
    }

    /// The primary "just go run" action. Always tappable — free runs work
    /// with or without nearby drops, so a runner who just wants to log km
    /// isn't blocked by an empty map.
    private var startRunButton: some View {
        Button {
            session.startFreeRun(drops: nearbyDrops)
        } label: {
            Label("Start Run", systemImage: "figure.run")
                .font(.headline.bold())
                .foregroundStyle(DS.Colors.snowCard)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(DS.Colors.pulse, in: Capsule())
                .shadow(color: DS.Colors.ink.opacity(0.25), radius: 10, y: 4)
        }
        .padding(.horizontal, 16)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Destination mode: tap a spot to plan a run from here → there.
            Button {
                if isDestinationMode {
                    exitDestinationMode()
                } else {
                    isDropMode = false
                    isDestinationMode = true
                }
            } label: {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3.bold())
                    .foregroundStyle(isDestinationMode ? DS.Colors.snowCard : DS.Colors.ink)
                    .frame(width: 48, height: 48)
                    .background(isDestinationMode ? DS.Colors.pulse : DS.Colors.snowCard,
                                in: Circle())
                    .overlay(Circle().stroke(
                        isDestinationMode ? .clear : DS.Colors.hairline, lineWidth: 1))
                    .shadow(color: DS.Colors.ink.opacity(0.15), radius: 6, y: 2)
            }

            // Drop mode: place a wallet gem anywhere.
            Button {
                if isDropMode {
                    isDropMode = false
                } else {
                    exitDestinationMode()
                    isDropMode = true
                }
            } label: {
                Image(systemName: "diamond.fill")
                    .font(.title3.bold())
                    .foregroundStyle(isDropMode ? DS.Colors.snowCard : DS.Colors.ink)
                    .frame(width: 48, height: 48)
                    .background(isDropMode ? DS.Colors.pulse : DS.Colors.snowCard,
                                in: Circle())
                    .overlay(Circle().stroke(
                        isDropMode ? .clear : DS.Colors.hairline, lineWidth: 1))
                    .shadow(color: DS.Colors.ink.opacity(0.15), radius: 6, y: 2)
            }

            Button {
                session.isCreatingRoute = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .foregroundStyle(DS.Colors.snowCard)
                    .frame(width: 56, height: 56)
                    .background(DS.Colors.pulse, in: Circle())
                    .shadow(color: DS.Colors.ink.opacity(0.2), radius: 8, y: 3)
            }
        }
        .padding(.trailing, 20)
    }

    private var dropModeBanner: some View {
        Text("Tap the map to drop a gem from your wallet")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(DS.Colors.ink)
            .airbnbCard(padding: 12)
            .padding(.horizontal, 16)
    }

    /// Destination banner: prompts "tap the map", live-summarizes the snapped
    /// path (km), surfaces planning errors, and offers Clear.
    private var destinationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(DS.Colors.pulse)
            VStack(alignment: .leading, spacing: 2) {
                if destination == nil {
                    Text("Tap the map to drop a destination pin")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Colors.ink)
                    Text("We'll snap a run from your location to there")
                        .font(.caption2)
                        .foregroundStyle(DS.Colors.inkSecondary)
                } else if let planError {
                    Text("Couldn't plan a path")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Colors.ink)
                    Text(planError)
                        .font(.caption2)
                        .foregroundStyle(DS.Colors.inkSecondary)
                } else {
                    let onWay = gemsOnTheWay
                    Text(destinationDistanceM > 0
                         ? "Destination set · \(distanceLabel(destinationDistanceM))"
                         : "Destination set")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Colors.ink)
                    if isPlanningPath {
                        Text("Snapping path…")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    } else if onWay > 0 {
                        Text("\(onWay) gem\(onWay == 1 ? "" : "s") on the way · tap Start Run")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.pulse)
                    } else {
                        Text("Tap Start Run when ready")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                }
            }
            Spacer()
            if destination != nil {
                Button("Clear") {
                    destination = nil
                    destinationPath = []
                    planError = nil
                }
                .font(.caption.bold())
                .foregroundStyle(DS.Colors.pulse)
            }
        }
        .airbnbCard(padding: 12)
        .padding(.horizontal, 16)
    }

    /// Primary "run to this pin" action — disabled until we have a snapped
    /// path from user location to the dropped pin.
    private var startDestinationButton: some View {
        let ready = destination != nil && destinationPath.count > 1 && !isPlanningPath
        return Button {
            startDestinationRun()
        } label: {
            Label(ready ? "Start Run" : (destination == nil ? "Drop a pin first" : "Planning…"),
                  systemImage: "figure.run")
                .font(.headline.bold())
                .foregroundStyle(DS.Colors.snowCard)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(ready ? DS.Colors.pulse : DS.Colors.pulse.opacity(0.4),
                            in: Capsule())
                .shadow(color: DS.Colors.ink.opacity(0.25), radius: 10, y: 4)
        }
        .disabled(!ready)
        .padding(.horizontal, 16)
    }

    private var destinationDistanceM: Int {
        guard destinationPath.count > 1 else { return 0 }
        return Int(RouteGeometry(coordinates: destinationPath).totalLengthM)
    }

    /// Nearby drops whose closest projection onto the snapped destination
    /// path is within ~60 m — i.e. they're actually reachable during the run.
    private var gemsOnTheWay: Int {
        guard destinationPath.count > 1 else { return 0 }
        let geometry = RouteGeometry(coordinates: destinationPath)
        return nearbyDrops.filter { geometry.project($0.coordinate).crossTrackM < 60 }.count
    }

    private func distanceLabel(_ m: Int) -> String {
        m < 1_000 ? "\(m) m" : String(format: "%.1f km", Double(m) / 1_000)
    }

    /// The map's tap callback: drop mode routes taps to the gem-drop sheet;
    /// destination mode sets a new destination and re-snaps the path.
    private var mapTapHandler: ((Coordinate) -> Void)? {
        if isDropMode {
            return { pendingDropSpot = TappedSpot(coordinate: $0) }
        }
        if isDestinationMode {
            return { setDestination($0) }
        }
        return nil
    }

    private func setDestination(_ c: Coordinate) {
        destination = c
        planError = nil
        Task { await planDestinationPath() }
    }

    private func exitDestinationMode() {
        isDestinationMode = false
        destination = nil
        destinationPath = []
        isPlanningPath = false
        planError = nil
    }

    /// Snap a walking path from the user's current location to the pin. If we
    /// don't have a fix yet, tell the user (rather than silently failing).
    private func planDestinationPath() async {
        guard let destination else {
            destinationPath = []
            return
        }
        let manager = CLLocationManager()
        guard let here = manager.location else {
            planError = "Waiting for your location — try again in a moment."
            destinationPath = []
            return
        }
        let start = Coordinate(lat: here.coordinate.latitude, lng: here.coordinate.longitude)
        isPlanningPath = true
        defer { isPlanningPath = false }
        let segment = await PathSnapper.snap(from: start, to: destination)
        destinationPath = segment
    }

    /// Assemble an in-memory Route from the snapped path and hand it to the
    /// session — RootView presents the Active Run cover.
    private func startDestinationRun() {
        guard destinationPath.count > 1 else { return }
        let geometry = RouteGeometry(coordinates: destinationPath)
        let distanceM = Int(geometry.totalLengthM)
        let difficulty: RouteDifficulty = switch distanceM {
        case ..<4_000: .easy
        case ..<9_000: .moderate
        default: .hard
        }
        let route = Route(
            id: UUID(),
            name: "Point to Point",
            description: nil,
            polyline: PolylineCodec.encode(destinationPath),
            distanceM: distanceM,
            elevationGainM: 0,
            difficulty: difficulty,
            creatorHandle: nil,
            gemDrops: [])
        exitDestinationMode()
        session.activeRoute = route
    }

    private var routeCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(routes) { route in
                    RouteCard(route: route)
                        .onTapGesture {
                            selectedID = route.id
                            detailRoute = route
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var emptyBanner: some View {
        Text("No routes here yet — be the first to create one")
            .font(.footnote)
            .foregroundStyle(DS.Colors.inkSecondary)
            .airbnbCard(padding: 12)
            .padding(.horizontal, 16)
    }

    /// GET /v1/routes + GET /v1/drops near the user; routes upsert into the
    /// SwiftData cache, drops render directly (they change hands too fast
    /// to cache).
    private func loadNearby() async {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        let center = manager.location.map {
            Coordinate(lat: $0.coordinate.latitude, lng: $0.coordinate.longitude)
        } ?? Coordinate(lat: 37.7749, lng: -122.4194)

        if let fetched = try? await API.shared.nearbyRoutes(
            lat: center.lat, lng: center.lng, radiusM: 5_000) {
            let cachedIDs = Set(storedRoutes.map(\.id))
            for route in fetched where !cachedIDs.contains(route.id) {
                context.insert(StoredRoute(route: route))
            }
            try? context.save()
        }
        if let drops = try? await API.shared.nearbyDrops(
            lat: center.lat, lng: center.lng, radiusM: 5_000) {
            withAnimation { nearbyDrops = drops }
        }
    }
}

/// Identifiable wrapper for a tapped map coordinate (sheet presentation).
struct TappedSpot: Identifiable {
    let coordinate: Coordinate
    var id: String { "\(coordinate.lat),\(coordinate.lng)" }
}

/// Airbnb listing-card anatomy: image on top (map preview), then title,
/// meta line, and the rarity row.
@MainActor
struct RouteCard: View {
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoutePreviewMap(route: route)
                .frame(height: 110)
                .allowsHitTesting(false)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16,
                                                  topTrailingRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(route.name)
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text(String(format: "%.1f km · %d m climb · %@",
                            Double(route.distanceM) / 1_000, route.elevationGainM,
                            route.difficulty.rawValue.capitalized))
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
                RarityDots(counts: rarityCounts)
            }
            .padding(12)
        }
        .frame(width: 250, alignment: .leading)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: DS.Colors.ink.opacity(0.1), radius: 12, y: 3)
    }

    private var rarityCounts: [Rarity: Int] {
        Dictionary(grouping: route.gemDrops, by: \.rarity).mapValues(\.count)
    }
}

/// Pick a wallet gem for the tapped location (docs: earn-by-running wallet).
@MainActor
struct DropGemSheet: View {
    let coordinate: Coordinate
    let onDropped: (GemDrop) -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var isDropping = false
    @State private var error: String?

    private var available: [(Rarity, Int)] {
        [Rarity.common, .uncommon, .rare, .epic]
            .compactMap { rarity in
                let count = session.wallet[rarity] ?? 0
                return count > 0 ? (rarity, count) : nil
            }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Drop a gem here")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
                .padding(.top, 20)
            if available.isEmpty {
                Text("Your wallet is empty. Gems are earned by running — sync with Apple Health in your Stash.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("First runner to pass within 25 m takes it.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
                HStack(spacing: 12) {
                    ForEach(available, id: \.0) { rarity, count in
                        Button {
                            drop(rarity)
                        } label: {
                            VStack(spacing: 4) {
                                RarityBadge(rarity, size: 24)
                                Text("×\(count)")
                                    .font(.caption)
                                    .foregroundStyle(DS.Colors.inkSecondary)
                            }
                            .frame(width: 64, height: 64)
                            .background(DS.Colors.snowCard,
                                        in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(DS.Colors.hairline, lineWidth: 1))
                        }
                        .disabled(isDropping)
                    }
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.pulse)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(DS.Colors.snow)
        .task {
            await session.refreshWallet()
        }
    }

    private func drop(_ rarity: Rarity) {
        isDropping = true
        Task {
            do {
                let gem = GemCatalog.gem(of: rarity)
                let placed = try await API.shared.dropGem(gemID: gem.id,
                                                          lat: coordinate.lat,
                                                          lng: coordinate.lng)
                session.spend(rarity)
                onDropped(placed)
                dismiss()
            } catch {
                self.error = "Couldn't drop the gem — try again."
            }
            isDropping = false
        }
    }
}

// MARK: - Live location + park-based seeding

/// Publishes the user's live coordinate so the map can render the runner
/// emoji and the Explore view can seed drops near the caller's real location.
@MainActor
@Observable
final class LiveLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var coordinate: Coordinate?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 15
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        // Deliver the last cached fix immediately so the emoji shows up
        // without waiting for the next GPS callback.
        if let cached = manager.location {
            coordinate = Coordinate(lat: cached.coordinate.latitude,
                                    lng: cached.coordinate.longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = Coordinate(lat: loc.coordinate.latitude,
                               lng: loc.coordinate.longitude)
        Task { @MainActor in self.coordinate = coord }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }
}

extension ExploreRootView {
    /// Greedy nearest-neighbor traversal from the user through the closest
    /// gems, snapped via MKDirections. Only rebuilds when the user has moved
    /// far enough that the current suggestion no longer starts near them.
    func rebuildSuggestedPath(from origin: Coordinate) async {
        if let last = suggestedFrom,
           RouteGeometry.planarDistance(from: last, to: origin) < 150,
           !suggestedPath.isEmpty {
            return
        }
        let picks = nearestPicks(from: origin, count: 4)
        guard !picks.isEmpty else {
            suggestedPath = []
            suggestedFrom = origin
            return
        }
        var path: [Coordinate] = [origin]
        var prev = origin
        for drop in picks {
            let segment = await PathSnapper.snap(from: prev, to: drop.coordinate)
            path.append(contentsOf: segment.dropFirst())
            prev = drop.coordinate
        }
        suggestedPath = path
        suggestedFrom = origin
    }

    /// Cheap nearest-neighbor pick: sort drops by distance to origin, then walk
    /// the list greedily, always picking the drop closest to the last pick.
    private func nearestPicks(from origin: Coordinate, count: Int) -> [GemDrop] {
        var remaining = nearbyDrops.sorted {
            RouteGeometry.planarDistance(from: origin, to: $0.coordinate)
            < RouteGeometry.planarDistance(from: origin, to: $1.coordinate)
        }
        // Cap the search radius so we don't suggest a run to the next town.
        remaining = Array(remaining.prefix(20))
        var picks: [GemDrop] = []
        var cursor = origin
        while picks.count < count, !remaining.isEmpty {
            let (i, next) = remaining.enumerated().min(by: {
                RouteGeometry.planarDistance(from: cursor, to: $0.element.coordinate)
                < RouteGeometry.planarDistance(from: cursor, to: $1.element.coordinate)
            })!
            picks.append(next)
            cursor = next.coordinate
            remaining.remove(at: i)
        }
        return picks
    }

    /// Query safe, public POIs around the user (parks, gas stations, cafes,
    /// libraries, museums, transit, post offices, bakeries, restaurants) and
    /// drop one gem at each. Explicitly excludes parking lots and skips any
    /// POI whose name hints at "private" / "residence" / "apartment".
    /// Rarity is weighted by category — parks and museums lean rarer, cafes
    /// and bakeries stay common — and the specific gem type is picked at
    /// random from the catalog so runners see rubies, emeralds, topaz, etc.
    func seedSafeZoneDrops(around center: Coordinate) async {
        let safeCategories: [(MKPointOfInterestCategory, [Rarity])] = [
            (.park,             [.uncommon, .rare, .epic]),
            (.publicTransport,  [.common, .uncommon]),
            (.gasStation,       [.common, .uncommon]),
            (.library,          [.uncommon, .rare]),
            (.museum,           [.rare, .epic]),
            (.cafe,             [.common, .common, .uncommon]),
            (.bakery,           [.common, .uncommon]),
            (.restaurant,       [.common, .uncommon]),
            (.postOffice,       [.common]),
        ]

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "cafe park library gas station"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng),
            latitudinalMeters: 4_000, longitudinalMeters: 4_000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(
            including: safeCategories.map(\.0))

        guard let response = try? await MKLocalSearch(request: request).start() else { return }

        // Private-building name hints we always skip, even if the POI matches
        // an allowed category (e.g. "Private Parking Lot Cafe").
        let banned = ["private", "residence", "apartment", "parking"]
        var made: [GemDrop] = []
        for item in response.mapItems.prefix(15) {
            let name = (item.name ?? item.placemark.name ?? "").lowercased()
            if banned.contains(where: name.contains) { continue }
            guard let category = item.pointOfInterestCategory,
                  let entry = safeCategories.first(where: { $0.0 == category })
            else { continue }
            let rarity = entry.1.randomElement() ?? .common
            let g = GemCatalog.randomGem(of: rarity)
            // ~30 m jitter so the pin sits near the POI, not on its label.
            let jitter = { Double.random(in: -0.0004...0.0004) }
            let c = item.placemark.coordinate
            made.append(GemDrop(
                id: UUID(),
                gemID: g.id,
                rarity: rarity,
                lat: c.latitude + jitter(),
                lng: c.longitude + jitter(),
                positionAlongRouteM: 0,
                respawnRule: .oneTime,
                placedBy: .creator))
        }

        guard !made.isEmpty else { return }
        withAnimation {
            let existing = nearbyDrops
            let novel = made.filter { new in
                !existing.contains { RouteGeometry.planarDistance(
                    from: $0.coordinate, to: new.coordinate) < 40 }
            }
            nearbyDrops.append(contentsOf: novel)
            seededParksForCenter = center
        }
    }
}
