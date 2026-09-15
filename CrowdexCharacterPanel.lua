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
--     (Grabbed, Prone, Surprised, Unconscious).
--   - "effect" entries: characterOngoingEffects flagged crowsCondition: true
--     (Blessed, Weakened, Vulnerable, plus item-granted Hastened and Raging).
-- Nothing stacks. Playtest 2 retired the Blessed/Boned level system and added
-- the blanket rule "You can't gain a second instance of a condition you already
-- have", so every Crows entry is stackable = false and `stacks` is always 1.
-- The stacks plumbing is kept because the engine reports it and a future
-- item-granted effect could still want it.
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

    -- Free-text conditions the player typed via "Custom..." in the add menu.
    -- Stored as a plain list of strings on the character; the text itself is
    -- the id, so removing one just deletes that string from the list.
    for _, text in ipairs(props:try_get("crowdex_customConditions", {}) or {}) do
        result[#result + 1] = {
            id = text,
            name = text,
            stacks = 1,
            kind = "custom",
            info = nil,
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

local function GetExpertises(props)
    if props == nil then return {} end
    -- Expertises are resource pools granted by the background, not a stored
    -- property. See creature:CrowdexExpertises in CrowdexRules.lua. Wrapped in
    -- pcall so the panel still renders for a selected monster, which has none.
    local result = {}
    pcall(function() result = props:CrowdexExpertises() or {} end)
    return result
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

-- A worn slot value is one card (a table with a name), a list of cards, or
-- a bare value. Returns the card to display (nil when there is none), whether
-- the slot holds more than one card ("overstuffed"), and whether the slot
-- counts as filled at all (a bare value fills the slot but shows no card).
local function WornSlotCard(v)
    if type(v) == "table" and #v > 1 then
        return v[1], true, true
    elseif type(v) == "table" and #v == 1 then
        return v[1], false, true
    elseif type(v) == "table" and v.name ~= nil then
        return v, false, true
    elseif v ~= nil and type(v) ~= "table" then
        return nil, false, true
    end
    return nil, false, false
end

-- True when `keys` is the same ordering a section applied last time, so it
-- can skip reassigning `children` -- which re-lays out the whole list even
-- when every panel in it is being kept.
local function SameKeyOrder(prev, keys)
    if prev == nil or #prev ~= #keys then return false end
    for i = 1, #keys do
        if prev[i] ~= keys[i] then return false end
    end
    return true
end

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

--- Damage and healing inputs. Damage: amount, piercing toggle, Apply. Sits
--- above the Armor Defense section since that's what the damage hits first.
--- Routes through creature:TakeDamage -- the standard damage path, which
--- CrowdexInventory overrides with the Crows armor/stamina/wounds waterfall --
--- so this input, abilities, and rule strings all resolve damage identically.
--- Heal: amount + Heal button, routed through creature:Heal so Stamina history
--- and regainhitpoints events fire like any other healing source.
local function CrowdexDamageRow()
    local amountInput
    local piercingCheck
    local healInput

    local function Heal(element)
        local sectionData = element:FindParentWithClass("crowdex-section").data
        local tok = sectionData.token
        local n = math.floor(tonumber(healInput.text) or 0)
        if n <= 0 or tok == nil or not tok.valid or tok.properties == nil then
            healInput.text = ""
            return
        end
        tok:ModifyProperties{
            description = "Heal",
            execute = function()
                tok.properties:Heal(n, string.format("%d Healing", n))
            end,
        }
        healInput.text = ""
    end

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
        width = 100,
        height = 24,
        fontSize = 14,
        textAlignment = "center",
        placeholderText = "Damage...",
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
        -- The checkbox class forces minWidth 200; this row wants it hugging its label.
        width = "auto",
        minWidth = 0,
        height = 24,
        valign = "center",
        lmargin = 10,
        value = false,
    }

    healInput = gui.Input{
        width = 100,
        rmargin = 8,
        height = 24,
        fontSize = 14,
        textAlignment = "center",
        placeholderText = "Heal...",
        characterLimit = 3,
        valign = "center",
        bgcolor = "#226622",

        change = function(element)
            Heal(element)
        end,
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
            width = "auto",
            height = "auto",
            flow = "horizontal",
            halign = "center",
            valign = "center",

            healInput,
            amountInput,
            piercingCheck,
        },
    }
end

