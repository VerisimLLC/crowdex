local mod = dmhub.GetModLoading()

-- The Crows character builder tab. Replaces the Draw Steel "Builder" tab
-- (which CrowdexCharacterSheet.lua deregisters) with the much smaller Crows
-- creation flow from the Characters Booklet:
--   1. Roll (or choose) a Background on the d66 table.
--   2. Pick a characteristic spread (the background's CharacterFeatureChoice).
--   3. Record a name and a distinguishing feature.
-- Stamina, skills, and the starting trait flow automatically from the
-- background's features; equipment is listed on the background card.

-- ---------------------------------------------------------------------------
-- The Backgrounds table (Characters Booklet, "Backgrounds Table"). First die
-- selects the row, second die selects the column. The booklet lists "Builder"
-- at 2-6 but contains no Builder entry; its stat block appears under Beggar
-- in the alphabetical listing, so Beggar takes that slot here.
-- ---------------------------------------------------------------------------

local BACKGROUND_TABLE = {
    { "Acolyte of the Gardner", "Acolyte of the Healer", "Acolyte of the Smith", "Acolyte of the Three", "Acolyte of the Warrior", "Alchemist" },
    { "Apprentice Mage", "Archer", "Assassin", "Blacksmith", "Bodyguard", "Beggar" },
    { "Cartographer", "Conjurer", "Cook", "Duelist", "Entertainer", "Executioner" },
    { "Farmer", "Gladiator", "Hunter", "Hydromancer", "Illusionist", "Keraunomancer" },
    { "Knight", "Merchant", "Miner", "Noble", "Pugilist", "Pyromancer" },
    { "Sage", "Soldier", "Thief", "Tinkerer", "Transmuter", "Village Watch" },
}

-- ---------------------------------------------------------------------------
-- Data helpers.
-- ---------------------------------------------------------------------------

local function FindBackgroundByName(name)
    local t = dmhub.GetTable(Background.tableName) or {}
    for k,v in unhidden_pairs(t) do
        if v.name == name then
            return k, v
        end
    end
    return nil, nil
end

local function GetBackground(props)
    if props == nil then return nil end
    local bgid = props:try_get("backgroundid")
    if bgid == nil then return nil end
    local t = dmhub.GetTable(Background.tableName) or {}
    return t[bgid]
end

-- Returns the background's CharacterFeatureChoice (the characteristic spread
-- choice) and a list of its plain features in declaration order.
local function BackgroundParts(bg)
    local choice = nil
    local features = {}
    if bg ~= nil then
        for _,f in ipairs(bg:GetClassLevel().features) do
            if f.typeName == "CharacterFeatureChoice" then
                choice = choice or f
            else
                features[#features+1] = f
            end
        end
    end
    return choice, features
end

-- Build the rich tooltip content shown when hovering a background cell: the
-- name, flavor description, and each plain feature's name + description. Mirrors
-- the background summary card (CreateBackgroundCard) so the hover preview and the
-- selected card read the same.
local function BuildBackgroundTooltipContent(bg)
    local _, features = BackgroundParts(bg)

    local children = {}
    children[#children+1] = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 18,
        bold = true,
        color = "#e8d59a",
        text = bg.name,
        interactable = false,
    }

    if bg.description ~= nil and bg.description ~= "" then
        children[#children+1] = gui.Label{
            width = "100%",
            height = "auto",
            fontSize = 12,
            italics = true,
            color = "#bbbbbb",
            bmargin = 6,
            text = bg.description,
            interactable = false,
        }
    end

    for _,f in ipairs(features) do
        children[#children+1] = gui.Label{
            width = "100%",
            height = "auto",
            fontSize = 12,
            bold = true,
            color = "white",
            text = f.name,
            interactable = false,
        }
        if f.description ~= nil and f.description ~= "" then
            children[#children+1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 11,
                color = "#cccccc",
                bmargin = 4,
                text = f.description,
                interactable = false,
            }
        end
    end

    return gui.Panel{
        width = 340,
        height = "auto",
        flow = "vertical",
        pad = 10,
        borderBox = true,
        interactable = false,
        children = children,
    }
end

local function GetHeroToken()
    if CharacterSheet.instance == false or CharacterSheet.instance == nil or not CharacterSheet.instance.valid then
        return nil
    end
    return CharacterSheet.instance.data.info.token
end

-- Mutate the hero inside the character sheet. The sheet owns the upload
-- lifecycle, so we modify properties directly and fire refreshAll, which
-- invalidates the creature and re-fires refreshCharacterInfo down the tree.
local function ChangeHero(fn)
    local token = GetHeroToken()
    if token == nil or token.properties == nil then return end
    fn(token.properties, token)
    CharacterSheet.instance:FireEvent("refreshAll")
end

-- ---------------------------------------------------------------------------
-- Small shared widgets, matching the CrowdexCharacterSheet idiom.
-- ---------------------------------------------------------------------------

local function SectionHeading(text)
    return gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 16,
        bold = true,
        color = "#e8d59a",
        text = text,
        tmargin = 14,
        bmargin = 4,
    }
