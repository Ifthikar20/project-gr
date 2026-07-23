import DesignSystem
import SwiftUI

/// The 3-step creation flow: draw → place gems → publish (docs/03 §4–6).
/// Phase A stub; built for real in Phase E (E1) on the Mapbox provider.
public struct RouteCreationFlow: View {
    public init() {}

    public var body: some View {
        PlaceholderScreen(
            title: "Create a route",
            subtitle: "Tap to draw. Drop gems. Publish. (Phase E)",
            systemImage: "pencil.and.outline"
        )
    }
}
