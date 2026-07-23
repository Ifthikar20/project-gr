import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// The exportable run card (docs/03 §8), rendered offscreen by ImageRenderer.
struct ShareCardView: View {
    let summary: RunCompletionSummary

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill")
                    .foregroundStyle(DS.Colors.gold)
                Text("GemRun")
                    .font(DS.Typography.display(20))
                    .foregroundStyle(DS.Colors.gold)
            }
            Text(summary.routeName)
                .font(DS.Typography.display(26))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
            HStack(spacing: 10) {
                ForEach(summary.gems) { gem in
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(DS.Colors.rarity(gem.rarity))
                }
                if summary.gems.isEmpty {
                    Text("Route completed")
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
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
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(28)
        .frame(width: 420)
        .background(DS.Colors.ink)
        .overlay(RoundedRectangle(cornerRadius: 0)
            .stroke(DS.Colors.gold.opacity(0.4), lineWidth: 2))
    }

    private func cardStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private func time(_ seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
