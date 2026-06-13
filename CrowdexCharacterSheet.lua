local mod = dmhub.GetModLoading()

-- The Crows "Sheet" tab. This is the single integrated character surface:
-- the creation flow (name + feature, characteristics, background) folds into
-- the same screen that shows skills, traits, and the inventory. There is no
-- separate Builder tab any more (it is deregistered below).
--
-- Layout: a two-column row inside a full-height host.
--   Left column (scrolls):  identity, characteristics, background, skills,
--                           traits.
--   Right column (scrolls): the full inventory interface (slots, party,
--                           item index), reused verbatim from
--                           CrowdexInventory.lua.
--
-- The builder data helpers (GetBackground, BackgroundParts, ChangeHero, ...)
-- are shared from CrowdexBuilder.lua via the CrowdexBuilderUI global; the
-- inventory tab from CrowdexInventory.lua via CrowdexInventoryUI. Both globals
-- are resolved at panel-build / event time, so module load order does not
-- matter.

-- ---------------------------------------------------------------------------
-- Field accessors.
-- ---------------------------------------------------------------------------

local function GetSkills(props)
    if props == nil then return {} end
    -- Skills come from the rules system (background proficiency modifiers
    -- etc.), not from a stored property. See creature:CrowdexSkills in
    -- CrowdexRules.lua.
    return props:CrowdexSkills()
end

local function GetTraits(props)
    if props == nil then return {} end
    -- A crow's trait flows from its background: the background carries a
    -- CharacterFeature whose name is prefixed "Trait:" (see the crows-background
    -- imports). There is no stored crowdex_traits list. The "Trait:" prefix is
    -- stripped for display since the section is already headed "Traits".
    local B = CrowdexBuilderUI
    if B == nil then return {} end
    local bg = B.GetBackground(props)
    if bg == nil then return {} end
    local _, features = B.BackgroundParts(bg)
    local result = {}
    for _, f in ipairs(features) do
        local name = f.name or ""
        if string.find(name, "^Trait:") then
            local display = string.gsub(name, "^Trait:%s*", "")
            result[#result + 1] = { name = display, description = f.description }
        end
    end
    return result
end

local function GetCharacteristic(props, attrid)
    if props == nil then return 0 end
    return props:GetAttribute(attrid):Modifier()
end

-- The characteristic readout order requested for the sheet: Mind, Agility,
-- Strength (the engine registers them Agility/Mind/Strength).
local CHAR_DISPLAY = {
    { id = "mind",     label = "MIND"     },
    { id = "agility",  label = "AGILITY"  },
    { id = "strength", label = "STRENGTH" },
}

-- ---------------------------------------------------------------------------
-- Small reusable widgets.
-- ---------------------------------------------------------------------------

local function SheetSectionHeading(text)
    return gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 16,
        bold = true,
        color = "#e8d59a",
        text = text,
        tmargin = 12,
        bmargin = 4,
    }
end

local function SheetSubHeading(text)
    return gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 11,
        bold = true,
        color = "#aaaaaa",
        text = text,
        tmargin = 6,
        bmargin = 2,
    }
end

local function ItalicEmpty(text)
    return gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 12,
        color = "#888888",
        italics = true,
        text = text,
        tmargin = 4,
    }
end

