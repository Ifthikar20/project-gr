import CoreLocationKit
import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftUI
import UIKit

/// The in-run screen (docs/03 §7): chase map, stats band, next-gem chip,
/// collection bursts, slide-free deliberate stop. Presented as a full-screen
/// cover at App root; the engine lives at App level so the run survives.
public struct ActiveRunView: View {
    let route: Route
    @Environment(SessionStore.self) private var session
    @Environment(ActiveRunEngine.self) private var engine
    @State private var burst: CollectionEngine.Event?
    @State private var summary: RunCompletionSummary?
    @State private var batteryAtStart: Float = -1

    public init(route: Route) {
        self.route = route
    }

    public var body: some View {
        ZStack {
            if let summary {
                RunSummaryView(summary: summary) {
                    engine.reset()
                    session.activeRoute = nil
                }
            } else {
                runningUI
            }
        }
        .onAppear {
            engine.onCollect = { event in
                burst = event
                HapticPlayer.shared.collection(for: event.drop.rarity)
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if burst == event { burst = nil }
                }
            }
            // Battery budget instrumentation (docs/04): delta logged at stop.
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryAtStart = UIDevice.current.batteryLevel
            // A restored run is already .running — don't restart it.
            guard engine.phase == .idle || engine.phase == .finished else { return }
            // Client respawn hint (docs/02): strip drops that can't award today
            // so the runner never celebrates a gem the server would revoke.
            engine.start(route: session.collectableRoute(from: route))
        }
        .preferredColorScheme(.dark)
    }

    private var runningUI: some View {
        VStack(spacing: 0) {
            ZStack {
                ActiveRunMapView(route: route,
                                 runnerPosition: engine.lastSample?.coordinate,
                                 collectedDropIDs: Set(engine.collectedEvents.map(\.drop.id)))
                if let event = burst {
                    CollectionBurst(rarity: event.drop.rarity)
                }
                if engine.phase == .paused {
                    Text("Paused — resume moving")
                        .font(.footnote.bold())
                        .padding(8)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                }
            }
            .frame(maxHeight: .infinity)

            statsBand
        }
        .ignoresSafeArea(edges: .top)
    }

    private var statsBand: some View {
        VStack(spacing: 14) {
            if let next = engine.nextGem {
                HStack(spacing: 8) {
                    Image(systemName: "diamond.fill")
                        .foregroundStyle(DS.Colors.rarity(next.drop.rarity))
                    if let bearing = engine.nextGemRelativeBearingDeg {
                        Image(systemName: "arrow.up")
                            .font(.footnote.bold())
                            .foregroundStyle(DS.Colors.gold)
                            .rotationEffect(.degrees(bearing))
                            .animation(.easeInOut(duration: 0.4), value: bearing)
                    }
                    Text("\(next.drop.rarity.rawValue.capitalized) · \(Int(next.distanceM)) m")
                        .font(.footnote.bold())
                        .foregroundStyle(DS.Colors.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DS.Colors.inkRaised, in: Capsule())
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 24) {
                    stat(format(seconds: Int(engine.elapsed)), "Time")
                    stat(String(format: "%.2f", engine.distanceM / 1_000), "km")
                    stat(engine.currentPaceSPerKm > 0
                         ? format(seconds: engine.currentPaceSPerKm) : "–:––", "min/km")
                }
            }

            HStack(spacing: 16) {
                Button {
                    engine.togglePause()
                } label: {
                    Image(systemName: engine.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                        .background(DS.Colors.inkRaised, in: Circle())
                        .foregroundStyle(DS.Colors.textPrimary)
                }
                // Deliberate friction (docs/03): long-press to stop, tap ignored.
                Text("Hold to stop")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(DS.Colors.gold, in: RoundedRectangle(cornerRadius: 32))
                    .onLongPressGesture(minimumDuration: 1) { finish() }
            }
        }
        .padding(20)
        .background(DS.Colors.ink)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statLarge)
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private func finish() {
        guard let result = engine.stop() else { return }
        logBattery(duration: result.validation.durationS)
        // Async: submits to POST /v1/runs/{id}/complete and builds the summary
        // from the authoritative verdict (mock API today, Django later).
        Task {
            let completion = await session.recordCompletion(result)
            summary = completion
            await HealthKitWriter.save(completion)
        }
    }

    private func logBattery(duration durationS: Int) {
        let now = UIDevice.current.batteryLevel
        guard batteryAtStart > 0, now > 0, durationS > 60 else { return }
        let perHour = Double(batteryAtStart - now) * 100 * 3_600 / Double(durationS)
        // The docs/04 gate is < 8%/hour — tracked per TestFlight build.
        print(String(format: "🔋 [Battery] %.1f%%/hour over %d min",
                     perHour, durationS / 60))
    }
}

struct CollectionBurst: View {
    let rarity: Rarity
    @State private var scale = 0.3
    @State private var opacity = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Colors.rarity(rarity), lineWidth: 3)
                .scaleEffect(scale * 2.2)
                .opacity(opacity * 0.5)
            Image(systemName: "diamond.fill")
                .font(.system(size: 72))
                .foregroundStyle(DS.Colors.rarity(rarity))
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.4)) { scale = 1.0 }
            withAnimation(.easeOut(duration: 1.2).delay(0.3)) { opacity = 0 }
        }
        .allowsHitTesting(false)
    }
}

func format(seconds: Int) -> String {
    seconds >= 3_600
        ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
