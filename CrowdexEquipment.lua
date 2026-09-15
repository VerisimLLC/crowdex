local mod = dmhub.GetModLoading()

-- Crows wielded-item display on tokens.
--
-- The base creature:GetWieldObjects() (DMHub Game Rules/Creature.lua) derives
-- the token's held-item visuals from the Draw Steel loadout model: the
-- selected loadout's mainhand/offhand equipment slots (where mainhand1 is the
-- light-source slot, which is why Draw Steel tokens only ever show torches)
-- plus belt accessory slots. Crows characters don't use that model at all --
-- their items live in crowdex_inventory hand slots (see CrowdexInventory.lua).
--
-- Override GetWieldObjects for characters so the two Crows hand slots (L/R)
-- render as the token's mainhand/offhand wield objects, D&D-style: you see
-- exactly what the crow is holding. Belt items are never shown on Crows
-- tokens. The override is on character (heroes); Crows monsters have no
-- crowdex_inventory and keep the base creature behavior.
--
-- No other plumbing is needed (see WIELD_ITEMS_REFERENCE.md): the engine
-- calls properties:GetWieldObjects() on every token refresh and attaches the
-- items' wield objects to the token's hand anchors, including the light
-- component for held torches.

-- The item in the given Crows hand slot (1 = L, 2 = R), or nil. Slots are
-- keyed "slot1"/"slot2" with a fallback to legacy numeric keys, matching
-- CrowdexInventory's GetSlot. Only the anchor slot of a multi-slot (two
-- handed) item reports it, so a 2-slot item renders in one hand rather than
-- twice.
local function HandItemId(props, index)
    local inv = props:try_get("crowdex_inventory")
    if inv == nil then return nil end
    local hands = inv.hands
    if hands == nil then return nil end
    local slot = hands["slot" .. tostring(index)] or hands[index]
    if slot == nil then return nil end
    -- A Usage Dice item whose pool is spent is inert: it stops being wielded
    -- (no token visual / light) and grants no abilities (a burned-out spellbook
    -- can't be cast) until its UD are restored. Resolved at call time so load
    -- order between this module and CrowdexInventory doesn't matter.
    if CrowdexInventoryUI ~= nil and CrowdexInventoryUI.IsUsageDiceDepleted ~= nil
            and CrowdexInventoryUI.IsUsageDiceDepleted(slot) then
        return nil
    end
    return slot.itemid
end

function character:GetWieldObjects()
    local gearTable = GetTableCached("tbl_Gear")

    local function displayable(itemid)
        if itemid == nil then return nil end
        local gearEntry = gearTable[itemid]
        if gearEntry == nil or (not gearEntry:DisplayOnToken()) then
            return nil
        end
        return itemid
    end

    return {
        mainhand = displayable(HandItemId(self, 1)),
        offhand = displayable(HandItemId(self, 2)),
        belt = {},
    }
end

-- ---------------------------------------------------------------------------
-- Spellbooks.
--
-- A spellbook is a wielded item (Spellbook equipment category, or any item
-- flagged crowsSpellbook) that grants a single castable spell ability while
-- held in a hand slot, exactly like a weapon grants its attack (see
-- character:GetCrowsWeaponAttacks in CrowdexInventory.lua). The casting is a
-- flat Mind test (2d10 + Mind); the spell's discipline names the spellcasting
-- EXPERTISE that can be spent on it, which is not a bonus added to the roll.
-- Outcomes per casting tier are stored on the
-- item and run through the standard power-roll pipeline, so damage (scaled by
-- {Mind}), push, and prone resolve automatically. Other outcomes (heal, AD,
-- blessed/weakened, teleport-self, summon, etc.) are not reachable from the tier
-- command grammar yet and read as descriptive tier text.
--
-- Usage Dice are deliberately not modeled here (a separate change): a wielded
-- spellbook can currently be cast freely.
-- ---------------------------------------------------------------------------

local SPELLBOOK_CATEGORY = "b8e4d6a2-9f13-4c57-ae80-3d1f6b29c4e7"

function IsSpellbookItem(item)
    if item == nil then return false end
    return item:try_get("crowsSpellbook", false) == true
        or item:try_get("equipmentCategory") == SPELLBOOK_CATEGORY
end

-- The action-economy resource a casting spends, from the spell's casting time.
-- "Out of Combat" spells can't be cast in tracked rounds; modelled as an
-- action so they still appear in the action drawer (the 10-minute restriction
-- is narrative).
local function SpellbookResourceId(castingTime)
    local t = string.lower(string.trim(tostring(castingTime or "action")))
    if t == "maneuver" then return CharacterResource.maneuverResourceId end
    if t == "reaction" then return CharacterResource.triggerResourceId end
    return CharacterResource.actionResourceId
end


-- Builds the casting ability for one wielded spellbook item.
--
-- The casting is a flat 2d10 + Mind. Playtest 1 added the discipline's skill
-- bonus on top; Playtest 2 makes a discipline an EXPERTISE -- "a spell's
-- discipline describes ... the spellcasting expertise than can be used for the
-- test made to cast the spell" -- and an expertise is spent after the roll to
-- improve the result, never added to it. Same correction as the weapon skill
-- coming off attack rolls in stage 4, and Endurance coming off the Miasma test.
local function BuildCrowsSpellbookAbility(c, item, itemid)
    local discipline = item:try_get("crowsSpellDiscipline", "")
    local roll = "2d10 + Mind"
    local mind = c:AttributeMod("mind")

    local function HasTrait(name)
        return CrowdexTraits ~= nil and CrowdexTraits.Has ~= nil and CrowdexTraits.Has(c, name)
    end

    local function AddMindToCharacteristicText(text, outcome)
        local pattern = "(%d+)%s*%+%s*M(%s+" .. outcome .. ")"
        return string.gsub(text, pattern, function(base, suffix)
            return string.format("%d + M%s", (tonumber(base) or 0) + mind, suffix)
        end)
    end

    local attack = item:try_get("crowsSpellAttack", false)
    local keywords = { Magic = true }
    if attack then keywords.Attack = true end
    if item:try_get("crowsSpellMelee", false) then keywords.Melee = true end
    if item:try_get("crowsSpellRanged", false) then keywords.Ranged = true end

    local tiers = {
        item:try_get("crowsSpellTier1", ""),
        item:try_get("crowsSpellTier2", ""),
        item:try_get("crowsSpellTier3", ""),
    }

    if discipline == "Elemental" and HasTrait("Burn Baby") then
        for i, text in ipairs(tiers) do tiers[i] = AddMindToCharacteristicText(text, "damage") end
    elseif discipline == "Benefaction" and HasTrait("Enhanced Healing") then
        for i, text in ipairs(tiers) do tiers[i] = AddMindToCharacteristicText(text, "Stamina") end
    elseif discipline == "Conjuration" and HasTrait("Jumper") then
        for i, text in ipairs(tiers) do tiers[i] = AddMindToCharacteristicText(text, "squares") end
    end

    -- Crows spell cards use "N + M" shorthand. Resolve it while the generated
    -- ability has its caster so the downstream Draw Steel command parser sees
    -- an exact number and never consults stale Draw Steel characteristic ids.
    for i, text in ipairs(tiers) do
        tiers[i] = string.gsub(text, "(%d+)%s*%+%s*M", function(base)
            return tostring((tonumber(base) or 0) + mind)
        end)
    end

    local rangeBonus = 0
    if item:try_get("crowsSpellRanged", false) then
        if discipline == "Elemental" and HasTrait("Hurl the Storm") then
            rangeBonus = mind
        elseif discipline == "Illusion" and HasTrait("Long-Distance Illusion") then
            rangeBonus = mind
        elseif discipline == "Necromancy" and HasTrait("Distant Necromancy") then
            rangeBonus = mind
        end
    end

    local descLines = {}
    local rank = item:try_get("crowsSpellRank")
    descLines[#descLines + 1] = string.format("Casting (%s%s): 2d10 + Mind.",
        cond(discipline ~= "", discipline, "spell"),
        cond(rank ~= nil, " R" .. tostring(rank), ""))
    local rangeText = item:try_get("crowsSpellRangeText")
    if rangeText ~= nil and rangeText ~= "" then
        descLines[#descLines + 1] = "Range: " .. rangeText
            .. cond(rangeBonus ~= 0, string.format(" (%+d from trait)", rangeBonus), "")
    end
    local targetText = item:try_get("crowsSpellTargetText")
    if targetText ~= nil and targetText ~= "" then
        descLines[#descLines + 1] = "Target: " .. targetText
    end
    local durationText = item:try_get("crowsSpellDuration")
    if durationText ~= nil and durationText ~= "" then
        local lastingTrait = nil
        if discipline == "Alteration" then
            lastingTrait = "Lasting Alteration"
        elseif discipline == "Benefaction" then
            lastingTrait = "Lasting Benefaction"
        elseif discipline == "Conjuration" then
            lastingTrait = "Lasting Conjuration"
        elseif discipline == "Illusion" then
            lastingTrait = "Lasting Illusion"
        end
        if lastingTrait ~= nil and string.find(string.upper(durationText), "UD", 1, true) and HasTrait(lastingTrait) then
            durationText = durationText .. " (+1 UD from " .. lastingTrait .. ")"
        end
        descLines[#descLines + 1] = "Duration: " .. durationText
    end
    local cardText = item:try_get("description")
    if cardText ~= nil and cardText ~= "" then
        descLines[#descLines + 1] = cardText
    end

    local ability = ActivatedAbility.Create{
        --Rebuilt on every GetActivatedAbilities call, so override Create's
        --random guid with a stable one: the action bar's novel-ability
        --tracker keys on guid, and a fresh guid each rebuild would re-flag
        --the casting as newly gained on every bar refresh.
        guid = "crows-spell:" .. itemid,
        name = item.name,
        description = table.concat(descLines, "\n"),
        iconid = item:try_get("iconid"),
        range = math.max(0, item:try_get("crowsSpellRange", 1) + rangeBonus),
        targetType = item:try_get("crowsSpellTargetType", "target"),
        numTargets = item:try_get("crowsSpellNumTargets", 1),
        keywords = keywords,
        -- "Ability" places the casting in the action bar's MAIN drawer,
        -- matching how Crows weapon attacks are surfaced.
        categorization = "Ability",
        actionResourceId = SpellbookResourceId(item:try_get("crowsCastingTime", "Action")),
        behaviors = {
            ActivatedAbilityPowerRollBehavior.new{
                roll = roll,
                tiers = tiers,
            },
        },
    }
    ability.crowdexExpertiseId = CrowdexExpertise.IdByName(discipline, "Spellcasting") or ""
    return ability
end

-- The casting abilities for this crow's wielded spellbooks: one per hand-slot
-- spellbook. Books in the backpack/belt are not castable -- a spellbook must
-- be wielded (placed in a hand slot) to be used.
function character:GetCrowsSpellbookAbilities()
    local result = {}
    local gearTable = GetTableCached("tbl_Gear")
    local seen = {}
    for i = 1, 2 do
        local itemid = HandItemId(self, i)
        if itemid ~= nil and not seen[itemid] then
            local item = gearTable[itemid]
            if IsSpellbookItem(item) then
                seen[itemid] = true
                result[#result + 1] = BuildCrowsSpellbookAbility(self, item, itemid)
            end
        end
    end
    return result
end

-- Append wielded-spellbook castings to a character's activated abilities, the
-- same way CrowdexInventory appends weapon attacks. Layered wrappers compose:
-- whichever of CrowdexInventory / CrowdexEquipment loads second wraps the
-- other, and both sets of abilities are returned regardless of load order.
local g_baseGetActivatedAbilitiesForSpellbooks = creature.GetActivatedAbilities
function creature:GetActivatedAbilities(options)
    local result = g_baseGetActivatedAbilitiesForSpellbooks(self, options)
    if self.typeName ~= "character" then
        return result
    end

    options = options or {}
    for _, ability in ipairs(self:GetCrowsSpellbookAbilities()) do
        if options.bindCaster then
            ability._tmp_boundCaster = self
        end
        result[#result + 1] = ability
    end
    return result
end
