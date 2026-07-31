import CoreLocationKit
import CoreModels
import CorePersistence
import SwiftData
import SwiftUI

@main
@MainActor
struct GemRunApp: App {
    @State private var session = SessionStore()
    // Owned here (docs/07): a run survives any navigation or view teardown.
    @State private var runEngine = ActiveRunEngine()
    private let container: ModelContainer

    init() {
        let schema = Schema([StoredRoute.self, StoredRun.self,
                             StoredStashItem.self, StoredProfile.self])
        do {
            container = try ModelContainer(for: schema)
        } catch {
            // A failed migration / corrupt store used to be an unconditional
            // launch crash for every installed user. Fall back to an
            // in-memory store instead: the app opens, server data re-syncs,
            // and the fault is on record for diagnosis.
            GemLog.persist.fault("SwiftData container failed — falling back to in-memory store: \(String(describing: error), privacy: .public)")
            do {
                container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("Failed to create even an in-memory SwiftData container: \(error)")
            }
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
