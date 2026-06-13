local mod = dmhub.GetModLoading()

-- Crows-specific CharacterModifier behaviors.
--
-- Starting Equipment: a modifier carried by a background's Equipment feature
-- that formally lists the gear the crow starts with (tbl_Gear entries plus a
-- quantity). The builder's background card shows a "Claim Starting Equipment"
-- button (CrowdexBuilder.lua) which places the items into the crow's slot
-- inventory. Each modifier is claimable once per character, tracked by
-- modifier guid in props.crowdex_claimedEquipment, so re-selecting the same
-- background never grants the gear twice.

CharacterModifier.RegisterType('startingequipment', "Starting Equipment")

CharacterModifier.TypeInfo.startingequipment = {
    init = function(modifier)
        modifier.equipment = {}
    end,

    createEditor = function(modifier, element)
        local Refresh
        Refresh = function()
            local items = modifier:get_or_add("equipment", {})

            local gearTable = dmhub.GetTable("tbl_Gear") or {}
            local itemOptions = {
                {
                    id = "none",
                    text = "Choose Item...",
                },
            }
            for k,item in unhidden_pairs(gearTable) do
                itemOptions[#itemOptions+1] = {
                    id = k,
                    text = item.name,
                }
            end

            local children = {}

            for i,entry in ipairs(items) do
                local index = i
                children[#children+1] = gui.Panel{
                    classes = {'formPanel'},
                    gui.Dropdown{
                        styles = ThemeEngine.GetStyles(),
                        selfStyle = {
                            height = 30,
                            width = 250,
                            fontSize = 16,
                        },
                        hasSearch = true,
                        sort = true,
                        options = itemOptions,
                        idChosen = entry.itemid or "none",
                        change = function(dropdownElement)
                            if dropdownElement.idChosen ~= "none" then
                                entry.itemid = dropdownElement.idChosen
                            end
                            Refresh()
                        end,
                    },
                    gui.Input{
                        width = 50,
                        height = 22,
                        fontSize = 16,
                        halign = "left",
                        valign = "center",
                        lmargin = 8,
                        text = tostring(entry.quantity or 1),
                        change = function(inputElement)
                            local num = tonumber(inputElement.text)
                            if num == nil or math.floor(num) < 1 then
                                inputElement.text = tostring(entry.quantity or 1)
                                return
                            end
                            entry.quantity = math.floor(num)
                            inputElement.text = tostring(entry.quantity)
                        end,
                    },
                    gui.DeleteItemButton{
                        width = 16,
                        height = 16,
                        halign = "left",
                        valign = "center",
                        lmargin = 8,
                        click = function()
                            table.remove(items, index)
                            Refresh()
                        end,
                    },
                }
            end

            children[#children+1] = gui.Button{
                text = "Add Item",
                halign = "left",
                fontSize = 14,
                vmargin = 4,
                click = function()
                    items[#items+1] = {
                        itemid = "none",
                        quantity = 1,
                    }
                    Refresh()
                end,
            }

            element.children = children
        end

        Refresh()
    end,
}

-- ---------------------------------------------------------------------------
-- Claim API, used by the builder's background card.
-- ---------------------------------------------------------------------------

CrowdexStartingEquipment = {}

local function ClaimedMap(creature)
    return creature:try_get("crowdex_claimedEquipment", {}) or {}
end

-- Gear every crow starts with regardless of background (Characters Booklet,
-- "Equipment Cards": a bedroll, an empty coin purse, a knife, a rope, and six
-- rations). Granted alongside the background's starting equipment and tracked
-- under STANDARD_CLAIM_KEY in crowdex_claimedEquipment so it is never granted
-- twice on the same character.
local STANDARD_CLAIM_KEY = "crowdex:standard-equipment"
local STANDARD_EQUIPMENT = {
    { itemid = "2dccafc8-60da-4724-8a56-72fed0653ba2", quantity = 1 }, -- Bedroll
    { itemid = "30ca817d-d782-4f78-8359-4d38afe9d7a0", quantity = 1 }, -- Coin Purse
    { itemid = "10c54280-6bb9-42ea-b7ed-a191783a8cef", quantity = 1 }, -- Knife
    { itemid = "fa1092d3-9d38-41e1-ac68-c4a018908c00", quantity = 1 }, -- Rope
    { itemid = "223f5332-0bd0-420b-a6e9-6459d23b0b5a", quantity = 6 }, -- Ration
}

