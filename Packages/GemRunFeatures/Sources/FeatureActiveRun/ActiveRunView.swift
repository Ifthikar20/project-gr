import DesignSystem
import SwiftUI

/// The in-run screen: chase camera, stats band, next-gem chip, slide-to-stop
/// (docs/03 §7). Phase A stub; built in Phase D on ActiveRunEngine.
public struct ActiveRunView: View {
    public init() {}

    public var body: some View {
        PlaceholderScreen(
            title: "Active Run",
            subtitle: "Chase camera, live pace, and gem collection land in Phase D.",
            systemImage: "figure.run"
        )
    }
}
