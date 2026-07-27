import CoreLocation
import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import GameKitCore
import SwiftData
import SwiftUI

/// The 3-step creation flow: draw → place gems → publish (docs/03 §4–6).
@MainActor
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
    }
}

@MainActor
@Observable
final class CreationModel {
    enum Step { case draw, gems, publish }
    enum PlanMode { case draw, destination }

    var step: Step = .draw
    var planMode: PlanMode = .draw
    var waypoints: [Coordinate] = []
    var pathCoords: [Coordinate] = []
    /// Along-route stretches where MKDirections could NOT confirm a walking
    /// path (straight-line fallback). Gems are refused here — an unverified
    /// segment may cross private land (docs/13 §2).
    var unsnappedRangesM: [ClosedRange<Double>] = []
    var placedDrops: [GemDrop] = []
    var selectedRarity: Rarity = .common
    var name = ""
    var descriptionText = ""
    var placementError: String?
    private var snapping = false

    // Destination mode: start (current location or a typed address) → pin.
    var destination: Coordinate?
    var startAddress = ""
    /// nil = "use my current location" (the default).
    var customStart: Coordinate?
    var planError: String?
    var isPlanning = false

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

    /// Destination mode: a map tap drops the destination pin and the route
    /// snaps from the start point to it.
    func setDestination(_ c: Coordinate) {
        destination = c
        Task { await planToDestination() }
    }

    func useCurrentLocationStart() {
        customStart = nil
        startAddress = ""
        Task { await planToDestination() }
    }

    /// Geocode a typed address into the start point.
    func geocodeStart() async {
        let query = startAddress.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            useCurrentLocationStart()
            return
        }
        planError = nil
        let placemarks = try? await CLGeocoder().geocodeAddressString(query)
        guard let location = placemarks?.first?.location else {
            planError = "Couldn't find that address."
            return
        }
        customStart = Coordinate(lat: location.coordinate.latitude,
                                 lng: location.coordinate.longitude)
        await planToDestination()
    }

    private func planToDestination() async {
        guard let destination else { return }
        planError = nil
        let start: Coordinate
        if let customStart {
            start = customStart
        } else if let here = CLLocationManager().location {
            start = Coordinate(lat: here.coordinate.latitude,
                               lng: here.coordinate.longitude)
        } else {
            planError = "Waiting for your location — or type a start address."
            return
        }
        isPlanning = true
        defer { isPlanning = false }
        let result = await PathSnapper.snapVerified(from: start, to: destination)
        waypoints = [start, destination]
        pathCoords = result.path
        unsnappedRangesM = result.snapped
            ? [] : [0...RouteGeometry(coordinates: result.path).totalLengthM]
    }

    func addWaypoint(_ c: Coordinate) {
        let previous = waypoints.last
        waypoints.append(c)
        guard let previous else {
            pathCoords = [c]
            unsnappedRangesM = []
            return
        }
        guard !snapping else { return }
        snapping = true
        Task {
            // Snap to walkable paths via MKDirections; a straight-line
            // fallback is recorded as an unverified stretch (no gems there).
            let result = await PathSnapper.snapVerified(from: previous, to: c)
            let startM = geometry.totalLengthM
            pathCoords.append(contentsOf: result.path.dropFirst())
            if !result.snapped {
                unsnappedRangesM.append(startM...geometry.totalLengthM)
            }
            snapping = false
        }
    }

    func undoWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        Task { await rebuildPath() }
    }

    /// Full re-snap of the path through all remaining waypoints.
    private func rebuildPath() async {
        guard !snapping else { return }
        snapping = true
        defer { snapping = false }
        guard let first = waypoints.first else {
            pathCoords = []
            unsnappedRangesM = []
            return
        }
        var rebuilt = [first]
        var ranges: [ClosedRange<Double>] = []
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let result = await PathSnapper.snapVerified(from: a, to: b)
            let startM = RouteGeometry(coordinates: rebuilt).totalLengthM
            rebuilt.append(contentsOf: result.path.dropFirst())
            if !result.snapped {
                ranges.append(startM...RouteGeometry(coordinates: rebuilt).totalLengthM)
            }
        }
        pathCoords = rebuilt
        unsnappedRangesM = ranges
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
        if unsnappedRangesM.contains(where: { $0.contains(alongM) }) {
            placementError = "This stretch isn't a confirmed walking path — place the gem on a snapped section."
            return
        }
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
            placementError = "Epics need a hard route — at least 5 miles for now."
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
