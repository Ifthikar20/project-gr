import CoreModels
import Observation

/// Auth/user session state shared app-wide via Environment (docs/07).
/// Optimistic values live here and reconcile against server verdicts (Phase F).
@Observable
final class SessionStore {
    var isSignedIn = false
    var profile: UserProfile?

    var xp = 0
    var level = 1
    var streakCount = 0
    var streakShields = 0
}
