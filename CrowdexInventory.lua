local mod = dmhub.GetModLoading()

-- The Crows inventory tab on the character sheet. Crows is a slot-based
-- inventory game: ten labeled backpack slots, two hand slots, and two belt
-- slots (magic item slots come later). Unlike the Draw Steel inventory's
-- icon grid, slots here are wide horizontal text rows with a small icon.
--
-- Data model: token.properties.crowdex_inventory = {
--   backpack = { [1..10] = slot }, hands = { [1..2] = slot }, belt = { [1..2] = slot }
-- }
-- where slot = { itemid, name, icon, category, quantity }. The name/icon/
-- category fields are denormalized from tbl_Gear so the side character panel
-- can render cells without table lookups; itemid is the canonical reference.
--
-- Party inventory uses the engine's standard party stash (dmhub.GetPartyInfo
-- + GiveItem), so it stays compatible with the Draw Steel trade flows. The
-- item index section reads tbl_Gear and reuses the engine's create-item
-- dialog (dmhud.createItemDialog) for authoring new items.

local ROW_CAPACITY = {
    backpack = 10,
    hands = 2,
    belt = 2,
}

local HAND_LABELS = { "L", "R" }

-- Every slot row is this wide, regardless of section.
local SLOT_WIDTH = 280

-- Party and item index rows carry an extra button, so they get a little
-- more room, but stay capped rather than spanning the whole tab.
local LIST_WIDTH = 380

-- ---------------------------------------------------------------------------
-- Data helpers.
-- ---------------------------------------------------------------------------

local function GetHeroToken()
    if CharacterSheet.instance == false or CharacterSheet.instance == nil or not CharacterSheet.instance.valid then
        return nil
    end
    return CharacterSheet.instance.data.info.token
end

-- Mutate the hero inside the character sheet; the sheet owns the upload
-- lifecycle so we modify directly and fire refreshAll.
local function ChangeHero(fn)
    local token = GetHeroToken()
    if token == nil or token.properties == nil then return end
    fn(token.properties, token)
    CharacterSheet.instance:FireEvent("refreshAll")
end

local function GetInventoryRows(props)
    if props == nil then return {} end
    return props:try_get("crowdex_inventory", {}) or {}
end

-- Slots are keyed "slot1".."slot10". Numeric keys (and numeric-string keys,
-- which serialization normalizes back to numbers) make the row a sparse Lua
-- array, and sparse arrays get compacted on the serialization round-trip --
-- items silently slide up into the gaps left by empty slots.
local function SlotKey(index)
    return "slot" .. tostring(index)
end

local function GetSlot(props, kind, index)
    local rows = GetInventoryRows(props)
    local row = rows[kind]
    if row == nil then return nil end
    return row[SlotKey(index)] or row[index]
end

local function SetSlot(props, kind, index, slot)
    local rows = props:try_get("crowdex_inventory", {}) or {}
    rows[kind] = rows[kind] or {}
    rows[kind][SlotKey(index)] = slot
    rows[kind][index] = nil
    props.crowdex_inventory = rows
end

-- How many adjacent slots an item occupies (cards: "Occupies 2 Slots").
-- Declared as slotsRequired on the tbl_Gear entry; default 1.
local MAX_ITEM_SLOTS = 4

