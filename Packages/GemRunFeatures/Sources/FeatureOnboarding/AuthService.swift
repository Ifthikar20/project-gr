import AuthenticationServices
import CoreModels
import CorePersistence
import Foundation

/// The auth layer: every provider's credential handling lives HERE, behind
/// one seam — views render outcomes, nothing else. This is deliberately the
/// single file the docs/10 real-auth work will touch later: GIDSignIn goes
/// in `signInWithGoogle`, and forwarding Apple's `identityToken` / Google's
/// `idToken` to Django for server-side verification goes alongside the
/// `session.signIn` calls. Until then, `AuthFlags.allowAllAccounts`
/// (TEMPORARY) keeps every path usable in dev.
@MainActor
struct AuthService {
    let session: SessionStore

    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    /// Sign in with Apple: extract the stable per-team user id from the
    /// credential. Django later verifies `credential.identityToken`
    /// server-side (docs/06); with the dev flag on, the local identity is
    /// enough.
    func signIn(apple result: Result<ASAuthorization, Error>,
                preferredHandle: String) -> Outcome {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                return fallthroughIfAllowed(provider: .apple, handle: preferredHandle,
                                            message: "Apple sign-in returned no credential.")
            }
            let name = preferredHandle.isEmpty
                ? (credential.fullName?.givenName ?? "runner") : preferredHandle
            session.signIn(provider: .apple, handle: name, externalID: credential.user)
            return .success
        case .failure:
            // Simulator without an Apple ID, or the user cancelled.
            return fallthroughIfAllowed(provider: .apple, handle: preferredHandle,
                                        message: "Apple sign-in didn't complete.")
        }
    }

    func signInWithGoogle(preferredHandle: String) -> Outcome {
        #if canImport(GoogleSignIn)
        // Real flow once the GoogleSignIn-iOS SPM package + OAuth client ID
        // (GIDClientID in Info.plist + reversed-ID URL scheme) are added:
        // GIDSignIn.sharedInstance.signIn(withPresenting:) → profile + idToken,
        // which Django verifies server-side.
        return .failure("Google SDK present — wire GIDSignIn here.")
        #else
        return fallthroughIfAllowed(provider: .google, handle: preferredHandle,
                                    message: "Google Sign-In needs the GoogleSignIn SDK and an OAuth client ID.")
        #endif
    }

    func signInAsGuest(handle: String) -> Outcome {
        session.signIn(provider: .guest, handle: handle, externalID: nil)
        return .success
    }

    private func fallthroughIfAllowed(provider: AuthProvider, handle: String,
                                      message: String) -> Outcome {
        if AuthFlags.allowAllAccounts {
            session.signIn(provider: provider, handle: handle, externalID: nil)
            return .success
        }
        GemLog.session.error("\(provider.rawValue, privacy: .public) sign-in failed: \(message, privacy: .public)")
        return .failure(message)
    }
}
