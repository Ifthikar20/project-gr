import Foundation

/// Minimal seedable RNG (SplitMix64) — deterministic across launches, which
/// `SystemRandomNumberGenerator` and `hashValue` are not. Promoted out of
/// FeatureExplore's route naming so every daily-stable draw in the app
/// (route names, zone selection, mint rolls) runs on the same generator
/// and tests can replay any of them from a seed.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Two draws folded into a deterministic UUID — stable zone ids, mint
    /// ids, anything that must replay from a seed.
    public mutating func nextUUID() -> UUID {
        let hi = next()
        let lo = next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: hi >> 56), UInt8(truncatingIfNeeded: hi >> 48),
            UInt8(truncatingIfNeeded: hi >> 40), UInt8(truncatingIfNeeded: hi >> 32),
            UInt8(truncatingIfNeeded: hi >> 24), UInt8(truncatingIfNeeded: hi >> 16),
            UInt8(truncatingIfNeeded: hi >> 8), UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56), UInt8(truncatingIfNeeded: lo >> 48),
            UInt8(truncatingIfNeeded: lo >> 40), UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24), UInt8(truncatingIfNeeded: lo >> 16),
            UInt8(truncatingIfNeeded: lo >> 8), UInt8(truncatingIfNeeded: lo)))
    }
}

/// Stable daily seeds from (day, ~geo cell): the same all day while you
/// stand in one area, fresh tomorrow. `salt` separates independent draws
/// (route names vs zone picks vs mint rolls) so they never correlate.
/// `day` is injected — callers own "today", tests own determinism.
public enum StableSeed {
    public static func daily(day: Int, lat: Double, lng: Double,
                             cellDeg: Double = 0.005,
                             salt: UInt64 = 0) -> UInt64 {
        let cellLat = Int((lat / cellDeg).rounded())
        let cellLng = Int((lng / cellDeg).rounded())
        let base = UInt64(bitPattern:
            Int64(day) &* 1_000_003 &+ Int64(cellLat) &* 8_191 &+ Int64(cellLng))
        return base ^ salt
    }
}
