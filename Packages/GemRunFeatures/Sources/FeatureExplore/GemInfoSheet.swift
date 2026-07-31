import CoreMap
import CoreModels
import DesignSystem
import SwiftUI

/// Tapping a gem pin on the Explore map opens this card: what the gem is,
/// its rarity, and a rotating real fact about the material.
struct GemInfoSheet: View {
    let drop: GemDrop
    /// Provided by Explore: plan a walking path to this gem and start a
    /// run that collects it. nil renders the old static pill instead.
    var onRunToGem: (() async -> Void)? = nil
    @State private var isPlanning = false
    /// Raw ever-incrementing counter for this gem's fact rotation; the
    /// shown fact is facts[factIndex % facts.count].
    @State private var factIndex = 0

    private var entry: GemCatalog.Entry? {
        GemCatalog.entry(forGemID: drop.gemID)
    }

    /// Per-gem rotation, persisted: every open of this card shows the NEXT
    /// fact (survives relaunches), and tapping the fact advances it live.
    private func bumpFactCounter() -> Int {
        let key = "gemrun.gemFact.\(drop.gemID.uuidString)"
        let defaults = UserDefaults.standard
        let counter = defaults.integer(forKey: key)
        defaults.set(counter + 1, forKey: key)
        return counter
    }

    var body: some View {
        VStack(spacing: 16) {
            GemIcon(gemID: drop.gemID, size: 92)
                .padding(.top, 30)

            Text(entry?.gem.name ?? "Mystery Gem")
                .font(DS.Typography.display(27))
                .foregroundStyle(DS.Colors.ink)

            HStack(spacing: 8) {
                RarityBadge(drop.rarity, size: 14)
                Text("\(drop.rarity.rawValue.capitalized) gem")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.rarity(drop.rarity))
            }

            if let facts = entry?.facts, !facts.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        factIndex = bumpFactCounter()
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(facts[factIndex % facts.count])
                            .font(.callout)
                            .foregroundStyle(DS.Colors.inkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        if facts.count > 1 {
                            Label("Tap for another fact", systemImage: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DS.Colors.pulse)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .buttonStyle(.plain)
                .onAppear { factIndex = bumpFactCounter() }
            }

            if let onRunToGem {
                // Tinted by THIS gem's tier — the button itself reads as the
                // rarity you're about to chase.
                RarityButton(isPlanning ? "Planning your path…" : "Walk or run to collect",
                             rarity: drop.rarity, isLoading: isPlanning) {
                    guard !isPlanning else { return }
                    isPlanning = true
                    Task {
                        await onRunToGem()
                        isPlanning = false
                    }
                }
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
