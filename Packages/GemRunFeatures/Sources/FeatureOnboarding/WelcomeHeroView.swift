import CoreModels
import DesignSystem
import SwiftUI

/// What a hero slot holds: a runner photo, or a Runner Card back tilted
/// the way the landing page fans its cards.
private enum HeroFace {
    case photo(String)
    case card(Rarity, tilt: Double)
}

/// The app's landing moment (docs/03 §1): the RunnerCard wordmark centered
/// on paper while runner photos and card backs float packed close around
/// it — springing outward from the center as the screen arrives, then
/// drifting gently. The Mobbin-hero grammar (many tiles orbiting bold
/// centered type), worn in Paper & Volt with photos and cards instead of
/// icons.
struct WelcomeHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hand-tuned slots in unit space, ringing the center tightly — photos
    /// and cards packed close together, only the middle held clear for the
    /// wordmark.
    private static let tiles: [(face: HeroFace, x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (.photo("run-1"), 0.20, 0.12, 86),
        (.card(.legendary, tilt: -8), 0.48, 0.07, 54),
        (.photo("run-2"), 0.76, 0.11, 72),
        (.photo("run-3"), 0.10, 0.29, 68),
        (.photo("run-5"), 0.90, 0.31, 88),
        (.card(.epic, tilt: 7), 0.10, 0.52, 50),
        (.photo("run-4"), 0.90, 0.54, 64),
        (.photo("run-6"), 0.17, 0.72, 82),
        (.card(.rare, tilt: -6), 0.84, 0.73, 54),
        (.photo("run-8"), 0.32, 0.87, 76),
        (.photo("run-7"), 0.51, 0.82, 62),
        (.photo("run-9"), 0.68, 0.89, 86),
    ]

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.46)
            ZStack {
                DS.Colors.snow.ignoresSafeArea()
                ForEach(Array(Self.tiles.enumerated()), id: \.offset) { index, tile in
                    FloatingTile(
                        face: tile.face,
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

/// One floating tile: a photo in the site's card recipe (continuous
/// corners, hairline, soft shadow) or a MiniCardBack at its slot's tilt.
/// Owns its own choreography — expand from the center on a staggered
/// spring, then bob forever, slightly out of phase with its neighbors.
/// Reduced motion renders it seated and still.
@MainActor
private struct FloatingTile: View {
    let face: HeroFace
    let size: CGFloat
    let slot: CGPoint
    let center: CGPoint
    let delay: Double
    let bobSeconds: Double
    let reduceMotion: Bool

    @State private var placed = false
    @State private var bobbing = false

    var body: some View {
        faceView
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

    @ViewBuilder
    private var faceView: some View {
        switch face {
        case .photo(let name):
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
        case .card(let rarity, let tilt):
            MiniCardBack(rarity: rarity, size: size)
                .rotationEffect(.degrees(tilt))
        }
    }
}
