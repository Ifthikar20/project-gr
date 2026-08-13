import CoreLocation
import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// Value prop → location priming → sign-in, under 60 seconds (docs/03 §1),
/// Daybreak Pulse: snow background, ink display type, pulse CTAs. The final
/// page is the full-bleed SignInView; all provider handling lives in
/// CoreAuth's AuthService (docs/18, the docs/10 real-auth landing zone).
@MainActor
public struct OnboardingView: View {
    @State private var page = 0

    public init() {}

    private static let pages: [(icon: String, title: String, text: String)] = [
        ("map.fill", "Routes are treasure maps",
         "Every route near you has gems hidden along it — some in plain sight, some you'll have to find."),
        ("figure.run", "Run to collect",
         "Pass within 100 feet of a gem and it's yours. Your phone buzzes; you never break stride."),
        ("diamond.fill", "Leave something behind",
         "Draw your own routes and place gems for the next runner. Rare ones belong on the hard hills."),
    ]

    public var body: some View {
        ZStack {
            DS.Colors.snow.ignoresSafeArea()
            // The TabView owns the WHOLE screen: a paged TabView hosts its
            // pages in a container that doesn't pass safe-area regions
            // through, so a page can never reach the edges on its own —
            // extending the TabView itself is what lets the sign-in photo
            // run truly full-bleed under the page dots.
            TabView(selection: $page) {
                ForEach(0..<Self.pages.count, id: \.self) { i in
                    pageView(Self.pages[i]).tag(i)
                }
                locationPriming.tag(Self.pages.count)
                SignInView().tag(Self.pages.count + 1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .ignoresSafeArea()
        }
    }

    private func pageView(_ p: (icon: String, title: String, text: String)) -> some View {
        VStack(spacing: 20) {
            Image(systemName: p.icon)
                .font(.system(size: 64))
                .foregroundStyle(DS.Colors.pulse)
            Text(p.title)
                .font(DS.Typography.display(28))
                .foregroundStyle(DS.Colors.ink)
            Text(p.text)
                .font(.body)
                .foregroundStyle(DS.Colors.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Next") { withAnimation { page += 1 } }
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.pulse)
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