-- A single name + bonus row used in the SKILLS list.
local function SkillRow(name, bonus)
    local b = tonumber(bonus) or 0
    local bonusText
    if b > 0 then
        bonusText = string.format("+%d", b)
    elseif b < 0 then
        bonusText = tostring(b)
    else
        bonusText = "0"
    end

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        valign = "center",
        vmargin = 1,

        gui.Label{
            width = "auto-grow",
            height = "auto",
            fontSize = 12,
            color = "#dddddd",
            halign = "left",
            text = name or "",
        },
        gui.Label{
            width = 40,
            height = "auto",
            fontSize = 12,
            color = "white",
            halign = "right",
            textAlignment = "right",
            text = bonusText,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Section 1: Identity (name + distinguishing feature).
--
-- While a field is empty it shows its caption + a boxed input, plus the
-- instructional paragraph. Once filled, the instructions collapse to save
-- space and the field renders as a plain (still-editable) label.
-- ---------------------------------------------------------------------------

local function IdentityField(caption, characterLimit, getText, onCommit)
    local captionLabel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 11,
        bold = true,
        color = "#aaaaaa",
        text = caption,
        bmargin = 2,
    }

    local input
    input = gui.Label{
        classes = {"crowsInput"},
        bgimage = true,
        width = "100%",
        maxWidth = 420,
        halign = "left",
        height = 32,
        fontSize = 16,
        color = "white",
        valign = "center",
        editable = true,
        characterLimit = characterLimit,
        borderBox = true,
        hpad = 6,
        text = "",

        change = function(element)
            onCommit(element.text)
        end,

        refreshCharacterInfo = function(element, props)
            local v = getText(props) or ""
            if not element.hasFocus then
                element.text = v
            end
            local entered = (v ~= "")
            element:SetClass("entered", entered)
            captionLabel:SetClass("collapsed", entered)
        end,
    }

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        bmargin = 8,

        captionLabel,
        input,
    }
end

