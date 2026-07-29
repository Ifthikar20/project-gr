import Foundation
import HealthKit

/// Reads total lifetime walking+running distance from Apple Health — the
/// input to gem-wallet minting ("the more you run, the more you can drop").
/// Requires the read purpose string + HealthKit entitlement (project.yml);
/// returns 0 quietly when unavailable or declined.
public enum HealthDistance {
    /// Long-lived store for the observer query — HealthKit stops delivering
    /// if the store or query is deallocated.
    private static let observerStore = HKHealthStore()
    private static var observerQuery: HKObserverQuery?

    public static func totalRunKm() async -> Double {
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        let store = HKHealthStore()
        let type = HKQuantityType(.distanceWalkingRunning)
        _ = try? await store.requestAuthorization(toShare: [], read: [type])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type,
                                          quantitySamplePredicate: nil,
                                          options: .cumulativeSum) { _, stats, _ in
                let meters = stats?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
                continuation.resume(returning: meters / 1_000)
            }
            store.execute(query)
        }
    }

    /// Health pushes instead of us polling: fires `onChange` whenever new
    /// walking/running distance lands — immediately while the app is open,
    /// and ~hourly from the background (iOS's floor for distance types,
    /// needs the background-delivery entitlement). Callback arrives on a
    /// HealthKit queue. Idempotent: second call is a no-op.
    public static func startObservingDistance(_ onChange: @escaping @Sendable () -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), observerQuery == nil else { return }
        let type = HKQuantityType(.distanceWalkingRunning)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, done, error in
            if error == nil { onChange() }
            done()
        }
        observerQuery = query
        observerStore.execute(query)
        observerStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
    }
}
