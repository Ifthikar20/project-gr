import CoreAuth
import CoreLocationKit
import CoreMap
import CoreModels
import CoreNetworking
import CorePersistence
import SwiftData
import SwiftUI

@main
@MainActor
struct GemRunApp: App {
    @State private var session = SessionStore()
    // Owned here (docs/07): a run survives any navigation or view teardown.
    @State private var runEngine = ActiveRunEngine()
    // The day's zones + the kilometre counter + the mint (docs/21). The
    // providers are injected here — the only layer that sees both the
    // network (Overpass) and the map (MKLocalSearch fallback).
    @State private var zoneEngine = ZoneMintEngine(providers: [
        OverpassZoneProvider(), LocalSearchZoneProvider(),
    ])
    private let container: ModelContainer

    init() {
        let schema = Schema([StoredRoute.self, StoredRun.self,
                             StoredStashItem.self, StoredProfile.self,
                             StoredRunnerCard.self])
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
                .environment(zoneEngine)
                .modelContainer(container)
                .preferredColorScheme(.light)   // "Daybreak Pulse" is a light system
                .task {
                    session.attach(context: container.mainContext)
                    zoneEngine.attach(context: container.mainContext,
                                      session: session)
                    // Runs feed the kilometre too: accepted samples flow to
                    // the zone engine (it gates on the runner_cards flag),
                    // and run-sourced mints stamp live steps + pace.
                    runEngine.onSample = { [zoneEngine] sample in
                        zoneEngine.ingestRunSample(sample)
                    }
                    zoneEngine.runStatsProvider = { [runEngine] in
                        (steps: runEngine.liveSteps,
                         paceSPerKm: runEngine.currentPaceSPerKm > 0
                             ? runEngine.currentPaceSPerKm : nil)
                    }
                    // After attach (restore needs the stored profile):
                    // adopt the persisted session token — or re-register a
                    // tokenless sign-in — so a relaunch is the SAME account,
                    // not an unauthenticated stranger (docs/18).
                    await AuthService(session: session).restoreSession()
                }
        }
    }
}
