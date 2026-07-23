import SwiftUI

public extension DS {
    /// SF Pro Rounded, Airbnb-calibrated (docs/03): display at medium weights
    /// — cards carry the visual weight, not heavy type. Stats stay bold.
    enum Typography {
        public static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        public static let statLarge = display(40, weight: .bold)
        public static let statMedium = display(24, weight: .bold)
        public static let heading = display(20)
    }
}
