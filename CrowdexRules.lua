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

-- Expertise is a Crows resource system, not a Draw Steel skill bonus. Keep a
-- small registry/service here so roll handling, advancement, crafting, item
-- editors, and the sheet all use the same catalog and resource rules.
CrowdexExpertise = rawget(_G, "CrowdexExpertise") or {}
local Expertise = CrowdexExpertise

Expertise.categoriesByGrouping = {
    ["General Expertise"] = "General",
    ["Spellcasting Expertise"] = "Spellcasting",
    ["Weapon Expertise"] = "Weapon",
}

-- Draw Steel builds this shorthand map before Crowdex replaces its attributes.
-- Repoint it so rules text using A, M, or S resolves against the Crows
-- characteristics rather than stale Might/Agility ids.
GameSystem.AttributeByFirstLetter = GameSystem.AttributeByFirstLetter or {}
GameSystem.AttributeByFirstLetter.a = "agility"
GameSystem.AttributeByFirstLetter.m = "mind"
GameSystem.AttributeByFirstLetter.s = "strength"

Expertise.groupingByCategory = {
    General = "General Expertise",
    Spellcasting = "Spellcasting Expertise",
    Weapon = "Weapon Expertise",
}

-- Returns every imported expertise, including ones the creature does not yet
-- possess. The compendium table is the canonical id/name store, so preserving
-- the existing resource ids also preserves all current character usage.
function Expertise.Catalog(category)
    local result = {}
    local resourceTable = dmhub.GetTable("characterResources") or {}
    for id, info in unhidden_pairs(resourceTable) do
        local expertiseCategory = Expertise.categoriesByGrouping[info:try_get("grouping", "")]
        if expertiseCategory ~= nil and (category == nil or category == expertiseCategory) then
            result[#result + 1] = {
                id = id,
                name = info.name,
                category = expertiseCategory,
                description = info:try_get("description", ""),
                resource = info,
            }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function Expertise.FindById(id)
    if id == nil or id == "" or id == "none" then return nil end
    local info = (dmhub.GetTable("characterResources") or {})[id]
    if info == nil then return nil end
    local category = Expertise.categoriesByGrouping[info:try_get("grouping", "")]
    if category == nil then return nil end
    return {
        id = id,
        name = info.name,
        category = category,
        description = info:try_get("description", ""),
        resource = info,
    }
end

function Expertise.FindByName(name, category)
    if name == nil then return nil end
    local wanted = string.lower(string.trim(tostring(name)))
    for _, entry in ipairs(Expertise.Catalog(category)) do
        if string.lower(entry.name) == wanted then return entry end
    end
    return nil
end

function Expertise.IdByName(name, category)
    local entry = Expertise.FindByName(name, category)
    return entry and entry.id or nil
end

function Expertise.IsExpertiseId(id)
    return Expertise.FindById(id) ~= nil
end

local function TemporaryExpertiseBonuses(c)
    local result = {}
    for _, source in pairs(c:try_get("crowdex_temporaryExpertises", {})) do
        for id, quantity in pairs(source.grants or {}) do
            if Expertise.IsExpertiseId(id) then
                result[id] = (result[id] or 0) + math.max(0, math.floor(tonumber(quantity) or 0))
            end
        end
    end
    return result
end

function Expertise.IsSuppressed(c)
    for _, active in pairs(c:try_get("crowdex_expertiseSuppression", {})) do
        if active then return true end
    end
    return false
end

-- Source-aware temporary grants support lore books, Miasma effects, and
-- transformations without altering permanent advancement allocations.
function Expertise.SetTemporaryGrant(c, sourceId, grants, expires)
    if c == nil or sourceId == nil then return end
    local all = c:get_or_add("crowdex_temporaryExpertises", {})
    local normalized = {}
    for id, quantity in pairs(grants or {}) do
        local n = math.max(0, math.floor(tonumber(quantity) or 0))
        if n > 0 and Expertise.IsExpertiseId(id) then normalized[id] = n end
    end
    if next(normalized) == nil then
        all[sourceId] = nil
    else
        all[sourceId] = { grants = normalized, expires = expires or "manual" }
    end
    c:InvalidateResources()
end

