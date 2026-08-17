local mod = dmhub.GetModLoading()

-- Crows ruleset definitions. This file loads after the Draw Steel rules, so
-- registrations here replace the Draw Steel equivalents.

-- The three Crows characteristics. Clearing and re-registering means any
-- interface that iterates creature.attributeIds (character sheet, character
-- panel, inspector, etc.) shows the Crows characteristics instead of the
-- Draw Steel ones. Note ClearAttributes also clears registered saving throws;
-- Crows resistance rolls (RRs) are tests against characteristics, so no
-- separate saving throws are registered.
creature.ClearAttributes()

creature.RegisterAttribute{
    id = "agility",
    description = "Agility",
    short = "AGI",
    order = 10,
}

creature.RegisterAttribute{
    id = "mind",
    description = "Mind",
    short = "MND",
    order = 20,
}

creature.RegisterAttribute{
    id = "strength",
    description = "Strength",
    short = "STR",
    order = 30,
}

-- Crows skill categories replace the Draw Steel ones (crafting, exploration,
-- etc.). The Skill game type keeps its category list as static Lua data (see
-- MCDMSkills.lua); skills imported with these category ids group under the
-- right headings in skill pickers and the compendium editor.
--
-- Playtest 2 retired skills in favour of expertises (see creature:Crowdex-
-- Expertises below), but this registry stays: the item editor still reads the
-- weapon and spellcasting categories to populate the dropdowns that set an
-- item's crowsWeaponType and spellbook discipline (CrowdexInventory.lua). The
-- Skills table rows themselves are left in place rather than deleted, so
-- nothing that still references one breaks.
Skill.categories = {
    {
        id = "general",
        text = "General",
    },
    {
        id = "spellcasting",
        text = "Spellcasting",
    },
    {
        id = "weapon",
        text = "Weapon",
    },
}

Skill.categoriesById = {}
for i,v in ipairs(Skill.categories) do
    Skill.categoriesById[v.id] = v
end

Skill.category = "general"

-- The expertises this creature has, and how many uses are left in each.
--
-- Playtest 2 deleted skills. An expertise is not a bonus on the roll -- it is a
-- pool you spend AFTER a roll to improve the result by one tier -- so it is
-- modelled as a CharacterResource per expertise (usageLimit "long", refreshed
-- by the Finish Rest action). A crow's uses come from their background's
-- resource grants and from advancement.
--
-- Expertise resources are identified by their grouping ("General Expertise",
-- "Spellcasting Expertise", "Weapon Expertise"), which keeps the three
-- categories the rules define without needing a parallel registry.
--
-- Entries are shaped for the sheet and side panel:
--   {id, name, category, max, used, remaining}
-- sorted by name. Any creature can be asked -- a monster simply has none.
local EXPERTISE_CATEGORIES = {
    ["General Expertise"] = "General",
    ["Spellcasting Expertise"] = "Spellcasting",
    ["Weapon Expertise"] = "Weapon",
}

function creature:CrowdexExpertises()
    local result = {}
    local resourceTable = dmhub.GetTable("characterResources") or {}

    for key, quantity in pairs(self:GetResources() or {}) do
        local info = resourceTable[key]
        if info ~= nil then
            local category = EXPERTISE_CATEGORIES[info:try_get("grouping", "")]
            if category ~= nil then
                local max = tonumber(quantity) or 0
                local used = 0
                pcall(function()
                    used = self:GetResourceUsage(key, info:try_get("usageLimit", "long")) or 0
                end)
                result[#result + 1] = {
                    id = key,
                    name = info.name,
                    category = category,
                    max = max,
                    used = used,
                    remaining = math.max(0, max - used),
                }
            end
        end
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- Crows PCs have no class; their Stamina comes entirely from their
-- background's hitpoints modifier. The Draw Steel BaseHitpoints returns a
-- floor of 1 when the character has no class, which would inflate every
-- crow's Stamina by 1. Return 0 instead so the background modifier is the
-- whole base value. Characters with a class (if any ever exist in Crows)
-- keep the standard calculation.
local g_baseHitpoints = character.BaseHitpoints
function character:BaseHitpoints()
    if self:GetClass() == nil then
        return 0
    end
    return g_baseHitpoints(self)
