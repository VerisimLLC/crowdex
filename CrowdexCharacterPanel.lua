local mod = dmhub.GetModLoading()

-- Overrides the Draw Steel character panel with a fresh Crows-system panel.
-- This file must be required AFTER Draw_Steel_Core_Rules_1b8f.MCDMCharacterPanel
-- so its assignments to CharacterPanel.* win.

-- ---------------------------------------------------------------------------
-- Field accessors. Crows-specific data (unassigned wounds, AD pools, etc.)
-- isn't a real data model yet; for now we read with try_get + sane defaults
-- so the panel renders for any character without requiring schema changes.
-- Once the Crows data model lands we can swap these for proper accessors.
-- ---------------------------------------------------------------------------

local function GetStamina(props)
    if props == nil then return 0 end
    local cur = props.CurrentHitpoints and props:CurrentHitpoints() or 0
    return cur or 0
end

local function GetStaminaMax(props)
    if props == nil then return 0 end
    local mx = props.MaxHitpoints and props:MaxHitpoints() or 0
    return mx or 0
end


-- Speed penalty: backpack slots holding both a wound and an item.
local function GetWoundSpeedPenalty(props)
    if props == nil then return 0 end
    if CrowdexInventoryUI ~= nil and CrowdexInventoryUI.CountWoundedItemSlots ~= nil then
        return CrowdexInventoryUI.CountWoundedItemSlots(props)
    end
    return 0
end

-- The real walking speed (creature:WalkingSpeed already subtracts the wound
-- penalty in CrowdexRules).
local function GetSpeed(props)
    if props == nil then return 5 end
    if props.WalkingSpeed ~= nil then
        return props:WalkingSpeed() or 0
    end
    return 5
end

local function GetArmorPieces(props)
    if props == nil then return {} end
    return props:try_get("crowdex_armorPieces", {})
end

-- Returns the character's active Crows conditions as a sorted list of
-- { id, name, stacks, kind, info } entries. Two sources feed this:
--   - "condition" entries: charConditions inflicted via InflictCondition
--     (Grabbed, Prone, Unconscious). These don't stack.
--   - "effect" entries: characterOngoingEffects flagged crowsCondition: true
--     (Blessed, Boned). These are stackable; stacks is the level.
local function GetActiveCrowsConditions(props)
    local result = {}
    if props == nil then return result end

    local conditionsTable = dmhub.GetTable(CharacterCondition.tableName) or {}
    for condid, entry in pairs(props:try_get("inflictedConditions", {})) do
        local info = conditionsTable[condid]
        if info ~= nil then
            result[#result + 1] = {
                id = condid,
                name = info.name,
                stacks = entry.stacks or 1,
                kind = "condition",
                info = info,
            }
        end
    end

    local effectsTable = dmhub.GetTable(CharacterOngoingEffect.tableName) or {}
    local effectStacks = {}
    for _, instance in ipairs(props:ActiveOngoingEffects()) do
        local info = effectsTable[instance.ongoingEffectid]
        if info ~= nil and info:try_get("crowsCondition", false) then
            effectStacks[instance.ongoingEffectid] = (effectStacks[instance.ongoingEffectid] or 0) + (instance.stacks or 1)
        end
    end
    for effectid, stacks in pairs(effectStacks) do
        local info = effectsTable[effectid]
        result[#result + 1] = {
            id = effectid,
            name = info.name,
            stacks = stacks,
            kind = "effect",
            info = info,
        }
    end

    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function GetInventory(props)
    if props == nil then return {} end
    return props:try_get("crowdex_inventory", {}) or {}
end

local function GetInventoryRow(props, rowKind)
    local inv = GetInventory(props)
    return inv[rowKind] or {}
end

local function GetWornSlots(props)
    if props == nil then return {} end
    return props:try_get("crowdex_wornSlots", {}) or {}
end

local function GetCharacteristic(props, attrid)
    if props == nil then return 0 end
    return props:GetAttribute(attrid):Modifier()
end

local function GetSkills(props)
    if props == nil then return {} end
    -- Skills come from the rules system (background proficiency modifiers
    -- etc.), not from a stored property. See creature:CrowdexSkills in
    -- CrowdexRules.lua.
    return props:CrowdexSkills()
end

-- The ordered list of magic-item worn slot keys used in section 6.
local WORN_SLOT_ORDER = {
    {key = "head",   short = "H", label = "Head"},
    {key = "neck",   short = "N", label = "Neck"},
    {key = "arms",   short = "A", label = "Arms"},
    {key = "waist",  short = "W", label = "Waist"},
    {key = "finger", short = "R", label = "Ring"},
    {key = "feet",   short = "F", label = "Feet"},
}

-- Card-category palette: 3px left-edge stripe color per design section 4.
local CATEGORY_COLOR = {
    weapon      = "#ff5050",
    armor       = "#5fa9d6",
    shield      = "#5fa9d6",
    consumable  = "#4caf50",
    light       = "#ffc107",
    tool        = "#9c27b0",
    spellbook   = "#5e35b1",
    magic       = "#ffd700",
    misc        = "#888",
}

local function ColorForCategory(category)
    return CATEGORY_COLOR[category or "misc"] or CATEGORY_COLOR.misc
end

-- ---------------------------------------------------------------------------
-- Reusable widgets
-- ---------------------------------------------------------------------------

