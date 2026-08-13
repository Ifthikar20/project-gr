import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// The Collection (docs/03 §9): your minted Runner Cards, and nothing
/// else — the wall of minis the landing page promises, newest first, tap
/// for the full card. Gems appear only AS cards now (the gem card type);
/// the old tiered gem grid renders solely in legacy mode (runner_cards
/// flag OFF), where this screen is still the gem stash.
@MainActor
public struct StashRootView: View {
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredStashItem.collectedAt, order: .reverse) private var items: [StoredStashItem]
    @Query(sort: \StoredRunnerCard.mintedAt, order: .reverse) private var cards: [StoredRunnerCard]
    @State private var detail: StoredStashItem?
    @State private var cardDetail: StoredRunnerCard?

    public init() {}

    private var cardsOn: Bool { FeatureFlags.shared.isEnabled(.runnerCards) }

    /// Commonest first — the natural reading order for a collection.
    private static let tiers: [Rarity] = [.common, .uncommon, .rare, .epic, .legendary]

    private var tierSections: [(tier: Rarity, entries: [GemCatalog.Entry])] {
        Self.tiers.compactMap { tier in
            let entries = GemCatalog.entries
                .filter { $0.gem.rarity == tier }
                .sorted { $0.gem.name < $1.gem.name }
            return entries.isEmpty ? nil : (tier, entries)
        }
    }

    private func collected(for gemID: UUID) -> StoredStashItem? {
        items.first { $0.gemID == gemID }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if cardsOn {
                        cardWall
                    } else {
                        ForEach(tierSections, id: \.tier) { section in
                            tierSection(section.tier, section.entries)
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await session.refreshStash() }
            .background(DS.Colors.snow)
            .navigationTitle("Collection")
            .task { await session.refreshStash() }
            .sheet(item: $detail) { item in
                GemDetailSheet(item: item)
                    .presentationDetents([.medium])
            }
            .sheet(item: $cardDetail) { stored in
                ScrollView {
                    RunnerCardView(card: stored.toRunnerCard(),
                                   art: cardArt(stored))
                        .padding(20)
                }
                .background(DS.Colors.snow)
                .presentationDetents([.large])
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            if cardsOn {
                // Cards are the whole collection now — gems only appear
                // AS cards, so the header speaks cards alone.
                VStack(alignment: .leading) {
                    Text("\(cards.count)")
                        .font(DS.Typography.statMedium)
                        .foregroundStyle(DS.Colors.ink)
                    Text("cards minted")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
                VStack(alignment: .leading) {
                    Text("\(Set(cards.map(\.cardID)).count)/\(RunnerCardCatalog.entries.count)")
                        .font(DS.Typography.statMedium)
                        .foregroundStyle(DS.Colors.ink)
                    Text("faces found")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
            } else {
                VStack(alignment: .leading) {
                    Text("\(items.count)")
                        .font(DS.Typography.statMedium)
                        .foregroundStyle(DS.Colors.ink)
                    Text("gems collected")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
                VStack(alignment: .leading) {
                    Text("\(Set(items.map(\.gemID)).count)/\(GemCatalog.entries.count)")
                        .font(DS.Typography.statMedium)
                        .foregroundStyle(DS.Colors.ink)
                    Text("unique found")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
            }
            Spacer()
        }
        .airbnbCard()
    }

    /// Real gem artwork on gem-backed faces; nil keeps the type glyph.
    private func cardArt(_ stored: StoredRunnerCard) -> AnyView? {
        guard let face = RunnerCardCatalog.entry(forCardID: stored.cardID),
              let gemID = face.gemID else { return nil }
        return AnyView(GemIcon(gemID: gemID, size: 84))
    }

    /// The wall of minis: every minted card, newest first. Tap for the
    /// full nine-part card. The screen title carries the name — the wall
    /// needs no header of its own.
    private var cardWall: some View {
        Group {
            if cards.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No cards yet")
                        .font(.subheadline.bold())
                        .foregroundStyle(DS.Colors.ink)
                    Text("Walk a mile inside a zone on the map to mint your first card.")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .airbnbCard(padding: 14)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                         count: 3),
                          spacing: 12) {
                    ForEach(cards) { stored in
                        MiniCardTile(stored: stored)
                            .onTapGesture { cardDetail = stored }
                    }
                }
            }
        }
    }

    private func tierSection(_ tier: Rarity, _ entries: [GemCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let found = entries.filter { collected(for: $0.gem.id) != nil }.count
            HStack(spacing: 8) {
                RarityBadge(tier, size: 14)
                Text("\(tier.rawValue.capitalized) gems")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Text("\(found)/\(entries.count)")
                    .font(.caption.bold())
                    .foregroundStyle(found == entries.count
                        ? DS.Colors.pulse : DS.Colors.inkSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                      spacing: 12) {
                ForEach(entries, id: \.gem.id) { entry in
                    let item = collected(for: entry.gem.id)
                    VStack(spacing: 4) {
                        if item != nil {
                            GemIcon(gemID: entry.gem.id, size: 32)
                                .frame(height: 36)
                        } else {
                            Image(systemName: DS.rarityGlyph(entry.gem.rarity))
                                .font(.system(size: 32))
                                .foregroundStyle(DS.Colors.hairline)   // silhouette: the pull
                                .frame(height: 36)
                        }
                        Text(item != nil ? entry.gem.name : "???")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.inkSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: DS.Colors.ink.opacity(0.06), radius: 8, y: 2)
                    .onTapGesture {
                        if let item { detail = item }
                    }
                }
            }
        }
    }
}

/// One minted card as a wall mini: edge-framed tile, type art, name, XP —
/// the landing page's binder-wall unit.
@MainActor
struct MiniCardTile: View {
    let stored: StoredRunnerCard

    var body: some View {
        let edge = CardPalette.edge(stored.rarity)
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CardPalette.wash(stored.type))
                Image(systemName: CardPalette.glyph(stored.type))
                    .font(.system(size: 22))
                    .foregroundStyle(edge)
            }
            .frame(height: 54)
            Text(stored.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
            Text("\(stored.rarity.rawValue.capitalized) · \(stored.stats.xpEarned) XP")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.Colors.inkSecondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(edge.opacity(0.5), lineWidth: 1.5))
        .shadow(color: DS.Colors.ink.opacity(0.06), radius: 8, y: 2)
    }
}

