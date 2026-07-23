import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Everything needed to decide to run (docs/03 §3). Start Run hands off to the
/// App-level full-screen cover via SessionStore.
struct RouteDetailView: View {
    let route: Route
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Query private var stash: [StoredStashItem]
    @Query private var runs: [StoredRun]

    private var collectedDropIDs: Set<UUID> {
        // Local proxy for "has this user collected this drop": collected gem IDs
        // on this route. Server-accurate per-drop state arrives in Phase F.
        let routeID = route.id
        let gemIDs = Set(stash.filter { $0.routeID == routeID }.map(\.gemID))
        return Set(route.gemDrops.filter { gemIDs.contains($0.gemID) }.map(\.id))
    }

    private var bestTimes: [StoredRun] {
        runs.filter {
            $0.routeID == route.id && !$0.isWalk
                && $0.statusRaw == RunValidationStatus.valid.rawValue
        }
        .sorted { $0.durationS < $1.durationS }
        .prefix(3)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RoutePreviewMap(route: route, collectedDropIDs: collectedDropIDs)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    statsRow

                    if let profile = route.elevationProfile, profile.count > 2 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Elevation")
                                .font(DS.Typography.heading)
                                .foregroundStyle(DS.Colors.textPrimary)
                            ElevationStrip(
                                profile: profile,
                                markers: route.gemDrops.map {
                                    (Double($0.positionAlongRouteM)
                                        / Double(max(route.distanceM, 1)), $0.rarity)
                                })
                        }
                        .padding(14)
                        .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 14))
                    }

                    gemManifest
                    leaderboardSnippet

                    if let creator = route.creatorHandle {
                        Text("Created by @\(creator)")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    } else {
                        Text("A GemRun original")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .padding(16)
            }
            .background(DS.Colors.ink)
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    session.activeRoute = route
                } label: {
                    Text("Start Run")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(DS.Colors.gold, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(16)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 20) {
            stat(String(format: "%.1f km", Double(route.distanceM) / 1_000), "Distance")
            stat("\(route.elevationGainM) m", "Climb")
            stat(route.difficulty.rawValue.capitalized, "Difficulty")
            stat("\(route.runCount)", "Runs")
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

    private var gemManifest: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gems on this route")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.textPrimary)
            ForEach(route.gemDrops) { drop in
                HStack {
                    Circle()
                        .fill(DS.Colors.rarity(drop.rarity))
                        .frame(width: 10, height: 10)
                    Text(drop.rarity.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Spacer()
                    if collectedDropIDs.contains(drop.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(DS.Colors.textSecondary)
                    } else if drop.rarity != .common, drop.rarity != .uncommon {
                        Text("hidden — find it")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(14)
        .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 14))
    }

    private var leaderboardSnippet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Best times")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.textPrimary)
            if bestTimes.isEmpty {
                Text("No valid runs yet — set the first time.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                ForEach(Array(bestTimes.enumerated()), id: \.element.id) { i, run in
                    HStack {
                        Text("#\(i + 1)")
                            .foregroundStyle(DS.Colors.gold)
                        Text(format(seconds: run.durationS))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Spacer()
                        Text(run.startedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .padding(14)
        .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 14))
    }
}

func format(seconds: Int) -> String {
    seconds >= 3_600
        ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