end

-- All crows have a starting speed of 5. The base game's
-- character:BaseWalkingSpeed() defaults to 30 (a 5e feet-based legacy value)
-- when the character has no ancestry to supply a speed, which crows never
-- have. An explicit walkingSpeed override (set via the attribute override
-- popup) still wins. Speed bonuses and penalties apply normally on top via
-- the speed attribute modifiers and movement multiplier.
function character:BaseWalkingSpeed()
    return self:try_get("walkingSpeed", 5)
end

-- Crows rounds everything down (see "Always Round Down" in The Rules
-- booklet), including halved speed from prone. The base WalkingSpeed can
-- return fractions (e.g. 2.5 from a 0.5 movement multiplier).
--
-- Wounds: "For each slot occupied by a wound and an item, your speed is
-- reduced by 1 (to a minimum of 0)." Only a backpack slot holding BOTH a
-- wound and an item costs speed -- a wound on an empty slot is free, which is
-- why wounds auto-assign to empty slots first (CrowdexInventory.AssignWound).
-- CrowdexInventoryUI is a global defined in CrowdexInventory.lua; resolved at
-- call time, so load order does not matter.
local g_walkingSpeed = creature.WalkingSpeed
function creature:WalkingSpeed()
    local speed = math.floor(g_walkingSpeed(self))
    if CrowdexInventoryUI ~= nil and CrowdexInventoryUI.CountWoundedItemSlots ~= nil then
        speed = speed - CrowdexInventoryUI.CountWoundedItemSlots(self)
    end
    return math.max(0, speed)
end

-- A crow at 0 Stamina is still up and fighting: damage past 0 becomes wounds
-- that fill backpack slots, and the crow only dies when ALL backpack slots
-- hold a wound (see Damage and Death in The Rules booklet). The Draw Steel
-- character:IsDead() keys off stamina, which mis-flags living crows as down:
-- the engine suppresses token status icons, applies death styling, and skips
-- them for targeting. creature:IsDown() routes through IsDead(), so this
-- override covers both.
--
-- Animals (Crows monsters that carry a crowsSlots property) follow the same
-- wound model: damage past 0 Stamina becomes wounds against their slots, and
-- they die only when their wounds fill every slot. An animal with crowsSlots
-- == 0 has no room for any wound, so it dies the moment it reaches 0 Stamina
-- (the normal monster rule). Other Crows monsters (Blood Creatures, the Ring
-- Collector) have no crowsSlots and keep dying at 0 Stamina.
local CROWS_BACKPACK_SLOTS = 10

-- Wound-slot capacity for the Crows damage/death model. A crow PC uses its
-- 10-slot backpack; an animal uses its crowsSlots property. Returns nil for
-- any creature that does not participate in the wound model (e.g. ordinary
-- Crows monsters with no crowsSlots), so callers can fall back to the base
-- stamina-based death rule.
function creature:CrowsSlotCapacity()
    if self.typeName == "character" then
        return CROWS_BACKPACK_SLOTS
    end
    local slots = self:try_get("crowsSlots")
    if slots ~= nil then
        return math.max(0, tonumber(slots) or 0)
    end
    return nil
end

-- Total wounds the creature is carrying. Both crow PCs and animals record
-- wounds as filled backpack/wound slots (crowdex_woundSlots), so counting that
-- per-slot map is the single source of truth and matches what the slot UI
-- renders. The crowdex_unassignedWounds term is a legacy fallback: an earlier
-- build queued animal wounds in that counter instead of the slot map, so an
-- animal carried over mid-game still dies at the right point.
function creature:CrowsTotalWounds()
    local wounds = 0
    local woundSlots = self:try_get("crowdex_woundSlots")
    if woundSlots ~= nil then
        for _, wounded in pairs(woundSlots) do
            if wounded then
                wounds = wounds + 1
            end
        end
    end

    wounds = wounds + (tonumber(self:try_get("crowdex_unassignedWounds", 0)) or 0)
    return wounds
end

