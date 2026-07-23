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

/// Elevation profile sparkline with gem position ticks (docs/03 §3).
public struct ElevationStrip: View {
    let profile: [Int]
    /// (fraction along route 0…1, rarity) for tick marks.
    let markers: [(Double, Rarity)]

    public init(profile: [Int], markers: [(Double, Rarity)]) {
        self.profile = profile
        self.markers = markers
    }

    public var body: some View {
        GeometryReader { geo in
            let maxEl = Double(max(profile.max() ?? 1, 1))
            let points = profile.enumerated().map { i, el in
                CGPoint(x: geo.size.width * Double(i) / Double(max(profile.count - 1, 1)),
                        y: geo.size.height * (1 - 0.85 * Double(el) / maxEl))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                }
                .fill(DS.Colors.gold.opacity(0.15))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(DS.Colors.gold, lineWidth: 2)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    Circle()
                        .fill(DS.Colors.rarity(marker.1))
                        .frame(width: 7, height: 7)
                        .position(x: geo.size.width * marker.0, y: geo.size.height - 5)
                }
            }
        }
        .frame(height: 56)
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
