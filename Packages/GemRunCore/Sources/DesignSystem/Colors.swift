import CoreModels
import SwiftUI

/// Paper & Volt (docs/03, restyled with the RunnerCard pivot): one green
/// in two strengths over paper-and-ink neutrals — the landing page's
/// system, verbatim. Volt (map) belongs to map & game graphics (zones,
/// routes, pins); volt-deep (pulse) is the chrome accent (CTAs, streaks,
/// live stats) because raw volt can't carry text on white. Rarity speaks
/// the card edge colors. Text stays ink — never a hue. Opacity/tint steps
/// of a hue count as the same color. Nothing else.
public enum DS {
    public enum Colors {
        // 1 — Paper: surfaces (the landing page's --bg; name kept for the
        // ~everywhere call sites).
        public static let snow = Color(red: 0.965, green: 0.973, blue: 0.984)   // #F6F8FB bg
        public static let snowCard = Color.white                                 // cards

        // 2 — Ink: text, icons, dark elements (landing --ink).
        public static let ink = Color(red: 0.063, green: 0.071, blue: 0.086)    // #101216
        public static let inkSecondary = ink.opacity(0.55)
        public static let hairline = ink.opacity(0.12)

        // 3 — Volt deep: the chrome accent (CTAs, streaks, live stats) —
        // the landing page's --volt-deep, dark enough to carry text and
        // glyphs on white. Token name kept from the pulse era.
        public static let pulse = Color(red: 0.173, green: 0.561, blue: 0.0)    // #2C8F00

        // 4 — Volt: map & game graphics — the landing page's --volt token.
        // Too bright to carry white: glyphs/text ON it use onMap (ink).
        public static let map = Color(red: 0.380, green: 1.0, blue: 0.0)        // #61FF00
        public static let onMap = ink

        // 5 — Route ink: walking/running paths on LIGHT map surfaces
        // (card heroes, previews, share exports) — deep violet, strong on
        // paper where volt washes out. Volt owns the dark live maps.
        // Mirrored as MapPalette.routeInk (CoreMap can't import us).
        public static let routeInk = Color(red: 0.271, green: 0.153, blue: 0.627) // #4527A0

        /// Rarity speaks the card system's edge colors (CardPalette) — the
        /// same five hues the landing page prints, on gems and cards alike.
        public static func rarity(_ rarity: Rarity) -> Color {
            CardPalette.edge(rarity)
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
