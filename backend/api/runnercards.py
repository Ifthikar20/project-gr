"""Runner Card catalog + minter — the server half of the mint (docs/21).

The catalog mirrors the iOS RunnerCardCatalog the way catalog.py mirrors
GemCatalog: fixed UUIDs via uuid.UUID(int=n) in the cards' own numeric range
(100+ named, 150+gem-byte for gem faces), ORDER PRESERVED — the minter picks
a face by index from the (type, rarity) pool, so entry order is part of the
wire contract with the client's CardMinter.

The minter is a draw-for-draw port of CardMinter.swift: one uniform double
for rarity at the published odds, one uniform type roll, one uniform face
pick within the combo (degrading down the rarity ladder if a combo were
empty), then the mint's own UUID — all off one SplitMix64 stream. The same
seed mints the identical card on both sides, which is what lets
POST /v1/cards verify a claim by simply replaying it.
"""
from . import catalog
from .seeded import SplitMix64
from uuid import UUID

CARD_TYPES = ["gem", "gear", "creature", "artifact", "fact"]   # CardType order
RARITY_LADDER = ["legendary", "epic", "rare", "uncommon", "common"]

# Published pull odds (MintOdds) — the landing page's rarity ladder.
LEGENDARY_ODDS = 1.0 / 900
EPIC_ODDS = 1.0 / 60
RARE_ODDS = 1.0 / 12
UNCOMMON_ODDS = 1.0 / 4


def roll_rarity(u: float) -> str:
    if u < LEGENDARY_ODDS:
        return "legendary"
    if u < LEGENDARY_ODDS + EPIC_ODDS:
        return "epic"
    if u < LEGENDARY_ODDS + EPIC_ODDS + RARE_ODDS:
        return "rare"
    if u < LEGENDARY_ODDS + EPIC_ODDS + RARE_ODDS + UNCOMMON_ODDS:
        return "uncommon"
    return "common"


def _entry(n, name, ctype, rarity, xp):
    return {"card_id": UUID(int=n), "name": name, "type": ctype,
            "rarity": rarity, "xp": xp}


# The 23 named faces, verbatim from RunnerCardCatalog.named (identity fields
# only — ability/flavor text stays client-side; validation needs id + name +
# combo + XP).
NAMED = [
    _entry(100, "Harbor Sapphire", "gem", "legendary", 240),
    _entry(101, "Golden Shoes", "gear", "legendary", 300),
    _entry(102, "Harbor Fox", "creature", "rare", 90),
    _entry(103, "The Unmarked Obelisk", "artifact", "epic", 160),
    _entry(104, "Runner's High", "fact", "rare", 60),
    _entry(105, "Trail Boots", "gear", "common", 20),
    _entry(106, "Night Heron", "creature", "epic", 180),
    _entry(107, "Rose Quartz", "gem", "uncommon", 40),
    _entry(108, "Ghost Koi", "creature", "legendary", 260),
    _entry(109, "Storm Shell", "gear", "rare", 70),
    _entry(110, "Second Wind", "fact", "uncommon", 35),
    _entry(111, "Old Tram Token", "artifact", "epic", 150),
    _entry(112, "City Sparrow", "creature", "common", 15),
    _entry(113, "Dawn Visor", "gear", "uncommon", 40),
    _entry(114, "Aurora Windbreaker", "gear", "epic", 160),
    _entry(115, "Towpath Otter", "creature", "uncommon", 40),
    _entry(116, "Bottle Cap, 1971", "artifact", "common", 15),
    _entry(117, "Faded Mile Marker", "artifact", "uncommon", 35),
    _entry(118, "Brass Compass Rose", "artifact", "rare", 80),
    _entry(119, "The First Bib", "artifact", "legendary", 260),
    _entry(120, "Left, Right, Repeat", "fact", "common", 15),
    _entry(121, "The Wall at 30K", "fact", "epic", 150),
    _entry(122, "The First Marathon", "fact", "legendary", 240),
]

# Base XP per rarity for gem-derived faces (RunnerCardCatalog.baseXP).
GEM_FACE_XP = {"common": 15, "uncommon": 35, "rare": 80,
               "epic": 160, "legendary": 260}

# Every catalog gem becomes a gem-type face: cardID = 150 + the gem UUID's
# last byte, name and rarity carried over — GemCatalog order preserved.
GEM_FACES = [
    _entry(150 + e["id"].bytes[-1], e["name"], "gem", e["rarity"],
           GEM_FACE_XP[e["rarity"]])
    for e in catalog.ENTRIES
]

ENTRIES = NAMED + GEM_FACES


def entry_for(card_id):
    return next((e for e in ENTRIES if e["card_id"] == card_id), None)


def _pick(ctype: str, rarity: str, entries, rng: SplitMix64):
    """CardMinter.pick: uniform face within the combo; an empty combo
    degrades to the nearest lower rarity in-type, then to anything."""
    ladder_from = RARITY_LADDER[RARITY_LADDER.index(rarity):]
    for r in ladder_from:
        pool = [e for e in entries if e["type"] == ctype and e["rarity"] == r]
        if pool:
            return pool[rng.next() % len(pool)]
    return entries[0] if entries else None


def mint(seed: int, entries=None):
    """Replay a mint from its seed: the card's identity (mint UUID, face,
    name, combo, XP), exactly as CardMinter.mint derives it. The caller
    compares this against the client's claim — stats/zone/serial are stamped
    on, not derived, so they're validated separately."""
    entries = ENTRIES if entries is None else entries
    rng = SplitMix64(seed)
    rarity = roll_rarity(rng.next_unit_double())
    ctype = CARD_TYPES[rng.next() % len(CARD_TYPES)]
    face = _pick(ctype, rarity, entries, rng)
    mint_uuid = rng.next_uuid()
    if face is None:
        return {"id": mint_uuid, "card_id": UUID(int=0), "name": "Blank Card",
                "type": ctype, "rarity": rarity, "xp": 10}
    return {"id": mint_uuid, "card_id": face["card_id"], "name": face["name"],
            "type": face["type"], "rarity": face["rarity"], "xp": face["xp"]}
