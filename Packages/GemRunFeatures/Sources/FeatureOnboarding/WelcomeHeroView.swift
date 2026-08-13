import DesignSystem
import SwiftUI

/// The app's landing moment (docs/03 §1): the RunnerCard wordmark centered
/// on paper while real runner photos float scattered around it — springing
/// outward from the center as the screen arrives, then drifting gently.
/// The Mobbin-hero grammar (many tiles orbiting bold centered type), worn
/// in Paper & Volt with photos instead of icons.
struct WelcomeHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hand-tuned slots in unit space, ringing the center the way the
    /// reference scatters its icons: corners and edges busy, middle clear.
    private static let tiles: [(name: String, x: CGFloat, y: CGFloat, size: CGFloat)] = [
        ("run-1", 0.17, 0.10, 92),
        ("run-2", 0.56, 0.05, 70),
        ("run-3", 0.88, 0.13, 84),
        ("run-4", 0.08, 0.34, 66),
        ("run-5", 0.93, 0.37, 96),
        ("run-6", 0.10, 0.74, 88),
        ("run-7", 0.88, 0.72, 76),
        ("run-8", 0.28, 0.90, 78),
        ("run-9", 0.70, 0.91, 94),
    ]

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.46)
            ZStack {
                DS.Colors.snow.ignoresSafeArea()
                ForEach(Array(Self.tiles.enumerated()), id: \.offset) { index, tile in
                    FloatingPhotoTile(
                        name: tile.name,
                        size: tile.size,
                        slot: CGPoint(x: geo.size.width * tile.x,
                                      y: geo.size.height * tile.y),
                        center: center,
                        delay: 0.15 + Double(index) * 0.045,
                        bobSeconds: 2.8 + Double(index % 5) * 0.35,
                        reduceMotion: reduceMotion)
                }
                centerCopy
                    .position(center)
            }
        }
    }

    private var centerCopy: some View {
        VStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .shadow(color: DS.Colors.ink.opacity(0.18), radius: 10, y: 5)
            Text("RunnerCard")
                .font(DS.Typography.display(40))
                .foregroundStyle(DS.Colors.ink)
            Text("Walk the zone. Mint the card.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.inkSecondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(DS.Colors.map)
                    .frame(width: 7, height: 7)
                Text("Swipe to start")
                    .font(.caption.bold())
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DS.Colors.snowCard, in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
            .padding(.top, 6)
        }
    }
}

/// One floating photo: the site's card recipe at tile scale (continuous
/// corners, hairline, soft shadow). Owns its own choreography — expand
/// from the center on a staggered spring, then bob forever, slightly out
/// of phase with its neighbors. Reduced motion renders it seated and
/// still.
private struct FloatingPhotoTile: View {
    let name: String
    let size: CGFloat
    let slot: CGPoint
    let center: CGPoint
    let delay: Double
    let bobSeconds: Double
    let reduceMotion: Bool

    @State private var placed = false
    @State private var bobbing = false

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24,
                                        style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24,
                                      style: .continuous)
                .stroke(DS.Colors.hairline, lineWidth: 1))
            .shadow(color: DS.Colors.ink.opacity(0.12), radius: 10, y: 5)
            .scaleEffect(placed ? 1 : 0.45)
            .opacity(placed ? 1 : 0)
            .position(placed ? slot : center)
            .offset(y: bobbing ? -6 : 0)
            .onAppear {
                guard !reduceMotion else {
                    placed = true
                    return
                }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)
                    .delay(delay)) {
                    placed = true
                }
                withAnimation(.easeInOut(duration: bobSeconds)
                    .repeatForever(autoreverses: true)
                    .delay(delay + 0.7)) {
                    bobbing = true
                }
            }
    }
}