local function CreateIdentitySection()
    local B = CrowdexBuilderUI

    local instructions = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 12,
        color = "#bbbbbb",
        wrap = true,
        bmargin = 8,
        text = "Give your crow a name and one distinguishing feature: a tattoo, a distinct body odor, a unique voice, a strong personality trait. Just one thing that stands out.",
    }

    local nameField = IdentityField("NAME", 30,
        function(props)
            local token = B.GetHeroToken()
            if token ~= nil then return token.name or "" end
            return ""
        end,
        function(text)
            local token = B.GetHeroToken()
            if token == nil then return end
            token.name = text
            token:UploadAppearance()
        end)

    local featureField = IdentityField("DISTINGUISHING FEATURE", 100,
        function(props)
            return props:try_get("crowdex_distinguishingFeature", "") or ""
        end,
        function(text)
            B.ChangeHero(function(props)
                props.crowdex_distinguishingFeature = text
            end)
        end)

    return gui.Panel{
        id = "crowsIdentitySection",
        width = "100%",
        height = "auto",
        flow = "vertical",

        instructions,
        nameField,
        featureField,

        refreshCharacterInfo = function(element, props)
            -- Collapse the instructional paragraph once a name is entered.
            local token = B.GetHeroToken()
            local hasName = token ~= nil and token.name ~= nil and token.name ~= ""
            instructions:SetClass("collapsed", hasName)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Section 2: Characteristics.
--
-- Shows the background's characteristic-spread choice as selectable cards.
-- Once a spread is chosen the section collapses to a compact Mind / Agility /
-- Strength readout.
-- ---------------------------------------------------------------------------

local function CharReadoutBox(attrid, label)
    return gui.Panel{
        width = 72,
        height = 64,
        flow = "vertical",
        halign = "left",
        valign = "center",
        borderWidth = 1,
        borderColor = "#666666",
        cornerRadius = 4,
        bgcolor = "#222222",
        bgimage = "panels/square.png",
        pad = 4,
        borderBox = true,
        rmargin = 8,
        bmargin = 8,

        gui.Label{
            width = "100%",
            height = "auto",
            halign = "center",
            textAlignment = "center",
            fontSize = 22,
            bold = true,
            color = "white",
            text = "0",
            refreshCharacterInfo = function(element, props)
                local val = GetCharacteristic(props, attrid)
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
            color = "#aaaaaa",
            text = label,
        },
    }
end

-- A compact Stamina readout + bar, sized to sit beside the characteristic
-- boxes. The current value is editable (writes damage_taken); the whole block
-- collapses until the crow has a Stamina pool (mx > 0), which a background's
-- hitpoints modifier supplies.
local function CreateStaminaBar()
    local st = { mx = 0, cur = 0 }
    local valueLabel, maxLabel, fillBar

    valueLabel = gui.Label{
        width = 34,
        height = 18,
        fontSize = 16,
        bold = true,
        color = "#5fae5f",
        valign = "center",
        halign = "left",
        textAlignment = "right",
        editable = true,
        characterLimit = 3,
        text = "0",
        change = function(element)
            local mx = st.mx
            local n = tonumber(element.text)
            if n == nil then
                element.text = tostring(st.cur)
                return
            end
            n = math.max(0, math.min(math.floor(n), mx))
            CrowdexBuilderUI.ChangeHero(function(props)
                props.damage_taken = mx - n
            end)
        end,
    }

    maxLabel = gui.Label{
        width = "auto",
        height = 18,
        fontSize = 16,
        bold = true,
        color = "#5fae5f",
        valign = "center",
        textAlignment = "left",
        interactable = false,
        text = " / 0",
    }

    fillBar = gui.Panel{
        width = "0%",
        height = "100%",
        halign = "left",
        bgimage = "panels/square.png",
        bgcolor = "#5fae5f",
        interactable = false,
    }

    return gui.Panel{
        width = 170,
        height = 64,
        flow = "vertical",
        borderWidth = 1,
        borderColor = "#666666",
        cornerRadius = 4,
        bgcolor = "#222222",
        bgimage = "panels/square.png",
        pad = 8,
        borderBox = true,
        valign = "top",
        halign = "left",
        lmargin = 4,

        linger = function(element)
            gui.Tooltip(string.format(
                "Stamina %d / %d. At 0 Stamina, further damage becomes wounds.", st.cur, st.mx))(element)
        end,

        gui.Label{
            width = "100%",
            height = "auto",
            fontSize = 10,
            bold = true,
            color = "#aaaaaa",
            text = "STAMINA",
            bmargin = 2,
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "center",

            valueLabel,
            maxLabel,
        },

        gui.Panel{
            width = "100%",
            height = 8,
            tmargin = 6,
            bgimage = "panels/square.png",
            bgcolor = "#101018",
            borderWidth = 1,
            borderColor = "#3a3a4a",
            interactable = false,

            fillBar,
        },

        refreshCharacterInfo = function(element, props)
            local mx = (props.MaxHitpoints and props:MaxHitpoints()) or 0
            element:SetClass("collapsed", mx <= 0)
            st.mx = mx
            if mx <= 0 then return end

            local cur = (props.CurrentHitpoints and props:CurrentHitpoints()) or 0
            cur = math.max(0, math.min(cur, mx))
            st.cur = cur

            local pct = cur / mx
            local barColor = "#5fae5f"
            if cur <= 0 then
                barColor = "#552222"
            elseif pct <= 0.34 then
                barColor = "#aa3333"
            end

            if not valueLabel.hasInputFocus then
                valueLabel.text = tostring(cur)
            end
            valueLabel.selfStyle.color = cond(cur <= 0, "#ff5050", "#5fae5f")
            maxLabel.text = string.format(" / %d", mx)
            fillBar.selfStyle.width = string.format("%.0f%%", pct * 100)
            fillBar.selfStyle.bgcolor = barColor
        end,
    }
end

local function CreateCharacteristicsSection()
    local B = CrowdexBuilderUI

    local placeholder = ItalicEmpty("Choose a background below to set your characteristics.")

    local descriptionLabel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 12,
        color = "#bbbbbb",
        wrap = true,
        bmargin = 6,
        text = "",
    }

    local cardsPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        wrap = true,
        halign = "left",
    }

    local readoutBoxes = {}
    for _, c in ipairs(CHAR_DISPLAY) do
        readoutBoxes[#readoutBoxes + 1] = CharReadoutBox(c.id, c.label)
    end
    local readoutPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        wrap = true,
        halign = "left",
        children = readoutBoxes,
    }

    local charContent = gui.Panel{
        width = 460,
        height = "auto",
        flow = "vertical",
        valign = "top",

        placeholder,
        descriptionLabel,
        cardsPanel,
        readoutPanel,
    }

    local staminaBar = CreateStaminaBar()

    return gui.Panel{
        id = "crowsCharacteristicsSection",
        width = "100%",
        height = "auto",
        flow = "vertical",

        SheetSectionHeading("Characteristics"),

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "top",

            charContent,
            staminaBar,
        },

        refreshCharacterInfo = function(element, props)
            local bg = B.GetBackground(props)
            local choice = nil
            if bg ~= nil then
                choice = B.BackgroundParts(bg)
            end

            if choice == nil then
                placeholder:SetClass("collapsed", false)
                descriptionLabel:SetClass("collapsed", true)
                cardsPanel:SetClass("collapsed", true)
                readoutPanel:SetClass("collapsed", true)
                return
            end

            placeholder:SetClass("collapsed", true)

            local selection = props:GetLevelChoices()[choice.guid]
            local selectedGuid = nil
            if type(selection) == "table" then
                selectedGuid = selection[1]
            elseif type(selection) == "string" then
                selectedGuid = selection
            end

            if selectedGuid ~= nil then
                -- Selected: show the compact characteristic readout.
                descriptionLabel:SetClass("collapsed", true)
                cardsPanel:SetClass("collapsed", true)
                readoutPanel:SetClass("collapsed", false)
                return
            end

            -- Unselected: show the spread choice cards.
            descriptionLabel.text = choice.description
            descriptionLabel:SetClass("collapsed", false)
            cardsPanel:SetClass("collapsed", false)
            readoutPanel:SetClass("collapsed", true)

            local cards = {}
            for _, opt in ipairs(choice.options) do
                cards[#cards + 1] = gui.Panel{
                    classes = {"crowsChoiceCard"},
                    bgimage = true,
                    width = 210,
                    height = 64,
                    flow = "vertical",
                    borderBox = true,
                    pad = 8,
                    rmargin = 8,
                    bmargin = 8,
                    data = { choiceGuid = choice.guid, optionGuid = opt.guid },

                    click = function(cardElement)
                        B.ChangeHero(function(p)
                            p:GetLevelChoices()[cardElement.data.choiceGuid] = { cardElement.data.optionGuid }
                        end)
                    end,

                    gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 13,
                        bold = true,
                        color = "white",
                        interactable = false,
                        text = opt.name,
                    },
                    gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 11,
                        color = "#bbbbbb",
                        interactable = false,
                        text = "Click to select",
                    },
                }
            end
            cardsPanel.children = cards
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Section 3: Background.
--
-- When no background is set, the d66 roll table (with roll button) is shown.
-- Once chosen, a summary card with a "Confirm Background" button is
-- shown; confirming awards the starting equipment and collapses the card to a
-- single label with a tooltip.
-- ---------------------------------------------------------------------------

