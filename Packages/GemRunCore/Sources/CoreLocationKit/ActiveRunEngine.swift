import CoreModels
import CoreMotion
import Foundation
import GameKitCore
import Observation

/// Drives a run end-to-end (docs/07): owns the recorder, feeds the collection
/// engine, accumulates the track. Owned at App level so a run survives any
/// navigation; the Active Run screen just renders its state.
@MainActor
@Observable
public final class ActiveRunEngine {
    public enum Phase: Equatable {
        case idle, running, paused, finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var route: Route?
    public private(set) var startedAt = Date()
    public private(set) var distanceM: Double = 0
    public private(set) var currentSpeed: Double = 0
    public private(set) var lastSample: TrackSample?
    /// Every accepted position, in order — the breadcrumb trail the run map
    /// draws behind the runner ("the steps we add as we actually move").
    public private(set) var traveledPath: [Coordinate] = []
    public private(set) var collectedEvents: [CollectionEngine.Event] = []
    /// UI hook: fired on each collection for haptics/animation.
    public var onCollect: ((CollectionEngine.Event) -> Void)?
    /// Fired for every ACCEPTED sample while running — the zone-mint
    /// pipeline listens here so runs feed zone progress. Auto-pause gates
    /// it naturally: paused samples never reach this.
    public var onSample: ((TrackSample) -> Void)?

    /// Steps taken this run, live from CMPedometer — the same motion pipeline
    /// that feeds Apple Health. 0 when Motion & Fitness is declined.
    public private(set) var liveSteps = 0

    private var recorder: LiveRunRecorder?
    private var collectionEngine: CollectionEngine?
    private var geometry: RouteGeometry?
    private var track: [TrackSample] = []
    private var pausedAccumulator: TimeInterval = 0
    private var lowSpeedSince: TimeInterval?
    private var consumeTask: Task<Void, Never>?

    // Motion-derived distance (Apple-Maps-walking style): GPS jitter creeps
    // the km counter up while standing still, so once the pedometer reports,
    // it owns `distanceM` and GPS deltas stop accumulating. Distance walked
    // during a pause is excluded via the offset.
    private let pedometer = CMPedometer()
    private var pedometerReporting = false
    private var pedometerLastM: Double = 0
    private var pedometerExcludedM: Double = 0

    public init() {}

    public var elapsed: TimeInterval {
        guard phase == .running || phase == .paused else { return 0 }
        return Date().timeIntervalSince(startedAt) - pausedAccumulator
    }

    /// Next uncollected gem, with straight-line distance (route or free run).
    public var nextGem: (drop: GemDrop, distanceM: Double)? {
        guard let last = lastSample else { return nil }
        let collectedIDs = Set(collectedEvents.map(\.drop.id))
        let candidates = isFreeRun ? freeDrops : (route?.gemDrops ?? [])
        return candidates
            .filter { !collectedIDs.contains($0.id) }
            .map { ($0, RouteGeometry.planarDistance(from: last.coordinate,
                                                     to: $0.coordinate)) }
            .min { $0.1 < $1.1 }
    }

    /// Direction of travel (degrees, 0 = north, clockwise) from recent motion.
    public private(set) var courseDeg: Double?

    /// Bearing to the next gem relative to travel direction, -180…180
    /// (0 = straight ahead). Drives the next-gem chip's arrow (docs/03 §7).
    public var nextGemRelativeBearingDeg: Double? {
        guard let next = nextGem, let last = lastSample, let courseDeg else { return nil }
        let k = 111_320.0
        let dy = (next.drop.lat - last.lat) * k
        let dx = (next.drop.lng - last.lng) * k * cos(last.lat * .pi / 180)
        let absolute = atan2(dx, dy) * 180 / .pi
        var relative = absolute - courseDeg
        while relative > 180 { relative -= 360 }
        while relative < -180 { relative += 360 }
        return relative
    }

    // Free runs (no route): collect standalone drops by pure proximity.
    public private(set) var isFreeRun = false
    private var freeDrops: [GemDrop] = []
    private var lastFreeCollection: Coordinate?

    public func start(route: Route) {
        guard phase == .idle || phase == .finished else { return }
        isFreeRun = false
        prepare(route: route, startedAt: Date())
        RunBuffer.begin(routeID: route.id, startedAt: startedAt)
        beginRecording()
    }

    /// Start a route-free run to collect standalone drops nearby.
    public func startFree(drops: [GemDrop]) {
        guard phase == .idle || phase == .finished else { return }
        isFreeRun = true
        freeDrops = drops
        lastFreeCollection = nil
        route = nil
        geometry = nil
        collectionEngine = nil
        track = []
        traveledPath = []
        collectedEvents = []
        distanceM = 0
        pausedAccumulator = 0
        startedAt = Date()
        phase = .running
        beginRecording()
    }

    /// Finish a free run: raw materials for the server's drop-collect check.
    public func stopFree() -> (track: [TrackSample], collected: [GemDrop],
                               durationS: Int, distanceM: Int)? {
        guard isFreeRun else { return nil }
        recorder?.stop()
        consumeTask?.cancel()
        pedometer.stopUpdates()
        phase = .finished
        let duration = track.count >= 2 ? Int(track.last!.t - track.first!.t) : 0
        return (track, collectedEvents.map(\.drop), duration, Int(distanceM))
    }

