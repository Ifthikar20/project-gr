import CoreLocation
import CoreMap
import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Map home (docs/03 §2), Airbnb search-results style: light map, image-top
/// route cards (mini map preview as the "photo"), pulse FAB.
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
                            .foregroundStyle(DS.Colors.snowCard)
                            .frame(width: 56, height: 56)
                            .background(DS.Colors.pulse, in: Circle())
                            .shadow(color: DS.Colors.ink.opacity(0.2), radius: 8, y: 3)
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
            // gemrun://route/{id} deep links land here via SessionStore.
            .onChange(of: session.pendingDeepLinkRouteID) { _, id in
                guard let id else { return }
                if let stored = storedRoutes.first(where: { $0.id == id }) {
                    detailRoute = stored.toRoute()
                }
                session.pendingDeepLinkRouteID = nil
            }
        }
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

    /// GET /v1/routes near the user, upserted into the SwiftData cache — the
    /// map renders cached routes instantly and refreshes when the call lands.
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

/// Airbnb listing-card anatomy: image on top (map preview), then title,
/// meta line, and the rarity row.
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
