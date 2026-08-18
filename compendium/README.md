# Crows compendium content

Importable YAML for the Crows game data: conditions, expertises, backgrounds
and (later) items, monsters and dungeons.

`import/` is the canonical source and is tracked here. The Codex resolves
`dmhub.ImportFile("<basename>.yaml")` relative to `<gitfolder>/compendium/import`,
so the codex checkout carries a directory junction at that path pointing back
into this folder. One copy on disk, versioned with the module that needs it.

If the junction is missing on a fresh checkout, recreate it from an elevated
shell at the codex root:

    New-Item -ItemType Junction -Path .\compendium\import `
             -Target .\Crowdex\compendium\import

The codex repo gitignores `compendium/*`, which is why the source lives here
rather than there.

## Importing

Import through the MCP bridge rather than typing `/import`:

    dmhub.ImportFile("crows-backgrounds-all.yaml")

Bundles (`crows-*-all.yaml`) pull in their members with `_include`. A top-level
YAML list is NOT supported -- the importer wants one entry per file plus a
bundle manifest.

**Check the game first.** `dmhub.ImportFile` writes to whatever game is loaded,
and it matches entries by NAME, so importing Crows content into a Draw Steel
game silently overwrites anything sharing a name (Beggar, Farmer, Gladiator,
Sage and Soldier all exist in both). Guard every import:

    local attrs = table.concat(creature.attributeIds or {}, ", ")
    if attrs ~= "agility, mind, strength" then return end

## Organising the bestiary

    -- through the MCP bridge, not /import
    loadfile("C:/MCDM/draw-steel-codex/Crowdex/compendium/organise-bestiary.lua")()

`organise-bestiary.lua` gives the Bestiary panel the five creature types Crows
actually uses -- Animal, Blood, Human, Undead, Unique, which is exactly what the
Ref Book's "Type:" lines say -- and files every monster under its own. It is
idempotent, so re-run it after importing more monsters.

Two things make it necessary. A game that has ever loaded Draw Steel inherits
that system's whole creature-type folder set (Aberration, Beast, Celestial,
Construct, Dragon, Fey, Fiend, Giant, Humanoid, Monstrosity, Ooze, Plant, Swarm,
Swarm of Tiny beasts), none of which exist in Crows and all of which show up
empty in the panel. And the monster YAML carries **no** `parentFolder`, on
purpose: folders are assets whose ids differ per game, so a hardcoded id would
be wrong everywhere except the game it was copied from. Imported monsters
therefore arrive unfiled and pile up at the root until this runs.

It only ever retires folders that are empty AND not one of the five, and
`Delete()` on a monster folder is a soft delete -- the record survives with
`hidden = true`.
