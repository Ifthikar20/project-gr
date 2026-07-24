import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// Airbnb listing-page anatomy (docs/03 §3): full-width map hero, white sheet
/// with hairline-separated sections, sticky bottom bar with the pulse CTA.
@MainActor
struct RouteDetailView: View {
    let route: Route
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Query private var stash: [StoredStashItem]
    @Query private var runs: [StoredRun]

    private var collectedDropIDs: Set<UUID> {
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
                VStack(alignment: .leading, spacing: 0) {
                    RoutePreviewMap(route: route, collectedDropIDs: collectedDropIDs)
                        .frame(height: 300)

                    VStack(alignment: .leading, spacing: 18) {
                        header
                        divider
                        statsRow
                        if let profile = route.elevationProfile, profile.count > 2 {
                            divider
                            elevationSection(profile)
                        }
                        divider
                        gemManifest
                        divider
                        leaderboardSnippet
                        divider
                        Text(route.creatorHandle.map { "Created by @\($0)" }
                             ?? "A GemRun original")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                    .padding(20)
                }
            }
            .background(DS.Colors.snowCard)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    private var divider: some View {
        Rectangle().fill(DS.Colors.hairline).frame(height: 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.name)
                .font(DS.Typography.display(26))
                .foregroundStyle(DS.Colors.ink)
            if let description = route.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
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
                .foregroundStyle(DS.Colors.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func elevationSection(_ profile: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Elevation")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
            ElevationStrip(
                profile: profile,
                markers: route.gemDrops.map {
                    (Double($0.positionAlongRouteM) / Double(max(route.distanceM, 1)),
                     $0.rarity)
                })
        }
    }

    private var gemManifest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gems on this route")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
            ForEach(route.gemDrops) { drop in
                HStack(spacing: 10) {
                    RarityBadge(drop.rarity, size: 15)
                    Text(drop.rarity.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.ink)
                    Spacer()
                    if collectedDropIDs.contains(drop.id) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    } else if drop.rarity != .common, drop.rarity != .uncommon {
                        Text("hidden — find it")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                }
            }
        }
    }

    private var leaderboardSnippet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Best times")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
            if bestTimes.isEmpty {
                Text("No valid runs yet — set the first time.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
            } else {
                ForEach(Array(bestTimes.enumerated()), id: \.element.id) { i, run in
                    HStack {
                        Text("#\(i + 1)")
                            .foregroundStyle(DS.Colors.pulse)
                        Text(format(seconds: run.durationS))
                            .foregroundStyle(DS.Colors.ink)
                            .monospacedDigit()
                        Spacer()
                        Text(run.startedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    /// Airbnb's sticky reserve bar: facts left, one pulse pill right.
    private var bottomBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f km", Double(route.distanceM) / 1_000))
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Text(route.difficulty.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            Spacer()
            Button {
                dismiss()
                session.activeRoute = route
            } label: {
                Text("Start Run")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.snowCard)
                    .padding(.horizontal, 36)
                    .frame(height: 50)
                    .background(DS.Colors.pulse, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DS.Colors.snowCard)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
        }
    }
}

func format(seconds: Int) -> String {
    seconds >= 3_600
        ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