--- One Armor Defense source rendered like an inventory slot row, but taller,
--- with an AD bar. Rows drag onto each other to reorder damage priority:
--- the TOP row is the armor that absorbs (and is destroyed) first.
-- Numbers and colors derived from an armor piece, shared by the row's
-- refresh, its tooltip and its editable AD label.
local function DeriveArmorPiece(piece)
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
    return cur, mx, broken, inactive, pct, barColor
end

--- One armor-defense row. Built once per armor slot and kept across
--- refreshes: refreshArmorPiece(piece, pieces, position, token) re-reads the
--- piece and updates the labels, colors and bar in place. The handlers read
--- the live piece list from row.data, so drag-reorder, the parry toggle and
--- the editable AD keep working after the list changes underneath them.
--- `isParryWeapon` is fixed per row because it changes the row's layout.
local function CrowdexArmorPieceRow(isParryWeapon)
    local row

    -- A small toggle for parry weapons: tap to enable/disable using this
    -- weapon to parry. Defaults on; off sets slot.parryOff.
    local parryToggle
    if isParryWeapon then
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
            bgcolor = "#3a4a2a",
            borderColor = "#8fbf5f",
            color = "#cfe8a0",
            hoverCursor = "hand",
            text = "Parry",
            refreshArmorPiece = function(element, piece)
                local inactive = piece.active == false
                element.selfStyle.bgcolor = cond(inactive, "#2a2a2a", "#3a4a2a")
                element.selfStyle.borderColor = cond(inactive, "#555555", "#8fbf5f")
                element.selfStyle.color = cond(inactive, "#888888", "#cfe8a0")
            end,
            linger = function(element)
                local piece = row.data.piece
                if piece == nil then return end
                gui.Tooltip(cond(piece.active == false,
                    "Parry off: this weapon is not used to absorb damage. Tap to enable.",
                    "Parry on: this weapon absorbs damage like a shield. Tap to disable."))(element)
            end,
            press = function(element)
                local token = row.data.token
                local piece = row.data.piece
                if piece == nil or token == nil or not token.valid or token.properties == nil then return end
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
        local token = row.data.token
        local pieces = row.data.pieces
        local position = row.data.position
        local piece = row.data.piece
        if piece == nil or pieces == nil or token == nil or not token.valid or token.properties == nil then return end
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

        -- adReorderPosition: this row's position in the list, kept current
        -- by refreshArmorPiece; a dragged row reads it off the target.
        data = {
            adReorderPosition = 0,
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

    local iconPanel = gui.Panel{
        width = 16,
        height = 16,
        valign = "center",
        rmargin = 6,
        bgimage = "panels/square.png",
        bgcolor = "white",
        interactable = false,
    }

    local nameLabel = gui.Label{
        -- Narrower when a Parry toggle (46+4) shares the line.
        width = AD_ROW_WIDTH - 12 - 22 - 64 - cond(isParryWeapon, 50, 0),
        height = "auto",
        fontSize = 13,
        color = "white",
        valign = "center",
        interactable = false,
        text = "",
    }

    -- Current AD: editable. Type a number to set the AD left on
    -- this item; clamped to [0, max].
    local curLabel = gui.Label{
        width = 28,
        height = 16,
        fontSize = 13,
        bold = true,
        color = "#e8d59a",
        valign = "center",
        textAlignment = "right",
        editable = true,
        characterLimit = 3,
        text = "",

        change = function(element)
            local token = row.data.token
            local piece = row.data.piece
            if piece == nil or token == nil or not token.valid or token.properties == nil then return end
            local cur, mx = DeriveArmorPiece(piece)
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
    }

    local maxLabel = gui.Label{
        width = 36,
        height = "auto",
        fontSize = 13,
        bold = true,
        color = "#e8d59a",
        valign = "center",
        textAlignment = "left",
        interactable = false,
        text = "",
    }

    local barFill = gui.Panel{
        width = "0%",
        height = "100%",
        halign = "left",
        bgimage = "panels/square.png",
        bgcolor = "#caa45c",
        interactable = false,
    }

    row = gui.Panel{
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

        -- The piece this row shows, the full ordered list it belongs to and
        -- its position in it, as of the last refresh.
        data = { token = nil, piece = nil, pieces = nil, position = 0 },

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

        refreshArmorPiece = function(element, piece, pieces, position, token)
            element.data.token = token
            element.data.piece = piece
            element.data.pieces = pieces
            element.data.position = position
            dropTarget.data.adReorderPosition = position

            local cur, mx, broken, inactive, pct, barColor = DeriveArmorPiece(piece)
            local name = piece.name or "?"

            iconPanel.bgimage = piece.icon or "panels/square.png"
            iconPanel.bgcolor = cond(broken or inactive, "#886666", "white")

            local nameText = cond(broken, string.format("%s (broken)", name), name)
            if nameLabel.text ~= nameText then
                nameLabel.text = nameText
            end
            nameLabel.color = cond(inactive, "#888888", cond(broken, "#ff5050", "white"))

            local curText = tostring(cur)
            if curLabel.text ~= curText then
                curLabel.text = curText
            end
            curLabel.color = cond(broken, "#ff5050", "#e8d59a")

            local maxText = string.format(" / %d", mx)
            if maxLabel.text ~= maxText then
                maxLabel.text = maxText
            end
            maxLabel.color = cond(broken, "#ff5050", "#e8d59a")

            barFill.selfStyle.width = string.format("%.0f%%", pct * 100)
            barFill.selfStyle.bgcolor = barColor
        end,

        canDragOnto = function(element, target)
            return target.data ~= nil and target.data.adReorderPosition ~= nil
                and target.data.adReorderPosition ~= element.data.position
        end,

        drag = function(element, target)
            if target == nil then return end
            local targetPosition = target.data.adReorderPosition
            if targetPosition == nil then return end
            ReorderTo(targetPosition)
        end,

        linger = function(element)
            local piece = element.data.piece
            if piece == nil then return end
            local cur, mx, broken = DeriveArmorPiece(piece)
            gui.Tooltip(string.format(
                "%s: AD %d / %d.%s\nDamage is absorbed by the top-most armor first. Drag to reorder.",
                piece.name or "?", cur, mx, cond(broken, " Broken: cannot stop damage until repaired.", "")))(element)
        end,

        -- top line: icon, name, cur/max
        gui.Panel{
            width = "100%",
            height = 16,
            flow = "horizontal",
            valign = "center",

            iconPanel,
            nameLabel,
            parryToggle,
            curLabel,
            maxLabel,
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

            barFill,
        },

        dropTarget,
    }
    return row
end

--- The Stamina bar, rendered in the same visual language as the AD rows and
--- shown directly below them: armor absorbs from the top of the list first,
--- and Stamina is what's left when the armor is gone. The current value is
--- editable. Built once; refreshStamina(token, props) updates it in place.
local function CrowdexStaminaBarRow()
    local row

    local curLabel = gui.Label{
        width = 28,
        height = 16,
        fontSize = 13,
        bold = true,
        color = "#5fae5f",
        valign = "center",
        textAlignment = "right",
        editable = true,
        characterLimit = 3,
        text = "",

        -- Current stamina: editable, clamped to [0, max].
        change = function(element)
            local token = row.data.token
            local cur = row.data.cur
            local mx = row.data.mx
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
    }

    local maxLabel = gui.Label{
        width = 36,
        height = "auto",
        fontSize = 13,
        bold = true,
        color = "#5fae5f",
        valign = "center",
        textAlignment = "left",
        interactable = false,
        text = "",
    }

    local barFill = gui.Panel{
        width = "0%",
        height = "100%",
        halign = "left",
        bgimage = "panels/square.png",
        bgcolor = "#5fae5f",
        interactable = false,
    }

    row = gui.Panel{
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

        -- The crow and its stamina as of the last refresh.
        data = { token = nil, cur = 0, mx = 0 },

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

        refreshStamina = function(element, token, props)
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

            element.data.token = token
            element.data.cur = cur
            element.data.mx = mx

            local curText = tostring(cur)
            if curLabel.text ~= curText then
                curLabel.text = curText
            end
            curLabel.color = cond(cur <= 0, "#ff5050", "#5fae5f")

            local maxText = string.format(" / %d", mx)
            if maxLabel.text ~= maxText then
                maxLabel.text = maxText
            end

            barFill.selfStyle.width = string.format("%.0f%%", pct * 100)
            barFill.selfStyle.bgcolor = barColor
        end,

        linger = function(element)
            gui.Tooltip(string.format(
                "Stamina %d / %d. When your armor's AD is gone, damage comes off Stamina; at 0 Stamina further damage becomes wounds.",
                element.data.cur, element.data.mx))(element)
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
            curLabel,
            maxLabel,
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

            barFill,
        },
    }
    return row
