import CoreMap
import CoreModels
import CorePersistence
import DesignSystem
import SwiftData
import SwiftUI

struct DrawStepView: View {
    @Bindable var model: CreationModel

    var body: some View {
        ZStack(alignment: .bottom) {
            DrawingMapView(pathCoords: model.pathCoords, waypoints: model.waypoints) { coord in
                model.addWaypoint(coord)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                HStack {
                    Button {
                        model.undoWaypoint()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.waypoints.isEmpty)
                    Spacer()
                    Text(String(format: "%.2f km · %d points",
                                Double(model.distanceM) / 1_000, model.waypoints.count))
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Button {
                    model.step = .gems
                } label: {
                    Text("Next: place gems")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DS.Colors.gold, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(model.distanceM < 1_000)
                .opacity(model.distanceM < 1_000 ? 0.5 : 1)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .navigationTitle("Draw your route")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Gem tray (docs/03 §5): pick a rarity, tap the route to place.
                HStack(spacing: 8) {
                    ForEach([Rarity.common, .uncommon, .rare, .epic], id: \.self) { rarity in
                        Button {
                            model.selectedRarity = rarity
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "diamond.fill")
                                    .foregroundStyle(DS.Colors.rarity(rarity))
                                Text("\(PlacementCost.label(rarity))")
                                    .font(.caption2)
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(
                                model.selectedRarity == rarity
                                    ? DS.Colors.gold.opacity(0.25) : DS.Colors.inkRaised,
                                in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Text("Budget \(model.pointsUsed)/\(model.pointsTotal) · Slots \(model.slotsUsed)/\(model.slotsTotal) · tap the route to place")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                Button {
                    model.step = .publish
                } label: {
                    Text(model.placedDrops.isEmpty ? "Continue without gems" : "Next: publish")
                        .font(DS.Typography.heading)
                        .foregroundStyle(DS.Colors.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DS.Colors.gold, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
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

struct PublishStepView: View {
    @Bindable var model: CreationModel
    let onDone: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(SessionStore.self) private var session

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
                    let route = model.buildRoute(creatorHandle: session.profile?.handle)
                    context.insert(StoredRoute(route: route))
                    try? context.save()
                    onDone()
                } label: {
                    Text("Publish")
                        .frame(maxWidth: .infinity)
                        .font(DS.Typography.heading)
                }
                .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Publish")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back") { model.step = .gems }
            }
        }
    }
}