--- Build the minimal name + avatar block.
--- @return Panel
local function CrowdexNameAndAvatar()
    return gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "left",
        valign = "top",
        pad = 4,

        gui.Panel{
            classes = {"crowdex-avatar"},
            width = 96,
            height = 96,
            halign = "center",
            valign = "top",
            bmargin = 4,
            cornerRadius = 6,
            borderWidth = 1,
            borderColor = "white",
            bgcolor = "clear",
            bgimage = "panels/square.png",
            refreshCharacter = function(element, tok)
                if tok == nil or not tok.valid then return end
                local portrait = tok.offTokenPortrait or tok.portrait
                if portrait == nil or portrait == "" then
                    element.bgimage = "panels/square.png"
                    element.selfStyle.bgcolor = "#ffffff22"
                    element.selfStyle.imageRect = nil
                    return
                end
                element.bgimage = portrait
                element.selfStyle.bgcolor = "white"
                if not portrait.hasSpineAnimation then
                    element.selfStyle.imageRect = tok:GetPortraitRectForAspect(1, portrait)
                end
            end,
        },

        gui.Label{
            classes = {"crowdex-name"},
            width = "auto",
            height = "auto",
            halign = "center",
            fontSize = 16,
            bold = true,
            color = "white",
            text = "",
            refreshCharacter = function(element, tok)
                if tok == nil or not tok.valid then
                    element.text = ""
                    return
                end
                local name = nil
                if tok.GetNameMaxLength ~= nil then
                    name = tok:GetNameMaxLength(64)
                end
                if name == nil or name == "" then
                    name = tok.name or ""
                end
                element.text = name
            end,
        },
    }
end

