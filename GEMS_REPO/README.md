# GEMS_REPO — drop the gem art here

Put one PNG per gem material in this folder and build
(`./run.sh device`). The import script downscales each image once and
wires it into the app; every pin, stash tile, drop sheet, gem card, and
run card picks it up automatically. Gems without art keep their emoji.

Naming: the material, any casing/spacing, "gem" optional —
`Emerald_Gem.png`, `mother of pearl.png`, `Tektite.png` all work.

The 21 materials (one PNG covers every gem that shares the material —
e.g. the emerald file covers Moss Emerald and Tide Emerald):

    quartz          emerald         sapphire        amethyst
    ember           ruby            topaz           bone
    copal           sponge coral    mother of pearl amber
    ammonite        jet             fossil coral    pearl
    red coral       tektite         ammolite        dinosaur bone
    ivory

Source art can be any size — ship-size (216 px) is generated at build
time into `App/Resources/Assets.xcassets`; the originals here are the
source of truth, so commit them.
