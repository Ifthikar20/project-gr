import CoreModels
import SwiftUI

/// "Daybreak Pulse" (docs/03): the entire app uses EXACTLY three colors —
/// snow surfaces, ink text, and one ember-red accent — Airbnb-style
/// (one brand color reserved for what matters, neutrals everywhere else).
/// Opacity/tint steps of a hue count as the same color. Nothing else.
public enum DS {
    public enum Colors {
        // 1 — Snow: surfaces
        public static let snow = Color(red: 0.980, green: 0.980, blue: 0.973)   // #FAFAF8 bg
        public static let snowCard = Color.white                                 // cards

        // 2 — Ink: text, icons, dark elements
        public static let ink = Color(red: 0.086, green: 0.094, blue: 0.114)    // #16181D
        public static let inkSecondary = ink.opacity(0.55)
        public static let hairline = ink.opacity(0.12)

        // 3 — Pulse: THE accent (CTAs, gems, streaks, live stats, own rows).
        // Ember red — deliberately red-shifted off #FC4C02, which is
        // Strava's exact brand orange.
        public static let pulse = Color(red: 0.937, green: 0.231, blue: 0.137)  // #EF3B23

        /// Rarity is a pulse ramp — never a new hue (docs/03 restyle).
        public static func rarity(_ rarity: Rarity) -> Color {
            pulse.opacity(rarityStep(rarity))
        }

        public static func rarityStep(_ rarity: Rarity) -> Double {
            switch rarity {
            case .common: 0.30
            case .uncommon: 0.50
            case .rare: 0.70
            case .epic: 0.88
            case .legendary: 1.0
            }
        }
    }

    /// Rarity is double-encoded (docs/03): pulse step + a distinct glyph, so
    /// tiers stay scannable in grayscale and for color-blind runners.
    public static func rarityGlyph(_ rarity: Rarity) -> String {
        switch rarity {
        case .common: "diamond"
        case .uncommon: "diamond.fill"
        case .rare: "rhombus.fill"
        case .epic: "seal.fill"
        case .legendary: "crown.fill"
        }
    }
}
