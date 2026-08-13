import CoreModels
import Foundation
import GameKitCore
import Observation
import SwiftData

/// One service owns the day's zones, the metres walked in them, and the
/// mint: providers resolve the zones (day-cached), the pure tracker meters
/// the walk, CardMinter rolls the card, SwiftData keeps it, SessionStore
/// gets the XP, and `lastMint` fires the ceremony wherever the user is.
///
/// Lives in CorePersistence (SwiftData + UserDefaults + GameKitCore are all
/// here already); the map/network providers are injected through
/// ZoneProviding by the App target, keeping the module graph acyclic — the
/// CoreAuth "service above persistence" precedent.
@MainActor
@Observable
public final class ZoneMintEngine {
    public enum ZonesState: Equatable {
        case idle, loading, ready, unavailable
    }

    public enum FixSource {
        case map, run
    }

    public private(set) var todayZones: [RunnerZone] = []
    public private(set) var zonesState: ZonesState = .idle
    public private(set) var progressM: [UUID: Double] = [:]
    public private(set) var mintedTodayCount = 0
    /// The freshly minted card, if any — Explore and the run screen observe
    /// this to play the ceremony and reveal, then set it back to nil.
    public var lastMint: RunnerCard?
    /// Steps/pace for run-sourced mints, injected by the App layer —
    /// CorePersistence can't see ActiveRunEngine.
    public var runStatsProvider: (() -> (steps: Int, paceSPerKm: Int?))?

    private let providers: [any ZoneProviding]
    private var tracker: ZoneProgressTracker?
    private var context: ModelContext?
    private var session: SessionStore?
    private var lastRunFixAt: TimeInterval?
    private var isRefreshing = false

    /// Run fixes own the stream: while they flow, map fixes are dropped for
    /// this long (Explore keeps observing beneath the run cover — without
    /// this, every metre run on the map screen counts twice).
    private let runPriorityWindowS: TimeInterval = 10

    public init(providers: [any ZoneProviding]) {
        self.providers = providers
    }

    public func attach(context: ModelContext, session: SessionStore) {
        self.context = context
        self.session = session
    }

    private var today: Int { Int(Date().timeIntervalSince1970 / 86_400) }

    private var mintThreshold: Double {
        MintThresholdOverride.current() ?? ZoneRules.mintDistanceM
    }

    /// What the progress rings fill toward — the kilometre, or the dev
    /// override while it's set.
    public var mintTargetM: Double { mintThreshold }

