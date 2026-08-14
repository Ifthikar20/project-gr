import CoreLocation
import CoreModels
import CorePersistence
import DesignSystem
import MapKit
import SwiftUI

/// Value prop → location priming → sign-in, under 60 seconds (docs/03 §1),
/// Paper & Volt: the floating-photos hero first, then three explainer
/// pages that move — pastel scene panels with living emoji, parallax on
/// the swipe — then priming and the full-bleed SignInView. All provider
/// handling lives in CoreAuth's AuthService (docs/18).
@MainActor
public struct OnboardingView: View {
    @State private var page = 0

    public init() {}

    public var body: some View {
        ZStack {
            DS.Colors.snow.ignoresSafeArea()
            // The TabView owns the WHOLE screen: a paged TabView hosts its
            // pages in a container that doesn't pass safe-area regions
            // through, so a page can never reach the edges on its own —
            // extending the TabView itself is what lets the sign-in photo
            // run truly full-bleed under the page dots.
            TabView(selection: $page) {
                // The landing moment: wordmark centered, runner photos and
                // cards expanding out around it — before any explaining.
                WelcomeHeroView().tag(0)
                ExplainerPage.zones.tag(1)
                ExplainerPage.mile.tag(2)
                ExplainerPage.cards.tag(3)
                locationPriming.tag(4)
                SignInView().tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .ignoresSafeArea()
        }
    }

    /// Explain before the system dialog (docs/03): honest, specific, once.
    private var locationPriming: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill")
                .font(.system(size: 64))
                .foregroundStyle(DS.Colors.pulse)
            Text("One thing first")
                .font(DS.Typography.display(28))
                .foregroundStyle(DS.Colors.ink)
            Text("RunnerCard uses your location while the map is open and during runs to measure the distance you cover inside zones — on a run that works even with your phone in your pocket, screen off. Beyond that, we never track you.")
                .font(.body)
                .foregroundStyle(DS.Colors.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            PulseButton("Enable location", fullWidth: false) {
                CLLocationManager().requestWhenInUseAuthorization()
                withAnimation { page += 1 }
            }
            Button("Not now") { withAnimation { page += 1 } }
                .font(.footnote)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }
}

/// One explainer page: an animated scene panel over a pastel wash, then
/// the words. The panel drifts at a different rate than the text while
/// you swipe (parallax), and the emoji inside keep living on their own
/// loops — no more blank pages.
@MainActor
struct ExplainerPage: View {
    let icon: String
    let title: String
    let text: String
    let wash: Color
    let scene: AnyView

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // In a paged TabView each page spans the screen; minX runs
            // 0 → ±width during the swipe. Different offset factors per
            // layer = the parallax.
            let minX = geo.frame(in: .global).minX
            VStack(spacing: 26) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(wash)
                        .overlay(RoundedRectangle(cornerRadius: 30,
                                                  style: .continuous)
                            .stroke(DS.Colors.hairline, lineWidth: 1))
                        .shadow(color: DS.Colors.ink.opacity(0.08),
                                radius: 15, y: 8)
                    scene
                }
                .frame(width: min(geo.size.width - 72, 340), height: 210)
                .offset(x: minX * 0.35)
                VStack(spacing: 12) {
                    Label(title, systemImage: icon)
                        .font(DS.Typography.display(26))
                        .foregroundStyle(DS.Colors.ink)
                        .labelStyle(.titleOnly)
                    Text(text)
                        .font(.body)
                        .foregroundStyle(DS.Colors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                .offset(x: minX * 0.12)
                Spacer()
                Spacer()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(1 - min(abs(minX) / max(geo.size.width, 1), 1) * 0.5)
        }
    }

    // MARK: - The three pages

    static var zones: ExplainerPage {
        ExplainerPage(
            icon: "map.fill",
            title: "Zones appear around you",
            text: "Every day, a few large zones land on parks and trails near you — real public ground with plenty of paths to walk. Never private land.",
            wash: CardPalette.wash(.creature),
            scene: AnyView(ZoneScene()))
    }

    static var mile: ExplainerPage {
        ExplainerPage(
            icon: "figure.walk",
            title: "Walk the mile",
            text: "Cover a mile inside a zone — on the map or mid-run — and a Runner Card mints on the spot. Your phone buzzes; you never break stride.",
            wash: CardPalette.wash(.gear),
            scene: AnyView(MileScene()))
    }

