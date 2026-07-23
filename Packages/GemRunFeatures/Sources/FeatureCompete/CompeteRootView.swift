import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Leaderboards (docs/03 §10), loaded from the API — the mock includes fake
/// competitors so the multi-user UI is visible before the Django backend.
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
                Picker("Board", selection: $board) {
                    ForEach(Board.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch board {
                case .routes: routeBoard
                case .local: localBoard
                }
            }
            .background(DS.Colors.ink)
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
                                Button(route.name) { selectedRouteID = route.id }
                                    .font(.footnote.bold())
                                    .foregroundStyle(route.id == currentRouteID
                                        ? DS.Colors.ink : DS.Colors.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(route.id == currentRouteID
                                        ? DS.Colors.gold : DS.Colors.inkRaised,
                                        in: Capsule())
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
                List(entries, id: \.rank) { entry in
                    HStack {
                        Text("#\(entry.rank)")
                            .foregroundStyle(entry.isMe ? DS.Colors.ink : DS.Colors.gold)
                            .frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.isMe ? "You" : "@\(entry.handle)")
                                .foregroundStyle(entry.isMe ? DS.Colors.ink : DS.Colors.textPrimary)
                            Text("Level \(entry.level)")
                                .font(.caption2)
                                .foregroundStyle(entry.isMe
                                    ? DS.Colors.ink.opacity(0.7) : DS.Colors.textSecondary)
                        }
                        Spacer()
                        Text(valueLabel(entry.bestTimeS))
                            .monospacedDigit()
                            .foregroundStyle(entry.isMe ? DS.Colors.ink : DS.Colors.textPrimary)
                    }
                    .listRowBackground(entry.isMe ? DS.Colors.gold : DS.Colors.inkRaised)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.gold)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
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
