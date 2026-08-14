import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Compete (docs/03 §10), Daybreak Pulse.
/// "My Routes": a seven-day summary (totals, trend vs the week before,
/// miles-per-day bars), your records (longest, fastest, best haul), then
/// every real run newest first with PB badges — local SwiftData history
/// merged with the server's copy (GET /v1/runs/mine) so a fresh install
/// still shows the past. Sub-0.1-mile starts fold into one quiet row.
/// "Friends": the friends board — you plus everyone you follow, ranked by
/// this week's XP. Swipe a friend left to remove; the magnifier searches
/// players by username to add.
@MainActor
public struct CompeteRootView: View {
    @Query(sort: \StoredRun.startedAt, order: .reverse) private var runs: [StoredRun]
    @State private var board = Board.myRoutes
    @State private var serverRuns: [CompletedRun] = []
    @State private var friendEntries: [FriendEntry] = []
    @State private var isLoading = false
    @State private var isSearchPresented = false
    /// Short starts (under ~0.1 mi) fold into one row; this unfolds them.
    @State private var showShortRuns = false

    enum Board: String, CaseIterable {
        case myRoutes = "My Routes"
        case week = "Friends"
        case calories = "Calories"
    }

    public init() {}

    /// Boards the current entitlements allow (Feature flags, Settings ›
    /// Features). "My Routes" is always on.
    private var visibleBoards: [Board] {
        Board.allCases.filter { b in
            switch b {
            case .myRoutes: true
            case .week: FeatureFlags.shared.isEnabled(.friendsBoard)
            case .calories: FeatureFlags.shared.isEnabled(.caloriesInsights)
            }
        }
    }

