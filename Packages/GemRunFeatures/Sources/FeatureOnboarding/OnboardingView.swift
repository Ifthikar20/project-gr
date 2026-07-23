import CoreLocation
import CorePersistence
import DesignSystem
import SwiftUI

/// Value prop → location priming → identity, under 60 seconds (docs/03 §1).
/// Sign in with Apple replaces the handle field in Phase F; local profile now.
public struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @State private var page = 0
    @State private var handle = ""

    public init() {}

    private static let pages: [(icon: String, title: String, text: String)] = [
        ("map.fill", "Routes are treasure maps",
         "Every route near you has gems hidden along it — some in plain sight, some you'll have to find."),
        ("figure.run", "Run to collect",
         "Pass within 25 meters of a gem and it's yours. Your phone buzzes; you never break stride."),
        ("diamond.fill", "Leave something behind",
         "Draw your own routes and place gems for the next runner. Rare ones belong on the hard hills."),
    ]

    public var body: some View {
        ZStack {
            DS.Colors.ink.ignoresSafeArea()
            VStack(spacing: 24) {
                TabView(selection: $page) {
                    ForEach(0..<Self.pages.count, id: \.self) { i in
                        pageView(Self.pages[i]).tag(i)
                    }
                    locationPriming.tag(Self.pages.count)
                    identity.tag(Self.pages.count + 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .preferredColorScheme(.dark)
    }

    private func pageView(_ p: (icon: String, title: String, text: String)) -> some View {
        VStack(spacing: 20) {
            Image(systemName: p.icon)
                .font(.system(size: 64))
                .foregroundStyle(DS.Colors.gold)
            Text(p.title)
                .font(DS.Typography.display(28))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(p.text)
                .font(.body)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Next") { withAnimation { page += 1 } }
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.gold)
        }
    }

    /// Explain before the system dialog (docs/03): honest, specific, once.
    private var locationPriming: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.fill")
                .font(.system(size: 64))
                .foregroundStyle(DS.Colors.gold)
            Text("One thing first")
                .font(DS.Typography.display(28))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("GemRun uses your location during runs to confirm you passed each gem. While-using only — we never track you outside a run.")
                .font(.body)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                CLLocationManager().requestWhenInUseAuthorization()
                withAnimation { page += 1 }
            } label: {
                Text("Enable location")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(DS.Colors.gold, in: Capsule())
            }
            Button("Not now") { withAnimation { page += 1 } }
                .font(.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var identity: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(DS.Colors.gold)
            Text("Pick a handle")
                .font(DS.Typography.display(28))
                .foregroundStyle(DS.Colors.textPrimary)
            TextField("runner", text: $handle)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: 220)
            Button {
                session.createProfile(handle: handle)
                session.isOnboarded = true
            } label: {
                Text("Start hunting")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(DS.Colors.gold, in: Capsule())
            }
        }
    }
}
