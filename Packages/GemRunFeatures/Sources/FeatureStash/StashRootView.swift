import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

/// The Collection (docs/03 §9): a swipeable deck, not a shelf. Type
/// chips filter, a menu sorts, and the cards themselves stack front and
/// center at full nine-part size — every catalog face rides the deck,
/// face-down until a mint flips it. Tap a face-up card for the sheet
/// view. Gems appear only AS cards now (the gem card type); the old
/// tiered gem grid renders solely in legacy mode (runner_cards flag
/// OFF), where this screen is still the gem stash.
@MainActor
public struct StashRootView: View {
    @Environment(SessionStore.self) private var session
    @Query(sort: \StoredStashItem.collectedAt, order: .reverse) private var items: [StoredStashItem]
    @Query(sort: \StoredRunnerCard.mintedAt, order: .reverse) private var cards: [StoredRunnerCard]
    @State private var detail: StoredStashItem?
    @State private var cardDetail: StoredRunnerCard?
    /// Deck controls: nil type = every card; order defaults to the
    /// commonest-first rarity read.
    @State private var typeFilter: CardType?
    @State private var deckOrder: DeckOrder = .rarity

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
                    // Just the count — no "/49". The binder below carries
                    // the pull; a printed ceiling only makes it feel small.
                    Text("\(Set(cards.map(\.cardID)).count)")
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

    /// The deck screen: type chips, then a hint bar with the sort menu,
    /// then the collection as a swipeable stack. Every face in the chosen
    /// category rides the deck — full nine-part card if minted, full-size
    /// card back if not — so zero cards still deals a deck worth flipping
    /// through.
    private var cardWall: some View {
        VStack(alignment: .leading, spacing: 18) {
            typeChips
            hintBar
            CardDeckView(slots: deckSlots,
                         art: { cardArt($0) },
                         onOpen: { cardDetail = $0 })
                .frame(maxWidth: .infinity)
                // A filter or order change deals a fresh deck from the top.
                .id("\(typeFilter?.rawValue ?? "all")-\(deckOrder.rawValue)")
        }
    }

