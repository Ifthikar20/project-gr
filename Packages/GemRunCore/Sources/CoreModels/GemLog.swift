import Foundation
import os

/// Unified logging for the whole app: one subsystem, one category per area,
/// so Console.app / `log stream` can filter "everything the API did" or
/// "everything the run engine did" with a single predicate.
///
/// `print` is invisible outside Xcode and unfilterable in release builds —
/// these are not: errors and faults persist on device and survive into
/// sysdiagnose, which is what makes field breakage findable after the fact.
public enum GemLog {
    public static let subsystem = "com.gemrun.app"

    public static let api = Logger(subsystem: subsystem, category: "api")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let persist = Logger(subsystem: subsystem, category: "persist")
    public static let explore = Logger(subsystem: subsystem, category: "explore")
    public static let run = Logger(subsystem: subsystem, category: "run")
    public static let buffer = Logger(subsystem: subsystem, category: "runbuffer")
    public static let health = Logger(subsystem: subsystem, category: "health")
    public static let map = Logger(subsystem: subsystem, category: "map")

    /// Run a throwing operation; on failure log WHY and return nil.
    /// The drop-in replacement for silent `try?` — identical nil-on-failure
    /// semantics, but the error is never swallowed unseen.
    @discardableResult
    public static func attempt<T>(_ logger: Logger, _ label: String,
                                  _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Async twin of `attempt`.
    @discardableResult
    public static func attempt<T>(_ logger: Logger, _ label: String,
                                  _ body: () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch {
            logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
