import CoreModels
import SwiftUI

/// The mint ceremony — the gem collection choreography from the run
/// screen, transplanted and re-skinned for cards: a burst at map center,
/// a tiny card back flying to the top-left binder chip (the same
/// CGPoint(52, 30) the gem flight lands on), and a "+1" float. The gem
/// original stays in place for flag-off runs; this is the card twin, not
/// a refactor of that screen.
///
/// Self-driving: overlay it when a card mints; `onLanded` fires as the
/// card reaches the chip (hosts bounce their chip there), `onFinished`
/// when the whole ceremony is over (hosts clear state / present the
/// reveal). Identical timings to the gem version: 0.35 s launch, 0.6 s
/// flight, 0.9 s float.
@MainActor
public struct MintCeremonyOverlay: View {
    let card: RunnerCard
    let onLanded: (() -> Void)?
    let onFinished: () -> Void

    @State private var burstVisible = true
    @State private var flightVisible = false
    @State private var flightLanded = false
    @State private var floatVisible = false
    @State private var floatRisen = false

    public init(card: RunnerCard, onLanded: (() -> Void)? = nil,
                onFinished: @escaping () -> Void) {
        self.card = card
        self.onLanded = onLanded
        self.onFinished = onFinished
    }

    public var body: some View {
        ZStack {
            if burstVisible {
                MintBurst(rarity: card.rarity)
            }
            GeometryReader { geo in
                if flightVisible {
                    MiniCardBack(rarity: card.rarity)
                        .position(flightLanded
                            ? CGPoint(x: 52, y: 30)
                            : CGPoint(x: geo.size.width / 2,
                                      y: geo.size.height * 0.42))
                        .scaleEffect(flightLanded ? 0.3 : 1.1)
                        .opacity(flightLanded ? 0.2 : 1)
                }
            }
            if floatVisible {
                HStack(spacing: 3) {
                    Image(systemName: "rectangle.portrait.fill")
                        .font(.caption2.bold())
                    Text("+1")
                        .font(.caption.bold())
                        .monospacedDigit()
                }
                .foregroundStyle(CardPalette.edge(card.rarity))
                .shadow(color: DS.Colors.snowCard, radius: 3)
                .offset(y: floatRisen ? -24 : 0)
                .opacity(floatRisen ? 0 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
                .padding(.top, 18)
                .padding(.leading, 96)
            }
        }
        .allowsHitTesting(false)
        .onAppear { run() }
    }

    private func run() {
        HapticPlayer.shared.collection(for: card.rarity)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            flightVisible = true
            withAnimation(.easeIn(duration: 0.6)) { flightLanded = true }
            try? await Task.sleep(for: .seconds(0.6))
            flightVisible = false
            onLanded?()
            floatVisible = true
            withAnimation(.easeOut(duration: 0.9)) { floatRisen = true }
            try? await Task.sleep(for: .seconds(0.55))
            burstVisible = false
            try? await Task.sleep(for: .seconds(0.35))
            floatVisible = false
            onFinished()
        }
    }
}

/// Ring + card glyph at map center — the CollectionBurst recipe with the
/// card's rarity edge instead of the gem ramp.
@MainActor
struct MintBurst: View {
    let rarity: Rarity
    @State private var scale = 0.3
    @State private var opacity = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(CardPalette.edge(rarity), lineWidth: 3)
                .scaleEffect(scale * 2.2)
                .opacity(opacity * 0.5)
            Image(systemName: "rectangle.portrait.fill")
                .font(.system(size: 72))
                .foregroundStyle(CardPalette.edge(rarity))
                .scaleEffect(scale)
                .opacity(opacity)
                .shadow(color: DS.Colors.snowCard, radius: 8)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.4)) { scale = 1.0 }
            withAnimation(.easeOut(duration: 1.2).delay(0.3)) { opacity = 0 }
        }
        .allowsHitTesting(false)
    }
}
