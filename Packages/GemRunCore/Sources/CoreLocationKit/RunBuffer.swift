import CoreModels
import Foundation

/// Crash-safe append-only buffer for the in-progress run (docs/04): a JSONL
/// file — header line with route/start, then one line per accepted sample.
/// A killed app loses at most the last write; `pending()` powers "Resume run".
///
/// Failures here are logged, never thrown: recording must not interrupt a
/// run, but a durability layer that fails silently is worse than none —
/// "Resume your run?" simply never appearing is undiagnosable without these
/// log lines.
public enum RunBuffer {
    public struct Pending: Sendable {
        public let routeID: UUID
        public let startedAt: Date
        public let samples: [TrackSample]
    }

    private struct Header: Codable {
        let routeID: UUID
        let startedAt: Date
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        GemLog.attempt(GemLog.buffer, "create Application Support directory") {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("active-run.jsonl")
    }

    public static func begin(routeID: UUID, startedAt: Date) {
        clear()
        GemLog.attempt(GemLog.buffer, "write run buffer header") {
            let data = try JSONEncoder().encode(Header(routeID: routeID, startedAt: startedAt))
            try (String(decoding: data, as: UTF8.self) + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func append(_ sample: TrackSample) {
        GemLog.attempt(GemLog.buffer, "append run buffer sample") {
            let data = try JSONEncoder().encode(sample)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    public static func clear() {
        // Absence is the normal case (no run in progress) — not an error.
        try? FileManager.default.removeItem(at: url)
    }

    public static func pending() -> Pending? {
        // No file = no pending run; that read failing is the normal path.
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n")
        guard let first = lines.first else { return nil }
        guard let header = GemLog.attempt(GemLog.buffer, "decode run buffer header", {
            try JSONDecoder().decode(Header.self, from: Data(first.utf8))
        }) else {
            // A file that exists but has a corrupt header can never resume —
            // clear it so it doesn't shadow the next run's buffer.
            clear()
            return nil
        }
        let decoder = JSONDecoder()
        let samples = lines.dropFirst().compactMap {
            try? decoder.decode(TrackSample.self, from: Data($0.utf8))
        }
        let dropped = lines.count - 1 - samples.count
        if dropped > 0 {
            GemLog.buffer.warning("recovered run: dropped \(dropped) corrupt sample line(s)")
        }
        return Pending(routeID: header.routeID, startedAt: header.startedAt, samples: samples)
    }
}