    /// The screenshot-style filter row: round icon chips, one per card
    /// type plus All, the selected one filled with the accent.
    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                typeChip(nil)
                ForEach(CardType.allCases) { typeChip($0) }
            }
            .padding(.horizontal, 2)
        }
    }

    private func typeChip(_ type: CardType?) -> some View {
        let selected = typeFilter == type
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                typeFilter = type
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: type.map { CardPalette.glyph($0) }
                    ?? "square.grid.2x2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? DS.Colors.snowCard : DS.Colors.ink)
                    .frame(width: 54, height: 54)
                    .background(selected ? DS.Colors.pulse : DS.Colors.snowCard,
                                in: Circle())
                    .overlay(Circle().stroke(
                        selected ? DS.Colors.pulse : DS.Colors.hairline,
                        lineWidth: 1))
                Text(type?.displayName ?? "All")
                    .font(selected ? .caption.bold() : .caption)
                    .foregroundStyle(selected ? DS.Colors.ink : DS.Colors.inkSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// One contextual line + the order menu — the deck's only chrome.
    private var hintBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk")
                .font(.subheadline.bold())
                .foregroundStyle(DS.Colors.ink)
            Text(hintText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Menu {
                Picker("Order", selection: $deckOrder) {
                    ForEach(DeckOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(deckOrder.label)
                    Image(systemName: "chevron.down")
                }
                .font(.caption.bold())
                .foregroundStyle(DS.Colors.pulse)
            }
        }
        .airbnbCard(padding: 14)
    }

    private var hintText: String {
        let slots = deckSlots
        let minted = slots.filter {
            if case .minted = $0 { true } else { false }
        }.count
        if minted == 0 {
            return "Walk a mile inside a zone to mint your first card."
        }
        if minted < slots.count {
            return "Swipe the deck — face-down cards flip when you mint them."
        }
        return "Every face here is found. Keep walking for copies."
    }

    /// Newest mint per face (cards come newest-first from the query), so
    /// a flipped slot always shows the most recent copy.
    private var newestMintByFace: [UUID: StoredRunnerCard] {
        var map: [UUID: StoredRunnerCard] = [:]
        for card in cards where map[card.cardID] == nil {
            map[card.cardID] = card
        }
        return map
    }

    /// Every catalog face in the chosen category, one slot each — minted
    /// faces carry their newest mint and copy count. Rarity order reads
    /// commonest-first with found cards ahead of face-down ones per tier;
    /// newest puts your mints first; A to Z ignores the flip state.
    private var deckSlots: [DeckSlot] {
        let newest = newestMintByFace
        let copies = cards.reduce(into: [UUID: Int]()) {
            $0[$1.cardID, default: 0] += 1
        }
        let faces = RunnerCardCatalog.entries
            .filter { typeFilter == nil || $0.type == typeFilter }
        let slots = faces.map { face -> DeckSlot in
            if let stored = newest[face.cardID] {
                return .minted(stored, copies: copies[face.cardID] ?? 1)
            }
            return .hidden(face)
        }
        func tierRank(_ r: Rarity) -> Int { Self.tiers.firstIndex(of: r) ?? 0 }
        switch deckOrder {
        case .rarity:
            return slots.sorted { a, b in
                if tierRank(a.rarity) != tierRank(b.rarity) {
                    return tierRank(a.rarity) < tierRank(b.rarity)
                }
                if (a.mintedAt != nil) != (b.mintedAt != nil) {
                    return a.mintedAt != nil
                }
                return a.name < b.name
            }
        case .newest:
            return slots.sorted { a, b in
                switch (a.mintedAt, b.mintedAt) {
                case let (x?, y?): return x > y
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none):
                    return tierRank(a.rarity) != tierRank(b.rarity)
                        ? tierRank(a.rarity) < tierRank(b.rarity)
                        : a.name < b.name
                }
            }
        case .name:
            return slots.sorted { $0.name < $1.name }
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

/// How the deck orders its cards — the "sorting" half of the controls.
enum DeckOrder: String, CaseIterable, Identifiable {
    case rarity, newest, name

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rarity: "By rarity"
        case .newest: "Newest first"
        case .name: "A to Z"
        }
    }
}

/// One position in the deck: a face you've minted (with how many copies
/// you hold) or one still face-down.
enum DeckSlot: Identifiable {
    case minted(StoredRunnerCard, copies: Int)
    case hidden(RunnerCardCatalog.Entry)

    var id: UUID {
        switch self {
        case .minted(let stored, _): stored.cardID
        case .hidden(let entry): entry.cardID
        }
    }

    var name: String {
        switch self {
        case .minted(let stored, _): stored.name
        case .hidden(let entry): entry.name
        }
    }

    var rarity: Rarity {
        switch self {
        case .minted(let stored, _): stored.rarity
        case .hidden(let entry): entry.rarity
        }
    }

    var mintedAt: Date? {
        switch self {
        case .minted(let stored, _): stored.mintedAt
        case .hidden: nil
        }
    }
}

/// The collection as a swipeable stack: the current card front and
/// center at full nine-part size, the next few fanned behind it — the
/// Instant-Workouts deck grammar. Swipe left for the next card, right
/// for the previous; tap a minted card for its sheet.
@MainActor
struct CardDeckView: View {
    let slots: [DeckSlot]
    let art: (StoredRunnerCard) -> AnyView?
    let onOpen: (StoredRunnerCard) -> Void

    @State private var index = 0
    @State private var dragX: CGFloat = 0

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(Array(windowSlots.enumerated()),
                        id: \.element.id) { depth, slot in
                    deckCard(slot)
                        .scaleEffect(depth == 0 ? 1 : 1 - CGFloat(depth) * 0.05)
                        .offset(x: depth == 0
                            ? dragX
                            : (depth.isMultiple(of: 2) ? -10 : 10)
                                * CGFloat(min(depth, 2)))
                        .rotationEffect(.degrees(depth == 0
                            ? Double(dragX) / 24
                            : (depth.isMultiple(of: 2) ? -1.8 : 1.8)))
                        .zIndex(Double(-depth))
                        .allowsHitTesting(depth == 0)
                }
            }
            // minimumDistance 20 leaves vertical drags to the ScrollView;
            // sideways swipes past ±70 pt turn the deck.
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { dragX = $0.translation.width }
                    .onEnded { value in
                        let dx = value.translation.width
                        withAnimation(.spring(response: 0.38,
                                              dampingFraction: 0.8)) {
                            if dx < -70, index < slots.count - 1 {
                                index += 1
                            } else if dx > 70, index > 0 {
                                index -= 1
                            }
                            dragX = 0
                        }
                    })
            if slots.count > 1 { pager }
        }
        .padding(.top, 8)
    }

    /// The front card plus up to three fanned behind it.
    private var windowSlots: [DeckSlot] {
        guard !slots.isEmpty else { return [] }
        let start = min(index, slots.count - 1)
        return Array(slots[start..<min(start + 4, slots.count)])
    }

    @ViewBuilder
    private func deckCard(_ slot: DeckSlot) -> some View {
        switch slot {
        case .minted(let stored, let copies):
            RunnerCardView(card: stored.toRunnerCard(), art: art(stored))
                .overlay(alignment: .topTrailing) {
                    if copies > 1 {
                        Text("×\(copies)")
                            .font(.caption.bold())
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.snowCard)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(DS.Colors.pulse, in: Capsule())
                            .offset(x: 6, y: -10)
                    }
                }
                .onTapGesture { onOpen(stored) }
        case .hidden(let entry):
            FullCardBack(entry: entry)
        }
    }

    /// Dots while they fit; a quiet position bar for a long deck — the
    /// deck never prints a count.
    private var pager: some View {
        Group {
            if slots.count <= 10 {
                HStack(spacing: 7) {
                    ForEach(slots.indices, id: \.self) { i in
                        Circle()
                            .fill(i == index ? DS.Colors.pulse : DS.Colors.hairline)
                            .frame(width: 7, height: 7)
                    }
                }
            } else {
                Capsule()
                    .fill(DS.Colors.hairline)
                    .frame(width: 120, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.pulse)
                            .frame(width: 24, height: 4)
                            .offset(x: CGFloat(index)
                                / CGFloat(max(slots.count - 1, 1)) * 96)
                    }
            }
        }
    }
}

/// A face not yet minted, at deck scale: the card back — snow face,
/// rarity edge, bolt emblem — with only the rarity and drop odds as the
/// tease. Same footprint recipe as RunnerCardView so the deck keeps its
/// shape whatever mix of found and hidden it deals.
@MainActor
struct FullCardBack: View {
    let entry: RunnerCardCatalog.Entry

    var body: some View {
        let edge = CardPalette.edge(entry.rarity)
        VStack(spacing: 18) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(edge)
                .shadow(color: edge.opacity(0.35), radius: 12)
            Text("???")
                .font(DS.Typography.display(30))
                .foregroundStyle(DS.Colors.inkSecondary)
            HStack(spacing: 6) {
                RarityBadge(entry.rarity, size: 13)
                Text("\(entry.rarity.rawValue.capitalized) · \(entry.dropNote)")
                    .font(.caption.bold())
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(DS.Colors.snow, in: Capsule())
        }
        .frame(maxWidth: .infinity, minHeight: 480)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(DS.Colors.snowCard)
                .shadow(color: DS.Colors.ink.opacity(0.14), radius: 18, y: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(edge.opacity(0.55), lineWidth: 1.5))
        .frame(maxWidth: 320)
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
