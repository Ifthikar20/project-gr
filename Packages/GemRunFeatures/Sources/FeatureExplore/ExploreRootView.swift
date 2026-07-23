import CoreLocation
import CoreMap
import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Map home (docs/03 §2): routes, standalone gem drops left by other
/// runners, drop mode (place a wallet gem anywhere with a pin-drop
/// animation), and free runs to collect nearby drops.
public struct ExploreRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredRoute.createdAt) private var storedRoutes: [StoredRoute]
    @State private var selectedID: UUID?
    @State private var detailRoute: Route?
    @State private var nearbyDrops: [GemDrop] = []
    @State private var isDropMode = false
    @State private var pendingDropCoordinate: Coordinate?

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
                    onSelect: { detailRoute = $0 },
                    onTapCoordinate: isDropMode ? { pendingDropCoordinate = $0 } : nil
                )
                .ignoresSafeArea()

                VStack(alignment: .trailing, spacing: 12) {
                    actionButtons
                    if isDropMode {
                        dropModeBanner
                    } else if routes.isEmpty {
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
            .sheet(item: $pendingDropCoordinate) { coordinate in
                DropGemSheet(coordinate: coordinate) { newDrop in
                    withAnimation { nearbyDrops.append(newDrop) }
                    isDropMode = false
                }
                .presentationDetents([.height(320)])
            }
            .task {
                await loadNearby()
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

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Free run: go collect the standalone drops near you.
            Button {
                session.startFreeRun(drops: nearbyDrops)
            } label: {
                Image(systemName: "figure.run")
                    .font(.title3.bold())
                    .foregroundStyle(DS.Colors.ink)
                    .frame(width: 48, height: 48)
                    .background(DS.Colors.snowCard, in: Circle())
                    .overlay(Circle().stroke(DS.Colors.hairline, lineWidth: 1))
                    .shadow(color: DS.Colors.ink.opacity(0.15), radius: 6, y: 2)
            }
            .disabled(nearbyDrops.isEmpty)
            .opacity(nearbyDrops.isEmpty ? 0.5 : 1)

            // Drop mode: place a wallet gem anywhere.
            Button {
                isDropMode.toggle()
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

extension Coordinate: Identifiable {
    public var id: String { "\(lat),\(lng)" }
}

/// Pick a wallet gem for the tapped location (docs: earn-by-running wallet).
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
