import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Leaderboards (docs/03 §10): per-route best times + weekly gem score.
/// Local-first: boards are computed from on-device runs until Phase F.
public struct CompeteRootView: View {
    @Query private var runs: [StoredRun]
    @State private var board = Board.routes

    enum Board: String, CaseIterable {
        case routes = "Routes"
        case local = "This Week"
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Board", selection: $board) {
                    ForEach(Board.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch board {
                case .routes: routeBoards
                case .local: weeklyBoard
                }
            }
            .background(DS.Colors.ink)
            .navigationTitle("Compete")
        }
    }

    private var validRuns: [StoredRun] {
        runs.filter { $0.statusRaw == RunValidationStatus.valid.rawValue && !$0.isWalk }
    }

    private var routeBoards: some View {
        Group {
            let byRoute = Dictionary(grouping: validRuns, by: \.routeID)
            if byRoute.isEmpty {
                emptyState("Run a route to see its leaderboard here.")
            } else {
                List {
                    ForEach(byRoute.keys.sorted(by: { $0.uuidString < $1.uuidString }),
                            id: \.self) { routeID in
                        if let best = byRoute[routeID]?.min(by: { $0.durationS < $1.durationS }) {
                            Section(best.routeName) {
                                ForEach(Array((byRoute[routeID] ?? [])
                                    .sorted { $0.durationS < $1.durationS }
                                    .prefix(5).enumerated()), id: \.element.id) { i, run in
                                    row(rank: i + 1, time: run.durationS, date: run.startedAt)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var weeklyBoard: some View {
        Group {
            let cal = Calendar.current
            let weekStart = cal.date(from: cal.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
            let weekXP = runs.filter { $0.startedAt >= weekStart }.map(\.xpEarned).reduce(0, +)
            VStack(spacing: 12) {
                Text("+\(weekXP) XP")
                    .font(DS.Typography.statLarge)
                    .foregroundStyle(DS.Colors.gold)
                Text("earned this week")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text("Local rankings arrive when GemRun goes online in your city.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(rank: Int, time: Int, date: Date) -> some View {
        HStack {
            Text("#\(rank)")
                .foregroundStyle(DS.Colors.gold)
                .frame(width: 36, alignment: .leading)
            Text(String(format: "%d:%02d", time / 60, time % 60))
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
            Spacer()
            Text(date, style: .date)
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .listRowBackground(DS.Colors.inkRaised)
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
}