local function SlotsRequiredForItem(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item ~= nil then
        local n = tonumber(item:try_get("slotsRequired", 1))
        if n ~= nil and n >= 1 then
            return math.min(math.floor(n), MAX_ITEM_SLOTS)
        end
    end
    return 1
end

-- Armor Defense (The Rules booklet, Damage and Death): suits of armor and
-- shields declare their AD on the gear entry as crowsAD; shields also set
-- crowsShield. Current AD is mutable per-instance state stored on the slot
-- entry (entry.ad); it depletes as the item absorbs damage and is restored
-- by the Repair Armor rest activity.
local function ArmorADForItem(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item ~= nil then
        local ad = tonumber(item:try_get("crowsAD", 0))
        if ad ~= nil and ad > 0 then
            return math.floor(ad)
        end
    end
    return 0
end

local function IsShieldItem(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    return item ~= nil and item:try_get("crowsShield", false) == true
end

-- Weapons declare crowsWeaponType (the weapon skill: Bashing, Bow, Chopping,
-- Slashing, Stabbing). A weapon that also has crowsAD carries the Parry X
-- quality: while wielded in a hand it absorbs damage like a shield.
local function IsWeaponItem(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    return item ~= nil and item:try_get("crowsWeaponType") ~= nil
end

-- Usage Dice (The Rules booklet): UD track anything with finite uses or a
-- limited duration -- torches, lanterns, spellbooks, consumables. An item with
-- UD has a pool of d6s; rolling the pool removes every die that comes up 1 or 2
-- (a 1-in-3 chance of loss each roll), and at 0 UD the effect ends.
--
-- The gear entry declares the pool and how it behaves:
--   usageDice        -- pool size (number of d6s). 0/absent = no UD.
--   usageDiceTrigger -- when the pool is rolled:
--                         "activate" -- on each use (e.g. cast a spellbook)
--                         "dt"       -- at the end of each dungeon turn
--                         "manual"   -- only when rolled by hand (default)
--   usageDiceRestore -- how the pool is refilled:
--                         "rest"    -- restored to max on a rest
--                         "refuel"  -- restored by using usageDiceRefuel item
--                         "useless" -- never restored; spent permanently
--   usageDiceRefuel  -- (refuel only) the gear itemid that refuels this pool.
--
-- Current UD is mutable per-instance state on the slot entry (slot.ud), exactly
-- like armor's current AD (slot.ad). A nil slot.ud means "full" so freshly
-- acquired items start at their maximum without any add-time initialization.
local function UsageDiceForItem(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item ~= nil then
        local n = tonumber(item:try_get("usageDice", 0))
        if n ~= nil and n > 0 then
            return math.floor(n)
        end
    end
    return 0
end

local function UsageDiceTrigger(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    local t = item ~= nil and item:try_get("usageDiceTrigger", "manual") or "manual"
    t = string.lower(tostring(t))
    if t == "activate" or t == "dt" or t == "manual" then
        return t
    end
    return "manual"
end

local function UsageDiceRestore(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item == nil then return nil end
    local r = item:try_get("usageDiceRestore")
    if r == nil then return nil end
    r = string.lower(tostring(r))
    if r == "rest" or r == "refuel" or r == "useless" then
        return r
    end
    return nil
end

local function UsageDiceRefuelItem(itemid)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item == nil then return nil end
    local fuel = item:try_get("usageDiceRefuel")
    if fuel == nil or fuel == "" then return nil end
    return fuel
end

-- Current UD remaining for a slot instance. nil slot.ud reads as a full pool.
local function CurrentUsageDice(slot)
    if slot == nil then return 0 end
    local maxUD = UsageDiceForItem(slot.itemid)
    if maxUD <= 0 then return 0 end
    if slot.ud == nil then return maxUD end
    return math.max(0, math.min(math.floor(slot.ud), maxUD))
end

-- True if this slot holds a UD item whose pool is spent (0 remaining). A spent
-- item is inert: it stops being wielded on the token and can't be used (its
-- spellbook casting / light / etc. is unavailable) until its UD are restored.
-- Items without a UD pool are never depleted.
local function IsUsageDiceDepleted(slot)
    if slot == nil then return false end
    if UsageDiceForItem(slot.itemid) <= 0 then return false end
    return CurrentUsageDice(slot) <= 0
end

-- True if the crow carries at least one of the given gear itemid anywhere in
-- its inventory. Used to decide whether a refuel option is available.
local function HasItem(props, itemid)
    if itemid == nil then return false end
    for _, kind in ipairs({"hands", "belt", "backpack"}) do
        for i = 1, ROW_CAPACITY[kind] do
            local s = GetSlot(props, kind, i)
            if s ~= nil and s.itemid == itemid then return true end
        end
    end
    return false
end

-- Consume one unit of a gear itemid from anywhere in the crow's inventory
-- (hands, then belt, then backpack). Returns true if one was removed. Used to
-- spend a refuel consumable (a pint of oil, etc.) when refilling a UD pool.
local function ConsumeOneItem(props, itemid)
    if itemid == nil then return false end
    for _, kind in ipairs({"hands", "belt", "backpack"}) do
        for i = 1, ROW_CAPACITY[kind] do
            local s = GetSlot(props, kind, i)
            if s ~= nil and s.itemid == itemid then
                local q = (s.quantity or 1) - 1
                if q <= 0 then
                    SetSlot(props, kind, i, nil)
                else
                    s.quantity = q
                    SetSlot(props, kind, i, s)
                end
                return true
            end
        end
    end
    return false
end

-- Roll a slot's Usage Dice. Rolls one d6 per remaining UD with the 3D dice
-- (and a chat entry), then removes every die showing 1 or 2; the survivors
-- become the new pool. At 0 the pool is spent (the item greys out; whether it
-- can be refilled depends on usageDiceRestore). Async: the write-back happens
-- in the roll's complete callback, re-fetching the slot so a concurrent edit
-- doesn't clobber it.
local function RollUsageDiceForSlot(row, env, kind, index)
    local token = env.getToken(row)
    if token == nil or not token.valid or token.properties == nil then return end
    local slot = GetSlot(token.properties, kind, index)
    if slot == nil then return end
    local cur = CurrentUsageDice(slot)
    if cur <= 0 then return end

    local itemName = slot.name or "item"

    dmhub.Roll{
        roll = string.format("%dd6", cur),
        description = string.format("Usage Dice: %s", itemName),
        tokenid = token.charid,
        complete = function(rollInfo)
            if mod.unloaded then return end
            local survivors = 0
            for _, r in ipairs(rollInfo.rolls or {}) do
                -- A die is lost on a 1 or 2; 3-6 stays in the pool.
                if not r.dropped and (r.result or 0) > 2 then
                    survivors = survivors + 1
                end
            end

            env.change(row, function(props)
                local s = GetSlot(props, kind, index)
                if s == nil then return end
                s.ud = survivors
                SetSlot(props, kind, index, s)
            end)
            if env.refreshNow ~= nil then env.refreshNow(row) end
        end,
    }
end

-- Restore a slot's UD pool to full (slot.ud = nil reads as the maximum). Used
-- by the rest restore and as a manual GM convenience.
local function RestoreUsageDice(row, env, kind, index)
    env.change(row, function(props)
        local s = GetSlot(props, kind, index)
        if s == nil then return end
        s.ud = nil
        SetSlot(props, kind, index, s)
    end)
    if env.refreshNow ~= nil then env.refreshNow(row) end
end

-- Refuel a slot's UD pool: spend one of its refuel consumable, then refill to
-- full. No-op (returns false) if the crow has none of the fuel item.
local function RefuelUsageDice(row, env, kind, index)
    local token = env.getToken(row)
    if token == nil or not token.valid or token.properties == nil then return false end
    local slot = GetSlot(token.properties, kind, index)
    if slot == nil then return false end
    local fuelId = UsageDiceRefuelItem(slot.itemid)
    if fuelId == nil then return false end

    local refilled = false
    env.change(row, function(props)
        if not ConsumeOneItem(props, fuelId) then return end
        local s = GetSlot(props, kind, index)
        if s == nil then return end
        s.ud = nil
        SetSlot(props, kind, index, s)
        refilled = true
    end)
    if env.refreshNow ~= nil then env.refreshNow(row) end
    return refilled
end

-- Slot entries snapshot the item's icon when the item is added (see
-- MakeSlotEntry), so compendium edits wouldn't show on already-stored
-- inventories. Resolve against the live gear table at render time; the
-- snapshot remains the fallback for items deleted from the table.
local function LiveItemIcon(entry)
    if entry == nil then return nil end
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = entry.itemid ~= nil and gearTable[entry.itemid] or nil
    if item ~= nil then
        return item:GetIcon()
    end
    return entry.icon
end

-- A wearable suit of armor: has an AD pool but is neither a shield nor a
-- weapon (those are wielded in hands, not worn). Only suits get the worn flag.
local function IsWearableArmor(itemid)
    return ArmorADForItem(itemid) > 0 and not IsShieldItem(itemid) and not IsWeaponItem(itemid)
end

local function HasWornArmor(props)
    for i = 1, ROW_CAPACITY.backpack do
        local slot = GetSlot(props, "backpack", i)
        if slot ~= nil and slot.worn == true and IsWearableArmor(slot.itemid) then
            return true
        end
    end
    return false
end

-- When a suit of armor lands in a backpack slot and the crow isn't already
-- wearing one, auto-wear it (the rules let you don a new suit out of combat;
-- this is the convenient default). Only fires for the specific slot just
-- filled, so deliberately taking armor off (Stop Wearing) and then adding an
-- unrelated item won't silently re-equip it.
local function MaybeAutoWearArmor(props, kind, index)
    if kind ~= "backpack" then return end
    local slot = GetSlot(props, "backpack", index)
    if slot == nil or not IsWearableArmor(slot.itemid) then return end
    if HasWornArmor(props) then return end
    slot.worn = true
    SetSlot(props, "backpack", index, slot)
end

local function MakeSlotEntry(item, quantity)
    local entry = {
        itemid = item.id,
        name = item.name,
        icon = item:GetIcon(),
        category = item:try_get("category", "Gear"),
        quantity = quantity or 1,
        slots = SlotsRequiredForItem(item.id),
    }
    local ad = ArmorADForItem(item.id)
    if ad > 0 then
        entry.ad = ad
    end
    return entry
end

-- Multi-slot items are stored once, anchored at their lowest slot index, and
-- cover (anchor .. anchor + slots - 1). Returns the anchor index and entry
-- covering the given slot, or nil if the slot is free.
local function OccupantOf(props, kind, index)
    for back = 0, MAX_ITEM_SLOTS - 1 do
        local i = index - back
        if i >= 1 then
            local entry = GetSlot(props, kind, i)
            if entry ~= nil then
                if i + (entry.slots or 1) - 1 >= index then
                    return i, entry
                end
                -- The nearest entry at or below us doesn't reach this slot,
                -- and entries can't overlap, so the slot is free.
                return nil
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Wounds.
--
-- A crow's wounds fill backpack slots (The Rules, Damage and Death). Each
-- wounded slot is crowdex_woundSlots[SlotKey(i)] = true, keyed "slot1".."slot10"
-- to dodge the sparse-array compaction that bites numeric keys on a
-- serialization round-trip (same reason inventory slots use SlotKey).
--
-- Speed: only a slot holding BOTH a wound and an item costs 1 speed. A wound
-- on an empty slot is free. That is why wounds auto-assign to empty slots
-- first (see AssignWound) -- it minimizes speed loss.
-- ---------------------------------------------------------------------------

local CROWS_BACKPACK_SLOTS = ROW_CAPACITY.backpack

local function GetWoundSlotMap(props)
    return props:try_get("crowdex_woundSlots", {}) or {}
end

-- Read with fallback to the old numeric / numeric-string keys so characters
-- wounded before the key-format change still display correctly.
local function IsSlotWounded(props, index)
    local ws = GetWoundSlotMap(props)
    return ws[SlotKey(index)] == true or ws[index] == true or ws[tostring(index)] == true
end

local function SetSlotWounded(props, index, wounded)
    local ws = props:try_get("crowdex_woundSlots", {}) or {}
    ws[index] = nil
    ws[tostring(index)] = nil
    if wounded then
        ws[SlotKey(index)] = true
    else
        ws[SlotKey(index)] = nil
    end
    props.crowdex_woundSlots = ws
end

local function CountWoundedSlots(props)
    local n = 0
    for i = 1, CROWS_BACKPACK_SLOTS do
        if IsSlotWounded(props, i) then n = n + 1 end
    end
    return n
end

-- Speed penalty: backpack slots that hold a wound AND an item.
local function CountWoundedItemSlots(props)
    local n = 0
    for i = 1, CROWS_BACKPACK_SLOTS do
        if IsSlotWounded(props, i) and OccupantOf(props, "backpack", i) ~= nil then
            n = n + 1
        end
    end
    return n
end

-- Place one wound following the Crows auto-assignment rule: fill from the
-- BOTTOM of the backpack up. The lowest (highest-index) empty unwounded slot
-- first (no speed cost), else the lowest unwounded slot that holds an item.
-- Returns the slot index, or nil if every backpack slot is already wounded
-- (which means the crow is dead -- IsDead).
local function AssignWound(props)
    for i = CROWS_BACKPACK_SLOTS, 1, -1 do
        if not IsSlotWounded(props, i) and OccupantOf(props, "backpack", i) == nil then
            SetSlotWounded(props, i, true)
            return i
        end
    end
    for i = CROWS_BACKPACK_SLOTS, 1, -1 do
        if not IsSlotWounded(props, i) then
            SetSlotWounded(props, i, true)
            return i
        end
    end
    return nil
end

-- Move a wound from one backpack slot to another (drag-to-reassign). No-op if
-- the source is not wounded or the destination is already wounded.
local function MoveWound(props, fromIndex, toIndex)
    if fromIndex == toIndex then return false end
    if not IsSlotWounded(props, fromIndex) then return false end
    if IsSlotWounded(props, toIndex) then return false end
    SetSlotWounded(props, fromIndex, false)
    SetSlotWounded(props, toIndex, true)
    return true
end

-- True when slots (anchor .. anchor+n-1) all exist in the section and are
-- free. ignoreKind/ignoreAnchor exclude an item's own current position so it
-- can be moved to an overlapping span.
local function SpanFree(props, kind, anchor, n, ignoreKind, ignoreAnchor)
    if anchor < 1 or anchor + n - 1 > ROW_CAPACITY[kind] then
        return false
    end
    for i = anchor, anchor + n - 1 do
        local occAnchor = OccupantOf(props, kind, i)
        if occAnchor ~= nil and not (kind == ignoreKind and occAnchor == ignoreAnchor) then
            return false
        end
    end
    return true
end

-- Where an n-slot item lands when dropped on a slot: it takes that slot plus
-- the next one(s); if those aren't available, it instead ends its span on
-- the dropped slot (i.e. takes the previous slot(s)). Returns the anchor
-- index, or nil if neither placement fits.
local function PlacementAnchor(props, kind, index, n, ignoreKind, ignoreAnchor)
    if SpanFree(props, kind, index, n, ignoreKind, ignoreAnchor) then
        return index
    end
    if n > 1 and SpanFree(props, kind, index - n + 1, n, ignoreKind, ignoreAnchor) then
        return index - n + 1
    end
    return nil
end

-- Crows stacking rule (The Rules booklet, Inventory Slots): most items do
-- NOT stack; an item's card declares "Stack N" when it does (potions 5,
-- locks 3, torches 2, rations 6...). Items carry that as a stackLimit field
-- in tbl_Gear; items without one hold 1 per slot. Hand slots never stack,
-- whatever the item ("Each hand can only hold one item at a time").
local function MaxStackForItem(itemid, kind)
    if kind == "hands" then
        return 1
    end
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item ~= nil then
        local m = tonumber(item:try_get("stackLimit", item:try_get("maxQuantity", 1)))
        if m ~= nil and m >= 1 then
            return math.floor(m)
        end
    end
    return 1
end

-- Items sold in bundles (ammunition: a quiver or case of 20) keep a single
-- unit as their tbl_Gear record -- one arrow, one bolt -- and declare the
-- bundle size as massQuantity. One Item Index pull (or party-stash take)
-- grants the whole bundle; in inventory the units then behave as an
-- ordinary stack, governed by stackLimit as usual. Items without
-- massQuantity pull one at a time.
local function PullQuantityForItem(item)
    if item == nil then return 1 end
    local n = tonumber(item:try_get("massQuantity", 1)) or 1
    if n < 1 then n = 1 end
    return math.floor(n)
end

-- First anchor index with n adjacent free slots (n defaults to 1).
local function FirstEmptySlot(props, kind, n)
    n = n or 1
    for i = 1, ROW_CAPACITY[kind] - n + 1 do
        if SpanFree(props, kind, i, n) then
            return i
        end
    end
    return nil
end

-- Add quantity of an item to the character: stacks onto an existing slot
-- holding the same item (respecting the item's stack limit), else takes the
-- first empty slot in one of the new-placement sections. placementKinds is the
-- ordered list of sections to try for a fresh slot (default: backpack only);
-- pass {"backpack", "belt"} to let the belt absorb backpack overflow. Returns
-- true on success, false if there was no room.
local function AddItemToCharacter(props, item, quantity, placementKinds)
    quantity = quantity or 1
    for _, kind in ipairs({"hands", "belt", "backpack"}) do
        local maxStack = MaxStackForItem(item.id, kind)
        for i = 1, ROW_CAPACITY[kind] do
            local slot = GetSlot(props, kind, i)
            if slot ~= nil and slot.itemid == item.id and (slot.quantity or 1) + quantity <= maxStack then
                slot.quantity = (slot.quantity or 1) + quantity
                SetSlot(props, kind, i, slot)
                return true
            end
        end
    end

    local slotsRequired = SlotsRequiredForItem(item.id)
    for _, kind in ipairs(placementKinds or {"backpack"}) do
        local index = FirstEmptySlot(props, kind, slotsRequired)
        if index ~= nil then
            SetSlot(props, kind, index, MakeSlotEntry(item, math.min(quantity, MaxStackForItem(item.id, kind))))
            if kind == "backpack" then
                MaybeAutoWearArmor(props, "backpack", index)
            end
            return true
        end
    end
    return false
end

-- Grant a list of starting items to a Crows character at creation time.
-- items: array of { item = tbl_Gear entry, quantity = number }.
--
-- A crow's gear normally lives in the ten backpack slots. When a background
-- grants more than ten items' worth of gear the backpack overflows, so the two
-- belt slots are pressed into service as well. Because the belt is quick-draw
-- storage, weapons are preferred for it: non-weapons fill the backpack first,
-- then weapons are placed (backpack, then belt), so an overflowing weapon lands
-- on the belt rather than being dropped to the engine inventory. Anything that
-- still doesn't fit (belt full too) falls back to the engine inventory, which
-- the Inventory tab migrates into slots as room frees up.
local function GrantStartingItems(props, items)
    local weapons, others = {}, {}
    for _, entry in ipairs(items) do
        if entry.item ~= nil then
            if IsWeaponItem(entry.item.id) then
                weapons[#weapons + 1] = entry
            else
                others[#others + 1] = entry
            end
        end
    end

    -- Places one entry's units one at a time into the given sections; returns
    -- any quantity that didn't fit so the caller can fall it back further.
    local function place(entry, placementKinds)
        local remaining = math.max(1, math.floor(tonumber(entry.quantity) or 1))
        while remaining > 0 and AddItemToCharacter(props, entry.item, 1, placementKinds) do
            remaining = remaining - 1
        end
        return remaining
    end

    -- Non-weapons fill the backpack first; weapons then take backpack space
    -- but spill onto the belt before anything else does. Whatever still
    -- overflows (including backpack-overflow non-weapons) tries the belt last,
    -- then the engine inventory.
    local leftover = {}
    for _, entry in ipairs(others) do
        local n = place(entry, {"backpack"})
        if n > 0 then leftover[#leftover + 1] = { item = entry.item, quantity = n } end
    end
    for _, entry in ipairs(weapons) do
        local n = place(entry, {"backpack", "belt"})
        if n > 0 then leftover[#leftover + 1] = { item = entry.item, quantity = n } end
    end
    for _, entry in ipairs(leftover) do
        local n = place(entry, {"belt"})
        if n > 0 then
            props:GiveItem(entry.item.id, n)
        end
    end
end

-- Slot-placement API for other Crowdex files. CrowdexModifiers' Starting
-- Equipment claim uses this to land granted gear directly in Crows slots
-- rather than going through the engine inventory + reconcile round trip.
CrowdexInventory = {
    AddItemToCharacter = AddItemToCharacter,
    GrantStartingItems = GrantStartingItems,
}

-- Loot picked up off the map (and anything else the engine gives a creature)
-- lands in the Draw Steel inventory model: creature.inventory, a map of
-- itemid -> {quantity}. Crows characters carry items in crowdex_inventory
-- slots instead, so migrate anything that shows up there into slots, one
-- unit at a time so stack limits and multi-slot placement apply. Items that
-- don't fit stay in the engine inventory for a later attempt.
local function ReconcileEngineInventory(props)
    local engineInv = props:try_get("inventory")
    if engineInv == nil then return false end

    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local pending = {}
    for itemid, entry in pairs(engineInv) do
        local quantity = entry.quantity or 0
        if quantity > 0 and gearTable[itemid] ~= nil then
            pending[#pending + 1] = { item = gearTable[itemid], quantity = quantity }
        end
    end

    local changed = false
    for _, p in ipairs(pending) do
        local moved = 0
        for i = 1, p.quantity do
            if AddItemToCharacter(props, p.item, 1) then
                moved = moved + 1
            else
                break
            end
        end
        if moved > 0 then
            props:GiveItem(p.item.id, -moved)
            changed = true
        end
    end

    return changed
end

local function GetParty()
    local token = GetHeroToken()
    if token == nil or token.partyid == nil or token.partyid == "" then
        return nil
    end
    return dmhub.GetPartyInfo(token.partyid)
end

-- Give quantity (may be negative) of an item to the stash of the party the
-- given token belongs to.
local function GivePartyItem(token, itemid, quantity)
    if token == nil or token.partyid == nil or token.partyid == "" then
        return false
    end
    local partyInfo = dmhub.GetPartyInfo(token.partyid)
    if partyInfo == nil then return false end
    partyInfo:BeginChanges()
    partyInfo.properties:GiveItem(itemid, quantity)
    partyInfo:CompleteChanges("Transfer item")
    return true
end

-- Drop a physical, lootable manifestation of the item on the map at the
-- character's feet -- the Draw Steel inventory's drop pattern
-- (DrawSteelInventory.lua "Drop Item"). Returns false when the character
-- isn't on a map, in which case the caller should leave the item alone.
local function DropItemOnMap(token, slotEntry, quantity)
    if token == nil or not token.valid then return false end
    if token.floorid == nil or token.floorid == "" or token.loc == nil then return false end
    local floor = game.GetFloor(token.floorid)
    if floor == nil then return false end

    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local itemInfo = gearTable[slotEntry.itemid]
    if itemInfo == nil then return false end

    floor:CreateObject{
        asset = {
            description = itemInfo.name,
            imageId = dmhub.GetRawImageId(itemInfo.iconid),
            hidden = false,
        },
        components = {
            CORE = {
                ["@class"] = "ObjectComponentCore",
                hasShadow = false,
                height = 1,
                pivot_x = 0.5,
                pivot_y = 0.5,
                rotation = 0,
                scale = 0.4,
                sprite_invisible_to_players = false,
            },

            LOOT = {
                ["@class"] = "ObjectComponentLoot",
                destroyOnEmpty = true,
                instantLoot = true,
                locked = false,
                properties = {
                    __typeName = "loot",
                    inventory = {
                        [slotEntry.itemid] = {
                            quantity = quantity,
                        },
                    },
                },
            },

            MOVEABLE = {
                ["@class"] = "ObjectComponentMoveable",
            },
        },
        assetid = "none",
        inactive = false,
        pos = {
            x = token.loc.x + 0.5,
            y = token.loc.y - 0.5,
        },

        zorder = 1,
    }

    return true
end

-- The character's active AD sources: the worn suit of armor (a backpack
-- entry flagged worn = true; per the rules the worn suit stays in backpack
-- slots) and any shields held in hand slots.
--
-- Ordered by damage priority: the FIRST piece in the list is the one that
-- absorbs (and is destroyed) first. The order is the adPriority field on
-- the slot entries (set by drag-reordering the Armor Defense rows in the
-- character panel); pieces without one sort after, in discovery order.
local function ArmorPieces(props)
    local result = {}
    local function consider(kind, i, requireWielded, requireWorn)
        local slot = GetSlot(props, kind, i)
        if slot == nil then return end
        if requireWorn and slot.worn ~= true then return end
        -- In hands, shields and Parry-quality weapons count as AD sources.
        if requireWielded and not (IsShieldItem(slot.itemid) or IsWeaponItem(slot.itemid)) then return end
        local max = ArmorADForItem(slot.itemid)
        if max > 0 then
            -- A Parry weapon (a wielded weapon with AD) can be toggled off in
            -- the Armor Defense list so it stops absorbing damage. It still
            -- appears (so it can be toggled back on) but is not active. Worn
            -- armor and shields are always active.
            local isParryWeapon = (kind == "hands") and IsWeaponItem(slot.itemid)
            local active = not (isParryWeapon and slot.parryOff == true)
            result[#result + 1] = {
                name = slot.name,
                ad = slot.ad or max,
                adMax = max,
                icon = LiveItemIcon(slot),
                kind = kind,
                index = i,
                priority = slot.adPriority,
                seq = #result + 1,
                isParryWeapon = isParryWeapon,
                active = active,
            }
        end
    end

    for i = 1, ROW_CAPACITY.backpack do
        consider("backpack", i, false, true)
    end
    for i = 1, ROW_CAPACITY.hands do
        consider("hands", i, true, false)
    end

    table.sort(result, function(a, b)
        local pa = a.priority or math.huge
        local pb = b.priority or math.huge
        if pa ~= pb then
            return pa < pb
        end
        return a.seq < b.seq
    end)
    return result
end

-- ---------------------------------------------------------------------------
-- Token Armor Defense bar.
--
-- A greyish-blue bar stacked just below the Stamina bar showing total Armor
-- Defense (current / max summed across the creature's active armor pieces).
-- Only creatures that carry AD (Crows with worn armor, shields, or Parry
-- weapons) get one -- the bar is suppressed entirely when total AD is 0, so it
-- never appears on monsters or non-Crows characters. Visibility mirrors the
-- Stamina bar's own settings (DMHub Token UI/TokenUIConfig.lua).
-- ---------------------------------------------------------------------------
local function CrowsTotalAD(props)
    local cur, max = 0, 0
    for _, piece in ipairs(ArmorPieces(props)) do
        if piece.active ~= false then
            cur = cur + (piece.ad or piece.adMax or 0)
            max = max + (piece.adMax or 0)
        end
    end
    return cur, max
end

TokenUI.RegisterStatusBar{
    id = "crowsArmorDefense",
    order = -1, -- sort ahead of the Stamina bar (cosmetic)
    y = 3,      -- stack just above the Stamina bar (which sits at y = 14;
                -- larger y is lower on screen, so a smaller y sits higher)
    height = 9,
    width = 1,
    seek = 10,
    fillColor = "#7d8aa5", -- greyish-blue
    emptyColor = "#15171c",

    showToGM = function() return dmhub.GetSettingValue("hpbarfordm") end,
    showToController = function() return dmhub.GetSettingValue("hpbarforownplayer") end,
    showToFriends = function() return dmhub.GetSettingValue("hpbarforparty") end,
    showToEnemies = function()
        return (dmhub.GetSettingValue("enemystambardisplay") or "none") ~= "none"
    end,

    Filter = function(props)
        return props.typeName == "character"
    end,

    Calculate = function(props)
        if dmhub.GetSettingValue("hpbarsonlyincombat") then
            local q = dmhub.initiativeQueue
            if q == nil or q.hidden then
                return nil
            end
        end

        local cur, max = CrowsTotalAD(props)
        if max <= 0 then
            return nil
        end

        return {
            value = cur,
            max = max,
            width = 1,
        }
    end,
}

dmhub.InvalidateTokenUI()

-- ---------------------------------------------------------------------------
-- Shared widgets.
-- ---------------------------------------------------------------------------

local function SectionHeading(text)
    return gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 14,
        bold = true,
        color = "#e8d59a",
        text = text,
        tmargin = 10,
        bmargin = 4,
    }
end

-- Inventory item card tooltip palette / layout, modelled on the printed Crows
-- inventory cards (see the May/June 2026 playtest Inventory Cards booklet).
local CARD_GOLD = "#e8d59a"
local CARD_TEXT = "#dcdce4"
local CARD_SUBTLE = "#b8b0a0"
local CARD_LINE = "#5a5a6e"
local CARD_WIDTH = 232

-- Splits an item description into its body prose and a trailing "Craft: ..."
-- clause (the cards print the crafting requirement in a footer). craftText is
-- nil when the description has no Craft: clause.
local function SplitCraftText(desc)
    if desc == nil or desc == "" then
        return "", nil
    end
    local idx = string.find(desc, "Craft:", 1, true)
    if idx == nil then
        return string.trim(desc), nil
    end
    return string.trim(string.sub(desc, 1, idx - 1)), string.trim(string.sub(desc, idx))
end

-- A two-row mini power-roll table (tier header over damage values), mirroring
-- the 12-16 / 17+ columns on the printed weapon cards.
local function PowerRollTablePanel(tier2, tier3)
    local cols = {}
    if tier2 ~= nil and tier2 ~= "" then
        cols[#cols + 1] = { head = "12-16", val = tier2 }
    end
    if tier3 ~= nil and tier3 ~= "" then
        cols[#cols + 1] = { head = "17+", val = tier3 }
    end
    if #cols == 0 then
        return nil
    end

    local cellWidth = math.floor(CARD_WIDTH / #cols)
    local function cell(text, isHead)
        return gui.Label{
            text = text,
            width = cellWidth,
            height = "auto",
            minHeight = 18,
            borderWidth = 1,
            borderColor = CARD_LINE,
            borderBox = true,
            vpad = 2,
            hpad = 3,
            fontSize = 12,
            bold = isHead,
            color = cond(isHead, CARD_GOLD, CARD_TEXT),
            textAlignment = "center",
            valign = "center",
            interactable = false,
        }
    end

    local headRow, valRow = {}, {}
    for _, c in ipairs(cols) do
        headRow[#headRow + 1] = cell(c.head, true)
        valRow[#valRow + 1] = cell(c.val, false)
    end

    return gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        tmargin = 3,
        bmargin = 3,
        children = {
            gui.Panel{ width = "auto", height = "auto", flow = "horizontal", children = headRow },
            gui.Panel{ width = "auto", height = "auto", flow = "horizontal", children = valRow },
        },
    }
end

-- Builds the card-style detail panel for an inventory item: a name + stack
-- header, then either a weapon stat block (range, attack, power-roll table,
-- qualities) or descriptive prose for non-weapons, then a craft / cost footer.
local function BuildItemCardPanel(item)
    local children = {}

    -- Header: item name with the stack limit floated to the right.
    local headerChildren = {
        gui.Label{
            text = item.name,
            width = "auto",
            maxWidth = CARD_WIDTH - 50,
            height = "auto",
            fontSize = 15,
            bold = true,
            color = CARD_GOLD,
            halign = "left",
            valign = "center",
            textAlignment = "left",
            interactable = false,
        },
    }
    local stackLimit = item:try_get("stackLimit")
    if stackLimit ~= nil and stackLimit > 1 then
        headerChildren[#headerChildren + 1] = gui.Label{
            text = string.format("Stack %d", stackLimit),
            floating = true,
            halign = "right",
            valign = "center",
            width = "auto",
            height = "auto",
            fontSize = 12,
            bold = true,
            color = CARD_SUBTLE,
            interactable = false,
        }
    end
    children[#children + 1] = gui.Panel{
        width = CARD_WIDTH,
        height = "auto",
        flow = "horizontal",
        valign = "center",
        bmargin = 2,
        children = headerChildren,
    }

    local function addLabel(text, params)
        local args = {
            text = text,
            width = CARD_WIDTH,
            height = "auto",
            fontSize = 13,
            color = CARD_TEXT,
            halign = "left",
            textAlignment = "left",
            interactable = false,
        }
        if params ~= nil then
            for k, v in pairs(params) do
                args[k] = v
            end
        end
        children[#children + 1] = gui.Label(args)
    end

    local body, craftText = SplitCraftText(item:try_get("description", ""))

    local wtype = item:try_get("crowsWeaponType")
    if wtype ~= nil then
        -- Weapon stat block.
        local rangeParts = {}
        local melee = item:try_get("crowsMeleeRange")
        local ranged = item:try_get("crowsRangedRange")
        if melee ~= nil then
            rangeParts[#rangeParts + 1] = string.format("Melee %d", melee)
        end
        if ranged ~= nil then
            rangeParts[#rangeParts + 1] = string.format("Ranged %d", ranged)
        end
        if #rangeParts > 0 then
            addLabel(string.format("<i>%s</i>", table.concat(rangeParts, "/")), { color = CARD_SUBTLE })
        end

        local stat = item:try_get("crowsAttackStat")
        if stat ~= nil then
            addLabel(string.format("<b>Attack</b> 2d10 + %s", stat))
        end

        local tablePanel = PowerRollTablePanel(item:try_get("crowsTier2"), item:try_get("crowsTier3"))
        if tablePanel ~= nil then
            children[#children + 1] = tablePanel
        end

        local qline = wtype
        local quals = item:try_get("crowsQualities", "")
        if quals ~= "" then
            qline = string.format("%s, %s", wtype, quals)
        end
        addLabel(string.format("<i>%s</i>", qline), { color = CARD_SUBTLE })
    elseif body ~= "" then
        -- Non-weapon: render the descriptive prose (includes any inline tiers,
        -- maneuver/action lines, AD value, etc.).
        addLabel(body, { markdown = true })
    end

    -- Footer: crafting requirement and gold cost.
    if craftText ~= nil and craftText ~= "" then
        addLabel(craftText, { fontSize = 11, color = CARD_SUBTLE, tmargin = 4 })
    end
    local cost = item:try_get("costInGold")
    if cost ~= nil and cost > 0 then
        addLabel(string.format("%g gc", cost), {
            fontSize = 11,
            bold = true,
            color = CARD_GOLD,
            tmargin = cond(craftText ~= nil and craftText ~= "", 0, 4),
        })
    end

    return gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        children = children,
    }
end

local function ItemTooltip(element, itemid, fallbackName)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local item = itemid ~= nil and gearTable[itemid] or nil
    if item ~= nil then
        element.tooltip = gui.TooltipFrame(BuildItemCardPanel(item))
        return
    end
    if fallbackName ~= nil then
        element.tooltip = gui.TooltipFrame(gui.Label{
            text = fallbackName,
            width = "auto",
            height = "auto",
            fontSize = 14,
            bold = true,
            color = CARD_GOLD,
            interactable = false,
        })
    end
end

-- ---------------------------------------------------------------------------
-- Slot rows.
-- ---------------------------------------------------------------------------

-- One wide horizontal slot row: slot label, small icon, item name, quantity.
-- Right-clicking a filled slot opens a menu of actions (transfer, move,
-- split, drop, destroy); rows drag onto each other with the engine's drag
-- system.
--
-- Rows are shared between the character sheet's Inventory tab and the
-- docked character panel. The env parameter supplies the context-specific
-- bits:
--   env.change(row, fn)  -- apply a mutation; fn receives (props, token).
--                           The sheet mutates directly (the sheet owns the
--                           upload lifecycle); the panel wraps the mutation
--                           in token:ModifyProperties.
--   env.getToken(row)    -- the token this row is currently displaying.
-- Rows respond to both refreshCharacterInfo (sheet, receives props) and
-- refreshCharacter (panel, receives the token).
local g_slotRowStyles = {
    {
        selectors = {"crowsInvSlot"},
        bgcolor = "#1c1c28",
        borderWidth = 1,
        borderColor = "#3a3a4a",
    },
    {
        selectors = {"crowsInvSlot", "hover"},
        bgcolor = "#3a3a5c",
        borderColor = "#e8d59a",
    },
    -- A wounded backpack slot (Crows: wounds fill backpack slots).
    {
        selectors = {"crowsInvSlot", "wounded"},
        bgcolor = "#2a1616",
        borderColor = "#aa3333",
    },
    -- The row currently being dragged (the engine applies the dragging
    -- class). Rows use dragMove = false so the panel itself stays put; this
    -- highlight plus the drag-target glow on destinations is the feedback.
    {
        selectors = {"crowsInvSlot", "dragging"},
        bgcolor = "#4a4422",
        borderColor = "#ffdd66",
        borderWidth = 2,
    },
}

-- One small d6 face for the Usage Dice strip: white/gold when the die is still
-- in the pool, grey when it has been spent.
local UD_PIP_SIZE = 12
local function UsageDicePip(available)
    return gui.Panel{
        width = UD_PIP_SIZE,
        height = UD_PIP_SIZE,
        bgimage = "panels/square.png",
        bgcolor = available and "#f3ead0" or "#3a3a3a",
        borderWidth = 1,
        borderColor = available and "#caa45c" or "#555555",
        cornerRadius = 2,
        hmargin = 1,
        valign = "center",
        interactable = false,
    }
end

local function SlotRow(kind, index, label, env)
    local iconPanel = gui.Panel{
        width = 18,
        height = 18,
        valign = "center",
        rmargin = 6,
        bgimage = "panels/square.png",
        bgcolor = "clear",
        interactable = false,
    }

    -- Fixed width so the quantity column right-aligns identically on every
    -- row: slot width minus padding (12), slot label (20), icon (18+6
    -- margin), and the quantity column (30).
    local nameLabel = gui.Label{
        width = SLOT_WIDTH - 12 - 20 - 24 - 30,
        height = "auto",
        fontSize = 12,
        color = "#666666",
        valign = "center",
        italics = true,
        interactable = false,
        text = "(empty)",
    }

    local row

    -- Editable: type a number to set the stack size directly. Clamped to
    -- [0, item stack limit]; 0 empties the slot.
    local quantityLabel = gui.Label{
        width = 30,
        height = 18,
        fontSize = 11,
        color = "#aaaaaa",
        valign = "center",
        textAlignment = "right",
        editable = false,
        characterLimit = 5,
        text = "",

        change = function(element)
            env.change(row, function(props)
                local slot = GetSlot(props, kind, index)
                if slot == nil then return end
                -- AD values display with an "AD " prefix; accept edits that
                -- keep it ("AD 3") as well as bare numbers ("3").
                local n = tonumber(element.text) or tonumber(string.match(element.text, "%d+") or "")
                if n == nil then return end
                n = math.floor(n)

                if row.data.numberMode == "ad" then
                    -- The number column shows current AD for armor items.
                    slot.ad = math.max(0, math.min(n, ArmorADForItem(slot.itemid)))
                    SetSlot(props, kind, index, slot)
                    return
                end

                n = math.max(0, math.min(n, MaxStackForItem(slot.itemid, kind)))
                if n <= 0 then
                    SetSlot(props, kind, index, nil)
                else
                    slot.quantity = n
                    SetSlot(props, kind, index, slot)
                end
            end)
        end,
    }

    -- The drop receiver: a transparent overlay registered with the engine's
    -- drag system via dragTarget = true (the same pattern the Draw Steel
    -- inventory uses). The engine toggles the drag-target / drag-target-hover
    -- classes on it while a compatible drag is in flight.
    local dropTarget = gui.Panel{
        floating = true,
        x = 0,
        y = 0,
        width = "100%",
        height = "100%",
        halign = "left",
        valign = "top",
        bgimage = "panels/square.png",
        bgcolor = "clear",
        interactable = false,
        dragTarget = true,

        data = {
            kind = kind,
            index = index,
        },

        styles = {
            {
                selectors = {"drag-target"},
                borderWidth = 1,
                borderColor = "#e8d59aaa",
                bgcolor = "#e8d59a22",
            },
            {
                selectors = {"drag-target-hover"},
                borderWidth = 2,
                borderColor = "#ffdd66",
                bgcolor = "#e8d59a44",
            },
        },
    }

    -- The wound marker: a draggable red dot shown on a wounded backpack slot.
    -- Drag it onto another backpack slot to move the wound there. Backpack
    -- rows only; hands/belt never take wounds. Sits on top of the dropTarget
    -- (added after it in the children list) so it captures its own press for
    -- the wound drag while the rest of the row still drags the item.
    local woundIcon = nil
    if kind == "backpack" then
        woundIcon = gui.Panel{
            classes = {"crowsWoundMarker", "hidden"},
            floating = true,
            halign = "right",
            valign = "center",
            rmargin = 4,
            width = 18,
            height = 18,
            bgimage = "panels/square.png",
            bgcolor = "#cc2222",
            cornerRadius = 9,
            borderWidth = 1,
            borderColor = "#ff8080",
            hoverCursor = "hand",
            draggable = false,

            styles = {
                { selectors = {"crowsWoundMarker", "dragging"}, bgcolor = "#ff5555", brightness = 1.4 },
                -- Optimistically placed, awaiting network confirmation.
                { selectors = {"crowsWoundMarker", "pending"}, opacity = 0.4 },
            },

            linger = function(element)
                gui.Tooltip("Wound. Drag to another backpack slot to move it.")(element)
            end,

            canDragOnto = function(element, target)
                if target.data == nil or target.data.kind ~= "backpack" or target.data.index == nil then
                    return false
                end
                if target.data.index == index then return false end
                local props = env.getToken(row) ~= nil and env.getToken(row).properties or nil
                if props == nil then return false end
                return not IsSlotWounded(props, target.data.index)
            end,

            drag = function(element, target)
                if target == nil or target.data == nil or target.data.index == nil then return end
                local toIndex = target.data.index
                env.change(row, function(props)
                    MoveWound(props, index, toIndex)
                    -- Optimistic: in a networked context the row only repaints
                    -- on the echo, so mark the destination pending (faded)
                    -- and paint it now; the echo clears the flag (full color).
                    if env.optimistic then
                        props._tmp_woundPending = { [SlotKey(toIndex)] = true }
                    end
                end)
                if env.refreshNow ~= nil then
                    env.refreshNow(row)
                end
            end,
        }
    end

    -- The context menu offered when the Usage Dice strip is clicked: roll the
    -- pool, plus refuel/restore where the item allows it.
    local function buildUsageDiceMenu()
        local entries = {}
        local token = env.getToken(row)
        if token == nil or token.properties == nil then return entries end
        local slot = GetSlot(token.properties, kind, index)
        if slot == nil then return entries end
        local maxUD = UsageDiceForItem(slot.itemid)
        if maxUD <= 0 then return entries end
        local cur = CurrentUsageDice(slot)

        if cur > 0 then
            entries[#entries + 1] = {
                text = string.format("Roll Usage Dice (%dd6)", cur),
                click = function() RollUsageDiceForSlot(row, env, kind, index) end,
            }
        end

        if cur < maxUD then
            -- The proper, rules-driven refill for a "refuel" item: spend one
            -- of its fuel consumable.
            if UsageDiceRestore(slot.itemid) == "refuel" then
                local fuelId = UsageDiceRefuelItem(slot.itemid)
                local gearTable = dmhub.GetTable("tbl_Gear") or {}
                local fuelItem = fuelId ~= nil and gearTable[fuelId] or nil
                local fuelName = fuelItem ~= nil and fuelItem.name or "fuel"
                if HasItem(token.properties, fuelId) then
                    entries[#entries + 1] = {
                        text = string.format("Refuel (use 1 %s)", fuelName),
                        click = function() RefuelUsageDice(row, env, kind, index) end,
                    }
                else
                    entries[#entries + 1] = {
                        text = string.format("Refuel (no %s)", fuelName),
                        disabled = true,
                        click = function() end,
                    }
                end
            end

            -- A manual restore is always available as an override, even for
            -- "useless" items the rules would otherwise leave spent for good --
            -- the Ref can refill them by hand.
            entries[#entries + 1] = {
                text = "Restore Usage Dice",
                click = function() RestoreUsageDice(row, env, kind, index) end,
            }
        end

        return entries
    end

    -- Floating Usage Dice strip at the row's right edge. Populated in DoRefresh;
    -- hidden for items without a UD pool.
    local usageDicePanel
    usageDicePanel = gui.Panel{
        classes = {"hidden"},
        floating = true,
        halign = "right",
        valign = "center",
        rmargin = 4,
        width = "auto",
        height = "auto",
        flow = "horizontal",
        bgimage = "panels/square.png",
        bgcolor = "clear",
        hoverCursor = "hand",

        press = function(element)
            local entries = buildUsageDiceMenu()
            if #entries == 0 then return end
            element.popup = gui.ContextMenu{
                entries = entries,
                click = function() element.popup = nil end,
            }
        end,

        linger = function(element)
            local token = env.getToken(row)
            if token == nil or token.properties == nil then return end
            local slot = GetSlot(token.properties, kind, index)
            if slot == nil then return end
            local maxUD = UsageDiceForItem(slot.itemid)
            if maxUD <= 0 then return end
            local cur = CurrentUsageDice(slot)

            local triggerText = ({
                activate = "Rolled each time the item is used.",
                dt = "Rolled at the end of each dungeon turn.",
                manual = "Rolled by hand.",
            })[UsageDiceTrigger(slot.itemid)] or "Rolled by hand."

            local restore = UsageDiceRestore(slot.itemid)
            local restoreText = ""
            if restore == "rest" then
                restoreText = " Refills on a rest."
            elseif restore == "refuel" then
                local fuelId = UsageDiceRefuelItem(slot.itemid)
                local gearTable = dmhub.GetTable("tbl_Gear") or {}
                local fuelItem = fuelId ~= nil and gearTable[fuelId] or nil
                restoreText = string.format(" Refilled with %s.", fuelItem ~= nil and fuelItem.name or "fuel")
            elseif restore == "useless" then
                restoreText = " Cannot be refilled once spent."
            end

            local stateText = cond(cur <= 0, "Spent.", string.format("%d of %d remaining.", cur, maxUD))
            gui.Tooltip(string.format("<b>Usage Dice</b>: %s\n%s%s\n\nClick to roll. Each die lost on a 1 or 2.",
                stateText, triggerText, restoreText))(element)
        end,
    }

    local function DoRefresh(element, props)
        local slot = GetSlot(props, kind, index)
        element.data.slot = slot
        element.data.continuation = nil
        element.draggable = (slot ~= nil)

        -- Default hidden; the filled-slot branch un-hides it for UD items.
        usageDicePanel:SetClass("hidden", true)

        -- Wounds fill backpack slots; show wounded slots in red with a
        -- draggable wound marker.
        local wounded = (kind == "backpack") and IsSlotWounded(props, index)
        element:SetClass("wounded", wounded)
        if woundIcon ~= nil then
            woundIcon:SetClass("hidden", not wounded)
            woundIcon.draggable = wounded
            -- Faded while a just-dropped wound here awaits network confirm.
            local pending = props:try_get("_tmp_woundPending")
            woundIcon:SetClass("pending", wounded and pending ~= nil and pending[SlotKey(index)] == true)
        end

        if slot ~= nil then
            iconPanel.bgimage = LiveItemIcon(slot) or "panels/square.png"
            iconPanel.bgcolor = "white"
            nameLabel.text = cond(slot.worn == true, string.format("%s (worn)", slot.name or "?"), slot.name or "?")
            nameLabel.italics = false
            nameLabel.color = "white"

            local armorAD = ArmorADForItem(slot.itemid)
            -- The number column shows current AD for armor/parry items,
            -- except for stackable items outside the hands (e.g. a stack of
            -- Parry knives in the backpack), where quantity matters more;
            -- AD only functions while wielded or worn anyway.
            local showAD = armorAD > 0
                and (kind == "hands" or MaxStackForItem(slot.itemid, kind) <= 1)
            if showAD then
                -- Editable. Red when depleted (the item can't stop damage).
                -- The "AD" prefix distinguishes this from a stack quantity:
                -- the same column shows quantity for stackables in the pack,
                -- so a Parry 2 knife reads "1" there and "AD 2" in hand.
                row.data.numberMode = "ad"
                quantityLabel.text = string.format("AD %d", slot.ad or armorAD)
                quantityLabel.color = cond((slot.ad or armorAD) <= 0, "#ff5050", "#aaaaaa")
                quantityLabel.editable = true
            elseif MaxStackForItem(slot.itemid, kind) > 1 then
                -- Only stackable items show (and can edit) a quantity.
                row.data.numberMode = "quantity"
                quantityLabel.text = tostring(slot.quantity or 1)
                quantityLabel.color = "#aaaaaa"
                quantityLabel.editable = true
            else
                row.data.numberMode = "quantity"
                quantityLabel.text = ""
                quantityLabel.editable = false
            end

            -- Usage Dice strip. UD items show their pool in place of a
            -- quantity (UD pools are per-instance, so the number column would
            -- be ambiguous), and grey the whole row out once the pool is spent.
            local maxUD = UsageDiceForItem(slot.itemid)
            if maxUD > 0 then
                local cur = CurrentUsageDice(slot)
                usageDicePanel:SetClass("hidden", false)
                if maxUD <= 6 then
                    local pips = {}
                    for i = 1, maxUD do
                        pips[#pips + 1] = UsageDicePip(i <= cur)
                    end
                    usageDicePanel.children = pips
                else
                    -- Too many to show as pips; render a compact count.
                    usageDicePanel.children = {
                        gui.Label{
                            width = "auto",
                            height = "auto",
                            fontSize = 11,
                            bold = true,
                            valign = "center",
                            interactable = false,
                            color = cond(cur <= 0, "#777777", "#f3ead0"),
                            text = string.format("%d/%d UD", cur, maxUD),
                        },
                    }
                end
                quantityLabel.text = ""
                quantityLabel.editable = false
                if cur <= 0 then
                    nameLabel.color = "#777777"
                    iconPanel.bgcolor = "#777777"
                end
            end
            return
        end

        -- Not an anchor: this slot may be covered by a multi-slot item
        -- anchored above it.
        local occAnchor, occEntry = OccupantOf(props, kind, index)
        if occAnchor ~= nil and occAnchor < index then
            element.data.continuation = occEntry
            iconPanel.bgimage = LiveItemIcon(occEntry) or "panels/square.png"
            iconPanel.bgcolor = "#888888"
            nameLabel.text = string.format("%s (cont.)", occEntry.name or "?")
            nameLabel.italics = true
            nameLabel.color = "#999999"
            quantityLabel.text = ""
            quantityLabel.editable = false
            return
        end

        iconPanel.bgcolor = "clear"
        nameLabel.text = cond(kind == "hands", "Unarmed", "(empty)")
        nameLabel.italics = true
        nameLabel.color = "#666666"
        quantityLabel.text = ""
        quantityLabel.editable = false
    end

    row = gui.Panel{
        classes = {"crowsInvSlot"},
        bgimage = true,
        width = SLOT_WIDTH,
        height = 26,
        flow = "horizontal",
        valign = "center",
        borderBox = true,
        hpad = 6,
        vmargin = 1,
        hoverCursor = "hand",
        draggable = false,
        styles = g_slotRowStyles,

        data = {
            slot = nil,
            kind = kind,
            index = index,
            panelToken = nil,
            numberMode = "quantity",
        },

        gui.Label{
            width = 20,
            height = "auto",
            fontSize = 11,
            bold = true,
            color = "#e8d59a",
            valign = "center",
            interactable = false,
            text = label,
        },

        iconPanel,
        nameLabel,
        quantityLabel,
        dropTarget,
        woundIcon,
        usageDicePanel,

        --sheet context: fired with the creature properties.
        refreshCharacterInfo = function(element, props)
            DoRefresh(element, props)
        end,

        --panel context: fired with the token.
        refreshCharacter = function(element, tok)
            if tok == nil or not tok.valid or tok.properties == nil then return end
            element.data.panelToken = tok
            DoRefresh(element, tok.properties)
        end,

        linger = function(element)
            local slot = element.data.slot or element.data.continuation
            if slot ~= nil then
                ItemTooltip(element, slot.itemid, slot.name)
            end
        end,

        canDragOnto = function(element, target)
            if target.data == nil or target.data.kind == nil or target.data.index == nil then
                return false
            end
            return target.data.kind ~= kind or target.data.index ~= index
        end,

        -- Drag a filled slot onto another slot: move into free space (a
        -- multi-slot item takes the dropped slot plus the next, or the
        -- previous when the next doesn't fit), merge stacks of the same
        -- item, or swap two single-slot items.
        drag = function(element, target)
            if target == nil then return end
            local destKind = target.data.kind
            local destIndex = target.data.index
            if destKind == nil or destIndex == nil then return end
            if destKind == kind and destIndex == index then return end

            env.change(row, function(props)
                local source = GetSlot(props, kind, index)
                if source == nil then return end
                local sourceSlots = source.slots or 1

                -- What occupies the dropped slot (ignoring the dragged item
                -- itself, so it can shift onto a span it already overlaps)?
                local destAnchor, dest = OccupantOf(props, destKind, destIndex)
                if destAnchor ~= nil and destKind == kind and destAnchor == index then
                    destAnchor, dest = nil, nil
                end

                if dest == nil then
                    local anchor = PlacementAnchor(props, destKind, destIndex, sourceSlots, kind, index)
                    if anchor == nil then return end
                    -- A destination that can't hold the whole stack (a hand
                    -- slot holds one item, ever) takes what fits; the
                    -- remainder stays behind in the source slot.
                    local maxStack = MaxStackForItem(source.itemid, destKind)
                    local moveQuantity = math.min(source.quantity or 1, maxStack)
                    if moveQuantity < (source.quantity or 1) then
                        local moved = shallow_copy_table(source)
                        moved.quantity = moveQuantity
                        source.quantity = (source.quantity or 1) - moveQuantity
                        SetSlot(props, kind, index, source)
                        SetSlot(props, destKind, anchor, moved)
                    else
                        SetSlot(props, kind, index, nil)
                        SetSlot(props, destKind, anchor, source)
                    end
                elseif dest.itemid == source.itemid and sourceSlots == 1 then
                    -- Merge stacks up to the item's stack limit; any
                    -- remainder stays behind in the source slot.
                    local maxStack = MaxStackForItem(dest.itemid, destKind)
                    local total = (dest.quantity or 1) + (source.quantity or 1)
                    dest.quantity = math.min(total, maxStack)
                    SetSlot(props, destKind, destAnchor, dest)
                    local remainder = total - dest.quantity
                    if remainder <= 0 then
                        SetSlot(props, kind, index, nil)
                    else
                        source.quantity = remainder
                        SetSlot(props, kind, index, source)
                    end
                elseif sourceSlots == 1 and (dest.slots or 1) == 1 then
                    -- No swap when either stack exceeds what the other side
                    -- can hold (e.g. a stack swapped into a hand slot): the
                    -- remainder would have nowhere to live.
                    if (source.quantity or 1) > MaxStackForItem(source.itemid, destKind)
                            or (dest.quantity or 1) > MaxStackForItem(dest.itemid, kind) then
                        return
                    end
                    SetSlot(props, destKind, destAnchor, source)
                    SetSlot(props, kind, index, dest)
                end
                -- Swaps involving multi-slot items are not supported: there
                -- is no unambiguous way to fit both spans.
            end)
        end,

        rightClick = function(element)
            local slot = element.data.slot

            local entries = {}

            -- Add/Remove a wound manually. Backpack slots only (empty or
            -- holding an item); wounds never go on hands/belt.
            if kind == "backpack" then
                local woundToken = env.getToken(row)
                local woundProps = woundToken ~= nil and woundToken.properties or nil
                if woundProps ~= nil then
                    if IsSlotWounded(woundProps, index) then
                        entries[#entries + 1] = {
                            text = "Remove Wound",
                            click = function()
                                env.change(row, function(p) SetSlotWounded(p, index, false) end)
                                if env.refreshNow ~= nil then env.refreshNow(row) end
                            end,
                        }
                    else
                        entries[#entries + 1] = {
                            text = "Add Wound",
                            click = function()
                                env.change(row, function(p) SetSlotWounded(p, index, true) end)
                                if env.refreshNow ~= nil then env.refreshNow(row) end
                            end,
                        }
                    end
                end
            end

            -- An empty slot has no item actions: show just the wound entry.
            if slot == nil then
                if #entries > 0 then
                    element.popup = gui.ContextMenu{
                        entries = entries,
                        click = function() element.popup = nil end,
                    }
                end
                return
            end

            local rowToken = env.getToken(row)
            if rowToken ~= nil and rowToken.partyid ~= nil and rowToken.partyid ~= "" then
                entries[#entries + 1] = {
                    text = "Send to Party",
                    click = function()
                        env.change(row, function(props, token)
                            local s = GetSlot(props, kind, index)
                            if s == nil then return end
                            if not GivePartyItem(token, s.itemid, s.quantity or 1) then return end
                            SetSlot(props, kind, index, nil)
                        end)
                    end,
                }
            end

            for _, target in ipairs({"hands", "belt", "backpack"}) do
                if target ~= kind then
                    local targetName = string.format("Move to %s", string.upper(string.sub(target, 1, 1)) .. string.sub(target, 2))
                    entries[#entries + 1] = {
                        text = targetName,
                        click = function()
                            env.change(row, function(props)
                                local s = GetSlot(props, kind, index)
                                if s == nil then return end
                                local free = FirstEmptySlot(props, target, s.slots or 1)
                                if free == nil then return end
                                -- Same stack rule as drag: a destination that
                                -- can't hold the whole stack (hands hold one)
                                -- takes what fits; the rest stays put.
                                local maxStack = MaxStackForItem(s.itemid, target)
                                local moveQuantity = math.min(s.quantity or 1, maxStack)
                                if moveQuantity < (s.quantity or 1) then
                                    local moved = shallow_copy_table(s)
                                    moved.quantity = moveQuantity
                                    s.quantity = (s.quantity or 1) - moveQuantity
                                    SetSlot(props, kind, index, s)
                                    SetSlot(props, target, free, moved)
                                else
                                    SetSlot(props, target, free, s)
                                    SetSlot(props, kind, index, nil)
                                end
                            end)
                        end,
                    }
                end
            end

            if (slot.quantity or 1) > 1 then
                entries[#entries + 1] = {
                    text = "Split Stack",
                    click = function()
                        env.change(row, function(props)
                            local s = GetSlot(props, kind, index)
                            if s == nil or (s.quantity or 1) < 2 then return end

                            -- Half the stack moves to the first empty slot in
                            -- this section, falling back to the backpack.
                            local targetKind = kind
                            local targetIndex = FirstEmptySlot(props, kind)
                            if targetIndex == nil and kind ~= "backpack" then
                                targetKind = "backpack"
                                targetIndex = FirstEmptySlot(props, "backpack")
                            end
                            if targetIndex == nil then return end

                            local half = math.floor((s.quantity or 1) / 2)
                            s.quantity = (s.quantity or 1) - half
                            SetSlot(props, kind, index, s)
                            SetSlot(props, targetKind, targetIndex, {
                                itemid = s.itemid,
                                name = s.name,
                                icon = s.icon,
                                category = s.category,
                                quantity = half,
                            })
                        end)
                    end,
                }
            end

            -- Armor: a suit in the backpack can be designated as worn (one
            -- at a time; per the rules it stays in its backpack slots).
            -- Shields grant AD from hand slots without any designation.
            local armorAD = ArmorADForItem(slot.itemid)
            if armorAD > 0 and kind == "backpack"
                and not IsShieldItem(slot.itemid) and not IsWeaponItem(slot.itemid) then
                if slot.worn == true then
                    entries[#entries + 1] = {
                        text = "Stop Wearing",
                        click = function()
                            env.change(row, function(props)
                                local s = GetSlot(props, kind, index)
                                if s == nil then return end
                                s.worn = nil
                                SetSlot(props, kind, index, s)
                            end)
                        end,
                    }
                else
                    entries[#entries + 1] = {
                        text = "Wear Armor",
                        click = function()
                            env.change(row, function(props)
                                -- only one worn suit at a time
                                for i = 1, ROW_CAPACITY.backpack do
                                    local other = GetSlot(props, "backpack", i)
                                    if other ~= nil and other.worn == true then
                                        other.worn = nil
                                        SetSlot(props, "backpack", i, other)
                                    end
                                end
                                local s = GetSlot(props, kind, index)
                                if s == nil then return end
                                s.worn = true
                                SetSlot(props, kind, index, s)
                            end)
                        end,
                    }
                end
            end

            if armorAD > 0 and (slot.ad or armorAD) < armorAD then
                entries[#entries + 1] = {
                    text = "Repair Armor",
                    click = function()
                        env.change(row, function(props)
                            local s = GetSlot(props, kind, index)
                            if s == nil then return end
                            s.ad = ArmorADForItem(s.itemid)
                            SetSlot(props, kind, index, s)
                        end)
                    end,
                }
            end

            -- Dropping places a lootable object on the map at the
            -- character's feet; it only works while the token is on a map.
            entries[#entries + 1] = {
                text = "Drop One",
                click = function()
                    env.change(row, function(props, token)
                        local s = GetSlot(props, kind, index)
                        if s == nil then return end
                        if not DropItemOnMap(token, s, 1) then return end
                        local q = (s.quantity or 1) - 1
                        if q <= 0 then
                            SetSlot(props, kind, index, nil)
                        else
                            s.quantity = q
                            SetSlot(props, kind, index, s)
                        end
                    end)
                end,
            }

            entries[#entries + 1] = {
                text = "Drop All",
                click = function()
                    env.change(row, function(props, token)
                        local s = GetSlot(props, kind, index)
                        if s == nil then return end
                        if not DropItemOnMap(token, s, s.quantity or 1) then return end
                        SetSlot(props, kind, index, nil)
                    end)
                end,
            }

            -- Destroy deletes the item outright -- nothing lands on the map.
            entries[#entries + 1] = {
                text = "Destroy Item",
                click = function()
                    env.change(row, function(props)
                        SetSlot(props, kind, index, nil)
                    end)
                end,
            }

            element.popup = gui.ContextMenu{
                entries = entries,
                click = function()
                    --any entry click closes the menu.
                    element.popup = nil
                end,
            }
        end,
    }
    return row
end

local function SlotColumn(title, kind, labels, env)
    local children = {
        SectionHeading(title),
    }
    for i = 1, ROW_CAPACITY[kind] do
        children[#children + 1] = SlotRow(kind, i, labels and labels[i] or tostring(i), env)
    end
    return gui.Panel{
        width = SLOT_WIDTH,
        height = "auto",
        flow = "vertical",
        children = children,
    }
end

-- ---------------------------------------------------------------------------
-- Party inventory section.
-- ---------------------------------------------------------------------------

local function CreatePartySection()
    local listPanel = gui.Panel{
        width = LIST_WIDTH,
        height = "auto",
        flow = "vertical",
        halign = "left",
    }

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        SectionHeading("Party Inventory"),
        listPanel,

        refreshCharacterInfo = function(element, props)
            local children = {}
            local partyInfo = GetParty()

            if partyInfo == nil then
                children[#children + 1] = gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 12,
                    italics = true,
                    color = "#888888",
                    text = "This character is not in a party.",
                }
                listPanel.children = children
                return
            end

            local gearTable = dmhub.GetTable("tbl_Gear") or {}
            local entries = {}
            for itemid, info in pairs(partyInfo.properties:try_get("inventory", {})) do
                local item = gearTable[itemid]
                if item ~= nil and (info.quantity or 0) > 0 then
                    entries[#entries + 1] = { item = item, quantity = info.quantity }
                end
            end
            table.sort(entries, function(a, b) return a.item.name < b.item.name end)

            for _, entry in ipairs(entries) do
                local item = entry.item
                local quantity = entry.quantity
                children[#children + 1] = gui.Panel{
                    classes = {"crowsInvSlot"},
                    bgimage = true,
                    width = "100%",
                    height = 26,
                    flow = "horizontal",
                    valign = "center",
                    borderBox = true,
                    hpad = 6,
                    vmargin = 1,

                    gui.Panel{
                        width = 18,
                        height = 18,
                        valign = "center",
                        rmargin = 6,
                        bgimage = item:GetIcon(),
                        bgcolor = "white",
                        interactable = false,
                    },
                    -- Fixed width so the quantity and Take columns
                    -- right-align: list width minus padding (12), icon
                    -- (18+6), quantity (36), Take button (50+8).
                    gui.Label{
                        width = LIST_WIDTH - 12 - 24 - 36 - 58,
                        height = "auto",
                        fontSize = 12,
                        color = "white",
                        valign = "center",
                        interactable = false,
                        text = item.name,
                    },
                    gui.Label{
                        width = 36,
                        height = "auto",
                        fontSize = 11,
                        color = "#aaaaaa",
                        valign = "center",
                        textAlignment = "right",
                        interactable = false,
                        text = string.format("x%d", quantity),
                    },
                    gui.Button{
                        text = "Take",
                        fontSize = 11,
                        width = 50,
                        height = 20,
                        valign = "center",
                        lmargin = 8,
                        click = function()
                            ChangeHero(function(props, token)
                                -- Bundled items (ammo) take a whole bundle per
                                -- click, capped by what the stash holds; one
                                -- unit at a time so stack limits and slot
                                -- spill apply.
                                local pull = math.min(PullQuantityForItem(item), quantity)
                                local moved = 0
                                for _ = 1, pull do
                                    if AddItemToCharacter(props, item, 1) then
                                        moved = moved + 1
                                    else
                                        break
                                    end
                                end
                                if moved > 0 then
                                    GivePartyItem(token, item.id, -moved)
                                end
                            end)
                        end,
                    },

                    linger = function(rowElement)
                        ItemTooltip(rowElement, item.id, item.name)
                    end,
                }
            end

            if #entries == 0 then
                children[#children + 1] = gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 12,
                    italics = true,
                    color = "#888888",
                    text = "The party stash is empty.",
                }
            end

            listPanel.children = children
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Item index section: search the global item table, add items to your
-- backpack, and author new items with the engine's create-item dialog.
-- ---------------------------------------------------------------------------

local MAX_INDEX_RESULTS = 30

local function CreateIndexSection()
    local sectionPanel
    local searchTerms = nil

    local listPanel = gui.Panel{
        width = LIST_WIDTH,
        height = "auto",
        maxHeight = 400,
        flow = "vertical",
        vscroll = true,
        halign = "left",
    }

    local function MatchesSearch(item)
        if searchTerms == nil then return true end
        local name = string.lower(item.name or "")
        for _, term in ipairs(searchTerms) do
            if not string.find(name, term, 1, true) then
                return false
            end
        end
        return true
    end

    local function RebuildList()
        local gearTable = dmhub.GetTable("tbl_Gear") or {}
        local items = {}
        for k, item in pairs(gearTable) do
            if (not item:try_get("hidden", false)) and MatchesSearch(item) then
                items[#items + 1] = item
            end
        end
        table.sort(items, function(a, b) return a.name < b.name end)

        local children = {}
        for i, item in ipairs(items) do
            if i > MAX_INDEX_RESULTS then break end
            local thisItem = item
            children[#children + 1] = gui.Panel{
                classes = {"crowsInvSlot"},
                bgimage = true,
                width = LIST_WIDTH,
                height = 26,
                flow = "horizontal",
                valign = "center",
                borderBox = true,
                hpad = 6,
                vmargin = 1,
                draggable = true,

                canDragOnto = function(element, target)
                    return target.data ~= nil and target.data.kind ~= nil and target.data.index ~= nil
                end,

                -- Drag an index entry onto a slot: place one pull into free
                -- space (multi-slot items take the dropped slot plus the
                -- next, or the previous when the next doesn't fit), or stack
                -- onto a slot already holding the same item. Bundled items
                -- (ammo) drop their whole bundle as a stack.
                drag = function(element, target)
                    if target == nil then return end
                    local destKind = target.data.kind
                    local destIndex = target.data.index
                    if destKind == nil or destIndex == nil then return end

                    ChangeHero(function(props)
                        local pull = PullQuantityForItem(thisItem)
                        local destAnchor, dest = OccupantOf(props, destKind, destIndex)
                        if dest == nil then
                            local anchor = PlacementAnchor(props, destKind, destIndex, SlotsRequiredForItem(thisItem.id))
                            if anchor == nil then return end
                            local put = math.min(pull, math.max(1, MaxStackForItem(thisItem.id, destKind)))
                            SetSlot(props, destKind, anchor, MakeSlotEntry(thisItem, put))
                            MaybeAutoWearArmor(props, destKind, anchor)
                        elseif dest.itemid == thisItem.id then
                            local maxStack = MaxStackForItem(thisItem.id, destKind)
                            local add = math.min(pull, maxStack - (dest.quantity or 1))
                            if add > 0 then
                                dest.quantity = (dest.quantity or 1) + add
                                SetSlot(props, destKind, destAnchor, dest)
                            end
                        end
                    end)
                end,

                gui.Panel{
                    width = 18,
                    height = 18,
                    valign = "center",
                    rmargin = 6,
                    bgimage = thisItem:GetIcon(),
                    bgcolor = "white",
                    interactable = false,
                },
                -- Fixed width so the cost / Add / Edit columns right-align
                -- on every row: list width minus padding (12), icon (18+6),
                -- cost (60), Add (46+8), Edit (46+4+10 right margin so it
                -- doesn't crowd the row edge).
                gui.Label{
                    width = LIST_WIDTH - 12 - 24 - 60 - 54 - 60,
                    height = "auto",
                    fontSize = 12,
                    color = "white",
                    valign = "center",
                    interactable = false,
                    text = thisItem.name,
                },
                gui.Label{
                    width = 60,
                    height = "auto",
                    fontSize = 11,
                    color = "#aaaaaa",
                    valign = "center",
                    textAlignment = "right",
                    interactable = false,
                    text = cond(tonumber(thisItem:try_get("costInGold", 0)) ~= nil and tonumber(thisItem:try_get("costInGold", 0)) > 0,
                        string.format("%dgp", tonumber(thisItem:try_get("costInGold", 0)) or 0), ""),
                },
                gui.Button{
                    text = "Add",
                    fontSize = 11,
                    width = 46,
                    height = 20,
                    valign = "center",
                    lmargin = 8,
                    click = function()
                        ChangeHero(function(props)
                            -- One click grants one pull: a full bundle for
                            -- bundled items (ammo), added unit by unit so
                            -- stacks top up and spill into fresh slots.
                            for _ = 1, PullQuantityForItem(thisItem) do
                                if not AddItemToCharacter(props, thisItem, 1) then
                                    break
                                end
                            end
                        end)
                    end,
                },
                gui.Button{
                    text = "Edit",
                    fontSize = 11,
                    width = 46,
                    height = 20,
                    valign = "center",
                    lmargin = 4,
                    rmargin = 10,
                    click = function()
                        -- Opens the engine's item dialog in edit mode for
                        -- this tbl_Gear entry; changes upload on close.
                        if gamehud ~= nil and gamehud.createItemDialog ~= nil then
                            gamehud.createItemDialog.data.show(sectionPanel, thisItem)
                        end
                    end,
                },

                linger = function(rowElement)
                    ItemTooltip(rowElement, thisItem.id, thisItem.name)
                end,
            }
        end

        if #items > MAX_INDEX_RESULTS then
            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 11,
                italics = true,
                color = "#888888",
                tmargin = 2,
                text = string.format("...and %d more. Refine your search to see them.", #items - MAX_INDEX_RESULTS),
            }
        elseif #items == 0 then
            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 12,
                italics = true,
                color = "#888888",
                text = "No items match.",
            }
        end

        listPanel.children = children
    end

    sectionPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        SectionHeading("Item Index"),

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "center",
            bmargin = 4,

            gui.Input{
                width = 300,
                height = 24,
                fontSize = 12,
                placeholderText = "Search items...",
                editlag = 0.2,
                edit = function(element)
                    if string.len(element.text) <= 0 then
                        searchTerms = nil
                    else
                        searchTerms = string.split(string.lower(element.text))
                    end
                    RebuildList()
                end,
            },

            gui.Button{
                text = "+ New Item",
                fontSize = 12,
                height = 24,
                valign = "center",
                lmargin = 12,
                click = function()
                    -- The engine's create-item dialog (shared with the Draw
                    -- Steel inventory, attached to the hud at GameHud.lua:746);
                    -- fires refreshInventory at us when the new item has been
                    -- uploaded to tbl_Gear.
                    if gamehud ~= nil and gamehud.createItemDialog ~= nil then
                        gamehud.createItemDialog.data.show(sectionPanel)
                    end
                end,
            },
        },

        listPanel,

        create = function(element)
            RebuildList()
        end,

        refreshInventory = function(element)
            RebuildList()
        end,

        refreshCharacterInfo = function(element, props)
            -- list contents don't depend on the character, but cheap to keep fresh.
        end,
    }

    return sectionPanel
end

-- ---------------------------------------------------------------------------
-- Tab assembly.
-- ---------------------------------------------------------------------------

-- Row environment for the character sheet: the sheet owns the upload
-- lifecycle, so mutations apply directly to the sheet's token.
local g_sheetEnv = {
    change = function(row, fn)
        ChangeHero(fn)
    end,
    getToken = function(row)
        return GetHeroToken()
    end,
}

local function CreateCrowdexInventoryTab()
    local content = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        valign = "top",
        hpad = 16,
        vpad = 12,
        borderBox = true,

        gui.Label{
            width = "100%",
            height = "auto",
            fontSize = 22,
            bold = true,
            color = "#e8d59a",
            text = "Inventory",
        },

        -- Slots: backpack on the left; hands, belt, and (future) worn magic
        -- slots on the right.
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "top",

            gui.Panel{
                width = SLOT_WIDTH,
                height = "auto",
                flow = "vertical",
                valign = "top",
                rmargin = 32,

                SlotColumn("Backpack", "backpack", nil, g_sheetEnv),
            },

            gui.Panel{
                width = SLOT_WIDTH,
                height = "auto",
                flow = "vertical",
                valign = "top",

                SlotColumn("Hands", "hands", HAND_LABELS, g_sheetEnv),
                SlotColumn("Belt", "belt", nil, g_sheetEnv),

                SectionHeading("Worn (Magic)"),
                gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 12,
                    italics = true,
                    color = "#888888",
                    text = "Magic item slots coming soon.",
                },
            },
        },

        CreatePartySection(),
        CreateIndexSection(),
    }

    return gui.Panel{
        classes = {"characterSheetPanel"},
        width = "100%",
        height = "100%",
        flow = "vertical",
        valign = "top",
        vscroll = true,

        data = {
            reconciling = false,
        },

        -- Looted items arrive in the engine inventory; pull them into Crows
        -- slots. Deferred out of the refresh pass since migration mutates
        -- the character (which triggers another refresh).
        refreshCharacterInfo = function(element, props)
            if element.data.reconciling then return end
            local engineInv = props:try_get("inventory")
            if engineInv == nil then return end
            local hasItems = false
            for _, entry in pairs(engineInv) do
                if (entry.quantity or 0) > 0 then
                    hasItems = true
                    break
                end
            end
            if not hasItems then return end

            element.data.reconciling = true
            dmhub.Schedule(0.1, function()
                if mod.unloaded or not element.valid then return end
                ChangeHero(function(heroProps)
                    ReconcileEngineInventory(heroProps)
                end)
                element.data.reconciling = false
            end)
        end,

        styles = {
            {
                selectors = {"crowsInvSlot"},
                bgcolor = "#1c1c28",
                borderWidth = 1,
                borderColor = "#3a3a4a",
            },
            {
                selectors = {"crowsInvSlot", "hover"},
                bgcolor = "#3a3a5c",
                borderColor = "#e8d59a",
            },
            {
                selectors = {"crowsInvSlot", "dragging"},
                bgcolor = "#4a4422",
                borderColor = "#ffdd66",
                borderWidth = 2,
            },
        },

        content,
    }
end

-- ---------------------------------------------------------------------------
-- Extend the shared item editor (DSInventoryEditor's
-- DataTables.tbl_Gear.GenerateEditor, used by the create/edit item dialog and
-- the compendium) with the Crows "Stack N" value. Stored as stackLimit on
-- the tbl_Gear entry; 1 (or absent) means the item doesn't stack.
-- ---------------------------------------------------------------------------

-- Equipment category helpers. An item counts as a weapon type when its
-- equipment category (or any category up the superset chain) carries the
-- Melee Weapon or Ranged Weapon flag; ranged weapon categories take
-- ammunition; ammunition lives in a category with the Ammunition flag.
local function CategoryChainHas(catid, field)
    local catTable = dmhub.GetTable("equipmentCategories") or {}
    local count = 0
    while catid ~= nil and count < 10 do
        local cat = catTable[catid]
        if cat == nil then return false end
        if cat[field] then return true end
        catid = cat:try_get("superset")
        count = count + 1
    end
    return false
end

local function IsWeaponCategory(catid)
    return CategoryChainHas(catid, "isMelee") or CategoryChainHas(catid, "isRanged")
end

local function IsRangedWeaponCategory(catid)
    return CategoryChainHas(catid, "isRanged")
end

local function IsAmmoCategory(catid)
    return CategoryChainHas(catid, "isAmmo")
end

-- Crows ammunition uses the isAmmo category flag rather than the base game's
-- isQuantity, so the item editor's projectile-preview panel (scale/rotation of
-- the object spawned when the ammo is fired) stays collapsed by default. Extend
-- the generic predicate so Crows ammo exposes the same preview/config controls.
-- The fire path (Projectile.Fire) already reads projectileScale/projectileRotation
-- off the ammo item, so configuring them here is honored at attack time.
local g_baseShowProjectilePreview = EquipmentCategory.ShowProjectilePreview
function EquipmentCategory.ShowProjectilePreview(item)
    if g_baseShowProjectilePreview(item) then
        return true
    end
    return IsAmmoCategory(item:try_get("equipmentCategory", ""))
end

-- In Crows any object can be wielded in hand, so every item exposes the
-- wield-object editor ("Display on Token" + "Edit Object"), not just light
-- sources. GetWieldObject() is generic, so this works for any item.
function EquipmentCategory.ShowWieldObjectEditor(item)
    return true
end

local g_baseGenerateGearEditor = DataTables.tbl_Gear.GenerateEditor
function DataTables.tbl_Gear.GenerateEditor(document, options)
    local panel = g_baseGenerateGearEditor(document, options)

    -- Append the Crows fields to the editor's left form column rather than
    -- the root: for tall variants of the form (ammunition categories add
    -- Destroy Chance / Modify Attacks sections) rows appended after the
    -- two-column body land below the dialog's reachable scroll range. The
    -- left column is located via the category dropdowns' id.
    local typePanel = panel:Get("equipmentTypePanel")
    local formColumn = (typePanel ~= nil and typePanel.parent ~= nil) and typePanel.parent or panel

    -- Register the heading class on the root panel so it cascades to all children.
    local existingStyles = panel.styles or {}
    existingStyles[#existingStyles + 1] = {
        classes = {"crowsEditorHeading"},
        bold = true,
        halign = "left",
        tmargin = 12,
        bmargin = 4,
        fontSize = 18,
        color = "#cccccc",
        width = "100%",
        height = "auto",
    }
    existingStyles[#existingStyles + 1] = {
        classes = {"crowsFormHint"},
        width = "auto",
        height = "auto",
        fontSize = 12,
        italics = true,
        color = "#888888",
        valign = "center",
        lmargin = 8,
    }
    panel.styles = existingStyles

    local function GetSkillsByCategory(category)
        local skillsTable = dmhub.GetTable(Skill.tableName) or {}
        local opts = { { id = "", text = "(None)" } }
        for _, sk in unhidden_pairs(skillsTable) do
            if (sk.category or ""):lower() == category then
                opts[#opts + 1] = { id = sk.name, text = sk.name }
            end
        end
        table.sort(opts, function(a, b) return a.text < b.text end)
        return opts
    end

    -- Remove any existing Crows fields panel from a previous hot-reload so
    -- we don't duplicate the section.
    local existing = formColumn:Get("crowsEditorFields")
    if existing ~= nil then
        existing:DestroySelf()
    end

    local hasUD = function()
        return (tonumber(document:try_get("usageDice", 0)) or 0) > 0
    end

    local crowsFields = gui.Panel{
        id = "crowsEditorFields",
        width = "100%",
        height = "auto",
        flow = "vertical",
    }

    crowsFields:AddChild(gui.Label{
        classes = {"crowsEditorHeading"},
        text = "Inventory",
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel"},
        halign = "left",

        gui.Label{
            classes = {"formLabel"},
            text = "Stack Limit:",
        },
        gui.Input{
            width = 60,
            height = 24,
            characterLimit = 3,
            text = tostring(document:try_get("stackLimit", 1)),
            change = function(element)
                local n = math.floor(tonumber(element.text) or 1)
                if n < 1 then n = 1 end
                document.stackLimit = n
                element.text = tostring(n)
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "How many fit in one inventory slot (1 = does not stack).",
        },
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel"},
        halign = "left",

        gui.Label{
            classes = {"formLabel"},
            text = "Occupies Slots:",
        },
        gui.Input{
            width = 60,
            height = 24,
            characterLimit = 1,
            text = tostring(document:try_get("slotsRequired", 1)),
            change = function(element)
                local n = math.floor(tonumber(element.text) or 1)
                if n < 1 then n = 1 end
                if n > MAX_ITEM_SLOTS then n = MAX_ITEM_SLOTS end
                document.slotsRequired = n
                element.text = tostring(n)
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "Adjacent inventory slots this item takes up.",
        },
    })

    crowsFields:AddChild(gui.Label{
        classes = {"crowsEditorHeading"},
        text = "Usage Dice",
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel"},
        halign = "left",

        gui.Label{
            classes = {"formLabel"},
            text = "Usage Dice:",
        },
        gui.Input{
            width = 60,
            height = 24,
            characterLimit = 2,
            text = tostring(document:try_get("usageDice", 0)),
            change = function(element)
                local n = math.floor(tonumber(element.text) or 0)
                if n < 0 then n = 0 end
                if n > 0 then
                    document.usageDice = n
                else
                    document.usageDice = nil
                end
                element.text = tostring(n)
                crowsFields:FireEventTree("refresh")
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "Pool of d6s (0 = no usage dice).",
        },
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel", cond(hasUD(), nil, "collapsed-anim")},
        halign = "left",

        refresh = function(element)
            element:SetClass("collapsed-anim", not hasUD())
        end,

        gui.Label{
            classes = {"formLabel"},
            text = "UD Trigger:",
        },
        gui.Dropdown{
            width = 140,
            height = 24,
            idChosen = document:try_get("usageDiceTrigger", "manual"),
            options = {
                { id = "manual",   text = "Manual" },
                { id = "activate", text = "Activate" },
                { id = "dt",       text = "Dungeon Turn" },
            },
            change = function(element)
                if element.idChosen == "manual" then
                    document.usageDiceTrigger = nil
                else
                    document.usageDiceTrigger = element.idChosen
                end
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "When the pool is rolled.",
        },
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel", cond(hasUD(), nil, "collapsed-anim")},
        halign = "left",

        refresh = function(element)
            element:SetClass("collapsed-anim", not hasUD())
        end,

        gui.Label{
            classes = {"formLabel"},
            text = "UD Restore:",
        },
        gui.Dropdown{
            width = 140,
            height = 24,
            idChosen = document:try_get("usageDiceRestore", "rest"),
            options = {
                { id = "rest",    text = "Rest" },
                { id = "refuel",  text = "Refuel" },
                { id = "useless", text = "Useless" },
            },
            change = function(element)
                if element.idChosen == "rest" then
                    document.usageDiceRestore = nil
                else
                    document.usageDiceRestore = element.idChosen
                end
                crowsFields:FireEventTree("refresh")
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "How the pool is refilled.",
        },
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel", cond(hasUD() and document:try_get("usageDiceRestore") == "refuel", nil, "collapsed-anim")},
        halign = "left",

        refresh = function(element)
            element:SetClass("collapsed-anim", not (hasUD() and document:try_get("usageDiceRestore") == "refuel"))
        end,

        gui.Label{
            classes = {"formLabel"},
            text = "Refuel Item:",
        },
        gui.Dropdown{
            width = 200,
            height = 24,
            hasSearch = true,
            idChosen = document:try_get("usageDiceRefuel", ""),
            options = {},

            create = function(element)
                local gearTable = dmhub.GetTable("tbl_Gear") or {}
                local opts = {
                    { id = "", text = "(None)" },
                }
                for k, item in pairs(gearTable) do
                    if not item:try_get("hidden", false) and k ~= document.id then
                        opts[#opts + 1] = { id = k, text = item.name }
                    end
                end
                table.sort(opts, function(a, b) return a.text < b.text end)
                element.options = opts
                element.idChosen = document:try_get("usageDiceRefuel", "")
            end,

            change = function(element)
                if element.idChosen == "" then
                    document.usageDiceRefuel = nil
                else
                    document.usageDiceRefuel = element.idChosen
                end
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "Item consumed to refill the pool.",
        },
    })

    crowsFields:AddChild(gui.Label{
        classes = {"crowsEditorHeading"},
        text = "Combat",
    })

    crowsFields:AddChild(gui.Panel{
        classes = {"formPanel"},
        halign = "left",

        gui.Label{
            classes = {"formLabel"},
            text = "Armor AD:",
        },
        gui.Input{
            width = 60,
            height = 24,
            characterLimit = 3,
            text = tostring(document:try_get("crowsAD", 0)),
            change = function(element)
                local n = math.floor(tonumber(element.text) or 0)
                if n < 0 then n = 0 end
                if n > 0 then
                    document.crowsAD = n
                else
                    document.crowsAD = nil
                end
                element.text = tostring(n)
            end,
        },
        gui.Check{
            text = "Shield",
            valign = "center",
            lmargin = 12,
            value = document:try_get("crowsShield", false),
            change = function(element)
                if element.value then
                    document.crowsShield = true
                else
                    document.crowsShield = nil
                end
            end,
        },
        gui.Label{
            classes = {"crowsFormHint"},
            text = "Armor Defense pool (0 = not armor). Shields absorb from a hand slot; suits must be worn. On a weapon this is its Parry X value.",
        },
    })

    -- Weapon stat block. Shown only when the item's equipment category is a
    -- weapon type (the category, or one up its superset chain, has the Melee
    -- Weapon or Ranged Weapon flag). The base editor fires a "refresh" event
    -- tree when the category dropdown changes, so visibility stays live.
    local function WeaponTextField(labelText, fieldName, inputWidth, hint)
        return gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = labelText,
            },
            gui.Input{
                width = inputWidth,
                height = 24,
                text = tostring(document:try_get(fieldName, "")),
                change = function(element)
                    local v = string.trim(element.text)
                    if v == "" then
                        document[fieldName] = nil
                    else
                        document[fieldName] = v
                    end
                    element.text = v
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = hint,
            },
        }
    end

    local function WeaponNumberField(labelText, fieldName, hint)
        return gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = labelText,
            },
            gui.Input{
                width = 60,
                height = 24,
                characterLimit = 3,
                text = tostring(document:try_get(fieldName, "")),
                change = function(element)
                    local n = tonumber(element.text)
                    if n == nil or n <= 0 then
                        document[fieldName] = nil
                        element.text = ""
                    else
                        n = math.floor(n)
                        document[fieldName] = n
                        element.text = tostring(n)
                    end
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = hint,
            },
        }
    end

    -- The Ammunition Type keyword pairs ranged weapons with their ammunition:
    -- a ranged weapon with the keyword set only attacks while the crow carries
    -- ammunition (an item in an Ammunition category) whose own keyword
    -- matches. Both editors write the same crowsAmmoType field.
    local function AmmoTypeField(hint, visibleFn)
        return gui.Panel{
            classes = {"formPanel", cond(visibleFn(), nil, "collapsed-anim")},
            halign = "left",

            refresh = function(element)
                element:SetClass("collapsed-anim", not visibleFn())
            end,

            gui.Label{
                classes = {"formLabel"},
                text = "Ammo Type:",
            },
            gui.Input{
                width = 100,
                height = 24,
                text = tostring(document:try_get("crowsAmmoType", "")),
                change = function(element)
                    local v = string.trim(element.text)
                    if v == "" then
                        document.crowsAmmoType = nil
                    else
                        document.crowsAmmoType = v
                    end
                    element.text = v
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = hint,
            },
        }
    end

    crowsFields:AddChild(gui.Label{
        classes = {"crowsEditorHeading", cond(IsWeaponCategory(document:try_get("equipmentCategory")), nil, "collapsed-anim")},
        text = "Weapon",
        refresh = function(element)
            element:SetClass("collapsed-anim", not IsWeaponCategory(document:try_get("equipmentCategory")))
        end,
    })

    local weaponSection = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        classes = {cond(IsWeaponCategory(document:try_get("equipmentCategory")), nil, "collapsed-anim")},

        refresh = function(element)
            element:SetClass("collapsed-anim", not IsWeaponCategory(document:try_get("equipmentCategory")))
        end,

        gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = "Weapon Type:",
            },
            gui.Dropdown{
                width = 140,
                height = 24,
                idChosen = document:try_get("crowsWeaponType", ""),
                options = {},
                create = function(element)
                    element.options = GetSkillsByCategory("weapon")
                    element.idChosen = document:try_get("crowsWeaponType", "")
                end,
                change = function(element)
                    if element.idChosen == "" then
                        document.crowsWeaponType = nil
                    else
                        document.crowsWeaponType = element.idChosen
                    end
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = "Weapon skill for attack tests.",
            },
        },
        WeaponNumberField("Melee Range:", "crowsMeleeRange",
            "Reach in squares. Blank = no melee attack."),
        WeaponNumberField("Ranged Range:", "crowsRangedRange",
            "Range in squares. Both set = thrown weapon."),
        WeaponTextField("Attack Stat:", "crowsAttackStat", 100,
            "Characteristic(s) for the test: S, A, or \"A or S\"."),
        WeaponTextField("Tier 2 Dam:", "crowsTier2", 100,
            "Damage on 12-16, e.g. \"3 + S\"."),
        WeaponTextField("Tier 3 Dam:", "crowsTier3", 100,
            "Damage on 17+, e.g. \"6 + S\"."),
        WeaponTextField("Qualities:", "crowsQualities", 200,
            "e.g. \"Light, Disengage, Parry 2\". Parry also needs Armor AD set."),
        AmmoTypeField("Ammunition this weapon fires, e.g. \"Arrows\". Blank = needs no ammunition.",
            function() return IsRangedWeaponCategory(document:try_get("equipmentCategory")) end),
    }
    crowsFields:AddChild(weaponSection)

    crowsFields:AddChild(AmmoTypeField("Must match the Ammo Type of the weapons this ammunition fits, e.g. \"Arrows\".",
        function() return IsAmmoCategory(document:try_get("equipmentCategory")) end))

    crowsFields:AddChild(gui.Label{
        classes = {"crowsEditorHeading", cond(IsSpellbookItem(document), nil, "collapsed-anim")},
        text = "Spellbook",
        refresh = function(element)
            element:SetClass("collapsed-anim", not IsSpellbookItem(document))
        end,
    })

    local spellbookSection = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        classes = {cond(IsSpellbookItem(document), nil, "collapsed-anim")},

        refresh = function(element)
            element:SetClass("collapsed-anim", not IsSpellbookItem(document))
        end,

        gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = "Discipline:",
            },
            gui.Dropdown{
                width = 140,
                height = 24,
                idChosen = document:try_get("crowsSpellDiscipline", ""),
                options = {},
                create = function(element)
                    element.options = GetSkillsByCategory("spellcasting")
                    element.idChosen = document:try_get("crowsSpellDiscipline", "")
                end,
                change = function(element)
                    if element.idChosen == "" then
                        document.crowsSpellDiscipline = nil
                    else
                        document.crowsSpellDiscipline = element.idChosen
                    end
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = "Spellcasting skill used for the casting test.",
            },
        },

        WeaponNumberField("Rank:", "crowsSpellRank",
            "Spell rank (0-5). Higher = more powerful."),

        gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = "Casting Time:",
            },
            gui.Dropdown{
                width = 140,
                height = 24,
                idChosen = document:try_get("crowsCastingTime", "Action"),
                options = {
                    { id = "None",          text = "None" },
                    { id = "Action",        text = "Action" },
                    { id = "Maneuver",      text = "Maneuver" },
                    { id = "Reaction",      text = "Reaction" },
                    { id = "Out of Combat", text = "Out of Combat" },
                },
                change = function(element)
                    if element.idChosen == "None" then
                        document.crowsCastingTime = nil
                    else
                        document.crowsCastingTime = element.idChosen
                    end
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = "Action economy cost to cast.",
            },
        },

        WeaponNumberField("Range (sq):", "crowsSpellRange",
            "Range in squares."),
        WeaponTextField("Range Text:", "crowsSpellRangeText", 150,
            "Narrative range, e.g. \"Self\", \"Melee 1\", \"Ranged 10\"."),
        gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = "Target Type:",
            },
            gui.Dropdown{
                width = 140,
                height = 24,
                idChosen = document:try_get("crowsSpellTargetType", ""),
                options = {
                    { id = "",         text = "(None)" },
                    { id = "target",   text = "Target" },
                    { id = "self",     text = "Self" },
                    { id = "allies",   text = "Allies" },
                    { id = "enemy",    text = "Enemy" },
                    { id = "creature", text = "Creature" },
                    { id = "object",   text = "Object" },
                    { id = "summoned", text = "Summoned" },
                },
                change = function(element)
                    if element.idChosen == "" then
                        document.crowsSpellTargetType = nil
                    else
                        document.crowsSpellTargetType = element.idChosen
                    end
                end,
            },
            gui.Label{
                classes = {"crowsFormHint"},
                text = "What kind of target the spell affects.",
            },
        },
        WeaponNumberField("Num Targets:", "crowsSpellNumTargets",
            "Number of targets (1 if blank)."),
        WeaponTextField("Target Text:", "crowsSpellTargetText", 200,
            "Narrative target description, e.g. \"1 creat.\", \"All creatures\"."),
        WeaponTextField("Duration:", "crowsSpellDuration", 120,
            "Instant, DT, or UD count (e.g. \"1 UD\")."),

        WeaponTextField("Tier 1:", "crowsSpellTier1", 200,
            "Outcome on 11 or lower."),
        WeaponTextField("Tier 2:", "crowsSpellTier2", 200,
            "Outcome on 12-16."),
        WeaponTextField("Tier 3:", "crowsSpellTier3", 200,
            "Outcome on 17+."),

        gui.Panel{
            classes = {"formPanel"},
            halign = "left",

            gui.Label{
                classes = {"formLabel"},
                text = "Keywords:",
            },
            gui.Check{
                text = "Attack",
                valign = "center",
                value = document:try_get("crowsSpellAttack", false),
                change = function(element)
                    if element.value then
                        document.crowsSpellAttack = true
                    else
                        document.crowsSpellAttack = nil
                    end
                end,
            },
            gui.Check{
                text = "Melee",
                valign = "center",
                lmargin = 12,
                value = document:try_get("crowsSpellMelee", false),
                change = function(element)
                    if element.value then
                        document.crowsSpellMelee = true
                    else
                        document.crowsSpellMelee = nil
                    end
                end,
            },
            gui.Check{
                text = "Ranged",
                valign = "center",
                lmargin = 12,
                value = document:try_get("crowsSpellRanged", false),
                change = function(element)
                    if element.value then
                        document.crowsSpellRanged = true
                    else
                        document.crowsSpellRanged = nil
                    end
                end,
            },
        },
    }
    crowsFields:AddChild(spellbookSection)

    formColumn:AddChild(crowsFields)

    return panel
end

-- The inventory is no longer a separate character-sheet tab; it is embedded
-- as the right-hand section of the integrated Crows Sheet (see
-- CrowdexCharacterSheet.lua, which reuses CreateCrowdexInventoryTab via the
-- CrowdexInventoryUI.CreateInventoryTab export). Deregister rather than
-- register so a stale registration from an earlier module version (e.g. after
-- a hot reload) is cleared instead of leaving the panel drawn over the sheet.
CharSheet.DeregisterTab("CrowsInventory")

-- The Crows damage rules, installed over the standard damage path so EVERY
-- damage source (abilities, monster attacks, rule strings, falls, the
-- panel's damage input) follows them. For a crow PC:
--   1. Damage drains the armor pieces in Armor Defense priority order (the
--      top of the panel's AD list absorbs and breaks first). Piercing
--      damage (info.piercing, or damagetype "piercing") skips AD.
--   2. What remains goes to Stamina through the base TakeDamage, so all
--      the usual machinery still fires: temporary stamina, losehitpoints /
--      dealdamage triggers, stat history, floaties.
--   3. Damage beyond 0 Stamina becomes wounds, queued as unassigned for
--      the player to place into backpack slots.
-- Monsters and other creature types keep the standard behavior.
local g_baseTakeDamage = creature.TakeDamage
function creature.TakeDamage(self, amount, note, info)
    if self.typeName ~= "character" then
        return g_baseTakeDamage(self, amount, note, info)
    end

    info = info or {}
    if type(amount) == "string" then
        amount = dmhub.RollInstant(amount)
    end
    if type(amount) ~= "number" or amount <= 0 then
        return g_baseTakeDamage(self, amount, note, info)
    end

    local piercing = info.piercing == true
        or string.lower(tostring(info.damagetype or "")) == "piercing"

    -- 1. Armor Defense absorbs first, top priority piece downward.
    local remaining = amount
    if not piercing then
        for _, piece in ipairs(ArmorPieces(self)) do
            if remaining <= 0 then break end
            -- A parry weapon toggled off in the Armor Defense list doesn't absorb.
            local slot = piece.active ~= false and GetSlot(self, piece.kind, piece.index) or nil
            if slot ~= nil then
                local ad = slot.ad or piece.adMax
                local absorbed = math.min(ad, remaining)
                if absorbed > 0 then
                    slot.ad = ad - absorbed
                    SetSlot(self, piece.kind, piece.index, slot)
                    remaining = remaining - absorbed

                    self:GetStatHistory("stamina"):Append{
                        note = string.format("%s absorbed %d damage%s", piece.name, absorbed,
                            cond(slot.ad <= 0, " and broke", "")),
                        set = self:CurrentHitpoints(),
                        disposition = "good",
                    }
                end
            end
        end
    end

    if remaining <= 0 then
        if self.FloatLabel ~= nil then
            self:FloatLabel(string.format("Armor absorbed %d", amount), "#aaaaff")
        end
        return
    end

    -- 2. Stamina (and temporary stamina, handled inside the base call)
    -- takes what it can; 3. the overflow becomes wounds.
    local buffer = math.max(0, self:CurrentHitpoints() or 0) + (self:TemporaryHitpoints() or 0)
    local wounds = math.max(0, remaining - buffer)
    local staminaDamage = remaining - wounds

    if staminaDamage > 0 then
        g_baseTakeDamage(self, staminaDamage, note, info)
    end

    if wounds > 0 then
        -- Auto-assign each wound to a backpack slot (empty slots first, then
        -- item slots). The player can drag a wound to a different slot later.
        local assigned = 0
        for _ = 1, wounds do
            if AssignWound(self) ~= nil then
                assigned = assigned + 1
            end
        end
        if self.FloatLabel ~= nil then
            self:FloatLabel(string.format("%d wound%s", wounds, cond(wounds == 1, "", "s")), "#ff5050")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Weapon attacks.
--
-- Crows attack resolution is structurally a Draw Steel power roll: 2d10 +
-- characteristic + weapon skill against the same tier bands (<=11 miss,
-- 12-16 tier 2, 17+ tier 3) with the same natural 19-20 crit. So wielded
-- weapons generate ActivatedAbilities through the standard power-roll
-- pipeline; tier damage routes through TakeDamage, i.e. the Crows
-- armor/stamina/wounds waterfall, and power-roll modifiers (Blessed/Boned)
-- apply automatically. Doom (natural 2-3) is noted in the ability rules
-- text but not yet automated.
--
-- Numbers are baked at build time (the abilities are rebuilt on every
-- GetActivatedAbilities call, so they stay fresh as stats change). "A or S"
-- weapons use the higher characteristic. A Parry weapon whose AD pool is
-- empty takes the -1 damage penalty from its quality.
-- ---------------------------------------------------------------------------

local function CrowsStatForWeapon(c, statSpec)
    local agi = c:GetAttribute("agility"):Value() or 0
    local str = c:GetAttribute("strength"):Value() or 0
    if statSpec == "A" then
        return agi, "Agility"
    end
    if statSpec == "S" then
        return str, "Strength"
    end
    -- "A or S": take the better one.
    if agi > str then
        return agi, "Agility"
    end
    return str, "Strength"
end

-- The flat skill bonus (+1, +2 with advancement) the crow has in the weapon
-- skill, or 0 without it. Deliberately SkillProficiencyBonus and NOT
-- SkillMod: SkillMod folds in the skill's characteristic, which the attack
-- roll already adds separately as statValue -- using it double-counts the
-- characteristic.
local function CrowsSkillModForWeaponType(c, weaponType)
    if weaponType == nil then
        return 0
    end
    local skillsTable = dmhub.GetTable(Skill.tableName) or {}
    for _, sk in unhidden_pairs(skillsTable) do
        if sk.name == weaponType then
            return c:SkillProficiencyBonus(sk) or 0
        end
    end
    return 0
end

-- Ammunition compatibility: a ranged weapon with an Ammunition Type keyword
-- (crowsAmmoType) only attacks while the crow carries compatible ammunition;
-- ammunition is compatible when it lives in an Ammunition equipment category
-- and its own Ammunition Type keyword matches the weapon's
-- (case-insensitively). A weapon with no keyword needs no ammunition.
local function NormalizeAmmoType(v)
    return string.lower(string.trim(tostring(v or "")))
end

-- Ammunition is looked up (and expended) backpack-first, in slot order, so
-- the slot the attack drains is deterministic and matches the ammo item the
-- projectile spawns. Belt and hands are fallbacks so ammo carried there
-- still fires (and still runs out) even though the backpack is the normal
-- home for quivers.
local AMMO_SEARCH_ORDER = {"backpack", "belt", "hands"}

-- The first carried ammunition item compatible with ammoType (nil if the
-- weapon needs no ammo, or none is carried). Returns the carried itemid too,
-- which the ranged attack stashes so its projectile spawns the right ammo.
local function FindCompatibleAmmo(c, ammoType)
    local want = NormalizeAmmoType(ammoType)
    if want == "" then return nil, nil end
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    for _, kind in ipairs(AMMO_SEARCH_ORDER) do
        for i = 1, ROW_CAPACITY[kind] do
            local slot = GetSlot(c, kind, i)
            local item = slot ~= nil and gearTable[slot.itemid] or nil
            if item ~= nil and IsAmmoCategory(item:try_get("equipmentCategory"))
                    and NormalizeAmmoType(item:try_get("crowsAmmoType")) == want then
                return item, slot.itemid
            end
        end
    end
    return nil, nil
end

-- A thrown weapon expends itself: throwing removes it from the hand slot
-- that held it, leaving the hand empty (the weapon flies off and lands as
-- map loot, so it can be recovered). If the same weapon is wielded in both
-- hands only the first goes. Hands normally hold one item, but a legacy
-- stack is decremented rather than wiped.
local function ExpendThrownWeapon(casterToken, itemid)
    if itemid == nil then return end
    if casterToken == nil or not casterToken.valid or casterToken.properties == nil then return end
    local props = casterToken.properties
    for i = 1, ROW_CAPACITY.hands do
        local slot = GetSlot(props, "hands", i)
        if slot ~= nil and slot.itemid == itemid then
            casterToken:ModifyProperties{
                description = "Throw weapon",
                execute = function()
                    local quantity = (slot.quantity or 1) - 1
                    if quantity > 0 then
                        slot.quantity = quantity
                        SetSlot(props, "hands", i, slot)
                    else
                        SetSlot(props, "hands", i, nil)
                    end
                end,
            }
            return
        end
    end
end

-- Expend one piece of ammunition compatible with ammoType from the first
-- slot (backpack in slot order, then belt, then hands) holding a matching
-- Ammunition item. The stack loses 1; the slot empties when it runs out,
-- which makes the weapon's ranged attack disappear on the next ability
-- rebuild. Called from the caster-side begin-roll hook only, so each shot
-- expends exactly once.
local function ExpendCompatibleAmmo(casterToken, ammoType)
    local want = NormalizeAmmoType(ammoType)
    if want == "" then return end
    if casterToken == nil or not casterToken.valid or casterToken.properties == nil then return end
    local props = casterToken.properties
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    for _, kind in ipairs(AMMO_SEARCH_ORDER) do
        for i = 1, ROW_CAPACITY[kind] do
            local slot = GetSlot(props, kind, i)
            local item = slot ~= nil and gearTable[slot.itemid] or nil
            if item ~= nil and IsAmmoCategory(item:try_get("equipmentCategory"))
                    and NormalizeAmmoType(item:try_get("crowsAmmoType")) == want then
                casterToken:ModifyProperties{
                    description = "Expend ammunition",
                    execute = function()
                        local quantity = (slot.quantity or 1) - 1
                        if quantity > 0 then
                            slot.quantity = quantity
                            SetSlot(props, kind, i, slot)
                        else
                            SetSlot(props, kind, i, nil)
                        end
                    end,
                }
                return
            end
        end
    end
end

local function HasCompatibleAmmo(c, ammoType)
    if NormalizeAmmoType(ammoType) == "" then return true end
    local item = FindCompatibleAmmo(c, ammoType)
    return item ~= nil
end

-- Builds one attack ability. args:
--   name, iconid, weaponType (skill name), statSpec ("A", "S", "A or S"),
--   t2base/t3base (numbers), mode ("melee"/"ranged"), range (squares),
--   qualities (display string), parrySpent (true = -1 damage penalty)
local function BuildCrowsAttackAbility(c, args)
    local statValue, statName = CrowsStatForWeapon(c, args.statSpec)
    local skillMod = CrowsSkillModForWeaponType(c, args.weaponType)
    local penalty = cond(args.parrySpent, 1, 0)
    local t2 = math.max(0, (args.t2base or 0) + statValue - penalty)
    local t3 = math.max(0, (args.t3base or 0) + statValue - penalty)

    local descLines = {
        string.format("%s attack: 2d10 + %s (%d)%s.",
            cond(args.mode == "melee", "Melee", "Ranged"),
            statName, statValue,
            cond(skillMod ~= 0, string.format(" + %s skill (%d)", args.weaponType or "?", skillMod), "")),
    }
    if args.qualities ~= nil and args.qualities ~= "" then
        descLines[#descLines + 1] = string.format("Qualities: %s, %s", args.weaponType or "", args.qualities)
    elseif args.weaponType ~= nil then
        descLines[#descLines + 1] = string.format("Qualities: %s", args.weaponType)
    end
    if args.parrySpent then
        descLines[#descLines + 1] = "Parry spent: this weapon's AD is 0, so it takes a -1 damage penalty until repaired."
    end
    if args.ammoType ~= nil and args.ammoType ~= "" then
        descLines[#descLines + 1] = string.format("Ammunition: %s.", args.ammoType)
    end
    if args.mode == "melee" then
        descLines[#descLines + 1] = "On a miss the target can counter. Doom (natural 2-3): tier 1 plus a major setback."
    else
        descLines[#descLines + 1] = "Beyond normal range: -2 per square. Adjacent target: -1. On a miss ammunition is destroyed and an ally adjacent to the target may be hit (tier 2; tier 3 on a doom)."
    end

    local keywords = { Weapon = true, Attack = true }
    if args.mode == "melee" then
        keywords.Melee = true
    else
        keywords.Ranged = true
    end

    -- Tier 1 (miss). On a melee attack the target may Counter, so label the
    -- tier-1 row "Counter" in dark red. ExecuteCommand only acts on damage /
    -- movement patterns, so this text is display-only. The actual counter is
    -- resolved by GameSystem.OnPowerRollResolvedAgainstTarget (CrowdexRules).
    local tier1 = ""
    if args.mode == "melee" then
        tier1 = "<color=#8b0000>Counter</color>"
    end

    local ability = ActivatedAbility.Create{
        name = args.name,
        description = table.concat(descLines, "\n"),
        iconid = args.iconid,
        range = args.range or 1,
        targetType = "target",
        numTargets = 1,
        keywords = keywords,
        --"Ability" (grouping "Abilities") renders directly in the MAIN ACTION
        --drawer's top level. "Basic Attack" maps to the "Common Abilities"
        --grouping, which the action bar buries in a nested submenu -- wrong
        --for Crows, where attacking IS the main action.
        categorization = "Ability",
        --making an attack is your action; this places attacks in the action
        --bar's MAIN ACTION drawer.
        actionResourceId = CharacterResource.actionResourceId,
        behaviors = {
            ActivatedAbilityPowerRollBehavior.new{
                roll = string.format("2d10 + %d", statValue + skillMod),
                tiers = {
                    tier1,
                    string.format("%d damage", t2),
                    string.format("%d damage", t3),
                },
            },
        },
    }

    -- Transient hints the ranged-attack animation reads off the ability: which
    -- ammo item the projectile spawns/drops, and the tier-2 damage number used
    -- when a missed shot redirects to an adjacent ally.
    if args.mode == "ranged" then
        ability._tmp_crowsAmmoItemId = args.ammoItemId
        -- nil for thrown weapons (they throw themselves; nothing to expend).
        ability._tmp_crowsAmmoType = args.ammoType
        ability._tmp_crowsTier2Damage = t2
    end

    return ability
end

-- The attack abilities for this crow's wielded weapons: one per hand-slot
-- weapon (two for thrown weapons: melee and thrown modes), plus the unarmed
-- strike everyone has.
function character:GetCrowsWeaponAttacks()
    local result = {}
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local seen = {}

    for i = 1, ROW_CAPACITY.hands do
        local slot = GetSlot(self, "hands", i)
        local item = slot ~= nil and gearTable[slot.itemid] or nil
        if item ~= nil and item:try_get("crowsWeaponType") ~= nil and not seen[slot.itemid] then
            seen[slot.itemid] = true
            local weaponType = item:try_get("crowsWeaponType")
            local statSpec = item:try_get("crowsAttackStat", "S")
            local t2base = tonumber(string.match(tostring(item:try_get("crowsTier2", "")), "^%s*(%d+)")) or 0
            local t3base = tonumber(string.match(tostring(item:try_get("crowsTier3", "")), "^%s*(%d+)")) or 0
            local qualities = item:try_get("crowsQualities", "")
            local melee = item:try_get("crowsMeleeRange")
            local ranged = item:try_get("crowsRangedRange")
            -- Parry penalty: the wielded copy's AD pool is empty.
            local parrySpent = ArmorADForItem(slot.itemid) > 0 and (slot.ad or 0) <= 0

            local common = {
                iconid = item:try_get("iconid"),
                weaponType = weaponType,
                statSpec = statSpec,
                t2base = t2base,
                t3base = t3base,
                qualities = qualities,
                parrySpent = parrySpent,
            }

            if melee ~= nil then
                local a = shallow_copy_table(common)
                a.name = item.name
                a.mode = "melee"
                a.range = melee
                result[#result + 1] = BuildCrowsAttackAbility(self, a)
            end
            if ranged ~= nil then
                -- An ammo-using weapon (a bow) with no compatible ammunition
                -- carried offers no ranged attack. Thrown weapons leave the
                -- keyword blank, so they always pass.
                local ammoType = item:try_get("crowsAmmoType")
                local ammoItem, ammoItemId = FindCompatibleAmmo(self, ammoType)
                if NormalizeAmmoType(ammoType) == "" or ammoItem ~= nil then
                    local a = shallow_copy_table(common)
                    a.name = cond(melee ~= nil, string.format("%s (Thrown)", item.name), item.name)
                    a.mode = "ranged"
                    a.range = ranged
                    a.ammoType = ammoType
                    -- For a bow this is the carried ammo (what the projectile
                    -- spawns / drops); a thrown weapon throws itself.
                    a.ammoItemId = ammoItemId or slot.itemid
                    result[#result + 1] = BuildCrowsAttackAbility(self, a)
                end
            end
        end
    end

    -- Unarmed strike: always available.
    result[#result + 1] = BuildCrowsAttackAbility(self, {
        name = "Unarmed Strike",
        weaponType = "Unarmed",
        statSpec = "A or S",
        t2base = 1,
        t3base = 2,
        mode = "melee",
        range = 1,
        qualities = "",
    })

    return result
end

local g_baseGetActivatedAbilities = creature.GetActivatedAbilities
function creature:GetActivatedAbilities(options)
    local result = g_baseGetActivatedAbilities(self, options)
    if self.typeName ~= "character" then
        return result
    end

    options = options or {}
    for _, ability in ipairs(self:GetCrowsWeaponAttacks()) do
        if options.bindCaster then
            ability._tmp_boundCaster = self
        end
        result[#result + 1] = ability
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Consumable items (potions, vials, bombs, etc.).
--
-- Draw Steel surfaces a tbl_Gear item's embedded `consumable` ActivatedAbility
-- by scanning the DS `inventory` field (MCDMCreature:GetActivatedAbilities) and
-- decrements it on use via the ability's `consumables` cost map ->
-- tok.properties:GiveItem (ActivatedAbility.lua). Crows characters don't use
-- the DS inventory at all -- their gear lives in crowdex_inventory slots -- so
-- neither the surfacing nor the GiveItem decrement reaches a crow's items.
--
-- This wrapper re-implements both halves against crowdex_inventory:
--   1. Scan ALL rows (hands, belt, backpack): consumables can be used from
--      anywhere, unlike weapons/spellbooks which must be wielded in a hand.
--   2. Append a temporary clone of each slotted item's `consumable` ability,
--      de-duped by itemid so two stacks add one action. UD-depleted items are
--      skipped (a spent item is inert).
--   3. Wire the per-use decrement: items whose `consumable` ability declares a
--      `consumables` cost map are consumed on use. We STRIP that cost map from
--      the clone (so the broken DS GiveItem decrement does nothing -- the cost
--      gates nothing else; GetCost ignores consumables for affordability) and
--      instead consume one unit from crowdex_inventory in an OnFinishCast hook,
--      wrapped in token:ModifyProperties for networking + undo. The hook is
--      skipped on an aborted/exited cast. Reusable UD-gated items (Boom Wand,
--      Minor Telekinesis Ring) deliberately omit the `consumables` map, so they
--      get an action but are never decremented.
-- ---------------------------------------------------------------------------

-- The consumable abilities this crow can use right now: one per distinct
-- slotted item that carries a `consumable` and whose Usage Dice (if any) are
-- not spent. Caller binds the caster and appends to GetActivatedAbilities.
function character:GetCrowsConsumableAbilities()
    local result = {}
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local seen = {}

    for _, kind in ipairs({"hands", "belt", "backpack"}) do
        for i = 1, ROW_CAPACITY[kind] do
            local slot = GetSlot(self, kind, i)
            if slot ~= nil and not seen[slot.itemid] then
                local item = gearTable[slot.itemid]
                if item ~= nil and item:has_key("consumable") and not IsUsageDiceDepleted(slot) then
                    seen[slot.itemid] = true

                    local itemid = slot.itemid
                    local ability = item.consumable:MakeTemporaryClone()

                    -- If the ability declares a `consumables` cost map, this
                    -- item is consumed on use. Strip the (DS-only, ineffective
                    -- for crows) cost and decrement crowdex_inventory ourselves
                    -- when the cast actually finishes. Items without the cost
                    -- map (reusable UD-gated wands/rings) get no decrement.
                    if ability:has_key("consumables") then
                        ability.consumables = {}
                        ability.OnFinishCast = function(_, finishOptions)
                            -- Don't consume on an aborted or bailed-out cast.
                            if type(finishOptions) == "table"
                                    and (finishOptions.abort or finishOptions.atexit) then
                                return
                            end
                            local tok = dmhub.LookupToken(self)
                            if tok == nil or not tok.valid or tok.properties == nil then return end
                            tok:ModifyProperties{
                                description = "Use consumable",
                                execute = function()
                                    ConsumeOneItem(tok.properties, itemid)
                                end,
                            }
                        end
                    end

                    result[#result + 1] = ability
                end
            end
        end
    end

    return result
end

-- Append consumable-item abilities. Composes with the weapon-attacks wrapper
-- above (and the spellbook wrapper in CrowdexEquipment.lua) by capturing the
-- previously installed creature.GetActivatedAbilities, so all three coexist
-- regardless of which Crowdex file loads last.
local g_baseGetActivatedAbilitiesForConsumables = creature.GetActivatedAbilities
function creature:GetActivatedAbilities(options)
    local result = g_baseGetActivatedAbilitiesForConsumables(self, options)
    if self.typeName ~= "character" then
        return result
    end

    options = options or {}
    for _, ability in ipairs(self:GetCrowsConsumableAbilities()) do
        if options.bindCaster then
            ability._tmp_boundCaster = self
        end
        result[#result + 1] = ability
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Crits, Dooms, and the Counter reaction.
--
-- Crows test results: natural 19-20 (unmodified 2d10) is a Critical, natural
-- 2-3 is a Doom. On a melee weapon attack, a tier 1 result (a miss) lets the
-- target use their reaction to Counter -- dealing their own wielded melee
-- weapon's tier 2 result (tier 3 on a Doom) back to the attacker.
-- ---------------------------------------------------------------------------

local CROWS_CRIT_MIN = 19
local CROWS_DOOM_MAX = 3

-- Dramatic banner on a Critical or Doom. Driven off the caster-side
-- "rollpower" event (dispatched once per power roll) by wrapping
-- creature.DispatchEvent -- no edits to the shared roll dialog.
local g_baseDispatchEvent = creature.DispatchEvent
function creature:DispatchEvent(eventName, arg)
    if eventName == "rollpower" and type(arg) == "table" then
        local nat = tonumber(arg.naturalroll)
        if nat ~= nil and DramaticBanner ~= nil and DramaticBanner.Show ~= nil then
            local tok = dmhub.LookupToken(self)
            local tokid = tok ~= nil and tok.id or nil
            if nat >= CROWS_CRIT_MIN then
                DramaticBanner.Show{ tokenid = tokid, text = "Critical", subtitle = "Natural " .. tostring(nat) }
            elseif nat <= CROWS_DOOM_MAX then
                DramaticBanner.Show{ tokenid = tokid, text = "Doom", subtitle = "Natural " .. tostring(nat) }
            end
        end
    end
    return g_baseDispatchEvent(self, eventName, arg)
end

-- The target's wielded melee weapon used for a counter, or nil for unarmed.
local function WieldedMeleeWeapon(c)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    for i = 1, ROW_CAPACITY.hands do
        local slot = GetSlot(c, "hands", i)
        local item = slot ~= nil and gearTable[slot.itemid] or nil
        if item ~= nil and item:try_get("crowsWeaponType") ~= nil and item:try_get("crowsMeleeRange") ~= nil then
            return item
        end
    end
    return nil
end

-- The counter's damage and weapon name: the counterer's wielded melee weapon
-- tier 2 result (tier 3 on a doom), or an unarmed strike if none wielded.
local function CounterDamage(counterer, doom)
    local item = WieldedMeleeWeapon(counterer)
    local statSpec, t2base, t3base, name
    if item ~= nil then
        statSpec = item:try_get("crowsAttackStat", "S")
        t2base = tonumber(string.match(tostring(item:try_get("crowsTier2", "")), "^%s*(%d+)")) or 0
        t3base = tonumber(string.match(tostring(item:try_get("crowsTier3", "")), "^%s*(%d+)")) or 0
        name = item.name
    else
        statSpec, t2base, t3base, name = "A or S", 1, 2, "Unarmed Strike"
    end
    local statValue = CrowsStatForWeapon(counterer, statSpec)
    local base = cond(doom, t3base, t2base)
    return math.max(0, base + statValue), name
end

-- Pull the numeric damage out of a power roll behavior's tier text (e.g.
-- "7 damage" -> 7). Only used to scale the engine hit-animation knockback.
local function TierDamageNumber(ability, tier)
    if ability == nil then return 5 end
    for _, behavior in ipairs(ability:try_get("behaviors", {})) do
        if behavior.typeName == "ActivatedAbilityPowerRollBehavior" then
            local tiers = behavior:try_get("tiers")
            local text = tiers ~= nil and tiers[tier] or nil
            if type(text) == "string" then
                local n = tonumber(string.match(text, "(%d+)"))
                if n ~= nil then return n end
            end
        end
    end
    return 5
end

-- Like TierDamageNumber but returns nil (not a fallback) when a tier carries no
-- numeric damage, so non-damaging maneuvers (Grab, Knockback) are excluded when
-- picking a monster's counter weapon below.
local function ParseTierDamage(ability, tier)
    if ability == nil then return nil end
    for _, behavior in ipairs(ability:try_get("behaviors", {})) do
        if behavior.typeName == "ActivatedAbilityPowerRollBehavior" then
            local tiers = behavior:try_get("tiers")
            local text = tiers ~= nil and tiers[tier] or nil
            if type(text) == "string" then
                local n = tonumber(string.match(text, "(%d+)"))
                if n ~= nil then return n end
            end
        end
    end
    return nil
end

-- Squares; the largest melee reach we expect on a Crows creature (Large). A
-- keyword-less attack with a longer range is treated as ranged, not melee.
local CROWS_MELEE_REACH_MAX = 2

-- Is this ability a melee attack (or melee maneuver) for Counter purposes?
-- Crow weapon attacks built by BuildCrowsAttackAbility carry the Melee keyword.
-- Monster and pet attacks come from the importer with NO keywords at all, so we
-- fall back to shape: a single-target power-roll ability at melee reach. This
-- also catches the Grab/Knockback maneuvers, which the rules say trigger a
-- counter too. (Ranged attacks carry the Ranged keyword for crows, or a longer
-- range for monsters.)
local function CrowsIsMeleeAttack(ability)
    if ability == nil then return false end
    if ability:HasKeyword("Ranged") then return false end
    if ability:HasKeyword("Melee") then return true end
    if ability:try_get("targetType") ~= "target" then return false end
    if (tonumber(ability:try_get("range")) or 99) > CROWS_MELEE_REACH_MAX then return false end
    for _, behavior in ipairs(ability:try_get("behaviors", {})) do
        if behavior.typeName == "ActivatedAbilityPowerRollBehavior" then
            return true
        end
    end
    return false
end

-- Counter damage and weapon name for a monster/pet counterer: its own best
-- (highest-damage) melee attack's tier 2 result, tier 3 on a doom, read from
-- the attack's tier text. Returns nil if the creature has no damaging melee
-- attack to riposte with (so it can't counter).
local function MonsterCounterDamage(counterToken, doom)
    if counterToken == nil or not counterToken.valid or counterToken.properties == nil then
        return nil
    end
    local best, bestTier2
    for _, a in ipairs(counterToken.properties:GetActivatedAbilities() or {}) do
        if CrowsIsMeleeAttack(a) then
            local t2 = ParseTierDamage(a, 2)
            if t2 ~= nil and (bestTier2 == nil or t2 > bestTier2) then
                bestTier2, best = t2, a
            end
        end
    end
    if best == nil then return nil end
    local damage = ParseTierDamage(best, cond(doom, 3, 2)) or bestTier2
    return damage, best.name
end

-- Player-facing cue: crow weapon attacks get a dark-red "Counter" label on
-- their tier-1 (miss) row in BuildCrowsAttackAbility. Monster and pet melee
-- attacks come from the importer without it, so stamp the same label here when
-- their abilities are surfaced. The label is display-only; the actual counter
-- is resolved by GameSystem.OnPowerRollResolvedAgainstTarget below.
--
-- Monster abilities are persistent objects (innateActivatedAbilities), returned
-- by reference, so this mutates in place -- but it is idempotent (skips a row
-- that already mentions Counter) and the label is correct for every Crows melee
-- attack, so a single stamp per ability is harmless and never accumulates.
local COUNTER_TIER1_LABEL = "<color=#8b0000>Counter</color>"
local g_baseGetActivatedAbilitiesForCounterLabel = creature.GetActivatedAbilities
function creature:GetActivatedAbilities(options)
    local result = g_baseGetActivatedAbilitiesForCounterLabel(self, options)
    if self.typeName == "character" then
        return result
    end
    for _, ability in ipairs(result) do
        if CrowsIsMeleeAttack(ability) then
            for _, behavior in ipairs(ability:try_get("behaviors", {})) do
                if behavior.typeName == "ActivatedAbilityPowerRollBehavior" then
                    local tiers = behavior:try_get("tiers")
                    -- Skip if the row already mentions a counter (case
                    -- insensitive) -- some maneuvers (Grab, Knockback) ship with
                    -- their own "The target can counter." note.
                    if tiers ~= nil and type(tiers[1]) == "string"
                            and not string.find(string.lower(tiers[1]), "counter", 1, true) then
                        if tiers[1] == "" then
                            tiers[1] = COUNTER_TIER1_LABEL
                        else
                            tiers[1] = tiers[1] .. "; " .. COUNTER_TIER1_LABEL
                        end
                    end
                end
            end
        end
    end
    return result
end

-- Allies of the attacker adjacent to (within 1 square of) the enemy, skipping
-- the attacker, the enemy itself, and downed creatures.
local function AdjacentAlliesOfAttacker(attackerToken, enemyToken)
    local result = {}
    if enemyToken.GetNearbyTokens == nil then return result end
    for _, tok in ipairs(enemyToken:GetNearbyTokens(1) or {}) do
        if tok ~= nil and tok.valid and tok.id ~= attackerToken.id and tok.id ~= enemyToken.id then
            local isAlly = tok.IsFriend ~= nil and tok:IsFriend(attackerToken)
            local down = tok.properties ~= nil and tok.properties.IsDownCached ~= nil and tok.properties:IsDownCached()
            if isAlly and not down then
                result[#result + 1] = tok
            end
        end
    end
    return result
end

-- Pending tier-1 ranged redirect, keyed by attacker charid: the random adjacent
-- ally the arrow flew into, and the tier-2 damage to apply when it lands. Set as
-- the shot is loosed (begin), consumed at the per-target resolution.
local g_rangedRedirect = {}

-- Fire a Crows ranged attack as a real, dice-synced projectile (the 5e physical
-- projectile system: a networked map object that windups at the bow then flies
-- so it strikes as the dice settle). Outcome by tier:
--   tier 2 -> strike the enemy off-centre; 50% the arrow drops as loot.
--   tier 3 -> strike the enemy nearer the centre of mass; 50% drops as loot.
--   tier 1 -> a miss: if the attacker has allies adjacent to the enemy the
--             arrow flies into a random one (dealing the bow's tier-2 result to
--             that ally, applied as the arrow lands); otherwise it flies wide.
--             A missed arrow is always destroyed.
-- Thrown weapons reuse this path but, being weapons rather than spent ammo,
-- always land as loot.
local function CrowsFireRangedProjectile(ability, casterToken, targetToken, rollInfo, rollid)
    if Projectile == nil or Projectile.Fire == nil or dmhub.GetAttackTrajectory == nil then return end
    local missileid = ability:try_get("_tmp_crowsAmmoItemId")
    if missileid == nil then return end
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local missileItem = gearTable[missileid]
    if missileItem == nil then return end

    local isConsumable = IsAmmoCategory(missileItem:try_get("equipmentCategory"))
    local src = core.Vector2(casterToken.posWithLean.x, casterToken.posWithLean.y)
    local tier = RollUtils.DiceResultToTier(rollInfo)

    local function trajectory(tok, kind)
        local fallback = core.Vector2(tok.loc.x, tok.loc.y)
        local t = dmhub.GetAttackTrajectory(casterToken, tok, src, kind)
        if t == nil then return fallback end
        if kind == "Miss" then
            return t.obstructionPoint or t.destPoint or fallback
        end
        return t.destPoint or fallback
    end

    local fireTarget = targetToken      -- the token the projectile aims at / flashes
    local outcome = "Hit"
    local dest
    local dropAmmo

    g_rangedRedirect[casterToken.charid] = nil

    if tier >= 2 then
        dest = trajectory(targetToken, "Hit")
        if tier == 3 then
            -- Pull the impact 60% of the way toward the target's centre of mass.
            local center = core.Vector2(targetToken.loc.x, targetToken.loc.y)
            dest = core.Vector2(dest.x + (center.x - dest.x) * 0.6, dest.y + (center.y - dest.y) * 0.6)
        end
        dropAmmo = (not isConsumable) or (math.random() < 0.5)
    else
        -- tier 1 miss: redirect into an adjacent ally, else fly wide.
        local allies = AdjacentAlliesOfAttacker(casterToken, targetToken)
        if #allies > 0 then
            local ally = allies[math.random(#allies)]
            fireTarget = ally
            dest = trajectory(ally, "Hit")
            g_rangedRedirect[casterToken.charid] = {
                allyId = ally.id,
                damage = ability:try_get("_tmp_crowsTier2Damage") or TierDamageNumber(ability, 2),
            }
        else
            outcome = "Miss"
            dest = trajectory(targetToken, "Miss")
        end
        -- A spent arrow is destroyed on a miss; a thrown weapon still lands.
        dropAmmo = (not isConsumable)
    end

    -- On a hit, scale the target's impact knockback by the damage dealt (the
    -- enemy's tier damage, or the bow's tier-2 result for a redirected stray).
    local hitDamage = nil
    if outcome ~= "Miss" then
        if tier >= 2 then
            hitDamage = TierDamageNumber(ability, tier)
        else
            hitDamage = ability:try_get("_tmp_crowsTier2Damage") or TierDamageNumber(ability, 2)
        end
    end

    Projectile.Fire{
        ability = ability,
        casterToken = casterToken,
        targetToken = fireTarget,
        rollInfo = rollInfo,
        rollKey = rollid,
        missileid = missileid,
        properties = { outcome = outcome, expectedDamage = hitDamage },
        target = dest,
        dropAmmo = dropAmmo,
        -- Resting sublayer is below tokens (correct for the arrow in flight, once
        -- it lands as loot, and for clients that download the dropped arrow later).
        -- While it is nocked on the attacker and launching, drawSublayer lifts it
        -- above tokens so it reads in front of the shooter; it drops back below
        -- tokens as soon as it clears the attacker.
        sublayer = "Objects",
        drawSublayer = "EffectsAboveTokens",
    }
end

-- Begin-of-roll animation hook (called from MCDMAbilityRollBehavior's beginRoll
-- when the dice are thrown). A weapon attack plays its dice-synced animation;
-- the result is already deterministic in rollInfo, so we classify it now.
--   Melee: the engine's token attack animation -- attacker and defender shuffle
--     while the dice tumble, then the attacker lunges so the strike lands as the
--     dice settle. tier 1 (miss) -> the defender dodges; tier 2 -> a hit; tier 3
--     -> a critical (faster thrust). On a hit the engine flashes the target and
--     the standard DS damage webp + sound fire automatically when the tier
--     damage applies (also at dice-settle), so they land together with the lunge.
--   Ranged: a real projectile (see CrowsFireRangedProjectile).
-- The roll key lets the engine sync the windup/thrust to the 3D dice timing.
function GameSystem.OnPowerRollBeginAnimation(ability, casterToken, targets, rollInfo, rollid)
    if ability == nil or casterToken == nil or not casterToken.valid then return end
    if casterToken.properties == nil or casterToken.properties.typeName ~= "character" then return end
    if not ability:HasKeyword("Weapon") then return end
    if targets == nil or #targets == 0 then return end

    local targetToken = targets[1].token
    if targetToken == nil or not targetToken.valid then return end

    if ability:HasKeyword("Ranged") then
        -- The shot is loosed here, so this is where the expenditure happens --
        -- independent of whether the projectile visual fires. Ammo-using
        -- weapons spend a piece of ammunition; thrown weapons throw
        -- themselves, emptying the hand that held them.
        local ammoType = ability:try_get("_tmp_crowsAmmoType")
        if NormalizeAmmoType(ammoType) ~= "" then
            ExpendCompatibleAmmo(casterToken, ammoType)
        else
            ExpendThrownWeapon(casterToken, ability:try_get("_tmp_crowsAmmoItemId"))
        end
        CrowsFireRangedProjectile(ability, casterToken, targetToken, rollInfo, rollid)
        return
    end

    if not ability:HasKeyword("Melee") then return end
    if casterToken.AnimateAttack == nil then return end

    local tier = RollUtils.DiceResultToTier(rollInfo)
    local outcome = "Hit"
    if tier == 1 then
        outcome = "Dodge"
    elseif tier == 3 then
        outcome = "Critical"
    end

    casterToken:AnimateAttack{
        targetid = targetToken.charid,
        rollid = rollid or "none",
        damage = TierDamageNumber(ability, tier),
        outcome = outcome,
    }
end

-- Crows has no manual Accept / Re-roll step on power rolls: the dialog resolves
-- on its own and lingers a moment before dismissing itself. EmbeddedRollDialog
-- checks these two; applying the result on auto-proceed (rather than on a
-- button press) is what lets a hit's damage land together with the dice-synced
-- attack animation above.
GameSystem.RollDialogDismissDelay = 1.25
function GameSystem.RollDialogAutoProceed(options)
    if options == nil then return false end
    return options.type == "ability_power_roll"
end

-- Per-target post-roll hook (called from MCDMAbilityRollBehavior). On a missed
-- (tier 1) melee weapon attack the target Counters; on a missed ranged weapon
-- attack a redirected arrow may strike an adjacent ally.
function GameSystem.OnPowerRollResolvedAgainstTarget(ability, casterToken, targetToken, tier, rollInfo, options)
    if ability == nil or casterToken == nil or targetToken == nil then return end
    if tier ~= 1 then return end

    -- Ranged: a missed shot that CrowsFireRangedProjectile redirected into an
    -- adjacent ally deals the bow's tier-2 result to that ally, scheduled so the
    -- damage and float text land as the arrow actually strikes them (the arrow
    -- was loosed at begin and flies for the dice-settle plus a short flight).
    if ability:HasKeyword("Weapon") and ability:HasKeyword("Ranged") then
        local pending = g_rangedRedirect[casterToken.charid]
        g_rangedRedirect[casterToken.charid] = nil
        if pending ~= nil then
            local attackerCreature = casterToken.valid and casterToken.properties or nil
            local allyId = pending.allyId
            local damage = pending.damage or 0
            dmhub.Schedule(0.35, function()
                if mod.unloaded then return end
                local allyTok = dmhub.GetTokenById(allyId)
                if allyTok == nil or not allyTok.valid or allyTok.properties == nil then return end
                allyTok:ModifyProperties{
                    description = "Stray arrow",
                    execute = function()
                        allyTok.properties:TakeDamage(damage, "Stray arrow", { attacker = attackerCreature })
                    end,
                }
            end)
        end
        return
    end

    -- A melee attack or melee maneuver. Crow weapon attacks carry Weapon+Melee
    -- keywords; monster/pet attacks (and Grab/Knockback maneuvers) come from the
    -- importer with no keywords, so CrowsIsMeleeAttack falls back to shape.
    if not CrowsIsMeleeAttack(ability) then return end

    -- The counterer is the target of the attack. Both crows (characters) and
    -- pets/monsters can counter: every creature has a reaction (Crows rules,
    -- "Counter"). Objects and other non-combatants can't.
    local counterer = targetToken.properties
    if counterer == nil then return end
    if counterer.typeName ~= "character" and counterer.typeName ~= "monster" then return end
    if not targetToken.valid or not casterToken.valid then return end

    -- Countering costs the counterer's response (the once-per-round reaction).
    -- If they have no response left this round, they can't counter.
    local responseMax = (counterer:GetResources() or {})[CharacterResource.triggerResourceId] or 0
    local responseUsed = counterer:GetResourceUsage(CharacterResource.triggerResourceId, "round") or 0
    if (responseMax - responseUsed) <= 0 then return end

    local nat = rollInfo ~= nil and tonumber(rollInfo.naturalRoll) or nil
    local doom = nat ~= nil and nat <= CROWS_DOOM_MAX

    -- Crows wield melee weapons (tier 2 result, tier 3 on a doom, or an unarmed
    -- strike); monsters/pets riposte with their own best melee attack. A monster
    -- with no damaging melee attack simply can't counter.
    local damage, weaponName
    if counterer.typeName == "character" then
        damage, weaponName = CounterDamage(counterer, doom)
    else
        damage, weaponName = MonsterCounterDamage(targetToken, doom)
        if damage == nil then return end
    end

    if not casterToken.valid or casterToken.properties == nil then return end

    -- Spend the counterer's response (reaction) up front.
    if targetToken.valid and targetToken.properties ~= nil then
        targetToken:ModifyProperties{
            description = "Counter (response)",
            execute = function()
                targetToken.properties:ConsumeResource(CharacterResource.triggerResourceId, "round", 1)
            end,
        }
    end

    -- The counter is a riposte: after a beat (so the attacker's missed lunge
    -- and the defender's dodge resolve first), the defender lunges back at the
    -- attacker. The counter damage -- the counterer's wielded melee weapon tier
    -- 2 result (tier 3 on a Doom) through the Crows damage waterfall -- and its
    -- float text are timed to land as the riposte connects, not the moment the
    -- miss is rolled. The riposte has no dice of its own, so its lunge fires
    -- immediately and connects after the engine's thrust window (~0.2s).
    local attackerId = casterToken.id
    local counterId = targetToken.id
    local counterOutcome = cond(doom, "Critical", "Hit")
    local COUNTER_BEAT = 0.7
    local COUNTER_IMPACT = 0.22

    dmhub.Schedule(COUNTER_BEAT, function()
        if mod.unloaded then return end
        local counterTok = dmhub.GetTokenById(counterId)
        local attackerTok = dmhub.GetTokenById(attackerId)
        if counterTok == nil or not counterTok.valid then return end
        if attackerTok == nil or not attackerTok.valid then return end

        if counterTok.properties ~= nil and counterTok.properties.FloatLabel ~= nil then
            counterTok.properties:FloatLabel(string.format("Counter! %s", weaponName), "#e8d59a")
        end

        if counterTok.AnimateAttack ~= nil then
            counterTok:AnimateAttack{
                targetid = attackerId,
                rollid = "none",
                damage = damage,
                outcome = counterOutcome,
            }
        end

        dmhub.Schedule(COUNTER_IMPACT, function()
            if mod.unloaded then return end
            local atk = dmhub.GetTokenById(attackerId)
            local ctr = dmhub.GetTokenById(counterId)
            if atk == nil or not atk.valid or atk.properties == nil then return end
            atk:ModifyProperties{
                description = "Counter",
                execute = function()
                    -- info.attacker must be the creature (TakeDamage calls
                    -- IsHero / GetClass on it), not the token.
                    local attackerCreature = ctr ~= nil and ctr.valid and ctr.properties or nil
                    atk.properties:TakeDamage(damage, "Counter", { attacker = attackerCreature })
                end,
            }
        end)
    end)
end

-- Crows characters carry items in crowdex_inventory slots, but the engine
-- (loot pickup via GameHud.LootAll, trades, scripts) delivers items through
-- creature:GiveItem into the Draw Steel inventory map. Route positive gear
-- grants straight into slots so they appear immediately everywhere; items
-- that don't fit fall through to the engine inventory, which the character
-- sheet's reconciler migrates once room frees up. Removals (negative
-- quantities) and unknown items pass through untouched, as do non-character
-- creatures (monsters, parties, loot containers).
local g_baseGiveItem = character.GiveItem
function character:GiveItem(itemid, quantity, slotIndex)
    quantity = quantity or 1
    if quantity > 0 then
        local gearTable = dmhub.GetTable("tbl_Gear") or {}
        local item = gearTable[itemid]
        if item ~= nil then
            local remaining = quantity
            while remaining > 0 do
                if not AddItemToCharacter(self, item, 1) then
                    break
                end
                remaining = remaining - 1
            end
            if remaining <= 0 then
                return
            end
            quantity = remaining
        end
    end
    return g_baseGiveItem(self, itemid, quantity, slotIndex)
end

-- Shared with the docked character panel (CrowdexCharacterPanel.lua), which
-- renders the same slot rows and drag-and-drop rules with a token-based
-- environment (see SlotRow's env parameter).
CrowdexInventoryUI = {
    SlotRow = SlotRow,
    SlotColumn = SlotColumn,
    HAND_LABELS = HAND_LABELS,
    ROW_CAPACITY = ROW_CAPACITY,
    GetSlot = GetSlot,
    SetSlot = SetSlot,
    MakeSlotEntry = MakeSlotEntry,
    AddItemToCharacter = AddItemToCharacter,
    DropItemOnMap = DropItemOnMap,
    MaxStackForItem = MaxStackForItem,
    SlotsRequiredForItem = SlotsRequiredForItem,
    FirstEmptySlot = FirstEmptySlot,
    OccupantOf = OccupantOf,
    ArmorADForItem = ArmorADForItem,
    IsShieldItem = IsShieldItem,
    ArmorPieces = ArmorPieces,
    -- Usage Dice: data accessors plus the roll/restore/refuel operations, so
    -- future trigger hooks (spellbook "activate", end-of-dungeon-turn "dt",
    -- rest restore) can drive the same model the inventory UI uses.
    UsageDiceForItem = UsageDiceForItem,
    UsageDiceTrigger = UsageDiceTrigger,
    UsageDiceRestore = UsageDiceRestore,
    UsageDiceRefuelItem = UsageDiceRefuelItem,
    CurrentUsageDice = CurrentUsageDice,
    IsUsageDiceDepleted = IsUsageDiceDepleted,
    RollUsageDiceForSlot = RollUsageDiceForSlot,
    RestoreUsageDice = RestoreUsageDice,
    RefuelUsageDice = RefuelUsageDice,
    IsSlotWounded = IsSlotWounded,
    CountWoundedSlots = CountWoundedSlots,
    CountWoundedItemSlots = CountWoundedItemSlots,
    AssignWound = AssignWound,
    MoveWound = MoveWound,
    -- The full inventory tab panel, reused as the right-hand column of the
    -- integrated Crows character sheet (CrowdexCharacterSheet.lua).
    CreateInventoryTab = CreateCrowdexInventoryTab,
}
