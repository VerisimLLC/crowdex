local mod = dmhub.GetModLoading()

-- The Crows "Sheet" tab. This is the single integrated character surface:
-- the creation flow (name + feature, characteristics, background) folds into
-- the same screen that shows expertises, traits, and the inventory. There is no
-- separate Builder tab any more (it is deregistered below).
--
-- Layout: a two-column row inside a full-height host.
--   Left column (scrolls):  identity, characteristics, background, expertises,
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

local function GetExpertises(props)
    if props == nil then return {} end
    -- Expertises are resource pools granted by the background, not a stored
    -- property. See creature:CrowdexExpertises in CrowdexRules.lua.
    local result = {}
    pcall(function() result = props:CrowdexExpertises() or {} end)
    return result
end

local function GetTraits(props)
    if props == nil then return {} end
    if CrowdexTraits ~= nil and CrowdexTraits.OwnedTraits ~= nil then
        return CrowdexTraits.OwnedTraits(props)
    end

    -- Compatibility fallback while loading older data that predates the trait
    -- catalog. The background's inline trait is display-only; current data
    -- resolves it to the canonical Crows Trait record above.
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
        tmargin = 10,
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

-- One expertise: its name, and how many uses are left of its maximum. An
-- expertise is spent after a roll to improve the result by one tier, so what
-- matters on the sheet is what remains, not a bonus.
local function ExpertiseRow(exp)
    local remaining = exp.remaining or 0
    local usesText = string.format("%d/%d", remaining, exp.max or 0)
    local spent = remaining <= 0

    local tooltip = exp.description or ""
    if exp.suppressed then
        tooltip = tooltip .. "\nExpertises are currently suppressed."
    else
        tooltip = tooltip .. "\nAfter an applicable test, spend one use to improve the result by one tier (maximum tier 3; one expertise per test)."
    end

    return gui.Panel{
        width = 320,
        height = "auto",
        flow = "horizontal",
        valign = "center",
        vmargin = 1,

        gui.Label{
            width = "auto-grow",
            height = "auto",
            fontSize = 12,
            halign = "left",
            text = exp.name or "",
            color = cond(spent, "#8a8a8a", "#dddddd"),
        },
        -- Keep the usage controls in a fixed-width cell. Conditional buttons
        -- can collapse without moving this cell, so every count and Use button
        -- lines up across the section.
        gui.Panel{
            width = 126,
            height = 20,
            flow = "horizontal",
            halign = "right",
            valign = "center",

            gui.Label{
                width = 36,
                height = "auto",
                fontSize = 12,
                color = cond(spent, "#8a8a8a", "white"),
                halign = "right",
                textAlignment = "right",
                text = usesText,
            },
            gui.Button{
                text = "Use",
                width = 40,
                height = 20,
                fontSize = 10,
                lmargin = 4,
                classes = {cond(remaining > 0 and not exp.suppressed, nil, "collapsed")},
                click = function()
                    if CrowdexBuilderUI == nil then return end
                    CrowdexBuilderUI.ChangeHero(function(props)
                        local info = CrowdexExpertise.FindById(exp.id)
                        if info ~= nil and CrowdexExpertise.Available(props, exp.id) > 0 then
                            props:ConsumeResource(exp.id, info.resource:try_get("usageLimit", "long"), 1,
                                "Manual expertise use")
                        end
                    end)
                end,
            },
            gui.Button{
                text = "Undo",
                width = 40,
                height = 20,
                fontSize = 10,
                lmargin = 2,
                classes = {cond((exp.used or 0) > 0, nil, "collapsed")},
                click = function()
                    if CrowdexBuilderUI == nil then return end
                    CrowdexBuilderUI.ChangeHero(function(props)
                        local info = CrowdexExpertise.FindById(exp.id)
                        if info ~= nil then
                            props:RefreshResource(exp.id, info.resource:try_get("usageLimit", "long"), 1,
                                "Refund expertise use")
                        end
                    end)
                end,
            },
        },
        linger = gui.Tooltip{
            text = tooltip,
            maxWidth = 420,
        },
    }
end