    /// Resume a run recovered from the crash-safe buffer (docs/04): replay the
    /// saved samples through the same pipeline, then continue recording live.
    public func restore(route: Route, from pending: RunBuffer.Pending) {
        guard phase == .idle || phase == .finished else { return }
        isFreeRun = false
        prepare(route: route, startedAt: pending.startedAt)
        RunBuffer.begin(routeID: route.id, startedAt: pending.startedAt)
        for sample in pending.samples {
            ingest(sample)
        }
        // The gap while the app was dead counts as paused, not elapsed.
        let lastT = pending.samples.last?.t ?? 0
        pausedAccumulator = max(0, Date().timeIntervalSince(startedAt) - lastT)
        lowSpeedSince = nil
        phase = .running
        beginRecording()
    }

    private func prepare(route: Route, startedAt: Date) {
        let geometry = RouteGeometry(polyline: route.polyline)
        self.route = route
        self.geometry = geometry
        self.collectionEngine = CollectionEngine(geometry: geometry, drops: route.gemDrops)
        self.track = []
        self.traveledPath = []
        self.collectedEvents = []
        self.distanceM = 0
        self.pausedAccumulator = 0
        self.startedAt = startedAt
        self.phase = .running
    }

    private func beginRecording() {
        let recorder = LiveRunRecorder()
        self.recorder = recorder
        LiveRunRecorder.requestPermissionIfNeeded()
        recorder.start()
        consumeTask = Task { [weak self] in
            for await sample in recorder.samples {
                self?.ingest(sample)
            }
        }
        beginPedometer()
    }

    private func beginPedometer() {
        liveSteps = 0
        pedometerReporting = false
        pedometerLastM = 0
        pedometerExcludedM = 0
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: startedAt) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                self?.ingestPedometer(data)
            }
        }
    }

    private func ingestPedometer(_ data: CMPedometerData) {
        guard phase == .running || phase == .paused else { return }
        liveSteps = data.numberOfSteps.intValue
        guard let cumulative = data.distance?.doubleValue else { return }
        if phase == .paused {
            pedometerExcludedM += max(0, cumulative - pedometerLastM)
        }
        pedometerLastM = cumulative
        pedometerReporting = true
        if phase == .running {
            distanceM = max(0, cumulative - pedometerExcludedM)
        }
    }

    public func togglePause() {
        switch phase {
        case .running: phase = .paused
        case .paused: phase = .running
        default: break
        }
    }

    public func stop() -> RunResult? {
        guard let route, let geometry else { return nil }
        recorder?.stop()
        consumeTask?.cancel()
        pedometer.stopUpdates()
        phase = .finished
        RunBuffer.clear()
        let validation = RunValidator.validate(track: track, geometry: geometry)
        return RunResult(route: route, startedAt: startedAt, track: track,
                         collectedDrops: collectedEvents.map(\.drop),
                         validation: validation)
    }

    public func reset() {
        route = nil
        geometry = nil
        collectionEngine = nil
        recorder = nil
        phase = .idle
    }

    private func ingest(_ sample: TrackSample) {
        currentSpeed = sample.speed

        // Auto-pause (docs/04): low speed sustained pauses the clock, not the GPS.
        if sample.speed < GPSRules.autoPauseBelowSpeed {
            if let since = lowSpeedSince {
                if sample.t - since >= GPSRules.autoPauseAfterS, phase == .running {
                    phase = .paused
                }
            } else {
                lowSpeedSince = sample.t
            }
        } else {
            lowSpeedSince = nil
            if phase == .paused, sample.speed > GPSRules.autoResumeAboveSpeed {
                phase = .running
            }
        }

        guard phase == .running else { return }
        if let last = lastSample {
            let step = RouteGeometry.planarDistance(from: last.coordinate,
                                                    to: sample.coordinate)
            // GPS deltas only until the pedometer reports; from then on
            // motion data owns the distance so standing still adds nothing.
            if !pedometerReporting {
                distanceM += step
            }
            // Course from recent motion, for the next-gem bearing arrow.
            if step > 2 {
                let k = 111_320.0
                let dy = (sample.lat - last.lat) * k
                let dx = (sample.lng - last.lng) * k * cos(last.lat * .pi / 180)
                courseDeg = atan2(dx, dy) * 180 / .pi
            }
        }
        lastSample = sample
        track.append(sample)
        traveledPath.append(sample.coordinate)
        onSample?(sample)
        if !isFreeRun {
            RunBuffer.append(sample)
        }

        if var engine = collectionEngine {
            let events = engine.ingest(sample)
            collectionEngine = engine
            for event in events {
                collectedEvents.append(event)
                onCollect?(event)
            }
        } else if isFreeRun {
            // Proximity-only collection: 200 ft threshold + exit hysteresis.
            let collectedIDs = Set(collectedEvents.map(\.drop.id))
            for drop in freeDrops where !collectedIDs.contains(drop.id) {
                let dist = RouteGeometry.planarDistance(from: sample.coordinate,
                                                        to: drop.coordinate)
                guard dist <= CollectionRules.dropCollectRadiusM else { continue }
                if let last = lastFreeCollection,
                   RouteGeometry.planarDistance(from: sample.coordinate, to: last)
                       <= CollectionRules.hysteresisExitRadiusM { continue }
                lastFreeCollection = drop.coordinate
                let event = CollectionEngine.Event(drop: drop, atAlongRouteM: 0)
                collectedEvents.append(event)
                onCollect?(event)
            }
        }

        // Adaptive GPS (docs/04): relax the filter when no gem is near.
        if let next = nextGem {
            recorder?.setRelaxedFilter(next.distanceM > GPSRules.relaxFilterBeyondM)
        }
    }

    public var currentPaceSPerKm: Int {
        guard distanceM > 50 else { return 0 }
        return Int(elapsed / (distanceM / 1_000))
    }
}
