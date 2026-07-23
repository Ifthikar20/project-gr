import SwiftUI

public extension DS {
    /// SF Pro Rounded for display numbers/headings; system text elsewhere (docs/03).
    enum Typography {
        public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        public static let statLarge = display(40)
        public static let statMedium = display(24)
        public static let heading = display(20, weight: .semibold)
    }
}
