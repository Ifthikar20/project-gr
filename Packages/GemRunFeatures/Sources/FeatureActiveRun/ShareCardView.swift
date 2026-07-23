import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// The exportable run card (docs/03 §8), Daybreak Pulse: snow surface, ink
/// type, pulse gems. Rendered offscreen by ImageRenderer.
struct ShareCardView: View {
    let summary: RunCompletionSummary

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .foregroundStyle(DS.Colors.pulse)
                Text("GemRun")
                    .font(DS.Typography.display(20))
                    .foregroundStyle(DS.Colors.pulse)
            }
            Text(summary.routeName)
                .font(DS.Typography.display(26))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
            HStack(spacing: 12) {
                ForEach(summary.gems) { gem in
                    Image(systemName: DS.rarityGlyph(gem.rarity))
                        .font(.system(size: 30))
                        .foregroundStyle(DS.Colors.rarity(gem.rarity))
                }
                if summary.gems.isEmpty {
                    Text("Route completed")
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
            }
            HStack(spacing: 22) {
                cardStat(time(summary.durationS), "time")
                cardStat(String(format: "%.2f km", Double(summary.distanceM) / 1_000), "distance")
                cardStat("+\(summary.xpEarned)", "XP")
                if let rank = summary.leaderboardRank {
                    cardStat("#\(rank)", "rank")
                }
            }
            Text("Drop gems. Run routes. Collect what others left behind.")
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .padding(28)
        .frame(width: 420)
        .background(DS.Colors.snowCard)
        .overlay(Rectangle().stroke(DS.Colors.hairline, lineWidth: 2))
    }

    private func cardStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(DS.Colors.ink)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private func time(_ seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
