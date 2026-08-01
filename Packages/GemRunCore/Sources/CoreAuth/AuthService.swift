import AuthenticationServices
import CoreModels
import CoreNetworking
import CorePersistence
import Foundation

/// A stable anonymous identity for guest accounts: one UUID minted per
/// install, kept in UserDefaults and sent as the guest's external id, so the
/// server recognizes the SAME account on every sign-in and relaunch. Without
/// it a guest would mint a fresh server profile each session and quietly
/// lose stash, XP, and streak.
public enum GuestIdentity {
    private static let key = "gemrun.guest.id"

    public static var id: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}

/// Persists the server session token across launches so a relaunch resumes
/// the SAME authenticated account instead of running unauthenticated.
/// UserDefaults for now — moving the raw token into the Keychain is the
/// docs/10 hardening item, and this type is the one place that change lands.
struct TokenStore {
    private let key = "gemrun.session.token"

    var token: String? {
        UserDefaults.standard.string(forKey: key)
    }

    func save(_ token: String) {
        UserDefaults.standard.set(token, forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// The auth service (docs/18): everything identity, behind one seam.
/// Provider credential handling, the per-install guest identity, server
/// registration (`POST /v1/auth/{provider}`), session-token persistence,
/// and launch restore all live HERE — views render `Outcome`s and nothing
/// else, and SessionStore only persists the local profile.
///
/// This module is also the future service boundary: when the backend splits
/// from the UI project, the client side of that split is this file and the
/// server side is Django's `/v1/auth/*` — no feature code moves.
///
/// docs/10 lands real verification in exactly two places: forwarding
/// Apple's `identityToken` / Google's `idToken` in `register`, and
/// `GIDSignIn` in `signInWithGoogle`. Until then
/// `AuthFlags.allowAllAccounts` (TEMPORARY) keeps dev sign-ins permissive —
/// but accounts are already unique, because every path sends a stable
/// external id.
@MainActor
public struct AuthService {
    let session: SessionStore
    private let tokens = TokenStore()

    public init(session: SessionStore) {
        self.session = session
    }

    public enum Outcome: Equatable {
        case success
        /// The user backed out (dismissed the Apple sheet) — show nothing.
        case cancelled
        case failure(String)
    }

    /// Whether this build can actually perform Google Sign-In. SignInView
    /// hides the Google button when false — an accurate page shows only
    /// buttons that do what they say.
    public static var isGoogleSignInAvailable: Bool {
        #if canImport(GoogleSignIn)
        true
        #else
        false
        #endif
    }

    /// Sign in with Apple. `credential.user` is Apple's stable per-team user
    /// id — our external id — so the same Apple ID lands on the same account
    /// on every device and reinstall. Django later verifies
    /// `credential.identityToken` server-side (docs/10).
    public func signIn(apple result: Result<ASAuthorization, Error>,
                       preferredHandle: String) -> Outcome {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                GemLog.session.error("Apple sign-in returned a non-AppleID credential")
                return .failure("Apple sign-in returned no usable credential. Try again, or continue as a guest.")
            }
            let name = preferredHandle.isEmpty
                ? (credential.fullName?.givenName ?? "runner") : preferredHandle
            return complete(provider: .apple, handle: name,
                            externalID: credential.user)
        case .failure(let error):
            // An accurate button reports its own failure — no silent guest
            // fallthrough (that used to mint a surprise second account).
            // Backing out of the sheet is a choice, not an error.
            if (error as? ASAuthorizationError)?.code == .canceled {
                return .cancelled
            }
            GemLog.session.error("Apple sign-in failed: \(String(describing: error), privacy: .public)")
            return .failure("Apple sign-in didn't complete. On a simulator without an Apple ID, continue as a guest instead.")
        }
    }

    public func signInWithGoogle(preferredHandle: String) -> Outcome {
        #if canImport(GoogleSignIn)
        // Real flow once the OAuth client ID is configured (docs/10):
        // GIDSignIn.sharedInstance.signIn(withPresenting:) → profile +
        // idToken for Django to verify; Google's `sub` becomes the external
        // id passed to `complete`.
        return .failure("Google Sign-In needs its OAuth client ID configured.")
        #else
        // Unreachable from the UI: SignInView hides the Google button when
        // `isGoogleSignInAvailable` is false.
        return .failure("Google Sign-In isn't part of this build yet.")
        #endif
    }

    /// Guest is a real, durable account: the per-install `GuestIdentity` id
    /// is its external id, so the server returns the same profile every time
    /// instead of a fresh one per session.
    public func signInAsGuest(handle: String) -> Outcome {
        complete(provider: .guest, handle: handle, externalID: GuestIdentity.id)
    }

    /// Call once at app launch, after `SessionStore.attach`. Reconnects this
    /// install to its server account:
    /// - stored token → adopted by the API client, so the relaunch IS the
    ///   same account with no network round-trip
    /// - signed in but tokenless (registration failed offline once, or an
    ///   older build) → re-registers with the stored identity, converging on
    ///   the same account instead of minting another
    /// Signed out or first launch → nothing to restore.
    public func restoreSession() async {
        guard session.isOnboarded else { return }
        if let token = tokens.token {
            await API.shared.adopt(sessionToken: token)
            GemLog.session.debug("session restored from stored token")
            return
        }
        guard let profile = session.profile else { return }
        let externalID = profile.externalUserID
            ?? (session.authProvider == .guest ? GuestIdentity.id : nil)
        do {
            let response = try await API.shared.auth(
                provider: session.authProvider, handle: profile.handle,
                externalID: externalID)
            tokens.save(response.token)
        } catch {
            GemLog.session.error("session restore failed — continuing unauthenticated: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Shared tail

    private func complete(provider: AuthProvider, handle: String,
                          externalID: String?) -> Outcome {
        guard session.signIn(provider: provider, handle: handle,
                             externalID: externalID) else {
            return .failure("Couldn't save your profile on this device.")
        }
        register(provider: provider,
                 handle: session.profile?.handle ?? handle,
                 externalID: externalID)
        return .success
    }

    /// Exchange the identity for a server session (`POST /v1/auth/{provider}`,
    /// docs/06) and keep the token for later launches. Fire-and-forget: local
    /// sign-in already succeeded and the app works offline — but an
    /// unregistered session sends every later request unauthenticated, so a
    /// failure is named loudly at its cause and `restoreSession()` retries on
    /// the next launch.
    private func register(provider: AuthProvider, handle: String,
                          externalID: String?) {
        Task {
            do {
                let response = try await API.shared.auth(
                    provider: provider, handle: handle, externalID: externalID)
                tokens.save(response.token)
            } catch {
                GemLog.session.error("auth POST failed — continuing unauthenticated: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
