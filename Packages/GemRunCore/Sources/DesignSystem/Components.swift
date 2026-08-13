import CoreModels
import SwiftUI

// Card grammar (docs/03, Paper & Volt): white surfaces on the website's
// bevel-soft recipe — 20pt corners, hairline border, one diffuse
// low-hanging shadow, pill CTAs.

public extension View {
    /// The standard card: the website's card, in Swift — white, 20pt
    /// continuous corners, hairline border, soft pop shadow.
    func airbnbCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(DS.Colors.snowCard,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(DS.Colors.hairline, lineWidth: 1))
            .shadow(color: DS.Colors.ink.opacity(0.08), radius: 15, y: 8)
    }

    /// Pin-drop entrance: the view falls onto the map with a spring bounce.
    /// Used for waypoints, destination pins, and gem drops (docs/03 motion).
    func pinDrop(delay: Double = 0) -> some View {
        modifier(PinDropEffect(delay: delay))
    }
}

public struct PinDropEffect: ViewModifier {
    @State private var dropped = false
    let delay: Double

    public init(delay: Double = 0) {
        self.delay = delay
    }

    public func body(content: Content) -> some View {
        content
            .offset(y: dropped ? 0 : -28)
            .scaleEffect(dropped ? 1 : 1.25, anchor: .bottom)
            .opacity(dropped ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)
                    .delay(delay)) { dropped = true }
            }
    }
}

/// Primary pill CTA — the one place pulse is guaranteed to appear on a screen.
public struct PillButton: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.snowCard)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(DS.Colors.pulse, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Selectable chip (Compete route picker, gem tray).
public struct Chip: View {
    let title: String
    let systemImage: String?
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, selected: Bool,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(selected ? DS.Colors.snowCard : DS.Colors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(selected ? DS.Colors.pulse : DS.Colors.snowCard, in: Capsule())
            .overlay(Capsule().stroke(selected ? .clear : DS.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Rarity glyph in its pulse step — the atomic rarity indicator.
public struct RarityBadge: View {
    let rarity: Rarity
    let size: CGFloat

    public init(_ rarity: Rarity, size: CGFloat = 14) {
        self.rarity = rarity
        self.size = size
    }

    public var body: some View {
        Image(systemName: DS.rarityGlyph(rarity))
            .font(.system(size: size))
            .foregroundStyle(DS.Colors.rarity(rarity))
    }
}

/// Rarity summary row used on route cards and manifests.
public struct RarityDots: View {
    let counts: [Rarity: Int]

    public init(counts: [Rarity: Int]) {
        self.counts = counts
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(Rarity.allCases, id: \.self) { rarity in
                if let count = counts[rarity], count > 0 {
                    HStack(spacing: 3) {
                        RarityBadge(rarity, size: 11)
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.inkSecondary)
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
                .fill(DS.Colors.pulse.opacity(0.12))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(DS.Colors.pulse, lineWidth: 2)
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

/// Placeholder for empty states.
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
            DS.Colors.snow.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.pulse)
                Text(title)
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}
