import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// The collection (docs/03 §9), Airbnb wishlist-grid style: white tiles on
/// snow, rarity as pulse ramp + glyph, ink-tint silhouettes for the missing.
@MainActor
public struct StashRootView: View {
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredStashItem.collectedAt, order: .reverse) private var items: [StoredStashItem]
    @State private var detail: StoredStashItem?
    @State private var isSyncing = false

    public init() {}

    private var sets: [(name: String, entries: [GemCatalog.Entry])] {
        Dictionary(grouping: GemCatalog.entries, by: \.setName)
            .map { (name: $0.key, entries: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func collected(for gemID: UUID) -> StoredStashItem? {
        items.first { $0.gemID == gemID }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    walletCard
                    header
                    ForEach(sets, id: \.name) { set in
                        setSection(set.name, set.entries)
                    }
                }
                .padding(16)
            }
            .background(DS.Colors.snow)
            .navigationTitle("Stash")
            .task { await session.refreshWallet() }
            .sheet(item: $detail) { item in
                GemDetailSheet(item: item)
                    .presentationDetents([.medium])
            }
        }
    }

    /// The gem wallet: gems earned by running (Apple Health), ready to drop
    /// anywhere from the Explore map. Everyone starts at zero.
    private var walletCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gem wallet")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Button {
                    isSyncing = true
                    Task {
                        await session.refreshWallet()
                        isSyncing = false
                    }
                } label: {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync Health", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                            .foregroundStyle(DS.Colors.pulse)
                    }
                }
            }
            if session.wallet.values.reduce(0, +) == 0 {
                Text("Empty — every 1.2 miles you run earns a gem to drop. Sync with Apple Health to collect what you've already earned.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            } else {
                HStack(spacing: 14) {
                    ForEach([Rarity.common, .uncommon, .rare, .epic], id: \.self) { rarity in
                        if let count = session.wallet[rarity], count > 0 {
                            HStack(spacing: 4) {
                                RarityBadge(rarity, size: 14)
                                Text("×\(count)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(DS.Colors.ink)
                            }
                        }
                    }
                    Spacer()
                    Text("drop them from the map")
                        .font(.caption2)
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
            }
        }
        .airbnbCard()
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

    private func setSection(_ name: String, _ entries: [GemCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let found = entries.filter { collected(for: $0.gem.id) != nil }.count
            HStack {
                Text(name)
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
                        Image(systemName: DS.rarityGlyph(entry.gem.rarity))
                            .font(.system(size: 32))
                            .foregroundStyle(item != nil
                                ? DS.Colors.rarity(entry.gem.rarity)
                                : DS.Colors.hairline)   // silhouette: the pull
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

struct GemDetailSheet: View {
    let item: StoredStashItem

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: DS.rarityGlyph(item.rarity))
                .font(.system(size: 72))
                .foregroundStyle(DS.Colors.rarity(item.rarity))
                .padding(.top, 24)
            Text(item.gemName)
                .font(DS.Typography.display(24))
                .foregroundStyle(DS.Colors.ink)
            Text("\(item.rarity.rawValue.capitalized) · \(item.setName) set")
                .font(.subheadline)
                .foregroundStyle(DS.Colors.inkSecondary)
            if item.isFirstFind {
                Label("First find", systemImage: "crown.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }
            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                .padding(.horizontal, 32)
            VStack(spacing: 4) {
                Text("Collected on \(item.routeName)")
                    .foregroundStyle(DS.Colors.ink)
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
