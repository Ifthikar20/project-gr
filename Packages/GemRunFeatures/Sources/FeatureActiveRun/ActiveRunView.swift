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
            guard engine.phase == .idle || engine.phase == .finished else { return }
            engine.onCollect = { event in
                burst = event
                haptic(for: event.drop.rarity)
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if burst == event { burst = nil }
                }
            }
            engine.start(route: route)
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
        // Async: submits to POST /v1/runs/{id}/complete and builds the summary
        // from the authoritative verdict (mock API today, Django later).
        Task { summary = await session.recordCompletion(result) }
    }

    private func haptic(for rarity: Rarity) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        // Rarity-scaled follow-ups (docs/03): extra impacts for higher tiers.
        let extraPulses = GemHaptics.collectionPattern(for: rarity).dropFirst()
        for (i, pulse) in extraPulses.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + pulse.delay + Double(i) * 0.05) {
                UIImpactFeedbackGenerator(style: .heavy)
                    .impactOccurred(intensity: pulse.intensity)
            }
        }
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
