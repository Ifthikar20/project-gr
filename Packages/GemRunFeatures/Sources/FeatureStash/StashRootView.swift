import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// The collection (docs/03 §9): grid grouped by set, silhouettes for missing
/// gems, provenance detail sheet.
public struct StashRootView: View {
    @Query(sort: \StoredStashItem.collectedAt, order: .reverse) private var items: [StoredStashItem]
    @State private var detail: StoredStashItem?

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
                    header
                    ForEach(sets, id: \.name) { set in
                        setSection(set.name, set.entries)
                    }
                }
                .padding(16)
            }
            .background(DS.Colors.ink)
            .navigationTitle("Stash")
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
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("gems collected")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            VStack(alignment: .leading) {
                Text("\(Set(items.map(\.gemID)).count)/\(GemCatalog.entries.count)")
                    .font(DS.Typography.statMedium)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("unique found")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    private func setSection(_ name: String, _ entries: [GemCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let found = entries.filter { collected(for: $0.gem.id) != nil }.count
            HStack {
                Text(name)
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                Text("\(found)/\(entries.count)")
                    .font(.caption)
                    .foregroundStyle(found == entries.count ? DS.Colors.gold : DS.Colors.textSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                      spacing: 12) {
                ForEach(entries, id: \.gem.id) { entry in
                    let item = collected(for: entry.gem.id)
                    VStack(spacing: 4) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(item != nil
                                ? DS.Colors.rarity(entry.gem.rarity)
                                : Color.white.opacity(0.1))   // silhouette: the pull
                        Text(item != nil ? entry.gem.name : "???")
                            .font(.caption2)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(DS.Colors.inkRaised, in: RoundedRectangle(cornerRadius: 12))
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
            Image(systemName: "diamond.fill")
                .font(.system(size: 72))
                .foregroundStyle(DS.Colors.rarity(item.rarity))
                .padding(.top, 24)
            Text(item.gemName)
                .font(DS.Typography.display(24))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("\(item.rarity.rawValue.capitalized) · \(item.setName) set")
                .font(.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
            if item.isFirstFind {
                Label("First find", systemImage: "crown.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(DS.Colors.gold)
            }
            Divider().overlay(DS.Colors.textSecondary.opacity(0.3))
            VStack(spacing: 4) {
                Text("Collected on \(item.routeName)")
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(item.collectedAt, style: .date)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(DS.Colors.ink)
    }
}
