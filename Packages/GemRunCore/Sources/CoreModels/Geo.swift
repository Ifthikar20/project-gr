import Foundation

/// A WGS84 coordinate. Kept SDK-free so pure modules can use it.
public struct Coordinate: Codable, Equatable, Sendable {
    public var lat: Double
    public var lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }
}

public extension GemDrop {
    var coordinate: Coordinate { Coordinate(lat: lat, lng: lng) }
}

public extension TrackSample {
    var coordinate: Coordinate { Coordinate(lat: lat, lng: lng) }
}

/// Google encoded-polyline codec (the wire format for Route.polyline, docs/05).
public enum PolylineCodec {
    public static func encode(_ coords: [Coordinate]) -> String {
        var out = ""
        var prevLat = 0
        var prevLng = 0
        for c in coords {
            let lat = Int((c.lat * 1e5).rounded())
            let lng = Int((c.lng * 1e5).rounded())
            out += encodeValue(lat - prevLat)
            out += encodeValue(lng - prevLng)
            prevLat = lat
            prevLng = lng
        }
        return out
    }

    public static func decode(_ polyline: String) -> [Coordinate] {
        let bytes = Array(polyline.utf8)
        var coords: [Coordinate] = []
        var i = 0
        var lat = 0
        var lng = 0
        while i < bytes.count {
            guard let dLat = decodeValue(bytes, &i) else { break }
            guard let dLng = decodeValue(bytes, &i) else { break }
            lat += dLat
            lng += dLng
            coords.append(Coordinate(lat: Double(lat) / 1e5, lng: Double(lng) / 1e5))
        }
        return coords
    }

    private static func encodeValue(_ value: Int) -> String {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        var out = ""
        while v >= 0x20 {
            out.append(Character(UnicodeScalar(UInt8(((v & 0x1F) | 0x20) + 63))))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(UInt8(v + 63))))
        return out
    }

    private static func decodeValue(_ bytes: [UInt8], _ i: inout Int) -> Int? {
        var result = 0
        var shift = 0
        var byte = 0
        repeat {
            guard i < bytes.count else { return nil }
            byte = Int(bytes[i]) - 63
            i += 1
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
