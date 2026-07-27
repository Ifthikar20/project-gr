import CoreMap
import CoreModels
import DesignSystem
import SwiftUI

/// Tapping a gem pin on the Explore map opens this card: what the gem is,
/// its rarity, its set, and a one-line blurb about the real material.
struct GemInfoSheet: View {
    let drop: GemDrop
    /// Provided by Explore: plan a walking path to this gem and start a
    /// run that collects it. nil renders the old static pill instead.
    var onRunToGem: (() async -> Void)? = nil
    @State private var isPlanning = false

    private var entry: GemCatalog.Entry? {
        GemCatalog.entry(forGemID: drop.gemID)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(MapPalette.emoji(forGemID: drop.gemID))
                .font(.system(size: 64))
                .padding(.top, 28)

            Text(entry?.gem.name ?? "Mystery Gem")
                .font(DS.Typography.display(24))
                .foregroundStyle(DS.Colors.ink)

            HStack(spacing: 8) {
                RarityBadge(drop.rarity, size: 14)
                Text(drop.rarity.rawValue.capitalized)
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.rarity(drop.rarity))
                if let setName = entry?.setName {
                    Text("· \(setName) set")
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
            }

            if let blurb = entry?.blurb, !blurb.isEmpty {
                Text(blurb)
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            if let onRunToGem {
                Button {
                    guard !isPlanning else { return }
                    isPlanning = true
                    Task {
                        await onRunToGem()
                        isPlanning = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isPlanning {
                            ProgressView()
                                .tint(DS.Colors.snowCard)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "figure.run")
                                .font(.footnote.bold())
                        }
                        Text(isPlanning ? "Planning your path…" : "Walk or run to collect")
                            .font(.footnote.bold())
                    }
                    .foregroundStyle(DS.Colors.snowCard)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(DS.Colors.pulse, in: Capsule())
                }
                .disabled(isPlanning)
                .padding(.top, 6)
            } else {
                Text("Walk or run to it to collect")
                    .font(.footnote.bold())
                    .foregroundStyle(DS.Colors.snowCard)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(DS.Colors.pulse, in: Capsule())
                    .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(DS.Colors.snow)
    }
}
