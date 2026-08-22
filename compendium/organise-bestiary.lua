-- Prune a Crows game's bestiary to the local Crowdex folder tree.
--
-- The Crows root, every descendant folder, and every creature filed anywhere
-- in that tree are preserved. Every visible creature and folder outside the
-- tree is soft-deleted. The Crows ruleset guard and root-folder check make the
-- cleanup refuse to run in another game or before the local data is loaded.

local CROWS_ROOT = "1609f940-294a-44c9-845c-5774b9d94437"

local attrs = table.concat(creature.attributeIds or {}, ", ")
if attrs ~= "agility, mind, strength" then
    print("GUARD: this is not a Crows game -- refusing to touch the bestiary")
    return
end

local folders = assets.monsterFolders or {}
if folders[CROWS_ROOT] == nil then
    print("BESTIARY:: local Crows folder data is not loaded -- no changes made")
    return
end

local function ReadAsset(asset)
    local hidden, parent = false, nil
    pcall(function() hidden = asset.hidden end)
    pcall(function() parent = asset.parentFolder end)
    return hidden, parent
end

-- Discover the protected tree recursively instead of hard-coding its current
-- children. Future folders nested under Crows are therefore protected too.
local keepFolders = { [CROWS_ROOT] = true }
local changed = true
while changed do
    changed = false
    for id, folder in pairs(folders) do
        if not keepFolders[id] then
            local _, parent = ReadAsset(folder)
            if parent ~= nil and keepFolders[parent] then
                keepFolders[id] = true
                changed = true
            end
        end
    end
end

local removeMonsters = {}
for _, monster in pairs(assets.monsters or {}) do
    local hidden, parent = ReadAsset(monster)
    if not hidden and not keepFolders[parent] then
        removeMonsters[#removeMonsters + 1] = monster
    end
end

-- Delete non-Crows folders from the leaves upward. This avoids asking DMHub to
-- remove a parent while one of its child folders is still visible.
local function FolderDepth(id)
    local depth = 0
    local seen = {}
    while id ~= nil and folders[id] ~= nil and not seen[id] do
        seen[id] = true
        local _, parent = ReadAsset(folders[id])
        id = parent
        depth = depth + 1
    end
    return depth
end

local removeFolders = {}
for id, folder in pairs(folders) do
    local hidden = ReadAsset(folder)
    if not hidden and not keepFolders[id] then
        removeFolders[#removeFolders + 1] = {
            folder = folder,
            depth = FolderDepth(id),
        }
    end
end
table.sort(removeFolders, function(a, b) return a.depth > b.depth end)

-- Asset uploads need to be separated by frames or only the last write can
-- persist. Both operations are DMHub soft deletions and remain recoverable.
dmhub.Coroutine(function()
    for _, monster in ipairs(removeMonsters) do
        monster.hidden = true
        monster:Upload()
        coroutine.yield(0.05)
    end
    for _, entry in ipairs(removeFolders) do
        pcall(function() entry.folder:Delete() end)
        coroutine.yield(0.05)
    end
    printf("BESTIARY:: preserved the Crows tree; retired %d creature(s) and %d folder(s) outside it",
        #removeMonsters, #removeFolders)
end)