-- Select a background without granting its equipment yet. Wipes any stale
-- characteristic choice + inventory + claim/confirm state from a prior
-- background. Granting is deferred to the Confirm step.
local function SelectBackground(props, bgid)
    local B = CrowdexBuilderUI
    local prev = B.GetBackground(props)
    if prev ~= nil then
        local choice = B.BackgroundParts(prev)
        if choice ~= nil then
            props:GetLevelChoices()[choice.guid] = nil
        end
    end
    props.backgroundid = bgid
    props.crowdex_inventory = {}
    props.crowdex_claimedEquipment = nil
    props.crowdex_backgroundConfirmed = nil
end

local function CreateBackgroundSection()
    local B = CrowdexBuilderUI

    -- ---- Selection sub-panel (no background yet) ----

    -- The full d66 background table + roll button, reused from the builder.
    -- The onSelect variant defers granting the starting equipment to the
    -- Confirm step (instead of granting immediately on selection).
    local selectionPanel = B.CreateRollSection(function(props, bgid)
        SelectBackground(props, bgid)
    end)

    -- ---- Summary card (background chosen) ----

    local cardContent = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
    }

    local confirmedLabel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 15,
        bold = true,
        color = "#e8d59a",
        text = "",
        -- Tooltip text is set on refresh; show it on hover.
        data = { tooltip = "" },
        hover = function(element)
            if element.data.tooltip ~= "" then
                gui.Tooltip(element.data.tooltip)(element)
            end
        end,
    }

    local confirmButton = gui.Button{
        text = "Confirm Background",
        halign = "left",
        fontSize = 12,
        tmargin = 10,
        click = function(element)
            B.ChangeHero(function(props)
                CrowdexStartingEquipment.Claim(props)
                props.crowdex_backgroundConfirmed = true
            end)
        end,
    }

    local changeButton = gui.Button{
        text = "Change Background",
        halign = "left",
        fontSize = 12,
        tmargin = 6,
        click = function(element)
            B.ChangeHero(function(props)
                local bg = B.GetBackground(props)
                if bg ~= nil then
                    local choice = B.BackgroundParts(bg)
                    if choice ~= nil then
                        props:GetLevelChoices()[choice.guid] = nil
                    end
                end
                props.backgroundid = nil
                props.crowdex_backgroundConfirmed = nil
            end)
        end,
    }

    local cardPanel = gui.Panel{
        id = "crowsBackgroundCard",
        classes = {"crowsCard"},
        bgimage = true,
        width = "100%",
        maxWidth = 560,
        halign = "left",
        height = "auto",
        flow = "vertical",
        borderBox = true,
        pad = 12,

        confirmedLabel,
        cardContent,
        confirmButton,
        changeButton,
    }

    -- ---- Assembly + state machine ----

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        SheetSectionHeading("Background"),
        selectionPanel,
        cardPanel,

        refreshCharacterInfo = function(element, props)
            local bg = B.GetBackground(props)

            -- No background: show the selector only.
            selectionPanel:SetClass("collapsed", bg ~= nil)
            cardPanel:SetClass("collapsed", bg == nil)
            if bg == nil then return end

            local confirmed = props:try_get("crowdex_backgroundConfirmed", false) == true

            local _, features = B.BackgroundParts(bg)

            if confirmed then
                -- Collapsed: a single label + tooltip; equipment already
                -- awarded. The Change button stays so the choice is editable.
                confirmedLabel:SetClass("collapsed", false)
                cardContent:SetClass("collapsed", true)
                confirmButton:SetClass("collapsed", true)

                confirmedLabel.text = string.format("Background: %s", bg.name)

                local tipLines = {}
                if bg.description ~= nil and bg.description ~= "" then
                    tipLines[#tipLines + 1] = bg.description
                end
                for _, f in ipairs(features) do
                    if f.name ~= nil and f.name ~= "" then
                        tipLines[#tipLines + 1] = string.format("<b>%s</b>", f.name)
                    end
                    if f.description ~= nil and f.description ~= "" then
                        tipLines[#tipLines + 1] = f.description
                    end
                end
                confirmedLabel.data.tooltip = table.concat(tipLines, "\n")
                return
            end

            -- Chosen but not confirmed: show the full summary + Confirm.
            confirmedLabel:SetClass("collapsed", true)
            cardContent:SetClass("collapsed", false)
            confirmButton:SetClass("collapsed", false)

            local children = {}
            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 20,
                bold = true,
                color = "#e8d59a",
                text = bg.name,
            }
            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 13,
                italics = true,
                color = "#bbbbbb",
                bmargin = 8,
                wrap = true,
                text = bg.description,
            }

            for _, f in ipairs(features) do
                children[#children + 1] = gui.Panel{
                    width = "100%",
                    height = "auto",
                    flow = "vertical",
                    bmargin = 6,

                    gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 13,
                        bold = true,
                        color = "white",
                        text = f.name,
                    },
                    gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 12,
                        color = "#cccccc",
                        wrap = true,
                        text = f.description,
                    },
                }
            end

            -- Preview of the gear that Confirm will grant.
            local unclaimed = CrowdexStartingEquipment.UnclaimedItems(props)
            if #unclaimed > 0 then
                local names = {}
                for _, e in ipairs(unclaimed) do
                    if e.quantity > 1 then
                        names[#names + 1] = string.format("%s x%d", e.item.name, e.quantity)
                    else
                        names[#names + 1] = e.item.name
                    end
                end
                children[#children + 1] = gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 11,
                    italics = true,
                    color = "#999999",
                    tmargin = 4,
                    wrap = true,
                    text = string.format("Confirming grants: %s", table.concat(names, ", ")),
                }
            end

            cardContent.children = children
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Section 4: Skills.
-- ---------------------------------------------------------------------------

local function CreateSkillsSection()
    local body
    body = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        refreshCharacterInfo = function(element, props)
            local skills = GetSkills(props)
            local buckets = {
                general      = {},
                spellcasting = {},
                weapon       = {},
            }
            for _, sk in ipairs(skills) do
                local cat = sk.category
                if cat == nil then cat = "general" end
                cat = string.lower(tostring(cat))
                if buckets[cat] == nil then
                    buckets.general[#buckets.general + 1] = sk
                else
                    buckets[cat][#buckets[cat] + 1] = sk
                end
            end

            local children = {}

            local function appendBucket(label, list)
                if #list == 0 then return end
                children[#children + 1] = SheetSubHeading(
                    string.format("%s (%d)", label, #list))
                for _, sk in ipairs(list) do
                    children[#children + 1] = SkillRow(sk.name, sk.bonus)
                end
            end

            appendBucket("General",      buckets.general)
            appendBucket("Spellcasting", buckets.spellcasting)
            appendBucket("Weapon",       buckets.weapon)

            element.children = children
        end,
    }

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        SheetSectionHeading("Skills"),
        body,

        -- Hide the whole section (heading included) until the crow has skills.
        refreshCharacterInfo = function(element, props)
            element:SetClass("collapsed", #GetSkills(props) == 0)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Section 5: Traits.
-- ---------------------------------------------------------------------------

local function CreateTraitsSection()
    local body = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        refreshCharacterInfo = function(element, props)
            local list = GetTraits(props)
            local children = {}
            for _, t in ipairs(list) do
                children[#children + 1] = gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 12,
                    bold = true,
                    color = "white",
                    text = t.name or "Trait",
                    tmargin = 4,
                }
                if t.description ~= nil and t.description ~= "" then
                    children[#children + 1] = gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 11,
                        color = "#cccccc",
                        text = t.description,
                        wrap = true,
                    }
                end
            end
            element.children = children
        end,
    }

    return gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        SheetSectionHeading("Traits"),
        body,

        -- Hide the whole section (heading included) until the crow has traits.
        refreshCharacterInfo = function(element, props)
            element:SetClass("collapsed", #GetTraits(props) == 0)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Tab assembly: two columns inside a full-height host.
-- ---------------------------------------------------------------------------

local function CreateCrowdexSheetTab()
    -- Left column takes all width except the fixed-width inventory on the
    -- right (648) plus margins. A definite "100%-N" width (rather than content
    -- sizing) means a 100%-width child can't blow the column out and shove the
    -- inventory aside, while still leaving room for the wide d66 table.
    local leftColumn = gui.Panel{
        width = "100%-672",
        height = "100%",
        flow = "vertical",
        valign = "top",
        vscroll = true,
        hpad = 12,
        vpad = 12,
        rmargin = 12,
        borderBox = true,

        CreateIdentitySection(),
        CreateCharacteristicsSection(),
        CreateBackgroundSection(),
        CreateSkillsSection(),
        CreateTraitsSection(),
    }

    -- The inventory interface fills the right column and scrolls internally.
    -- It is normally a standalone tab root, so it carries the decorative
    -- characterSheetPanel chrome (flag-bar bg + border); strip that here so it
    -- doesn't double up with the outer sheet root's chrome.
    local inventoryTab = CrowdexInventoryUI.CreateInventoryTab()
    inventoryTab:SetClass("characterSheetPanel", false)

    -- The inventory only needs ~620px (two 280px slot columns + padding), so
    -- pin it to its natural width at the right edge rather than stretching it.
    local rightColumn = gui.Panel{
        width = 648,
        height = "100%",
        flow = "vertical",
        valign = "top",

        inventoryTab,
    }

    return gui.Panel{
        classes = {"characterSheetPanel"},
        width = "100%",
        height = "100%",
        flow = "horizontal",
        valign = "top",

        styles = {
            {
                selectors = {"crowsInput"},
                bgcolor = "#10101a",
                borderWidth = 1,
                borderColor = "#666688",
            },
            {
                selectors = {"crowsInput", "focus"},
                borderColor = "#e8d59a",
            },
            {
                -- A filled field renders as a plain (still-editable) label.
                selectors = {"crowsInput", "entered"},
                bgcolor = "clear",
                borderWidth = 0,
            },
            {
                selectors = {"crowsInput", "entered", "hover"},
                bgcolor = "#1c1c28",
                borderWidth = 1,
                borderColor = "#3a3a4a",
            },
            {
                selectors = {"crowsCard"},
                bgcolor = "#1c1c28",
                borderWidth = 2,
                borderColor = "#e8d59a",
            },
            {
                selectors = {"crowsChoiceCard"},
                bgcolor = "#1c1c28",
                borderWidth = 1,
                borderColor = "#3a3a4a",
            },
            {
                selectors = {"crowsChoiceCard", "hover"},
                bgcolor = "#3a3a5c",
                borderColor = "#aaaaaa",
            },
            {
                selectors = {"crowsBgCell"},
                bgcolor = "#1c1c28",
                borderWidth = 1,
                borderColor = "#3a3a4a",
            },
            {
                selectors = {"crowsBgCell", "hover"},
                bgcolor = "#3a3a5c",
                borderColor = "#e8d59a",
            },
            {
                selectors = {"crowsBgCell", "predicted"},
                bgcolor = "#7a6a2a",
                borderColor = "#ffdd66",
                borderWidth = 2,
                transitionTime = 0.1,
            },
        },

        leftColumn,
        rightColumn,
    }
end

CharSheet.RegisterTab{
    id = "CrowsSheet",
    text = "Sheet",
    order = 1,
    panel = CreateCrowdexSheetTab,
}

-- The Draw Steel tabs we want to remove may not be registered yet (this file
-- can load before them). Defer the deregistration + default-tab assignment
-- until the next scheduler tick so all module-load requires have completed.
dmhub.Schedule(0, function()
    if mod.unloaded then return end

    -- The integrated Crows Sheet supersedes the DS Inventory/Builder/Character
    -- tabs and the standalone Crows Builder tab (now folded into the Sheet).
    -- Crows doesn't use Draw Steel downtime projects, so drop that tab too.
    CharSheet.DeregisterTab("Inventory")
    CharSheet.DeregisterTab("Builder")
    CharSheet.DeregisterTab("CharacterSheet")
    CharSheet.DeregisterTab("CrowsBuilder")
    CharSheet.DeregisterTab("Downtime")

    CharSheet.defaultSheet = "CrowsSheet"

    dmhub.RefreshCharacterSheet()
end)
