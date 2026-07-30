import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftUI

/// Identity + streak, and the door to Settings (docs/03 §11), Daybreak
/// Pulse: grouped white cards on snow, pulse for streak/level accents.
/// Run history and lifetime stats live in Compete ("My Routes"), not here.
@MainActor
public struct ProfileRootView: View {
    @Environment(SessionStore.self) private var session

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                headerSection
                streakSection
                settingsSection
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
            Text(String(format: "XP multiplier %.1f× — any run over 0.6 mi keeps the flame alive.",
                        session.streakMultiplier))
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
                .listRowBackground(DS.Colors.snowCard)
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .foregroundStyle(DS.Colors.ink)
            }
            .listRowBackground(DS.Colors.snowCard)
        } footer: {
            Text("Account, permissions, how your data is handled, terms & privacy.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }
}
