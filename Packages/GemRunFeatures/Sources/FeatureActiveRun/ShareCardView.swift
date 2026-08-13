import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI
import UIKit

/// The exportable run card (docs/03 §8), Daybreak Pulse: the same face the
/// in-app flip card leads with — wordmark, route, hero distance, the full
/// stat row (time · pace · steps · calories · XP), and the finds as their
/// real emojis. Rendered offscreen by ImageRenderer at 3×.
struct ShareCardView: View {
    let summary: RunCompletionSummary
    /// Real street snapshot of the traveled track (TrackSnapshotter) —
    /// nil (offline, no track) falls back to the abstract route shape.
    var mapImage: UIImage? = nil

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(DS.Colors.pulse)
                    Text("RUNNERCARD")
                        .font(DS.Typography.display(20))
                        .kerning(1.5)
                        .foregroundStyle(DS.Colors.pulse)
                }
                Spacer()
                Text(summary.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }

            // Hero: the actual streets you ran, with the headline distance
            // overlaid — same trading-card anatomy as the in-app flip card.
            ZStack {
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .scaledToFill()
                } else if let polyline = summary.pathPolyline {
                    let coords = PolylineCodec.decode(polyline)
                    if coords.count > 1 {
                        RouteShapeView(coords: coords)
                    }
                } else {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(DS.Colors.pulse.opacity(0.10))
                }
                VStack {
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(UnitFormat.milesText(fromMeters: Double(summary.distanceM)))
                            .font(DS.Typography.statLarge)
                            .foregroundStyle(DS.Colors.ink)
                            .monospacedDigit()
                        Text("mi")
                            .font(DS.Typography.heading)
                            .foregroundStyle(DS.Colors.inkSecondary)
                        Spacer()
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(DS.Colors.snow, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(DS.Colors.hairline, lineWidth: 1))

            HStack(spacing: 8) {
                Text(summary.routeName)
                    .font(DS.Typography.display(24))
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
            }

            HStack(spacing: 8) {
                tile(time(summary.durationS), "Time")
                tile(summary.paceSPerKm > 0
                     ? time(UnitFormat.paceSecPerMile(
                        fromSecPerKm: summary.paceSPerKm)) : "–", "Pace /mi")
                tile(summary.steps > 0 ? "\(summary.steps)" : "–", "Steps")
            }
            HStack(spacing: 8) {
                tile("~\(summary.approxCalories)", "Calories")
                tile("+\(summary.xpEarned)", "XP", accent: true)
                if let rank = summary.leaderboardRank {
                    tile("#\(rank)", "Rank")
                } else {
                    tile("\(summary.gems.count)", "Gems")
                }
            }

            if !summary.gems.isEmpty {
                HStack(spacing: 8) {
                    ForEach(summary.gems.prefix(8)) { gem in
                        GemIcon(gemID: gem.gemID, size: 26)
                    }
                    if summary.gems.count > 8 {
                        Text("+\(summary.gems.count - 8)")
                            .font(.caption.bold())
                            .foregroundStyle(DS.Colors.inkSecondary)
                    }
                }
            }

            Text("Walk the zone. Mint the card. Yours forever.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .padding(26)
        .frame(width: 460)
        .background(DS.Colors.snowCard)
        .overlay(Rectangle().stroke(DS.Colors.hairline, lineWidth: 2))
    }

    /// Caps label on top, number under — the same stat-tile the in-app
    /// card uses, so the export matches what the runner saw.
    private func tile(_ value: String, _ label: String,
                      accent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(DS.Colors.inkSecondary)
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(accent ? DS.Colors.pulse : DS.Colors.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(DS.Colors.snow, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private func time(_ seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
