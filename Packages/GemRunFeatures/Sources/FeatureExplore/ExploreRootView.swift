import CoreMap
import CoreModels
import DesignSystem
import SwiftUI

/// Map home (docs/03 §2). Phase A: placeholder map + "+" FAB.
/// Phase C replaces the provider with Mapbox and adds the route-card carousel.
public struct ExploreRootView: View {
    private let mapProvider: any MapProviding = PlaceholderMapProvider()

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                mapProvider.exploreMap(routes: [])
                    .ignoresSafeArea()

                Button {
                    // TODO(Phase E): present FeatureRouteCreation flow.
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(DS.Colors.ink)
                        .frame(width: 56, height: 56)
                        .background(DS.Colors.gold, in: Circle())
                        .shadow(radius: 6)
                }
                .padding(20)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

#Preview {
    ExploreRootView()
}
