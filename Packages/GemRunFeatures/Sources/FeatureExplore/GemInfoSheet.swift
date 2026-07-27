import CoreMap
import CoreModels
import DesignSystem
import SwiftUI

/// Tapping a gem pin on the Explore map opens this card: what the gem is,
/// its rarity, its set, and a one-line blurb about the real material.
struct GemInfoSheet: View {
    let drop: GemDrop

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

            Text("Walk or run to it to collect")
                .font(.footnote.bold())
                .foregroundStyle(DS.Colors.snowCard)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(DS.Colors.pulse, in: Capsule())
                .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(DS.Colors.snow)
    }
}
