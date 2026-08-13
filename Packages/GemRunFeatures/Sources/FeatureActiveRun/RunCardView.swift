import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import MapKit
import SwiftUI

/// Energy estimate shared by the summary card, the exported share card, and
/// Compete › Calories — one model (CalorieRules), stated once.
extension RunCompletionSummary {
    var approxCalories: Int {
        CalorieRules.kcal(distanceM: distanceM, isWalk: isWalk)
    }
}

/// The shape of the run: the completed path drawn as a clean route-ink
/// stroke (deep violet — the light-surface path color), normalized into
/// whatever frame it's given (planar-scaled so it isn't squashed, start
/// dot in ink, finish dot in route ink). Pure Path drawing, so
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
                .stroke(DS.Colors.routeInk,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round,
                                           lineJoin: .round))
                Circle()
                    .fill(DS.Colors.ink)
                    .frame(width: 7, height: 7)
                    .position(pts[0])
                Circle()
                    .fill(DS.Colors.routeInk)
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

/// The run drawn on a real, muted street map — the card's hero. Static:
/// no interaction, no controls; just streets for context, the deep-violet
/// route line (light surface → route ink), an ink start dot and a
/// route-ink finish dot.
struct RunRouteMap: View {
    let coords: [Coordinate]

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            MapPolyline(coordinates: coords.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            })
            .stroke(DS.Colors.routeInk,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                       lineJoin: .round))
            if let first = coords.first {
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: first.lat, longitude: first.lng)) {
                    Circle()
                        .fill(DS.Colors.ink)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(DS.Colors.snowCard, lineWidth: 2))
                }
            }
            if let last = coords.last, coords.count > 1 {
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: last.lat, longitude: last.lng)) {
                    Circle()
                        .fill(DS.Colors.routeInk)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(DS.Colors.snowCard, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// Route bounds + 45% breathing room, with a floor so a short loop
    /// doesn't zoom into a single intersection.
    private var region: MKCoordinateRegion {
        let lats = coords.map(\.lat)
        let lngs = coords.map(\.lng)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90))
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.004, (maxLat - minLat) * 1.45),
                longitudeDelta: max(0.004, (maxLng - minLng) * 1.45)))
    }
}

/// The run card (docs/03 §8), Daybreak Pulse: a single flippable card.
/// Front = the route on a real muted street map (full-bleed hero) over
/// three headline stats — distance, duration, avg pace — with the quieter
/// numbers (steps, calories, XP) on one caption line and the gem reveal
/// strip. Back = the finds themselves — each gem's icon, tier, and its
/// real-material blurb. Tap flips with a 3D spring.
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
        .frame(height: 545)
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

    // MARK: front — real map hero, three headline stats

    /// The hero: the path you actually ran drawn on a real, muted street
    /// map (full-bleed to the card's top edge, non-interactive so the
    /// card's tap-to-flip still works). Faint diamond watermark when the
    /// run has no track. The bottom edge dissolves into the card through
    /// a soft blur + wash so map and stats read as one surface.
    private var mapHero: some View {
        ZStack {
            if pathCoords.count > 1 {
                RunRouteMap(coords: pathCoords)
            } else {
                DS.Colors.snow
                Image(systemName: "diamond.fill")
                    .font(.system(size: 70))
                    .foregroundStyle(DS.Colors.pulse.opacity(0.10))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .overlay(alignment: .bottom) {
            // Blend seam: a gradient-masked blur over the map's last
            // ~64 pt, plus a wash of the card color on top of it.
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.clear, .black],
                                         startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [DS.Colors.snowCard.opacity(0),
                                        DS.Colors.snowCard.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 64)
        }
        .allowsHitTesting(false)
    }

    private var front: some View {
        VStack(spacing: 0) {
            mapHero

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(summary.routeName)
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }

                HStack(alignment: .top, spacing: 10) {
                    heroStat(UnitFormat.milesText(fromMeters: Double(summary.distanceM)),
                             "mi", "DISTANCE")
                    heroStat(formatDuration(summary.durationS),
                             summary.durationS >= 3_600 ? "hr" : "min", "DURATION")
                    heroStat(summary.paceSPerKm > 0
                             ? formatDuration(UnitFormat.paceSecPerMile(
                                fromSecPerKm: summary.paceSPerKm)) : "–",
                             "/mi", "AVG PACE")
                }

                HStack(alignment: .top, spacing: 10) {
                    heroStat(summary.steps > 0
                             ? summary.steps.formatted() : "–", "", "STEPS")
                    heroStat("~\(summary.approxCalories)", "cal", "CALORIES")
                    heroStat("\(summary.gems.count)", "", "GEMS")
                }

                Text(extrasLine)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
                    .lineLimit(1)

                Group {
                    if summary.gems.isEmpty {
                        Text("No gems this time. The route remembers you anyway.")
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.bold())
                    Text(summary.gems.isEmpty ? "Tap to flip" : "Tap to meet your finds")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(DS.Colors.pulse)
                .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .background(DS.Colors.snowCard)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .stroke(DS.Colors.hairline, lineWidth: 1))
        .shadow(color: DS.Colors.ink.opacity(0.12), radius: 16, y: 6)
    }

    /// Date + XP, one quiet line under the stat rows: "Jul 30 · +75 XP".
    private var extrasLine: String {
        "\(summary.startedAt.formatted(date: .abbreviated, time: .omitted))"
        + " · +\(summary.xpEarned) XP"
    }

    /// Reference-style stat: small caps label above, big number with a
    /// quiet unit suffix under it.
    private func heroStat(_ value: String, _ unit: String,
                          _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.0)
                .foregroundStyle(DS.Colors.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(DS.Typography.statMedium)
                    .foregroundStyle(DS.Colors.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Nothing collected this run. Fresh gems appear along popular paths every day.")
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
                Text("Every gem is a real material. Its story travels with it.")
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
