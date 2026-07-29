import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI
import UIKit

/// Settings (docs/03 §11): account, permissions, data transparency, legal.
/// Deliberately small — the essentials a location game owes its users:
/// rename, sign out, in-app account deletion (App Store 5.1.1(v)), a
/// plain-language "how we handle your data" page, privacy policy, terms.
/// There is no password to change: sign-in is Apple-ID based, so the
/// account section says exactly that instead of pretending otherwise.
@MainActor
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var newHandle = ""
    @State private var isSavingHandle = false
    @State private var confirmingErase = false
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var legalDoc: LegalDoc?

    var body: some View {
        List {
            accountSection
            permissionsSection
            dataSection
            legalSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.Colors.snow)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $legalDoc) { doc in
            LegalTextView(doc: doc)
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            let provider = switch session.authProvider {
            case .apple: "Signed in with Apple"
            case .google: "Signed in with Google"
            case .guest: "Guest account"
            }
            Label(provider, systemImage: session.authProvider == .guest
                  ? "person.fill.questionmark" : "checkmark.seal.fill")
                .foregroundStyle(DS.Colors.ink)
                .listRowBackground(DS.Colors.snowCard)

            HStack(spacing: 8) {
                TextField("Change username", text: $newHandle,
                          prompt: Text("@\(session.profile?.handle ?? "runner")"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    saveHandle()
                } label: {
                    if isSavingHandle {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").font(.caption.bold())
                            .foregroundStyle(DS.Colors.pulse)
                    }
                }
                .disabled(newHandle.trimmingCharacters(in: .whitespaces).isEmpty
                          || isSavingHandle)
            }
            .listRowBackground(DS.Colors.snowCard)

            Text("There's no GemRun password to change — your sign-in is "
                 + "protected by your Apple ID (Face ID or passcode). Manage "
                 + "it in iOS Settings → your name → Sign-In & Security.")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
                .listRowBackground(DS.Colors.snowCard)

            Button("Sign out") { session.signOut() }
                .foregroundStyle(DS.Colors.pulse)
                .listRowBackground(DS.Colors.snowCard)

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
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Location, Health & Motion — manage in iOS Settings",
                      systemImage: "location.fill")
                    .foregroundStyle(DS.Colors.ink)
            }
            .listRowBackground(DS.Colors.snowCard)
            Text("Location is used while the app is open, never in the "
                 + "background. Every permission can be revoked there at any "
                 + "time — the app keeps working, with those features off.")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
                .listRowBackground(DS.Colors.snowCard)
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
                Text(Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "0.1")
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)
        } footer: {
            Text("GemRun — drop gems, run routes, collect what others left behind.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    // MARK: - Actions

    private func saveHandle() {
        let handle = newHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        isSavingHandle = true
        Task {
            if let updated = try? await API.shared.updateMe(handle: handle) {
                session.profile?.handle = updated.handle
                try? context.save()
                newHandle = ""
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
                block("Location — only while you look",
                      "GemRun uses your location while the app is open: to "
                      + "show gems near you and to record your path during a "
                      + "run you started. We never track you in the "
                      + "background, and there is no location history beyond "
                      + "the runs you keep.")
                block("Your GPS trace stays on your phone",
                      "When you finish a run, your route trace is sent once "
                      + "to our server to verify your gem collections were "
                      + "real (anti-cheat), then discarded. The server keeps "
                      + "the outcome — distance, time, XP, which gems — not "
                      + "the trace. The full trace is stored only on your "
                      + "phone, and \"Erase all local data\" deletes it.")
                block("Apple Health, by permission",
                      "With your permission we read your total running "
                      + "distance (it mints wallet gems) and save finished "
                      + "runs as workouts. Revoke either anytime in iOS "
                      + "Settings; the app keeps working.")
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

            • Account: a username you choose, plus level, XP, and streak.
            • Activity: summary numbers for runs you complete (distance, \
            time, pace, gems collected). Your raw GPS trace is used once, \
            transiently, to validate collections, and is stored only on \
            your device.
            • Location: used while the app is open, never in the background.
            • Apple Health: read/write only with your permission, only for \
            the features described in the app.

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
            into a place you shouldn't be. Gems only spawn on public \
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
