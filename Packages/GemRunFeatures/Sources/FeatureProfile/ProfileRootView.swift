import DesignSystem
import SwiftUI

/// Identity, streak, and creations (docs/03 §11). Phase A: streak placeholder.
public struct ProfileRootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.ink.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(DS.Colors.gold)
                    Text("0-day streak")
                        .font(DS.Typography.statMedium)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Run at least 1 km today to start one.")
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    ProfileRootView()
}
