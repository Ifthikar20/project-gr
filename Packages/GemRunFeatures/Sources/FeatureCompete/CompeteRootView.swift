import DesignSystem
import SwiftUI

/// Leaderboards (docs/03 §10). Phase A: segmented shell with empty states.
public struct CompeteRootView: View {
    @State private var board = Board.routes

    enum Board: String, CaseIterable {
        case routes = "Routes"
        case local = "Local"
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

                PlaceholderScreen(
                    title: board.rawValue,
                    subtitle: board == .routes
                        ? "Run a route to see its leaderboard here."
                        : "Weekly gem scores for your area land here.",
                    systemImage: "trophy"
                )
            }
            .background(DS.Colors.ink)
            .navigationTitle("Compete")
        }
    }
}

#Preview {
    CompeteRootView()
}
