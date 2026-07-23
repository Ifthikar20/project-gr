import CorePersistence
import DesignSystem
import FeatureActiveRun
import FeatureCompete
import FeatureExplore
import FeatureOnboarding
import FeatureProfile
import FeatureRouteCreation
import FeatureStash
import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        @Bindable var session = session
        Group {
            if session.isOnboarded && session.profile != nil {
                tabs
            } else {
                OnboardingView()
            }
        }
        // Cross-tab presentations (docs/03 nav): Active Run and the creation
        // flow are full-screen covers at root, triggered via SessionStore.
        .fullScreenCover(item: $session.activeRoute) { route in
            ActiveRunView(route: route)
        }
        .fullScreenCover(isPresented: $session.isCreatingRoute) {
            RouteCreationFlow()
        }
    }

    private var tabs: some View {
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