local function ShowExpertiseAdvancementDialog(props, bonus)
    if props == nil or bonus == nil then return end

    local allocation = {}
    local kind = "expertise"
    local dialogPanel
    local contentPanel

    local function RequiredExpertise()
        if kind == "expertise" then return 3 end
        if kind == "mixed" then return 1 end
        return 0
    end

    local function StaminaAward()
        if kind == "stamina" then return 2 end
        if kind == "mixed" then return 1 end
        return 0
    end

    local function AllocatedTotal()
        local result = 0
        for _, quantity in pairs(allocation) do result = result + quantity end
        return result
    end

    local function RefreshDialog()
        local required = RequiredExpertise()
        local allocated = AllocatedTotal()
        local cap = CrowdexAdvancement.MaxExpertiseUses(CrowdexAdvancement.RestedXP(props))
        local children = {
            gui.Label{
                classes = {"dialogTitle"},
                text = string.format("Advancement at %d TXP", bonus.threshold),
            },
            gui.Label{
                width = "100%",
                height = "auto",
                wrap = true,
                color = "#cccccc",
                text = "Choose 3 expertise uses, +2 Stamina, or 1 expertise use and +1 Stamina. Expertise uses can create a new expertise, but cannot exceed the TXP cap.",
            },
            gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                tmargin = 8,
                gui.Label{
                    width = 150,
                    height = 24,
                    valign = "center",
                    text = "Advancement choice:",
                },
                gui.Dropdown{
                    width = 260,
                    height = 24,
                    idChosen = kind,
                    options = {
                        { id = "expertise", text = "3 Expertise Uses" },
                        { id = "stamina", text = "+2 Stamina" },
                        { id = "mixed", text = "1 Expertise Use and +1 Stamina" },
                    },
                    change = function(element)
                        kind = element.idChosen
                        allocation = {}
                        RefreshDialog()
                    end,
                },
            },
        }

        if required > 0 then
            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                bold = true,
                color = cond(allocated == required, "#aaffaa", "#e8d59a"),
                text = string.format("Allocate uses: %d/%d (maximum %d in one expertise)", allocated, required, cap),
                tmargin = 8,
                bmargin = 4,
            }

            for _, expertise in ipairs(CrowdexExpertise.Catalog()) do
                local current = CrowdexAdvancement.PermanentExpertiseMaximum(props, expertise.id)
                local added = allocation[expertise.id] or 0
                children[#children + 1] = gui.Panel{
                    width = "100%",
                    height = 24,
                    flow = "horizontal",
                    valign = "center",
                    gui.Label{
                        width = "auto-grow",
                        height = "auto",
                        text = expertise.name,
                        color = "#dddddd",
                        linger = gui.Tooltip{
                            text = expertise.description,
                            maxWidth = 420,
                        },
                    },
                    gui.Label{
                        width = 70,
                        height = "auto",
                        textAlignment = "right",
                        text = string.format("%d/%d", current + added, cap),
                    },
                    gui.Button{
                        text = "-",
                        width = 28,
                        height = 20,
                        fontSize = 14,
                        classes = {cond(added > 0, nil, "collapsed")},
                        click = function()
                            allocation[expertise.id] = math.max(0, (allocation[expertise.id] or 0) - 1)
                            RefreshDialog()
                        end,
                    },
                    gui.Button{
                        text = "+",
                        width = 28,
                        height = 20,
                        fontSize = 14,
                        lmargin = 2,
                        classes = {cond(allocated < required and current + added < cap, nil, "collapsed")},
                        click = function()
                            allocation[expertise.id] = (allocation[expertise.id] or 0) + 1
                            RefreshDialog()
                        end,
                    },
                }
            end
        else
            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                color = "#aaffaa",
                text = "+2 maximum Stamina",
                tmargin = 10,
            }
        end

        local errorLabel = gui.Label{
            width = "100%",
            height = "auto",
            color = "#ff8888",
            wrap = true,
            text = "",
            tmargin = 6,
        }
        children[#children + 1] = errorLabel
        children[#children + 1] = gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            tmargin = 8,
            gui.Button{
                text = "Cancel",
                width = 120,
                click = function() gui.CloseModal() end,
            },
            gui.Button{
                text = "Confirm",
                width = 160,
                lmargin = 8,
                classes = {cond(allocated == required, nil, "collapsed")},
                click = function()
                    local success = false
                    local errorText = nil
                    CrowdexBuilderUI.ChangeHero(function(hero)
                        success, errorText = CrowdexAdvancement.Claim(hero, bonus.index, {
                            kind = kind,
                            stamina = StaminaAward(),
                            expertises = allocation,
                        })
                    end)
                    if success then
                        gui.CloseModal()
                    else
                        errorLabel.text = errorText or "Unable to claim this advancement."
                    end
                end,
            },
        }

        contentPanel.children = children
    end

    contentPanel = gui.Panel{
        width = "100%",
        height = "auto",
        maxHeight = 720,
        flow = "vertical",
        vscroll = true,
        pad = 12,
        borderBox = true,
    }

    dialogPanel = gui.Panel{
        width = 620,
        height = "auto",
        maxHeight = 780,
        classes = {"framedPanel"},
        contentPanel,
    }
    RefreshDialog()
    gui.ShowModal(dialogPanel)
end

local function ShowCharacteristicAdvancementDialog(props, bonus)
    if props == nil or bonus == nil then return end

    local allAtMaximum = props:AttributeMod("agility") >= 4
        and props:AttributeMod("mind") >= 4
        and props:AttributeMod("strength") >= 4
    local errorLabel = gui.Label{
        width = "100%",
        height = "auto",
        color = "#ff8888",
        wrap = true,
        text = "",
        tmargin = 6,
    }

    local children = {
        gui.Label{
            classes = {"dialogTitle"},
            text = string.format("Characteristic Advancement at %d TXP", bonus.threshold),
        },
        gui.Label{
            width = "100%",
            height = "auto",
            wrap = true,
            color = "#cccccc",
            text = cond(allAtMaximum,
                "All three characteristics are already 4. This advancement grants +2 maximum Stamina instead.",
                "Increase one characteristic by 1, to a maximum of 4."),
            bmargin = 8,
        },
    }

    local choices = cond(allAtMaximum, {
        { id = "stamina", label = "+2 Stamina", value = 0 },
    }, {
        { id = "mind", label = "Mind", value = props:AttributeMod("mind") },
        { id = "agility", label = "Agility", value = props:AttributeMod("agility") },
        { id = "strength", label = "Strength", value = props:AttributeMod("strength") },
    })

    for _, choice in ipairs(choices) do
        local disabled = choice.id ~= "stamina" and choice.value >= 4
        children[#children + 1] = gui.Panel{
            width = "100%",
            height = 30,
            flow = "horizontal",
            valign = "center",
            gui.Label{
                width = "auto-grow",
                height = "auto",
                text = cond(choice.id == "stamina", choice.label,
                    string.format("%s  %s  %s", choice.label, ModifierStr(choice.value), ModifierStr(choice.value + 1))),
                color = cond(disabled, "#777777", "#dddddd"),
            },
            gui.Button{
                width = 120,
                height = 24,
                fontSize = 11,
                text = cond(choice.id == "stamina", "Take +2 Stamina", "Increase"),
                classes = {cond(disabled, "collapsed", nil)},
                click = function()
                    local success = false
                    local errorText = nil
                    CrowdexBuilderUI.ChangeHero(function(hero)
                        success, errorText = CrowdexAdvancement.ClaimCharacteristic(hero, bonus.index, choice.id)
                    end)
                    if success then
                        gui.CloseModal()
                    else
                        errorLabel.text = errorText or "Unable to claim this characteristic advancement."
                    end
                end,
            },
        }
    end
    children[#children + 1] = errorLabel
    children[#children + 1] = gui.Button{
        width = 120,
        height = 24,
        text = "Cancel",
        tmargin = 8,
        click = function() gui.CloseModal() end,
    }

    gui.ShowModal(gui.Panel{
        width = 520,
        height = "auto",
        maxHeight = 620,
        classes = {"framedPanel"},
        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            pad = 12,
            borderBox = true,
            children = children,
        },
    })
end

local function ShowTraitPurchaseDialog(props)
    if props == nil or CrowdexTraits == nil then return end
    local catalog = CrowdexTraits.Catalog()
    if #catalog == 0 then return end

    local treeOptions = {}
    local seenTrees = {}
    for _, trait in ipairs(catalog) do
        if not seenTrees[trait.tree] then
            seenTrees[trait.tree] = true
            treeOptions[#treeOptions + 1] = { id = trait.tree, text = trait.tree }
        end
    end

    local ownedTraits = CrowdexTraits.OwnedTraits(props)
    local selectedTree = treeOptions[1].id
    if #ownedTraits > 0 then selectedTree = ownedTraits[1].tree end
    local contentPanel

    -- ShowModal reparents this subtree at the global modal layer, so it cannot
    -- inherit the character sheet's style cascade. Keep the custom rules small
    -- and merge them with the shared theme so framedPanel, buttons, dropdowns,
    -- visibility classes, fonts, and scheme tokens all resolve correctly.
    local dialogStyles = {
        {
            selectors = {"buyTraitsTitle"},
            width = "100%",
            halign = "left",
            textAlignment = "left",
            tmargin = 0,
            bmargin = 6,
            fontSize = 26,
        },
        {
            selectors = {"buyTraitsBalanceLabel"},
            color = "@fgMuted",
            fontSize = 12,
        },
        {
            selectors = {"buyTraitsBalance"},
            color = "@fgStrong",
            fontSize = 16,
            bold = true,
        },
        {
            selectors = {"buyTraitsHelp"},
            color = "@fgMuted",
            fontSize = 12,
        },
        {
            selectors = {"buyTraitsFieldLabel"},
            color = "@fgMuted",
            fontSize = 12,
            bold = true,
        },
        {
            selectors = {"buyTraitsDivider"},
            bgimage = true,
            bgcolor = "@border",
            opacity = 0.35,
        },
        {
            selectors = {"buyTraitsCard"},
            bgimage = true,
            bgcolor = "@bgAlt",
            borderWidth = 1,
            borderColor = "@border",
        },
        {
            selectors = {"buyTraitsCard", "owned"},
            borderColor = "@accent",
        },
        {
            selectors = {"buyTraitsName"},
            color = "@fg",
            fontSize = 15,
            bold = true,
        },
        {
            selectors = {"buyTraitsName", "owned"},
            color = "@fgStrong",
        },
        {
            selectors = {"buyTraitsCost"},
            color = "@fgMuted",
            fontSize = 12,
        },
        {
            selectors = {"buyTraitsStatus"},
            color = "@fgMuted",
            fontSize = 12,
            bold = true,
        },
        {
            selectors = {"buyTraitsStatus", "owned"},
            color = "@fgStrong",
        },
        {
            selectors = {"buyTraitsDescription"},
            color = "@fg",
            fontSize = 12,
        },
        {
            selectors = {"buyTraitsPrerequisite"},
            color = "@fgMuted",
            fontSize = 10,
            italics = true,
        },
    }

    local function PrerequisiteText(trait)
        if trait.starting then return "Starting trait: always available to buy." end
        local names = {}
        for _, id in ipairs(trait.prerequisites) do
            local prerequisite = CrowdexTraits.FindById(id)
            if prerequisite ~= nil then names[#names + 1] = prerequisite.name end
        end
        if #names == 0 then return "No connected prerequisite is recorded." end
        return "Requires any connected trait: " .. table.concat(names, ", ")
    end

    local function RefreshDialog()
        local owned = CrowdexTraits.OwnedTraitIds(props)
        local spendableXP = CrowdexAdvancement.SpendableXP(props)

        local headerPanel = gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",

            gui.Label{
                classes = {"modalTitle", "buyTraitsTitle"},
                text = "Buy Crows Traits",
            },
            gui.Panel{
                width = "100%",
                height = 24,
                flow = "horizontal",
                valign = "center",
                gui.Label{
                    classes = {"buyTraitsBalanceLabel"},
                    width = "auto-grow",
                    height = "auto",
                    text = "Available after the last completed rest",
                },
                gui.Label{
                    classes = {"buyTraitsBalance", "number"},
                    width = 110,
                    height = "auto",
                    textAlignment = "right",
                    text = string.format("%d XP", spendableXP),
                },
            },
            gui.Label{
                classes = {"buyTraitsHelp"},
                width = "100%",
                height = "auto",
                wrap = true,
                text = "Starting traits can be bought freely. Other traits require any connected trait in the same tree.",
                bmargin = 10,
            },
            gui.Panel{
                width = "100%",
                height = 32,
                flow = "horizontal",
                valign = "center",
                gui.Label{
                    classes = {"buyTraitsFieldLabel"},
                    width = 82,
                    height = "auto",
                    text = "Trait tree:",
                },
                gui.Dropdown{
                    width = 300,
                    height = 30,
                    fontSize = 13,
                    idChosen = selectedTree,
                    options = treeOptions,
                    change = function(element)
                        selectedTree = element.idChosen
                        RefreshDialog()
                    end,
                },
            },
            gui.Panel{
                classes = {"buyTraitsDivider"},
                width = "100%",
                height = 1,
                tmargin = 8,
                bmargin = 10,
            },
        }

        local traitCards = {}
        for _, trait in ipairs(catalog) do
            if trait.tree == selectedTree then
                local canPurchase, reason = CrowdexTraits.CanPurchase(props, trait.id)
                local isOwned = owned[trait.id] ~= nil
                traitCards[#traitCards + 1] = gui.Panel{
                    classes = {"buyTraitsCard", cond(isOwned, "owned", nil)},
                    width = "100%",
                    height = "auto",
                    flow = "vertical",
                    pad = 12,
                    bmargin = 6,
                    borderBox = true,
                    gui.Panel{
                        width = "100%",
                        height = 30,
                        flow = "horizontal",
                        valign = "center",
                        gui.Label{
                            classes = {"buyTraitsName", cond(isOwned, "owned", nil)},
                            width = "auto-grow",
                            height = "auto",
                            text = trait.name,
                        },
                        gui.Label{
                            classes = {"buyTraitsCost", "number"},
                            width = 72,
                            height = "auto",
                            textAlignment = "right",
                            text = string.format("%d XP", trait.cost),
                        },
                        gui.Button{
                            classes = {"sizeS", cond(canPurchase, nil, "collapsed")},
                            width = 90,
                            lmargin = 12,
                            text = "Buy",
                            click = function()
                                local success = false
                                CrowdexBuilderUI.ChangeHero(function(hero)
                                    success = CrowdexTraits.Purchase(hero, trait.id)
                                end)
                                if success then gui.CloseModal() end
                            end,
                        },
                        gui.Label{
                            classes = {"buyTraitsStatus", cond(isOwned, "owned", nil), cond(canPurchase, "collapsed", nil)},
                            width = 90,
                            height = "auto",
                            lmargin = 12,
                            textAlignment = "right",
                            text = cond(isOwned, owned[trait.id], "Locked"),
                            linger = gui.Tooltip{
                                text = cond(isOwned, "This crow already owns this trait.", reason or "Unavailable."),
                                maxWidth = 360,
                            },
                        },
                    },
                    gui.Label{
                        classes = {"buyTraitsDescription"},
                        width = "100%",
                        height = "auto",
                        wrap = true,
                        text = trait.description,
                        bmargin = 4,
                    },
                    gui.Label{
                        classes = {"buyTraitsPrerequisite"},
                        width = "100%",
                        height = "auto",
                        wrap = true,
                        text = PrerequisiteText(trait),
                    },
                }
            end
        end

        local listPanel = gui.Panel{
            width = "100%",
            height = "100%-190",
            flow = "vertical",
            vscroll = true,
            rpad = 8,
            borderBox = true,
            children = traitCards,
        }

        local footerPanel = gui.Panel{
            width = "100%",
            height = 46,
            flow = "horizontal",
            halign = "right",
            valign = "bottom",
            tmargin = 10,
            gui.Button{
                classes = {"sizeM"},
                width = 120,
                text = "Close",
                escapeActivates = true,
                escapePriority = EscapePriority.EXIT_MODAL_DIALOG,
                click = function() gui.CloseModal() end,
            },
        }

        contentPanel.children = {headerPanel, listPanel, footerPanel}
    end

    contentPanel = gui.Panel{
        width = "100%",
        height = "100%",
        flow = "vertical",
    }
    RefreshDialog()
    gui.ShowModal(gui.Panel{
        styles = ThemeEngine.MergeStyles(dialogStyles),
        classes = {"framedPanel", "buyTraitsDialog"},
        width = 760,
        maxWidth = "92%",
        height = 780,
        maxHeight = "90%",
        halign = "center",
        valign = "center",
        floating = true,
        flow = "vertical",
        pad = 20,
        borderBox = true,
        contentPanel,
    })
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
        width = 252,
        height = "auto",
        flow = "horizontal",
        wrap = true,
        halign = "left",
        children = readoutBoxes,
    }

    local charContent = gui.Panel{
        width = 440,
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
                charContent.selfStyle.width = 440
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
                charContent.selfStyle.width = 252
                descriptionLabel:SetClass("collapsed", true)
                cardsPanel:SetClass("collapsed", true)
                readoutPanel:SetClass("collapsed", false)
                return
            end

            -- Unselected: show the spread choice cards.
            charContent.selfStyle.width = 440
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
                    if e.quantityLabel ~= nil then
                        names[#names + 1] = string.format("%s %s", e.item.name, e.quantityLabel)
                    elseif e.quantity > 1 then
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
-- Section 4: Expertises.
--
-- Playtest 2 replaced skills with expertises: a pool of uses spent after a
-- roll to improve its result by one tier, refreshed on a rest. So each row
-- shows uses remaining rather than a bonus, and a spent expertise dims rather
-- than disappearing -- you still want to see you have it.
-- ---------------------------------------------------------------------------

local function CreateExpertisesSection()
    local body
    body = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        refreshCharacterInfo = function(element, props)
            local buckets = { General = {}, Spellcasting = {}, Weapon = {} }
            for _, exp in ipairs(GetExpertises(props)) do
                local list = buckets[exp.category] or buckets.General
                list[#list + 1] = exp
            end

            local children = {}

            local totalXP = CrowdexAdvancement.TotalXP(props)
            local spentXP = CrowdexAdvancement.SpentXP(props)
            local restedXP = CrowdexAdvancement.RestedXP(props)
            local unclaimed = CrowdexAdvancement.UnclaimedBonuses(props)
            local unclaimedCharacteristics = CrowdexAdvancement.UnclaimedCharacteristicBonuses(props)

            local function XPInput(label, value, field, helpText)
                return gui.Panel{
                    width = "auto",
                    height = 24,
                    flow = "horizontal",
                    valign = "center",
                    rmargin = 10,
                    gui.Label{
                        width = "auto",
                        height = "auto",
                        text = label,
                        fontSize = 11,
                        color = "#aaaaaa",
                    },
                    gui.Input{
                        width = 70,
                        height = 22,
                        lmargin = 4,
                        fontSize = 12,
                        textAlignment = "right",
                        characterLimit = 8,
                        text = tostring(value),
                        change = function(input)
                            local n = math.max(0, math.floor(tonumber(input.text) or value))
                            input.text = tostring(n)
                            CrowdexBuilderUI.ChangeHero(function(hero)
                                hero[field] = n
                            end)
                        end,
                    },
                    linger = gui.Tooltip{
                        text = helpText,
                        maxWidth = 360,
                    },
                }
            end

            local function XPReadout(label, value, helpText)
                return gui.Label{
                    width = "auto",
                    height = 24,
                    valign = "center",
                    fontSize = 11,
                    color = "#aaaaaa",
                    text = string.format("%s: %d", label, value),
                    rmargin = 12,
                    linger = gui.Tooltip{
                        text = helpText,
                        maxWidth = 360,
                    },
                }
            end

            local advancementChildren = {
                XPInput("TXP", totalXP, "crowdex_totalXP",
                    "Total XP: all XP this crow has ever earned. TXP never decreases when XP is spent."),
                XPReadout("Spent", spentXP,
                    "XP spent on traits. This is calculated from the purchase ledger and cannot be edited directly."),
                XPReadout("Rested", restedXP,
                    "TXP recorded at the last completed rest. Advancement and trait purchases use this rested amount."),
                XPReadout("Available", CrowdexAdvancement.SpendableXP(props),
                    "Rested TXP minus XP spent on traits. XP earned since the last rest is not spendable yet."),
            }
            if #unclaimed > 0 then
                local nextBonus = unclaimed[1]
                advancementChildren[#advancementChildren + 1] = gui.Button{
                    width = 170,
                    height = 24,
                    fontSize = 11,
                    text = string.format("Claim %d TXP Bonus", nextBonus.threshold),
                    click = function()
                        ShowExpertiseAdvancementDialog(props, nextBonus)
                    end,
                }
            end
            if #unclaimedCharacteristics > 0 then
                local nextBonus = unclaimedCharacteristics[1]
                advancementChildren[#advancementChildren + 1] = gui.Button{
                    width = 190,
                    height = 24,
                    fontSize = 11,
                    text = string.format("Increase Characteristic (%d)", nextBonus.threshold),
                    click = function()
                        ShowCharacteristicAdvancementDialog(props, nextBonus)
                    end,
                }
            end
            if #unclaimed == 0 and #unclaimedCharacteristics == 0 and totalXP > restedXP then
                advancementChildren[#advancementChildren + 1] = gui.Label{
                    width = 170,
                    height = "auto",
                    fontSize = 10,
                    italics = true,
                    color = "#999999",
                    textAlignment = "right",
                    text = "Finish a rest to unlock earned bonuses.",
                }
            end

            children[#children + 1] = gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                wrap = true,
                valign = "center",
                bmargin = 5,
                children = advancementChildren,
            }

            children[#children + 1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 10,
                color = "#888888",
                wrap = true,
                text = "After an applicable test, spend one use to improve the result by one tier (maximum tier 3; one expertise per test). A completed rest restores all uses.",
                bmargin = 3,
            }

            local function appendBucket(label, list)
                if #list == 0 then return end
                children[#children + 1] = SheetSubHeading(label)
                for _, exp in ipairs(list) do
                    children[#children + 1] = ExpertiseRow(exp)
                end
            end

            appendBucket("General",      buckets.General)
            appendBucket("Spellcasting", buckets.Spellcasting)
            appendBucket("Weapon",       buckets.Weapon)

            element.children = children
        end,
    }

    return gui.Panel{
        width = 500,
        height = "auto",
        flow = "vertical",

        SheetSectionHeading("Expertises"),
        body,

        -- Hide the whole section (heading included) until the crow has one.
        refreshCharacterInfo = function(element, props)
            element:SetClass("collapsed", #GetExpertises(props) == 0)
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
            local children = {
                gui.Panel{
                    width = 500,
                    height = 26,
                    flow = "horizontal",
                    valign = "center",
                    bmargin = 3,
                    gui.Label{
                        width = "auto-grow",
                        height = "auto",
                        fontSize = 10,
                        color = "#888888",
                        text = string.format("%d owned  |  %d XP available after rest", #list, CrowdexAdvancement.SpendableXP(props)),
                    },
                    gui.Button{
                        width = 100,
                        height = 22,
                        fontSize = 10,
                        text = "Buy Traits",
                        click = function() ShowTraitPurchaseDialog(props) end,
                    },
                },
            }
            for _, t in ipairs(list) do
                children[#children + 1] = gui.Panel{
                    width = "100%",
                    height = "auto",
                    tmargin = 4,
                    flow = "horizontal",
                    valign = "center",
                    gui.Label{
                        width = "auto-grow",
                        height = "auto",
                        fontSize = 12,
                        bold = true,
                        color = "white",
                        text = t.name or "Trait",
                    },
                    gui.Label{
                        width = 190,
                        height = "auto",
                        fontSize = 9,
                        color = "#888888",
                        textAlignment = "right",
                        text = string.format("%s tree  |  %s", t.tree or "Trait", t.grantedBy or "Owned"),
                    },
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
        width = 600,
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
    -- The character area uses two deliberate content columns instead of one
    -- enormous flexible column. At normal desktop widths identity/background
    -- sit beside characteristics/expertises/traits; at narrower widths the
    -- secondary column wraps below. Before a background is chosen, the primary
    -- column temporarily expands for the 930px d66 table and the secondary
    -- column naturally wraps.
    local primaryColumn = gui.Panel{
        width = 560,
        height = "auto",
        flow = "vertical",
        valign = "top",
        rmargin = 16,

        CreateIdentitySection(),
        CreateBackgroundSection(),

        refreshCharacterInfo = function(element, props)
            local bg = CrowdexBuilderUI.GetBackground(props)
            element.selfStyle.width = cond(bg == nil, 930, 560)
        end,
    }

    local secondaryColumn = gui.Panel{
        width = 620,
        height = "auto",
        flow = "vertical",
        valign = "top",

        CreateCharacteristicsSection(),
        CreateExpertisesSection(),
        CreateTraitsSection(),
    }

    local detailsGrid = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "horizontal",
        wrap = true,
        halign = "left",
        valign = "top",

        primaryColumn,
        secondaryColumn,
    }

    -- Character details take all width except the fixed-width inventory on the
    -- right. A definite "100%-N" width prevents the d66 table or any 100%-width
    -- child from pushing the inventory off screen.
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

        detailsGrid,
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