-- The standard equipment as a flat { item = tbl_Gear entry, quantity } list,
-- or empty if this creature has already claimed it. Entries whose item no
-- longer exists in tbl_Gear are skipped.
local function StandardUnclaimedItems(creature)
    if ClaimedMap(creature)[STANDARD_CLAIM_KEY] then
        return {}
    end
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local result = {}
    for _,e in ipairs(STANDARD_EQUIPMENT) do
        local item = gearTable[e.itemid]
        if item ~= nil then
            result[#result+1] = { item = item, quantity = e.quantity }
        end
    end
    return result
end

-- The creature's startingequipment modifiers that have not been claimed yet.
function CrowdexStartingEquipment.UnclaimedModifiers(creature)
    local claimed = ClaimedMap(creature)
    local result = {}
    for _,entry in ipairs(creature:GetActiveModifiers()) do
        local m = entry.mod
        if m.behavior == "startingequipment" and not claimed[m.guid] then
            result[#result+1] = m
        end
    end
    return result
end

-- Flat displayable list of what an unclaimed grant would give:
-- { item = tbl_Gear entry, quantity = number } in declaration order.
-- Entries whose item no longer exists in tbl_Gear are skipped.
function CrowdexStartingEquipment.UnclaimedItems(creature)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local result = {}
    for _,e in ipairs(StandardUnclaimedItems(creature)) do
        result[#result+1] = e
    end
    for _,m in ipairs(CrowdexStartingEquipment.UnclaimedModifiers(creature)) do
        for _,e in ipairs(m:try_get("equipment", {})) do
            local item = gearTable[e.itemid]
            if item ~= nil then
                result[#result+1] = {
                    item = item,
                    quantity = math.max(1, math.floor(tonumber(e.quantity) or 1)),
                }
            end
        end
    end
    return result
end

-- Places the full set of granted items into the crow's slot inventory in one
-- pass, so the backpack-vs-belt overflow decision can see all the gear at once
-- (CrowdexInventory.GrantStartingItems puts overflow on the belt, preferring
-- weapons). Falls back to the engine inventory if that API isn't available.
local function PlaceItems(creature, items)
    local inventoryApi = rawget(_G, "CrowdexInventory")
    if inventoryApi ~= nil and inventoryApi.GrantStartingItems ~= nil then
        inventoryApi.GrantStartingItems(creature, items)
        return
    end
    for _,entry in ipairs(items) do
        creature:GiveItem(entry.item.id, math.max(1, math.floor(tonumber(entry.quantity) or 1)))
    end
end

local function GrantModifiers(creature, mods)
    local gearTable = dmhub.GetTable("tbl_Gear") or {}
    local claimed = ClaimedMap(creature)
    local granted = false
    local items = {}

    -- Universal starting gear every crow gets, once per character.
    if not claimed[STANDARD_CLAIM_KEY] then
        for _,e in ipairs(STANDARD_EQUIPMENT) do
            local item = gearTable[e.itemid]
            if item ~= nil then
                items[#items+1] = { item = item, quantity = e.quantity }
            end
        end
        claimed[STANDARD_CLAIM_KEY] = true
        granted = true
    end

    for _,m in ipairs(mods) do
        for _,e in ipairs(m:try_get("equipment", {})) do
            local item = gearTable[e.itemid]
            if item ~= nil then
                items[#items+1] = { item = item, quantity = e.quantity }
            end
        end
        claimed[m.guid] = true
        granted = true
    end

    if not granted then
        return false
    end

    PlaceItems(creature, items)

    creature.crowdex_claimedEquipment = claimed
    return true
end

-- Grants every unclaimed startingequipment modifier on the creature. Call
-- inside the character sheet's mutation flow (ChangeHero / ModifyProperties).
-- Returns true if anything was claimed.
function CrowdexStartingEquipment.Claim(creature)
    return GrantModifiers(creature, CrowdexStartingEquipment.UnclaimedModifiers(creature))
end

-- The startingequipment modifiers declared on a background definition. Read
-- straight off the background's features (not GetActiveModifiers) so it is
-- valid in the same mutation that just assigned the background, before the
-- creature's modifier cache refreshes.
local function BackgroundEquipmentModifiers(bg)
    local result = {}
    if bg == nil then
        return result
    end
    for _,f in ipairs(bg:GetClassLevel().features) do
        for _,m in ipairs(f:try_get("modifiers", {})) do
            if m.behavior == "startingequipment" then
                result[#result+1] = m
            end
        end
    end
    return result
end

-- Called by the builder when a background is chosen: wipes the crow's slot
-- inventory and claim history, then grants the new background's starting
-- equipment fresh. Call inside the character sheet's mutation flow.
function CrowdexStartingEquipment.InitializeFromBackground(creature, bg)
    creature.crowdex_inventory = {}
    creature.crowdex_claimedEquipment = nil
    GrantModifiers(creature, BackgroundEquipmentModifiers(bg))
end
