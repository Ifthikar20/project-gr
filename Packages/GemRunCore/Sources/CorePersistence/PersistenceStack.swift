import CoreModels
import Foundation

/// SwiftData container + offline sync queue (docs/05 client mirror, docs/04 offline).
/// Wired in Phase F; Phase D adds the crash-safe append-only run sample buffer here.
public enum PersistenceStack {
    // TODO(Phase D): append-only TrackSample buffer for in-progress runs.
    // TODO(Phase F): SwiftData ModelContainer (CachedRoute, DraftRoute, LocalRun,
    // StashCache) + SyncQueue with idempotency keys and backoff.
}
