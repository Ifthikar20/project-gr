import CoreLocationKit
import CorePersistence
import SwiftData
import SwiftUI

@main
struct GemRunApp: App {
    @State private var session = SessionStore()
    // Owned here (docs/07): a run survives any navigation or view teardown.
    @State private var runEngine = ActiveRunEngine()
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: StoredRoute.self, StoredRun.self, StoredStashItem.self, StoredProfile.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(runEngine)
                .modelContainer(container)
                .preferredColorScheme(.light)   // "Daybreak Pulse" is a light system
                .task {
                    session.attach(context: container.mainContext)
                }
        }
    }
}
