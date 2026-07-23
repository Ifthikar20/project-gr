import Foundation
import HealthKit

/// Reads total lifetime walking+running distance from Apple Health — the
/// input to gem-wallet minting ("the more you run, the more you can drop").
/// Requires the read purpose string + HealthKit entitlement (project.yml);
/// returns 0 quietly when unavailable or declined.
public enum HealthDistance {
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
}