end

local function SectionText(text)
    return gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 12,
        color = "#bbbbbb",
        text = text,
        bmargin = 6,
    }
end

-- ---------------------------------------------------------------------------
-- Section 1a: the roll panel (shown while no background is set).
-- ---------------------------------------------------------------------------

local CELL_WIDTH = 150
local CELL_HEIGHT = 30

-- onSelect(props, bgid) is called inside ChangeHero when a background is
-- picked (by click or by roll). It defaults to the builder behavior: set the
-- background id and grant its starting equipment immediately. The integrated
-- character sheet passes a variant that defers granting to a Confirm step.
local function CreateRollSection(onSelect)
    onSelect = onSelect or function(props, bgid)
        props.backgroundid = bgid
        local t = dmhub.GetTable(Background.tableName) or {}
        CrowdexStartingEquipment.InitializeFromBackground(props, t[bgid])
    end

    local resultPanel
    local sectionPanel

    -- Cells indexed by [row][col] so the live dice prediction can highlight
    -- the cell the tumbling dice currently point at.
    local m_cells = {}

    -- A single clickable cell of the d66 grid.
    local function TableCell(row, col)
        local name = BACKGROUND_TABLE[row][col]
        local cell = gui.Panel{
            classes = {"crowsBgCell"},
            bgimage = true,
            width = CELL_WIDTH,
            height = CELL_HEIGHT,
            halign = "left",
            valign = "center",
            borderBox = true,
            hpad = 6,
            data = { name = name },

            click = function(element)
                local bgid = FindBackgroundByName(element.data.name)
                if bgid == nil then return end
                ChangeHero(function(props)
                    onSelect(props, bgid)
                end)
            end,

            linger = function(element)
                local _, bg = FindBackgroundByName(element.data.name)
                if bg ~= nil then
                    element.tooltip = gui.TooltipFrame(BuildBackgroundTooltipContent(bg), {
                        halign = "right",
                        valign = "center",
                    })
                else
                    element.tooltip = gui.TooltipFrame(gui.Label{
                        text = string.format("Choose %s", element.data.name),
                        width = "auto",
                        height = "auto",
                        fontSize = 14,
                        color = "white",
                        interactable = false,
                    })
                end
            end,

            gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 11,
                color = "#dddddd",
                halign = "left",
                valign = "center",
                interactable = false,
                text = name,
            },
        }
        m_cells[row] = m_cells[row] or {}
        m_cells[row][col] = cell
        return cell
    end

    -- Header row: blank corner + second-die faces.
    local headerCells = {
        gui.Panel{ width = 30, height = CELL_HEIGHT },
    }
    for col = 1,6 do
        headerCells[#headerCells+1] = gui.Label{
            width = CELL_WIDTH,
            height = CELL_HEIGHT,
            fontSize = 12,
            bold = true,
            color = "#e8d59a",
            textAlignment = "center",
            valign = "center",
            text = tostring(col),
        }
    end

    local gridRows = {
        gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            children = headerCells,
        },
    }

    for row = 1,6 do
        local cells = {
            gui.Label{
                width = 30,
                height = CELL_HEIGHT,
                fontSize = 12,
                bold = true,
                color = "#e8d59a",
                textAlignment = "center",
                valign = "center",
                text = tostring(row),
            },
        }
        for col = 1,6 do
            cells[#cells+1] = TableCell(row, col)
        end
        gridRows[#gridRows+1] = gui.Panel{
            width = "auto",
            height = "auto",
            flow = "horizontal",
            children = cells,
        }
    end

    local grid = gui.Panel{
        width = "auto",
        height = "auto",
        flow = "vertical",
        halign = "left",
        tmargin = 6,
        children = gridRows,
    }

    resultPanel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 13,
        color = "white",
        text = "",
        tmargin = 6,
    }

    local rollButton
    rollButton = gui.Button{
        text = "Roll 2d6 for Background",
        halign = "left",
        fontSize = 14,
        data = { rolling = false },

        click = function(element)
            if element.data.rolling then return end
            local token = GetHeroToken()
            if token == nil then return end
            element.data.rolling = true

            dmhub.Roll{
                roll = "2d6",
                description = "Background Roll",
                tokenid = token.charid,

                -- While the dice tumble, listen for diceface events so the
                -- grid can highlight the cell the dice currently predict.
                begin = function(rollInfo)
                    if mod.unloaded then return end
                    if sectionPanel == nil or not sectionPanel.valid then return end
                    sectionPanel.data.dicefaces = {}
                    sectionPanel.data.rolls = rollInfo.rolls
                    sectionPanel.data.predictedCell = nil
                    for _,roll in ipairs(rollInfo.rolls or {}) do
                        chat.DiceEvents(roll.guid):Listen(sectionPanel)
                    end
                end,

                complete = function(rollInfo)
                    if mod.unloaded then return end
                    if rollButton ~= nil and rollButton.valid then
                        rollButton.data.rolling = false
                    end

                    if sectionPanel ~= nil and sectionPanel.valid then
                        for _,roll in ipairs(sectionPanel.data.rolls or {}) do
                            chat.DiceEvents(roll.guid):Unlisten(sectionPanel)
                        end
                        sectionPanel.data.rolls = nil
                        local predicted = sectionPanel.data.predictedCell
                        if predicted ~= nil and predicted.valid then
                            predicted:SetClass("predicted", false)
                        end
                        sectionPanel.data.predictedCell = nil
                    end

                    -- First die is the table row, second die is the column.
                    local dice = {}
                    for _,roll in ipairs(rollInfo.rolls or {}) do
                        if not roll.dropped then
                            dice[#dice+1] = roll.result
                        end
                    end
                    if #dice < 2 then return end
                    local row = math.max(1, math.min(6, dice[1]))
                    local col = math.max(1, math.min(6, dice[2]))
                    local name = BACKGROUND_TABLE[row][col]

                    if resultPanel ~= nil and resultPanel.valid then
                        resultPanel.text = string.format("Rolled %d and %d: <b>%s</b>", row, col, name)
                    end

                    local bgid = FindBackgroundByName(name)
                    if bgid == nil then return end
                    ChangeHero(function(props)
                        onSelect(props, bgid)
                    end)
                end,
            }
        end,
    }

    sectionPanel = gui.Panel{
        id = "crowsRollSection",
        width = "100%",
        height = "auto",
        flow = "vertical",
        data = {
            dicefaces = {},
            rolls = nil,
            predictedCell = nil,
        },

        SectionText("You weren't always a crow. Roll 2d6 to find out who you were: the first die picks the row, the second picks the column. (Or click a background to choose it directly.)"),
        rollButton,
        resultPanel,
        grid,
        gui.Label{
            width = "100%",
            height = "auto",
            fontSize = 10,
            italics = true,
            color = "#888888",
            tmargin = 4,
            text = "The playtest table lists \"Builder\" at 2-6; its entry appears as Beggar, which is used here.",
        },

        refreshCharacterInfo = function(element, props)
            element:SetClass("collapsed", GetBackground(props) ~= nil)
        end,

        -- Fired by chat.DiceEvents while the dice are rolling: num is the
        -- face the die is currently showing. Once every die has a known
        -- face, light up the cell that result would land on.
        diceface = function(element, diceguid, num, timeRemaining)
            local data = element.data
            if data.rolls == nil then return end
            data.dicefaces[diceguid] = num

            local faces = {}
            for _,roll in ipairs(data.rolls) do
                local f = data.dicefaces[roll.guid]
                if f == nil then return end
                faces[#faces+1] = f
            end
            if #faces < 2 then return end

            local row = math.max(1, math.min(6, faces[1]))
            local col = math.max(1, math.min(6, faces[2]))
            local cell = m_cells[row] and m_cells[row][col]

            local previous = data.predictedCell
            if previous ~= nil and previous ~= cell and previous.valid then
                previous:SetClass("predicted", false)
            end
            if cell ~= nil and cell.valid then
                cell:SetClass("predicted", true)
            end
            data.predictedCell = cell

            if resultPanel ~= nil and resultPanel.valid then
                resultPanel.text = string.format("Rolling... %d and %d: %s", row, col, BACKGROUND_TABLE[row][col])
            end
        end,
    }

    return sectionPanel
end

-- ---------------------------------------------------------------------------
-- Section 1b: the background summary card (shown once a background is set).
-- ---------------------------------------------------------------------------

local function CreateBackgroundCard()
    local content = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
    }

    return gui.Panel{
        id = "crowsBackgroundCard",
        classes = {"crowsCard"},
        bgimage = true,
        width = "95%",
        height = "auto",
        flow = "vertical",
        borderBox = true,
        pad = 12,

        content,

        gui.Button{
            text = "Change Background",
            halign = "left",
            fontSize = 12,
            tmargin = 10,
            click = function(element)
                ChangeHero(function(props)
                    local bg = GetBackground(props)
                    if bg ~= nil then
                        -- drop the stale characteristic selection for this background
                        local choice = BackgroundParts(bg)
                        if choice ~= nil then
                            props:GetLevelChoices()[choice.guid] = nil
                        end
                    end
                    props.backgroundid = nil
                end)
            end,
        },

        refreshCharacterInfo = function(element, props)
            local bg = GetBackground(props)
            element:SetClass("collapsed", bg == nil)
            if bg == nil then return end

            local _, features = BackgroundParts(bg)

            local children = {}
            children[#children+1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 20,
                bold = true,
                color = "#e8d59a",
                text = bg.name,
            }
            children[#children+1] = gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 13,
                italics = true,
                color = "#bbbbbb",
                bmargin = 8,
                text = bg.description,
            }

            for _,f in ipairs(features) do
                children[#children+1] = gui.Panel{
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
                        text = f.description,
                    },
                }
            end

            -- Starting equipment: when the background's features carry
            -- Starting Equipment modifiers (CrowdexModifiers.lua), offer a
            -- one-time claim that drops the listed gear into the crow's
            -- inventory slots.
            local hasEquipmentGrant = false
            for _,f in ipairs(features) do
                for _,m in ipairs(f:try_get("modifiers", {})) do
                    if m.behavior == "startingequipment" then
                        hasEquipmentGrant = true
                    end
                end
            end

            if hasEquipmentGrant then
                local unclaimed = CrowdexStartingEquipment.UnclaimedItems(props)
                if #unclaimed > 0 then
                    local names = {}
                    for _,e in ipairs(unclaimed) do
                        if e.quantity > 1 then
                            names[#names+1] = string.format("%s x%d", e.item.name, e.quantity)
                        else
                            names[#names+1] = e.item.name
                        end
                    end
                    children[#children+1] = gui.Button{
                        text = "Claim Starting Equipment",
                        halign = "left",
                        fontSize = 12,
                        tmargin = 4,
                        hover = function(buttonElement)
                            gui.Tooltip(string.format("Adds to your inventory: %s", table.concat(names, ", ")))(buttonElement)
                        end,
                        click = function()
                            ChangeHero(function(p)
                                CrowdexStartingEquipment.Claim(p)
                            end)
                        end,
                    }
                else
                    children[#children+1] = gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 11,
                        italics = true,
                        color = "#88aa88",
                        tmargin = 4,
                        text = "Starting equipment claimed.",
                    }
                end
            end

            content.children = children
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Section 2: characteristic spread choice.
-- ---------------------------------------------------------------------------

local function CreateCharacteristicsSection()
    local descriptionLabel = gui.Label{
        width = "100%",
        height = "auto",
        fontSize = 12,
        color = "#bbbbbb",
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

    return gui.Panel{
        id = "crowsCharacteristicsSection",
        width = "100%",
        height = "auto",
        flow = "vertical",

        SectionHeading("2. Characteristics"),
        descriptionLabel,
        cardsPanel,

        refreshCharacterInfo = function(element, props)
            local bg = GetBackground(props)
            local choice = nil
            if bg ~= nil then
                choice = BackgroundParts(bg)
            end
            element:SetClass("collapsed", choice == nil)
            if choice == nil then return end

            descriptionLabel.text = choice.description

            local selection = props:GetLevelChoices()[choice.guid]
            local selectedGuid = nil
            if type(selection) == "table" then
                selectedGuid = selection[1]
            elseif type(selection) == "string" then
                selectedGuid = selection
            end

            local cards = {}
            for _,opt in ipairs(choice.options) do
                local selected = (opt.guid == selectedGuid)
                cards[#cards+1] = gui.Panel{
                    classes = {"crowsChoiceCard", cond(selected, "selected")},
                    bgimage = true,
                    width = 220,
                    height = 64,
                    flow = "vertical",
                    borderBox = true,
                    pad = 8,
                    rmargin = 8,
                    bmargin = 8,
                    data = { choiceGuid = choice.guid, optionGuid = opt.guid },

                    click = function(cardElement)
                        ChangeHero(function(p)
                            p:GetLevelChoices()[cardElement.data.choiceGuid] = { cardElement.data.optionGuid }
                        end)
                    end,

                    gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 13,
                        bold = true,
                        color = cond(selected, "#e8d59a", "white"),
                        interactable = false,
                        text = opt.name,
                    },
                    gui.Label{
                        width = "100%",
                        height = "auto",
                        fontSize = 11,
                        color = "#bbbbbb",
                        interactable = false,
                        text = cond(selected, "Selected", "Click to select"),
                    },
                }
            end

            cardsPanel.children = cards
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Section 3: name and distinguishing feature.
-- ---------------------------------------------------------------------------

local function CreateIdentitySection()
    return gui.Panel{
        id = "crowsIdentitySection",
        width = "100%",
        height = "auto",
        flow = "vertical",

        SectionHeading("3. Name and Feature"),
        SectionText("Give your crow a name and one distinguishing feature: a tattoo, a distinct body odor, a unique voice, a strong personality trait. Just one thing that stands out."),

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            valign = "top",

            gui.Panel{
                width = 280,
                height = "auto",
                flow = "vertical",
                rmargin = 20,

                gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 11,
                    bold = true,
                    color = "#aaaaaa",
                    text = "NAME",
                    bmargin = 2,
                },
                gui.Label{
                    classes = {"crowsInput"},
                    bgimage = true,
                    width = "100%",
                    height = 34,
                    fontSize = 14,
                    color = "white",
                    valign = "center",
                    editable = true,
                    characterLimit = 30,
                    borderBox = true,
                    hpad = 6,
                    text = "",

                    refreshCharacterInfo = function(element, props)
                        local token = GetHeroToken()
                        if token ~= nil then
                            element.text = token.name or ""
                        end
                    end,

                    change = function(element)
                        local token = GetHeroToken()
                        if token == nil then return end
                        token.name = element.text
                        token:UploadAppearance()
                    end,
                },
            },

            gui.Panel{
                width = 420,
                height = "auto",
                flow = "vertical",

                gui.Label{
                    width = "100%",
                    height = "auto",
                    fontSize = 11,
                    bold = true,
                    color = "#aaaaaa",
                    text = "DISTINGUISHING FEATURE",
                    bmargin = 2,
                },
                gui.Label{
                    classes = {"crowsInput"},
                    bgimage = true,
                    width = "100%",
                    height = 34,
                    fontSize = 14,
                    color = "white",
                    valign = "center",
                    editable = true,
                    characterLimit = 100,
                    borderBox = true,
                    hpad = 6,
                    text = "",

                    refreshCharacterInfo = function(element, props)
                        element.text = props:try_get("crowdex_distinguishingFeature", "") or ""
                    end,

                    change = function(element)
                        ChangeHero(function(props)
                            props.crowdex_distinguishingFeature = element.text
                        end)
                    end,
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Tab assembly.
-- ---------------------------------------------------------------------------

local function CreateCrowdexBuilderTab()
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
            text = "Crow Creation",
            bmargin = 2,
        },
        SectionText("It also might be a dying, but you knew the risks when you became a crow."),

        SectionHeading("1. Background"),
        CreateRollSection(),
        CreateBackgroundCard(),
        CreateCharacteristicsSection(),
        CreateIdentitySection(),
    }

    return gui.Panel{
        classes = {"characterSheetPanel"},
        width = "100%",
        height = "100%",
        flow = "vertical",
        valign = "top",
        vscroll = true,

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
                selectors = {"crowsChoiceCard", "selected"},
                bgcolor = "#2a2a44",
                borderColor = "#e8d59a",
                borderWidth = 2,
            },
        },

        content,
    }
end

CharSheet.RegisterTab{
    id = "CrowsBuilder",
    text = "Builder",
    order = 2,
    panel = CreateCrowdexBuilderTab,
}

-- Shared with the integrated Crows character sheet (CrowdexCharacterSheet.lua),
-- which folds these builder steps (identity, characteristics, background) into
-- the main Sheet tab. Exposing the small data helpers + the background table
-- lets the sheet reuse the same mutation logic without duplicating it.
CrowdexBuilderUI = {
    FindBackgroundByName = FindBackgroundByName,
    GetBackground = GetBackground,
    BackgroundParts = BackgroundParts,
    GetHeroToken = GetHeroToken,
    ChangeHero = ChangeHero,
    BACKGROUND_TABLE = BACKGROUND_TABLE,
    CreateRollSection = CreateRollSection,
}
