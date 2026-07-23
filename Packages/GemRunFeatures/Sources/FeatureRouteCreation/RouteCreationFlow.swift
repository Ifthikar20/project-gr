import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftData
import SwiftUI

/// The 3-step creation flow: draw → place gems → publish (docs/03 §4–6).
public struct RouteCreationFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = CreationModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .draw: DrawStepView(model: model)
                case .gems: GemPlacementStepView(model: model)
                case .publish: PublishStepView(model: model, onDone: { dismiss() })
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
@Observable
final class CreationModel {
    enum Step { case draw, gems, publish }

    var step: Step = .draw
    var waypoints: [Coordinate] = []
    var pathCoords: [Coordinate] = []
    var placedDrops: [GemDrop] = []
    var selectedRarity: Rarity = .common
    var name = ""
    var descriptionText = ""
    var placementError: String?
    private var snapping = false

    var geometry: RouteGeometry { RouteGeometry(coordinates: pathCoords) }
    var distanceM: Int { Int(geometry.totalLengthM) }

    var slotsUsed: Int { placedDrops.count }
    var slotsTotal: Int { PlacementBudget.slots(forDistanceM: distanceM) }
    var pointsUsed: Int { placedDrops.compactMap { PlacementBudget.cost(of: $0.rarity) }.reduce(0, +) }
    var pointsTotal: Int { PlacementBudget.points(forDistanceM: distanceM) }

    var difficulty: RouteDifficulty {
        switch distanceM {
        case ..<4_000: .easy
        case ..<9_000: .moderate
        default: .hard
        }
    }

    func addWaypoint(_ c: Coordinate) {
        let previous = waypoints.last
        waypoints.append(c)
        guard let previous else {
            pathCoords = [c]
            return
        }
        guard !snapping else { return }
        snapping = true
        Task {
            // Snap to walkable paths via MKDirections; straight-line fallback.
            let segment = await PathSnapper.snap(from: previous, to: c)
            pathCoords.append(contentsOf: segment.dropFirst())
            snapping = false
        }
    }

    func undoWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        // Re-snap from scratch is overkill for MVP: truncate the path to the
        // last remaining waypoint's nearest vertex.
        if let last = waypoints.last {
            let g = RouteGeometry(coordinates: pathCoords)
            let along = g.project(last).alongRouteM
            var kept: [Coordinate] = []
            for (i, c) in pathCoords.enumerated() where g.cumulative[i] <= along + 1 {
                kept.append(c)
            }
            pathCoords = kept.isEmpty ? [last] : kept
        } else {
            pathCoords = []
        }
    }

    /// Budget + spacing + rarity-position rules (docs/02), with kind rejections.
    func placeGem(at tapped: Coordinate) {
        placementError = nil
        let projection = geometry.project(tapped)
        guard projection.crossTrackM < 60 else {
            placementError = "Tap closer to your route to place a gem."
            return
        }
        guard slotsUsed < slotsTotal else {
            placementError = "No gem slots left (1 per 250 m of route)."
            return
        }
        guard let cost = PlacementBudget.cost(of: selectedRarity) else {
            placementError = "Legendary gems are seeded by GemRun — they can't be placed."
            return
        }
        guard pointsUsed + cost <= pointsTotal else {
            placementError = "Not enough rarity points left for \(selectedRarity.rawValue)."
            return
        }
        let alongM = projection.alongRouteM
        if placedDrops.contains(where: {
            abs(Double($0.positionAlongRouteM) - alongM) < Double(PlacementBudget.minGemSpacingM)
        }) {
            placementError = "Too close to another gem (100 m minimum)."
            return
        }
        if selectedRarity == .rare || selectedRarity == .epic {
            guard alongM >= geometry.totalLengthM * PlacementBudget.rareMinRouteFraction else {
                placementError = "Rare and Epic gems must be at least 40% into the route."
                return
            }
        }
        // Without elevation data (local-first), the Epic hard-segment rule
        // (docs/02) approximates to: Epics only on routes ≥ 8 km. Server
        // validates against real elevation in Phase F.
        if selectedRarity == .epic, distanceM < 8_000 {
            placementError = "Epics need a hard route — at least 8 km for now."
            return
        }
        let snapped = geometry.coordinate(atDistance: alongM)
        placedDrops.append(GemDrop(
            id: UUID(), gemID: GemCatalog.gem(of: selectedRarity).id, rarity: selectedRarity,
            lat: snapped.lat, lng: snapped.lng, positionAlongRouteM: Int(alongM),
            respawnRule: selectedRarity == .common || selectedRarity == .uncommon
                ? .daily : .oncePerUser,
            placedBy: .creator))
    }

    func buildRoute(creatorHandle: String?) -> Route {
        Route(id: UUID(), name: name.isEmpty ? "Untitled Route" : name,
              description: descriptionText.isEmpty ? nil : descriptionText,
              polyline: PolylineCodec.encode(pathCoords),
              distanceM: distanceM, elevationGainM: 0,
              difficulty: difficulty, creatorHandle: creatorHandle,
              gemDrops: placedDrops.sorted { $0.positionAlongRouteM < $1.positionAlongRouteM })
    }
}
