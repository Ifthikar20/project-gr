import Foundation

/// App-level Apple Health switches (Settings → Permissions). iOS never
/// lets an app flip its own SYSTEM permissions, so these gate what GemRun
/// actually does: a toggle off means the feature simply doesn't run,
/// regardless of what the system grant says — an honest in-app on/off.
public enum HealthPrefs {
    private static let saveKey = "gemrun.health.saveWorkouts"
    private static let stepsKey = "gemrun.health.readSteps"

    /// Save finished runs/walks to Apple Health as workouts.
    public static var saveWorkouts: Bool {
        get { UserDefaults.standard.object(forKey: saveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: saveKey) }
    }

    /// Read the Health step count for run stats (off = live pedometer only).
    public static var readSteps: Bool {
        get { UserDefaults.standard.object(forKey: stepsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: stepsKey) }
    }
}
