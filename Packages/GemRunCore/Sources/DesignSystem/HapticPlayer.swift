import CoreHaptics
import CoreModels
import UIKit

/// Plays the GemHaptics pulse vocabulary through CoreHaptics, with a UIKit
/// generator fallback for devices without a haptic engine (docs/03).
@MainActor
public final class HapticPlayer {
    public static let shared = HapticPlayer()
    private var engine: CHHapticEngine?

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        try? engine?.start()
    }

    public func play(_ pulses: [GemHaptics.Pulse]) {
        guard let engine else {
            fallback(pulses)
            return
        }
        let events = pulses.map { pulse in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity,
                                       value: Float(pulse.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
            ], relativeTime: pulse.delay)
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: 0)
        } catch {
            fallback(pulses)
        }
    }

    public func collection(for rarity: Rarity) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        play(GemHaptics.collectionPattern(for: rarity))
    }

    private func fallback(_ pulses: [GemHaptics.Pulse]) {
        for pulse in pulses {
            DispatchQueue.main.asyncAfter(deadline: .now() + pulse.delay) {
                UIImpactFeedbackGenerator(style: .heavy)
                    .impactOccurred(intensity: pulse.intensity)
            }
        }
    }
}
