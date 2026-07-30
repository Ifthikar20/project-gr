#!/usr/bin/env bash
# Import custom gem art into the asset catalog.
#
#   1. Drop PNGs into GEMS_REPO/ named after the gem material —
#      "Emerald_Gem.png", "mother of pearl.png", "Tektite.png" all work.
#   2. ./run.sh app|device runs this automatically before every build
#      (or run it directly: bash scripts/import-gem-art.sh).
#
# Each PNG is downscaled ONCE to 216 px (72 pt @3x — the largest size the
# app ever renders a gem), so in-app decode cost and bundle size stay tiny
# no matter how big the source art is, then written as a universal
# imageset named by the catalog ref (gem.emerald, ...). GemIcon picks it
# up with zero code changes; gems without art keep their emoji fallback.
# macOS only (uses sips) — builds happen on Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="GEMS_REPO"
CATALOG="App/Resources/Assets.xcassets"
REFS="quartz emerald sapphire amethyst ember ruby topaz bone copal
      spongecoral motherofpearl amber ammonite jet fossilcoral pearl
      redcoral tektite ammolite dinobone ivory"

[ -d "$SRC" ] || exit 0
command -v sips >/dev/null 2>&1 || { echo "import-gem-art: needs macOS (sips) — skipping."; exit 0; }

imported=0
for png in "$SRC"/*.png "$SRC"/*.PNG; do
    [ -f "$png" ] || continue
    name=$(basename "$png")
    name="${name%.*}"
    # Normalize the filename to a catalog key: lowercase, letters only,
    # the word "gem" dropped ("Emerald_Gem" → "emerald").
    key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')
    key="${key//gem/}"
    # Friendly aliases for the long material names.
    case "$key" in
        dinosaurbone)    key="dinobone" ;;
        firstlightember) key="ember" ;;
    esac
    match=""
    for ref in $REFS; do
        if [ "$key" = "$ref" ]; then match="$ref"; break; fi
    done
    if [ -z "$match" ]; then
        echo "import-gem-art: skipping $(basename "$png") — '$key' matches no catalog ref"
        continue
    fi
    set_dir="$CATALOG/gem.$match.imageset"
    mkdir -p "$set_dir"
    sips -Z 216 "$png" --out "$set_dir/gem.$match.png" >/dev/null
    cat > "$set_dir/Contents.json" <<EOF
{
  "images" : [
    { "filename" : "gem.$match.png", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
    imported=$((imported + 1))
    echo "import-gem-art: gem.$match ← $(basename "$png")"
done
if [ "$imported" -gt 0 ]; then
    echo "import-gem-art: $imported image(s) in the catalog."
fi
exit 0
