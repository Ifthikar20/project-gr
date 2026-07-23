import CoreModels
import SwiftUI

/// The map abstraction seam (docs/07): nothing outside CoreMap may import a
/// map SDK. `MapboxMapProvider` arrives in Phase C; the placeholder keeps
/// Phases A–B buildable without the SDK or a token.
@MainActor
public protocol MapProviding {
    /// Full-bleed map for Explore: user-centered, renders route polylines.
    func exploreMap(routes: [Route]) -> AnyView
    /// Static preview for Route Detail: polyline + gem/zone markers.
    func routePreview(route: Route) -> AnyView
}

public struct PlaceholderMapProvider: MapProviding {
    public init() {}

    public func exploreMap(routes: [Route]) -> AnyView {
        AnyView(PlaceholderMapView(caption: "\(routes.count) routes nearby"))
    }

    public func routePreview(route: Route) -> AnyView {
        AnyView(PlaceholderMapView(caption: route.name))
    }
}

struct PlaceholderMapView: View {
    let caption: String

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.08, blue: 0.13)
            // Faux topo contours so the placeholder reads as "map".
            ForEach(0..<5) { ring in
                Circle()
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    .frame(width: CGFloat(80 + ring * 90))
            }
            VStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.system(size: 36))
                    .foregroundStyle(Color(red: 0.95, green: 0.76, blue: 0.29))
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                Text("Mapbox map lands in Phase C")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}
