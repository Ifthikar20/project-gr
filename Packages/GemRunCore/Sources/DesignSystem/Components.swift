import CoreModels
import SwiftUI

/// Rarity-colored dot row used on route cards and manifests (docs/03).
public struct RarityDots: View {
    let counts: [Rarity: Int]

    public init(counts: [Rarity: Int]) {
        self.counts = counts
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Rarity.allCases, id: \.self) { rarity in
                if let count = counts[rarity], count > 0 {
                    HStack(spacing: 2) {
                        Circle().fill(DS.Colors.rarity(rarity)).frame(width: 8, height: 8)
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
        }
    }
}

/// Placeholder used by stub screens during Phases A–B.
public struct PlaceholderScreen: View {
    let title: String
    let subtitle: String
    let systemImage: String

    public init(title: String, subtitle: String, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    public var body: some View {
        ZStack {
            DS.Colors.ink.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.gold)
                Text(title)
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}
