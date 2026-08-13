import CoreModels
import SwiftUI

/// The card system's colors, straight off the landing page: one `edge`
/// color per rarity drives every accent on a card (pip, band, ability
/// icon, found-most bar, sheen) — mirror of the site's `--edge` variable —
/// plus a pastel wash per type for default art.
public enum CardPalette {
    public static func edge(_ rarity: Rarity) -> Color {
        switch rarity {
        case .common: Color(red: 0.604, green: 0.608, blue: 0.631)      // #9a9ba1
        case .uncommon: Color(red: 0.341, green: 0.722, blue: 0.471)    // #57b878
        case .rare: Color(red: 0.310, green: 0.561, blue: 0.878)        // #4f8fe0
        case .epic: Color(red: 0.608, green: 0.435, blue: 0.878)        // #9b6fe0
        case .legendary: Color(red: 0.878, green: 0.651, blue: 0.227)   // #e0a63a
        }
    }

    public static func wash(_ type: CardType) -> Color {
        switch type {
        case .gem: Color(red: 0.875, green: 0.914, blue: 0.984)         // #dfe9fb
        case .gear: Color(red: 0.992, green: 0.941, blue: 0.855)        // #fdf0da
        case .creature: Color(red: 0.871, green: 0.949, blue: 0.894)    // #def2e4
        case .artifact: Color(red: 0.902, green: 0.890, blue: 0.984)    // #e6e3fb
        case .fact: Color(red: 0.984, green: 0.902, blue: 0.941)        // #fbe6f0
        }
    }

    public static func glyph(_ type: CardType) -> String {
        switch type {
        case .gem: "diamond.fill"
        case .gear: "shoe.fill"
        case .creature: "pawprint.fill"
        case .artifact: "seal.fill"
        case .fact: "book.fill"
        }
    }
}

/// A minted Runner Card, rendered with the landing page's nine-part
/// anatomy: stage pill · name + XP · art · rarity band · three run-stat
/// tiles · ability · found-most bar · flavor · footer with serial. The
/// catalog face fills the static parts; the mint's stats fill the rest.
/// `art` lets callers inject real artwork (gem faces pass GemIcon);
/// the default is the type glyph on its pastel wash.
@MainActor
public struct RunnerCardView: View {
    let card: RunnerCard
    let art: AnyView?

    private var face: RunnerCardCatalog.Entry? {
        RunnerCardCatalog.entry(forCardID: card.cardID)
    }

    private var edge: Color { CardPalette.edge(card.rarity) }

    public init(card: RunnerCard, art: AnyView? = nil) {
        self.card = card
        self.art = art
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            artBlock
            band
            statTiles
            if let face { ability(face) }
            if let face { foundMost(face) }
            flavor
            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(DS.Colors.snowCard)
                .shadow(color: DS.Colors.ink.opacity(0.14), radius: 18, y: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(edge.opacity(0.55), lineWidth: 1.5))
        .frame(maxWidth: 320)
    }

