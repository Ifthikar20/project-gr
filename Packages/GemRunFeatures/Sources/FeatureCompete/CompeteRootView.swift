import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Leaderboards (docs/03 §10), Daybreak Pulse: chip pickers, white rows on
/// snow, own row in pulse. Loaded from the API (mock fakes competitors).
public struct CompeteRootView: View {
    @Query private var runs: [StoredRun]
    @Query(sort: \StoredRoute.createdAt) private var storedRoutes: [StoredRoute]
    @State private var board = Board.routes
    @State private var selectedRouteID: UUID?
    @State private var routeEntries: [LeaderboardEntry] = []
    @State private var localEntries: [LeaderboardEntry] = []
    @State private var isLoading = false

    enum Board: String, CaseIterable {
        case routes = "Routes"
        case local = "This Week"
    }

    public init() {}

    /// Routes worth a board: ones the user has run, else all cached routes.
    private var boardRoutes: [StoredRoute] {
        let runIDs = Set(runs.map(\.routeID))
        let ran = storedRoutes.filter { runIDs.contains($0.id) }
        return ran.isEmpty ? storedRoutes : ran
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(Board.allCases, id: \.self) { b in
                        Chip(b.rawValue, selected: board == b) { board = b }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                switch board {
                case .routes: routeBoard
                case .local: localBoard
                }
            }
            .background(DS.Colors.snow)
            .navigationTitle("Compete")
            .task(id: board) { await load() }
            .task(id: selectedRouteID) { await load() }
        }
    }

    // MARK: - Route board

    private var routeBoard: some View {
        Group {
            if boardRoutes.isEmpty {
                emptyState("Run a route to see its leaderboard here.")
            } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(boardRoutes) { route in
                                Chip(route.name, selected: route.id == currentRouteID) {
                                    selectedRouteID = route.id
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 8)
                    entryList(routeEntries, valueLabel: { format(seconds: $0) })
                }
            }
        }
    }

    private var currentRouteID: UUID? { selectedRouteID ?? boardRoutes.first?.id }

    // MARK: - Local weekly board

    private var localBoard: some View {
        entryList(localEntries, valueLabel: { "\($0) XP" })
    }

    private func entryList(_ entries: [LeaderboardEntry],
                           valueLabel: @escaping (Int) -> String) -> some View {
        Group {
            if isLoading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState("No results yet — get out there.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(entries, id: \.rank) { entry in
                            HStack {
                                Text("#\(entry.rank)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(entry.isMe
                                        ? DS.Colors.snowCard : DS.Colors.pulse)
                                    .frame(width: 40, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.isMe ? "You" : "@\(entry.handle)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(entry.isMe
                                            ? DS.Colors.snowCard : DS.Colors.ink)
                                    Text("Level \(entry.level)")
                                        .font(.caption2)
                                        .foregroundStyle(entry.isMe
                                            ? DS.Colors.snowCard.opacity(0.75)
                                            : DS.Colors.inkSecondary)
                                }
                                Spacer()
                                Text(valueLabel(entry.bestTimeS))
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundStyle(entry.isMe
                                        ? DS.Colors.snowCard : DS.Colors.ink)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(entry.isMe ? DS.Colors.pulse : DS.Colors.snowCard,
                                        in: RoundedRectangle(cornerRadius: 14))
                            .shadow(color: DS.Colors.ink.opacity(0.06), radius: 8, y: 2)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.pulse)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DS.Colors.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch board {
        case .routes:
            guard let id = currentRouteID else { return }
            // GET /v1/routes/{id}/leaderboard
            routeEntries = (try? await API.shared.routeLeaderboard(
                routeID: id, window: .allTime)) ?? []
        case .local:
            // GET /v1/leaderboards/local
            localEntries = (try? await API.shared.localLeaderboard(geohash: "local")) ?? []
        }
    }

    private func format(seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
