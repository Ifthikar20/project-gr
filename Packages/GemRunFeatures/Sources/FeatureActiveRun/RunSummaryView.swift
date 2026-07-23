import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// The reward ceremony (docs/03 §8): gems reveal rarest-last, XP breakdown,
/// leaderboard delta, honest validation state.
struct RunSummaryView: View {
    let summary: RunCompletionSummary
    let onDone: () -> Void
    @State private var revealed = 0
    @State private var shareImage: Image?

    private var orderedGems: [RunCompletionSummary.CollectedGem] {
        let order: [Rarity] = [.common, .uncommon, .rare, .epic, .legendary]
        return summary.gems.sorted {
            (order.firstIndex(of: $0.rarity) ?? 0) < (order.firstIndex(of: $1.rarity) ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(summary.isWalk ? "Walk complete" : "Run complete")
                    .font(DS.Typography.display(28))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.top, 32)

                gemReveal

                if summary.status == .flagged || summary.status == .pending {
                    Text("We're confirming your run — gems will settle into your stash shortly.")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if summary.status == .invalid {
                    Text("This run couldn't be validated, so no gems or XP were awarded.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else if summary.revokedCount > 0 {
                    // Server verdict revoked some optimistic collections (docs/06)
                    // — e.g. a daily gem already collected today.
                    Text("\(summary.revokedCount) gem\(summary.revokedCount == 1 ? "" : "s") already collected today didn't count again.")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                xpCard
                statsCard
                splitsCard

                if let shareImage {
                    ShareLink(item: shareImage,
                              preview: SharePreview("My GemRun on \(summary.routeName)",
                                                    image: shareImage)) {
                        Label("Share run card", systemImage: "square.and.arrow.up")
                            .font(DS.Typography.heading)
                            .foregroundStyle(DS.Colors.gold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(DS.Colors.inkRaised,
                                        in: RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 20)
                }

                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(DS.Colors.gold, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(DS.Colors.ink.ignoresSafeArea())
        .onAppear {
            revealNext()
            renderShareCard()
        }
    }

    /// Renders the share card offscreen (docs/03 §8).
    @MainActor
    private func renderShareCard() {
        let renderer = ImageRenderer(content: ShareCardView(summary: summary))
        renderer.scale = 3
        if let uiImage = renderer.uiImage {
            shareImage = Image(uiImage: uiImage)
        }
    }

    private var gemReveal: some View {
        VStack(spacing: 12) {
            if summary.gems.isEmpty {
                Text("No gems this time — the route remembers you anyway.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(Array(orderedGems.enumerated()), id: \.element.id) { i, gem in
                        VStack(spacing: 6) {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(i < revealed
                                    ? DS.Colors.rarity(gem.rarity)
                                    : Color.white.opacity(0.1))
                                .scaleEffect(i < revealed ? 1 : 0.7)
                                .animation(.spring(duration: 0.5), value: revealed)
                            Text(i < revealed ? gem.name : "?")
                                .font(.caption2)
                                .foregroundStyle(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var xpCard: some View {
        VStack(spacing: 8) {
            Text("+\(summary.xpEarned) XP")
                .font(DS.Typography.statLarge)
                .foregroundStyle(DS.Colors.gold)
            if summary.multiplier > 1 {
                Text(String(format: "includes %.1f× streak bonus", summary.multiplier))
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            if summary.isWalk {
                Text("Walk pace — half XP, no leaderboard time")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            if summary.setBonusXP > 0, let setName = summary.completedSetName {
                Label("\(setName) set complete! +\(summary.setBonusXP) XP",
                      systemImage: "rosette")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.gold)
            }
            if summary.streakExtended {
                Label("\(summary.streakCount)-day streak", systemImage: "flame.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var statsCard: some View {
        HStack(spacing: 24) {
            stat(formatDuration(summary.durationS), "Time")
            stat(String(format: "%.2f km", Double(summary.distanceM) / 1_000), "Distance")
            stat(summary.paceSPerKm > 0 ? formatDuration(summary.paceSPerKm) : "–", "Pace")
            if let rank = summary.leaderboardRank {
                stat("#\(rank)", "Route rank")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var splitsCard: some View {
        Group {
            if !summary.splitsS.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Splits")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.textPrimary)
                    let fastest = summary.splitsS.min() ?? 0
                    ForEach(Array(summary.splitsS.enumerated()), id: \.offset) { i, split in
                        HStack {
                            Text("km \(i + 1)")
                                .foregroundStyle(DS.Colors.textSecondary)
                                .frame(width: 52, alignment: .leading)
                            Text(formatDuration(split))
                                .monospacedDigit()
                                .foregroundStyle(split == fastest
                                    ? DS.Colors.gold : DS.Colors.textPrimary)
                            Spacer()
                            GeometryReader { geo in
                                Capsule()
                                    .fill(split == fastest
                                        ? DS.Colors.gold : DS.Colors.gold.opacity(0.35))
                                    .frame(width: geo.size.width
                                        * CGFloat(fastest) / CGFloat(max(split, 1)))
                            }
                            .frame(height: 6)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(16)
                .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
            }
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
    }

    private func revealNext() {
        guard revealed < summary.gems.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            revealed += 1
            revealNext()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