--- Speed column. Right-aligned vertical strip carrying just the speed pill
--- (Crowdex doesn't use stamina). Speed turns red when below base.
local function CrowdexStaminaRow()
    return gui.Panel{
        classes = {"crowdex-section"},
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "right",
        valign = "top",
        pad = 4,
        borderBox = true,

        -- Speed pill
        gui.Panel{
            width = 64,
            height = 52,
            flow = "vertical",
            halign = "right",
            valign = "top",
            borderWidth = 1,
            borderColor = "#666",
            cornerRadius = 6,
            bgcolor = "#222",
            bgimage = "panels/square.png",
            pad = 4,
            borderBox = true,

            gui.Label{
                width = "100%",
                height = "auto",
                halign = "center",
                fontSize = 10,
                bold = true,
                color = "#aaa",
                text = "SPEED",
            },
            gui.Label{
                width = "100%",
                height = "auto",
                halign = "center",
                fontSize = 24,
                bold = true,
                color = "white",
                text = "5",
                refreshCharacter = function(element, tok)
                    if tok == nil or tok.properties == nil then return end
                    local spd = GetSpeed(tok.properties)
                    local penalty = GetWoundSpeedPenalty(tok.properties)
                    element.text = tostring(spd)
                    if penalty > 0 then
                        element.selfStyle.color = "#ff5050"
                    else
                        element.selfStyle.color = "white"
                    end
                end,
                linger = function(element)
                    gui.Tooltip("Speed. Each backpack slot holding both a wound and an item reduces speed by 1.")(element)
                end,
            },
        },
    }
end

--- Per-piece Armor Defense list. Renders one row per armor piece; collapses
--- itself entirely when no armor is equipped (the section header still shows
--- a brief "No armor" line so the player knows where it would be).
-- Width of an Armor Defense row; matches the inventory slot rows.
local AD_ROW_WIDTH = 280

--- Damage input: amount, piercing toggle, Apply. Sits above the Armor
--- Defense section since that's what the damage hits first. Routes through
--- creature:TakeDamage -- the standard damage path, which CrowdexInventory
--- overrides with the Crows armor/stamina/wounds waterfall -- so this input,
--- abilities, and rule strings all resolve damage identically.
local function CrowdexDamageRow()
    local amountInput
    local piercingCheck

    local function Apply(element)
        local sectionData = element:FindParentWithClass("crowdex-section").data
        local tok = sectionData.token
        local n = math.floor(tonumber(amountInput.text) or 0)
        if n <= 0 or tok == nil or not tok.valid or tok.properties == nil then
            amountInput.text = ""
            return
        end
        local piercing = piercingCheck.value
        tok:ModifyProperties{
            description = "Take damage",
            execute = function()
                tok.properties:TakeDamage(n, "Damage", { piercing = piercing })
            end,
        }
        amountInput.text = ""
    end

    amountInput = gui.Input{
        width = 140,
        height = 24,
        fontSize = 14,
        textAlignment = "center",
        placeholderText = "Apply Damage...",
        characterLimit = 3,
        valign = "center",
        bgcolor = "#882222",


        change = function(element)
            Apply(element)
        end,
    }

    piercingCheck = gui.Check{
        text = "Piercing",
        fontSize = 12,
        valign = "center",
        lmargin = 10,
        value = false,
    }

    return gui.Panel{
        classes = {"crowdex-section"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 8,

        data = {
            token = nil,
        },

        refreshCharacter = function(element, tok)
            element.data.token = tok
        end,

        gui.Label{
            width = "auto",
            height = "auto",
            fontSize = 11,
            bold = true,
            color = "#aaa",
            text = "DAMAGE",
            bmargin = 4,
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "center",

            amountInput,
            piercingCheck,

            gui.Button{
                text = "Apply",
                fontSize = 12,
                width = 60,
                height = 24,
                valign = "center",
                lmargin = 12,
                click = function(element)
                    Apply(element)
                end,
            },
        },
    }
end

--- One Armor Defense source rendered like an inventory slot row, but taller,
--- with an AD bar. Rows drag onto each other to reorder damage priority:
--- the TOP row is the armor that absorbs (and is destroyed) first.
local function CrowdexArmorPieceRow(token, pieces, position)
    local piece = pieces[position]
    local cur = piece.ad or 0
    local mx = piece.adMax or 0
    local broken = cur <= 0
    -- A parry weapon toggled off: still listed (so you can re-enable it) but
    -- greyed and not absorbing.
    local inactive = piece.active == false
    local pct = 0
    if mx > 0 then
        pct = math.max(0, math.min(1, cur / mx))
    end

    local barColor = "#caa45c"
    if inactive then
        barColor = "#3a3a3a"
    elseif broken then
        barColor = "#552222"
    elseif pct <= 0.34 then
        barColor = "#aa3333"
    end

    -- A small toggle for parry weapons: tap to enable/disable using this
    -- weapon to parry. Defaults on; off sets slot.parryOff.
    local parryToggle
    if piece.isParryWeapon then
        parryToggle = gui.Label{
            width = 46,
            height = 16,
            fontSize = 10,
            bold = true,
            textAlignment = "center",
            valign = "center",
            rmargin = 4,
            cornerRadius = 3,
            borderWidth = 1,
            bgimage = "panels/square.png",
            bgcolor = cond(inactive, "#2a2a2a", "#3a4a2a"),
            borderColor = cond(inactive, "#555555", "#8fbf5f"),
            color = cond(inactive, "#888888", "#cfe8a0"),
            hoverCursor = "hand",
            text = "Parry",
            linger = function(element)
                gui.Tooltip(cond(inactive,
                    "Parry off: this weapon is not used to absorb damage. Tap to enable.",
                    "Parry on: this weapon absorbs damage like a shield. Tap to disable."))(element)
            end,
            press = function(element)
                if token == nil or not token.valid or token.properties == nil then return end
                token:ModifyProperties{
                    description = "Toggle parry",
                    execute = function()
                        local slot = CrowdexInventoryUI.GetSlot(token.properties, piece.kind, piece.index)
                        if slot == nil then return end
                        if slot.parryOff == true then
                            slot.parryOff = nil
                        else
                            slot.parryOff = true
                        end
                        CrowdexInventoryUI.SetSlot(token.properties, piece.kind, piece.index, slot)
                    end,
                }
            end,
        }
    else
        -- Zero-size placeholder for non-parry pieces (avoids a nil hole in
        -- the children list, which would truncate the row).
        parryToggle = gui.Panel{ width = 0, height = 0, interactable = false }
    end

    -- Reorders the underlying slot entries' adPriority so that the dragged
    -- piece lands at the target position; everything renumbers 1..n.
    local function ReorderTo(targetPosition)
        if token == nil or not token.valid or token.properties == nil then return end
        token:ModifyProperties{
            description = "Reorder armor",
            execute = function()
                local order = {}
                for i, p in ipairs(pieces) do
                    if i ~= position then
                        order[#order + 1] = p
                    end
                end
                table.insert(order, math.max(1, math.min(targetPosition, #order + 1)), piece)

                for i, p in ipairs(order) do
                    local slot = CrowdexInventoryUI.GetSlot(token.properties, p.kind, p.index)
                    if slot ~= nil then
                        slot.adPriority = i
                        CrowdexInventoryUI.SetSlot(token.properties, p.kind, p.index, slot)
                    end
                end
            end,
        }
    end

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
            adReorderPosition = position,
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

    return gui.Panel{
        classes = {"crowsInvSlot"},
        bgimage = true,
        width = AD_ROW_WIDTH,
        height = 40,
        flow = "vertical",
        borderBox = true,
        hpad = 6,
        vpad = 4,
        vmargin = 2,
        hoverCursor = "hand",
        draggable = true,

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

        canDragOnto = function(element, target)
            return target.data ~= nil and target.data.adReorderPosition ~= nil
                and target.data.adReorderPosition ~= position
        end,

        drag = function(element, target)
            if target == nil then return end
            local targetPosition = target.data.adReorderPosition
            if targetPosition == nil then return end
            ReorderTo(targetPosition)
        end,

        linger = function(element)
            gui.Tooltip(string.format(
                "%s: AD %d / %d.%s\nDamage is absorbed by the top-most armor first. Drag to reorder.",
                piece.name, cur, mx, cond(broken, " Broken: cannot stop damage until repaired.", "")))(element)
        end,

        -- top line: icon, name, cur/max
        gui.Panel{
            width = "100%",
            height = 16,
            flow = "horizontal",
            valign = "center",

            gui.Panel{
                width = 16,
                height = 16,
                valign = "center",
                rmargin = 6,
                bgimage = piece.icon or "panels/square.png",
                bgcolor = cond(broken or inactive, "#886666", "white"),
                interactable = false,
            },
            gui.Label{
                -- Narrower when a Parry toggle (46+4) shares the line.
                width = AD_ROW_WIDTH - 12 - 22 - 64 - cond(piece.isParryWeapon, 50, 0),
                height = "auto",
                fontSize = 13,
                color = cond(inactive, "#888888", cond(broken, "#ff5050", "white")),
                valign = "center",
                interactable = false,
                text = cond(broken, string.format("%s (broken)", piece.name), piece.name),
            },
            parryToggle,
            -- Current AD: editable. Type a number to set the AD left on
            -- this item; clamped to [0, max].
            gui.Label{
                width = 28,
                height = 16,
                fontSize = 13,
                bold = true,
                color = cond(broken, "#ff5050", "#e8d59a"),
                valign = "center",
                textAlignment = "right",
                editable = true,
                characterLimit = 3,
                text = tostring(cur),

                change = function(element)
                    if token == nil or not token.valid or token.properties == nil then return end
                    local n = tonumber(element.text)
                    if n == nil then
                        element.text = tostring(cur)
                        return
                    end
                    n = math.max(0, math.min(math.floor(n), mx))
                    token:ModifyProperties{
                        description = "Set armor AD",
                        execute = function()
                            local slot = CrowdexInventoryUI.GetSlot(token.properties, piece.kind, piece.index)
                            if slot == nil then return end
                            slot.ad = n
                            CrowdexInventoryUI.SetSlot(token.properties, piece.kind, piece.index, slot)
                        end,
                    }
                end,
            },
            gui.Label{
                width = 36,
                height = "auto",
                fontSize = 13,
                bold = true,
                color = cond(broken, "#ff5050", "#e8d59a"),
                valign = "center",
                textAlignment = "left",
                interactable = false,
                text = string.format(" / %d", mx),
            },
        },

        -- AD bar
        gui.Panel{
            width = "100%",
            height = 8,
            tmargin = 4,
            bgimage = "panels/square.png",
            bgcolor = "#101018",
            borderWidth = 1,
            borderColor = "#3a3a4a",
            interactable = false,

            gui.Panel{
                width = string.format("%.0f%%", pct * 100),
                height = "100%",
                halign = "left",
                bgimage = "panels/square.png",
                bgcolor = barColor,
                interactable = false,
            },
        },

        dropTarget,
    }
end

--- The Stamina bar, rendered in the same visual language as the AD rows and
--- shown directly below them: armor absorbs from the top of the list first,
--- and Stamina is what's left when the armor is gone. The current value is
--- editable.
local function CrowdexStaminaBarRow(token, props)
    local mx = props:MaxHitpoints() or 0
    local cur = math.max(0, math.min(props:CurrentHitpoints() or 0, mx))
    local pct = 0
    if mx > 0 then
        pct = math.max(0, math.min(1, cur / mx))
    end

    local barColor = "#5fae5f"
    if cur <= 0 then
        barColor = "#552222"
    elseif pct <= 0.34 then
        barColor = "#aa3333"
    end

    return gui.Panel{
        classes = {"crowsInvSlot"},
        bgimage = true,
        width = AD_ROW_WIDTH,
        height = 40,
        flow = "vertical",
        borderBox = true,
        hpad = 6,
        vpad = 4,
        vmargin = 2,
        tmargin = 6,

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
        },

        linger = function(element)
            gui.Tooltip(string.format(
                "Stamina %d / %d. When your armor's AD is gone, damage comes off Stamina; at 0 Stamina further damage becomes wounds.", cur, mx))(element)
        end,

        gui.Panel{
            width = "100%",
            height = 16,
            flow = "horizontal",
            valign = "center",

            gui.Label{
                width = AD_ROW_WIDTH - 12 - 64,
                height = "auto",
                fontSize = 13,
                bold = true,
                color = "white",
                valign = "center",
                interactable = false,
                text = "Stamina",
            },
            -- Current stamina: editable, clamped to [0, max].
            gui.Label{
                width = 28,
                height = 16,
                fontSize = 13,
                bold = true,
                color = cond(cur <= 0, "#ff5050", "#5fae5f"),
                valign = "center",
                textAlignment = "right",
                editable = true,
                characterLimit = 3,
                text = tostring(cur),

                change = function(element)
                    if token == nil or not token.valid or token.properties == nil then return end
                    local n = tonumber(element.text)
                    if n == nil then
                        element.text = tostring(cur)
                        return
                    end
                    n = math.max(0, math.min(math.floor(n), mx))
                    token:ModifyProperties{
                        description = "Set Stamina",
                        execute = function()
                            token.properties.damage_taken = mx - n
                        end,
                    }
                end,
            },
            gui.Label{
                width = 36,
                height = "auto",
                fontSize = 13,
                bold = true,
                color = "#5fae5f",
                valign = "center",
                textAlignment = "left",
                interactable = false,
                text = string.format(" / %d", mx),
            },
        },

        -- Stamina bar
        gui.Panel{
            width = "100%",
            height = 8,
            tmargin = 4,
            bgimage = "panels/square.png",
            bgcolor = "#101018",
            borderWidth = 1,
            borderColor = "#3a3a4a",
            interactable = false,

            gui.Panel{
                width = string.format("%.0f%%", pct * 100),
                height = "100%",
                halign = "left",
                bgimage = "panels/square.png",
                bgcolor = barColor,
                interactable = false,
            },
        },
    }
end

local function CrowdexArmorRow()
    return gui.Panel{
        classes = {"crowdex-section"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 8,

        gui.Label{
            width = "auto",
            height = "auto",
            fontSize = 11,
            bold = true,
            color = "#aaa",
            text = "ARMOR DEFENSE",
            bmargin = 4,
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",

            refreshCharacter = function(element, tok)
                if tok == nil or tok.properties == nil then return end
                -- AD sources derive from the inventory: the worn suit of
                -- armor plus shields held in hand slots, in damage-priority
                -- order (top-most absorbs first). Stamina renders below
                -- them: it's what damage hits once the armor is gone.
                local pieces = CrowdexInventoryUI.ArmorPieces(tok.properties)
                local rows = {}
                for i = 1, #pieces do
                    rows[#rows + 1] = CrowdexArmorPieceRow(tok, pieces, i)
                end
                if #pieces == 0 then
                    rows[#rows + 1] = gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 11,
                        color = "#888",
                        italics = true,
                        text = "No armor worn. Right-click a suit of armor in your backpack to wear it.",
                        textWrap = true,
                    }
                elseif #pieces > 1 then
                    rows[#rows + 1] = gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 10,
                        italics = true,
                        color = "#888888",
                        tmargin = 2,
                        text = "Top armor takes damage first. Drag to reorder.",
                    }
                end

                rows[#rows + 1] = CrowdexStaminaBarRow(tok, tok.properties)

                element.children = rows
            end,
        },
    }
end

--- Strip of condition chips, driven by the game's condition content tables.
--- Grabbed/Prone/Unconscious live in the charConditions table and are
--- inflicted via creature:InflictCondition. Blessed/Boned live in
--- characterOngoingEffects (flagged crowsCondition: true) and are applied
--- via creature:ApplyOngoingEffect, which accumulates stacks (their level).
--- Clicking a chip removes the condition (or one level of a stacked one).
local function CrowdexConditionsRow(token)
    -- The sidebar is built once and re-pointed at different crows via the
    -- setToken/refreshCharacter events (see SingleCharacterDisplaySidePanel),
    -- so the `token` captured at construction goes stale. Track the live token
    -- here, updated each refresh, and route all mutations through it -- the add
    -- menu and the remove handler are otherwise served the wrong crow.
    local currentToken = token

    local function buildAddMenu()
        local entries = {}
        if currentToken == nil or currentToken.properties == nil then return entries end

        local active = {}
        for _, cond in ipairs(GetActiveCrowsConditions(currentToken.properties)) do
            active[cond.id] = cond
        end

        -- candidates: all conditions in the charConditions table...
        local candidates = {}
        for condid, info in unhidden_pairs(dmhub.GetTable(CharacterCondition.tableName) or {}) do
            candidates[#candidates + 1] = {id = condid, name = info.name, kind = "condition"}
        end
        -- ...plus ongoing effects flagged as Crows conditions (stackable).
        for effectid, info in unhidden_pairs(dmhub.GetTable(CharacterOngoingEffect.tableName) or {}) do
            if info:try_get("crowsCondition", false) then
                candidates[#candidates + 1] = {id = effectid, name = info.name, kind = "effect", stackable = info:try_get("stackable", false)}
            end
        end
        table.sort(candidates, function(a, b) return a.name < b.name end)

        for _, candidate in ipairs(candidates) do
            local already = active[candidate.id] ~= nil
            if not already or (candidate.kind == "effect" and candidate.stackable) then
                local actionLabel = candidate.name
                if already then
                    actionLabel = "Increase " .. candidate.name
                end
                local entry = candidate
                entries[#entries + 1] = {
                    text = actionLabel,
                    click = function()
                        currentToken:ModifyProperties{
                            description = "Add condition " .. entry.name,
                            execute = function()
                                if entry.kind == "condition" then
                                    currentToken.properties:InflictCondition(entry.id, {})

                                    -- Conditions that carry other conditions (e.g.
                                    -- Unconscious makes you Prone) declare them with
                                    -- bestowcondition modifiers. The engine only
                                    -- honors those for ongoing-effect-delivered
                                    -- conditions, so inflict them explicitly here.
                                    -- They are intentionally NOT removed when the
                                    -- main condition ends: waking up doesn't stand
                                    -- you up.
                                    local conditionsTable = dmhub.GetTable(CharacterCondition.tableName) or {}
                                    local info = conditionsTable[entry.id]
                                    for _, m in ipairs((info and info.modifiers) or {}) do
                                        if m.behavior == "bestowcondition" and m:try_get("conditionid", "none") ~= "none" then
                                            currentToken.properties:InflictCondition(m.conditionid, {})
                                        end
                                    end
                                else
                                    currentToken.properties:ApplyOngoingEffect(entry.id)
                                end
                            end,
                        }
                    end,
                }
            end
        end
        if #entries == 0 then
            entries[#entries + 1] = {
                text = "(no conditions to add)",
                click = function() end,
            }
        end
        return entries
    end

    return gui.Panel{
        classes = {"crowdex-section"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 8,
        borderBox = true,

        gui.Label{
            width = "auto",
            height = "auto",
            fontSize = 11,
            bold = true,
            color = "#aaa",
            text = "CONDITIONS",
            bmargin = 4,
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            wrap = true,

            refreshCharacter = function(element, tok)
                if tok == nil or tok.properties == nil then return end
                currentToken = tok
                local children = {}
                for _, cond in ipairs(GetActiveCrowsConditions(tok.properties)) do
                    local displayLabel = cond.name
                    if cond.kind == "effect" and (cond.stacks or 1) > 1 then
                        displayLabel = string.format("%s x%d", cond.name, cond.stacks)
                    end
                    local condid = cond.id
                    local kind = cond.kind
                    local rulesText = cond.info:try_get("description", "")
                    children[#children + 1] = gui.Panel{
                        width = "auto",
                        height = "auto",
                        flow = "horizontal",
                        valign = "center",
                        pad = 4,
                        hpad = 8,
                        borderBox = true,
                        cornerRadius = 10,
                        borderWidth = 1,
                        borderColor = "#caa45c",
                        bgcolor = "#33271a",
                        bgimage = "panels/square.png",
                        rmargin = 4,
                        bmargin = 4,
                        hoverCursor = "hand",

                        press = function(element)
                            currentToken:ModifyProperties{
                                description = "Remove condition " .. displayLabel,
                                execute = function()
                                    if kind == "condition" then
                                        currentToken.properties:InflictCondition(condid, {purge = true})
                                    else
                                        --remove one stack (level) at a time
                                        currentToken.properties:RemoveOngoingEffect(condid, 1)
                                    end
                                end,
                            }
                        end,

                        linger = function(element)
                            local removeText
                            if kind == "effect" then
                                removeText = "Click to remove one level of " .. cond.name .. "."
                            else
                                removeText = "Click to remove " .. cond.name .. "."
                            end
                            gui.Tooltip(string.format("<b>%s</b>: %s\n\n%s", displayLabel, rulesText, removeText))(element)
                        end,

                        gui.Label{
                            width = "auto",
                            height = "auto",
                            fontSize = 12,
                            color = "#ffe6b8",
                            text = displayLabel,
                        },
                    }
                end

                -- Add button always present at end.
                children[#children + 1] = gui.Panel{
                    width = "auto",
                    height = "auto",
                    flow = "horizontal",
                    valign = "center",
                    pad = 4,
                    hpad = 8,
                    borderBox = true,
                    cornerRadius = 10,
                    borderWidth = 1,
                    borderColor = "#666",
                    bgcolor = "#222",
                    bgimage = "panels/square.png",
                    rmargin = 4,
                    bmargin = 4,
                    hoverCursor = "hand",

                    press = function(element)
                        element.popup = gui.ContextMenu{
                            entries = buildAddMenu(),
                            click = function()
                                --any entry click closes the menu.
                                element.popup = nil
                            end,
                        }
                    end,

                    gui.Label{
                        width = "auto",
                        height = "auto",
                        fontSize = 12,
                        color = "#aaa",
                        text = "+ Add",
                    },
                }

                element.children = children
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Inventory cells and rows.
-- ---------------------------------------------------------------------------

local CELL_W = 60
local CELL_H = 80

-- Environment for the shared inventory slot rows (CrowdexInventoryUI,
-- defined in CrowdexInventory.lua). The same rows and drag-and-drop rules
-- as the character sheet's Inventory tab. Rows learn their token from the
-- refreshCharacter event; mutations go through token:ModifyProperties since
-- the panel lives outside the character sheet's edit lifecycle.
local g_panelSlotEnv = {
    -- The panel writes through token:ModifyProperties, which uploads to the
    -- cloud; the rows only re-render when the network echo arrives via
    -- monitorGame. That round-trip is why a dropped item/wound briefly snaps
    -- back. optimistic + refreshNow let the wound drag paint the new state
    -- locally (faded) right away; the echo then clears the faded flag.
    optimistic = true,
    getToken = function(row)
        local tok = row.data.panelToken
        if tok ~= nil and tok.valid then
            return tok
        end
        return nil
    end,
    change = function(row, fn)
        local tok = row.data.panelToken
        if tok == nil or not tok.valid or tok.properties == nil then return end
        tok:ModifyProperties{
            description = "Inventory",
            execute = function()
                fn(tok.properties, tok)
            end,
        }
    end,
    -- Re-render the whole sidebar from the now-updated local properties
    -- without waiting for the network echo.
    refreshNow = function(row)
        local sidebar = row:FindParentWithClass("crowdex-sidebar")
        local tok = row.data.panelToken
        if sidebar ~= nil and tok ~= nil and tok.valid then
            sidebar:FireEventTree("refreshCharacter", tok)
        end
    end,
}

--- A labelled inventory section. `title` is the header; `rowSpec` is a list of
--- (rowKind, slotIndex) tuples that become the cells. For multi-row sections
--- (backpack), call multiple times.
local function CrowdexInventorySectionHeader(title)
    return gui.Label{
        width = "auto",
        height = "auto",
        fontSize = 11,
        bold = true,
        color = "#aaa",
        text = title,
        bmargin = 4,
    }
end

--- Worn (magic) section. Default collapsed = dot bar. Expanded = 6 cells.
--- A red `!` badge on the header shows when any slot has more than one item.
local function CrowdexWornRow(token)
    local expanded = false

    -- The two display modes live as siblings; we toggle `collapsed` rather
    -- than swapping children (see UI_BEST_PRACTICES "Orphaned Panels").

    local collapsedBar
    collapsedBar = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "horizontal",
        valign = "center",

        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            local worn = GetWornSlots(tok.properties)
            local children = {}
            for _, def in ipairs(WORN_SLOT_ORDER) do
                local v = worn[def.key]
                local filled = false
                if v ~= nil then
                    if type(v) == "table" and #v == 0 then
                        -- Single card stored as a table.
                        filled = v.name ~= nil
                    elseif type(v) == "table" and #v > 0 then
                        filled = true
                    elseif type(v) ~= "table" then
                        filled = true
                    end
                end
                children[#children + 1] = gui.Label{
                    width = "auto",
                    height = "auto",
                    fontSize = 11,
                    color = filled and "#ffd700" or "#666",
                    rmargin = 4,
                    text = string.format("%s%s", def.short, filled and "(*)" or "( )"),
                }
            end
            element.children = children
        end,
    }

    local expandedCells
    expandedCells = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        classes = {"collapsed"},
        tmargin = 4,

        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            local worn = GetWornSlots(tok.properties)
            local cells = {}
            for _, def in ipairs(WORN_SLOT_ORDER) do
                local v = worn[def.key]
                local card = nil
                local overstuffed = false
                if type(v) == "table" and #v > 1 then
                    card = v[1]
                    overstuffed = true
                elseif type(v) == "table" and #v == 1 then
                    card = v[1]
                elseif type(v) == "table" and v.name ~= nil then
                    card = v
                end

                cells[#cells + 1] = gui.Panel{
                    width = CELL_W,
                    height = CELL_H,
                    flow = "none",
                    bgimage = "panels/square.png",
                    bgcolor = "#181818",
                    borderWidth = 1,
                    borderColor = card and "#caa45c" or "#444",
                    cornerRadius = 3,
                    hmargin = 2,
                    vmargin = 2,

                    gui.Panel{
                        width = "100%",
                        height = "auto",
                        flow = "vertical",
                        halign = "center",
                        valign = "top",
                        pad = 4,
                        borderBox = true,

                        gui.Label{
                            width = "100%",
                            height = "auto",
                            halign = "center",
                            textAlignment = "center",
                            fontSize = 10,
                            color = card and "white" or "#666",
                            text = card and (card.name or def.label) or def.label,
                            textWrap = true,
                        },
                    },

                    overstuffed and gui.Label{
                        floating = true,
                        x = -3,
                        y = 3,
                        width = "auto",
                        height = "auto",
                        halign = "right",
                        valign = "top",
                        fontSize = 12,
                        bold = true,
                        color = "#ff4040",
                        text = "!",
                    } or nil,
                }
            end
            element.children = {
                gui.Panel{
                    width = "auto",
                    height = "auto",
                    flow = "horizontal",
                    halign = "left",
                    children = cells,
                },
            }
        end,
    }

    local header
    header = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        valign = "center",
        bmargin = 4,

        gui.Label{
            width = "auto-grow",
            height = "auto",
            halign = "left",
            fontSize = 11,
            bold = true,
            color = "#aaa",
            text = "WORN (magic)",
        },

        gui.Label{
            width = "auto",
            height = "auto",
            halign = "right",
            valign = "center",
            fontSize = 11,
            bold = true,
            color = "#ff4040",
            text = "",
            rmargin = 6,
            refreshCharacter = function(element, tok)
                if tok == nil or tok.properties == nil then
                    element.text = ""
                    return
                end
                local worn = GetWornSlots(tok.properties)
                local warn = false
                for _, def in ipairs(WORN_SLOT_ORDER) do
                    local v = worn[def.key]
                    if type(v) == "table" and #v > 1 then
                        warn = true
                        break
                    end
                end
                element.text = warn and "!" or ""
                if warn then
                    gui.Tooltip("One or more slots is overstuffed; will roll 1d6 wounds at end of DT.")(element)
                end
            end,
        },

        gui.Label{
            width = "auto",
            height = "auto",
            halign = "right",
            fontSize = 11,
            color = "#aaa",
            text = "[v]",
            hoverCursor = "hand",
            press = function(element)
                expanded = not expanded
                element.text = expanded and "[^]" or "[v]"
                collapsedBar:SetClass("collapsed", expanded)
                expandedCells:SetClass("collapsed", not expanded)
            end,
        },
    }

    return gui.Panel{
        classes = {"crowdex-section"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 8,
        borderBox = true,

        header,
        collapsedBar,
        expandedCells,
    }
end

--- Characteristic block (one per registered creature attribute).
--- Click rolls 2d10 + char.
local function CrowdexCharacteristicBox(token, key, label)
    -- The sidebar slot is reused across crows via setToken (see
    -- SingleCharacterDisplaySidePanel), so the captured `token` goes stale.
    -- Track the live token from the value label's refresh and roll through it.
    local currentToken = token
    return gui.Panel{
        width = 64,
        height = 64,
        flow = "vertical",
        halign = "center",
        valign = "center",
        borderWidth = 1,
        borderColor = "#666",
        cornerRadius = 4,
        bgcolor = "#222",
        bgimage = "panels/square.png",
        pad = 4,
        borderBox = true,
        hmargin = 4,
        hoverCursor = "hand",

        press = function(element)
            if currentToken == nil or currentToken.properties == nil then return end
            currentToken.properties:ShowAttributeRollDialog(key)
        end,

        rightClick = function(element)
            if currentToken == nil or currentToken.properties == nil then return end
            currentToken.properties:RollAttributeCheck(key)
        end,

        linger = function(element)
            if currentToken == nil or currentToken.properties == nil then return end
            local val = GetCharacteristic(currentToken.properties, key)
            local sign = (val >= 0) and "+" or ""
            gui.Tooltip(string.format("%s test: 2d10 %s%d. Click to roll.", label, sign, val))(element)
        end,

        gui.Label{
            width = "100%",
            height = "auto",
            halign = "center",
            textAlignment = "center",
            fontSize = 22,
            bold = true,
            color = "white",
            text = "0",
            refreshCharacter = function(element, tok)
                if tok == nil or tok.properties == nil then return end
                currentToken = tok
                local val = GetCharacteristic(tok.properties, key)
                local sign = (val >= 0) and "+" or ""
                element.text = string.format("%s%d", sign, val)
            end,
        },
        gui.Label{
            width = "100%",
            height = "auto",
            halign = "center",
            textAlignment = "center",
            fontSize = 10,
            bold = true,
            color = "#aaa",
            text = label,
        },
    }
end

local function CrowdexCharacteristicsRow(token)
    local boxes = {}
    for _, attrid in ipairs(creature.attributeIds) do
        local info = creature.attributesInfo[attrid]
        boxes[#boxes+1] = CrowdexCharacteristicBox(token, attrid, info.short or string.upper(info.description))
    end

    return gui.Panel{
        classes = {"crowdex-section"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 8,
        borderBox = true,

        gui.Label{
            width = "auto",
            height = "auto",
            fontSize = 11,
            bold = true,
            color = "#aaa",
            text = "CHARACTERISTICS",
            bmargin = 6,
        },

        gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            halign = "center",
            children = boxes,
        },
    }
end

--- Skills section. Collapsed by default. When expanded, shows a filter
--- dropdown above a flat scrollable list of "Name +N" rows.
local function CrowdexSkillsSection(token)
    local expanded = false
    local currentFilter = "all"
    -- Slot reused across crows via setToken; track the live token so the
    -- filter dropdown re-renders the right crow's skills.
    local currentToken = token

    local function skillMatchesFilter(skill, filt)
        if filt == "all" then return true end
        if filt == "combat" then
            return (skill.subcategory or ""):lower() == "combat"
        end
        if filt == "lore" then
            return (skill.subcategory or ""):lower() == "lore"
        end
        if filt == "spellcasting" then
            return (skill.category or ""):lower() == "spellcasting"
        end
        if filt == "weapon" then
            return (skill.category or ""):lower() == "weapon"
        end
        return true
    end

    local skillsListPanel
    skillsListPanel = gui.Panel{
        width = "100%",
        height = "auto",
        maxHeight = 200,
        flow = "vertical",
        vscroll = true,

        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            currentToken = tok
            local skills = GetSkills(tok.properties)
            local children = {}
            for _, skill in ipairs(skills) do
                if skillMatchesFilter(skill, currentFilter) then
                    local bonus = tonumber(skill.bonus) or 0
                    local sign = (bonus >= 0) and "+" or ""
                    children[#children + 1] = gui.Panel{
                        width = "100%",
                        height = "auto",
                        flow = "horizontal",
                        valign = "center",
                        vmargin = 1,

                        gui.Label{
                            width = "auto-grow",
                            height = "auto",
                            halign = "left",
                            fontSize = 12,
                            color = "white",
                            text = skill.name or "(unnamed)",
                        },
                        gui.Label{
                            width = "auto",
                            height = "auto",
                            halign = "right",
                            fontSize = 12,
                            bold = true,
                            color = (bonus > 0) and "#9bd97a" or "#ccc",
                            text = string.format("%s%d", sign, bonus),
                        },
                    }
                end
            end
            if #children == 0 then
                children[#children + 1] = gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 11,
                    italics = true,
                    color = "#666",
                    text = "(no skills match filter)",
                }
            end
            element.children = children
        end,
    }

    local filterDropdown
    filterDropdown = gui.Dropdown{
        width = 140,
        height = 22,
        halign = "right",
        options = {
            {id = "all",          text = "All"},
            {id = "combat",       text = "Combat"},
            {id = "lore",         text = "Lore"},
            {id = "spellcasting", text = "Spellcasting"},
            {id = "weapon",       text = "Weapon"},
        },
        idChosen = "all",
        change = function(element)
            currentFilter = element.idChosen or "all"
            if currentToken ~= nil and currentToken.valid then
                skillsListPanel:FireEventTree("refreshCharacter", currentToken)
            end
        end,
    }

    local contentPanel
    contentPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        classes = {"collapsed"},
        tmargin = 4,

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "center",
            bmargin = 4,
            gui.Label{
                width = "auto-grow",
                height = "auto",
                halign = "left",
                fontSize = 11,
                color = "#aaa",
                text = "Filter:",
            },
            filterDropdown,
        },

        skillsListPanel,
    }

    local headerCount
    headerCount = gui.Label{
        width = "auto",
        height = "auto",
        halign = "left",
        fontSize = 11,
        bold = true,
        color = "#aaa",
        text = "SKILLS",
        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            local skills = GetSkills(tok.properties)
            element.text = string.format("SKILLS (%d)", #skills)
        end,
    }

    local header
    header = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        valign = "center",
        hoverCursor = "hand",

        press = function(element)
            expanded = not expanded
            contentPanel:SetClass("collapsed", not expanded)
        end,

        headerCount,

        gui.Label{
            width = "auto",
            height = "auto",
            halign = "right",
            fontSize = 11,
            color = "#aaa",
            text = "[v]",
            refreshCharacter = function(element)
                element.text = expanded and "[^]" or "[v]"
            end,
        },
    }

    return gui.Panel{
        classes = {"crowdex-section"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        pad = 8,
        borderBox = true,

        header,
        contentPanel,
    }
end

--- A thin section separator.
local function CrowdexSeparator()
    return gui.Panel{
        width = "92%",
        height = 1,
        halign = "center",
        bgcolor = "#444",
        bgimage = "panels/square.png",
        vmargin = 2,
    }
end

-- ---------------------------------------------------------------------------
-- Operational panel assembly.
-- ---------------------------------------------------------------------------

local function CrowdexOperationalPanel(token)
    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        halign = "center",
        valign = "top",
        tmargin = 16,

        -- Top row: avatar/name on the left, stat pills on the right.
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "top",

            CrowdexNameAndAvatar(),
            CrowdexStaminaRow(),
        },
        CrowdexSeparator(),
        CrowdexDamageRow(),
        CrowdexArmorRow(),
        CrowdexSeparator(),
        CrowdexConditionsRow(token),
        CrowdexSeparator(),
        CrowdexInventoryUI.SlotColumn("Hands", "hands", CrowdexInventoryUI.HAND_LABELS, g_panelSlotEnv),
        CrowdexInventoryUI.SlotColumn("Belt", "belt", nil, g_panelSlotEnv),
        CrowdexInventoryUI.SlotColumn("Backpack", "backpack", nil, g_panelSlotEnv),
        CrowdexSeparator(),
        CrowdexWornRow(token),
        CrowdexSeparator(),
        CrowdexCharacteristicsRow(token),
        CrowdexSeparator(),
        CrowdexSkillsSection(token),
    }
end

-- ---------------------------------------------------------------------------
-- CharacterPanel.* overrides
-- ---------------------------------------------------------------------------

-- Detail panel (rendered BELOW the sidebar when exactly one token is selected).
-- The expanded view now lives in the character-sheet "Sheet" tab, so this
-- stays a stub.
CharacterPanel.CreateCharacterDetailsPanel = function(token)
    return gui.Panel{
        width = "100%",
        height = 1,
    }
end

-- Side panel (shown in the Character dockable panel for each selected token).
function CharacterPanel.SingleCharacterDisplaySidePanel(token)
    local resultPanel
    resultPanel = gui.Panel{
        id = "sidebar",
        classes = {"crowdex-sidebar"},
        width = "auto",
        height = "auto",
        halign = "left",
        flow = "vertical",

        data = { token = token },

        events = {
            setToken = function(element, tok)
                token = tok
                element.data.token = tok
                -- Character sheet edits upload through the sheet harness,
                -- whose cache echo is identified-and-elided; the ONLY local
                -- notification is FireMonitorGame on the character's path.
                -- Monitor it so sheet edits show up here immediately.
                element.monitorGame = tok.monitorPath
                element:FireEventTree("refreshCharacter", tok)
            end,
            refreshGame = function(element)
                if token == nil or not token.valid then return end
                -- The network echo confirms our local change: clear the
                -- optimistic "pending" wound flags so the faded marker
                -- renders at full color.
                if token.properties ~= nil then
                    token.properties._tmp_woundPending = nil
                end
                element:FireEventTree("refreshCharacter", token)
            end,
            refresh = function(element)
                if token == nil or not token.valid then return end
                element:FireEventTree("refreshCharacter", token)
            end,
        },

        CrowdexOperationalPanel(token),
    }
    return resultPanel
end

-- Multi-edit panel (when multiple tokens are selected). Empty for now so the
-- old Draw Steel multi-edit doesn't render.
CharacterPanel.CreateMultiEdit = function()
    return gui.Panel{
        width = "auto",
        height = 0,
        events = {
            tokens = function(element, tokens) end,
        },
    }
end
