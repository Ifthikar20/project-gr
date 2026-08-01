import CoreModels
import MapKit
import UIKit

/// Real-map snapshot of a traveled track, for share exports. ImageRenderer
/// cannot rasterize live Map views (they export blank — the reason the share
/// card used an abstract route shape), so this asks MKMapSnapshotter for
/// actual street imagery and draws the pulse track, an ink start dot, and a
/// pulse finish dot on top — the same muted look as the in-app card hero.
public enum TrackSnapshotter {
    public static func image(for coords: [Coordinate],
                             size: CGSize) async -> UIImage? {
        guard coords.count > 1 else { return nil }
        let lats = coords.map(\.lat)
        let lngs = coords.map(\.lng)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.004, (maxLat - minLat) * 1.45),
                longitudeDelta: max(0.004, (maxLng - minLng) * 1.45)))
        options.size = size
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        // Daybreak Pulse is a light system, and the export must not depend
        // on the device's appearance; 3× matches the card's render scale.
        options.traitCollection = UITraitCollection(traitsFrom: [
            options.traitCollection,
            UITraitCollection(displayScale: 3),
            UITraitCollection(userInterfaceStyle: .light),
        ])

        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            // Offline/region failure → caller falls back to the abstract
            // route shape; the card is never blank.
            GemLog.map.error("track snapshot failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            snapshot.image.draw(at: .zero)
            let points = coords.map { snapshot.point(for: $0.cl) }
            let path = UIBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            UIColor(MapPalette.pulse).setStroke()
            path.stroke()
            dot(at: points[0], color: UIColor(MapPalette.ink))
            dot(at: points[points.count - 1], color: UIColor(MapPalette.pulse))
        }
    }

    private static func dot(at point: CGPoint, color: UIColor) {
        let radius: CGFloat = 5
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        color.setFill()
        UIBezierPath(ovalIn: rect).fill()
        UIColor.white.setStroke()
        let ring = UIBezierPath(ovalIn: rect)
        ring.lineWidth = 2
        ring.stroke()
    }
}
