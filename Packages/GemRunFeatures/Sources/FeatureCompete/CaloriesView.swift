import Charts
import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftData
import SwiftUI

/// Compete › Calories (gated by Feature.caloriesInsights): burn insights
/// computed entirely on-device from stored runs — no network, no HealthKit
/// permission needed. Steps and calories are distance-based estimates
/// (CalorieRules; 70 kg assumed until a body-weight profile exists), stated
/// honestly in the footer. Tap any run to expand its technical breakdown.
struct CaloriesView: View {
    @Query(sort: \StoredRun.startedAt, order: .reverse) private var runs: [StoredRun]
    @State private var expandedID: UUID?

    var body: some View {
        Group {
            if runs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        weekTiles
                        burnChart
                        runList
                        methodFootnote
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - This week

    private var weekStart: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let sinceMonday = (weekday - cal.firstWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -sinceMonday, to: today) ?? today
    }

    private var weekRuns: [StoredRun] { runs.filter { $0.startedAt >= weekStart } }

    private var weekTiles: some View {
        let kcal = weekRuns.reduce(0) { $0 + CalorieRules.kcal(distanceM: $1.distanceM, isWalk: $1.isWalk) }
        let steps = weekRuns.reduce(0) { $0 + CalorieRules.estimatedSteps(distanceM: $1.distanceM, isWalk: $1.isWalk) }
        let seconds = weekRuns.reduce(0) { $0 + $1.durationS }
        let rate = CalorieRules.kcalPerHour(kcal: kcal, durationS: seconds)
        return HStack(spacing: 10) {
            statTile(value: "\(kcal)", unit: "kcal", label: "THIS WEEK")
            statTile(value: steps.formatted(), unit: "steps", label: "THIS WEEK")
            statTile(value: rate > 0 ? "\(rate)" : "—", unit: "kcal/h", label: "AVG BURN")
        }
    }

    private func statTile(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(DS.Colors.inkSecondary)
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .airbnbCard(padding: 12)
    }

    // MARK: - 14-day burn graph

    private struct DayBurn: Identifiable {
        let id: Date
        let kcal: Int
    }

    private var last14Days: [DayBurn] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            let kcal = runs
                .filter { $0.startedAt >= day && $0.startedAt < next }
                .reduce(0) { $0 + CalorieRules.kcal(distanceM: $1.distanceM, isWalk: $1.isWalk) }
            return DayBurn(id: day, kcal: kcal)
        }
    }

    private var burnChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily burn — last 14 days")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
            Chart(last14Days) { day in
                BarMark(x: .value("Day", day.id, unit: .day),
                        y: .value("kcal", day.kcal))
                    .foregroundStyle(day.kcal > 0
                        ? DS.Colors.pulse
                        : DS.Colors.ink.opacity(0.08))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 140)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .airbnbCard()
    }

    // MARK: - Per-run breakdown (tap to expand)

    private var runList: some View {
        VStack(spacing: 10) {
            ForEach(runs.prefix(30), id: \.id) { run in
                runRow(run)
            }
        }
    }

    private func runRow(_ run: StoredRun) -> some View {
        let kcal = CalorieRules.kcal(distanceM: run.distanceM, isWalk: run.isWalk)
        let steps = CalorieRules.estimatedSteps(distanceM: run.distanceM, isWalk: run.isWalk)
        let expanded = expandedID == run.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    expandedID = expanded ? nil : run.id
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: run.isWalk ? "figure.walk" : "figure.run")
                        .font(.title3)
                        .foregroundStyle(DS.Colors.pulse)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.routeName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(kcal) kcal")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(DS.Colors.ink)
                        Text("\(steps.formatted()) steps")
                            .font(.caption)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DS.Colors.inkSecondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            if expanded {
                technicalGrid(run, kcal: kcal, steps: steps)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .airbnbCard(padding: 14)
    }

    /// The technical readout: everything the engine knew about this effort,
    /// derived on the spot.
    private func technicalGrid(_ run: StoredRun, kcal: Int, steps: Int) -> some View {
        let miles = Double(run.distanceM) / 1_609.34
        let kcalPerMile = miles > 0.05 ? Int((Double(kcal) / miles).rounded()) : 0
        return VStack(spacing: 8) {
            Divider().overlay(DS.Colors.hairline)
            techRow("Distance", UnitFormat.milesLabel(fromMeters: Double(run.distanceM), decimals: 2))
            techRow("Duration", format(seconds: run.durationS))
            techRow("Pace", "\(format(seconds: UnitFormat.paceSecPerMile(fromSecPerKm: run.paceSPerKm))) /mi")
            techRow("Burn rate", "\(CalorieRules.kcalPerHour(kcal: kcal, durationS: run.durationS)) kcal/h")
            techRow("Energy cost", kcalPerMile > 0 ? "\(kcalPerMile) kcal/mi" : "—")
            techRow("Cadence", "\(CalorieRules.cadence(steps: steps, durationS: run.durationS)) spm")
            techRow("Type", run.isWalk ? "Walk (half XP)" : "Run")
            techRow("XP earned", "+\(run.xpEarned)")
        }
    }

    private func techRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(DS.Colors.inkSecondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.ink)
        }
    }

    private var methodFootnote: some View {
        Text("Calories and steps are estimates from distance and pace, "
             + "assuming a 70 kg runner — a body-weight profile will refine "
             + "them. Steps recorded by Apple Health appear on each run's "
             + "summary card.")
            .font(.caption2)
            .foregroundStyle(DS.Colors.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame")
                .font(.system(size: 40))
                .foregroundStyle(DS.Colors.pulse)
            Text("Finish a run and your burn rate, steps, and daily graph land here.")
                .font(.subheadline)
                .foregroundStyle(DS.Colors.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func format(seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