function Expertise.RemoveTemporaryGrant(c, sourceId)
    local all = c:try_get("crowdex_temporaryExpertises")
    if all ~= nil then
        all[sourceId] = nil
        c:InvalidateResources()
    end
end

function Expertise.SetSuppressed(c, sourceId, active)
    local all = c:get_or_add("crowdex_expertiseSuppression", {})
    all[sourceId] = active and true or nil
end

function Expertise.Available(c, id)
    if Expertise.IsSuppressed(c) then return 0 end
    local entry = Expertise.FindById(id)
    if entry == nil then return 0 end
    local maximum = (c:GetResources() or {})[id] or 0
    local used = c:GetResourceUsage(id, entry.resource:try_get("usageLimit", "long")) or 0
    return math.max(0, maximum - used)
end

function Expertise.CanCraft(c, id, requiredUses)
    if Expertise.IsSuppressed(c) then return false end
    return ((c:GetResources() or {})[id] or 0) >= math.max(0, tonumber(requiredUses) or 0)
end

-- Crafting is the written exception to ordinary expertise use: each selected
-- expertise adds +4, and up to two distinct expertises can be spent.
function Expertise.ValidateCraftingSelection(c, ids)
    local seen = {}
    local result = {}
    for _, id in ipairs(ids or {}) do
        if not seen[id] then
            if #result >= 2 then return false, "Only two expertises can be used on a crafting roll." end
            if Expertise.FindById(id) == nil then return false, "Unknown expertise." end
            if Expertise.Available(c, id) < 1 then return false, "That expertise has no uses remaining." end
            seen[id] = true
            result[#result + 1] = id
        end
    end
    return true, result
end

function Expertise.SpendCraftingSelection(c, ids)
    local valid, selection = Expertise.ValidateCraftingSelection(c, ids)
    if not valid then return false, selection end
    for _, id in ipairs(selection) do
        local entry = Expertise.FindById(id)
        c:ConsumeResource(id, entry.resource:try_get("usageLimit", "long"), 1, "Crafting expertise")
    end
    return true, #selection * 4
end

CrowdexCrafting = rawget(_G, "CrowdexCrafting") or {}
local Crafting = CrowdexCrafting

-- Craft cards currently store their prerequisite and goal in the printed
-- description. Normalize that clause in one place until those fields become
-- first-class item editor properties.
function Crafting.ParseItem(item)
    if item == nil then return nil end
    local description = item:try_get("description", "")
    local startAt = string.find(description, "Craft:", 1, true)
    if startAt == nil then return nil end
    local clause = string.sub(description, startAt)
    -- A quality-scaled card can print values such as "1/2/3 uses" and
    -- "20/100/200". The current inventory record represents one base item,
    -- so use the standard-quality (first) values while still cataloging it.
    local expertiseName, required = string.match(clause,
        "Craft:%s*([%a%s]+)%s*%((%d+)[%d/]*%s+uses?%)")
    local goal = string.match(clause, ",%s*(%d+)[%d/]*%s*%.")
    if expertiseName == nil or required == nil or goal == nil then return nil end
    local expertise = Expertise.FindByName(string.trim(expertiseName), "General")
    if expertise == nil then return nil end
    return {
        itemId = item.id,
        item = item,
        clause = clause,
        expertiseId = expertise.id,
        expertiseName = expertise.name,
        requiredUses = tonumber(required),
        goal = tonumber(goal),
    }
end

function Crafting.Catalog()
    local result = {}
    for _, item in unhidden_pairs(dmhub.GetTable("tbl_Gear") or {}) do
        local info = Crafting.ParseItem(item)
        if info ~= nil then result[#result + 1] = info end
    end
    table.sort(result, function(a, b) return a.item.name < b.item.name end)
    return result
end

function Crafting.Progress(c, itemId)
    local project = c:try_get("crowdex_craftingProjects", {})[itemId]
    return project and math.max(0, math.floor(tonumber(project.points) or 0)) or 0
end

function Crafting.CalculateRoll(c, naturalRoll, otherBonus, expertiseIds)
    local valid, selection = Expertise.ValidateCraftingSelection(c, expertiseIds)
    if not valid then return nil, selection end
    naturalRoll = math.floor(tonumber(naturalRoll) or 0)
    local doom = naturalRoll >= 2 and naturalRoll <= 3
    local crit = naturalRoll >= 19
    if doom then
        return { natural = naturalRoll, total = 0, doom = true, crit = false, expertiseIds = selection }
    end
    local total = naturalRoll + c:AttributeMod("mind") + math.floor(tonumber(otherBonus) or 0) + (#selection * 4)
    return {
        natural = naturalRoll,
        total = math.max(1, total),
        doom = false,
        crit = crit,
        expertiseIds = selection,
    }
end

-- Mutates the project owner and grants completed copies. Materials and tools
-- remain Ref-adjudicated because current cards contain prose rather than
-- structured inventory requirements.
function Crafting.ApplyProgress(owner, craftInfo, points)
    local projects = owner:get_or_add("crowdex_craftingProjects", {})
    local project = projects[craftInfo.itemId] or { points = 0 }
    project.points = math.max(0, math.floor(tonumber(project.points) or 0)) + math.max(0, math.floor(points or 0))
    local completed = 0
    while project.points >= craftInfo.goal do
        project.points = project.points - craftInfo.goal
        owner:GiveItem(craftInfo.itemId, 1)
        completed = completed + 1
    end
    projects[craftInfo.itemId] = project
    return completed, project.points
end

-- Expertise/Stamina advancement. Claims are the canonical ledger; bonuses are
-- projected into resources and BaseHitpoints rather than copied into a second
-- persistent store.
CrowdexAdvancement = rawget(_G, "CrowdexAdvancement") or {}
local Advancement = CrowdexAdvancement

Advancement.thresholds = { 100, 500, 1250, 2250, 3500, 5000, 10000, 20000, 30000 }
Advancement.characteristicThresholds = { 5000, 15000, 30000 }

function Advancement.TotalXP(c) return math.max(0, math.floor(tonumber(c:try_get("crowdex_totalXP", 0)) or 0)) end
function Advancement.LegacySpentXP(c)
    if c:try_get("crowdex_traitLedgerVersion", 0) >= 1 then
        return math.max(0, math.floor(tonumber(c:try_get("crowdex_legacySpentXP", 0)) or 0))
    end
    return math.max(0, math.floor(tonumber(c:try_get("crowdex_spentXP", 0)) or 0))
end

function Advancement.TraitPurchaseSpentXP(c)
    local result = 0
    for _, purchase in pairs(c:try_get("crowdex_purchasedTraits", {}) or {}) do
        if type(purchase) == "table" then
            result = result + math.max(0, math.floor(tonumber(purchase.xpCost) or 0))
        end
    end
    return result
end

function Advancement.SpentXP(c)
    return Advancement.LegacySpentXP(c) + Advancement.TraitPurchaseSpentXP(c)
end
function Advancement.RestedXP(c) return math.max(0, math.floor(tonumber(c:try_get("crowdex_restedXP", 0)) or 0)) end
function Advancement.UnspentXP(c) return math.max(0, Advancement.TotalXP(c) - Advancement.SpentXP(c)) end
function Advancement.SpendableXP(c) return math.max(0, Advancement.RestedXP(c) - Advancement.SpentXP(c)) end

function Advancement.ThresholdForBonus(index)
    if index <= #Advancement.thresholds then return Advancement.thresholds[index] end
    return 30000 + (index - #Advancement.thresholds) * 30000
end

function Advancement.UnlockedBonusCount(xp)
    xp = math.max(0, math.floor(tonumber(xp) or 0))
    local count = 0
    for _, threshold in ipairs(Advancement.thresholds) do
        if xp < threshold then return count end
        count = count + 1
    end
    return count + math.floor((xp - 30000) / 30000)
end

function Advancement.CharacteristicThresholdForBonus(index)
    if index <= #Advancement.characteristicThresholds then
        return Advancement.characteristicThresholds[index]
    end
    return 30000 + (index - #Advancement.characteristicThresholds) * 30000
end

function Advancement.UnlockedCharacteristicBonusCount(xp)
    xp = math.max(0, math.floor(tonumber(xp) or 0))
    local count = 0
    for _, threshold in ipairs(Advancement.characteristicThresholds) do
        if xp < threshold then return count end
        count = count + 1
    end
    return count + math.floor((xp - 30000) / 30000)
end

function Advancement.MaxExpertiseUses(xp)
    xp = tonumber(xp) or 0
    if xp >= 20000 then return 4 end
    if xp >= 5000 then return 3 end
    return 2
end

local function AdvancementClaims(c)
    return c:try_get("crowdex_advancementClaims", {}) or {}
end

function Advancement.ExpertiseBonuses(c)
    local result = {}
    for _, claim in pairs(AdvancementClaims(c)) do
        for id, quantity in pairs(claim.expertises or {}) do
            if Expertise.IsExpertiseId(id) then
                result[id] = (result[id] or 0) + math.max(0, math.floor(tonumber(quantity) or 0))
            end
        end
    end
    return result
end

function Advancement.StaminaBonus(c)
    local result = 0
    for _, claim in pairs(AdvancementClaims(c)) do
        result = result + math.max(0, math.floor(tonumber(claim.stamina) or 0))
    end
    return result
end

function Advancement.CharacteristicBonuses(c)
    local result = { agility = 0, mind = 0, strength = 0 }
    for key, claim in pairs(AdvancementClaims(c)) do
        if string.find(key, "^characteristic:") and result[claim.characteristic] ~= nil then
            result[claim.characteristic] = result[claim.characteristic] + 1
        end
    end
    return result
end

function Advancement.UnclaimedBonuses(c)
    local result = {}
    local claims = AdvancementClaims(c)
    for index = 1, Advancement.UnlockedBonusCount(Advancement.RestedXP(c)) do
        local key = "expertise-stamina:" .. tostring(index)
        if claims[key] == nil then
            result[#result + 1] = { index = index, threshold = Advancement.ThresholdForBonus(index) }
        end
    end
    return result
end

function Advancement.UnclaimedCharacteristicBonuses(c)
    local result = {}
    local claims = AdvancementClaims(c)
    for index = 1, Advancement.UnlockedCharacteristicBonusCount(Advancement.RestedXP(c)) do
        local key = "characteristic:" .. tostring(index)
        if claims[key] == nil then
            result[#result + 1] = {
                index = index,
                threshold = Advancement.CharacteristicThresholdForBonus(index),
            }
        end
    end
    return result
end

local function PermanentExpertiseMaximum(c, id)
    local value = (c:GetResources() or {})[id] or 0
    return math.max(0, value - (TemporaryExpertiseBonuses(c)[id] or 0))
end

Advancement.PermanentExpertiseMaximum = PermanentExpertiseMaximum

function Advancement.ValidateClaim(c, index, claim)
    index = math.floor(tonumber(index) or 0)
    if index < 1 or index > Advancement.UnlockedBonusCount(Advancement.RestedXP(c)) then
        return false, "That advancement bonus is not available until after a qualifying rest."
    end
    local key = "expertise-stamina:" .. tostring(index)
    if AdvancementClaims(c)[key] ~= nil then return false, "That advancement bonus has already been claimed." end

    local kind = claim and claim.kind or ""
    local expectedExpertise = 0
    local expectedStamina = 0
    if kind == "expertise" then
        expectedExpertise = 3
    elseif kind == "stamina" then
        expectedStamina = 2
    elseif kind == "mixed" then
        expectedExpertise = 1
        expectedStamina = 1
    else
        return false, "Choose Expertise, Stamina, or a mixed advancement."
    end

    if math.floor(tonumber(claim.stamina) or 0) ~= expectedStamina then return false, "Invalid Stamina award." end
    local expertiseTotal = 0
    local cap = Advancement.MaxExpertiseUses(Advancement.RestedXP(c))
    for id, quantity in pairs(claim.expertises or {}) do
        local n = tonumber(quantity) or 0
        if Expertise.FindById(id) == nil or n < 0 or n ~= math.floor(n) then return false, "Invalid expertise allocation." end
        if PermanentExpertiseMaximum(c, id) + n > cap then
            return false, string.format("%s cannot exceed %d uses at this TXP.", Expertise.FindById(id).name, cap)
        end
        expertiseTotal = expertiseTotal + n
    end
    if expertiseTotal ~= expectedExpertise then
        return false, string.format("This choice must allocate exactly %d expertise uses.", expectedExpertise)
    end
    return true
end

function Advancement.Claim(c, index, claim)
    local valid, errorText = Advancement.ValidateClaim(c, index, claim)
    if not valid then return false, errorText end
    local claims = c:get_or_add("crowdex_advancementClaims", {})
    local key = "expertise-stamina:" .. tostring(index)
    claims[key] = {
        threshold = Advancement.ThresholdForBonus(index),
        kind = claim.kind,
        stamina = math.floor(tonumber(claim.stamina) or 0),
        expertises = DeepCopy(claim.expertises or {}),
        claimedRestId = c:try_get("longRestId", "none"),
    }
    c:InvalidateResources()
    return true
end

function Advancement.ValidateCharacteristicClaim(c, index, characteristic)
    index = math.floor(tonumber(index) or 0)
    if index < 1 or index > Advancement.UnlockedCharacteristicBonusCount(Advancement.RestedXP(c)) then
        return false, "That characteristic increase is not available until after a qualifying rest."
    end

    local key = "characteristic:" .. tostring(index)
    if AdvancementClaims(c)[key] ~= nil then
        return false, "That characteristic increase has already been claimed."
    end

    local allAtMaximum = c:AttributeMod("agility") >= 4
        and c:AttributeMod("mind") >= 4
        and c:AttributeMod("strength") >= 4
    if allAtMaximum then
        if characteristic ~= "stamina" then
            return false, "All characteristics are already 4; take +2 Stamina instead."
        end
        return true
    end

    if characteristic ~= "agility" and characteristic ~= "mind" and characteristic ~= "strength" then
        return false, "Choose Agility, Mind, or Strength."
    end
    if c:AttributeMod(characteristic) >= 4 then
        return false, "A characteristic cannot be increased above 4."
    end
    return true
end

function Advancement.ClaimCharacteristic(c, index, characteristic)
    local valid, errorText = Advancement.ValidateCharacteristicClaim(c, index, characteristic)
    if not valid then return false, errorText end

    local claims = c:get_or_add("crowdex_advancementClaims", {})
    local key = "characteristic:" .. tostring(index)
    claims[key] = {
        threshold = Advancement.CharacteristicThresholdForBonus(index),
        characteristic = cond(characteristic == "stamina", nil, characteristic),
        stamina = cond(characteristic == "stamina", 2, 0),
        claimedRestId = c:try_get("longRestId", "none"),
    }
    c:InvalidateResources()
    return true
end

function Advancement.OnRest(c)
    c.crowdex_restedXP = Advancement.TotalXP(c)
    local temporary = c:try_get("crowdex_temporaryExpertises")
    if temporary ~= nil then
        for sourceId, source in pairs(temporary) do
            if source.expires == "rest" then temporary[sourceId] = nil end
        end
    end
    c:InvalidateResources()
end

-- Crows traits use the standard feat record envelope for compendium storage,
-- but have their own tag, tree metadata, purchase ledger, and acquisition
-- rules. They never enter creatureFeats, so Draw Steel feat pickers and Crows
-- advancement cannot leak into one another.
CrowdexTraits = rawget(_G, "CrowdexTraits") or {}
local Traits = CrowdexTraits

local function IsCrowsTrait(feat)
    local result = false
    if feat ~= nil then
        pcall(function() result = feat:HasTag("Crows Trait") end)
    end
    return result
end

local function TraitCatalogCache()
    if Traits._tmp_catalogUpdate == dmhub.ngameupdate and Traits._tmp_catalog ~= nil then
        return Traits._tmp_catalog
    end
    local result = {}
    for id, feat in unhidden_pairs(dmhub.GetTable(CharacterFeat.tableName) or {}) do
        if IsCrowsTrait(feat) then
            result[#result + 1] = {
                id = id,
                name = feat.name,
                description = feat:try_get("description", ""),
                tree = feat:try_get("crowdexTraitTree", ""),
                cost = math.max(0, math.floor(tonumber(feat:try_get("crowdexTraitCost", 0)) or 0)),
                starting = feat:try_get("crowdexTraitStarting", false),
                rank = math.max(1, math.floor(tonumber(feat:try_get("crowdexTraitRank", 1)) or 1)),
                prerequisites = feat:try_get("crowdexTraitPrerequisites", {}) or {},
                feat = feat,
            }
        end
    end
    table.sort(result, function(a, b)
        if a.tree ~= b.tree then return a.tree < b.tree end
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)
    Traits._tmp_catalogUpdate = dmhub.ngameupdate
    Traits._tmp_catalog = result
    return result
end

function Traits.Catalog(tree)
    local result = {}
    for _, entry in ipairs(TraitCatalogCache()) do
        if tree == nil or entry.tree == tree then
            result[#result + 1] = shallow_copy_table(entry)
        end
    end
    return result
end

function Traits.FindById(id)
    if id == nil or id == "" or id == "none" then return nil end
    for _, entry in ipairs(TraitCatalogCache()) do
        if entry.id == id then return shallow_copy_table(entry) end
    end
    return nil
end

function Traits.FindByName(name)
    local normalized = string.lower(trim(name or ""))
    for _, entry in ipairs(TraitCatalogCache()) do
        if string.lower(entry.name) == normalized then return shallow_copy_table(entry) end
    end
    return nil
end

function Traits.BackgroundTraitId(c)
    local background = c and c:Background() or nil
    if background == nil then return nil end
    for _, feature in ipairs(background:GetClassLevel().features or {}) do
        local id = feature:try_get("crowdexTraitId", "")
        if id ~= "" and Traits.FindById(id) ~= nil then return id end
    end
    return nil
end

function Traits.OwnedTraitIds(c)
    local result = {}
    local backgroundId = Traits.BackgroundTraitId(c)
    if backgroundId ~= nil then result[backgroundId] = "Background" end
    for id, purchase in pairs(c:try_get("crowdex_purchasedTraits", {}) or {}) do
        if type(purchase) == "table" and Traits.FindById(id) ~= nil then
            result[id] = "Purchased"
        end
    end
    return result
end

function Traits.OwnedTraits(c)
    local result = {}
    for id, grantedBy in pairs(Traits.OwnedTraitIds(c)) do
        local entry = Traits.FindById(id)
        if entry ~= nil then
            entry.grantedBy = grantedBy
            entry.purchase = (c:try_get("crowdex_purchasedTraits", {}) or {})[id]
            result[#result + 1] = entry
        end
    end
    table.sort(result, function(a, b)
        if a.tree ~= b.tree then return a.tree < b.tree end
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)
    return result
end

function Traits.Has(c, idOrName)
    local entry = Traits.FindById(idOrName) or Traits.FindByName(idOrName)
    return entry ~= nil and Traits.OwnedTraitIds(c)[entry.id] ~= nil
end

function Traits.CanPurchase(c, traitId)
    local entry = Traits.FindById(traitId)
    if entry == nil then return false, "That Crows trait does not exist." end
    local owned = Traits.OwnedTraitIds(c)
    if owned[traitId] ~= nil then return false, "You already have this trait." end
    if Advancement.SpendableXP(c) < entry.cost then
        return false, string.format("This trait costs %d XP; you have %d rested XP available.", entry.cost, Advancement.SpendableXP(c))
    end
    if entry.starting then return true end
    for _, prerequisiteId in ipairs(entry.prerequisites) do
        if owned[prerequisiteId] ~= nil then return true end
    end
    return false, "You must own a trait connected to this one in its trait tree."
end

local function EnsureTraitLedger(c)
    if c:try_get("crowdex_traitLedgerVersion", 0) >= 1 then return end
    c.crowdex_legacySpentXP = math.max(0, math.floor(tonumber(c:try_get("crowdex_spentXP", 0)) or 0))
    c.crowdex_traitLedgerVersion = 1
end

function Traits.Purchase(c, traitId)
    local valid, errorText = Traits.CanPurchase(c, traitId)
    if not valid then return false, errorText end
    EnsureTraitLedger(c)
    local entry = Traits.FindById(traitId)
    local purchases = c:get_or_add("crowdex_purchasedTraits", {})
    purchases[traitId] = {
        xpCost = entry.cost,
        purchasedRestId = c:try_get("longRestId", "none"),
    }
    c:InvalidateResources()
    return true
end

-- Project purchased/background traits through the ordinary CharacterFeature
-- pipeline. The data record remains canonical, so fixing a trait in local data
-- immediately updates every crow that owns it without copying stale modifiers
-- into character state.
local g_crowdexBaseGetClassFeatures = character.GetClassFeatures
function character:GetClassFeatures(options)
    local result = g_crowdexBaseGetClassFeatures(self, options)
    local existing = {}
    for _, feature in ipairs(result) do
        existing[feature:try_get("guid", "")] = true
    end

    for _, trait in ipairs(Traits.OwnedTraits(self)) do
        local traitFeatures = {}
        trait.feat:FillClassFeatures(self:GetLevelChoices(), traitFeatures, self)
        for _, feature in ipairs(traitFeatures) do
            local guid = feature:try_get("guid", "")
            if guid == "" or not existing[guid] then
                result[#result + 1] = feature
                existing[guid] = true
            end
        end
    end

    local characteristicBonuses = Advancement.CharacteristicBonuses(self)
    local modifiers = {}
    for _, characteristic in ipairs({ "agility", "mind", "strength" }) do
        local value = characteristicBonuses[characteristic] or 0
        if value > 0 then
            modifiers[#modifiers + 1] = CharacterModifier.new{
                behavior = "attribute",
                attribute = characteristic,
                value = value,
                name = "Crows Characteristic Advancement",
                source = "Crows Advancement",
                sourceguid = "crowdex-characteristic-advancement",
                guid = "crowdex-characteristic-" .. characteristic,
            }
        end
    end
    if #modifiers > 0 then
        result[#result + 1] = CharacterFeature.new{
            guid = "crowdex-characteristic-advancement",
            name = "Crows Characteristic Advancement",
            description = "Permanent characteristic increases purchased through Crows advancement.",
            source = "Crows Advancement",
            implementation = 3,
            modifiers = modifiers,
        }
    end
    return result
end

-- The expertises this creature has, and how many uses are left in each. Entries
-- are shaped for the sheet and side panel and sorted by name.

function creature:CrowdexExpertises()
    local result = {}
    local resourceTable = dmhub.GetTable("characterResources") or {}

    for key, quantity in pairs(self:GetResources() or {}) do
        local info = resourceTable[key]
        if info ~= nil then
            local category = Expertise.categoriesByGrouping[info:try_get("grouping", "")]
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
                    remaining = cond(Expertise.IsSuppressed(self), 0, math.max(0, max - used)),
                    description = info:try_get("description", ""),
                    suppressed = Expertise.IsSuppressed(self),
                }
            end
        end
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- Crows natural results are absolute: a natural 19-20 is tier 3 and a
-- natural 2-3 is doom/tier 1 regardless of edges, bonuses, or expertise.
function GameSystem.PowerRollNaturalTierOverride(result)
    local natural = tonumber(result and (result.naturalRoll or result.naturalroll)) or 0
    if natural >= 2 and natural <= 3 then return 1 end
    if natural >= 19 then return 3 end
    return nil
end

-- Becoming unconscious puts the creature physically prone. Keep Prone as its
-- own inflicted condition so waking removes Unconscious without standing the
-- creature up; they must still use the Stand Up maneuver afterward.
local CROWS_PRONE_CONDITION_ID = "da6867b1-01e3-4570-8d1b-1b94ea1ea343"
local CROWS_UNCONSCIOUS_CONDITION_ID = "bfe300f4-83f9-4303-9abb-951974025e88"
local g_baseInflictCondition = creature.InflictCondition
function creature:InflictCondition(conditionid, args)
    args = args or {}
    g_baseInflictCondition(self, conditionid, args)

    if conditionid == CROWS_UNCONSCIOUS_CONDITION_ID and not args.purge then
        local inflicted = self:try_get("inflictedConditions", {})
        if inflicted[CROWS_PRONE_CONDITION_ID] == nil then
            g_baseInflictCondition(self, CROWS_PRONE_CONDITION_ID, {
                silent = true,
                sourceDescription = "Prone while unconscious",
                casterInfo = args.casterInfo,
            })
        end
    end
end

-- Blessed adds damage equal to the characteristic actually used for the
-- attack. Resolve that value while DescribeModifyPowerRoll still has the
-- ability, then return a temporary copy carrying the exact numeric bonus. This
-- covers both ability rolls (which collect modifiers directly) and ordinary
-- tests (which use creature:GetModifiersForPowerRoll).
CharacterModifier.crowdexDamageFromRollCharacteristic = false
local g_baseDescribeModifyPowerRoll = CharacterModifier.DescribeModifyPowerRoll
function CharacterModifier:DescribeModifyPowerRoll(modContext, c, rollType, options)
    local result = g_baseDescribeModifyPowerRoll(self, modContext, c, rollType, options)
    if result == nil or rollType ~= "ability_power_roll"
            or not self:try_get("crowdexDamageFromRollCharacteristic", false)
            or options == nil or options.ability == nil then
        return result
    end

    local characteristic = nil
    pcall(function() characteristic = options.ability:GetRollCharacteristicValue(c) end)
    characteristic = tonumber(characteristic)
    if characteristic ~= nil then
        result.modifier = DeepCopy(self)
        result.modifier.damageModifier = tostring(characteristic)
    end
    return result
end

ActivatedAbility.crowdexExpertiseId = ""

local function IsExpertiseModifier(modifier)
    return modifier ~= nil
        and modifier:try_get("source", "") == "Expertise"
        and Expertise.IsExpertiseId(modifier:try_get("resourceCost"))
end

local function AfterRollCanImprove(options)
    local cast = options and options.symbols and options.symbols.cast or nil
    if cast == nil then return true end
    local natural = 0
    local tier = 0
    pcall(function()
        natural = tonumber(cast:try_get("naturalRoll", 0)) or 0
        tier = tonumber(cast:try_get("tier", 0)) or 0
    end)
    return not ((natural >= 2 and natural <= 3) or natural >= 19 or tier >= 3)
end

-- Filter the global expertise modifiers by Crows applicability and add the
-- generic roll-dialog coordination flags. Tests and resistance/opposed rolls
-- offer general expertises for Ref adjudication. Generated weapons and spells
-- carry an exact resource id; unannotated NPC/imported abilities offer owned
-- weapon/spellcasting expertises so the Ref can adjudicate them.
local g_baseAfterRollModifiers = creature.GetAfterRollModifiersForPowerRoll
function creature:GetAfterRollModifiersForPowerRoll(rollType, options)
    options = options or {}
    local candidates = g_baseAfterRollModifiers(self, rollType, options) or {}
    if rollType == "resistance_power_roll" or rollType == "opposed_power_roll" then
        local generalCandidates = g_baseAfterRollModifiers(self, "test_power_roll", options) or {}
        for _, entry in ipairs(generalCandidates) do
            if IsExpertiseModifier(entry.modifier) then candidates[#candidates + 1] = entry end
        end
    end

    local result = {}
    local exactId = options.ability and options.ability:try_get("crowdexExpertiseId", "") or ""
    for _, entry in ipairs(candidates) do
        if not IsExpertiseModifier(entry.modifier) then
            result[#result + 1] = entry
        elseif not Expertise.IsSuppressed(self) and AfterRollCanImprove(options) then
            local id = entry.modifier:try_get("resourceCost")
            local info = Expertise.FindById(id)
            local applicable = false
            if rollType == "test_power_roll" or rollType == "resistance_power_roll" or rollType == "opposed_power_roll" then
                applicable = info ~= nil and info.category == "General"
            elseif rollType == "ability_power_roll" then
                if exactId ~= "" and exactId ~= "none" then
                    applicable = id == exactId
                else
                    applicable = info ~= nil and (info.category == "Weapon" or info.category == "Spellcasting")
                end
            end

            if applicable and Expertise.Available(self, id) > 0 then
                local copy = DeepCopy(entry)
                copy.modifier.afterRollExclusiveGroup = "crowdex-expertise"
                copy.modifier.consumeOncePerRoll = true
                copy.modifier.rollType = rollType
                result[#result + 1] = copy
            end
        end
    end
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
        return Advancement.StaminaBonus(self)
    end
    return g_baseHitpoints(self) + Advancement.StaminaBonus(self)
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

    -- Permanent advancement and source-aware temporary grants project into
    -- the ordinary CharacterResource maxima. Background modifiers are added
    -- later by creature:GetResources, so the sources compose naturally.
    for id, quantity in pairs(Advancement.ExpertiseBonuses(creature)) do
        result[id] = (result[id] or 0) + quantity
    end
    for id, quantity in pairs(TemporaryExpertiseBonuses(creature)) do
        result[id] = (result[id] or 0) + quantity
    end
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
