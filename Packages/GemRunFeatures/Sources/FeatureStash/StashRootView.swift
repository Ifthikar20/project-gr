import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// The collection (docs/03 §9), Airbnb wishlist-grid style: white tiles on
/// snow, grouped by rarity tier (Common → Legendary) so the buckets read
/// plainly; ink-tint silhouettes for the missing.
@MainActor
public struct StashRootView: View {
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredStashItem.collectedAt, order: .reverse) private var items: [StoredStashItem]
    @State private var detail: StoredStashItem?

    public init() {}

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
                    ForEach(tierSections, id: \.tier) { section in
                        tierSection(section.tier, section.entries)
                    }
                }
                .padding(16)
            }
            .refreshable { await session.refreshStash() }
            .background(DS.Colors.snow)
            .navigationTitle("Stash")
            .task { await session.refreshStash() }
            .sheet(item: $detail) { item in
                GemDetailSheet(item: item)
                    .presentationDetents([.medium])
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
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
            Spacer()
        }
        .airbnbCard()
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
                    Label("Welcome gift — free gems for joining", systemImage: "gift.fill")
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
