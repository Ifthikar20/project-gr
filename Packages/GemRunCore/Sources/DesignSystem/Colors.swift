import CoreModels
import SwiftUI

/// "Night Expedition" palette (docs/03). Rarity colors are the ONLY saturated
/// hues in the app — everything else stays dark and neutral.
public enum DS {
    public enum Colors {
        // Surfaces
        public static let ink = Color(red: 0.06, green: 0.08, blue: 0.13)          // deep navy background
        public static let inkRaised = Color(red: 0.10, green: 0.12, blue: 0.18)    // cards
        public static let parchment = Color(red: 0.91, green: 0.86, blue: 0.74)    // accent texture tint
        public static let gold = Color(red: 0.95, green: 0.76, blue: 0.29)         // routes, CTAs, tab tint
        public static let textPrimary = Color.white.opacity(0.92)
        public static let textSecondary = Color.white.opacity(0.55)

        // Rarity (docs/02)
        public static func rarity(_ rarity: Rarity) -> Color {
            switch rarity {
            case .common: Color(white: 0.92)                                 // Quartz
            case .uncommon: Color(red: 0.22, green: 0.78, blue: 0.45)        // Emerald
            case .rare: Color(red: 0.25, green: 0.53, blue: 0.96)            // Sapphire
            case .epic: Color(red: 0.64, green: 0.36, blue: 0.94)            // Amethyst
            case .legendary: Color(red: 0.98, green: 0.62, blue: 0.18)       // Ember
            }
        }
    }
}
