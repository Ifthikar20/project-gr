import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// The reward ceremony (docs/03 §8), Daybreak Pulse: one flippable run
/// card (stats on the front, the finds' real-material stories on the
/// back), honest validation states, splits, share.
struct RunSummaryView: View {
    let summary: RunCompletionSummary
    let onDone: () -> Void
    @State private var revealed = 0
    @State private var shareImage: Image?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(summary.isWalk ? "Walk complete" : "Run complete")
                    .font(DS.Typography.display(28))
                    .foregroundStyle(DS.Colors.ink)
                    .padding(.top, 32)

                RunCardView(summary: summary, revealed: revealed)
                    .padding(.horizontal, 20)

                bonusNotes

                if summary.status == .flagged || summary.status == .pending {
                    Text("We're confirming your run — gems will settle into your stash shortly.")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if summary.status == .invalid {
                    Text("This run couldn't be validated, so no gems or XP were awarded.")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.pulse)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else if summary.revokedCount > 0 {
                    Text("\(summary.revokedCount) gem\(summary.revokedCount == 1 ? "" : "s") already collected today didn't count again.")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                splitsCard

                if let shareImage {
                    ShareLink(item: shareImage,
                              preview: SharePreview("My GemRun on \(summary.routeName)",
                                                    image: shareImage)) {
                        Label("Share run card", systemImage: "square.and.arrow.up")
                            .font(DS.Typography.heading)
                            .foregroundStyle(DS.Colors.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(DS.Colors.snowCard, in: Capsule())
                            .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
                    }
                    .padding(.horizontal, 20)
                }

                PillButton("Done") { onDone() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
        .background(DS.Colors.snow.ignoresSafeArea())
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

    /// Bonus context that used to live in the XP card — now a quiet row of
    /// notes under the run card (which carries the XP number itself).
    private var bonusNotes: some View {
        VStack(spacing: 6) {
            if summary.multiplier > 1 {
                Text(String(format: "includes %.1f× streak bonus", summary.multiplier))
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            if summary.isWalk {
                Text("Walk pace — half XP, no leaderboard time")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            if summary.setBonusXP > 0, let setName = summary.completedSetName {
                Label("\(setName) set complete! +\(summary.setBonusXP) XP",
                      systemImage: "rosette")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }
            if summary.streakExtended {
                Label("\(summary.streakCount)-day streak", systemImage: "flame.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }
            if let rank = summary.leaderboardRank {
                Label("#\(rank) on this route", systemImage: "trophy")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }
        }
        .padding(.horizontal, 32)
    }

    private var splitsCard: some View {
        Group {
            if !summary.splitsS.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Splits")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                    let fastest = summary.splitsS.min() ?? 0
                    ForEach(Array(summary.splitsS.enumerated()), id: \.offset) { i, split in
                        HStack {
                            Text("mi \(i + 1)")
                                .foregroundStyle(DS.Colors.inkSecondary)
                                .frame(width: 52, alignment: .leading)
                            Text(formatDuration(split))
                                .monospacedDigit()
                                .foregroundStyle(split == fastest
                                    ? DS.Colors.pulse : DS.Colors.ink)
                            Spacer()
                            GeometryReader { geo in
                                Capsule()
                                    .fill(split == fastest
                                        ? DS.Colors.pulse : DS.Colors.pulse.opacity(0.35))
                                    .frame(width: geo.size.width
                                        * CGFloat(fastest) / CGFloat(max(split, 1)))
                            }
                            .frame(height: 6)
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .airbnbCard()
                .padding(.horizontal, 20)
            }
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
