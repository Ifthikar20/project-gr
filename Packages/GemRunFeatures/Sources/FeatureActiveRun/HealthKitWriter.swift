import CoreModels
import CorePersistence
import HealthKit

/// Writes a finished run/walk to Health as an HKWorkout (docs/07 — write-only,
/// no reads in MVP). Fails silently when Health is unavailable or the user
/// declines; requires the HealthKit entitlement + Info.plist purpose strings
/// (configured in project.yml — remove both there if signing complains).
enum HealthKitWriter {
    static func save(_ summary: RunCompletionSummary) async {
        guard HKHealthStore.isHealthDataAvailable(),
              summary.status != .invalid, summary.durationS > 60 else { return }
        let store = HKHealthStore()
        do {
            try await store.requestAuthorization(
                toShare: [.workoutType(), HKQuantityType(.distanceWalkingRunning)],
                read: [])
            let config = HKWorkoutConfiguration()
            config.activityType = summary.isWalk ? .walking : .running
            config.locationType = .outdoor
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config,
                                           device: .local())
            let start = summary.startedAt
            let end = start.addingTimeInterval(TimeInterval(summary.durationS))
            try await builder.beginCollection(at: start)
            let distance = HKQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: Double(summary.distanceM)),
                start: start, end: end)
            try await builder.addSamples([distance])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            // Authorization declined or entitlement absent — non-fatal by design.
        }
    }
}
