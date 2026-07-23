import DesignSystem
import FeatureCompete
import FeatureExplore
import FeatureProfile
import FeatureStash
import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            ExploreRootView()
                .tabItem { Label("Explore", systemImage: "map.fill") }
            StashRootView()
                .tabItem { Label("Stash", systemImage: "diamond.fill") }
            CompeteRootView()
                .tabItem { Label("Compete", systemImage: "trophy.fill") }
            ProfileRootView()
                .tabItem { Label("Profile", systemImage: "person.fill") }
        }
        .tint(DS.Colors.gold)
    }
}

#Preview {
    RootTabView().environment(SessionStore())
}
