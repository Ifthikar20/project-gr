import CoreLocation
import CoreModels
import Foundation

public enum GPSRules {
    public static let maxHorizontalAccuracyM: Double = 30
    public static let distanceFilterM: Double = 5
    public static let autoPauseBelowSpeed: Double = 0.5      // m/s, sustained 10 s
    public static let autoPauseAfterS: TimeInterval = 10
    public static let autoResumeAboveSpeed: Double = 1.0     // m/s, sustained 3 s
}

/// The docs/04 GPS pipeline: CLLocationManager → accuracy/staleness filter →
/// 3-sample weighted smoothing → AsyncStream of accepted samples.
/// Create and use from the main thread (delegate callbacks then arrive there).
public final class LiveRunRecorder: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<TrackSample>.Continuation?
    private var recent: [CLLocation] = []
    private var startTime: Date?

    public private(set) lazy var samples: AsyncStream<TrackSample> = AsyncStream { c in
        self.continuation = c
    }

    override public init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = GPSRules.distanceFilterM
    }

    public static func requestPermissionIfNeeded() {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    public var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    public func start() {
        startTime = Date()
        recent.removeAll()
        // Background updates only while a run is live (docs/04, docs/07).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        continuation?.finish()
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let start = startTime else { return }
        for loc in locations {
            // docs/04 sample filter: bad accuracy, invalid speed, stale fix.
            guard loc.horizontalAccuracy > 0,
                  loc.horizontalAccuracy <= GPSRules.maxHorizontalAccuracyM,
                  loc.speed >= 0,
                  loc.timestamp.timeIntervalSinceNow > -5 else { continue }

            recent.append(loc)
            if recent.count > 3 { recent.removeFirst() }

            // Weighted moving average, newest first: 0.5 / 0.3 / 0.2.
            let weights: [Double] = switch recent.count {
            case 3: [0.2, 0.3, 0.5]
            case 2: [0.4, 0.6]
            default: [1.0]
            }
            var lat = 0.0, lng = 0.0, speed = 0.0
            for (w, l) in zip(weights, recent) {
                lat += w * l.coordinate.latitude
                lng += w * l.coordinate.longitude
                speed += w * max(0, l.speed)
            }

            continuation?.yield(TrackSample(
                t: loc.timestamp.timeIntervalSince(start),
                lat: lat, lng: lng,
                horizontalAccuracy: loc.horizontalAccuracy,
                speed: speed
            ))
        }
    }
}
