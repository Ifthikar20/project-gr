import CoreModels
import CorePersistence
import HealthKit

/// Writes a finished run/walk to Health as an HKWorkout, and reads back the
/// step count for the run window. Fails silently when Health is unavailable
/// or the user declines; requires the HealthKit entitlement + Info.plist
/// purpose strings (configured in project.yml — remove both there if signing
/// complains).
enum HealthKitWriter {
    /// Steps recorded in Health during the run window. 0 when Health is
    /// unavailable/declined — and possibly for a minute or two right after
    /// a run, since the motion coprocessor flushes step samples in batches.
    static func steps(from start: Date, to end: Date) async -> Int {
        guard HealthPrefs.readSteps,
              HKHealthStore.isHealthDataAvailable() else { return 0 }
        let store = HKHealthStore()
        let type = HKQuantityType(.stepCount)
        _ = try? await store.requestAuthorization(toShare: [], read: [type])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(
                    withStart: start, end: end),
                options: .cumulativeSum) { _, stats, _ in
                let count = stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(count))
            }
            store.execute(query)
        }
    }

    static func save(_ summary: RunCompletionSummary) async {
        guard HealthPrefs.saveWorkouts,
              HKHealthStore.isHealthDataAvailable(),
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