    static var cards: ExplainerPage {
        ExplainerPage(
            icon: "rectangle.portrait.on.rectangle.portrait.fill",
            title: "Collect the cards",
            text: "Gems, gear, creatures, artifacts, facts — five kinds, five rarities, every card stamped with the walk that earned it.",
            wash: CardPalette.wash(.artifact),
            scene: AnyView(CardScene()))
    }
}

// MARK: - The living scenes

/// A volt zone breathing on real ground: a street-map snippet of Echo
/// Park Lake in Los Angeles, clipped in the pulsing ring — the promise
/// made literal, a zone landing on an actual city park. The duck bobs on
/// the lake; the pin floats over the boundary.
private struct ZoneScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    /// Echo Park Lake, Los Angeles — real public ground, the city grid
    /// tight around it.
    private static let echoParkLake = CLLocationCoordinate2D(
        latitude: 34.0723, longitude: -118.2602)

    var body: some View {
        ZStack {
            // Same recipe as the run cards' route map: static, muted,
            // no POI chatter — just streets, park green and the lake.
            Map(initialPosition: .region(MKCoordinateRegion(
                    center: Self.echoParkLake,
                    latitudinalMeters: 950, longitudinalMeters: 950)),
                interactionModes: [])
                .mapStyle(.standard(elevation: .flat,
                                    pointsOfInterest: .excludingAll))
                .allowsHitTesting(false)   // swipes belong to the TabView
                .frame(width: 150, height: 150)
                .clipShape(Circle())
                .overlay(Circle().stroke(DS.Colors.map.opacity(0.55),
                                         lineWidth: 3))
                .scaleEffect(breathe ? 1.04 : 0.96)
            Text("🦆")
                .font(.system(size: 26))
                .offset(x: 26, y: 40)
                .offset(y: breathe ? -3 : 3)
            Text("📍")
                .font(.system(size: 28))
                .offset(y: breathe ? -66 : -60)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4)
                .repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// The runner paces the panel, dust puffing behind, the progress bar
/// filling toward the mile.
private struct MileScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run = false
    @State private var puff = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Text("💨")
                    .font(.system(size: 26))
                    .offset(x: run ? 46 : -114, y: 4)
                    .opacity(puff ? 0.1 : 0.7)
                Text("🏃‍♂️")
                    .font(.system(size: 52))
                    .scaleEffect(x: 1)
                    .offset(x: run ? 84 : -84)
            }
            .frame(height: 70)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.ink.opacity(0.08))
                    .frame(width: 190, height: 10)
                Capsule()
                    .fill(DS.Colors.map)
                    .frame(width: run ? 190 : 16, height: 10)
                Text("1 mile")
                    .font(.caption2.bold())
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .offset(y: 16)
            }
            .frame(width: 190, height: 26)
        }
        .onAppear {
            guard !reduceMotion else {
                run = true
                return
            }
            withAnimation(.easeInOut(duration: 3.2)
                .repeatForever(autoreverses: true)) { run = true }
            withAnimation(.easeInOut(duration: 1.1)
                .repeatForever(autoreverses: true)) { puff = true }
        }
    }
}

/// The finds fan out and bob: a card back tilting between living emoji.
private struct CardScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false
    @State private var tilt = false

    var body: some View {
        ZStack {
            MiniCardBack(rarity: .legendary, size: 74)
                .rotationEffect(.degrees(tilt ? 6 : -6))
            Text("💎")
                .font(.system(size: 34))
                .offset(x: -78, y: bob ? -26 : -18)
            Text("🦊")
                .font(.system(size: 34))
                .offset(x: 80, y: bob ? -10 : -20)
            Text("👟")
                .font(.system(size: 30))
                .offset(x: -66, y: bob ? 42 : 50)
            Text("⚡️")
                .font(.system(size: 28))
                .offset(x: 72, y: bob ? 48 : 40)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2)
                .repeatForever(autoreverses: true)) { bob = true }
            withAnimation(.easeInOut(duration: 2.8)
                .repeatForever(autoreverses: true)) { tilt = true }
        }
    }
}
