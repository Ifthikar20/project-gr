import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftUI

/// Rough energy estimate from distance alone (no body-weight profile yet):
/// ~1.03 kcal/kg/km running, ~0.53 walking, 70 kg assumed. Shared by the
/// summary card and the exported share card.
extension RunCompletionSummary {
    var approxCalories: Int {
        let km = Double(distanceM) / 1_000
        return Int(km * 70 * (isWalk ? 0.53 : 1.03))
    }
}

/// The shape of the run: the completed path drawn as a clean pulse stroke,
/// normalized into whatever frame it's given (planar-scaled so it isn't
/// squashed, start dot in ink, finish dot in pulse). Pure Path drawing, so
/// ImageRenderer exports it identically on the share card.
struct RouteShapeView: View {
    let coords: [Coordinate]

    var body: some View {
        GeometryReader { geo in
            let pts = normalized(into: geo.size)
            if pts.count > 1 {
                Path { p in
                    p.move(to: pts[0])
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(DS.Colors.pulse,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round,
                                           lineJoin: .round))
                Circle()
                    .fill(DS.Colors.ink)
                    .frame(width: 7, height: 7)
                    .position(pts[0])
                Circle()
                    .fill(DS.Colors.pulse)
                    .overlay(Circle().stroke(DS.Colors.snowCard, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(pts[pts.count - 1])
            }
        }
    }

    private func normalized(into size: CGSize) -> [CGPoint] {
        guard coords.count > 1,
              let minLat = coords.map(\.lat).min(),
              let maxLat = coords.map(\.lat).max(),
              let minLng = coords.map(\.lng).min(),
              let maxLng = coords.map(\.lng).max() else { return [] }
        // Planar meters so a north-south run isn't drawn squashed.
        let kLat = 111_320.0
        let kLng = kLat * cos((minLat + maxLat) / 2 * .pi / 180)
        let spanX = max(1, (maxLng - minLng) * kLng)
        let spanY = max(1, (maxLat - minLat) * kLat)
        let inset = 0.12 * min(size.width, size.height)
        let scale = min((size.width - 2 * inset) / spanX,
                        (size.height - 2 * inset) / spanY)
        let offsetX = (size.width - spanX * scale) / 2
        let offsetY = (size.height - spanY * scale) / 2
        return coords.map { c in
            CGPoint(x: offsetX + (c.lng - minLng) * kLng * scale,
                    y: size.height - offsetY - (c.lat - minLat) * kLat * scale)
        }
    }
}

/// The run card (docs/03 §8), Daybreak Pulse: a single flippable card.
/// Front = the run's numbers, from steps to calories to collected gems,
/// plus the shape of the path you completed. Back = the finds themselves —
/// each gem's emoji, rarity, set, and its real-material blurb. Tap (or the
/// corner button) flips with a 3D spring.
struct RunCardView: View {
    let summary: RunCompletionSummary
    /// Sequential-reveal counter owned by RunSummaryView's ceremony timer:
    /// front-face gem emojis pop in one by one, rarest last.
    let revealed: Int
    @State private var isFlipped = false

    var body: some View {
        ZStack {
            front
                .opacity(isFlipped ? 0 : 1)
                .accessibilityHidden(isFlipped)
            back
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
                .accessibilityHidden(!isFlipped)
        }
        .frame(height: 500)
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0),
                          axis: (x: 0, y: 1, z: 0), perspective: 0.3)
        .contentShape(Rectangle())
        .onTapGesture { flip() }
        .accessibilityAction(named: isFlipped ? "Show run stats" : "Show gem details") {
            flip()
        }
    }

