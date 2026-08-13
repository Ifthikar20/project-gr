import CoreLocation
import CoreModels
import CoreMotion
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI
import UIKit

/// Settings (docs/03 §11): account, permissions, data transparency, legal —
/// destructive actions live at the very bottom, standard practice.
/// Deliberately small — the essentials a location game owes its users:
/// rename (with live availability), sign out, in-app account deletion
/// (App Store 5.1.1(v)), working Apple Health toggles, a plain-language
/// "how we handle your data" page, privacy policy, terms. There is no
/// password to change: sign-in is Apple-ID based, and no email is ever
/// stored — the account section says exactly that instead of pretending
/// otherwise.
@MainActor
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var newHandle = ""
    @State private var isSavingHandle = false
    @State private var handleStatus: HandleStatus = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var confirmingErase = false
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var legalDoc: LegalDoc?
    // In-app Health switches (HealthPrefs) — mirrored into @State so the
    // toggles animate; every change writes straight back.
    @State private var saveWorkouts = HealthPrefs.saveWorkouts
    @State private var readSteps = HealthPrefs.readSteps

    enum HandleStatus: Equatable {
        case idle, tooShort, checking, available, taken, failed
    }

    var body: some View {
        List {
            accountSection
            permissionsSection
            featuresSection
            dataSection
            legalSection
            aboutSection
            dangerSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.Colors.snow)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $legalDoc) { doc in
            LegalTextView(doc: doc)
        }
        .onChange(of: newHandle) { _, _ in scheduleAvailabilityCheck() }
        .onChange(of: saveWorkouts) { _, on in HealthPrefs.saveWorkouts = on }
        .onChange(of: readSteps) { _, on in HealthPrefs.readSteps = on }
    }

    // MARK: - Account

    /// What actually falls under "Account", spelled out: how you're signed
    /// in, the username on file (with live availability when changing it),
    /// what we do and don't keep, and sign out. Deletion lives at the
    /// bottom of the page, where destructive actions belong.
    private var accountSection: some View {
        Section {
            let provider = switch session.authProvider {
            case .apple: "Signed in with Apple"
            case .google: "Signed in with Google"
            case .guest: "Guest account"
            }
            Label(provider, systemImage: session.authProvider == .guest
                  ? "person.fill.questionmark" : "checkmark.seal.fill")
                .foregroundStyle(DS.Colors.ink)
                .listRowBackground(DS.Colors.snowCard)

            HStack {
                Text("Username")
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Text("@\(session.profile?.handle ?? "runner")")
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)

            HStack {
                Text("Email")
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Text("Not stored")
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("New username", text: $newHandle,
                              prompt: Text("Change username"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        saveHandle()
                    } label: {
                        if isSavingHandle {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save").font(.caption.bold())
                                .foregroundStyle(handleStatus == .available
                                    ? DS.Colors.pulse : DS.Colors.inkSecondary)
                        }
                    }
                    .disabled(handleStatus != .available || isSavingHandle)
                }
                availabilityLine
            }
            .listRowBackground(DS.Colors.snowCard)

            Button("Sign out") { session.signOut() }
                .foregroundStyle(DS.Colors.pulse)
                .listRowBackground(DS.Colors.snowCard)
        } header: {
            Text("Account")
        } footer: {
            Text("On file: your username, how you signed in, a one-way "
                 + "scrambled sign-in ID, and your gameplay stats. No email, "
                 + "phone number, or password is ever stored, so there is "
                 + "nothing more to leak. Sign-in security lives with your "
                 + "Apple ID (Face ID or passcode).")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    /// Live feedback under the username field.
    @ViewBuilder private var availabilityLine: some View {
        switch handleStatus {
        case .idle:
            EmptyView()
        case .tooShort:
            Text("At least 3 characters")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking availability…")
            }
            .font(.caption2)
            .foregroundStyle(DS.Colors.inkSecondary)
        case .available:
            Label("Available", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Colors.ink)
        case .taken:
            Label("Already taken", systemImage: "xmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Colors.pulse)
        case .failed:
            Text("Couldn't check right now. Try again in a moment.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.pulse)
        }
    }

    // MARK: - Permissions

    /// Real, working switches — not a bounce to iOS Settings. iOS never
    /// lets an app flip its own system permissions, so the Health toggles
    /// gate what GemRun DOES (off = the feature doesn't run at all), and
    /// the status rows show what the system currently allows.
    private var permissionsSection: some View {
        Section {
            Toggle(isOn: $saveWorkouts) {
                Label("Save runs to Apple Health", systemImage: "heart.fill")
                    .foregroundStyle(DS.Colors.ink)
            }
            .tint(DS.Colors.pulse)
            .listRowBackground(DS.Colors.snowCard)

            Toggle(isOn: $readSteps) {
                Label("Read steps for run stats", systemImage: "figure.walk")
                    .foregroundStyle(DS.Colors.ink)
            }
            .tint(DS.Colors.pulse)
            .listRowBackground(DS.Colors.snowCard)

            HStack {
                Label("Location", systemImage: "location.fill")
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Text(locationStatus)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)

            HStack {
                Label("Motion & steps", systemImage: "figure.run")
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Text(motionStatus)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("System permissions in iOS Settings",
                      systemImage: "gearshape")
                    .foregroundStyle(DS.Colors.ink)
            }
            .listRowBackground(DS.Colors.snowCard)
        } header: {
            Text("Permissions")
        } footer: {
            Text("The two Health switches take effect immediately, no "
                 + "system dialog. Location is used while the app is open, "
                 + "never in the background. Apple hides whether Health "
                 + "reading was granted (by design) — if steps stay at 0, "
                 + "check the Health app under Sharing.")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private var locationStatus: String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: "While using"
        case .denied, .restricted: "Off"
        default: "Not asked yet"
        }
    }

    private var motionStatus: String {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: "On"
        case .denied, .restricted: "Off"
        default: "Not asked yet"
        }
    }

    // MARK: - Data

    /// Feature entitlements: every switchable surface, on-device toggles
    /// (FeatureFlags). The gated UI disappears in place — no restart needed.
    private var featuresSection: some View {
        Section {
            ForEach(Feature.allCases) { feature in
                Toggle(isOn: Binding(
                    get: { FeatureFlags.shared.isEnabled(feature) },
                    set: { FeatureFlags.shared.set(feature, enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .foregroundStyle(DS.Colors.ink)
                        Text(feature.detail)
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                }
                .tint(DS.Colors.pulse)
                .listRowBackground(DS.Colors.snowCard)
            }
        } header: {
            Text("Features")
        } footer: {
            Text("Switch any part of RunnerCard off — it disappears everywhere "
                 + "in the app until you switch it back on.")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private var dataSection: some View {
        Section("Your data") {
            NavigationLink {
                DataTransparencyView()
            } label: {
                Label("How we handle your data", systemImage: "hand.raised.fill")
                    .foregroundStyle(DS.Colors.ink)
            }
            .listRowBackground(DS.Colors.snowCard)
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        Section("Legal") {
            Button {
                legalDoc = .privacy
            } label: {
                Label("Privacy Policy", systemImage: "lock.fill")
                    .foregroundStyle(DS.Colors.ink)
            }
            .listRowBackground(DS.Colors.snowCard)
            Button {
                legalDoc = .terms
            } label: {
                Label("Terms of Service", systemImage: "doc.text.fill")
                    .foregroundStyle(DS.Colors.ink)
            }
            .listRowBackground(DS.Colors.snowCard)
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                // "0.1.0 (214)" — marketing version + auto-incremented
                // build number (run.sh derives it from the git commit
                // count, so every build/release shows a higher number).
                let short = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "0.1"
                let build = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
                Text("\(short) (\(build))")
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)
        } footer: {
            Text("RunnerCard — walk real zones, mint collectible cards.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    // MARK: - Danger zone (always the last section)

    private var dangerSection: some View {
        Section {
            Button("Erase all local data", role: .destructive) {
                confirmingErase = true
            }
            .listRowBackground(DS.Colors.snowCard)
            .confirmationDialog(
                "Erase everything on this phone? Runs, stash, and routes "
                + "stored locally are gone for good. Your server account is "
                + "not touched.",
                isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase local data", role: .destructive) { eraseLocal() }
            }

            Button(isDeleting ? "Deleting…" : "Delete account & data",
                   role: .destructive) {
                confirmingDelete = true
            }
            .disabled(isDeleting)
            .listRowBackground(DS.Colors.snowCard)
            .confirmationDialog(
                "Delete your account? Your profile, runs, stash, and friends "
                + "are erased from our server for good. Gems you placed stay "
                + "on the map but are no longer linked to you.",
                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    Task { await deleteAccount() }
                }
            }
            if let deleteError {
                Text(deleteError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(DS.Colors.snowCard)
            }
        } footer: {
            Text("Erase clears this phone only. Delete removes your account "
                 + "and history from our server, permanently.")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    // MARK: - Actions

    /// Debounced live availability: fires ~350 ms after the last keystroke,
    /// and a stale response can never overwrite a newer field value.
    private func scheduleAvailabilityCheck() {
        checkTask?.cancel()
        let handle = newHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { handleStatus = .idle; return }
        guard handle.count >= 3 else { handleStatus = .tooShort; return }
        handleStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let available = await GemLog.attempt(GemLog.session, "handle availability check", {
                try await API.shared.checkHandle(handle)
            })
            guard !Task.isCancelled,
                  handle == newHandle.trimmingCharacters(in: .whitespaces)
            else { return }
            switch available {
            case .none: handleStatus = .failed
            case .some(true): handleStatus = .available
            case .some(false): handleStatus = .taken
            }
        }
    }

    private func saveHandle() {
        let handle = newHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        isSavingHandle = true
        Task {
            do {
                let updated = try await API.shared.updateMe(handle: handle)
                session.profile?.handle = updated.handle
                GemLog.attempt(GemLog.persist, "save renamed handle") {
                    try context.save()
                }
                newHandle = ""
                handleStatus = .idle
            } catch let error as HTTPGemRunAPI.HTTPError
                        where error.code == "handle_taken" {
                // Someone grabbed it between the live check and Save.
                handleStatus = .taken
            } catch {
                GemLog.session.error("handle save failed: \(String(describing: error), privacy: .public)")
                handleStatus = .failed
            }
            isSavingHandle = false
        }
    }

    private func eraseLocal() {
        // "Erase all local data" silently no-oping is worse than failing —
        // log each step so a stuck row is diagnosable.
        GemLog.attempt(GemLog.persist, "erase StoredRun rows") {
            try context.delete(model: StoredRun.self)
        }
        GemLog.attempt(GemLog.persist, "erase StoredStashItem rows") {
            try context.delete(model: StoredStashItem.self)
        }
        GemLog.attempt(GemLog.persist, "erase StoredRoute rows") {
            try context.delete(model: StoredRoute.self)
        }
        if let profile = session.profile {
            profile.xp = 0
            profile.level = 1
            profile.streakCount = 0
            profile.streakShields = 0
            profile.streakLastDate = nil
        }
        GemLog.attempt(GemLog.persist, "save local erase") { try context.save() }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        deleteError = nil
        // Server first (App Store 5.1.1(v): in-app deletion must really
        // delete). If the server call fails, STOP — wiping the phone and
        // signing out anyway showed a "deleted" outcome while the account
        // lived on, silently.
        do {
            try await API.shared.deleteAccount()
        } catch {
            GemLog.session.error("account deletion failed: \(String(describing: error), privacy: .public)")
            deleteError = "Couldn't delete your account — check your connection and try again."
            return
        }
        eraseLocal()
        session.signOut()
    }
}

// MARK: - How we handle your data

/// The explicit version — written for the runner, not the lawyer. Every
/// claim here mirrors what the code actually does; when behavior changes,
/// this page changes in the same commit.
struct DataTransparencyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                block("Location — only for the map and your runs",
                      "RunnerCard uses your location while the app is open, "
                      + "to show zones near you and count the distance you "
                      + "cover inside them. During a run YOU started, "
                      + "tracking continues with the screen off or the app "
                      + "pocketed — that's how zone distance adds up mid-run "
                      + "— and iOS shows its location indicator the whole "
                      + "time. The moment the run ends, background tracking "
                      + "stops. Outside the map and your runs we never track "
                      + "you, and there is no location history beyond the "
                      + "runs you keep.")
                block("Your GPS trace stays on your phone",
                      "When you finish a run, your route trace is sent once "
                      + "to our server to verify your gem collections were "
                      + "real (anti-cheat), then discarded. The server keeps "
                      + "the outcome — distance, time, XP, which gems — not "
                      + "the trace. The full trace is stored only on your "
                      + "phone, and \"Erase all local data\" deletes it.")
                block("Apple Health, by permission and by switch",
                      "With your permission we read your step count to "
                      + "show accurate run stats, and save finished runs "
                      + "as workouts. Both have in-app switches under "
                      + "Permissions that stop them instantly, and the "
                      + "system-level grants can be revoked in iOS "
                      + "Settings anytime; the app keeps working.")
                block("Sign-in secrets are scrambled",
                      "Your session tokens and your Apple/Google sign-in ID "
                      + "are stored only as one-way SHA-256 scrambles — "
                      + "never in plaintext — so a leaked database contains "
                      + "no usable credentials. We never store your email, "
                      + "phone number, or any password. Your username is "
                      + "public by design (leaderboards and friends), which "
                      + "is why it isn't secret.")
                block("What lives on our server",
                      "Your username, level, XP, streak, stash, friends "
                      + "list, and the runs' summary numbers. Gems you "
                      + "place on the map are linked to your account until "
                      + "you delete it.")
                block("What we don't do",
                      "No ads. No selling or sharing your data. No "
                      + "third-party analytics or tracking SDKs — the app "
                      + "talks to our server and to Apple's services "
                      + "(Maps, Health) on your device, nothing else. Map "
                      + "data for placing gems comes from OpenStreetMap, "
                      + "queried by our server — your identity never "
                      + "touches it.")
                block("Deleting is real",
                      "Delete your account here in Settings and our server "
                      + "erases your profile, runs, stash, and friends "
                      + "immediately. Gems you placed stay on the map but "
                      + "are no longer linked to anyone.")
            }
            .padding(20)
        }
        .background(DS.Colors.snow)
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(DS.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Legal documents

/// The canonical text also lives in docs/legal/*.md (the hostable public
/// copies App Store Connect needs) — behavior, this text, and those files
/// change in the same commit. [Bracketed] values must be set before launch.
enum LegalDoc: String, Identifiable {
    case privacy, terms
    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Service"
        }
    }

    var body: String {
        switch self {
        case .privacy:
            return """
            Last updated: [set on release]

            RunnerCard is a running game: large zones appear over real \
            parks and trails, and you mint collectible cards by physically \
            covering distance inside them. That only \
            works with location data, so this policy is specific about what \
            we collect, when, what leaves your phone, and what never does. \
            Every statement here describes what the app actually does — \
            when the app's behavior changes, this policy changes with it.

            1. WHO WE ARE

            RunnerCard is operated by [legal entity name, address]. Contact \
            for anything in this policy: [privacy@yourdomain]. "We" below \
            means that operator; "the service" means the RunnerCard iOS app \
            and its server.

            2. WHAT WE COLLECT, AND WHEN

            Account. A username ("handle") you choose. If you sign in with \
            Apple or Google, we receive a provider account identifier; we \
            store it only as a one-way cryptographic hash, and use it \
            solely to recognize your account. We do not collect or store \
            your email address, phone number, real name, or any password. \
            Session tokens are likewise stored only as one-way hashes on \
            our server.

            Location — the heart of the game, and the most carefully \
            scoped thing we touch:

            • While the app is open, your location positions you on the \
            map, and the coordinates of the area you are viewing are sent \
            to our server so it can return — and stock — routes and gems \
            near you.
            • During an active run, location tracking continues in the \
            background (screen off, phone pocketed) until the run ends. \
            iOS shows its background-location indicator the entire time. \
            Tracking stops when the run stops. Outside a run, we never \
            track you in the background.
            • When you finish a run, the app uploads that run's GPS track \
            once, so the server can verify your collections were \
            physically real (our anti-cheat). The server keeps the \
            verdict — summary numbers, which gems were awarded or \
            revoked — not the raw track. Your raw track stays on your \
            phone, where it draws your run maps.
            • If you place a gem on the map for others, you are publishing \
            that coordinate: other players can see and collect it there.

            Motion & fitness. Live step counts and distance during a run \
            come from your phone's motion coprocessor, on-device. Step \
            counts are never sent to our server.

            Apple Health. Only with your permission, and each direction \
            has its own switch inside the app: writing finished runs to \
            Health as workouts, and reading Health's step count for a \
            run's time window. Nothing read from Health leaves your phone.

            Gameplay. Runs you complete (distance, time, pace, validation \
            status, XP), your gem stash, streaks, level, routes you create \
            and publish, and who you follow.

            Fairness records. When you attempt to collect a gem, the \
            server records the attempt and its outcome (collected, \
            already taken, too far) with your closest distance to the \
            gem — this is how first-come races and disputes stay \
            auditable.

            Operational logs. Our server keeps request logs (with short \
            request identifiers) and the coordinates of map areas \
            requested, for reliability and abuse prevention, for a \
            limited period. On-device diagnostic logs redact your precise \
            coordinates.

            3. HOW WE USE IT

            To run the game: show the map, stock gems near where players \
            actually are, verify collections, settle runs, compute \
            XP/streaks/leaderboards, and keep the shared world fair. \
            Nothing else. We do not build advertising or marketing \
            profiles.

            4. WHAT OTHER PLAYERS CAN SEE

            RunnerCard is a shared world, so some things are public by design:

            • Your handle and level, on leaderboards and in player search.
            • Your weekly XP, distance, and run count, to players who \
            follow you.
            • Routes you publish: their name, description, path, gem \
            placements, and your handle as creator.
            • Gems you place on the map, at the coordinate you chose, \
            until collected.
            • First-find credit on gems you were first to collect.

            Your live location, your GPS tracks, and your run history \
            details are never shown to other players.

            5. WHAT WE DON'T DO

            No ads. No sale, rental, or sharing of personal data with \
            data brokers. No third-party analytics or tracking SDKs \
            embedded in the app. No email marketing (we don't have your \
            email). No cross-app or cross-site tracking.

            6. THIRD PARTIES THE APP TOUCHES

            • Apple. Maps, walking directions, and address lookup are \
            provided by Apple frameworks on your device; coordinates used \
            for those features are processed by Apple under Apple's \
            privacy policy. Sign in with Apple, if you use it, is \
            likewise handled by Apple.
            • Google. Only if you sign in with Google (when that option \
            is enabled), Google processes that sign-in under Google's \
            privacy policy.
            • OpenStreetMap. Our server queries OpenStreetMap's data (via \
            the Overpass API) to learn where public walkable paths are, \
            so gems never spawn on highways or private grounds. Those \
            queries are about geographic areas, come from our server, and \
            are not linked to your account.
            • Infrastructure. Our server runs on cloud infrastructure \
            providers who process data on our behalf under contract: \
            [list providers at launch].

            7. COOKIES, IDENTIFIERS, AND WHAT LIVES ON YOUR PHONE

            RunnerCard is a native app with no embedded browser: we use no \
            cookies, no advertising identifier (we never request IDFA), \
            and no fingerprinting. What is stored on your device, under \
            your control:

            • Your game cache: routes, your runs (including their map \
            traces), your stash, and your profile.
            • Preferences: onboarding state, Health switches, feature \
            toggles, and which gem fact you saw last.
            • A session token while the app is signed in.
            • During a run, a crash-recovery file of that run's samples, \
            deleted when the run completes or is discarded.

            "Erase all local data" in Settings removes the game data \
            above. If we ever operate a website, it will carry its own \
            cookie notice.

            8. RETENTION AND DELETION

            Your data is kept while your account exists. Two controls, \
            both in Settings:

            • Erase all local data — wipes the game data on your device; \
            your server account is untouched.
            • Delete account & data — permanently deletes your profile, \
            runs, stash, and follows from our server, immediately, from \
            inside the app. Gems you placed remain on the map but are no \
            longer linked to any account. If the deletion request cannot \
            reach the server, the app tells you and deletes nothing \
            silently.

            9. SECURITY

            Sign-in identifiers and session tokens are stored only as \
            one-way hashes — a copy of our database contains no usable \
            credentials. Production traffic uses TLS. No system is \
            perfectly secure, but we deliberately minimize what exists to \
            be stolen.

            10. CHILDREN

            RunnerCard is not directed at children under 13, and we do not \
            knowingly collect personal information from them. If you \
            believe a child under 13 has an account, contact us and we \
            will delete it.

            11. YOUR RIGHTS AND CHOICES

            Depending on where you live, you may have rights to access, \
            correct, delete, or port your personal data, and to object to \
            or restrict processing. Most of these are built in: rename \
            your handle in Settings, flip Health and location permissions \
            in iOS Settings, toggle features off, and delete everything \
            in-app. For anything else — or to exercise rights in your \
            jurisdiction — contact [privacy@yourdomain]. You can also \
            complain to your local data protection authority.

            12. WHERE DATA IS PROCESSED

            Our server currently runs in [region — set at launch]. If you \
            use RunnerCard from elsewhere, your data is processed there under \
            this policy and applicable safeguards.

            13. CHANGES TO THIS POLICY

            When the app's behavior changes in a way that matters here, \
            this policy changes in the same release, with the date above \
            updated. Material changes will be called out in the app.

            14. CONTACT

            [privacy@yourdomain] · [postal address] — or through the App \
            Store listing.

            Not fine print, just the deal: the game needs your location \
            while you play, almost everything else stays on your phone, \
            and nothing about you is for sale.
            """
        case .terms:
            return """
            Last updated: [set on release]

            These terms are the deal between you and [legal entity name] \
            ("we") for using RunnerCard. By creating an account or using the \
            app, you agree to them. The Privacy Policy explains data; \
            these terms explain conduct, safety, and what you can expect \
            from the service.

            1. WHO CAN PLAY

            You must be at least 13 years old (or older where your local \
            law requires) and able to agree to these terms. If you're \
            under 18, make sure a parent or guardian is okay with you \
            playing.

            2. WHAT RUNNERCARD IS

            A running game. The service marks large zones over real parks \
            and trails; you mint collectible cards by physically covering \
            about a mile inside a zone while the app is open or \
            recording your run. Cards, XP, streaks, and levels are game \
            features — see section 7 for what they are (and aren't) worth.

            3. YOUR ACCOUNT

            One account per person, operated by you. You're responsible \
            for what happens with it. Pick a handle that isn't \
            impersonating someone else, misleading, or offensive; handles \
            are visible to other players and we may require a change or \
            reclaim ones that break these rules.

            4. SAFETY — READ THIS ONE

            Running outdoors carries real risk, and you are always the \
            one on the ground:

            • You are responsible for your own safety. Watch traffic, \
            obey signals and laws, and mind terrain, weather, darkness, \
            and your own condition.
            • Never chase a card into a place you shouldn't be. The \
            service anchors zones only on public parks and paths that \
            public map data marks as walkable, and never knowingly over \
            private grounds, schools, or restricted areas — but map data \
            can be wrong or stale. If your mile would mean \
            trespassing, crossing unsafely, or taking any risk, walk \
            somewhere else. A fresh zone appears tomorrow; you don't \
            respawn.
            • Not medical advice. RunnerCard is not a medical device. Calorie \
            and step figures are estimates computed from distance and \
            pace with standard assumptions. Consult a physician before \
            starting an exercise program if you have any doubt about your \
            health.
            • Don't interact with the screen while moving through \
            traffic; the game is designed to work with your phone \
            pocketed.

            5. FAIR PLAY

            The shared world only works if collections are real:

            • No GPS spoofing, location simulation, automation, bots, \
            emulators, or tampering with the app or its traffic.
            • Every run is verified server-side against your recorded \
            track; the server may revoke collections and XP that \
            verification does not support, and its verdict is final for \
            game state.
            • Collection attempts are logged (outcome and distance) so \
            races and disputes are auditable.
            • Cheating, multi-account abuse, or exploiting bugs can lead \
            to revoked items, suspension, or termination of your account. \
            Found a bug? Report it — don't farm it.

            6. YOUR CONTENT

            Routes you create and publish, route names and descriptions, \
            your handle, and gem placements are your content. You grant \
            us a worldwide, royalty-free license to host, display, and \
            distribute that content within the service so the game can \
            work — a published route and its gems are visible to other \
            players by design, credited to your handle. Don't publish \
            content that is unlawful, infringing, hateful, or that \
            exposes someone's private information (including placing gems \
            to mark a private location that isn't yours to publish). We \
            may remove content or placements that break these rules or \
            degrade the game.

            7. VIRTUAL ITEMS

            Gems, XP, streaks, shields, and levels have no monetary \
            value, are not redeemable, and can't be sold, traded outside \
            the game, or transferred except as game features allow. The \
            world is first-come: someone reaching a one-time gem before \
            you is the game working, not a defect. Uncollected \
            system-placed gems rotate daily. We may rebalance values, \
            respawn rules, placement, and features as the game evolves, \
            including resetting game state during this development period.

            8. WHAT NOT TO DO

            Besides sections 5 and 6: don't interfere with or overload \
            the service, probe or bypass its security, scrape it, reverse \
            engineer the app except where law permits, harass other \
            players, or use the service to break any law. Don't use \
            RunnerCard where using it would itself be unsafe or unlawful.

            9. OUR STUFF

            The app, the service, the RunnerCard name, the design, and \
            the card catalog are ours or our licensors'. Map and path data \
            include content from OpenStreetMap contributors \
            (© OpenStreetMap, ODbL) and Apple. These terms give you a \
            personal, non-transferable license to use the app for playing \
            the game — nothing more.

            10. ENDING THINGS

            You can stop any time — and delete your account and data from \
            inside the app (Settings), which is immediate and permanent. \
            We may suspend or terminate accounts that violate these \
            terms, with revocation of virtual items. Sections that by \
            their nature survive (4, the section 6 license for \
            already-published content, 7, 11, 12) survive termination.

            11. THE SERVICE IS PROVIDED "AS IS"

            RunnerCard is under active development. We don't promise \
            uninterrupted or error-free service, that zones or cards will \
            be reachable or fairly distributed in every area, that map data \
            is accurate, or that any particular feature will persist. To \
            the maximum extent permitted by law, we disclaim all \
            warranties, express or implied.

            12. LIMITATION OF LIABILITY

            To the maximum extent permitted by law, we are not liable for \
            indirect, incidental, special, consequential, or punitive \
            damages, or for loss of data, profits, or goodwill, arising \
            from your use of the service — and our total liability for \
            any claim is limited to the greater of [USD 50] or the amount \
            you paid us in the past 12 months (today: nothing, the app is \
            free). Nothing in these terms limits liability that cannot be \
            limited by law. Your safety while running remains your \
            responsibility as described in section 4.

            13. GOVERNING LAW & DISPUTES

            These terms are governed by the laws of [jurisdiction — set \
            before launch], without regard to conflict-of-law rules. \
            Disputes will be resolved in the courts of [venue], unless \
            your local law gives you mandatory protections — those stay \
            yours.

            14. CHANGES TO THESE TERMS

            These terms evolve with the app. Material changes will be \
            announced in the app with an updated date above; continuing \
            to play after they take effect means you accept them.

            15. CONTACT

            [support@yourdomain] · [postal address] — or through the App \
            Store listing.

            Not fine print, just the deal: be safe, be fair, respect the \
            world you're running through, and have fun.
            """
        }
    }
}

struct LegalTextView: View {
    let doc: LegalDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(doc.body)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(DS.Colors.snow)
            .navigationTitle(doc.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(DS.Colors.pulse)
                }
            }
        }
    }
}
