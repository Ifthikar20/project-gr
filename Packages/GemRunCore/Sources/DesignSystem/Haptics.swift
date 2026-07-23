import CoreModels
import Foundation

/// Haptic vocabulary (docs/03) — patterns defined as data here; CoreHaptics
/// playback is wired in Phase D with the Active Run screen.
public enum GemHaptics {
    public struct Pulse: Sendable {
        public let intensity: Double  // 0…1
        public let delay: TimeInterval

        public init(intensity: Double, delay: TimeInterval) {
            self.intensity = intensity
            self.delay = delay
        }
    }

    /// Collection pattern scales with rarity: Common = single thump,
    /// Legendary = escalating triple burst.
    public static func collectionPattern(for rarity: Rarity) -> [Pulse] {
        switch rarity {
        case .common: [Pulse(intensity: 0.6, delay: 0)]
        case .uncommon: [Pulse(intensity: 0.8, delay: 0)]
        case .rare: [Pulse(intensity: 0.8, delay: 0), Pulse(intensity: 1.0, delay: 0.15)]
        case .epic: [Pulse(intensity: 0.7, delay: 0), Pulse(intensity: 0.9, delay: 0.15),
                     Pulse(intensity: 1.0, delay: 0.3)]
        case .legendary: [Pulse(intensity: 0.6, delay: 0), Pulse(intensity: 0.8, delay: 0.2),
                          Pulse(intensity: 1.0, delay: 0.4)]
        }
    }

    /// Editor placement tick / streak-saved double-knock.
    public static let placementTick = [Pulse(intensity: 0.4, delay: 0)]
    public static let streakSaved = [Pulse(intensity: 0.7, delay: 0), Pulse(intensity: 0.7, delay: 0.25)]
}
