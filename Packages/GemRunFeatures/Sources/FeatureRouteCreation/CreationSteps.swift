import CoreMap
import CoreModels
import CoreNetworking
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

@MainActor
struct DrawStepView: View {
    @Bindable var model: CreationModel

    var body: some View {
        ZStack(alignment: .bottom) {
            DrawingMapView(pathCoords: model.pathCoords,
                           waypoints: model.planMode == .draw ? model.waypoints : [],
                           destination: model.planMode == .destination
                               ? model.destination : nil) { coord in
                switch model.planMode {
                case .draw: model.addWaypoint(coord)
                case .destination: model.setDestination(coord)
                }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                Picker("Mode", selection: $model.planMode) {
                    Text("Draw it").tag(CreationModel.PlanMode.draw)
                    Text("To a destination").tag(CreationModel.PlanMode.destination)
                }
                .pickerStyle(.segmented)

                switch model.planMode {
                case .draw: drawControls
                case .destination: destinationControls
                }

                PillButton("Next: place gems") { model.step = .gems }
                    .disabled(model.distanceM < 1_000)
                    .opacity(model.distanceM < 1_000 ? 0.5 : 1)
            }
            .padding(16)
            .background(DS.Colors.snow)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Colors.hairline).frame(height: 1)
            }
        }
        .navigationTitle("Plan your route")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var drawControls: some View {
        HStack {
            Button {
                model.undoWaypoint()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .foregroundStyle(DS.Colors.ink)
            }
            .disabled(model.waypoints.isEmpty)
            Spacer()
            Text(String(format: "%.2f km · %d points",
                        Double(model.distanceM) / 1_000, model.waypoints.count))
                .font(.footnote)
                .foregroundStyle(DS.Colors.inkSecondary)
        }
    }

    /// Destination mode (docs/03 update): start = current location or a
    /// typed address; tap the map to drop the destination pin.
    private var destinationControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Start: address (or use my location)",
                          text: $model.startAddress)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.geocodeStart() } }
                Button {
                    model.useCurrentLocationStart()
                } label: {
                    Image(systemName: "location.fill")
                        .foregroundStyle(model.customStart == nil
                            ? DS.Colors.pulse : DS.Colors.ink)
                        .frame(width: 40, height: 34)
                        .background(DS.Colors.snowCard,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(DS.Colors.hairline, lineWidth: 1))
                }
            }
            HStack {
                if model.isPlanning {
                    ProgressView().controlSize(.small)
                    Text("Finding a walkable path…")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                } else if let error = model.planError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DS.Colors.pulse)
                } else if model.destination == nil {
                    Text("Tap the map to drop your destination pin")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.inkSecondary)
                } else {
                    Text(String(format: "%.2f km to your pin",
                                Double(model.distanceM) / 1_000))
                        .font(.caption.bold())
                        .foregroundStyle(DS.Colors.ink)
                }
                Spacer()
            }
        }
    }
}

@MainActor
struct GemPlacementStepView: View {
    @Bindable var model: CreationModel

    var body: some View {
        ZStack(alignment: .bottom) {
            DrawingMapView(
                pathCoords: model.pathCoords,
                waypoints: model.placedDrops.map(\.coordinate)
            ) { coord in
                model.placeGem(at: coord)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                if let error = model.placementError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.pulse)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Gem tray (docs/03 §5): pick a rarity, tap the route to place.
                HStack(spacing: 8) {
                    ForEach([Rarity.common, .uncommon, .rare, .epic], id: \.self) { rarity in
                        Button {
                            model.selectedRarity = rarity
                        } label: {
                            VStack(spacing: 3) {
                                RarityBadge(rarity, size: 16)
                                Text(PlacementCost.label(rarity))
                                    .font(.caption2)
                                    .foregroundStyle(DS.Colors.inkSecondary)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(DS.Colors.snowCard,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(model.selectedRarity == rarity
                                    ? DS.Colors.pulse : DS.Colors.hairline,
                                    lineWidth: model.selectedRarity == rarity ? 2 : 1))
                        }
                    }
                }
                Text("Budget \(model.pointsUsed)/\(model.pointsTotal) · Slots \(model.slotsUsed)/\(model.slotsTotal) · tap the route to place")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.inkSecondary)
                PillButton(model.placedDrops.isEmpty ? "Continue without gems" : "Next: publish") {
                    model.step = .publish
                }
            }
            .padding(16)
            .background(DS.Colors.snow)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Colors.hairline).frame(height: 1)
            }
        }
        .navigationTitle("Place gems")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back") { model.step = .draw }
            }
        }
    }
}

enum PlacementCost {
    static func label(_ r: Rarity) -> String {
        switch r {
        case .common: "1 pt"
        case .uncommon: "3 pt"
        case .rare: "10 pt"
        case .epic: "25 pt"
        case .legendary: "—"
        }
    }
}

@MainActor
struct PublishStepView: View {
    @Bindable var model: CreationModel
    let onDone: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(SessionStore.self) private var session
    @State private var isPublishing = false
    @State private var publishError: String?

    /// POST /v1/routes — the server re-validates the placement budget; the
    /// returned (published) route is what enters the local cache.
    private func publish() {
        isPublishing = true
        publishError = nil
        let route = model.buildRoute(creatorHandle: session.profile?.handle)
        Task {
            do {
                let published = try await API.shared.publishRoute(route)
                context.insert(StoredRoute(route: published))
                try? context.save()
                onDone()
            } catch {
                publishError = "Publish failed — check your gem placement and try again."
            }
            isPublishing = false
        }
    }

    var body: some View {
        Form {
            Section("Name your route") {
                TextField("e.g. Tuesday Torture", text: $model.name)
                TextField("Description (optional)", text: $model.descriptionText)
            }
            Section {
                LabeledContent("Distance",
                               value: String(format: "%.2f km", Double(model.distanceM) / 1_000))
                LabeledContent("Difficulty", value: model.difficulty.rawValue.capitalized)
                LabeledContent("Gems", value: "\(model.placedDrops.count)")
                LabeledContent("Visibility", value: "Public")
            }
            Section {
                Button {
                    publish()
                } label: {
                    if isPublishing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Publish")
                            .frame(maxWidth: .infinity)
                            .font(DS.Typography.heading)
                            .foregroundStyle(DS.Colors.pulse)
                    }
                }
                .disabled(isPublishing
                    || model.name.trimmingCharacters(in: .whitespaces).isEmpty)
                if let publishError {
                    Text(publishError)
                        .foregroundStyle(DS.Colors.pulse)
                        .font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.Colors.snow)
        .navigationTitle("Publish")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back") { model.step = .gems }
            }
        }
    }
}
