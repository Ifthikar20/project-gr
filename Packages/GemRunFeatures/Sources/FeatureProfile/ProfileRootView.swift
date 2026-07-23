import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftData
import SwiftUI

/// Identity, streak, creations, settings (docs/03 §11), Daybreak Pulse:
/// grouped white cards on snow, pulse for streak/level accents.
public struct ProfileRootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.modelContext) private var context
    @Query private var runs: [StoredRun]
    @Query private var stash: [StoredStashItem]
    @Query(sort: \StoredRoute.createdAt, order: .reverse) private var routes: [StoredRoute]
    @State private var confirmingReset = false

    public init() {}

    private var myRoutes: [StoredRoute] {
        guard let handle = session.profile?.handle else { return [] }
        return routes.filter { $0.creatorHandle == handle }
    }

    public var body: some View {
        NavigationStack {
            List {
                headerSection
                streakSection
                statsSection
                myRoutesSection
                accountSection
                dataSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.snow)
            .navigationTitle("Profile")
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DS.Colors.pulse)
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(session.profile?.handle ?? "runner")")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                    let level = session.profile?.level ?? 1
                    let xp = session.profile?.xp ?? 0
                    let needed = XPRules.xpToAdvance(from: level)
                    Text("Level \(level) · \(xp)/\(needed) XP")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                    ProgressView(value: Double(xp), total: Double(needed))
                        .tint(DS.Colors.pulse)
                }
            }
            .listRowBackground(DS.Colors.snowCard)
        }
    }

    private var streakSection: some View {
        Section {
            HStack(spacing: 16) {
                Label("\(session.profile?.streakCount ?? 0)-day streak",
                      systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(DS.Colors.pulse)
                Spacer()
                let shields = session.profile?.streakShields ?? 0
                Label("\(shields)", systemImage: "shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(shields > 0 ? DS.Colors.ink : DS.Colors.inkSecondary)
            }
            .listRowBackground(DS.Colors.snowCard)
            Text(String(format: "XP multiplier %.1f× — any run of 1 km+ keeps the flame alive.",
                        session.streakMultiplier))
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
                .listRowBackground(DS.Colors.snowCard)
        }
    }

    private var statsSection: some View {
        Section("Lifetime") {
            let km = Double(runs.map(\.distanceM).reduce(0, +)) / 1_000
            HStack {
                stat(String(format: "%.1f", km), "km")
                stat("\(runs.count)", "runs")
                stat("\(stash.count)", "gems")
                stat("\(myRoutes.count)", "routes made")
            }
            .listRowBackground(DS.Colors.snowCard)
        }
    }

    private var myRoutesSection: some View {
        Section("My routes") {
            if myRoutes.isEmpty {
                Text("Routes you create appear here.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .listRowBackground(DS.Colors.snowCard)
            }
            ForEach(myRoutes) { route in
                HStack {
                    VStack(alignment: .leading) {
                        Text(route.name)
                            .foregroundStyle(DS.Colors.ink)
                        Text(String(format: "%.1f km · %d runs",
                                    Double(route.distanceM) / 1_000, route.runCount))
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                    Spacer()
                }
                .listRowBackground(DS.Colors.snowCard)
            }
            .onDelete { offsets in
                for offset in offsets {
                    myRoutes[offset].statusRaw = RouteStatus.archived.rawValue
                }
                try? context.save()
            }
        }
    }

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
            if AuthFlags.allowAllAccounts {
                Text("Dev mode: all accounts temporarily accepted (AuthFlags.allowAllAccounts).")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .listRowBackground(DS.Colors.snowCard)
            }
            Button("Sign out") {
                session.signOut()
            }
            .foregroundStyle(DS.Colors.pulse)
            .listRowBackground(DS.Colors.snowCard)
        }
    }

    private var dataSection: some View {
        Section("Settings") {
            Button("Erase all local data", role: .destructive) {
                confirmingReset = true
            }
            .listRowBackground(DS.Colors.snowCard)
            .confirmationDialog("Erase everything? Runs, stash, and routes are gone for good.",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { eraseAll() }
            }
            Text("GemRun is local-first for now — full accounts arrive with the backend.")
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
                .listRowBackground(DS.Colors.snowCard)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(DS.Colors.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func eraseAll() {
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
}
