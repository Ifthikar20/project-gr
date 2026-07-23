import CoreModels
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
    public private(set) var collectedEvents: [CollectionEngine.Event] = []
    /// UI hook: fired on each collection for haptics/animation.
    public var onCollect: ((CollectionEngine.Event) -> Void)?

    private var recorder: LiveRunRecorder?
    private var collectionEngine: CollectionEngine?
    private var geometry: RouteGeometry?
    private var track: [TrackSample] = []
    private var pausedAccumulator: TimeInterval = 0
    private var lowSpeedSince: TimeInterval?
    private var consumeTask: Task<Void, Never>?

    public init() {}

    public var elapsed: TimeInterval {
        guard phase == .running || phase == .paused else { return 0 }
        return Date().timeIntervalSince(startedAt) - pausedAccumulator
    }

    /// Next uncollected gem ahead of current progress, with straight-line distance.
    public var nextGem: (drop: GemDrop, distanceM: Double)? {
        guard let route, let geometry, let last = lastSample else { return nil }
        let collectedIDs = Set(collectedEvents.map(\.drop.id))
        return route.gemDrops
            .filter { !collectedIDs.contains($0.id) }
            .map { ($0, geometry.distance(from: last.coordinate, to: $0.coordinate)) }
            .min { $0.1 < $1.1 }
    }

    public func start(route: Route) {
        guard phase == .idle || phase == .finished else { return }
        let geometry = RouteGeometry(polyline: route.polyline)
        self.route = route
        self.geometry = geometry
        self.collectionEngine = CollectionEngine(geometry: geometry, drops: route.gemDrops)
        self.track = []
        self.collectedEvents = []
        self.distanceM = 0
        self.pausedAccumulator = 0
        self.startedAt = Date()
        self.phase = .running

        let recorder = LiveRunRecorder()
        self.recorder = recorder
        LiveRunRecorder.requestPermissionIfNeeded()
        recorder.start()

        consumeTask = Task { [weak self] in
            for await sample in recorder.samples {
                self?.ingest(sample)
            }
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
        phase = .finished
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
        if let last = lastSample, let geometry {
            distanceM += geometry.distance(from: last.coordinate, to: sample.coordinate)
        }
        lastSample = sample
        track.append(sample)

        if var engine = collectionEngine {
            let events = engine.ingest(sample)
            collectionEngine = engine
            for event in events {
                collectedEvents.append(event)
                onCollect?(event)
            }
        }
    }

    public var currentPaceSPerKm: Int {
        guard distanceM > 50 else { return 0 }
        return Int(elapsed / (distanceM / 1_000))
    }
}
