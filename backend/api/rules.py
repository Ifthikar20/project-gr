"""Game rules — a 1:1 port of the iOS GameKitCore constants (docs/02, docs/04).
The Swift fixture tests in Packages/GemRunCore/Tests double as test vectors.
"""

# Collection / validity (Swift: CollectionRules)
COLLECTION_RADIUS_M = 30.5   # ~100 ft — mirrors Swift CollectionRules
HYSTERESIS_EXIT_RADIUS_M = 40.0
HYSTERESIS_ADVANCE_M = 50.0

MAX_CROSS_TRACK_M = 40.0
MIN_ON_ROUTE_SAMPLE_RATIO = 0.90
MIN_ROUTE_COVERAGE_RATIO = 0.95

TELEPORT_SPEED = 8.0                # m/s sustained
TELEPORT_SUSTAIN_S = 5.0
MIN_RUN_PACE_S_PER_KM = 150         # 2:30 — faster is a vehicle
MAX_VALID_PACE_S_PER_KM = 1200      # 20:00 — slower is invalid
WALK_PACE_THRESHOLD_S_PER_KM = 600  # 10:00 — slower is a walk (0.5x XP)

# XP (Swift: XPRules)
XP_BY_RARITY = {"common": 10, "uncommon": 25, "rare": 75, "epic": 200, "legendary": 500}
SET_COMPLETION_BONUS = 500
WALK_MULTIPLIER = 0.5


def xp_to_advance(level: int) -> int:
    return 100 * level


# Streaks (Swift: StreakRules)
MIN_VALID_RUN_DISTANCE_M = 1000
MAX_SHIELDS = 2
SHIELD_EARNED_EVERY_DAYS = 7


def streak_multiplier(days: int) -> float:
    return min(1.5, 1.0 + 0.1 * (max(0, days) // 7))


# Gem wallet minting (earn-by-running): total lifetime run distance (from
# Apple Health, client-reported for now) mints gems at these thresholds —
# one gem per N km per tier. Users start at 0. Legendary is never mintable.
MINT_THRESHOLD_KM = {"common": 2.0, "uncommon": 5.0, "rare": 15.0, "epic": 40.0}

# Standalone drop capture: within 100 ft while walking/running past
# (Swift mirror: CollectionRules.dropCollectRadiusM).
DROP_COLLECT_RADIUS_M = 30.5
# GPS samples worse than this are ignored when matching a track to a drop —
# a 200 m-accuracy fix can't prove you were within collection range of
# anything.
MAX_CLAIM_ACCURACY_M = 50.0

# Creator placement budget (Swift: PlacementBudget)
METERS_PER_SLOT = 250
MIN_GEM_SPACING_M = 100
RARE_MIN_ROUTE_FRACTION = 0.4
PLACEMENT_COST = {"common": 1, "uncommon": 3, "rare": 10, "epic": 25}  # legendary: not placeable


def budget_slots(distance_m: int) -> int:
    return distance_m // METERS_PER_SLOT


def budget_points(distance_m: int) -> int:
    return distance_m // 100