/// A collected gem's card: icon, name, tier, a rotating real-material fact
/// (same per-gem rotation the map pins use — every open shows the next
/// one), and where you found it.
struct GemDetailSheet: View {
    let item: StoredStashItem
    /// Raw ever-incrementing counter; shown fact = facts[factIndex % count].
    @State private var factIndex = 0

    private var entry: GemCatalog.Entry? {
        GemCatalog.entry(forGemID: item.gemID)
    }

    /// Shared with the map's gem card (same UserDefaults key), so the
    /// rotation continues across surfaces instead of resetting.
    private func bumpFactCounter() -> Int {
        let key = "gemrun.gemFact.\(item.gemID.uuidString)"
        let defaults = UserDefaults.standard
        let counter = defaults.integer(forKey: key)
        defaults.set(counter + 1, forKey: key)
        return counter
    }

    var body: some View {
        VStack(spacing: 14) {
            GemIcon(gemID: item.gemID, size: 72)
                .padding(.top, 24)
            Text(item.gemName)
                .font(DS.Typography.display(24))
                .foregroundStyle(DS.Colors.ink)
            HStack(spacing: 8) {
                RarityBadge(item.rarity, size: 14)
                Text("\(item.rarity.rawValue.capitalized) gem")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.rarity(item.rarity))
            }
            if item.isFirstFind {
                Label("First find", systemImage: "crown.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }
            if let facts = entry?.facts, !facts.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        factIndex = bumpFactCounter()
                    }
                } label: {
                    VStack(spacing: 5) {
                        Text(facts[factIndex % facts.count])
                            .font(.subheadline)
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
            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                .padding(.horizontal, 32)
            VStack(spacing: 4) {
                if item.routeName == "Welcome gift" {
                    Label("Welcome gift, free gems for joining", systemImage: "gift.fill")
                        .foregroundStyle(DS.Colors.pulse)
                } else {
                    Text("Collected on \(item.routeName)")
                        .foregroundStyle(DS.Colors.ink)
                }
                Text(item.collectedAt, style: .date)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(DS.Colors.snowCard)
    }
}
