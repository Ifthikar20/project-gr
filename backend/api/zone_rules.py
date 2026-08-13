"""Zone selection + mint constants — a 1:1 port of the iOS GameKitCore
ZoneRules (docs/21), the same way rules.py mirrors CollectionRules. The Swift
fixture tests double as vectors; if a value moves, move it on BOTH sides in
the same change.
"""
import math

# Selection
MAX_ZONE_COUNT = 4
SEARCH_RADIUS_M = 2_500.0
MIN_ZONE_RADIUS_M = 350.0
MAX_ZONE_RADIUS_M = 500.0
MIN_PARK_AREA_M2 = 8_000.0
# Polygon zones grow to at least the min-radius circle's footprint — odd
# shape, large area — capped so a pocket park can't project a district.
TARGET_ZONE_AREA_M2 = math.pi * 350 * 350
MAX_RING_SCALE = 3.0
MAX_RING_VERTICES = 160
MIN_TRAIL_LENGTH_M = 200.0
MIN_SEPARATION_FACTOR = 1.2

# The mile: metres credited inside a zone that mint a card (the app speaks
# miles everywhere; internals stay metric — UnitFormat.metersPerMile).
MINT_DISTANCE_M = 1_609.344
MAX_MINTS_PER_ZONE_PER_DAY = 3

# Per-segment gates (ZoneProgressTracker) — documented here for the future
# server-side track validation; the client enforces them today.
MAX_ACCURACY_M = 50.0
MAP_SPEED_CAP_MPS = 3.5
RUN_SPEED_CAP_MPS = 6.0
TELEPORT_SPEED_MPS = 8.0
MAX_SAMPLE_GAP_S = 120.0
MIN_SEGMENT_M = 3.0

# Draw salts (StableSeed) — "Zone" and "Mint" in ASCII, exactly the Swift
# literals, so independent draws never correlate and both sides agree.
ZONE_PICK_SALT = 0x5A6F6E65
MINT_SALT = 0x4D696E74
