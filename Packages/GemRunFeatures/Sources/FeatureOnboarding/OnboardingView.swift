import AuthenticationServices
import CoreLocation
import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// Value prop → location priming → identity, under 60 seconds (docs/03 §1).
/// Identity offers Sign in with Apple, Google, or guest. While
/// `AuthFlags.allowAllAccounts` is on (TEMPORARY), every path succeeds —
/// including provider failures — so any account works during development.
public struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @State private var page = 0
    @State private var handle = ""
    @State private var authError: String?

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
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(DS.Colors.gold)
            Text("Who's hunting?")
                .font(DS.Typography.display(28))
                .foregroundStyle(DS.Colors.textPrimary)
            TextField("handle (optional)", text: $handle)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: 220)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName]
            } onCompletion: { result in
                handleAppleResult(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(width: 260, height: 46)
            .clipShape(Capsule())

            Button {
                continueWithGoogle()
            } label: {
                Label("Continue with Google", systemImage: "g.circle.fill")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                    .frame(width: 260, height: 46)
                    .background(.white, in: Capsule())
            }

            Button("Continue as guest") {
                session.signIn(provider: .guest, handle: handle, externalID: nil)
            }
            .font(.footnote)
            .foregroundStyle(DS.Colors.textSecondary)

            if let authError {
                Text(authError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if AuthFlags.allowAllAccounts {
                Text("Dev mode: all accounts are temporarily accepted.")
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                fallthroughIfAllowed(provider: .apple, message: "Apple sign-in returned no credential.")
                return
            }
            let name = handle.isEmpty
                ? (credential.fullName?.givenName ?? "runner") : handle
            // Django later verifies credential.identityToken server-side
            // (docs/06); with the dev flag on, the local identity is enough.
            session.signIn(provider: .apple, handle: name, externalID: credential.user)
        case .failure:
            // Simulator without an Apple ID, or the user cancelled.
            fallthroughIfAllowed(provider: .apple,
                                 message: "Apple sign-in didn't complete.")
        }
    }

    private func continueWithGoogle() {
        #if canImport(GoogleSignIn)
        // Real flow once the GoogleSignIn-iOS SPM package + OAuth client ID
        // (GIDClientID in Info.plist + reversed-ID URL scheme) are added:
        // GIDSignIn.sharedInstance.signIn(withPresenting:) → profile + idToken,
        // which Django verifies server-side.
        authError = "Google SDK present — wire GIDSignIn here."
        #else
        fallthroughIfAllowed(provider: .google,
                             message: "Google Sign-In needs the GoogleSignIn SDK and an OAuth client ID.")
        #endif
    }

    private func fallthroughIfAllowed(provider: AuthProvider, message: String) {
        if AuthFlags.allowAllAccounts {
            session.signIn(provider: provider, handle: handle, externalID: nil)
        } else {
            authError = message
        }
    }
}
