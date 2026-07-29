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
import UIKit

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
    /// Gem pin the user tapped — presents the what-is-this-gem card.
    @State private var infoDrop: GemDrop?
    @State private var isDropMode = false
    @State private var pendingDropSpot: TappedSpot?
    // Destination mode: tap a spot to build a run from here → there.
    @State private var isDestinationMode = false
    @State private var destination: Coordinate?
    @State private var destinationPath: [Coordinate] = []
    @State private var isPlanningPath = false
    @State private var planError: String?
    // Live GPS fix drives the runner emoji on the map + refetch-on-move.
    @State private var live = LiveLocation()
    /// Center of the last nearby-fetch, so a first real GPS fix (or a big
    /// move) far from it triggers a refetch.
    @State private var lastFetchCenter: Coordinate?
    @State private var isLoadingNearby = false
    /// User-toggleable: fold the recommended-routes carousel to see the map.
    @State private var isRoutesCollapsed = false
    /// Auto-planned routes from the user's location through nearby gems —
    /// generated client-side by RouteRecommender; never persisted.
    @State private var recommendedRoutes: [Route] = []
    @State private var lastRecommendCenter: Coordinate?
    @State private var isRecommending = false
    @Environment(\.scenePhase) private var scenePhase
    // Drop-mode validation state: last denial reason, and "checking…" flag
    // for the POI lookup that gates a drop.
    @State private var dropError: String?
    @State private var isValidatingDrop = false
    /// First-open gate: the map is never shown unstocked. An opaque cover
    /// sits over it from tab-open until the first gem fetch lands —
    /// location permission → GPS fix → GET /v1/drops (which stocks the
    /// area server-side) → reveal, pins already in place.
    enum FirstLoad { case locating, stocking, failed, ready }
    @State private var firstLoad: FirstLoad = .locating
    @Environment(\.openURL) private var openURL
    /// Reverse-geocoded "Street · City" for the capsule at the top of the
    /// map. nil until the first geocode lands (the capsule stays hidden).
    @State private var locationLabel: String?
    @State private var lastGeocodedCoord: Coordinate?
    @State private var isGeocodingLabel = false
    /// Bumped when the location capsule is tapped — ExploreMapView watches
    /// it and snaps the camera back to the user's current position.
    @State private var recenterTick = 0

    public init() {}

    private var routes: [Route] {
        let published = storedRoutes
            .filter { $0.statusRaw == RouteStatus.published.rawValue }
            .map { $0.toRoute() }
        // Only recommend routes near the user — otherwise a route from a city
        // the user visited weeks ago keeps showing up here.
        let nearby: [Route]
        if let here = live.coordinate {
            nearby = published.filter { route in
                guard let start = PolylineCodec.decode(route.polyline).first else { return false }
                return RouteGeometry.planarDistance(from: here, to: start) <= 8_000
            }
        } else {
            nearby = published
        }
        // Auto-planned routes come first — they always start where the user
        // is standing, so they're the most directly actionable.
        return recommendedRoutes + nearby
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
                    onSelect: { detailRoute = $0 },
                    onTapCoordinate: mapTapHandler,
                    onSelectDrop: { infoDrop = $0 },
                    recenterTick: recenterTick
                )
                .ignoresSafeArea()

                VStack(alignment: .trailing, spacing: 12) {
                    actionButtons
                    if isDestinationMode {
                        destinationBanner
                    } else if routes.isEmpty {
                        emptyBanner
                    } else {
                        routeCards
                    }
                    if isDestinationMode {
                        startDestinationButton
                    } else {
                        startRunButton
                    }
                }
                .padding(.bottom, 8)

                if firstLoad != .ready {
                    firstLoadCover
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .overlay(alignment: .top) {
                if firstLoad == .ready {
                    VStack(spacing: 8) {
                        if let locationLabel {
                            // Tapping the capsule snaps the map back to
                            // where you're standing.
                            Button {
                                recenterTick += 1
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "location.fill")
                                        .font(.caption2.bold())
                                        .foregroundStyle(DS.Colors.pulse)
                                    Text(locationLabel)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DS.Colors.ink)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(DS.Colors.snowCard.opacity(0.94), in: Capsule())
                                .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
                                .shadow(color: DS.Colors.ink.opacity(0.08), radius: 5, y: 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show my current location")
                            .transition(.opacity)
                        }
                        // Honest empty state: fail-closed spawning means an
                        // area with no trusted walkable geometry legitimately
                        // has zero gems — say so instead of showing a
                        // silently bare map.
                        if nearbyDrops.isEmpty {
                            Text("No gems in this area yet — check back soon")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DS.Colors.ink)
                                .airbnbCard(padding: 12)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $detailRoute) { route in
                RouteDetailView(route: route)
            }
            .sheet(item: $infoDrop) { drop in
                GemInfoSheet(drop: drop) {
                    await runToGem(drop)
                }
                .presentationDetents([.height(320)])
            }
            .sheet(item: $pendingDropSpot) { spot in
                DropGemSheet(coordinate: spot.coordinate) { newDrop in
                    withAnimation { nearbyDrops.append(newDrop) }
                    isDropMode = false
                }
                .presentationDetents([.height(320)])
            }
            .task {
                // Start GPS but DON'T fetch yet — a demo-city fallback would
                // recommend routes from the wrong place. loadNearby() runs
                // when the first real fix arrives via onChange below.
                live.start()
            }
            // Gems come exclusively from the backend (GET /v1/drops in
            // loadNearby) — no client-side phantom seeding.
            .onChange(of: live.coordinate) { _, fix in
                // First fetch can run before a GPS fix exists (falls back to
                // the demo city). Re-fetch once a real fix arrives far from
                // the last query center, or after a big move.
                guard let fix else { return }
                Task { await updateLocationLabel(for: fix) }
                if let last = lastFetchCenter,
                   RouteGeometry.planarDistance(from: last, to: fix) <= 1_500 {
                    return
                }
                Task { await loadNearby() }
            }
            // Returning to the app refreshes the world: collected gems
            // vanish, new spawns appear — no relaunch needed.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadNearby() } }
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

    /// Opaque snow cover shown instead of an ever-empty map. Three shapes:
    /// a denied-permission call-to-action (gems are location-based, so the
    /// map is useless without it), a spinner while locating/stocking, and
    /// a retry screen when the first fetch fails. The map + tiles keep
    /// loading underneath, so the reveal is instant once pins are in hand.
    private var firstLoadCover: some View {
        VStack(spacing: 14) {
            Spacer()
            if live.isDenied {
                Image(systemName: "location.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.pulse)
                Text("Turn on location")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Text("Gems spawn on real sidewalks and trails around you — GemRun needs your location to stock the map.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.headline.bold())
                        .foregroundStyle(DS.Colors.snowCard)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(DS.Colors.pulse, in: Capsule())
                }
                .padding(.top, 6)
            } else if firstLoad == .failed {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.pulse)
                Text("Couldn't load gems")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Text("Check your connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                Button {
                    Task { await loadNearby() }
                } label: {
                    Text("Retry")
                        .font(.headline.bold())
                        .foregroundStyle(DS.Colors.snowCard)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 14)
                        .background(DS.Colors.pulse, in: Capsule())
                }
                .padding(.top, 6)
            } else {
                ProgressView()
                    .tint(DS.Colors.pulse)
                    .scaleEffect(1.4)
                    .padding(.bottom, 4)
                Text(firstLoad == .locating ? "Finding you…" : "Stocking gems near you…")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Text(firstLoad == .locating
                     ? "Gems spawn where you are — waiting for a GPS fix."
                     : "Placing gems on sidewalks and trails around you.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.snow)
        .ignoresSafeArea()
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
        VStack(alignment: .leading, spacing: 4) {
            if isValidatingDrop {
                Text("Checking that spot…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.ink)
            } else if let dropError {
                Text("Can't drop there")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.pulse)
                Text(dropError)
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.inkSecondary)
            } else {
                Text("Tap a trail you've run or a public spot")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.ink)
                Text("Parks, cafes, transit, libraries work — hospitals and private buildings don't.")
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        UnitFormat.shortDistance(fromMeters: Double(m))
    }

    /// The map's tap callback: drop mode routes taps through DropValidator
    /// first (trail-run + public-POI rules); destination mode sets a new
    /// destination and re-snaps the path.
    private var mapTapHandler: ((Coordinate) -> Void)? {
        if isDropMode {
            return { c in Task { await validateAndOpenDrop(c) } }
        }
        if isDestinationMode {
            return { setDestination($0) }
        }
        return nil
    }

    /// Runs DropValidator against past-run trails + published routes. If the
    /// spot passes, we open the DropGemSheet; otherwise we surface the reason
    /// in the drop-mode banner without opening the sheet.
    private func validateAndOpenDrop(_ c: Coordinate) async {
        isValidatingDrop = true
        dropError = nil
        defer { isValidatingDrop = false }
        let pastTrails = (try? context.fetch(FetchDescriptor<StoredRun>()))?
            .compactMap(\.trackPolyline) ?? []
        let published = routes.map(\.polyline)
        let verdict = await DropValidator.validate(
            c, pastTrails: pastTrails, nearbyRoutes: published)
        switch verdict {
        case .allowed:
            pendingDropSpot = TappedSpot(coordinate: c)
        case .denied(let reason):
            dropError = reason
        }
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

    /// Reverse-geocode the fix into the top capsule's "Street · City"
    /// label. On-device (CLGeocoder), no key needed — but Apple
    /// rate-limits it, so re-geocode only after moving ~200 m.
    private func updateLocationLabel(for fix: Coordinate) async {
        guard !isGeocodingLabel else { return }
        if locationLabel != nil, let last = lastGeocodedCoord,
           RouteGeometry.planarDistance(from: last, to: fix) < 200 {
            return
        }
        isGeocodingLabel = true
        defer { isGeocodingLabel = false }
        lastGeocodedCoord = fix
        let location = CLLocation(latitude: fix.lat, longitude: fix.lng)
        guard let mark = try? await CLGeocoder()
            .reverseGeocodeLocation(location).first else { return }
        var parts = [mark.thoroughfare ?? mark.subLocality ?? mark.name,
                     mark.locality ?? mark.subAdministrativeArea]
            .compactMap { $0 }
        if parts.count == 2, parts[0] == parts[1] { parts.removeLast() }
        guard !parts.isEmpty else { return }
        withAnimation { locationLabel = parts.joined(separator: " · ") }
    }

    /// The gem card's CTA: snap a walking path from the user to the tapped
    /// gem and start a run along it. Deliberately a FREE run, not a route
    /// run — free runs are the mode that collects standalone drops by
    /// proximity (≤ ~30 m, ActiveRunEngine), so arriving at the pin awards
    /// the gem; every other nearby gem stays collectable on the way.
    private func runToGem(_ drop: GemDrop) async {
        let here: Coordinate
        if let fix = live.coordinate {
            here = fix
        } else if let last = CLLocationManager().location {
            here = Coordinate(lat: last.coordinate.latitude,
                              lng: last.coordinate.longitude)
        } else {
            return   // map is only revealed after a fix, so this is rare
        }
        var path = await PathSnapper.snap(from: here, to: drop.coordinate)
        if path.count < 2 {
            // Snapper came up empty (offline, or no walkable route found):
            // fall back to a straight guide line so the run still starts —
            // collection is proximity-based, not path-based.
            path = [here, drop.coordinate]
        }
        infoDrop = nil
        let gemName = GemCatalog.entry(forGemID: drop.gemID)?.gem.name ?? "a Gem"
        session.startFreeRun(drops: nearbyDrops, plannedPath: path,
                             runName: "Run to \(gemName)")
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

    /// Suggested routes near the user — cards for the routes the backend
    /// returned, horizontally scrollable. Header row folds the carousel so
    /// the map isn't covered when you just want to look at gems.
    private var routeCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(routes.count) route\(routes.count == 1 ? "" : "s") nearby")
                    .font(.footnote.bold())
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Button {
                    Task { await regenerateRecommendations(force: true) }
                } label: {
                    if isRecommending {
                        ProgressView().scaleEffect(0.7).padding(.horizontal, 4)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.bold())
                            .foregroundStyle(DS.Colors.ink)
                            .padding(6)
                    }
                }
                .disabled(isRecommending)
                .accessibilityLabel("Refresh recommendations")
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRoutesCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isRoutesCollapsed ? "chevron.up" : "chevron.down")
                        .font(.footnote.bold())
                        .foregroundStyle(DS.Colors.ink)
                        .padding(6)
                }
                .accessibilityLabel(isRoutesCollapsed ? "Show routes" : "Hide routes")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(DS.Colors.snow.opacity(0.92), in: Capsule())
            .padding(.horizontal, 16)

            if !isRoutesCollapsed {
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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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
        guard !isLoadingNearby else { return }
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Recommendations are proximity-based, so a fetch without a real
        // location shows the wrong routes. Skip until GPS lands; the
        // onChange(of: live.coordinate) watcher retries on first fix.
        let center: Coordinate
        if let fix = live.coordinate {
            center = fix
        } else if let last = manager.location {
            center = Coordinate(lat: last.coordinate.latitude,
                                lng: last.coordinate.longitude)
        } else {
            print("[Explore] skipping fetch — no GPS fix yet")
            // Back to "Finding you…" — the first-fix onChange watcher will
            // re-enter here the moment GPS lands.
            if firstLoad != .ready { firstLoad = .locating }
            return
        }
        isLoadingNearby = true
        defer { isLoadingNearby = false }
        if firstLoad != .ready { firstLoad = .stocking }
        lastFetchCenter = center
        // Covers the cached-CLLocationManager path, where the live-fix
        // onChange (the usual geocode trigger) hasn't fired yet.
        Task { await updateLocationLabel(for: center) }
        print("[Explore] fetching nearby at (\(center.lat), \(center.lng))")

        do {
            let fetched = try await API.shared.nearbyRoutes(
                lat: center.lat, lng: center.lng, radiusM: 8_000)
            print("[Explore] routes: \(fetched.count)")
            // Refresh, not just insert: re-encoding cached rows picks up
            // server-side changes AND migrates gem blobs stored under the
            // old (pre-CodingKeys) key spelling.
            let cachedByID = Dictionary(uniqueKeysWithValues:
                                            storedRoutes.map { ($0.id, $0) })
            for route in fetched {
                if let existing = cachedByID[route.id] { context.delete(existing) }
                context.insert(StoredRoute(route: route))
            }
            // Backend is authoritative: anything it doesn't return is gone
            // (deleted server-side, or leftover from a prior mock-mode run).
            // No distance guard — a SF-coord mock route stranded in a Dallas
            // user's cache should NOT keep appearing on their map.
            if AppConfig.apiBaseURL != nil {
                let fetchedIDs = Set(fetched.map(\.id))
                for stored in storedRoutes where !fetchedIDs.contains(stored.id) {
                    context.delete(stored)
                }
            }
            try? context.save()
        } catch {
            print("[Explore] nearbyRoutes FAILED: \(error)")
        }
        do {
            let drops = try await API.shared.nearbyDrops(
                lat: center.lat, lng: center.lng, radiusM: 8_000)
            print("[Explore] drops: \(drops.count)")
            // Reveal the map only now — pins land in the same frame, so an
            // unstocked map is never on screen.
            withAnimation {
                nearbyDrops = drops
                firstLoad = .ready
            }
        } catch {
            print("[Explore] nearbyDrops FAILED: \(error)")
            // Keep the cover up with a Retry — a bare map with zero gems
            // must never stand in for a failed fetch. Refreshes after the
            // first reveal keep the stale pins instead.
            if firstLoad != .ready { firstLoad = .failed }
        }
        // Recommendations key off the fresh drop list — regenerate here so
        // the carousel updates in the same pass as everything else.
        await regenerateRecommendations(force: false)
    }

    /// Client-side route synthesis: 4 walking routes starting at the user's
    /// live location, visiting different combinations of nearby gems. Debounced
    /// to moves > 100 m; `force=true` skips the debounce (refresh button).
    private func regenerateRecommendations(force: Bool) async {
        guard !isRecommending, let here = live.coordinate else { return }
        if !force, let last = lastRecommendCenter,
           RouteGeometry.planarDistance(from: last, to: here) < 100 {
            return
        }
        isRecommending = true
        defer { isRecommending = false }
        lastRecommendCenter = here
        let planned = await RouteRecommender.recommend(from: here, drops: nearbyDrops)
        withAnimation { recommendedRoutes = planned }
        print("[Explore] recommended: \(planned.count)")
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
                Text(String(format: "%.1f mi · %d ft climb · %@",
                            UnitFormat.miles(fromMeters: Double(route.distanceM)),
                            UnitFormat.feet(fromMeters: Double(route.elevationGainM)),
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
                Text("First runner to pass within 100 ft takes it.")
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
    /// True once the user has denied (or MDM has restricted) location —
    /// the Explore first-load cover switches to its Settings prompt.
    var isDenied = false

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
        isDenied = manager.authorizationStatus == .denied
            || manager.authorizationStatus == .restricted
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
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.isDenied = status == .denied || status == .restricted
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }
}

// MARK: - Drop validation

/// Verdict from checking whether a spot on the map is a legal place to drop
/// a gem. See DropValidator for the rules — trails-you've-run + runnable
/// public POIs are OK; hospitals, apartments, parking, private residences
/// are not.
enum DropVerdict {
    case allowed
    case denied(reason: String)
}

/// Rule engine that gate-keeps drop mode.
///
/// A drop is allowed if any of these hold:
///   1. It's within 30 m of the polyline of a run the user has completed.
///   2. It's within 30 m of a published Route polyline (a known runnable path).
///   3. There's a runnable public POI (park, cafe, restaurant, library, museum,
///      transit, gas station, bakery, post office, beach, marina) within 80 m,
///      AND no forbidden POI (hospital, pharmacy, school, university, parking,
///      airport) or private-address hint within 60 m.
///
/// Everything else — an anonymous parcel, a private building, a hospital
/// parking lot — is denied with a human-readable reason so the user learns
/// the rule instead of just seeing a red toast.
enum DropValidator {
    static let allowedCategories: [MKPointOfInterestCategory] = [
        .park, .publicTransport, .cafe, .restaurant, .bakery,
        .library, .museum, .postOffice, .gasStation, .marina,
        .beach, .stadium,
    ]
    static let forbiddenCategories: [MKPointOfInterestCategory] = [
        .hospital, .pharmacy, .school, .university, .parking, .airport,
    ]
    static let bannedNameHints = ["private", "residence", "apartment",
                                  "condominium", "parking", "hospital", "clinic"]

    static func validate(_ c: Coordinate,
                         pastTrails: [String],
                         nearbyRoutes: [String]) async -> DropVerdict {
        // 1 + 2. On or near any trail we know is runnable.
        let allTrails = pastTrails + nearbyRoutes
        for polyline in allTrails {
            let coords = PolylineCodec.decode(polyline)
            guard coords.count > 1 else { continue }
            let geometry = RouteGeometry(coordinates: coords)
            if geometry.project(c).crossTrackM < 30 { return .allowed }
        }
        // 3. POI check.
        return await checkPOIs(around: c)
    }

    private static func checkPOIs(around c: Coordinate) async -> DropVerdict {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "place"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng),
            latitudinalMeters: 200, longitudinalMeters: 200)
        request.pointOfInterestFilter = MKPointOfInterestFilter(
            including: allowedCategories + forbiddenCategories)

        let response = try? await MKLocalSearch(request: request).start()
        guard let items = response?.mapItems, !items.isEmpty else {
            return .denied(reason: "Drop only on trails you've run or a public spot (park, cafe, transit).")
        }
        let sorted: [(MKMapItem, Double)] = items.map { item in
            let p = item.placemark.coordinate
            return (item, RouteGeometry.planarDistance(
                from: c,
                to: Coordinate(lat: p.latitude, lng: p.longitude)))
        }.sorted { $0.1 < $1.1 }

        for (item, dist) in sorted where dist < 60 {
            if let category = item.pointOfInterestCategory,
               forbiddenCategories.contains(category) {
                return .denied(reason: "Too close to \(displayName(for: category)). Pick a park or cafe instead.")
            }
            let name = (item.name ?? "").lowercased()
            if bannedNameHints.contains(where: name.contains) {
                return .denied(reason: "Looks like a private place. Try a park, cafe, or transit stop.")
            }
        }
        for (item, dist) in sorted where dist < 80 {
            if let category = item.pointOfInterestCategory,
               allowedCategories.contains(category) {
                return .allowed
            }
        }
        return .denied(reason: "Not a runnable public spot. Drop on trails or near parks, cafes, or transit.")
    }

    private static func displayName(for category: MKPointOfInterestCategory) -> String {
        switch category {
        case .hospital: "a hospital"
        case .pharmacy: "a pharmacy"
        case .school: "a school"
        case .university: "a school"
        case .parking: "a parking lot"
        case .airport: "an airport"
        default: "a restricted area"
        }
    }
}