end

local function CrowdexArmorRow()
    -- Live rows keyed by armor slot ("kind:index:parry"), kept across
    -- refreshes; `order` is the key list last applied to `children`.
    local rows = {}
    local order = nil

    local emptyLabel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 11,
        color = "#888",
        italics = true,
        text = "No armor worn. Right-click a suit of armor in your backpack to wear it.",
        textWrap = true,
        classes = {"collapsed"},
    }

    local hintLabel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 10,
        italics = true,
        color = "#888888",
        tmargin = 2,
        text = "Top armor takes damage first. Drag to reorder.",
        classes = {"collapsed"},
    }

    local staminaRow = CrowdexStaminaBarRow()

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

            emptyLabel,
            hintLabel,
            staminaRow,

            refreshCharacter = function(element, tok)
                if tok == nil or tok.properties == nil then return end
                -- AD sources derive from the inventory: the worn suit of
                -- armor plus shields held in hand slots, in damage-priority
                -- order (top-most absorbs first). Stamina renders below
                -- them: it's what damage hits once the armor is gone.
                local pieces = CrowdexInventoryUI.ArmorPieces(tok.properties)
                local newRows = {}
                local children = {}
                local keys = {}
                for i, piece in ipairs(pieces) do
                    local isParry = piece.isParryWeapon == true
                    local key = string.format("%s:%s:%s", tostring(piece.kind), tostring(piece.index), tostring(isParry))
                    local row = rows[key]
                    if row == nil or not row.valid then
                        row = CrowdexArmorPieceRow(isParry)
                    end
                    row:FireEventTree("refreshArmorPiece", piece, pieces, i, tok)
                    newRows[key] = row
                    children[#children + 1] = row
                    keys[#keys + 1] = key
                end
                rows = newRows

                emptyLabel:SetClass("collapsed", #pieces ~= 0)
                hintLabel:SetClass("collapsed", #pieces <= 1)
                children[#children + 1] = emptyLabel
                keys[#keys + 1] = "(empty)"
                children[#children + 1] = hintLabel
                keys[#keys + 1] = "(hint)"

                staminaRow:FireEvent("refreshStamina", tok, tok.properties)
                children[#children + 1] = staminaRow
                keys[#keys + 1] = "(stamina)"

                if not SameKeyOrder(order, keys) then
                    order = keys
                    element.children = children
                end
            end,
        },
    }
end

--- Strip of condition chips, driven by the game's condition content tables.
--- Grabbed/Prone/Surprised/Unconscious live in the charConditions table and
--- are inflicted via creature:InflictCondition. Blessed/Weakened/Vulnerable
--- live in characterOngoingEffects (flagged crowsCondition: true) and are
--- applied via creature:ApplyOngoingEffect. Clicking a chip removes the
--- condition. Nothing stacks in Playtest 2, so the stack-aware paths below are
--- dormant rather than dead -- they still serve any future stackable effect.
local function CrowdexConditionsRow(token)
    -- The sidebar is built once and re-pointed at different crows via the
    -- setToken/refreshCharacter events (see SingleCharacterDisplaySidePanel),
    -- so the `token` captured at construction goes stale. Track the live token
    -- here, updated each refresh, and route all mutations through it -- the add
    -- menu and the remove handler are otherwise served the wrong crow.
    local currentToken = token

    -- The "+ Add" chip, created on the first refresh and kept; the custom
    -- popup anchors to it.
    local addButton = nil
    local ShowCustomConditionPopup

    -- Re-render the sidebar from local properties right away rather than
    -- waiting for the network echo of the ModifyProperties upload.
    local function RefreshSidebar(element)
        local sidebar = element:FindParentWithClass("crowdex-sidebar")
        if sidebar ~= nil and currentToken ~= nil and currentToken.valid then
            sidebar:FireEventTree("refreshCharacter", currentToken)
        end
    end

    local function AddCustomCondition(anchor, text)
        text = string.trim(text or "")
        if text == "" or currentToken == nil or currentToken.properties == nil then return end
        currentToken:ModifyProperties{
            description = "Add condition " .. text,
            execute = function()
                local list = currentToken.properties:try_get("crowdex_customConditions", nil)
                if list == nil then
                    list = {}
                    currentToken.properties.crowdex_customConditions = list
                end
                for _, existing in ipairs(list) do
                    if existing == text then return end
                end
                list[#list + 1] = text
            end,
        }
        RefreshSidebar(anchor)
    end

    -- Small popup with a single text field. Enter or "Add" commits; Escape,
    -- "Cancel", or an empty submit just closes it.
    ShowCustomConditionPopup = function(anchor)
        local input
        input = gui.Input{
            width = 200,
            height = 28,
            fontSize = 14,
            placeholderText = "Condition...",
            characterLimit = 40,
            hasFocus = true,
            change = function(element)
                local text = element.text
                anchor.popup = nil
                AddCustomCondition(anchor, text)
            end,
        }

        anchor.popup = gui.Panel{
            classes = {"framedPanel"},
            styles = ThemeEngine.GetStyles(),
            flow = "vertical",
            width = 240,
            height = "auto",
            pad = 12,
            borderBox = true,
            captureEscape = true,
            escape = function()
                anchor.popup = nil
            end,
            gui.Label{
                classes = {"sizeM"},
                text = "Custom condition",
                width = "auto",
                height = "auto",
                bmargin = 6,
            },
            input,
            gui.Panel{
                flow = "horizontal",
                width = "auto",
                height = "auto",
                halign = "right",
                tmargin = 8,
                gui.Button{
                    classes = {"sizeM"},
                    text = "Cancel",
                    width = 80,
                    height = 30,
                    hmargin = 4,
                    click = function()
                        anchor.popup = nil
                    end,
                },
                gui.Button{
                    classes = {"sizeM"},
                    text = "Add",
                    width = 80,
                    height = 30,
                    hmargin = 4,
                    click = function()
                        local text = input.text
                        anchor.popup = nil
                        AddCustomCondition(anchor, text)
                    end,
                },
            },
        }
    end

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
        entries[#entries + 1] = {
            text = "Custom...",
            click = function()
                -- Open the text-entry popup on the next frame: the context
                -- menu is still closing when this fires, and setting popup
                -- now would be clobbered by the menu's own teardown.
                dmhub.Schedule(0.01, function()
                    if mod.unloaded or addButton == nil or not addButton.valid then return end
                    ShowCustomConditionPopup(addButton)
                end)
            end,
        }
        return entries
    end

    -- One chip. It reads the condition it shows from chip.data.cond, which
    -- refreshCondition updates, so the same chip can be kept across refreshes.
    local function CreateConditionChip()
        local chip
        local function DisplayLabel(c)
            if c.kind == "effect" and (c.stacks or 1) > 1 then
                return string.format("%s x%d", c.name, c.stacks)
            end
            return c.name
        end

        chip = gui.Panel{
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
            data = { cond = nil },

            refreshCondition = function(element, c)
                element.data.cond = c
            end,

            press = function(element)
                local c = element.data.cond
                if c == nil or currentToken == nil or not currentToken.valid then return end
                local displayLabel = DisplayLabel(c)
                local condid = c.id
                local kind = c.kind
                currentToken:ModifyProperties{
                    description = "Remove condition " .. displayLabel,
                    execute = function()
                        if kind == "condition" then
                            currentToken.properties:InflictCondition(condid, {purge = true})
                        elseif kind == "custom" then
                            local list = currentToken.properties:try_get("crowdex_customConditions", {}) or {}
                            for i = #list, 1, -1 do
                                if list[i] == condid then table.remove(list, i) end
                            end
                        else
                            --remove one stack (level) at a time
                            currentToken.properties:RemoveOngoingEffect(condid, 1)
                        end
                    end,
                }
                RefreshSidebar(element)
            end,

            linger = function(element)
                local c = element.data.cond
                if c == nil then return end
                local displayLabel = DisplayLabel(c)
                if c.kind == "custom" then
                    gui.Tooltip(string.format("<b>%s</b>\n\nClick to remove %s.", displayLabel, c.name))(element)
                    return
                end
                local rulesText = ""
                if c.info ~= nil then
                    rulesText = c.info:try_get("description", "")
                end
                local removeText
                if c.kind == "effect" then
                    removeText = "Click to remove one level of " .. c.name .. "."
                else
                    removeText = "Click to remove " .. c.name .. "."
                end
                gui.Tooltip(string.format("<b>%s</b>: %s\n\n%s", displayLabel, rulesText, removeText))(element)
            end,

            gui.Label{
                width = "auto",
                height = "auto",
                fontSize = 12,
                color = "#ffe6b8",
                text = "",
                refreshCondition = function(element, c)
                    local text = DisplayLabel(c)
                    if element.text ~= text then
                        element.text = text
                    end
                end,
            },
        }
        return chip
    end

    local function CreateAddButton()
        return gui.Panel{
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

            -- chips: live chip panels keyed by "<kind>:<id>", kept across
            -- refreshes so an unchanged condition costs nothing to redraw.
            -- order: the key list last applied to `children`.
            data = { chips = {}, order = nil },

            refreshCharacter = function(element, tok)
                if tok == nil or tok.properties == nil then return end
                currentToken = tok
                local chips = element.data.chips
                local newChips = {}
                local children = {}
                local keys = {}
                for _, c in ipairs(GetActiveCrowsConditions(tok.properties)) do
                    local key = c.kind .. ":" .. tostring(c.id)
                    local chip = chips[key]
                    if chip == nil or not chip.valid then
                        chip = CreateConditionChip()
                    end
                    chip:FireEventTree("refreshCondition", c)
                    newChips[key] = chip
                    children[#children + 1] = chip
                    keys[#keys + 1] = key
                end

                -- Add button always present at end.
                if addButton == nil or not addButton.valid then
                    addButton = CreateAddButton()
                end
                children[#children + 1] = addButton
                keys[#keys + 1] = "+add"

                element.data.chips = newChips
                if not SameKeyOrder(element.data.order, keys) then
                    element.data.order = keys
                    element.children = children
                end
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

    -- One label per slot, built once; refreshes only recolor and retext them.
    local collapsedLabels = {}
    for _, def in ipairs(WORN_SLOT_ORDER) do
        collapsedLabels[#collapsedLabels + 1] = gui.Label{
            width = "auto",
            height = "auto",
            fontSize = 11,
            color = "#666",
            rmargin = 4,
            text = def.short .. "( )",
            data = { key = def.key, short = def.short },
        }
    end

    local collapsedBar
    collapsedBar = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "horizontal",
        valign = "center",
        children = collapsedLabels,

        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            local worn = GetWornSlots(tok.properties)
            for _, label in ipairs(collapsedLabels) do
                local _, _, filled = WornSlotCard(worn[label.data.key])
                local text = string.format("%s%s", label.data.short, filled and "(*)" or "( )")
                if label.text ~= text then
                    label.text = text
                end
                label.color = filled and "#ffd700" or "#666"
            end
        end,
    }

    -- One cell per slot, built once. A refresh sends each cell its card via
    -- refreshWornSlot; the overstuffed badge is always present and toggled.
    local wornCells = {}
    for _, def in ipairs(WORN_SLOT_ORDER) do
        local slotLabel = def.label
        local nameLabel = gui.Label{
            width = "100%",
            height = "auto",
            halign = "center",
            textAlignment = "center",
            fontSize = 10,
            color = "#666",
            text = slotLabel,
            textWrap = true,
        }
        local badge = gui.Label{
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
            classes = {"collapsed"},
        }
        wornCells[#wornCells + 1] = gui.Panel{
            width = CELL_W,
            height = CELL_H,
            flow = "none",
            bgimage = "panels/square.png",
            bgcolor = "#181818",
            borderWidth = 1,
            borderColor = "#444",
            cornerRadius = 3,
            hmargin = 2,
            vmargin = 2,
            data = { key = def.key },

            refreshWornSlot = function(element, card, overstuffed)
                element.selfStyle.borderColor = card and "#caa45c" or "#444"
                nameLabel.color = card and "white" or "#666"
                local text = card and (card.name or slotLabel) or slotLabel
                if nameLabel.text ~= text then
                    nameLabel.text = text
                end
                badge:SetClass("collapsed", not overstuffed)
            end,

            gui.Panel{
                width = "100%",
                height = "auto",
                flow = "vertical",
                halign = "center",
                valign = "top",
                pad = 4,
                borderBox = true,

                nameLabel,
            },

            badge,
        }
    end

    local expandedCells
    expandedCells = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        classes = {"collapsed"},
        tmargin = 4,

        gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            halign = "left",
            children = wornCells,
        },

        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            local worn = GetWornSlots(tok.properties)
            for _, cell in ipairs(wornCells) do
                local card, overstuffed = WornSlotCard(worn[cell.data.key])
                cell:FireEvent("refreshWornSlot", card, overstuffed)
            end
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

--- Expertises section. Collapsed by default. When expanded, shows a filter
--- dropdown above a flat scrollable list with editable remaining uses.
local function CrowdexExpertisesSection(token)
    local expanded = false
    local currentFilter = "all"
    -- Slot reused across crows via setToken; track the live token so the
    -- filter dropdown re-renders the right crow's expertises.
    local currentToken = token

    -- Playtest 2 has exactly three expertise categories and no further
    -- subdivision, so the filter is those three plus All.
    local function expertiseMatchesFilter(exp, filt)
        if filt == "all" then return true end
        return (exp.category or ""):lower() == filt
    end

    -- One expertise row. Its controls read the live record from row.data.exp
    -- (set by refreshExpertise) instead of closing over one refresh's values,
    -- so the row can be kept and updated in place across refreshes.
    local function CreateExpertiseRow()
        local row

        local function Limit(info)
            return info.resource:try_get("usageLimit", "long")
        end

        local nameLabel = gui.Label{
            width = "auto-grow",
            height = "auto",
            halign = "left",
            fontSize = 12,
            color = "white",
            text = "",
            refreshExpertise = function(element, exp)
                local text = exp.name or "(unnamed)"
                if element.text ~= text then
                    element.text = text
                end
                element.color = cond((exp.remaining or 0) <= 0, "#777", "white")
            end,
        }

        -- Fixed-width controls keep every expertise aligned.
        -- The input edits uses remaining; - spends one and +
        -- restores one without changing the expertise maximum.
        local minusButton = gui.Button{
            width = 22,
            height = 20,
            fontSize = 12,
            text = "-",
            refreshExpertise = function(element, exp)
                element:SetClass("disabled", not ((exp.remaining or 0) > 0 and not exp.suppressed))
            end,
            click = function()
                local expertise = row.data.exp
                if expertise == nil or currentToken == nil or not currentToken.valid or expertise.suppressed then return end
                currentToken:ModifyProperties{
                    description = "Spend " .. (expertise.name or "expertise") .. " use",
                    execute = function()
                        local info = CrowdexExpertise.FindById(expertise.id)
                        if info ~= nil and CrowdexExpertise.Available(currentToken.properties, expertise.id) > 0 then
                            currentToken.properties:ConsumeResource(expertise.id, Limit(info), 1,
                                "Manual expertise use")
                        end
                    end,
                }
            end,
            linger = gui.Tooltip("Spend one use"),
        }

        local input = gui.Input{
            width = 30,
            height = 20,
            fontSize = 11,
            textAlignment = "right",
            characterLimit = 2,
            text = "",
            refreshExpertise = function(element, exp)
                local text = tostring(exp.remaining or 0)
                if element.text ~= text then
                    element.text = text
                end
            end,
            change = function(element)
                local expertise = row.data.exp
                if expertise == nil then return end
                local remaining = expertise.remaining or 0
                local maximum = expertise.max or 0
                if currentToken == nil or not currentToken.valid or expertise.suppressed then
                    element.text = tostring(remaining)
                    return
                end
                local target = tonumber(element.text)
                if target == nil then
                    element.text = tostring(remaining)
                    return
                end
                target = math.max(0, math.min(math.floor(target), maximum))
                element.text = tostring(target)
                currentToken:ModifyProperties{
                    description = "Set " .. (expertise.name or "expertise") .. " uses",
                    execute = function()
                        local info = CrowdexExpertise.FindById(expertise.id)
                        if info == nil then return end
                        local props = currentToken.properties
                        local liveMaximum = tonumber((props:GetResources() or {})[expertise.id]) or maximum
                        local used = props:GetResourceUsage(expertise.id, Limit(info)) or 0
                        local current = math.max(0, liveMaximum - used)
                        local desired = math.max(0, math.min(target, liveMaximum))
                        local difference = desired - current
                        if difference > 0 then
                            props:RefreshResource(expertise.id, Limit(info), difference,
                                "Edit expertise uses")
                        elseif difference < 0 then
                            props:ConsumeResource(expertise.id, Limit(info), -difference,
                                "Edit expertise uses")
                        end
                    end,
                }
            end,
            linger = gui.Tooltip("Set uses remaining"),
        }

        local maxLabel = gui.Label{
            width = 24,
            height = "auto",
            fontSize = 11,
            color = "#9bd97a",
            text = "",
            refreshExpertise = function(element, exp)
                local text = "/" .. tostring(exp.max or 0)
                if element.text ~= text then
                    element.text = text
                end
                element.color = cond((exp.remaining or 0) <= 0, "#777", "#9bd97a")
            end,
        }

        local plusButton = gui.Button{
            width = 22,
            height = 20,
            fontSize = 12,
            text = "+",
            refreshExpertise = function(element, exp)
                element:SetClass("disabled", not ((exp.remaining or 0) < (exp.max or 0) and not exp.suppressed))
            end,
            click = function()
                local expertise = row.data.exp
                if expertise == nil or currentToken == nil or not currentToken.valid or expertise.suppressed then return end
                currentToken:ModifyProperties{
                    description = "Restore " .. (expertise.name or "expertise") .. " use",
                    execute = function()
                        local info = CrowdexExpertise.FindById(expertise.id)
                        if info ~= nil then
                            currentToken.properties:RefreshResource(expertise.id, Limit(info), 1,
                                "Refund expertise use")
                        end
                    end,
                }
            end,
            linger = gui.Tooltip("Restore one spent use"),
        }

        row = gui.Panel{
            width = "100%",
            height = 22,
            flow = "horizontal",
            valign = "center",
            vmargin = 1,
            data = { exp = nil },

            refreshExpertise = function(element, exp)
                element.data.exp = exp
            end,

            nameLabel,
            gui.Panel{
                width = 104,
                height = 22,
                flow = "horizontal",
                halign = "right",
                valign = "center",

                minusButton,
                input,
                maxLabel,
                plusButton,
            },
        }
        return row
    end

    local expertiseListPanel
    expertiseListPanel = gui.Panel{
        width = "100%",
        height = "auto",
        maxHeight = 200,
        flow = "vertical",
        vscroll = true,

        -- rows: live row panels keyed by expertise id, kept across refreshes.
        -- order: the key list last applied to `children`.
        -- dirty: a refresh arrived while collapsed; catch up on expand.
        data = { rows = {}, order = nil, dirty = false, emptyLabel = nil },

        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            currentToken = tok
            -- Nothing here is visible while the section is collapsed, and
            -- this list is the most expensive part of the sidebar to fill.
            if not expanded then
                element.data.dirty = true
                return
            end
            element.data.dirty = false

            local rows = element.data.rows
            local newRows = {}
            local children = {}
            local keys = {}
            for _, exp in ipairs(GetExpertises(tok.properties)) do
                if expertiseMatchesFilter(exp, currentFilter) then
                    local key = tostring(exp.id or exp.name)
                    local row = rows[key]
                    if row == nil or not row.valid then
                        row = CreateExpertiseRow()
                    end
                    row:FireEventTree("refreshExpertise", exp)
                    newRows[key] = row
                    children[#children + 1] = row
                    keys[#keys + 1] = key
                end
            end
            if #children == 0 then
                local empty = element.data.emptyLabel
                if empty == nil or not empty.valid then
                    empty = gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 11,
                        italics = true,
                        color = "#666",
                        text = "(no expertises match filter)",
                    }
                    element.data.emptyLabel = empty
                end
                children[1] = empty
                keys[1] = "(empty)"
            end
            element.data.rows = newRows
            if not SameKeyOrder(element.data.order, keys) then
                element.data.order = keys
                element.children = children
            end
        end,
    }

    local filterDropdown
    filterDropdown = gui.Dropdown{
        width = 140,
        height = 22,
        halign = "right",
        options = {
            {id = "all",          text = "All"},
            {id = "general",      text = "General"},
            {id = "spellcasting", text = "Spellcasting"},
            {id = "weapon",       text = "Weapon"},
        },
        idChosen = "all",
        change = function(element)
            currentFilter = element.idChosen or "all"
            if currentToken ~= nil and currentToken.valid then
                expertiseListPanel:FireEventTree("refreshCharacter", currentToken)
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

        expertiseListPanel,
    }

    local headerCount
    headerCount = gui.Label{
        width = "auto",
        height = "auto",
        halign = "left",
        fontSize = 11,
        bold = true,
        color = "#aaa",
        text = "EXPERTISES",
        refreshCharacter = function(element, tok)
            if tok == nil or tok.properties == nil then return end
            local expertises = GetExpertises(tok.properties)
            local remaining = 0
            for _, exp in ipairs(expertises) do
                remaining = remaining + (exp.remaining or 0)
            end
            element.text = string.format("EXPERTISES (%d %s left)", remaining,
                cond(remaining == 1, "use", "uses"))
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
            -- Refreshes are skipped while collapsed; fill the list now if
            -- one arrived in the meantime.
            if expanded and expertiseListPanel.data.dirty and currentToken ~= nil and currentToken.valid then
                expertiseListPanel:FireEvent("refreshCharacter", currentToken)
            end
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
        CrowdexExpertisesSection(token),
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

        -- The hud broadcasts 'refresh' tree-wide after ANY game change --
        -- every step of every token's move, on every client -- so the
        -- sections below must update their existing panels in place and
        -- only create or destroy panels when the crow's structure changes
        -- (a new item, a new condition). Rebuilding them on each refresh
        -- froze slower machines for up to a second per step (bug 67X6T34H).
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