    /// Resolve the day's zones: cache first, then providers in order. A
    /// provider answering `nil` (unreachable) falls through; `[]` (answered
    /// empty) stops the chain — an answer is an answer.
    public func refreshZones(around center: Coordinate) async {
        guard FeatureFlags.shared.isEnabled(.runnerCards), !isRefreshing else { return }
        let day = today
        if zonesState == .ready, todayZones.first?.day == day,
           ZoneCacheStore.load(day: day, near: center) != nil {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if let cached = ZoneCacheStore.load(day: day, near: center) {
            adopt(zones: cached, day: day)
            return
        }
        if todayZones.isEmpty { zonesState = .loading }
        for provider in providers {
            guard let zones = await provider.zones(around: center, day: day) else {
                continue
            }
            ZoneCacheStore.save(day: day, center: center, zones: zones)
            adopt(zones: zones, day: day)
            return
        }
        zonesState = .unavailable
    }

    private func adopt(zones: [RunnerZone], day: Int) {
        let saved = ZoneProgressStore.load(day: day)
        todayZones = zones
        progressM = saved.progressM
        mintedTodayCount = saved.mintCounts.values.reduce(0, +)
        tracker = ZoneProgressTracker(zones: zones,
                                      initialProgressM: saved.progressM,
                                      mintCounts: saved.mintCounts,
                                      mintDistanceM: mintThreshold)
        zonesState = .ready
        GemLog.explore.info("zones ready: \(zones.count, privacy: .public) for day \(day, privacy: .public)")
    }

    /// Feed one position. The engine stamps the clock itself so map fixes
    /// and run samples (whose native t bases differ) share one timeline.
    public func ingest(lat: Double, lng: Double, accuracyM: Double,
                       source: FixSource) {
        guard FeatureFlags.shared.isEnabled(.runnerCards), tracker != nil else { return }
        rolloverIfNeeded(currentLat: lat, currentLng: lng)
        guard tracker != nil else { return }
        let now = Date().timeIntervalSince1970
        if source == .map, let lastRun = lastRunFixAt,
           now - lastRun < runPriorityWindowS {
            return
        }
        if source == .run { lastRunFixAt = now }

        let fix = ZoneFix(t: now, lat: lat, lng: lng, accuracyM: accuracyM)
        guard var tracker else { return }
        let events = tracker.ingest(fix, source: source == .map ? .map : .run)
        self.tracker = tracker
        guard !events.isEmpty else { return }
        progressM = tracker.progressM
        for event in events {
            if case .minted(let zoneID, _) = event {
                mint(in: zoneID, source: source)
            }
        }
        if let day = todayZones.first?.day {
            ZoneProgressStore.save(day: day, progressM: tracker.progressM,
                                   mintCounts: tracker.mintCounts)
        }
    }

    /// Convenience for the run pipeline: accepted TrackSamples, restamped
    /// onto the shared clock.
    public func ingestRunSample(_ sample: TrackSample) {
        ingest(lat: sample.lat, lng: sample.lng,
               accuracyM: sample.horizontalAccuracy, source: .run)
    }

    private func rolloverIfNeeded(currentLat: Double, currentLng: Double) {
        guard let zoneDay = todayZones.first?.day, zoneDay != today else { return }
        // Midnight passed with the app open: yesterday's zones are gone,
        // fresh ones resolve around wherever the user is now.
        todayZones = []
        tracker = nil
        progressM = [:]
        mintedTodayCount = 0
        zonesState = .idle
        let center = Coordinate(lat: currentLat, lng: currentLng)
        Task { await refreshZones(around: center) }
    }

    private func mint(in zoneID: UUID, source: FixSource) {
        guard let zone = todayZones.first(where: { $0.id == zoneID }) else { return }
        let mintedBefore = context.flatMap { context in
            GemLog.attempt(GemLog.persist, "count minted cards") {
                try context.fetchCount(FetchDescriptor<StoredRunnerCard>())
            }
        } ?? 0
        let runStats = source == .run ? runStatsProvider?() : nil
        let stats = MintStats(distanceM: Int(mintThreshold),
                              steps: runStats?.steps ?? 0,
                              xpEarned: 0,
                              paceSPerKm: runStats?.paceSPerKm,
                              mintedDuringRun: source == .run)
        // Seeded by (day, zone, serial) for replayability, XORed with real
        // entropy — the next pull must not be predictable from the map.
        var entropy = SystemRandomNumberGenerator()
        let seed = StableSeed.daily(day: zone.day, lat: zone.lat, lng: zone.lng,
                                    salt: 0x4D69_6E74 &+ UInt64(mintedBefore))
            ^ entropy.next()
        let card = CardMinter.mint(seed: seed, zone: zone, at: Date(),
                                   serial: mintedBefore + 1, stats: stats)
        if let context {
            context.insert(StoredRunnerCard(from: card))
            GemLog.attempt(GemLog.persist, "save minted card") { try context.save() }
        }
        session?.recordCardMint(xp: card.stats.xpEarned)
        mintedTodayCount += 1
        lastMint = card
        GemLog.session.info("minted \(card.name, privacy: .public) (\(card.rarity.rawValue, privacy: .public) \(card.type.rawValue, privacy: .public)) in \(zone.name, privacy: .public)")
    }
}
