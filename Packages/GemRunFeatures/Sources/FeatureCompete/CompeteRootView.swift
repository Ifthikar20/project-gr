import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Compete (docs/03 §10), Daybreak Pulse.
/// "My Routes": every run you've completed, newest first, as cards —
/// local SwiftData history merged with the server's copy (GET /v1/runs/mine)
/// so a fresh install still shows the past.
/// "This Week": the friends board — you plus everyone you follow, ranked by
/// this week's XP. Swipe a friend left to remove; the magnifier searches
/// players by username to add.
public struct CompeteRootView: View {
    @Query(sort: \StoredRun.startedAt, order: .reverse) private var runs: [StoredRun]
    @State private var board = Board.myRoutes
    @State private var serverRuns: [CompletedRun] = []
    @State private var friendEntries: [FriendEntry] = []
    @State private var isLoading = false
    @State private var isSearchPresented = false

    enum Board: String, CaseIterable {
        case myRoutes = "My Routes"
        case week = "This Week"
    }

    public init() {}

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
                case .myRoutes: myRoutesBoard
                case .week: weekBoard
                }
            }
            .background(DS.Colors.snow)
            .navigationTitle("Compete")
            .toolbar {
                if board == .week {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isSearchPresented = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(DS.Colors.ink)
                        }
                        .accessibilityLabel("Search players")
                    }
                }
            }
            .sheet(isPresented: $isSearchPresented) {
                PlayerSearchSheet(
                    friendIDs: Set(friendEntries.map(\.id))
                ) { refreshed in
                    withAnimation { friendEntries = refreshed }
                }
            }
            .task(id: board) { await load() }
        }
    }

    // MARK: - My Routes (completed runs as cards)

    /// One card per completed run. Local StoredRun rows win (they carry
    /// gems collected and include free runs); server rows fill in history
    /// this device doesn't have.
    private struct RunCard: Identifiable {
        let id: UUID
        let routeName: String
        let startedAt: Date
        let distanceM: Int
        let durationS: Int
        let paceSPerKm: Int
        let xpEarned: Int
        let gemsCollected: Int?
        let isWalk: Bool
    }

    private var completedRuns: [RunCard] {
        var cards: [UUID: RunCard] = [:]
        for r in serverRuns {
            cards[r.id] = RunCard(id: r.id, routeName: r.routeName,
                                  startedAt: r.startedAt, distanceM: r.distanceM,
                                  durationS: r.durationS, paceSPerKm: r.paceSPerKm,
                                  xpEarned: r.xpEarned, gemsCollected: nil,
                                  isWalk: r.isWalk)
        }
        for r in runs {
            cards[r.id] = RunCard(id: r.id, routeName: r.routeName,
                                  startedAt: r.startedAt, distanceM: r.distanceM,
                                  durationS: r.durationS, paceSPerKm: r.paceSPerKm,
                                  xpEarned: r.xpEarned, gemsCollected: r.gemsCollected,
                                  isWalk: r.isWalk)
        }
        return cards.values.sorted { $0.startedAt > $1.startedAt }
    }

    private var myRoutesBoard: some View {
        Group {
            let cards = completedRuns
            if cards.isEmpty {
                emptyState("Finish a run and it'll show up here.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(cards) { card in
                            runCardView(card)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func runCardView(_ card: RunCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.routeName)
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Spacer()
                Text(card.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            HStack(spacing: 14) {
                stat(UnitFormat.milesLabel(fromMeters: Double(card.distanceM),
                                           decimals: 2))
                stat(format(seconds: card.durationS))
                if card.paceSPerKm > 0 {
                    stat("\(format(seconds: UnitFormat.paceSecPerMile(fromSecPerKm: card.paceSPerKm))) /mi")
                }
                if card.isWalk {
                    stat("walk")
                }
                Spacer()
                if let gems = card.gemsCollected, gems > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "diamond.fill")
                            .font(.caption2)
                        Text("\(gems)")
                            .font(.caption.bold())
                            .monospacedDigit()
                    }
                    .foregroundStyle(DS.Colors.pulse)
                }
                Text("+\(card.xpEarned) XP")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.pulse)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: DS.Colors.ink.opacity(0.06), radius: 8, y: 2)
    }

    private func stat(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(DS.Colors.inkSecondary)
    }

    // MARK: - This Week (friends board)

    private var weekBoard: some View {
        Group {
            if isLoading && friendEntries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if friendEntries.count <= 1 {
                emptyState("It's quiet in here — tap the magnifier to find "
                           + "friends by username.")
            } else {
                List {
                    ForEach(Array(friendEntries.enumerated()),
                            id: \.element.id) { i, entry in
                        weekRow(entry, rank: i + 1)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16,
                                                      bottom: 5, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !entry.isMe {
                                    Button(role: .destructive) {
                                        remove(entry)
                                    } label: {
                                        Label("Remove", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func weekRow(_ entry: FriendEntry, rank: Int) -> some View {
        HStack {
            Text("#\(rank)")
                .font(.subheadline.bold())
                .foregroundStyle(entry.isMe ? DS.Colors.snowCard : DS.Colors.pulse)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isMe ? "You" : "@\(entry.handle)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.isMe ? DS.Colors.snowCard : DS.Colors.ink)
                Text("Level \(entry.level)")
                    .font(.caption2)
                    .foregroundStyle(entry.isMe
                        ? DS.Colors.snowCard.opacity(0.75)
                        : DS.Colors.inkSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(entry.weeklyXp) XP")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(entry.isMe ? DS.Colors.snowCard : DS.Colors.ink)
                Text("\(UnitFormat.milesLabel(fromMeters: Double(entry.weeklyDistanceM))) · \(entry.weeklyRuns) run\(entry.weeklyRuns == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(entry.isMe
                        ? DS.Colors.snowCard.opacity(0.75)
                        : DS.Colors.inkSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(entry.isMe ? DS.Colors.pulse : DS.Colors.snowCard,
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: DS.Colors.ink.opacity(0.06), radius: 8, y: 2)
    }

    private func remove(_ entry: FriendEntry) {
        withAnimation { friendEntries.removeAll { $0.id == entry.id } }
        Task { try? await API.shared.removeFriend(profileID: entry.id) }
    }

    // MARK: - Shared

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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch board {
        case .myRoutes:
            serverRuns = (try? await API.shared.myRuns()) ?? []
        case .week:
            friendEntries = (try? await API.shared.friends()) ?? []
        }
    }

    private func format(seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Username search (docs/03 §10): debounced GET /v1/players, one-tap add.
/// Adding returns the refreshed weekly board so the list behind the sheet
/// is already correct when it closes.
@MainActor
struct PlayerSearchSheet: View {
    let friendIDs: Set<UUID>
    let onBoardRefreshed: ([FriendEntry]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlayerSummary] = []
    @State private var addedIDs: Set<UUID> = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DS.Colors.inkSecondary)
                    TextField("Search by username", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isSearching { ProgressView().controlSize(.small) }
                }
                .padding(12)
                .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(DS.Colors.hairline, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if results.isEmpty {
                    Text(query.count < 2
                         ? "Type at least two letters of a username."
                         : (isSearching ? " " : "No players match \"\(query)\"."))
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.inkSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(results) { player in
                                playerRow(player)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .background(DS.Colors.snow)
            .navigationTitle("Find players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(DS.Colors.pulse)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: query) { _, text in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await search(text)
            }
        }
    }

    private func playerRow(_ player: PlayerSummary) -> some View {
        let alreadyFriend = friendIDs.contains(player.id)
            || addedIDs.contains(player.id)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("@\(player.handle)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.ink)
                Text("Level \(player.level)")
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            Spacer()
            Button {
                add(player)
            } label: {
                Text(alreadyFriend ? "Added" : "Add")
                    .font(.caption.bold())
                    .foregroundStyle(alreadyFriend
                        ? DS.Colors.inkSecondary : DS.Colors.snowCard)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(alreadyFriend
                        ? AnyShapeStyle(DS.Colors.snow)
                        : AnyShapeStyle(DS.Colors.pulse),
                        in: Capsule())
            }
            .disabled(alreadyFriend)
        }
        .padding(12)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: DS.Colors.ink.opacity(0.05), radius: 6, y: 2)
    }

    private func search(_ text: String) async {
        guard text.count >= 2 else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        results = (try? await API.shared.searchPlayers(query: text)) ?? []
    }

    private func add(_ player: PlayerSummary) {
        addedIDs.insert(player.id)
        Task {
            if let refreshed = try? await API.shared.addFriend(profileID: player.id) {
                onBoardRefreshed(refreshed)
            }
        }
    }
}