    public var body: some View {
        // A board switched off while selected falls back to My Routes.
        let active = visibleBoards.contains(board) ? board : .myRoutes
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(visibleBoards, id: \.self) { b in
                        Chip(b.rawValue, selected: active == b) { board = b }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                switch active {
                case .myRoutes: myRoutesBoard
                case .week: weekBoard
                case .calories: CaloriesView()
                }
            }
            .background(DS.Colors.snow)
            .navigationTitle("Compete")
            .toolbar {
                if active == .week {
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
            .task(id: active) { await load(active) }
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

    /// A run this short never got going — history, not a highlight.
    private static let shortRunCutoffM = 160   // ≈ 0.1 mi

    private var myRoutesBoard: some View {
        Group {
            let cards = completedRuns
            if cards.isEmpty {
                emptyState("Finish a run and it'll show up here.")
            } else {
                let real = cards.filter { $0.distanceM >= Self.shortRunCutoffM }
                let shortStarts = cards.filter { $0.distanceM < Self.shortRunCutoffM }
                let longestID = real.count >= 2
                    ? real.max { $0.distanceM < $1.distanceM }?.id : nil
                let fastestID = real.count >= 2
                    ? real.filter { $0.paceSPerKm > 0 && $0.distanceM >= 400 }
                        .min { $0.paceSPerKm < $1.paceSPerKm }?.id
                    : nil
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        weekSummary(cards)
                        if real.count >= 2 { bestsStrip(real) }
                        ForEach(real) { card in
                            runCardView(card,
                                        badge: card.id == longestID ? "Longest"
                                            : card.id == fastestID ? "Fastest"
                                            : nil)
                        }
                        if !shortStarts.isEmpty {
                            shortStartsSection(shortStarts)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    /// The headline: the last seven days at a glance — totals up top, the
    /// week's shape as seven quiet bars, and the week-before comparison
    /// when it means something.
    private func weekSummary(_ cards: [RunCard]) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let prior = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let thisWeek = cards.filter { $0.startedAt >= weekAgo }
        let lastWeek = cards.filter { $0.startedAt >= prior && $0.startedAt < weekAgo }
        let miles = UnitFormat.miles(
            fromMeters: Double(thisWeek.reduce(0) { $0 + $1.distanceM }))
        let priorMiles = UnitFormat.miles(
            fromMeters: Double(lastWeek.reduce(0) { $0 + $1.distanceM }))
        let delta = miles - priorMiles
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 7 days")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                if abs(delta) >= 0.1 {
                    Text("\(delta > 0 ? "▲" : "▼") \(String(format: "%.1f", abs(delta))) mi vs week before")
                        .font(.caption.bold())
                        .foregroundStyle(delta > 0 ? DS.Colors.pulse : DS.Colors.inkSecondary)
                }
            }
            HStack(spacing: 24) {
                summaryStat(String(format: "%.1f", miles), "miles")
                summaryStat(format(seconds: thisWeek.reduce(0) { $0 + $1.durationS }),
                            "time")
                summaryStat("\(thisWeek.count)", "runs")
                summaryStat("+\(thisWeek.reduce(0) { $0 + $1.xpEarned })", "XP")
                Spacer()
            }
            SevenDayBars(days: dailyMiles(cards, calendar: cal, today: today))
        }
        .airbnbCard()
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DS.Typography.statMedium)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    /// Miles per day, oldest → today, weekday letter attached.
    private func dailyMiles(_ cards: [RunCard], calendar cal: Calendar,
                            today: Date) -> [(label: String, miles: Double)] {
        (0..<7).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: today) ?? today
            let meters = cards
                .filter { cal.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0) { $0 + $1.distanceM }
            return (label: day.formatted(.dateTime.weekday(.narrow)),
                    miles: UnitFormat.miles(fromMeters: Double(meters)))
        }
    }

    /// Your records, computed from every full run on the board.
    private func bestsStrip(_ real: [RunCard]) -> some View {
        let longest = real.max { $0.distanceM < $1.distanceM }
        let fastest = real.filter { $0.paceSPerKm > 0 && $0.distanceM >= 400 }
            .min { $0.paceSPerKm < $1.paceSPerKm }
        let richest = real.max { $0.xpEarned < $1.xpEarned }
        return HStack(spacing: 10) {
            if let longest {
                bestTile("Longest",
                         UnitFormat.milesLabel(fromMeters: Double(longest.distanceM)))
            }
            if let fastest {
                bestTile("Fastest",
                         "\(format(seconds: UnitFormat.paceSecPerMile(fromSecPerKm: fastest.paceSPerKm))) /mi")
            }
            if let richest, richest.xpEarned > 0 {
                bestTile("Best haul", "+\(richest.xpEarned) XP")
            }
        }
    }

    private func bestTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.pulse)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .airbnbCard(padding: 12)
    }

    /// Runs that never got going, folded into one quiet row until asked.
    private func shortStartsSection(_ shortStarts: [RunCard]) -> some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showShortRuns.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showShortRuns ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold())
                    Text("\(shortStarts.count) short start\(shortStarts.count == 1 ? "" : "s") under 0.1 mi")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(DS.Colors.inkSecondary)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            if showShortRuns {
                ForEach(shortStarts) { card in
                    runCardView(card)
                }
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func runCardView(_ card: RunCard, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.routeName)
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                if let badge {
                    HStack(spacing: 3) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(badge)
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(DS.Colors.pulse)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(DS.Colors.pulse.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(dayLabel(card.startedAt))
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

    // MARK: - Friends (weekly board)

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
        Task {
            // The row is optimistically gone from the UI — a failed unfollow
            // (friend reappears on next load) was untraceable without this.
            await GemLog.attempt(GemLog.session, "unfollow \(entry.handle)", {
                try await API.shared.removeFriend(profileID: entry.id)
            })
        }
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

    private func load(_ active: Board) async {
        isLoading = true
        defer { isLoading = false }
        // A failed load renders as an empty board — indistinguishable from
        // "no runs/friends yet" without these log lines.
        switch active {
        case .myRoutes:
            serverRuns = await GemLog.attempt(GemLog.session, "load my runs", {
                try await API.shared.myRuns()
            }) ?? []
        case .week:
            friendEntries = await GemLog.attempt(GemLog.session, "load friends board", {
                try await API.shared.friends()
            }) ?? []
        case .calories:
            break   // fully on-device — nothing to fetch
        }
    }

    private func format(seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Seven quiet bars, one per day, today on the right. Single hue for the
/// single series (the map volt), faint tracks marking the empty days,
/// weekday letters in text ink with today emphasized. The totals above
/// carry the numbers; the bars carry only the shape of the week.
@MainActor
private struct SevenDayBars: View {
    let days: [(label: String, miles: Double)]

    var body: some View {
        let peak = max(days.map(\.miles).max() ?? 0, 0.01)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(DS.Colors.ink.opacity(0.05))
                        if day.miles > 0 {
                            Capsule()
                                .fill(DS.Colors.map)
                                .frame(height: max(CGFloat(day.miles / peak) * 56, 6))
                        }
                    }
                    .frame(height: 56)
                    .frame(maxWidth: .infinity)
                    Text(day.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(i == days.count - 1
                            ? DS.Colors.ink : DS.Colors.inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%.1f miles over the last seven days",
                                   days.reduce(0) { $0 + $1.miles }))
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
        results = await GemLog.attempt(GemLog.session, "player search", {
            try await API.shared.searchPlayers(query: text)
        }) ?? []
    }

    private func add(_ player: PlayerSummary) {
        addedIDs.insert(player.id)
        Task {
            // The button already flipped to "Added" — a failed follow needs
            // at least a trace, since the UI can't take it back here.
            if let refreshed = await GemLog.attempt(GemLog.session, "follow \(player.handle)", {
                try await API.shared.addFriend(profileID: player.id)
            }) {
                onBoardRefreshed(refreshed)
            }
        }
    }
}
