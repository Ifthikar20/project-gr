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

    /// One verified segment between consecutive numbered dots. `options`
    /// holds every walkable alternate MKDirections offered for the pair —
    /// never empty, because an unwalkable leg is rejected instead of stored.
    /// The drawn path is `options[chosenIndex]`; "Another path" advances it.
    struct Leg {
        let options: [[Coordinate]]
        var chosenIndex: Int
        var path: [Coordinate] { options[chosenIndex] }
    }

    var step: Step = .draw
    var planMode: PlanMode = .draw
    var waypoints: [Coordinate] = []
    /// Idle invariant: legs.count == max(0, waypoints.count - 1). While the
    /// snap worker drains, trailing waypoints briefly outnumber legs.
    var legs: [Leg] = []
    var placedDrops: [GemDrop] = []
    var selectedRarity: Rarity = .common
    var name = ""
    var descriptionText = ""
    var placementError: String?
    /// Transient "No walkable path to that spot." style message; auto-clears.
    var pathNotice: String?
    /// Draw-mode "Finding a walkable path…" indicator (worker lifetime).
    var isSnapping = false
    @ObservationIgnored private var snapWorker: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // Destination mode: start (current location or a typed address) → pin.
    var destination: Coordinate?
    var destinationPath: [Coordinate] = []
    var startAddress = ""
    /// nil = "use my current location" (the default).
    var customStart: Coordinate?
    var planError: String?
    var isPlanning = false
    @ObservationIgnored private var planGeneration = 0

    /// Single source of truth for the drawn/published polyline, derived per
    /// mode. Draw mode concatenates the chosen path of each verified leg —
    /// unverified geometry is structurally impossible here.
    var pathCoords: [Coordinate] {
        switch planMode {
        case .draw:
            guard let first = waypoints.first else { return [] }
            var out = [first]
            for leg in legs { out.append(contentsOf: leg.path.dropFirst()) }
            return out
        case .destination:
            return destinationPath
        }
    }

    /// "Another path" is offered only for the most recent settled leg, and
    /// only when MKDirections actually returned more than one option.
    var canCycleAlternate: Bool {
        !isSnapping && (legs.last?.options.count ?? 0) > 1
    }

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
        let placemarks: [CLPlacemark]?
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(query)
        } catch {
            // Distinguish "no such address" from "geocoder unreachable" —
            // the same UI copy hid two different problems.
            GemLog.map.error("geocode failed: \(String(describing: error), privacy: .public)")
            planError = "Couldn't look up that address — check your connection."
            return
        }
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
        // Generation token: rapid re-pinning can finish out of order, and an
        // older plan must never overwrite a newer pin's result.
        planGeneration += 1
        let generation = planGeneration
        isPlanning = true
        defer { isPlanning = false }
        let result = await PathSnapper.snapVerified(from: start, to: destination)
        guard generation == planGeneration else { return }
        guard result.snapped else {
            // Never keep the straight-line fallback: an unreachable pin is
            // rejected outright, and a fresh tap is the retry gesture.
            self.destination = nil
            destinationPath = []
            planError = "No walkable path there — try a closer pin."
            return
        }
        destinationPath = result.path
    }

    /// Draw mode: the numbered dot appears instantly; the serial worker
    /// verifies a walking path to it and rejects the dot if none exists.
    func addWaypoint(_ c: Coordinate) {
        waypoints.append(c)
        ensureSnapWorker()
    }

    /// One drain loop resolves pending legs strictly in order. Everything
    /// runs on the main actor, so between awaits nothing interleaves and
    /// each iteration's read-check-mutate is atomic. Rapid taps queue
    /// naturally; undo and rejections re-shape the queue and the loop just
    /// re-derives the next job from live state — legs can never silently
    /// desync from waypoints.
    private func ensureSnapWorker() {
        guard snapWorker == nil, waypoints.count - 1 > legs.count else { return }
        isSnapping = true
        snapWorker = Task {
            defer {
                snapWorker = nil
                isSnapping = false
            }
            while legs.count < waypoints.count - 1 {
                let i = legs.count
                let from = waypoints[i], to = waypoints[i + 1]
                let options = await PathSnapper.snapAlternates(from: from, to: to)
                // Undo may have mutated state during the await — apply the
                // result only if this job still describes the pending leg.
                guard i == legs.count, i + 1 < waypoints.count,
                      waypoints[i] == from, waypoints[i + 1] == to else { continue }
                if options.isEmpty {
                    // No confirmed walking route (highway, river, private
                    // land, or MKDirections unreachable): reject the dot —
                    // nothing unwalkable is ever drawn or published.
                    waypoints.remove(at: i + 1)
                    showPathNotice("No walkable path to that spot.")
                } else {
                    legs.append(Leg(options: options, chosenIndex: 0))
                }
            }
        }
    }

    /// Pure array surgery — zero MKDirections requests. A leg is popped only
    /// when the removed dot's leg had settled; an in-flight result for it is
    /// discarded by the worker's revalidation guard.
    func undoWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        if !legs.isEmpty, legs.count == waypoints.count {
            legs.removeLast()
        }
    }

    /// "Another path": swap the most recent segment for MKDirections' next
    /// alternate. The dots stay exactly where they are — only the connecting
    /// line changes; a full cycle wraps back to the original.
    func cycleAlternatePath() {
        guard canCycleAlternate, let last = legs.indices.last else { return }
        legs[last].chosenIndex = (legs[last].chosenIndex + 1) % legs[last].options.count
    }

    private func showPathNotice(_ text: String) {
        pathNotice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            pathNotice = nil
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
        // Every drawn stretch is a confirmed walking path by construction
        // (unwalkable legs are rejected at draw time), so gems can go
        // anywhere along the route that passes the rules below.
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
