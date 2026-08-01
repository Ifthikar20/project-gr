import AuthenticationServices
import CoreAuth
import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI
import UIKit

/// The sign-in / sign-up page: a full-bleed photo of a runner (asset
/// "running-background" — drop `running-background.jpg` at the repo root
/// and run.sh imports it into the build) drifting slowly under an ink
/// scrim, with the identity controls staggering in from below. When no
/// photo has been added yet, a designed ember-gradient fallback keeps the
/// page whole — probed once via UIImage, the same pattern as CoreMap's
/// GemArtProbe. All provider logic lives in CoreAuth's AuthService; every
/// button here does exactly what it says (docs/18) — Google only appears
/// when the build can actually perform it.
@MainActor
struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var handle = ""
    @State private var authError: String?
    @State private var revealed = false

    var body: some View {
        ZStack {
            RunningBackdrop()
            scrim
            content
        }
        .onAppear { revealed = true }
    }

    private var auth: AuthService { AuthService(session: session) }

    /// Ink gradient over the photo so snow text stays legible at any
    /// exposure — light at the top, deep where the controls sit.
    private var scrim: some View {
        LinearGradient(
            colors: [DS.Colors.ink.opacity(0.05),
                     DS.Colors.ink.opacity(0.45),
                     DS.Colors.ink.opacity(0.82)],
            startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DS.Colors.pulse)
                    .shadow(color: DS.Colors.ink.opacity(0.4), radius: 8, y: 2)
                Text("GemRun")
                    .font(DS.Typography.display(38))
                    .foregroundStyle(DS.Colors.snowCard)
                Text("Run. Hunt. Keep what you find.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.snowCard.opacity(0.85))
            }
            .entrance(revealed, delay: 0.1)
            .padding(.bottom, 10)

            VStack(spacing: 12) {
                TextField("", text: $handle,
                          prompt: Text("handle (optional)")
                              .foregroundStyle(DS.Colors.snowCard.opacity(0.6)))
                    .foregroundStyle(DS.Colors.snowCard)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 20)
                    .frame(width: 280, height: 48)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(DS.Colors.snowCard.opacity(0.25),
                                              lineWidth: 1))

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    report(auth.signIn(apple: result, preferredHandle: handle))
                }
                .signInWithAppleButtonStyle(.white)
                .frame(width: 280, height: 48)
                .clipShape(Capsule())
                .shadow(color: DS.Colors.ink.opacity(0.3), radius: 8, y: 3)

                if AuthService.isGoogleSignInAvailable {
                    GhostButton("Continue with Google", icon: "g.circle.fill",
                                fullWidth: false) {
                        report(auth.signInWithGoogle(preferredHandle: handle))
                    }
                    .frame(width: 280)
                }
            }
            .entrance(revealed, delay: 0.22)

            VStack(spacing: 8) {
                Button("Continue as guest") {
                    report(auth.signInAsGuest(handle: handle))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.snowCard.opacity(0.85))

                if let authError {
                    Text(authError)
                        .font(.caption)
                        .foregroundStyle(DS.Colors.snowCard)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(DS.Colors.pulse.opacity(0.85), in: Capsule())
                        .padding(.horizontal, 24)
                }
                if AuthFlags.allowAllAccounts {
                    Text("Dev mode: all accounts are temporarily accepted.")
                        .font(.caption2)
                        .foregroundStyle(DS.Colors.snowCard.opacity(0.6))
                }
            }
            .entrance(revealed, delay: 0.34)

            // The paged TabView is full-bleed now, so this margin measures
            // from the physical screen edge: clear the home indicator AND
            // the page dots that overlay the bottom of the screen.
            Spacer().frame(height: 56)
        }
    }

    private func report(_ outcome: AuthService.Outcome) {
        switch outcome {
        case .success, .cancelled:
            break   // success dismisses onboarding; cancel was a choice
        case .failure(let message):
            withAnimation { authError = message }
        }
    }
}

// MARK: - Backdrop

/// Full-bleed runner photo with a slow Ken Burns drift; ember-gradient
/// fallback (with a ghosted runner glyph) until the photo lands in the
/// asset catalog.
private struct RunningBackdrop: View {
    @State private var drift = false
    /// Probed once — UIImage re-searches the bundle on every miss.
    private static let photo = UIImage(named: "running-background")

    var body: some View {
        GeometryReader { geo in
            if let photo = Self.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(drift ? 1.08 : 1.0)
                    .clipped()
            } else {
                LinearGradient(colors: [DS.Colors.ink,
                                        DS.Colors.pulse.opacity(0.75)],
                               startPoint: .top,
                               endPoint: drift ? .bottomTrailing : .bottom)
                    .overlay(
                        Image(systemName: "figure.run")
                            .font(.system(size: 240, weight: .bold))
                            .foregroundStyle(DS.Colors.snowCard.opacity(0.08))
                            .offset(x: 40, y: -60)
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

// MARK: - Staggered entrance

private struct Entrance: ViewModifier {
    let revealed: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 36)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(delay),
                       value: revealed)
    }
}

private extension View {
    func entrance(_ revealed: Bool, delay: Double) -> some View {
        modifier(Entrance(revealed: revealed, delay: delay))
    }
}
