import CoreModels
import DesignSystem
import GameKitCore
import SwiftUI

/// The zone's own card: how far along the mile you are, what can mint
/// here, and the rules in one honest line. Presented from a tap on the
/// zone's chip or anywhere inside its circle.
@MainActor
struct ZoneSheet: View {
    let zone: RunnerZone
    let progressM: Double
    let targetM: Double

    private var fraction: Double { min(progressM / max(targetM, 1), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(zone.name)
                    .font(DS.Typography.display(26))
                    .foregroundStyle(DS.Colors.ink)
                Text("Today's zone · fresh line-up tomorrow")
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UnitFormat.milesLabel(fromMeters: progressM, decimals: 2))
                        .font(DS.Typography.display(22))
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.ink)
                    Text("of \(targetLabel) mints a card")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Colors.inkSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Colors.ink.opacity(0.08))
                        Capsule().fill(DS.Colors.map)
                            .frame(width: max(geo.size.width * fraction,
                                              fraction > 0 ? 6 : 0))
                    }
                }
                .frame(height: 8)
            }
            .padding(14)
            .background(DS.Colors.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("What can mint here")
                    .font(.footnote.bold())
                    .foregroundStyle(DS.Colors.ink)
                HStack(spacing: 10) {
                    ForEach(CardType.allCases) { type in
                        VStack(spacing: 4) {
                            Image(systemName: CardPalette.glyph(type))
                                .font(.system(size: 18))
                                .foregroundStyle(DS.Colors.ink.opacity(0.7))
                                .frame(width: 40, height: 40)
                                .background(CardPalette.wash(type),
                                            in: RoundedRectangle(
                                                cornerRadius: 12,
                                                style: .continuous))
                            Text(type.displayName)
                                .font(.caption2)
                                .foregroundStyle(DS.Colors.inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text("Common ~6 in 10 · Uncommon ~1 in 4 · Rare ~1 in 12 · Epic ~1 in 60 · Legendary ~1 in 900")
                    .font(.caption2)
                    .foregroundStyle(DS.Colors.inkSecondary)
            }

            Label {
                Text("Distance counts while you're on the map or on a run — walking pace, good GPS. Up to \(ZoneRules.maxMintsPerZonePerDay) cards per zone per day.")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
            } icon: {
                Image(systemName: "figure.walk")
                    .font(.caption.bold())
                    .foregroundStyle(DS.Colors.pulse)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDragIndicator(.visible)
    }

    private var targetLabel: String {
        abs(targetM - UnitFormat.metersPerMile) < 1 ? "1 mile"
            : "\(Int(targetM)) m"
    }
}
