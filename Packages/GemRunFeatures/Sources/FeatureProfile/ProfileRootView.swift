import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftData
import SwiftUI

/// Identity, streak, creations, settings (docs/03 §11).
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
                settingsSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.ink)
            .navigationTitle("Profile")
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DS.Colors.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(session.profile?.handle ?? "runner")")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.textPrimary)
                    let level = session.profile?.level ?? 1
                    let xp = session.profile?.xp ?? 0
                    let needed = XPRules.xpToAdvance(from: level)
                    Text("Level \(level) · \(xp)/\(needed) XP")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                    ProgressView(value: Double(xp), total: Double(needed))
                        .tint(DS.Colors.gold)
                }
            }
            .listRowBackground(DS.Colors.inkRaised)
        }
    }

    private var streakSection: some View {
        Section {
            HStack(spacing: 16) {
                Label("\(session.profile?.streakCount ?? 0)-day streak",
                      systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                let shields = session.profile?.streakShields ?? 0
                Label("\(shields)", systemImage: "shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(shields > 0 ? DS.Colors.gold : DS.Colors.textSecondary)
            }
            .listRowBackground(DS.Colors.inkRaised)
            Text(String(format: "XP multiplier %.1f× — any run of 1 km+ keeps the flame alive.",
                        session.streakMultiplier))
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .listRowBackground(DS.Colors.inkRaised)
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
            .listRowBackground(DS.Colors.inkRaised)
        }
    }

    private var myRoutesSection: some View {
        Section("My routes") {
            if myRoutes.isEmpty {
                Text("Routes you create appear here.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .listRowBackground(DS.Colors.inkRaised)
            }
            ForEach(myRoutes) { route in
                HStack {
                    VStack(alignment: .leading) {
                        Text(route.name)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(String(format: "%.1f km · %d runs",
                                    Double(route.distanceM) / 1_000, route.runCount))
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer()
                }
                .listRowBackground(DS.Colors.inkRaised)
            }
            .onDelete { offsets in
                for offset in offsets {
                    myRoutes[offset].statusRaw = RouteStatus.archived.rawValue
                }
                try? context.save()
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Button("Erase all local data", role: .destructive) {
                confirmingReset = true
            }
            .listRowBackground(DS.Colors.inkRaised)
            .confirmationDialog("Erase everything? Runs, stash, and routes are gone for good.",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { eraseAll() }
            }
            Text("GemRun is local-first for now — an account system arrives with the backend.")
                .font(.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .listRowBackground(DS.Colors.inkRaised)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.textSecondary)
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