    private var topRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Stage \(face?.stage ?? 1)")
                .font(.caption2.bold())
                .foregroundStyle(DS.Colors.inkSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DS.Colors.ink.opacity(0.05), in: Capsule())
            Text(card.name)
                .font(DS.Typography.display(19))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text("\(card.stats.xpEarned)")
                .font(DS.Typography.display(19))
                .foregroundStyle(edge)
            + Text(" XP")
                .font(.caption2.bold())
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private var artBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CardPalette.wash(card.type))
            if let art {
                art
            } else {
                Image(systemName: CardPalette.glyph(card.type))
                    .font(.system(size: 56))
                    .foregroundStyle(edge)
                    .shadow(color: DS.Colors.snowCard.opacity(0.8), radius: 6)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var band: some View {
        HStack(spacing: 6) {
            Circle().fill(edge).frame(width: 8, height: 8)
            Text("\(card.rarity.rawValue.capitalized) \(card.type.displayName) · \(card.zoneName) zone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(edge.opacity(0.12), in: Capsule())
    }

    private var statTiles: some View {
        HStack(spacing: 8) {
            statTile(value: String(format: "%.1f", Double(card.stats.distanceM) / 1_000),
                     label: "km walked")
            statTile(value: card.stats.steps > 0 ? "\(card.stats.steps)" : "—",
                     label: "steps")
            statTile(value: "+\(card.stats.xpEarned)", label: "xp gained",
                     highlighted: true)
        }
    }

    private func statTile(value: String, label: String,
                          highlighted: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(highlighted ? edge : DS.Colors.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(DS.Colors.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func ability(_ face: RunnerCardCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption.bold())
                    .foregroundStyle(edge)
                Text(face.abilityName)
                    .font(.footnote.bold())
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Text(face.abilityValue)
                    .font(.footnote.bold())
                    .foregroundStyle(edge)
            }
            Text(face.abilityText)
                .font(.caption2)
                .foregroundStyle(DS.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(DS.Colors.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func foundMost(_ face: RunnerCardCatalog.Entry) -> some View {
        HStack(spacing: 8) {
            Text("found most")
                .font(.caption2.bold())
                .foregroundStyle(DS.Colors.inkSecondary)
            Text(face.foundMostWhere)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.ink.opacity(0.08))
                    Capsule().fill(edge)
                        .frame(width: geo.size.width
                            * Double(face.foundMostPct) / 100)
                }
            }
            .frame(height: 5)
            Text("\(face.foundMostPct)%")
                .font(.caption2.bold())
                .monospacedDigit()
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    private var flavor: some View {
        Text(face?.flavor ?? "Minted on foot, kept forever.")
            .font(.caption.italic())
            .foregroundStyle(DS.Colors.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack {
            Text("illus. RUNNERCARD · \(face?.dropNote ?? "on foot")")
            Spacer()
            Text("\(String(format: "%03d", card.serial)) / \(face?.printRun ?? 500)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(DS.Colors.inkSecondary)
    }
}

/// The back of a Runner Card at chip scale — what flies to the binder in
/// the mint ceremony, and the pre-reveal face in the flip.
@MainActor
public struct MiniCardBack: View {
    let rarity: Rarity
    var size: CGFloat = 46

    public init(rarity: Rarity, size: CGFloat = 46) {
        self.rarity = rarity
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .fill(DS.Colors.snowCard)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .stroke(CardPalette.edge(rarity), lineWidth: 2))
            .overlay(
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(CardPalette.edge(rarity)))
            .frame(width: size, height: size * 1.35)
            .shadow(color: DS.Colors.ink.opacity(0.2), radius: 5, y: 2)
    }
}

/// Reveal presentation: the card back flips into the front — the sheet
/// both Explore and the binder use for a fresh mint.
@MainActor
public struct MintRevealView: View {
    let card: RunnerCard
    let art: AnyView?
    @State private var revealed = false

    public init(card: RunnerCard, art: AnyView? = nil) {
        self.card = card
        self.art = art
    }

    public var body: some View {
        VStack(spacing: 18) {
            Text(revealed ? "Minted in \(card.zoneName)" : "Card minted!")
                .font(DS.Typography.heading)
                .foregroundStyle(DS.Colors.ink)
                .contentTransition(.opacity)
            ZStack {
                if revealed {
                    RunnerCardView(card: card, art: art)
                        .rotation3DEffect(.degrees(revealed ? 0 : -90),
                                          axis: (x: 0, y: 1, z: 0),
                                          perspective: 0.3)
                } else {
                    MiniCardBack(rarity: card.rarity, size: 120)
                        .rotation3DEffect(.degrees(revealed ? 90 : 0),
                                          axis: (x: 0, y: 1, z: 0),
                                          perspective: 0.3)
                }
            }
            Text("Walked into your binder — yours forever.")
                .font(.footnote)
                .foregroundStyle(DS.Colors.inkSecondary)
                .opacity(revealed ? 1 : 0)
        }
        .padding(.vertical, 20)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)
                .delay(0.35)) {
                revealed = true
            }
        }
    }
}
