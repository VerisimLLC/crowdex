local mod = dmhub.GetModLoading()

-- Crows: Campaign Tracker extensions.
-- ----------------------------------
-- The Crowdex module is only loaded for Crows games, so anything registered
-- here automatically scopes itself to Crows -- no game-system gate is needed.
--
-- This file hooks custom sections into the shared Campaign Tracker panel via
-- CampaignTracker.RegisterSection (see DocumentSystem/CampaignTrackerPanel.lua).
--
-- Dungeon Turn timer
-- ------------------
-- A 30-minute countdown for the Crows "Dungeon Turn". State lives in a synced
-- document so every client sees the same timer:
--   running   -- bool: is the clock ticking?
--   endTime   -- server time (dmhub.serverTime) at which it hits zero; only
--                meaningful while running. Players compute their own remaining
--                from this against the synced clock, so the bar needs no
--                per-second network writes.
--   remaining -- seconds left, recorded whenever the timer is paused/adjusted.
--   duration  -- the full length the bar is measured against (the 30 minutes).
--
-- The Director sees the numeric time, play/pause, and manual adjust controls
-- and is the sole authority that runs the countdown and detects expiry. Players
-- see only the countdown bar. On expiry the Director shows a "Dungeon Turn"
-- dramatic banner (itself synced to every client) and fires a "Dungeon Turn"
-- custom creature trigger on every creature -- heroes and monsters alike -- so
-- abilities can react.

local DUNGEON_TURN_DOC = "crowdex_dungeon_turn"
local DUNGEON_TURN_DURATION = 30 * 60   -- 30 minutes, in seconds.
local DUNGEON_TURN_TRIGGER = "Dungeon Turn"
local DUNGEON_TURN_ACCENT = "#e8c264"   -- amber, matching the dramatic banner.

mod:RegisterDocumentForCheckpointBackups(DUNGEON_TURN_DOC)

-- Campaign mode
-- ------------
-- A synced enumerated mode (Wilderness / Town / Dungeon) for the whole table.
-- The Director picks it; players see the current value read-only. The Dungeon
-- Turn controls below are only shown while the mode is Dungeon. State lives in
-- its own synced document so every client agrees on the current mode.
local CAMPAIGN_MODE_DOC = "crowdex_campaign_mode"
local MODE_WILDERNESS = "wilderness"
local MODE_TOWN = "town"
local MODE_DUNGEON = "dungeon"
local MODE_DEFAULT = MODE_WILDERNESS
local MODE_OPTIONS = {
    { id = MODE_WILDERNESS, text = "Wilderness" },
    { id = MODE_TOWN, text = "Town" },
    { id = MODE_DUNGEON, text = "Dungeon" },
}

mod:RegisterDocumentForCheckpointBackups(CAMPAIGN_MODE_DOC)

-- Wilderness travel
-- -----------------
-- Shown while the mode is Wilderness (Director only). The Director assigns each
-- crow on the map a travel role, prompts the role's test, and tracks the day's
-- Encounter Number (EN). State is synced so role assignments and EN persist and
-- show on every Director client.
--   route       -- "known" / "unknown"; selects which Guide test table is used.
--   enBase      -- the day's base EN (default 6; the Ref lowers it for monster-
--                  dense areas per the travel rules).
--   enScout     -- adjustment applied by the Scout's prompted roll: -2 / -1 / 0
--                  for a tier 1 / 2 / 3 result. The displayed EN is enBase+enScout.
--   roles       -- map of token id -> role id for the crows on the map.
local WILDERNESS_DOC = "crowdex_wilderness"
local ROUTE_KNOWN = "known"
local ROUTE_UNKNOWN = "unknown"
local ROUTE_DEFAULT = ROUTE_KNOWN
local ROUTE_OPTIONS = {
    { id = ROUTE_KNOWN, text = "Known Route" },
    { id = ROUTE_UNKNOWN, text = "Unknown Route" },
}

local EN_DEFAULT = 6
local EN_MIN = 1
local EN_MAX = 6

-- Base overland pace (Rules Booklet: 12 miles a day). A Guide tier-3 result lets
-- the group travel up to 50% further; a tier-1 on an unknown route gets them lost.
local BASE_PACE_MILES = 12

-- Custom creature trigger fired on each crow by the Miasma Check button. The
-- imported "Miasma" global rule (compendium/import/crows-rule-miasma-check.yaml)
-- reacts to it and prompts that crow's miasma test.
local MIASMA_TRIGGER = "Miasma Check"

-- Weather. At the start of each travel day the Ref rolls 1d6 on the table for
-- the current climate/season (Rules Booklet, "Weather"). The season is a Ref
-- setting (the climate the group is traveling in); the weather is re-rolled each
-- day. SEASON_WEATHER maps a 1d6 result to the weather for each season.
local SEASON_DEFAULT = "spring"
local SEASON_OPTIONS = {
    { id = "winter", text = "Cold of Winter" },
    { id = "desert", text = "Desert" },
    { id = "fall", text = "Fall" },
    { id = "spring", text = "Spring" },
    { id = "summer", text = "Summer / Tropical" },
}
local SEASON_WEATHER = {
    winter = function(d) if d == 1 then return "Blizzard" elseif d == 6 then return "Snow" else return "Cold" end end,
    desert = function(d) if d <= 4 then return "Heat Wave (day) and Cold (night)" elseif d == 5 then return "Sandstorm" else return "Thunderstorm" end end,
    fall = function(d) if d == 1 then return "Fog" elseif d == 6 then return "Rain" else return "Pleasant" end end,
    spring = function(d) if d <= 4 then return "Pleasant" elseif d == 5 then return "Rain" else return "Thunderstorm" end end,
    summer = function(d) if d == 1 then return "Heat Wave" elseif d <= 4 then return "Pleasant" elseif d == 5 then return "Rain" else return "Thunderstorm" end end,
}

-- Travel roles. "guide" and "scout" are the required roles (red warning when
-- unassigned); any number of crows can be foragers or leaders.
local ROLE_NONE = "none"
local ROLE_GUIDE = "guide"
local ROLE_SCOUT = "scout"
local ROLE_FORAGER = "forager"
local ROLE_LEADER = "leader"
local ROLE_OPTIONS = {
    { id = ROLE_NONE, text = "--" },
    { id = ROLE_GUIDE, text = "Guide" },
    { id = ROLE_SCOUT, text = "Scout" },
    { id = ROLE_FORAGER, text = "Forager" },
    { id = ROLE_LEADER, text = "Leader" },
}

-- Crows skill ids used by the role tests, resolved by name at runtime (with the
-- imported GUID as a fallback) so a game with a re-imported skill table still
-- works. Only the Guide test adds a skill (Navigate).
local NAVIGATE_SKILL_NAME = "Navigate"
local NAVIGATE_SKILL_GUID = "afe54dc8-11a0-4535-9fb1-9757abc94b4e"

