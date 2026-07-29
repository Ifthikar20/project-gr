import CoreLocationKit
import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftUI
import UIKit

/// The in-run screen (docs/03 §7), Daybreak Pulse: light map, snow stats
/// band, ink numerals, pulse for the live accent. Presented as a full-screen
/// cover at App root; the engine lives at App level so the run survives.
@MainActor
public struct ActiveRunView: View {
    /// nil = free run: no route, collect standalone drops by proximity.
    let route: Route?
    @Environment(SessionStore.self) private var session
    @Environment(ActiveRunEngine.self) private var engine
    @State private var burst: CollectionEngine.Event?
    @State private var summary: RunCompletionSummary?
    @State private var batteryAtStart: Float = -1
    /// Collect ceremony: the captured gem flies from mid-map into the
    /// stash chip, which bounces as it "catches" the gem.
    @State private var flight: CollectionEngine.Event?
    @State private var flightLanded = false
    @State private var stashBounce = false
    /// Quiet receipt: a small "+1" drifts up beside the stash chip right
    /// as it catches the flying gem, then fades.
    @State private var stashedFloat: CollectionEngine.Event?

    public init(route: Route?) {
        self.route = route
    }

    public var body: some View {
        ZStack {
            if let summary {
                RunSummaryView(summary: summary) {
                    engine.reset()
                    session.activeRoute = nil
                    session.isFreeRunning = false
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
                // Into-the-stash flight: launch shortly after the burst so
                // the two read as one ceremony, then bounce the chip.
                flight = event
                flightLanded = false
                Task {
                    try? await Task.sleep(for: .seconds(0.35))
                    guard flight == event else { return }
                    withAnimation(.easeIn(duration: 0.6)) { flightLanded = true }
                    try? await Task.sleep(for: .seconds(0.6))
                    guard flight == event else { return }
                    flight = nil
                    stashedFloat = event
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                        stashBounce = true
                    }
                    try? await Task.sleep(for: .seconds(0.3))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        stashBounce = false
                    }
                    try? await Task.sleep(for: .seconds(0.9))
                    if stashedFloat == event { stashedFloat = nil }
                }
            }
            // Battery budget instrumentation (docs/04): delta logged at stop.
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryAtStart = UIDevice.current.batteryLevel
            // A restored run is already .running — don't restart it.
            guard engine.phase == .idle || engine.phase == .finished else { return }
            if let route {
                // Client respawn hint (docs/02): strip drops that can't award
                // today, so no celebrating a gem the server would revoke.
                engine.start(route: session.collectableRoute(from: route))
            } else {
                engine.startFree(drops: session.freeRunDrops)
            }
        }
    }

    private var runningUI: some View {
        VStack(spacing: 0) {
            ZStack {
                ActiveRunMapView(route: route,
                                 freeDrops: route == nil ? session.freeRunDrops : [],
                                 plannedPath: route == nil ? session.freeRunPlannedPath : [],
                                 runnerPosition: engine.lastSample?.coordinate,
                                 collectedDropIDs: Set(engine.collectedEvents.map(\.drop.id)),
                                 traveledPath: engine.traveledPath)
                if let event = burst {
                    CollectionBurst(rarity: event.drop.rarity)
                }
                // Stash chip: this run's haul, top-leading (the map's
                // recenter control owns top-trailing). Hidden until the
                // first find — a fresh run starts with a clean map, no
                // orange "0" badge — then pops in to catch the flying gem
                // and stays as the live count.
                if !engine.collectedEvents.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond.fill")
                            .font(.caption.bold())
                            .foregroundStyle(DS.Colors.pulse)
                        Text("\(engine.collectedEvents.count)")
                            .font(.footnote.bold())
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.ink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DS.Colors.snowCard.opacity(0.94), in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
                    .scaleEffect(stashBounce ? 1.18 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .padding([.top, .leading], 12)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.4, anchor: .topLeading)
                        .combined(with: .opacity))
                }
                if let stashed = stashedFloat {
                    StashedFloat(rarity: stashed.drop.rarity)
                        .id(stashed.drop.id)   // restart per gem, even back-to-back
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(.top, 18)
                        .padding(.leading, 96)
                        .allowsHitTesting(false)
                }
                // The gem in flight: map center → stash chip.
                GeometryReader { geo in
                    if let flight {
                        GemIcon(gemID: flight.drop.gemID, size: 46)
                            .position(flightLanded
                                ? CGPoint(x: 52, y: 30)
                                : CGPoint(x: geo.size.width / 2,
                                          y: geo.size.height * 0.42))
                            .scaleEffect(flightLanded ? 0.3 : 1.15)
                            .opacity(flightLanded ? 0.2 : 1)
                    }
                }
                .allowsHitTesting(false)
                if engine.phase == .paused {
                    Text("Paused — resume moving")
                        .font(.footnote.bold())
                        .foregroundStyle(DS.Colors.snowCard)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(DS.Colors.ink.opacity(0.85), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                }
            }
            // Drives the stash chip's first appearance (empty → 1 find).
            .animation(.spring(response: 0.35, dampingFraction: 0.7),
                       value: engine.collectedEvents.isEmpty)
            .frame(maxHeight: .infinity)

            statsBand
        }
        .ignoresSafeArea(edges: .top)
    }

    private var statsBand: some View {
        VStack(spacing: 14) {
            if let next = engine.nextGem {
                HStack(spacing: 8) {
                    RarityBadge(next.drop.rarity, size: 13)
                    if let bearing = engine.nextGemRelativeBearingDeg {
                        Image(systemName: "arrow.up")
                            .font(.footnote.bold())
                            .foregroundStyle(DS.Colors.pulse)
                            .rotationEffect(.degrees(bearing))
                            .animation(.easeInOut(duration: 0.4), value: bearing)
                    }
                    // Apple-Maps-style "Xm · ~Y:ZZ" for the next gem.
                    Text(nextGemLabel(distanceM: next.distanceM,
                                      rarity: next.drop.rarity))
                        .font(.footnote.bold())
                        .foregroundStyle(DS.Colors.ink)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(DS.Colors.snowCard, in: Capsule())
                .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 24) {
                    stat(format(seconds: Int(engine.elapsed)), "Time")
                    stat(UnitFormat.milesText(fromMeters: engine.distanceM), "mi")
                    stat("\(engine.liveSteps)", "Steps")
                    stat(engine.currentPaceSPerKm > 0
                         ? format(seconds: UnitFormat.paceSecPerMile(
                            fromSecPerKm: engine.currentPaceSPerKm)) : "–:––",
                         "min/mi", accent: true)
                }
            }

            HStack(spacing: 16) {
                Button {
                    engine.togglePause()
                } label: {
                    Image(systemName: engine.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                        .background(DS.Colors.snowCard, in: Circle())
                        .overlay(Circle().stroke(DS.Colors.hairline, lineWidth: 1))
                        .foregroundStyle(DS.Colors.ink)
                }
                // Deliberate friction (docs/03): long-press to stop, tap ignored.
                Text("Hold to stop")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.snowCard)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(DS.Colors.pulse, in: RoundedRectangle(cornerRadius: 32))
                    .onLongPressGesture(minimumDuration: 1) { finish() }
            }
        }
        .padding(20)
        .background(DS.Colors.snow)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
        }
    }

    /// "Rare · 240 ft · ~2:15" once we have a pace; falls back to
    /// "Rare · 240 ft" on the first stretch before pace stabilizes.
    /// (ETA math is unit-invariant: meters × s-per-km cancels the same.)
    private func nextGemLabel(distanceM: Double, rarity: Rarity) -> String {
        let base = "\(rarity.rawValue.capitalized) · \(UnitFormat.shortDistance(fromMeters: distanceM))"
        let pace = engine.currentPaceSPerKm
        guard pace > 0 else { return base }
        let etaSec = Int(distanceM / 1_000 * Double(pace))
        return "\(base) · ~\(format(seconds: etaSec))"
    }

    private func stat(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statLarge)
                .foregroundStyle(accent ? DS.Colors.pulse : DS.Colors.ink)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private func finish() {
        // Live pedometer count is the fallback: Health flushes step samples
        // in batches, so the read can come back 0 right at run end.
        let pedometerSteps = engine.liveSteps
        if route == nil {
            guard let free = engine.stopFree() else { return }
            logBattery(duration: free.durationS)
            // POST /v1/drops/collect — server confirms the track passed each drop.
            Task {
                var completion = await session.recordFreeCompletion(
                    track: free.track, collected: free.collected,
                    durationS: free.durationS, distanceM: free.distanceM)
                completion.steps = await runSteps(completion,
                                                  fallback: pedometerSteps)
                summary = completion
                await HealthKitWriter.save(completion)
            }
            return
        }
        guard let result = engine.stop() else { return }
        logBattery(duration: result.validation.durationS)
        // Async: submits to POST /v1/runs/{id}/complete and builds the summary
        // from the authoritative verdict (mock API today, Django later).
        Task {
            var completion = await session.recordCompletion(result)
            completion.steps = await runSteps(completion, fallback: pedometerSteps)
            summary = completion
            await HealthKitWriter.save(completion)
        }
    }

    private func runSteps(_ completion: RunCompletionSummary,
                          fallback: Int) async -> Int {
        let fromHealth = await HealthKitWriter.steps(
            from: completion.startedAt,
            to: completion.startedAt.addingTimeInterval(
                TimeInterval(completion.durationS)))
        return fromHealth > 0 ? fromHealth : fallback
    }

    private func logBattery(duration durationS: Int) {
        let now = UIDevice.current.batteryLevel
        guard batteryAtStart > 0, now > 0, durationS > 60 else { return }
        let perHour = Double(batteryAtStart - now) * 100 * 3_600 / Double(durationS)
        // The docs/04 gate is < 8%/hour — tracked per TestFlight build.
        print(String(format: "[Battery] %.1f%%/hour over %d min",
                     perHour, durationS / 60))
    }
}

/// The subtle "just stashed it" cue: a tiny "+1" in the gem's rarity color
/// that rises from the stash chip's edge and fades — quiet enough to read
/// in peripheral vision mid-run.
@MainActor
struct StashedFloat: View {
    let rarity: Rarity
    @State private var risen = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "diamond.fill")
                .font(.caption2.bold())
            Text("+1")
                .font(.caption.bold())
                .monospacedDigit()
        }
        .foregroundStyle(DS.Colors.rarity(rarity))
        .shadow(color: DS.Colors.snowCard, radius: 3)
        .offset(y: risen ? -24 : 0)
        .opacity(risen ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { risen = true }
        }
    }
}

@MainActor
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
            Image(systemName: DS.rarityGlyph(rarity))
                .font(.system(size: 72))
                .foregroundStyle(DS.Colors.rarity(rarity))
                .scaleEffect(scale)
                .opacity(opacity)
                .shadow(color: DS.Colors.snowCard, radius: 8)
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
