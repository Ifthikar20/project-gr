"""Seeded determinism — a bit-exact port of GameKitCore/SeededRNG.swift and
ZoneSelector.stableZoneID, so the server and the iOS client derive the SAME
zone ids and replay the SAME mints from a seed. The cross-language vector
tests (SeededVectorTests here, SeededVectorTests.swift in GameKitCoreTests)
pin both sides to shared literals; touching any constant here breaks them —
deliberately.

Swift wraps in 64-bit two's-complement (&*, &+); Python ints are unbounded,
so every step masks back to 64 bits. Swift's `.rounded()` is
round-half-AWAY-FROM-ZERO; Python's round() is banker's — `_rounded` exists
because that difference flips cell indices exactly on the half boundary.
"""
import math
import uuid

MASK64 = (1 << 64) - 1


def _rounded(x: float) -> int:
    """Swift Double.rounded(): to nearest, halves away from zero."""
    return int(math.copysign(math.floor(abs(x) + 0.5), x))


class SplitMix64:
    """GameKitCore's SplitMix64, draw-for-draw."""

    def __init__(self, seed: int):
        self.state = seed & MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return (z ^ (z >> 31)) & MASK64

    def next_unit_double(self) -> float:
        """Swift: Double(next() >> 11) / Double(1 << 53) — uniform [0, 1)."""
        return (self.next() >> 11) / float(1 << 53)

    def next_uuid(self) -> uuid.UUID:
        """Two draws folded into a UUID, high bits first (Swift nextUUID)."""
        hi = self.next()
        lo = self.next()
        return uuid.UUID(int=(hi << 64) | lo)


def stable_seed_daily(day: int, lat: float, lng: float,
                      cell_deg: float = 0.005, salt: int = 0) -> int:
    """StableSeed.daily: same seed all day within a ~500 m cell."""
    cell_lat = _rounded(lat / cell_deg)
    cell_lng = _rounded(lng / cell_deg)
    base = (day * 1_000_003 + cell_lat * 8_191 + cell_lng) & MASK64
    return base ^ (salt & MASK64)


def stable_zone_id(day: int, lat: float, lng: float) -> uuid.UUID:
    """ZoneSelector.stableZoneID: deterministic zone UUID from (day,
    centroid rounded to ~1 m). The client keys partial mile progress by this
    id — the formula must NEVER change, on either side."""
    seed = (day * 6_700_417
            + _rounded(lat * 1e5) * 65_537
            + _rounded(lng * 1e5)) & MASK64
    return SplitMix64(seed).next_uuid()