-- Per-role power-roll tier text (tier 1 / 2 / 3), surfaced on the prompted roll
-- so the player and Director see the role's outcomes. The Guide has two tables
-- depending on whether the route is known.
local GUIDE_TIERS_KNOWN = {
    "The group moves at their normal pace toward the destination.",
    "Normal pace, and the route gives the scout and any foragers a +2 bonus on their role tests today.",
    "As tier 2, and the group can travel up to 50% further during the initial travel without a test to push.",
}
local GUIDE_TIERS_UNKNOWN = {
    "The group gets lost.",
    "The group moves at their normal pace toward the destination.",
    "Normal pace, and the route gives the scout and any foragers a +2 bonus on their role tests today.",
}
local SCOUT_TIERS = {
    "The day's EN decreases by 2.",
    "The day's EN decreases by 1.",
    "The day's EN remains the same.",
}
local FORAGER_TIERS = {
    "The forager finds no food.",
    "The forager procures 1 ration.",
    "The forager procures 3 rations.",
}
local LEADER_TIERS = {
    "The leader provides no bonus to their allies.",
    "The leader's allies gain a +1 bonus to tests made to resist the Miasma.",
    "As tier 2, except the bonus is +2.",
}

mod:RegisterDocumentForCheckpointBackups(WILDERNESS_DOC)

----------------------------------------------------------------------
-- Document accessors / state math.
----------------------------------------------------------------------

local function GetDoc()
    return mod:GetDocumentSnapshot(DUNGEON_TURN_DOC)
end

local function GetModeDoc()
    return mod:GetDocumentSnapshot(CAMPAIGN_MODE_DOC)
end

-- Current synced mode, falling back to the default for a fresh document or any
-- unrecognized stored value.
local function GetMode()
    local mode = GetModeDoc().data.mode
    if mode == MODE_WILDERNESS or mode == MODE_TOWN or mode == MODE_DUNGEON then
        return mode
    end
    return MODE_DEFAULT
end

-- Director-only: write the new mode, syncing it to every client.
local function SetMode(mode)
    local doc = GetModeDoc()
    doc:BeginChange()
    doc.data.mode = mode
    doc:CompleteChange("Set campaign mode", {undoable = false})
end

----------------------------------------------------------------------
-- Wilderness travel state (synced).
----------------------------------------------------------------------

local function GetWildernessDoc()
    return mod:GetDocumentSnapshot(WILDERNESS_DOC)
end

local function GetRoute()
    local route = GetWildernessDoc().data.route
    if route == ROUTE_KNOWN or route == ROUTE_UNKNOWN then
        return route
    end
    return ROUTE_DEFAULT
end

local function SetRoute(route)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.route = route
    doc:CompleteChange("Set travel route", {undoable = false})
end

local function GetEnBase()
    local n = GetWildernessDoc().data.enBase
    if type(n) ~= "number" then return EN_DEFAULT end
    return math.max(EN_MIN, math.min(EN_MAX, math.floor(n)))
end

-- Scout adjustment, clamped to the [-2, 0] range the Scout test can produce.
local function GetEnScout()
    local n = GetWildernessDoc().data.enScout
    if type(n) ~= "number" then return 0 end
    return math.max(-2, math.min(0, math.floor(n)))
end

-- The day's EN as displayed: base plus the Scout adjustment, clamped.
local function GetEffectiveEn()
    return math.max(EN_MIN, math.min(EN_MAX, GetEnBase() + GetEnScout()))
end

local function SetEnBase(n)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.enBase = math.max(EN_MIN, math.min(EN_MAX, math.floor(n)))
    doc:CompleteChange("Set encounter number", {undoable = false})
end

local function SetEnScout(adjust)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.enScout = math.max(-2, math.min(0, math.floor(adjust)))
    doc:CompleteChange("Scout adjusted encounter number", {undoable = false})
end

local function GetRole(tokenid)
    local roles = GetWildernessDoc().data.roles
    if type(roles) ~= "table" then return ROLE_NONE end
    return roles[tokenid] or ROLE_NONE
end

local function SetRole(tokenid, roleId)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    if type(doc.data.roles) ~= "table" then
        doc.data.roles = {}
    end
    if roleId == ROLE_NONE then
        doc.data.roles[tokenid] = nil
    else
        doc.data.roles[tokenid] = roleId
    end
    doc:CompleteChange("Assign travel role", {undoable = false})
end

-- The encounter table (a RollTable id in the "encounterTables" table) chosen for
-- this area, or "" for none.
local ENCOUNTER_TABLES = "encounterTables"

local function GetEncounterTableId()
    return GetWildernessDoc().data.encounterTableId or ""
end

local function SetEncounterTableId(id)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.encounterTableId = id or ""
    doc:CompleteChange("Set encounter table", {undoable = false})
end

-- Climate/season the group is traveling in (drives the weather table).
local function GetSeason()
    local s = GetWildernessDoc().data.season
    if SEASON_WEATHER[s] ~= nil then return s end
    return SEASON_DEFAULT
end

local function SetSeason(season)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.season = season
    doc:CompleteChange("Set season", {undoable = false})
end

-- The day's rolled weather (a display string), or "" before it is rolled.
local function GetWeather()
    return GetWildernessDoc().data.weather or ""
end

local function SetWeather(weather)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.weather = weather or ""
    doc:CompleteChange("Set weather", {undoable = false})
end

local function GetDay()
    local n = GetWildernessDoc().data.day
    if type(n) ~= "number" or n < 1 then return 1 end
    return math.floor(n)
end

-- The Guide's most recent roll tier for the day (1/2/3), or nil if not yet
-- rolled. Drives the travel-distance display.
local function GetGuideTier()
    local n = GetWildernessDoc().data.guideTier
    if n == 1 or n == 2 or n == 3 then return n end
    return nil
end

local function SetGuideTier(tier)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.guideTier = tier
    doc:CompleteChange("Guide roll set travel pace", {undoable = false})
end

