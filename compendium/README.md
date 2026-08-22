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
    loadfile("C:/dev/dmhub/draw-steel-codex/Crowdex/compendium/organise-bestiary.lua")()

The current local data store includes a stable top-level **Crows** folder with
five children: Animals, Blood Creatures, Humans, Undead, and Unique Creatures.
Every canonical Playtest 2 creature has a `parentFolder` pointing into that
tree, so a fresh game needs no organizer pass.

Run `organise-bestiary.lua` when the Crows game should contain only this local
bestiary. The script waits until the stable `Crows` root is loaded, preserves
that folder, every descendant folder, and every creature filed anywhere in the
tree. It then soft-deletes every visible bestiary creature and folder outside
the tree, including unfoldered records. Non-Crows folders are removed from the
leaves upward. The operation is idempotent and recoverable through DMHub's soft
deletion model.
