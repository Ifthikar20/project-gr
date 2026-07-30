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
            Text("GemRun — drop gems, run routes, collect what others left behind.")
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
            let available = try? await API.shared.checkHandle(handle)
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
                try? context.save()
                newHandle = ""
                handleStatus = .idle
            } catch let error as HTTPGemRunAPI.HTTPError
                        where error.code == "handle_taken" {
                // Someone grabbed it between the live check and Save.
                handleStatus = .taken
            } catch {
                handleStatus = .failed
            }
            isSavingHandle = false
        }
    }

    private func eraseLocal() {
        try? context.delete(model: StoredRun.self)
        try? context.delete(model: StoredStashItem.self)
        try? context.delete(model: StoredRoute.self)
        if let profile = session.profile {
            profile.xp = 0
            profile.level = 1
            profile.streakCount = 0
            profile.streakShields = 0
            profile.streakLastDate = nil
        }
        try? context.save()
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        // Server first (App Store 5.1.1(v): in-app deletion must really
        // delete). Then wipe the phone and return to onboarding.
        try? await API.shared.deleteAccount()
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
                      "GemRun uses your location while the app is open, to "
                      + "show gems near you. During a run YOU started, "
                      + "tracking continues with the screen off or the app "
                      + "pocketed — that's how gems collect mid-run — and "
                      + "iOS shows its location indicator the whole time. "
                      + "The moment the run ends, background tracking stops. "
                      + "Outside a run we never track you, and there is no "
                      + "location history beyond the runs you keep.")
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
            GemRun collects the minimum needed to run the game:

            • Account: a username you choose, plus level, XP, and streak. \
            Session tokens and sign-in identifiers are stored only as \
            one-way hashes; we never store your email, phone number, or \
            any password.
            • Activity: summary numbers for runs you complete (distance, \
            time, pace, gems collected). Your raw GPS trace is used once, \
            transiently, to validate collections, and is stored only on \
            your device.
            • Location: used while the app is open; during an active run, \
            tracking continues in the background (screen off, phone \
            pocketed) until the run ends — never at any other time.
            • Apple Health: read/write only with your permission, only for \
            the features described in the app, each with an in-app switch.

            We do not sell, rent, or share your personal data. We show no \
            ads and embed no third-party analytics or tracking SDKs.

            Data is retained until you delete it: "Erase all local data" \
            removes everything on your device; "Delete account & data" \
            erases your profile and history from our server immediately. \
            Gems you placed remain on the map, unlinked from any account.

            Questions or requests: contact the developer through the App \
            Store listing.
            """
        case .terms:
            return """
            Welcome to GemRun. By using the app you agree to the basics:

            • Run safely. You are responsible for your surroundings — obey \
            traffic signals, stay on public paths, and never chase a gem \
            into a place you shouldn't be. Gems only appear on public \
            walkable paths, but the judgment on the ground is always yours.
            • Play fair. GPS spoofing, automation, or tampering with the \
            service may void collections and can end your account.
            • One-time gems are first-come. Someone reaching a gem before \
            you is part of the game, not a defect.
            • The service is provided as-is, in active development: gems, \
            XP values, and features may change, reset, or be rebalanced.
            • You keep responsibility for your account and anything done \
            with it; we may suspend accounts that abuse the service or \
            other players.
            • These terms may evolve with the app; material changes will \
            appear here.

            Not fine print, just the deal: be safe, be fair, have fun.
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
