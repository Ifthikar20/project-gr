"""Route geometry + polyline codec — port of GameKitCore/RouteGeometry.swift
and CoreModels/Geo.swift. Equirectangular approximation around route origin.
"""
import math

M_PER_DEG_LAT = 111_320.0


def polyline_decode(s: str):
    coords, i, lat, lng = [], 0, 0, 0
    b = s.encode()

    def value(i):
        result, shift = 0, 0
        while True:
            byte = b[i] - 63
            i += 1
            result |= (byte & 0x1F) << shift
            shift += 5
            if byte < 0x20:
                break
        return (~(result >> 1) if (result & 1) else (result >> 1)), i

    while i < len(b):
        d, i = value(i)
        lat += d
        d, i = value(i)
        lng += d
        coords.append((lat / 1e5, lng / 1e5))
    return coords


def polyline_encode(coords):
    out, prev_lat, prev_lng = [], 0, 0

    def enc(v):
        v = ~(v << 1) if v < 0 else (v << 1)
        chunk = ""
        while v >= 0x20:
            chunk += chr(((v & 0x1F) | 0x20) + 63)
            v >>= 5
        return chunk + chr(v + 63)

    for lat, lng in coords:
        ilat, ilng = round(lat * 1e5), round(lng * 1e5)
        out.append(enc(ilat - prev_lat))
        out.append(enc(ilng - prev_lng))
        prev_lat, prev_lng = ilat, ilng
    return "".join(out)


class RouteGeometry:
    def __init__(self, coords):
        self.coords = coords
        lat0, lng0 = coords[0] if coords else (0.0, 0.0)
        self.origin = (lat0, lng0)
        self.m_per_deg_lng = M_PER_DEG_LAT * math.cos(math.radians(lat0))
        self.xy, self.cumulative = [], []
        total = 0.0
        for i, (lat, lng) in enumerate(coords):
            x = (lng - lng0) * self.m_per_deg_lng
            y = (lat - lat0) * M_PER_DEG_LAT
            if i > 0:
                px, py = self.xy[i - 1]
                total += math.hypot(x - px, y - py)
            self.xy.append((x, y))
            self.cumulative.append(total)

    @property
    def total_length_m(self):
        return self.cumulative[-1] if self.cumulative else 0.0

    def _to_xy(self, lat, lng):
        return ((lng - self.origin[1]) * self.m_per_deg_lng,
                (lat - self.origin[0]) * M_PER_DEG_LAT)

    def project(self, lat, lng):
        """Returns (cross_track_m, along_route_m) of the closest polyline point."""
        if len(self.coords) < 2:
            return (self.distance((lat, lng), self.origin), 0.0)
        px, py = self._to_xy(lat, lng)
        best = (float("inf"), 0.0)
        for i in range(len(self.coords) - 1):
            ax, ay = self.xy[i]
            dx, dy = self.xy[i + 1][0] - ax, self.xy[i + 1][1] - ay
            len2 = dx * dx + dy * dy
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / len2)) if len2 > 0 else 0.0
            cx, cy = ax + t * dx, ay + t * dy
            dist = math.hypot(px - cx, py - cy)
            if dist < best[0]:
                best = (dist, self.cumulative[i] + t * math.sqrt(len2))
        return best

    def coordinate_at(self, d):
        if not self.cumulative or self.total_length_m <= 0:
            return self.origin
        d = max(0.0, min(d, self.total_length_m))
        for i in range(1, len(self.cumulative)):
            if self.cumulative[i] >= d:
                seg = self.cumulative[i] - self.cumulative[i - 1]
                t = (d - self.cumulative[i - 1]) / seg if seg > 0 else 0.0
                (alat, alng), (blat, blng) = self.coords[i - 1], self.coords[i]
                return (alat + t * (blat - alat), alng + t * (blng - alng))
        return self.coords[-1]

    def distance(self, a, b):
        dx = (a[1] - b[1]) * self.m_per_deg_lng
        dy = (a[0] - b[0]) * M_PER_DEG_LAT
        return math.hypot(dx, dy)
