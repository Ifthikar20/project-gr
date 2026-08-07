import CoreModels
import SwiftUI

/// "Daybreak Pulse" (docs/03): the app maintains EXACTLY two accents over
/// snow-and-ink neutrals — the same pair as the landing page. Map green
/// belongs to map & game graphics (routes, gems, pins); pulse violet is
/// the chrome accent (CTAs, streaks, live stats, own rows). Text stays
/// ink — never a hue. Opacity/tint steps of a hue count as the same
/// color. Nothing else.
public enum DS {
    public enum Colors {
        // 1 — Snow: surfaces
        public static let snow = Color(red: 0.980, green: 0.980, blue: 0.973)   // #FAFAF8 bg
        public static let snowCard = Color.white                                 // cards

        // 2 — Ink: text, icons, dark elements
        public static let ink = Color(red: 0.086, green: 0.094, blue: 0.114)    // #16181D
        public static let inkSecondary = ink.opacity(0.55)
        public static let hairline = ink.opacity(0.12)

        // 3 — Pulse: the chrome accent (CTAs, streaks, live stats, own rows).
        public static let pulse = Color(red: 0.373, green: 0.251, blue: 0.749)  // #5F40BF

        // 4 — Map: map & game graphics — the landing page's --map token.
        // Too bright to carry white: glyphs/text ON it use onMap (ink).
        public static let map = Color(red: 0.380, green: 1.0, blue: 0.0)        // #61FF00
        public static let onMap = ink

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
