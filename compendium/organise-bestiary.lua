-- Organise the Crows bestiary: five type folders, everything filed, no strays.
--
-- Run through the MCP bridge (dmhub.ImportFile cannot do this -- folders are
-- ASSETS, not table items, and the monster YAML deliberately carries no
-- parentFolder because folder ids differ per game).
--
-- Why this exists: a game that has ever loaded Draw Steel inherits its whole
-- creature-type folder set -- Aberration, Beast, Celestial, Construct, Dragon,
-- Fey, Fiend, Giant, Humanoid, Monstrosity, Ooze, Plant, Swarm, Swarm of Tiny
-- beasts -- none of which exist in Crows. The Ref Book uses exactly five
-- types, counted off its "Type:" lines: Animal (32), Human (27), Undead (8),
-- Blood (3), Unique (1). Imported monsters also arrive with no folder at all
-- and pile up at the root.
--
-- Idempotent: safe to re-run after importing more monsters.
--
-- NOTE: Delete() on a monster folder is a SOFT delete -- it sets hidden=true
-- and the record stays. Only empty folders are ever touched.

local CROWS_TYPES = { "Animals", "Blood", "Human", "Undead", "Unique" }

-- monster_category (as written in the monster YAML) -> folder name
local CATEGORY_FOLDER = {
    ["Animal"]         = "Animals",
    ["Blood Creature"] = "Blood",
    ["Human"]          = "Human",
    ["Undead"]         = "Undead",
    ["Unique"]         = "Unique",
}

local attrs = table.concat(creature.attributeIds or {}, ", ")
if attrs ~= "agility, mind, strength" then
    print("GUARD: this is not a Crows game -- refusing to touch the bestiary")
    return
end

local function FoldersByName()
    local byName = {}
    for id, folder in pairs(assets.monsterFolders or {}) do
        local hidden, name = false, nil
        pcall(function() hidden = folder.hidden end)
        pcall(function() name = folder.description end)
        if not hidden and name ~= nil then
            byName[name] = { id = id, folder = folder }
        end
    end
    return byName
end

-- 1. Make sure the five Crows folders exist.
local byName = FoldersByName()
local created = 0
for _, name in ipairs(CROWS_TYPES) do
    if byName[name] == nil then
        assets:UploadNewMonsterFolder{ description = name }
        created = created + 1
    end
end
if created > 0 then
    printf("BESTIARY:: created %d folder(s) -- re-run to file monsters into them", created)
    return   -- the new folders are not readable until the upload lands
end

-- 2. File every monster under its type.
local todo = {}
for _, monster in pairs(assets.monsters or {}) do
    local hidden = false
    pcall(function() hidden = monster.hidden end)
    if not hidden then
        local category, parent = nil, nil
        pcall(function() category = monster.properties.monster_category end)
        pcall(function() parent = monster.parentFolder end)
        local wanted = CATEGORY_FOLDER[category]
        wanted = wanted ~= nil and byName[wanted] or nil
        if wanted ~= nil and parent ~= wanted.id then
            todo[#todo + 1] = { monster = monster, id = wanted.id }
        end
    end
end

-- 3. Retire every EMPTY folder that is not one of ours.
local populated = {}
for _, monster in pairs(assets.monsters or {}) do
    local hidden = false
    pcall(function() hidden = monster.hidden end)
    if not hidden then
        local parent = nil
        pcall(function() parent = monster.parentFolder end)
        if parent ~= nil then populated[parent] = true end
    end
end
local keep = {}
for _, name in ipairs(CROWS_TYPES) do keep[name] = true end

local doomed = {}
for name, entry in pairs(byName) do
    if not keep[name] and not populated[entry.id] then
        doomed[#doomed + 1] = entry.folder
    end
end

-- One upload per frame: SetAndUpload keeps only the LAST write to a table in a
-- given frame, so a tight loop would persist just the final change.
dmhub.Coroutine(function()
    for _, entry in ipairs(todo) do
        entry.monster.parentFolder = entry.id
        entry.monster:Upload()
        coroutine.yield(0.05)
    end
    for _, folder in ipairs(doomed) do
        pcall(function() folder:Delete() end)
        coroutine.yield(0.05)
    end
    printf("BESTIARY:: filed %d monster(s), retired %d empty non-Crows folder(s)",
        #todo, #doomed)
end)
