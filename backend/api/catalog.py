"""Gem catalog — mirrors the iOS GemCatalog exactly, including the fixed
UUIDs (uuid.UUID(int=n) equals Swift's UUID with last byte n), so gem ids on
both sides match without any sync.
"""
import uuid

TRAILBLAZER_SET = uuid.UUID(int=1)
HARBOR_SET = uuid.UUID(int=2)

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
]


def gem_of(rarity: str):
    return next(e for e in ENTRIES if e["rarity"] == rarity)


def entry_for(gem_id):
    return next((e for e in ENTRIES if e["id"] == gem_id), None)
