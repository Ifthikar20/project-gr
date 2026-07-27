"""Gem catalog — mirrors the iOS GemCatalog exactly, including the fixed
UUIDs (uuid.UUID(int=n) equals Swift's UUID with last byte n), so gem ids on
both sides match without any sync.
"""
import uuid

TRAILBLAZER_SET = uuid.UUID(int=1)
HARBOR_SET = uuid.UUID(int=2)
CITY_LIGHTS_SET = uuid.UUID(int=3)
RELICS_SET = uuid.UUID(int=4)

ENTRIES = [
    {"id": uuid.UUID(int=10), "name": "Trail Quartz", "rarity": "common",
     "set_id": TRAILBLAZER_SET, "set_name": "Trailblazer", "icon_ref": "gem.quartz"},
    {"id": uuid.UUID(int=11), "name": "Moss Emerald", "rarity": "uncommon",
     "set_id": TRAILBLAZER_SET, "set_name": "Trailblazer", "icon_ref": "gem.emerald"},
    {"id": uuid.UUID(int=12), "name": "Ridge Sapphire", "rarity": "rare",
     "set_id": TRAILBLAZER_SET, "set_name": "Trailblazer", "icon_ref": "gem.sapphire"},
    {"id": uuid.UUID(int=13), "name": "Summit Amethyst", "rarity": "epic",
     "set_id": TRAILBLAZER_SET, "set_name": "Trailblazer", "icon_ref": "gem.amethyst"},
    {"id": uuid.UUID(int=14), "name": "First Light Ember", "rarity": "legendary",
     "set_id": TRAILBLAZER_SET, "set_name": "Trailblazer", "icon_ref": "gem.ember"},
    {"id": uuid.UUID(int=20), "name": "Harbor Quartz", "rarity": "common",
     "set_id": HARBOR_SET, "set_name": "Harbor Lights", "icon_ref": "gem.quartz"},
    {"id": uuid.UUID(int=21), "name": "Tide Emerald", "rarity": "uncommon",
     "set_id": HARBOR_SET, "set_name": "Harbor Lights", "icon_ref": "gem.emerald"},
    {"id": uuid.UUID(int=22), "name": "Deepwater Sapphire", "rarity": "rare",
     "set_id": HARBOR_SET, "set_name": "Harbor Lights", "icon_ref": "gem.sapphire"},
    {"id": uuid.UUID(int=30), "name": "Streetlight Quartz", "rarity": "common",
     "set_id": CITY_LIGHTS_SET, "set_name": "City Lights", "icon_ref": "gem.quartz"},
    {"id": uuid.UUID(int=31), "name": "Neon Ruby", "rarity": "uncommon",
     "set_id": CITY_LIGHTS_SET, "set_name": "City Lights", "icon_ref": "gem.ruby"},
    {"id": uuid.UUID(int=32), "name": "Skyline Topaz", "rarity": "rare",
     "set_id": CITY_LIGHTS_SET, "set_name": "City Lights", "icon_ref": "gem.topaz"},
    {"id": uuid.UUID(int=33), "name": "Midnight Amethyst", "rarity": "epic",
     "set_id": CITY_LIGHTS_SET, "set_name": "City Lights", "icon_ref": "gem.amethyst"},
    # Ancient Relics — organic and rock gemstone materials.
    {"id": uuid.UUID(int=40), "name": "Bone", "rarity": "common",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.bone"},
    {"id": uuid.UUID(int=41), "name": "Copal", "rarity": "common",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.copal"},
    {"id": uuid.UUID(int=42), "name": "Sponge Coral", "rarity": "common",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.spongecoral"},
    {"id": uuid.UUID(int=43), "name": "Mother-of-Pearl", "rarity": "common",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.motherofpearl"},
    {"id": uuid.UUID(int=44), "name": "Amber", "rarity": "uncommon",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.amber"},
    {"id": uuid.UUID(int=45), "name": "Ammonite", "rarity": "uncommon",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.ammonite"},
    {"id": uuid.UUID(int=46), "name": "Jet", "rarity": "uncommon",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.jet"},
    {"id": uuid.UUID(int=47), "name": "Fossil Coral", "rarity": "uncommon",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.fossilcoral"},
    {"id": uuid.UUID(int=48), "name": "Pearl", "rarity": "rare",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.pearl"},
    {"id": uuid.UUID(int=49), "name": "Red Coral", "rarity": "rare",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.redcoral"},
    {"id": uuid.UUID(int=50), "name": "Tektite", "rarity": "rare",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.tektite"},
    {"id": uuid.UUID(int=51), "name": "Ammolite", "rarity": "epic",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.ammolite"},
    {"id": uuid.UUID(int=52), "name": "Dinosaur Bone", "rarity": "epic",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.dinobone"},
    {"id": uuid.UUID(int=53), "name": "Ivory (historical)", "rarity": "epic",
     "set_id": RELICS_SET, "set_name": "Ancient Relics", "icon_ref": "gem.ivory"},
]


def gem_of(rarity: str):
    return next(e for e in ENTRIES if e["rarity"] == rarity)


def random_gem_of(rarity: str, rng):
    """A random catalog gem of the given rarity — placement uses this so the
    map shows ambers and pearls, not the same quartz/emerald every time."""
    choices = [e for e in ENTRIES if e["rarity"] == rarity]
    return rng.choice(choices) if choices else gem_of(rarity)


def entry_for(gem_id):
    return next((e for e in ENTRIES if e["id"] == gem_id), None)
