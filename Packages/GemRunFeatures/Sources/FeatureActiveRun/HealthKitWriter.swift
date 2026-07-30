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
        guard HealthPrefs.readSteps else {
            print("[Vendor] HealthKit steps read skipped — in-app switch off")
            return 0
        }
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        let store = HKHealthStore()
        let type = HKQuantityType(.stepCount)
        _ = try? await store.requestAuthorization(toShare: [], read: [type])
        let queried = Date()
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(
                    withStart: start, end: end),
                options: .cumulativeSum) { _, stats, error in
                let count = stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                let ms = Int(Date().timeIntervalSince(queried) * 1_000)
                if let error, count == 0 {
                    // 0 + error usually = read authorization not granted
                    // (Apple reports denied reads as "no data" by design).
                    print("[Vendor] HealthKit steps query → 0 in \(ms) ms (\(error.localizedDescription))")
                } else {
                    print("[Vendor] HealthKit steps query → \(Int(count)) in \(ms) ms")
                }
                continuation.resume(returning: Int(count))
            }
            store.execute(query)
        }
    }

    static func save(_ summary: RunCompletionSummary) async {
        guard HealthPrefs.saveWorkouts else {
            print("[Vendor] HealthKit workout save skipped — in-app switch off")
            return
        }
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
            print("[Vendor] HealthKit workout saved (\(summary.isWalk ? "walk" : "run"), \(summary.distanceM) m, \(summary.durationS) s)")
        } catch {
            // Authorization declined or entitlement absent — non-fatal by
            // design, but never silent: this is the line that explains a
            // run missing from the Health app.
            print("[Vendor] HealthKit workout save FAILED: \(error.localizedDescription)")
        }
    }
}
