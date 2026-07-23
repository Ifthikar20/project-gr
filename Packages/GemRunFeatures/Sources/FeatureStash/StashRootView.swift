import DesignSystem
import SwiftUI

/// The collection grid (docs/03 §9). Phase A: empty state only.
public struct StashRootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            PlaceholderScreen(
                title: "Stash",
                subtitle: "Your stash is empty — run a route to start collecting.",
                systemImage: "diamond"
            )
            .navigationTitle("Stash")
            .toolbarBackground(DS.Colors.ink, for: .navigationBar)
        }
    }
}

#Preview {
    StashRootView()
}
