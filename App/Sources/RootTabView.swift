import CoreLocationKit
import CorePersistence
import DesignSystem
import FeatureActiveRun
import FeatureCompete
import FeatureExplore
import FeatureOnboarding
import FeatureProfile
import FeatureRouteCreation
import FeatureStash
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ActiveRunEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @State private var recoverable: RunBuffer.Pending?

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
        // Free run: no route — collect standalone drops near you.
        .fullScreenCover(isPresented: $session.isFreeRunning) {
            ActiveRunView(route: nil)
        }
        .fullScreenCover(isPresented: $session.isCreatingRoute) {
            RouteCreationFlow()
        }
        // gemrun://route/{uuid} → Explore opens the route detail.
        .onOpenURL { url in
            guard url.scheme == "gemrun", url.host() == "route",
                  let id = UUID(uuidString: url.lastPathComponent) else { return }
            session.pendingDeepLinkRouteID = id
        }
        .onAppear { checkForRecoverableRun() }
        .alert("Resume your run?", isPresented: recoveryBinding) {
            Button("Resume") { resumeRun() }
            Button("Discard", role: .destructive) {
                RunBuffer.clear()
                recoverable = nil
            }
        } message: {
            Text("GemRun closed during a run. Your track and gems are safe.")
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
        .tint(DS.Colors.pulse)
    }

    // MARK: - Crash recovery (docs/04)

    private var recoveryBinding: Binding<Bool> {
        Binding(get: { recoverable != nil }, set: { if !$0 { recoverable = nil } })
    }

    private func checkForRecoverableRun() {
        guard engine.phase == .idle,
              let pending = RunBuffer.pending() else { return }
        let lastActivity = pending.startedAt
            .addingTimeInterval(pending.samples.last?.t ?? 0)
        // Older than 30 minutes → stale; a run that old shouldn't resume.
        guard Date().timeIntervalSince(lastActivity) < 30 * 60 else {
            RunBuffer.clear()
            return
        }
        recoverable = pending
    }

    private func resumeRun() {
        guard let pending = recoverable else { return }
        recoverable = nil
        let routeID = pending.routeID
        guard let stored = try? context.fetch(FetchDescriptor<StoredRoute>(
            predicate: #Predicate { $0.id == routeID })).first else {
            RunBuffer.clear()
            return
        }
        let route = stored.toRoute()
        engine.restore(route: session.collectableRoute(from: route), from: pending)
        session.activeRoute = route
    }
}
