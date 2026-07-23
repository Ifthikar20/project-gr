import CoreLocation
import CoreMap
import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Map home (docs/03 §2): full-bleed map, route card carousel, "+" FAB.
public struct ExploreRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredRoute.createdAt) private var storedRoutes: [StoredRoute]
    @State private var selectedID: UUID?
    @State private var detailRoute: Route?

    public init() {}

    private var routes: [Route] {
        storedRoutes
            .filter { $0.statusRaw == RouteStatus.published.rawValue }
            .map { $0.toRoute() }
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ExploreMapView(routes: routes, selectedID: selectedID) { route in
                    detailRoute = route
                }
                .ignoresSafeArea()

                VStack(alignment: .trailing, spacing: 12) {
                    Button {
                        session.isCreatingRoute = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.bold())
                            .foregroundStyle(DS.Colors.ink)
                            .frame(width: 56, height: 56)
                            .background(DS.Colors.gold, in: Circle())
                            .shadow(radius: 6)
                    }
                    .padding(.trailing, 20)

                    if routes.isEmpty {
                        emptyBanner
                    } else {
                        routeCards
                    }
                }
                .padding(.bottom, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $detailRoute) { route in
                RouteDetailView(route: route)
            }
            .task {
                await loadNearbyRoutes()
            }
        }
    }

    private var routeCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(routes) { route in
                    RouteCard(route: route)
                        .onTapGesture {
                            selectedID = route.id
                            detailRoute = route
                        }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyBanner: some View {
        Text("No routes here yet — be the first to create one")
            .font(.footnote)
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(12)
            .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
    }

    /// GET /v1/routes near the user (mock API today, Django later), upserted
    /// into the SwiftData cache — the map renders cached routes instantly and
    /// refreshes when the call lands, so the network is never a bottleneck.
    private func loadNearbyRoutes() async {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        let center = manager.location.map {
            Coordinate(lat: $0.coordinate.latitude, lng: $0.coordinate.longitude)
        } ?? Coordinate(lat: 37.7749, lng: -122.4194)

        guard let fetched = try? await API.shared.nearbyRoutes(
            lat: center.lat, lng: center.lng, radiusM: 5_000) else { return }
        let cachedIDs = Set(storedRoutes.map(\.id))
        for route in fetched where !cachedIDs.contains(route.id) {
            context.insert(StoredRoute(route: route))
        }
        try? context.save()
    }
}

struct RouteCard: View {
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(route.name)
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Label(String(format: "%.1f km", Double(route.distanceM) / 1_000),
                      systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                Label("\(route.elevationGainM) m", systemImage: "arrow.up.right")
                Text(route.difficulty.rawValue.capitalized)
            }
            .font(.caption)
            .foregroundStyle(DS.Colors.textSecondary)
            RarityDots(counts: rarityCounts)
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(DS.Colors.gold.opacity(0.25), lineWidth: 1))
    }

    private var rarityCounts: [Rarity: Int] {
        Dictionary(grouping: route.gemDrops, by: \.rarity).mapValues(\.count)
    }
}
