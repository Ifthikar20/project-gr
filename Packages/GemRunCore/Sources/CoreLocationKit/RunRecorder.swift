import CoreModels
import Foundation

/// The GPS pipeline contract (docs/04): filtering, smoothing, auto-pause.
/// `LiveRunRecorder` (CLLocationManager-backed) lands in Phase D.
public protocol RunRecording: Sendable {
    /// Accepted, smoothed samples. Finishes when the run stops.
    var samples: AsyncStream<TrackSample> { get }
    func start() async
    func stop() async
}

public enum GPSRules {
    public static let maxHorizontalAccuracyM: Double = 30
    public static let distanceFilterM: Double = 5
    public static let relaxedDistanceFilterM: Double = 10   // >500 m from next gem
    public static let autoPauseBelowSpeed: Double = 0.5      // m/s, sustained 10 s
    public static let autoPauseAfterS: TimeInterval = 10
    public static let autoResumeAboveSpeed: Double = 1.0     // m/s, sustained 3 s
    public static let autoResumeAfterS: TimeInterval = 3
}