function character:IsDead()
    -- Every wound must fill a slot, so once the total reaches the backpack
    -- size there is nowhere left to put them.
    return self:CrowsTotalWounds() >= self:CrowsSlotCapacity()
end

-- Animals die by the wound model: only once they are at 0 Stamina AND their
-- wounds fill every slot. The HP<=0 guard is essential -- a 0-slot animal
-- (crowsSlots == 0) at full Stamina has 0 wounds >= 0 capacity, which without
-- the guard would read as dead while alive. With the guard, a 0-slot animal
-- simply dies the instant it hits 0 Stamina, matching the base rule. Monsters
-- with no crowsSlots fall through to the base stamina-based death check.
local g_baseMonsterIsDead = monster.IsDead
function monster:IsDead()
    local capacity = self:CrowsSlotCapacity()
    if capacity == nil then
        return g_baseMonsterIsDead(self)
    end

    return (self:CurrentHitpoints() or 0) <= 0 and self:CrowsTotalWounds() >= capacity
end

-- Crows action economy. The Draw Steel base grants string-keyed resources
-- (standardAction/movementAction/bonusAction/reaction), but the action bar
-- and the CharacterResource.* Lua constants key off GUIDs. Grant the Crows
-- economy by those GUIDs so the action bar's MAIN ACTION / MANEUVER / TRIGGER
-- drawers find their resources and show the right availability pips. The
-- matching resource definitions (names, refresh) are imported from
-- crows-resources.yaml.
--
-- Per The Rules booklet ("Turn"): a maneuver and an action, or two maneuvers,
-- each turn; 1 reaction per round. Move is the Move Speed maneuver (distance =
-- speed), so it needs no resource -- the action bar's Move drawer is a
-- distance bar. We layer the GUIDs on top of the base resources rather than
-- replacing them, so any base-engine code still reading the string keys keeps
-- working. Applies to every creature: Crows monsters also act and react.
local g_baseCreatureResources = GameSystem.BaseCreatureResources
function GameSystem.BaseCreatureResources(creature)
    local result = g_baseCreatureResources(creature)
    result[CharacterResource.actionResourceId] = 1
    result[CharacterResource.maneuverResourceId] = 1
    result[CharacterResource.triggerResourceId] = 1
    return result
end

--use a crow sound as the iconic crows sound.
audio.SoundEvent{
    name = "UI.DrawSteel",
    mixgroup = "ui",
    sounds = {"abl/shapeshift/Abl_Shapeshift_Start_Crow_v1_01.wav","abl/shapeshift/Abl_Shapeshift_Start_Crow_v1_02.wav","abl/shapeshift/Abl_Shapeshift_Start_Crow_v1_03.wav"},
    volume = 1,
}

-- Crows-specific setting defaults. A setting is keyed by its id, so re-running
-- setting{} with the same id replaces the prior registration (the engine keeps
-- its original ordinal/position). This file loads after the engine core
-- settings and the Draw Steel rules, so these win. We deep-copy the existing
-- definition and only override the default, which preserves the editor, enum,
-- storage, help, etc. of the original -- so this stays correct if those change.
--
-- Only the DEFAULT changes: games where a DM already set one of these keep
-- their chosen value (all three are storage = "game"). The new default applies
-- to fresh games / values that were never set.
local function CrowdexSettingDefault(settingId, defaultValue)
    local existing = Settings[settingId]
    if existing == nil then
        -- The source setting hasn't been registered yet; load order changed.
        -- Fail loud rather than silently registering a bare setting.
        dmhub.Debug(string.format("Crowdex: cannot override default for unknown setting '%s'", settingId))
        return
    end

    local info = dmhub.DeepCopy(existing)
    info.default = defaultValue
    setting(info)
end

-- Lighting engine: Crows defaults to the "Old School" lighting model.
CrowdexSettingDefault("lightingengine", "oldschool")

-- Monster Name Generation: default to "None" (the enum value for None is the
-- boolean false; see DMHub Game Rules/Monster.lua), so monsters spawn unnamed.
CrowdexSettingDefault("assignmonstersnames", false)

-- Players May Rename Monsters: on by default in Crows.
CrowdexSettingDefault("players_rename_monsters", true)
