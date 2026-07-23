import CoreModels
import Foundation

/// Crash-safe append-only buffer for the in-progress run (docs/04): a JSONL
/// file — header line with route/start, then one line per accepted sample.
/// A killed app loses at most the last write; `pending()` powers "Resume run".
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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active-run.jsonl")
    }

    public static func begin(routeID: UUID, startedAt: Date) {
        clear()
        if let data = try? JSONEncoder().encode(Header(routeID: routeID, startedAt: startedAt)) {
            try? (String(data: data, encoding: .utf8)! + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func append(_ sample: TrackSample) {
        guard let data = try? JSONEncoder().encode(sample),
              let line = String(data: data, encoding: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    public static func pending() -> Pending? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n")
        guard let first = lines.first,
              let header = try? JSONDecoder().decode(Header.self, from: Data(first.utf8)) else {
            return nil
        }
        let samples = lines.dropFirst().compactMap {
            try? JSONDecoder().decode(TrackSample.self, from: Data($0.utf8))
        }
        return Pending(routeID: header.routeID, startedAt: header.startedAt, samples: samples)
    }
}