    private func flip() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            isFlipped.toggle()
        }
    }

    private var orderedGems: [RunCompletionSummary.CollectedGem] {
        let order: [Rarity] = [.common, .uncommon, .rare, .epic, .legendary]
        return summary.gems.sorted {
            (order.firstIndex(of: $0.rarity) ?? 0) < (order.firstIndex(of: $1.rarity) ?? 0)
        }
    }

    private var pathCoords: [Coordinate] {
        guard let polyline = summary.pathPolyline else { return [] }
        return PolylineCodec.decode(polyline)
    }

    // MARK: front — trading-card anatomy

    /// Hero panel (the "player photo"): the shape of the path you actually
    /// ran, drawn large, with the headline distance overlaid. Falls back to
    /// a faint diamond watermark when no track exists.
    private var hero: some View {
        ZStack {
            if pathCoords.count > 1 {
                RouteShapeView(coords: pathCoords)
            } else {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 70))
                    .foregroundStyle(DS.Colors.pulse.opacity(0.10))
            }
            VStack {
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(UnitFormat.milesText(fromMeters: Double(summary.distanceM)))
                        .font(DS.Typography.statLarge)
                        .foregroundStyle(DS.Colors.ink)
                        .monospacedDigit()
                    Text("mi")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.inkSecondary)
                    Spacer()
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .background(DS.Colors.snow, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private var front: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "diamond.fill")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.pulse)
                    Text("GEMRUN")
                        .font(.caption.bold())
                        .kerning(1.2)
                        .foregroundStyle(DS.Colors.pulse)
                }
                Spacer()
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }

            hero

            HStack(spacing: 8) {
                Text(summary.routeName)
                    .font(DS.Typography.display(20))
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(summary.isWalk ? "WALK" : "RUN")
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(0.8)
                    .foregroundStyle(DS.Colors.snowCard)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(DS.Colors.pulse, in: Capsule())
            }

            HStack(spacing: 8) {
                tile(formatDuration(summary.durationS), "Time")
                tile(summary.paceSPerKm > 0
                     ? formatDuration(UnitFormat.paceSecPerMile(
                        fromSecPerKm: summary.paceSPerKm)) : "–", "Pace /mi")
                tile(summary.steps > 0 ? "\(summary.steps)" : "–", "Steps")
            }
            HStack(spacing: 8) {
                tile("~\(summary.approxCalories)", "Calories")
                tile("+\(summary.xpEarned)", "XP", accent: true)
                tile("\(summary.gems.count)", "Gems")
            }

            Group {
                if summary.gems.isEmpty {
                    Text("No gems this time — the route remembers you anyway.")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(Array(orderedGems.prefix(8).enumerated()),
                                id: \.element.id) { i, gem in
                            GemIcon(gemID: gem.gemID, size: 26)
                                .scaleEffect(i < revealed ? 1 : 0.3)
                                .opacity(i < revealed ? 1 : 0)
                                .animation(.spring(duration: 0.45), value: revealed)
                        }
                        if orderedGems.count > 8 {
                            Text("+\(orderedGems.count - 8)")
                                .font(.caption.bold())
                                .foregroundStyle(DS.Colors.inkSecondary)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2.bold())
                Text(summary.gems.isEmpty ? "Tap to flip" : "Tap to meet your finds")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(DS.Colors.pulse)
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(DS.Colors.hairline, lineWidth: 1))
        .shadow(color: DS.Colors.ink.opacity(0.12), radius: 16, y: 6)
    }

    /// Baseball-card stat tile: small caps label on top, the number under
    /// it, on its own soft panel — snow on snow-card, hairline stroked.
    private func tile(_ value: String, _ label: String,
                      accent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(DS.Colors.inkSecondary)
            Text(value)
                .font(DS.Typography.statMedium)
                .foregroundStyle(accent ? DS.Colors.pulse : DS.Colors.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(DS.Colors.snow, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(DS.Colors.hairline, lineWidth: 1))
    }

    private var cardDivider: some View {
        Rectangle().fill(DS.Colors.hairline).frame(height: 1)
    }

    // MARK: back — the finds

    /// One row per distinct gem type; duplicates collapse into a ×N badge
    /// so the blurb isn't repeated.
    private struct Find: Identifiable {
        let gem: RunCompletionSummary.CollectedGem
        let count: Int
        var id: UUID { gem.id }
    }

    private var groupedFinds: [Find] {
        var counts: [UUID: Int] = [:]
        var firsts: [RunCompletionSummary.CollectedGem] = []
        for gem in orderedGems {
            if counts[gem.gemID] == nil { firsts.append(gem) }
            counts[gem.gemID, default: 0] += 1
        }
        return firsts.map { Find(gem: $0, count: counts[$0.gemID] ?? 1) }
    }

    private var back: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your finds")
                    .font(DS.Typography.heading)
                    .foregroundStyle(DS.Colors.ink)
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }

            if summary.gems.isEmpty {
                Spacer()
                Text("Nothing collected this run. Gems respawn where runners go — the next map open restocks the area.")
                    .font(.subheadline)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedFinds.enumerated()),
                                id: \.element.id) { i, find in
                            if i > 0 { cardDivider }
                            findRow(find.gem, count: find.count)
                                .padding(.vertical, 10)
                        }
                    }
                }
                Text("Every gem is a real material — its story travels with it.")
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .background(DS.Colors.snowCard, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(DS.Colors.hairline, lineWidth: 1))
        .shadow(color: DS.Colors.ink.opacity(0.12), radius: 16, y: 6)
    }

    private func findRow(_ gem: RunCompletionSummary.CollectedGem,
                         count: Int) -> some View {
        let entry = GemCatalog.entry(forGemID: gem.gemID)
        return HStack(alignment: .top, spacing: 12) {
            GemIcon(gemID: gem.gemID, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(gem.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(DS.Colors.ink)
                    if count > 1 {
                        Text("×\(count)")
                            .font(.caption.bold())
                            .foregroundStyle(DS.Colors.pulse)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: DS.rarityGlyph(gem.rarity))
                        .font(.caption2)
                    Text("\(gem.rarity.rawValue.capitalized) gem")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(DS.Colors.rarity(gem.rarity))
                if let blurb = entry?.blurb, !blurb.isEmpty {
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
