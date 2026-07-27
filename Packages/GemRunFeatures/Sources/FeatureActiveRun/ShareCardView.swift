import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// The exportable run card (docs/03 §8), Daybreak Pulse: the same face the
/// in-app flip card leads with — wordmark, route, hero distance, the full
/// stat row (time · pace · steps · calories · XP), and the finds as their
/// real emojis. Rendered offscreen by ImageRenderer at 3×.
struct ShareCardView: View {
    let summary: RunCompletionSummary

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "diamond.fill")
                        .foregroundStyle(DS.Colors.pulse)
                    Text("GemRun")
                        .font(DS.Typography.display(20))
                        .foregroundStyle(DS.Colors.pulse)
                }
                Spacer()
                Text(summary.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }

            Text(summary.routeName)
                .font(DS.Typography.display(26))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(UnitFormat.milesText(fromMeters: Double(summary.distanceM)))
                            .font(DS.Typography.statLarge)
                            .foregroundStyle(DS.Colors.ink)
                            .monospacedDigit()
                        Text("mi")
                            .font(DS.Typography.heading)
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                    if !summary.gems.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(summary.gems.prefix(6)) { gem in
                                Text(MapPalette.emoji(forGemID: gem.gemID))
                                    .font(.system(size: 24))
                            }
                            if summary.gems.count > 6 {
                                Text("+\(summary.gems.count - 6)")
                                    .font(.caption.bold())
                                    .foregroundStyle(DS.Colors.inkSecondary)
                            }
                        }
                    }
                }
                Spacer()
                if let polyline = summary.pathPolyline {
                    let coords = PolylineCodec.decode(polyline)
                    if coords.count > 1 {
                        RouteShapeView(coords: coords)
                            .frame(width: 96, height: 96)
                            .background(DS.Colors.snow,
                                        in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(DS.Colors.hairline, lineWidth: 1))
                    }
                }
            }

            Rectangle().fill(DS.Colors.hairline).frame(height: 1)

            HStack(spacing: 0) {
                cardStat(time(summary.durationS), "time")
                cardStat(summary.paceSPerKm > 0
                         ? time(UnitFormat.paceSecPerMile(
                            fromSecPerKm: summary.paceSPerKm)) : "–", "pace /mi")
                if summary.steps > 0 {
                    cardStat("\(summary.steps)", "steps")
                }
                cardStat("~\(summary.approxCalories)", "kcal")
                cardStat("+\(summary.xpEarned)", "XP", accent: true)
                if let rank = summary.leaderboardRank {
                    cardStat("#\(rank)", "rank")
                }
            }

            Text("Drop gems. Run routes. Collect what others left behind.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .padding(28)
        .frame(width: 460)
        .background(DS.Colors.snowCard)
        .overlay(Rectangle().stroke(DS.Colors.hairline, lineWidth: 2))
    }

    private func cardStat(_ value: String, _ label: String,
                          accent: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(accent ? DS.Colors.pulse : DS.Colors.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func time(_ seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