-- Advance to the next travel day: bump the counter and clear the per-day roll
-- outcomes (Scout EN adjustment, Guide pace, and the day's weather) so they are
-- re-rolled. Season and role assignments persist as sensible defaults.
local function AdvanceDay()
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.day = GetDay() + 1
    doc.data.enScout = 0
    doc.data.guideTier = nil
    doc.data.weather = ""
    doc:CompleteChange("End of day", {undoable = false})
end

----------------------------------------------------------------------
-- Role roll prompts.
----------------------------------------------------------------------

-- Resolve the Navigate skill id from the Skills table by name, falling back to
-- the imported GUID if a name match isn't found.
local function ResolveNavigateSkillId()
    local skills = dmhub.GetTable(Skill.tableName) or {}
    for id, skill in pairs(skills) do
        if skill ~= nil and skill.name == NAVIGATE_SKILL_NAME then
            return id
        end
    end
    return NAVIGATE_SKILL_GUID
end

-- Map a power-roll total to its Crows tier: 11 or lower = 1, 12-16 = 2, 17+ = 3.
local function TierFromResult(total)
    if type(total) ~= "number" then return nil end
    if total <= 11 then return 1 end
    if total <= 16 then return 2 end
    return 3
end

-- Build the list of RollChecks for a role. Roles that allow a choice of
-- characteristic ("A or M", "A or S") return one check per option so the
-- prompted player can pick; the Guide adds the Navigate skill and uses the
-- known/unknown tier table per the current route.
local function BuildRoleChecks(roleId, route)
    if roleId == ROLE_GUIDE then
        local tiers = cond(route == ROUTE_UNKNOWN, GUIDE_TIERS_UNKNOWN, GUIDE_TIERS_KNOWN)
        return {
            RollCheck.new{
                type = "test_power_roll",
                id = "mind",
                text = "Mind",
                options = { skills = { ResolveNavigateSkillId() }, tiers = tiers },
            },
        }
    elseif roleId == ROLE_SCOUT then
        return {
            RollCheck.new{ type = "test_power_roll", id = "agility", text = "Agility", options = { tiers = SCOUT_TIERS } },
            RollCheck.new{ type = "test_power_roll", id = "mind", text = "Mind", options = { tiers = SCOUT_TIERS } },
        }
    elseif roleId == ROLE_FORAGER then
        return {
            RollCheck.new{ type = "test_power_roll", id = "agility", text = "Agility", options = { tiers = FORAGER_TIERS } },
            RollCheck.new{ type = "test_power_roll", id = "strength", text = "Strength", options = { tiers = FORAGER_TIERS } },
        }
    elseif roleId == ROLE_LEADER then
        return {
            RollCheck.new{ type = "test_power_roll", id = "mind", text = "Mind", options = { tiers = LEADER_TIERS } },
        }
    end
    return nil
end

local function RoleDisplayName(roleId)
    for _, opt in ipairs(ROLE_OPTIONS) do
        if opt.id == roleId then return opt.text end
    end
    return roleId
end

-- Send the role's test to the crow's controlling player and show the Director a
-- result summary. Returns the action request id (or nil if the role has no
-- test), so a Scout prompt can be watched to auto-apply its EN adjustment.
local function PromptRoleRoll(token, roleId, route)
    local checks = BuildRoleChecks(roleId, route)
    if checks == nil then return nil end

    local actionid = dmhub.SendActionRequest(RollRequest.new{
        title = string.format("%s -- %s", token.name or "Crow", RoleDisplayName(roleId)),
        checks = checks,
        tokens = { [token.id] = {} },
        dicetower = false,
    })
    gamehud:ShowRollSummaryDialog(actionid)
    return actionid
end

----------------------------------------------------------------------
-- Encounter check + encounter table roll.
----------------------------------------------------------------------

-- {id, text} options for every encounter table in the compendium, sorted by
-- name, with a leading "None" entry.
local function GetEncounterTableOptions()
    local options = { { id = "", text = "None" } }
    local tables = dmhub.GetTable(ENCOUNTER_TABLES) or {}
    for id, tbl in pairs(tables) do
        options[#options + 1] = { id = id, text = tbl.name or "(unnamed table)" }
    end
    table.sort(options, function(a, b)
        if a.id == "" then return true end
        if b.id == "" then return false end
        return a.text < b.text
    end)
    return options
end

-- Render a rolled VariantCollection to a flat string. We avoid the engine's
-- VariantCollection:ToString(), which errors when an entry's quantity is a dice
-- expression string rather than a number; instead each item is stringified and
-- its quantity rolled for display.
local function RenderRolledCollection(coll)
    local parts = {}
    for _, item in ipairs(coll.items or {}) do
        local ok, s = pcall(function() return item:ToString() end)
        if ok and s ~= nil and s ~= "" then
            if item:HasQuantity() then
                local okq, qn = pcall(function() return item:RollQuantity() end)
                if okq and type(qn) == "number" and qn > 1 then
                    s = string.format("%s x %d", s, qn)
                end
            end
            parts[#parts + 1] = s
        end
    end
    if #parts == 0 then return "(no result)" end
    return table.concat(parts, ", ")
end

-- Render the row a table's dice total landed on (used to echo the dialog's
-- rolled outcome inline).
local function RenderRolledRow(t, total)
    local idx = t:RowIndexFromDiceResult(total)
    if idx == nil or t.rows[idx] == nil then return "(no result)" end
    return RenderRolledCollection(t.rows[idx].value)
end

-- Open the standard animated roll dialog (gamehud.rollDialog) to roll on an
-- encounter table -- the same dialog used for ability/skill rolls. No PC token
-- is needed for a table roll. onResult(total, text) fires when accepted.
local function ShowEncounterTableRoll(tableId, onResult)
    local tbl = (dmhub.GetTable(ENCOUNTER_TABLES) or {})[tableId]
    if tbl == nil then return end
    local ref = RollTableReference.CreateRef(ENCOUNTER_TABLES, tableId)
    gamehud.rollDialog.data.ShowDialog{
        tableRef = ref,
        completeRoll = function(rollInfo)
            if onResult ~= nil then
                onResult(rollInfo.total, RenderRolledRow(tbl, rollInfo.total))
            end
        end,
    }
end

-- How far the group can travel today, adjusted by the Guide's roll (Rules
-- Booklet "Guide"): tier 3 -> 50% further; tier 1 on an unknown route -> lost.
local function GetTravelDistanceText()
    local tier = GetGuideTier()
    if tier == nil then
        return string.format("%d miles (base pace; roll the Guide)", BASE_PACE_MILES)
    end
    if tier == 1 and GetRoute() == ROUTE_UNKNOWN then
        return "Lost -- no progress toward the destination."
    end
    if tier == 3 then
        return string.format("%d miles (Guide tier 3: +50%%)", math.floor(BASE_PACE_MILES * 1.5))
    end
    return string.format("%d miles (normal pace)", BASE_PACE_MILES)
end

-- Fire the Miasma Check custom trigger on every crow on the map. Each crow's
-- imported "Miasma" global rule reacts and prompts that player's miasma test.
-- Returns the number of crows prompted.
local function FireMiasmaCheck()
    local crows = dmhub.GetTokens({ playerControlled = true })
    for _, tok in ipairs(crows) do
        if tok ~= nil and tok.valid and tok.properties ~= nil then
            tok.properties:DispatchEvent("custom", { triggername = MIASMA_TRIGGER, triggervalue = 0 })
        end
    end
    return #crows
end

-- Map a 1d6 weather roll to the weather for a season (Rules Booklet tables).
local function WeatherForRoll(season, d6)
    local fn = SEASON_WEATHER[season] or SEASON_WEATHER[SEASON_DEFAULT]
    return fn(d6)
end

local function SeasonDisplayName(season)
    for _, opt in ipairs(SEASON_OPTIONS) do
        if opt.id == season then return opt.text end
    end
    return season
end

local function GetDuration(data)
    return data.duration or DUNGEON_TURN_DURATION
end

-- Seconds left on the timer right now, derived from the synced state. While
-- running this is endTime minus the synced clock; while paused it is the
-- recorded remaining; a brand-new document starts at the full duration.
local function ComputeRemaining(data)
    if data.running then
        return math.max(0, (data.endTime or dmhub.serverTime) - dmhub.serverTime)
    end
    if data.remaining ~= nil then
        return math.max(0, data.remaining)
    end
    return GetDuration(data)
end

local function FormatTime(seconds)
    -- ceil so the clock reads 30:00 at the top and only shows 0:00 at the end.
    seconds = math.max(0, math.ceil(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Parse Director-typed time. Accepts "mm:ss" (e.g. "12:30") or a bare number of
-- minutes (e.g. "30" or "7.5"). Returns seconds, or nil if unparseable.
local function ParseTime(text)
    if text == nil then return nil end
    text = text:gsub("%s+", "")
    local m, s = text:match("^(%d+):(%d+)$")
    if m ~= nil then
        return tonumber(m) * 60 + tonumber(s)
    end
    local n = tonumber(text)
    if n ~= nil then
        return n * 60
    end
    return nil
end

----------------------------------------------------------------------
-- Director-only mutators. Each wraps the document write in
-- BeginChange/CompleteChange so the new state syncs to every client.
----------------------------------------------------------------------

local function StartTimer()
    local doc = GetDoc()
    local remaining = ComputeRemaining(doc.data)
    -- Stopped at zero: the Director must add time before it can run again.
    if remaining <= 0 then return end
    doc:BeginChange()
    doc.data.duration = GetDuration(doc.data)
    doc.data.remaining = remaining
    doc.data.running = true
    doc.data.endTime = dmhub.serverTime + remaining
    doc:CompleteChange("Start Dungeon Turn timer", {undoable = false})
end

local function PauseTimer()
    local doc = GetDoc()
    local remaining = ComputeRemaining(doc.data)
    doc:BeginChange()
    doc.data.running = false
    doc.data.remaining = remaining
    doc.data.endTime = nil
    doc:CompleteChange("Pause Dungeon Turn timer", {undoable = false})
end

-- Set the remaining time to an explicit value (clamped to [0, duration]),
-- recomputing endTime when the timer is running so it keeps ticking smoothly.
local function SetRemaining(seconds)
    local doc = GetDoc()
    local duration = GetDuration(doc.data)
    seconds = math.max(0, math.min(duration, seconds))
    doc:BeginChange()
    doc.data.duration = duration
    doc.data.remaining = seconds
    if doc.data.running then
        if seconds <= 0 then
            doc.data.running = false
            doc.data.endTime = nil
        else
            doc.data.endTime = dmhub.serverTime + seconds
        end
    end
    doc:CompleteChange("Adjust Dungeon Turn timer", {undoable = false})
end

local function ResetTimer()
    local doc = GetDoc()
    doc:BeginChange()
    doc.data.duration = DUNGEON_TURN_DURATION
    doc.data.remaining = DUNGEON_TURN_DURATION
    doc.data.running = false
    doc.data.endTime = nil
    doc:CompleteChange("Reset Dungeon Turn timer", {undoable = false})
end

-- The timer reached zero: stop it (held at 0:00 until the Director adjusts).
local function StopAtZero()
    local doc = GetDoc()
    doc:BeginChange()
    doc.data.running = false
    doc.data.remaining = 0
    doc.data.endTime = nil
    doc:CompleteChange("Dungeon Turn expired", {undoable = false})
end

-- Fire everything that happens when a Dungeon Turn ends. Run on the Director's
-- client only. The banner is itself a synced document, so every client sees it;
-- DispatchEvent routes each creature trigger to that token's controlling client,
-- so every creature on the map -- heroes and monsters alike -- receives the
-- "Dungeon Turn" custom trigger.
local function FireDungeonTurnExpiry()
    if DramaticBanner ~= nil and DramaticBanner.Show ~= nil then
        DramaticBanner.Show{
            text = "Dungeon Turn",
        }
    end

    for _, tok in ipairs(dmhub.GetTokens()) do
        if tok ~= nil and tok.valid and tok.properties ~= nil then
            tok.properties:DispatchEvent("custom", {
                triggername = DUNGEON_TURN_TRIGGER,
                triggervalue = 0,
            })
        end
    end
end

----------------------------------------------------------------------
-- Small round icon button (play / pause), styled like the audio play chip.
----------------------------------------------------------------------

local function TimerIconButton(args)
    local icon = gui.Panel{
        bgimage = args.icon,
        bgcolor = "white",
        width = "58%",
        height = "58%",
        halign = "center",
        valign = "center",
        interactable = false,
    }

    return gui.Panel{
        classes = args.classes,
        width = 22,
        height = 22,
        cornerRadius = 11,
        valign = "center",
        bgcolor = args.color,
        bgimage = "panels/square.png",
        borderWidth = 1,
        borderColor = "#ffffff55",
        styles = {
            { selectors = {"hover"}, brightness = 1.2, transitionTime = 0.1 },
            { selectors = {"press"}, brightness = 0.6 },
            { selectors = {"hidden"}, hidden = 1 },
        },
        linger = args.tooltip ~= nil and gui.Tooltip(args.tooltip) or nil,
        press = args.press,
        icon,
    }
end

----------------------------------------------------------------------
-- Mode selector. For the Director it is an interactive enumerated slider
-- that writes the synced mode; for players it is the same themed visual
-- rendered read-only (interactable=false does not cascade to the option
-- labels, so players get a press-less row built from the same classes).
-- Either way the returned panel responds to FireEvent("setMode", mode) to
-- reflect the current synced value.
----------------------------------------------------------------------

local function CreateModeSelector(isDM)
    if isDM then
        return gui.EnumeratedSliderControl{
            options = MODE_OPTIONS,
            value = GetMode(),
            width = "100%",
            valign = "center",
            change = function(element)
                SetMode(element.value)
            end,
            setMode = function(element, mode)
                if element.value ~= mode then
                    element:SetValue(mode, false)
                end
            end,
        }
    end

    -- Read-only display for players: same look as the slider, no presses.
    local optionLabels = {}
    for i, option in ipairs(MODE_OPTIONS) do
        optionLabels[#optionLabels + 1] = gui.Label{
            classes = {
                "enumSliderOption",
                cond(i == 1, "enumSliderFirst"),
                cond(i == #MODE_OPTIONS, "enumSliderLast"),
            },
            data = { id = option.id },
            text = option.text,
            width = string.format("%.4f%%", 100 / #MODE_OPTIONS),
            interactable = false,
        }
    end

    return gui.Panel{
        classes = {"enumSlider"},
        valign = "center",
        setMode = function(element, mode)
            for _, child in ipairs(optionLabels) do
                child:SetClass("selected", child.data.id == mode)
            end
        end,
        children = optionLabels,
    }
end

----------------------------------------------------------------------
-- Wilderness travel block (Director only). A route slider, a list of the
-- crows on the map with a role dropdown and a Prompt Roll button each, the
-- required-role warnings, and the day's Encounter Number. Shown only while
-- the mode is Wilderness. Responds to FireEvent("refreshWilderness") to
-- reconcile against the synced state and the current map tokens.
----------------------------------------------------------------------

local function CreateWildernessBlock()
    local block
    local routeSelector
    local crowListPanel
    local guideWarning
    local scoutWarning
    local emptyLabel
    local enValueLabel
    local enScoutNote
    local clearScoutButton
    local tableDropdown
    local lastResultLabel
    local dayLabel
    local travelLabel
    local weatherLabel
    local seasonDropdown

    -- Scout and Guide prompts record their action here so we can auto-apply
    -- their day effects once the roll completes (Scout -> EN adjustment, Guide
    -- -> travel pace). Director-local; only the Director prompts rolls.
    -- onTier(tier) applies the effect; the entry clears on complete/cancel.
    local function ApplyPending(key, onTier)
        local pending = block.data[key]
        if pending == nil then return end
        local action = dmhub.GetPlayerActionRequest(pending.actionid)
        if action == nil then
            block.data[key] = nil
            return
        end
        local info = action.info.tokens[pending.tokenid]
        if info == nil then return end
        if info.status == "complete" then
            local tier = TierFromResult(info.result)
            if tier ~= nil then
                onTier(tier)
            end
            block.data[key] = nil
        elseif info.status == "cancel" then
            block.data[key] = nil
        end
    end

    local function ApplyPendingRolls()
        -- Scout: tier 1 -> -2, tier 2 -> -1, tier 3 -> 0.
        ApplyPending("pendingScout", function(tier) SetEnScout(tier - 3) end)
        -- Guide: the tier drives the travel-distance display.
        ApplyPending("pendingGuide", function(tier) SetGuideTier(tier) end)
    end

    local function CreateCrowRow(tokenid)
        -- Fixed control widths with the name filling the remainder, so a long
        -- crow name can't push the dropdown/button past the panel edge.
        local nameLabel = gui.Label{
            classes = {"label", "sizeS"},
            width = "100%-212",
            height = "auto",
            valign = "center",
            textWrap = false,
            textOverflow = "Truncate",
        }

        local roleDropdown = gui.Dropdown{
            classes = {"sizeXs"},
            options = ROLE_OPTIONS,
            idChosen = GetRole(tokenid),
            width = 108,
            height = 24,
            valign = "center",
            change = function(element)
                SetRole(tokenid, element.idChosen)
            end,
        }

        local promptButton = gui.Button{
            classes = {"sizeXs"},
            text = "Prompt Roll",
            width = 96,
            height = 24,
            hmargin = 4,
            halign = "right",
            valign = "center",
            hover = function(element)
                gui.Tooltip("Prompt this crow's player to roll their role's test")(element)
            end,
            press = function(element)
                local tok = dmhub.GetCharacterById(tokenid)
                if tok == nil then return end
                local roleId = GetRole(tokenid)
                local actionid = PromptRoleRoll(tok, roleId, GetRoute())
                if actionid ~= nil and roleId == ROLE_SCOUT then
                    block.data.pendingScout = { actionid = actionid, tokenid = tokenid }
                elseif actionid ~= nil and roleId == ROLE_GUIDE then
                    block.data.pendingGuide = { actionid = actionid, tokenid = tokenid }
                end
            end,
        }

        return gui.Panel{
            flow = "horizontal",
            width = "100%",
            height = "auto",
            valign = "center",
            vmargin = 2,

            refreshRow = function(element)
                local tok = dmhub.GetCharacterById(tokenid)
                -- token.description is the canonical display name ("(unnamed
                -- token)" when blank); token.name can be nil.
                nameLabel.text = (tok ~= nil and tok.description) or "(gone)"
                local roleId = GetRole(tokenid)
                roleDropdown.idChosen = roleId
                -- No test to prompt for an unassigned crow.
                promptButton:SetClass("collapsed", roleId == ROLE_NONE)
            end,

            nameLabel,
            roleDropdown,
            promptButton,
        }
    end

    ------------------------------------------------------------------
    -- Static widgets.
    ------------------------------------------------------------------

    -- Title + day counter row.
    dayLabel = gui.Label{
        classes = {"label", "sizeS"},
        text = "Day 1",
        width = "auto",
        height = "auto",
        halign = "right",
        valign = "center",
        color = "white",
    }

    local header = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        valign = "center",
        bmargin = 2,

        gui.Label{
            classes = {"label", "sizeS"},
            text = "Wilderness Travel",
            width = "auto",
            height = "auto",
            halign = "left",
            valign = "center",
        },
        gui.Panel{ width = "100%-80", height = 1 },  -- spacer pushes the day to the right
        dayLabel,
    }

    -- Weather display + season chooser + per-day weather roll.
    weatherLabel = gui.Label{
        classes = {"label", "sizeS"},
        text = "Weather: --",
        width = "100%",
        height = "auto",
        halign = "left",
        color = "white",
    }

    seasonDropdown = gui.Dropdown{
        classes = {"sizeXs"},
        options = SEASON_OPTIONS,
        idChosen = GetSeason(),
        width = 132,
        height = 24,
        valign = "center",
        change = function(element)
            SetSeason(element.idChosen)
        end,
    }

    local rollWeatherButton = gui.Button{
        classes = {"sizeXs"},
        text = "Roll Weather",
        width = 100,
        height = 24,
        halign = "right",
        valign = "center",
        hmargin = 4,
        hover = function(element)
            gui.Tooltip("Roll 1d6 on this season's weather table")(element)
        end,
        press = function(element)
            local season = GetSeason()
            gamehud.rollDialog.data.ShowDialog{
                roll = "1d6",
                type = "flat",
                description = string.format("Weather -- %s", SeasonDisplayName(season)),
                completeRoll = function(rollInfo)
                    if not block.valid then return end
                    SetWeather(WeatherForRoll(season, rollInfo.total))
                    block:FireEvent("refreshWilderness")
                end,
            }
        end,
    }

    local weatherRow = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        valign = "center",
        bmargin = 4,

        gui.Label{
            classes = {"label", "sizeS"},
            text = "Season",
            width = 56,
            height = "auto",
            valign = "center",
        },
        seasonDropdown,
        rollWeatherButton,
    }

    routeSelector = gui.EnumeratedSliderControl{
        options = ROUTE_OPTIONS,
        value = GetRoute(),
        width = "100%",
        valign = "center",
        bmargin = 4,
        change = function(element)
            SetRoute(element.value)
        end,
        setRoute = function(element, route)
            if element.value ~= route then
                element:SetValue(route, false)
            end
        end,
    }

    -- How far the group can travel today (adjusted by the Guide's roll).
    travelLabel = gui.Label{
        classes = {"sizeXs"},
        text = "",
        width = "100%",
        height = "auto",
        bmargin = 2,
        color = "#c9c9c9",
    }

    crowListPanel = gui.Panel{
        flow = "vertical",
        width = "100%",
        height = "auto",
        data = { rowsById = {}, signature = nil },
    }

    emptyLabel = gui.Label{
        classes = {"label", "sizeXs", "collapsed"},
        text = "No crows on the map.",
        width = "100%",
        height = "auto",
        color = "#9a9a9a",
    }

    guideWarning = gui.Label{
        classes = {"sizeXs", "collapsed"},
        text = "A Guide must be assigned.",
        width = "100%",
        height = "auto",
        color = "#e06b6b",
        tmargin = 2,
    }

    scoutWarning = gui.Label{
        classes = {"sizeXs", "collapsed"},
        text = "A Scout must be assigned.",
        width = "100%",
        height = "auto",
        color = "#e06b6b",
    }

    -- EN controls: a stepper over the base EN plus a note showing the Scout's
    -- automatic adjustment (with a clear button to undo it).
    local enStep = function(delta)
        return gui.Button{
            classes = {"sizeS"},
            text = delta < 0 and "-" or "+",
            width = 24,
            height = 24,
            valign = "center",
            press = function(element)
                SetEnBase(GetEnBase() + delta)
            end,
        }
    end

    enValueLabel = gui.Label{
        classes = {"sizeM"},
        text = tostring(EN_DEFAULT),
        width = 32,
        height = "auto",
        valign = "center",
        textAlignment = "center",
        color = "white",
    }

    clearScoutButton = gui.Button{
        classes = {"sizeXs", "collapsed"},
        text = "Clear",
        width = 52,
        height = 22,
        valign = "center",
        hmargin = 6,
        hover = function(element)
            gui.Tooltip("Clear the Scout's EN adjustment")(element)
        end,
        press = function(element)
            SetEnScout(0)
        end,
    }

    enScoutNote = gui.Label{
        classes = {"sizeXs", "collapsed"},
        text = "",
        width = "auto",
        height = "auto",
        valign = "center",
        hmargin = 6,
        color = "#9a9a9a",
    }

    -- Roll the encounter check (1d6 vs EN); on an encounter, roll the chosen
    -- table. Result goes to chat and to the inline result label below.
    local rollCheckButton = gui.Button{
        classes = {"sizeXs"},
        text = "Roll Check",
        width = 92,
        height = 24,
        halign = "right",
        valign = "center",
        hover = function(element)
            gui.Tooltip("Roll 1d6 against EN; on an encounter, roll the chosen table")(element)
        end,
        press = function(element)
            local en = GetEffectiveEn()
            -- Roll the encounter check (1d6) in the standard roll dialog. 1d6 >=
            -- EN means an encounter occurs; on an encounter we then open the
            -- table roll dialog. No creature -- it's a Ref-side flat check.
            gamehud.rollDialog.data.ShowDialog{
                roll = "1d6",
                type = "flat",
                description = string.format("Encounter Check (EN %d)", en),
                completeRoll = function(rollInfo)
                    if not block.valid then return end
                    local d6 = rollInfo.total

                    if d6 < en then
                        block.data.lastResult = string.format("Rolled %d vs EN %d: no encounter.", d6, en)
                        block:FireEvent("refreshWilderness")
                        return
                    end

                    local tableId = GetEncounterTableId()
                    if tableId == "" then
                        block.data.lastResult = string.format(
                            "Encounter! (rolled %d vs EN %d) -- select an encounter table to roll.", d6, en)
                        block:FireEvent("refreshWilderness")
                        return
                    end

                    block.data.lastResult = string.format("Encounter! (rolled %d vs EN %d) -- rolling...", d6, en)
                    block:FireEvent("refreshWilderness")

                    -- Defer the table roll so the encounter-check dialog has
                    -- finished tearing down before we reuse the shared dialog.
                    dmhub.Schedule(0.15, function()
                        if mod.unloaded or not block.valid then return end
                        ShowEncounterTableRoll(tableId, function(total, text)
                            if not block.valid then return end
                            block.data.lastResult = string.format("Encounter (%d vs EN %d): %s", d6, en, text)
                            block:FireEvent("refreshWilderness")
                        end)
                    end)
                end,
            }
        end,
    }

    local enRow = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        valign = "center",
        tmargin = 6,

        gui.Label{
            classes = {"label", "sizeS"},
            text = "Encounter Number (EN)",
            width = "auto",
            height = "auto",
            valign = "center",
            hmargin = 6,
        },
        enStep(-1),
        enValueLabel,
        enStep(1),
        rollCheckButton,
    }

    -- Scout's automatic EN adjustment note + clear, on its own row so the EN
    -- row stays uncluttered.
    local scoutRow = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        valign = "center",
        enScoutNote,
        clearScoutButton,
    }

    -- Encounter table chooser ("which kind of encounter is in this area").
    tableDropdown = gui.Dropdown{
        classes = {"sizeXs"},
        options = GetEncounterTableOptions(),
        idChosen = GetEncounterTableId(),
        width = "100%-120",
        height = 24,
        valign = "center",
        change = function(element)
            SetEncounterTableId(element.idChosen)
        end,
    }

    local tableRow = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        valign = "center",
        tmargin = 4,

        gui.Label{
            classes = {"label", "sizeS"},
            text = "Encounter Table",
            width = 116,
            height = "auto",
            valign = "center",
        },
        tableDropdown,
    }

    -- Inline echo of the most recent encounter check.
    lastResultLabel = gui.Label{
        classes = {"sizeXs", "collapsed"},
        text = "",
        width = "100%",
        height = "auto",
        tmargin = 4,
        color = "#c9c9c9",
        textWrap = true,
    }

    -- Day-level actions: prompt every crow's miasma check, and end the day.
    local miasmaButton = gui.Button{
        classes = {"sizeXs"},
        text = "Miasma Check",
        width = 110,
        height = 24,
        valign = "center",
        hover = function(element)
            gui.Tooltip("Prompt every crow to make a Miasma Check (2d10 + Mind + Endurance)")(element)
        end,
        press = function(element)
            FireMiasmaCheck()
        end,
    }

    local endDayButton = gui.Button{
        classes = {"sizeXs"},
        text = "End of Day",
        width = 96,
        height = 24,
        halign = "right",
        valign = "center",
        hmargin = 4,
        hover = function(element)
            gui.Tooltip("Advance to the next travel day (re-rolls EN and pace)")(element)
        end,
        press = function(element)
            AdvanceDay()
            block.data.lastResult = nil
            block:FireEvent("refreshWilderness")
        end,
    }

    local dayActionsRow = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        valign = "center",
        tmargin = 8,

        miasmaButton,
        gui.Panel{ width = "100%-220", height = 1 },  -- spacer
        endDayButton,
    }

    ------------------------------------------------------------------
    -- Root + reconcile.
    ------------------------------------------------------------------

    block = gui.Panel{
        flow = "vertical",
        width = "100%",
        height = "auto",
        tmargin = 8,
        data = { pendingScout = nil, pendingGuide = nil },

        refreshWilderness = function(element)
            ApplyPendingRolls()

            dayLabel.text = string.format("Day %d", GetDay())
            travelLabel.text = "Travel: " .. GetTravelDistanceText()

            local weather = GetWeather()
            weatherLabel.text = "Weather: " .. (weather ~= "" and weather or "-- (roll for weather)")
            seasonDropdown.idChosen = GetSeason()

            routeSelector:FireEvent("setRoute", GetRoute())

            local crows = dmhub.GetTokens({ playerControlled = true })
            table.sort(crows, function(a, b)
                return (a.name or "") < (b.name or "")
            end)

            -- Rebuild rows only when the set/order of crow ids changes; reuse
            -- existing row panels otherwise so dropdown state and events survive.
            local ids = {}
            for _, c in ipairs(crows) do ids[#ids + 1] = c.id end
            local signature = table.concat(ids, ",")

            if signature ~= crowListPanel.data.signature then
                local oldRows = crowListPanel.data.rowsById
                local newRows = {}
                local children = {}
                for _, c in ipairs(crows) do
                    local r = oldRows[c.id] or CreateCrowRow(c.id)
                    newRows[c.id] = r
                    children[#children + 1] = r
                end
                crowListPanel.data.rowsById = newRows
                crowListPanel.data.signature = signature
                crowListPanel.children = children
            end

            for _, r in pairs(crowListPanel.data.rowsById) do
                r:FireEvent("refreshRow")
            end

            -- Required-role warnings + empty state.
            local haveGuide, haveScout = false, false
            for _, c in ipairs(crows) do
                local roleId = GetRole(c.id)
                if roleId == ROLE_GUIDE then haveGuide = true end
                if roleId == ROLE_SCOUT then haveScout = true end
            end
            emptyLabel:SetClass("collapsed", #crows > 0)
            guideWarning:SetClass("collapsed", haveGuide)
            scoutWarning:SetClass("collapsed", haveScout)

            -- EN display.
            enValueLabel.text = tostring(GetEffectiveEn())
            local scout = GetEnScout()
            if scout ~= 0 then
                enScoutNote.text = string.format("base %d, Scout %d", GetEnBase(), scout)
                enScoutNote:SetClass("collapsed", false)
                clearScoutButton:SetClass("collapsed", false)
            else
                enScoutNote:SetClass("collapsed", true)
                clearScoutButton:SetClass("collapsed", true)
            end

            -- Encounter table selection + last check echo.
            tableDropdown.idChosen = GetEncounterTableId()
            local last = block.data.lastResult
            lastResultLabel.text = last or ""
            lastResultLabel:SetClass("collapsed", last == nil or last == "")
        end,

        header,
        weatherLabel,
        weatherRow,
        routeSelector,
        travelLabel,
        crowListPanel,
        emptyLabel,
        guideWarning,
        scoutWarning,
        enRow,
        scoutRow,
        tableRow,
        lastResultLabel,
        dayActionsRow,
    }

    return block
end

----------------------------------------------------------------------
-- The Dungeon Turn section. Built once per Campaign Tracker panel instance.
-- Also hosts the campaign-mode slider at the top; the Dungeon Turn controls
-- below are only shown while the mode is Dungeon.
----------------------------------------------------------------------

local function CreateDungeonTurnSection()
    local isDM = dmhub.isDM

    -- Countdown bar (visible to everyone). Continuous fill, no segments.
    local barFill = gui.Panel{
        classes = {"fillBarFill"},
        floating = true,
        width = "100%",
        height = "100%",
        halign = "left",
        valign = "center",
        bgcolor = DUNGEON_TURN_ACCENT,
    }

    local barTrack = gui.Panel{
        classes = {"fillBar"},
        width = "100%",
        height = 16,
        valign = "center",
        halign = "left",
        flow = "horizontal",
        barFill,
    }

    -- Director-only widgets.
    local timeLabel
    local playButton
    local pauseButton
    local controlRow

    -- Forward-declared so updateDisplay (defined below) can close over them
    -- before they are assigned further down.
    local modeSelector
    local dungeonTurnBlock
    local wildernessBlock

    if isDM then
        -- Editable clock: click to type a new time as "mm:ss" or a number of
        -- minutes. While running it counts down live, but we never overwrite the
        -- text while the Director has it focused (mid-edit).
        timeLabel = gui.Input{
            classes = {"timerInput"},
            text = FormatTime(DUNGEON_TURN_DURATION),
            width = 96,
            height = 30,
            fontSize = 22,
            characterLimit = 6,
            halign = "left",
            valign = "center",
            textAlignment = "left",
            hover = function(element)
                gui.Tooltip("Click to set the time (mm:ss or minutes)")(element)
            end,
            change = function(element)
                local secs = ParseTime(element.text)
                if secs ~= nil then
                    SetRemaining(secs)
                end
                -- Snap the field back to the canonical, clamped value.
                element.text = FormatTime(ComputeRemaining(GetDoc().data))
            end,
        }

        playButton = TimerIconButton{
            icon = "ui-icons/AudioPlayButton.png",
            color = "#43b06f",
            tooltip = "Start the Dungeon Turn",
            press = function(element)
                StartTimer()
            end,
        }

        pauseButton = TimerIconButton{
            classes = {"hidden"},
            icon = "panels/square.png",
            color = "#c46a6a",
            tooltip = "Pause the Dungeon Turn",
            press = function(element)
                PauseTimer()
            end,
        }

        local resetButton = gui.Button{
            classes = {"sizeXs"},
            text = "Reset",
            width = 60,
            height = 24,
            valign = "center",
            hmargin = 8,
            hover = function(element)
                gui.Tooltip("Reset to 30:00")(element)
            end,
            press = function(element)
                ResetTimer()
            end,
        }

        controlRow = gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "auto",
            halign = "left",
            valign = "center",
            tmargin = 4,

            playButton,
            pauseButton,
            timeLabel,
            resetButton,
        }
    end

    -- Re-render the bar (and, for the Director, the clock + button states) from
    -- the current synced state. Driven both by the periodic think tick (smooth
    -- countdown off the synced clock) and by refreshGame (instant reaction when
    -- another client plays/pauses/adjusts).
    local function updateDisplay(element)
        -- Reflect the synced mode on the slider and gate the per-mode blocks.
        local mode = GetMode()
        modeSelector:FireEvent("setMode", mode)
        dungeonTurnBlock:SetClass("collapsed", mode ~= MODE_DUNGEON)
        if wildernessBlock ~= nil then
            wildernessBlock:SetClass("collapsed", mode ~= MODE_WILDERNESS)
            if mode == MODE_WILDERNESS then
                wildernessBlock:FireEvent("refreshWilderness")
            end
        end

        local data = GetDoc().data
        local remaining = ComputeRemaining(data)
        local duration = GetDuration(data)
        local frac = 0
        if duration > 0 then
            frac = math.max(0, math.min(1, remaining / duration))
        end
        barFill.selfStyle.width = string.format("%.2f%%", frac * 100)

        if isDM then
            local running = data.running == true
            -- Leave the field alone while the Director is typing into it.
            if not timeLabel.hasInputFocus then
                timeLabel.text = FormatTime(remaining)
            end
            playButton:SetClass("hidden", running)
            pauseButton:SetClass("hidden", not running)
            playButton:SetClass("disabled", remaining <= 0)
        end
    end

    -- Mode slider (always shown). Interactive for the Director, read-only for
    -- players; both reflect the synced mode through FireEvent("setMode", ...).
    local modeHeader = gui.Label{
        classes = {"label", "sizeS"},
        text = "Mode",
        width = "100%",
        height = "auto",
        halign = "left",
        bmargin = 2,
    }

    modeSelector = CreateModeSelector(isDM)

    -- Dungeon Turn block (header + countdown bar + Director controls). Collapsed
    -- unless the mode is Dungeon.
    local dungeonHeader = gui.Label{
        classes = {"label", "sizeS"},
        text = "Dungeon Turn",
        width = "100%",
        height = "auto",
        halign = "left",
        bmargin = 2,
    }

    local dungeonChildren = { dungeonHeader, barTrack }
    if controlRow ~= nil then
        dungeonChildren[#dungeonChildren + 1] = controlRow
    end

    dungeonTurnBlock = gui.Panel{
        flow = "vertical",
        width = "100%",
        height = "auto",
        tmargin = 8,
        children = dungeonChildren,
    }

    -- Wilderness travel block (Director only). Collapsed unless mode is Wilderness.
    if isDM then
        wildernessBlock = CreateWildernessBlock()
    end

    local children = { modeHeader, modeSelector, dungeonTurnBlock }
    if wildernessBlock ~= nil then
        children[#children + 1] = wildernessBlock
    end

    return gui.Panel{
        classes = {"campaignTrackerSection"},
        flow = "vertical",
        width = "100%",
        height = "auto",
        vmargin = 4,

        styles = {
            -- Editable clock: reads as plain numerals at rest, with a subtle
            -- border appearing on hover/focus to signal it can be clicked + typed.
            {
                selectors = {"timerInput"},
                bgcolor = "clear",
                color = "white",
                fontFace = "@number",
                borderWidth = 0,
                cornerRadius = 4,
                pad = 2,
                borderBox = true,
            },
            {
                selectors = {"timerInput", "hover"},
                borderWidth = 1,
                borderColor = "#ffffff55",
            },
            {
                selectors = {"timerInput", "focus"},
                borderWidth = 1,
                borderColor = DUNGEON_TURN_ACCENT,
            },
        },

        monitorGame = {
            mod:GetDocumentPath(DUNGEON_TURN_DOC),
            mod:GetDocumentPath(CAMPAIGN_MODE_DOC),
            mod:GetDocumentPath(WILDERNESS_DOC),
            "/actionRequests",
        },
        thinkTime = 0.1,
        data = { handledEndTime = nil },

        -- The handlers are pcall-guarded so a runtime error in this section can
        -- never propagate out of its attachment/refresh. Without this, an error
        -- in `create` (which fires while the section is being attached, before
        -- the built-in notes section since this sorts at ord -10) would cascade
        -- up and orphan the shared Campaign Tracker. Errors are logged, not
        -- silenced, so real bugs stay visible.
        create = function(element)
            local ok, err = pcall(updateDisplay, element)
            if not ok then printf("Crowdex campaign section (create): %s", tostring(err)) end
        end,

        refreshGame = function(element)
            local ok, err = pcall(updateDisplay, element)
            if not ok then printf("Crowdex campaign section (refreshGame): %s", tostring(err)) end
        end,

        think = function(element)
            local ok, err = pcall(function()
                local data = GetDoc().data

                -- Director-only: detect expiry and fire it exactly once per run.
                -- handledEndTime guards the brief window before the running=false
                -- write propagates back through the document. Only fires while
                -- the mode is Dungeon, since that is the only time the timer is shown.
                if isDM and GetMode() == MODE_DUNGEON
                    and data.running and data.endTime ~= nil
                    and dmhub.serverTime >= data.endTime
                    and element.data.handledEndTime ~= data.endTime then
                    element.data.handledEndTime = data.endTime
                    StopAtZero()
                    FireDungeonTurnExpiry()
                end

                updateDisplay(element)
            end)
            if not ok then printf("Crowdex campaign section (think): %s", tostring(err)) end
        end,

        children = children,
    }
end

----------------------------------------------------------------------
-- Registration. Guard the hook in case the host panel is unavailable.
----------------------------------------------------------------------

local CampaignTrackerGlobal = rawget(_G, "CampaignTracker")
if CampaignTrackerGlobal ~= nil and CampaignTrackerGlobal.RegisterSection ~= nil then
    CampaignTrackerGlobal.RegisterSection{
        id = "crowdexDungeonTurn",
        ord = -10,   -- above the built-in notes section (ord 0).
        create = CreateDungeonTurnSection,
    }
end
