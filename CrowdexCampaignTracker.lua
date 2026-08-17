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
local DUNGEON_TURN_DURATION = 30 * 60   -- 30 minutes, in seconds: the default.
local DUNGEON_TURN_TRIGGER = "Dungeon Turn"

-- Dungeon turn length. 30 minutes is the rule; The Rules ("Adjusting DT Time")
-- also sanctions 60 minutes for a more relaxed pace and 20 for a more intense
-- one. The chosen length lives in the synced document's `duration` field, so
-- every client agrees on it and the bar measures against the right total.
local DUNGEON_TURN_LENGTH_OPTIONS = {
    { id = "1200", text = "20 min (intense)" },
    { id = "1800", text = "30 min (standard)" },
    { id = "3600", text = "60 min (relaxed)" },
}
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

-- Travel pace (The Rules, Travel Pace). Pace sets BOTH the distance covered and
-- the day's encounter number, and colours every role test.
local PACE_SLOW, PACE_NORMAL, PACE_FAST = "slow", "normal", "fast"
local PACE_DEFAULT = PACE_NORMAL
local PACE_OPTIONS = {
    { id = PACE_SLOW,   text = "Slow -- 1 hex, EN 8" },
    { id = PACE_NORMAL, text = "Normal -- 2 hexes, EN 7" },
    { id = PACE_FAST,   text = "Fast -- 3 hexes, EN 6" },
}
local PACE_INFO = {
    [PACE_SLOW]   = { hexes = 1, en = 8, note = "Role tests gain an edge." },
    [PACE_NORMAL] = { hexes = 2, en = 7, note = "" },
    [PACE_FAST]   = { hexes = 3, en = 6, note = "Role tests take a bane." },
}

-- A hex is 5 miles across. Distance is counted in hexes now, not miles.
local HEX_MILES = 5

-- Encounter checks are d10. An encounter happens when the roll is EQUAL TO OR
-- HIGHER THAN the EN, so a HIGHER EN means FEWER encounters -- which is why a
-- slow, careful pace carries the highest number, and why role results that help
-- the party RAISE it. Playtest 1 was d6 with the opposite intuition baked in.
-- The book caps it: "The EN can never be more than 10."
local EN_MIN, EN_MAX = 1, 10

-- Distance modifiers (The Rules, Rivers and Roads; Changing Pace). Director
-- toggles, since only the table knows the day's terrain.
local SPEED_BAND_OPTIONS = {
    { id = "slow",   text = "Slowest speed 3 or lower (-1 hex)" },
    { id = "normal", text = "Slowest speed 4-6" },
    { id = "fast",   text = "Slowest speed 7-9 (+1 hex)" },
    { id = "vfast",  text = "Slowest speed 10+ (+2 hexes)" },
}
local SPEED_BAND_HEXES = { slow = -1, normal = 0, fast = 1, vfast = 2 }

-- Custom creature trigger fired on each crow by the Miasma check. The imported
-- "Miasma" global rule reacts to it and prompts that crow's test.
local MIASMA_TRIGGER = "Miasma Check"

-- Travel roles (The Rules, Travel Roles). Playtest 2 renamed and re-scoped
-- them: Leader became Supporter, Forager became Tracker, and each role now
-- offers a choice of tasks rather than one fixed test. Only one creature can be
-- the Guide; the other roles take up to three each.
local ROLE_NONE      = "none"
local ROLE_SUPPORTER = "supporter"
local ROLE_GUIDE     = "guide"
local ROLE_SCOUT     = "scout"
local ROLE_TRACKER   = "tracker"
local ROLE_OPTIONS = {
    { id = ROLE_NONE,      text = "--" },
    { id = ROLE_SUPPORTER, text = "Supporter" },
    { id = ROLE_GUIDE,     text = "Guide" },
    { id = ROLE_SCOUT,     text = "Scout" },
    { id = ROLE_TRACKER,   text = "Tracker" },
}
local ROLE_NAMES = {
    [ROLE_SUPPORTER] = "Supporter",
    [ROLE_GUIDE]     = "Guide",
    [ROLE_SCOUT]     = "Scout",
    [ROLE_TRACKER]   = "Tracker",
}

-- The eleven tasks, with the characteristic(s) the test may use and its tier
-- results as printed. `en`, `hexes` and `lost` record the automatic effect of a
-- tier where the book states one outright. A tier that offers the party a
-- choice ("Choose one: ...") deliberately records nothing and is left to the
-- Director, because the module cannot know which half they took.
local TASK_NONE = "none"
local TASKS = {
    [ROLE_SUPPORTER] = {
        { id = "miasma", text = "Fight the Miasma", attrs = {"mind"}, tiers = {
            "No effect.",
            "Up to four creatures traveling with you, including you, gain an edge on the RR against the Miasma today.",
            "As tier 2, but the benefit is a double edge." } },
        { id = "camp", text = "Make Camp", attrs = {"strength"}, tiers = {
            "No effect.",
            "Choose one: raise the EN during today's rest by 1, or each creature making a crafting roll at camp today gains a +2 bonus.",
            "As tier 2, but the EN is raised by 2 or the crafting bonus is +4." } },
        { id = "support", text = "Support Everyone", attrs = {"mind", "strength"}, tiers = {
            "Up to four chosen allies take a -1 penalty to tests related to their travel roles today.",
            "Those allies gain a +1 bonus on tests related to their travel roles today.",
            "As tier 2, but the bonus is +2." } },
    },
    [ROLE_GUIDE] = {
        { id = "normal", text = "Follow Normal Route", attrs = {"mind"}, tiers = {
            "Choose one: the group moves 1 fewer hex than the pace set, or the EN for travel encounters today is reduced by 1.",
            "No effect.",
            "Choose one: the group moves 1 more hex than the pace set, or the EN for travel encounters today is increased by 1." } },
        { id = "safe", text = "Follow Safe Route", attrs = {"mind"},
            en = { nil, 1, 2 }, hexes = { nil, -1, 0 }, lost = { true, false, false }, tiers = {
            "The group gets lost.",
            "The EN for travel encounters today is raised by 1, but the group moves 1 hex slower than the pace set.",
            "The EN for travel encounters today is increased by 2." } },
        { id = "shortcut", text = "Follow Shortcut", attrs = {"mind"},
            en = { nil, -1, 0 }, hexes = { nil, 1, 2 }, lost = { true, false, false }, tiers = {
            "The group gets lost.",
            "The group moves 1 hex faster than the pace set, but the EN for travel encounters is reduced by 1 today.",
            "The group moves 2 hexes faster." } },
    },
    [ROLE_SCOUT] = {
        { id = "danger", text = "Scout for Danger", attrs = {"agility", "mind"},
            en = { 0, 1, 2 }, tiers = {
            "No effect.",
            "The EN for travel encounters today increases by 1.",
            "As tier 2, but the EN increases by 2." } },
        { id = "shelter", text = "Scout for Shelter", attrs = {"mind"},
            restEn = { 0, 1, 2 }, tiers = {
            "No effect.",
            "The EN for rest encounters today increases by 1.",
            "As tier 2, but the EN increases by 2." } },
        { id = "treasure", text = "Treasure Hunt", attrs = {"strength"}, tiers = {
            "No effect.",
            "The Ref rolls on the Minor Things table.",
            "The Ref rolls on the Major Things table." } },
    },
    [ROLE_TRACKER] = {
        { id = "forage", text = "Forage", attrs = {"mind"}, tiers = {
            "No effect.",
            "You procure 1 ration.",
            "You procure 1d6 + 1 rations." } },
        { id = "hunt", text = "Hunt", attrs = {"agility"},
            en = { -1, 0, 0 }, tiers = {
            "The EN for travel encounters today decreases by 1.",
            "No effect.",
            "You procure 3d6 rations and a Large animal hide." } },
        { id = "track", text = "Track Specific Creature", attrs = {"mind"},
            en = { -1, 0, 0 }, tiers = {
            "The EN for travel encounters today decreases by 1.",
            "No effect.",
            "You encounter the creature you sought; the Ref decides when and where." } },
    },
}

-- While lost, the Guide makes this test instead of a route task.
local BACK_ON_TRACK = {
    id = "backontrack", text = "Back on Track", attrs = {"mind"},
    lost = { true, false, false }, tiers = {
        "The group remains lost.",
        "You realize where the group is. You are no longer lost and move toward your destination at the pace set.",
        "As tier 2, and choose one: the group moves 1 more hex than the pace set, or the EN today is increased by 1." },
}

-- Look up a task record by role + task id.
local function TaskInfo(roleId, taskId)
    for _, t in ipairs(TASKS[roleId] or {}) do
        if t.id == taskId then return t end
    end
    return nil
end

-- {id, text} options for a role's task picker, with a leading placeholder.
local function TaskOptions(roleId)
    local out = { { id = TASK_NONE, text = "(pick task)" } }
    for _, t in ipairs(TASKS[roleId] or {}) do
        out[#out + 1] = { id = t.id, text = t.text }
    end
    return out
end

mod:RegisterDocumentForCheckpointBackups(WILDERNESS_DOC)

-- Resting
-- -------
-- A rest is its own unit of time in Playtest 2 -- not three dungeon turns as it
-- was in Playtest 1. Finishing one restores every crow's Stamina, removes a
-- wound, and refills equipment whose Usage Dice recharge on a rest; a rest
-- taken in the Miasma also triggers each human's Mind test against it.
--
-- Each crow may perform one rest activity. Only two have effects worth
-- automating: Tend Wounds (its target loses 2 wounds instead of 1) and Seclude
-- Camp (-1 EN for the rest). The others are prompts for the table -- recorded
-- so the Director can see who is doing what, and so nobody doubles up.
--
-- State lives in its own synced document:
--   activities -- map of token id -> activity id
--   tendTargets -- map of tending token id -> the token id they are tending
local REST_DOC = "crowdex_rest"

local REST_NONE = "none"
local REST_TEND = "tend"
local REST_SECLUDE = "seclude"
local REST_ACTIVITY_OPTIONS = {
    { id = REST_NONE, text = "--" },
    { id = "craft", text = "Craft Equipment" },
    { id = "harvest", text = "Harvest" },
    { id = "identify", text = "Identify Item" },
    { id = "prepare", text = "Prepare for Task" },
    { id = "repair", text = "Repair Armor" },
    { id = REST_SECLUDE, text = "Seclude Camp" },
    { id = REST_TEND, text = "Tend Wounds" },
}

-- Activities the Finish Rest button resolves by itself. Everything else is
-- narrated at the table, so the button reports it rather than applying it.
local REST_AUTOMATED = {
    [REST_TEND] = true,
}

mod:RegisterDocumentForCheckpointBackups(REST_DOC)

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

----------------------------------------------------------------------
-- Pace and distance.
----------------------------------------------------------------------

local function GetPace()
    local pace = GetWildernessDoc().data.pace
    if PACE_INFO[pace] ~= nil then return pace end
    return PACE_DEFAULT
end

local function SetPace(pace)
    if PACE_INFO[pace] == nil then return end
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.pace = pace
    doc:CompleteChange("Set travel pace", {undoable = false})
end

local function GetSpeedBand()
    local band = GetWildernessDoc().data.speedBand
    if SPEED_BAND_HEXES[band] ~= nil then return band end
    return "normal"
end

local function SetSpeedBand(band)
    if SPEED_BAND_HEXES[band] == nil then return end
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.speedBand = band
    doc:CompleteChange("Set group speed band", {undoable = false})
end

-- Terrain toggles: following a road all day, and moving up or down a waterway.
local function GetTerrain(key)
    local t = GetWildernessDoc().data.terrain
    if type(t) ~= "table" then return false end
    return t[key] == true
end

local function SetTerrain(key, value)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    if type(doc.data.terrain) ~= "table" then doc.data.terrain = {} end
    doc.data.terrain[key] = value and true or nil
    doc:CompleteChange("Set travel terrain", {undoable = false})
end

-- Hex adjustment banked from role results (a Guide shortcut, say). Kept apart
-- from the terrain and speed modifiers so ending the day clears only this.
local function GetHexAdjust()
    local n = GetWildernessDoc().data.hexAdjust
    if type(n) ~= "number" then return 0 end
    return math.floor(n)
end

local function AddHexAdjust(delta)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.hexAdjust = GetHexAdjust() + math.floor(delta)
    doc:CompleteChange("Adjust travel distance", {undoable = false})
end

-- Hexes covered today: the pace, plus the group-speed band, plus road and
-- waterway modifiers, plus anything role results banked. Never below zero --
-- a badly modified day means no progress, not backwards progress.
local function GetHexesToday()
    local hexes = PACE_INFO[GetPace()].hexes
    hexes = hexes + (SPEED_BAND_HEXES[GetSpeedBand()] or 0)
    if GetTerrain("road") then hexes = hexes + 1 end
    if GetTerrain("downstream") then hexes = hexes + 1 end
    if GetTerrain("upstream") then hexes = hexes - 1 end
    hexes = hexes + GetHexAdjust()
    return math.max(0, hexes)
end

local function GetTravelDistanceText()
    if GetLost ~= nil and GetLost() then
        -- A lost group still covers ground, they just do not choose where.
        return string.format("%d hexes (~%d miles) -- LOST, direction unknown",
            GetHexesToday(), GetHexesToday() * HEX_MILES)
    end
    return string.format("%d hexes (~%d miles)", GetHexesToday(), GetHexesToday() * HEX_MILES)
end

----------------------------------------------------------------------
-- Encounter number.
----------------------------------------------------------------------

-- The day's base EN comes from the pace. The Ref can still nudge it, and role
-- results bank their own adjustment; both are kept separately so ending the
-- day clears the role effects without losing a deliberate Ref ruling.
local function GetEnBase()
    local n = GetWildernessDoc().data.enBase
    if type(n) ~= "number" then return PACE_INFO[GetPace()].en end
    return math.max(EN_MIN, math.min(EN_MAX, math.floor(n)))
end

local function SetEnBase(n)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.enBase = math.max(EN_MIN, math.min(EN_MAX, math.floor(n)))
    doc:CompleteChange("Set encounter number", {undoable = false})
end

-- Role adjustment. Unlike Playtest 1 this is symmetric: Scout for Danger and
-- the Guide's safe route RAISE it (fewer encounters), Hunt and Track lower it.
local function GetEnRoles()
    local n = GetWildernessDoc().data.enRoles
    if type(n) ~= "number" then return 0 end
    return math.floor(n)
end

local function AddEnRoles(delta)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.enRoles = GetEnRoles() + math.floor(delta)
    doc:CompleteChange("Role result adjusted encounter number", {undoable = false})
end

local function GetEffectiveEn()
    return math.max(EN_MIN, math.min(EN_MAX, GetEnBase() + GetEnRoles()))
end

-- Rest encounters carry their own number (Scout for Shelter, Seclude Camp).
local function GetRestEn()
    local n = GetWildernessDoc().data.restEn
    if type(n) ~= "number" then return PACE_INFO[GetPace()].en end
    return math.max(EN_MIN, math.min(EN_MAX, math.floor(n)))
end

local function AddRestEn(delta)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.restEn = math.max(EN_MIN, math.min(EN_MAX, GetRestEn() + math.floor(delta)))
    doc:CompleteChange("Adjusted rest encounter number", {undoable = false})
end

----------------------------------------------------------------------
-- Lost.
----------------------------------------------------------------------

-- While lost the group does not know where it is. The book has the Ref roll a
-- secret d6 per hex left and count clockwise from the northernmost neighbour;
-- that stays on the Ref's paper, because this document syncs to every client
-- and a "secret" in it would not be secret. All the module tracks is the flag.
function GetLost()
    return GetWildernessDoc().data.lost == true
end

local function SetLost(value)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.lost = value and true or nil
    doc:CompleteChange(value and "The group is lost" or "Back on track", {undoable = false})
end

----------------------------------------------------------------------
-- Roles and tasks.
----------------------------------------------------------------------

local function GetRole(tokenid)
    local roles = GetWildernessDoc().data.roles
    if type(roles) ~= "table" then return ROLE_NONE end
    return roles[tokenid] or ROLE_NONE
end

local function SetRole(tokenid, roleId)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    if type(doc.data.roles) ~= "table" then doc.data.roles = {} end
    if roleId == ROLE_NONE then
        doc.data.roles[tokenid] = nil
    else
        doc.data.roles[tokenid] = roleId
    end
    -- Changing role invalidates the task, which belonged to the old one.
    if type(doc.data.tasks) == "table" then doc.data.tasks[tokenid] = nil end
    doc:CompleteChange("Assign travel role", {undoable = false})
end

local function GetTask(tokenid)
    local tasks = GetWildernessDoc().data.tasks
    if type(tasks) ~= "table" then return TASK_NONE end
    return tasks[tokenid] or TASK_NONE
end

local function SetTask(tokenid, taskId)
    local doc = GetWildernessDoc()
    doc:BeginChange()
    if type(doc.data.tasks) ~= "table" then doc.data.tasks = {} end
    if taskId == TASK_NONE then
        doc.data.tasks[tokenid] = nil
    else
        doc.data.tasks[tokenid] = taskId
    end
    doc:CompleteChange("Assign travel task", {undoable = false})
end

-- Only one creature can be the Guide (The Rules, Travel Roles).
local function GuideTokenId()
    local roles = GetWildernessDoc().data.roles
    if type(roles) ~= "table" then return nil end
    for tokenid, roleId in pairs(roles) do
        if roleId == ROLE_GUIDE then return tokenid end
    end
    return nil
end

-- The encounter table (a RollTable id in the "encounterTables" table) chosen for
-- this area, or "" for none.
----------------------------------------------------------------------
-- Rest state (synced).
----------------------------------------------------------------------

local function GetRestDoc()
    return mod:GetDocumentSnapshot(REST_DOC)
end

local function GetRestActivity(tokenid)
    local acts = GetRestDoc().data.activities
    if type(acts) ~= "table" then return REST_NONE end
    return acts[tokenid] or REST_NONE
end

local function SetRestActivity(tokenid, activityId)
    local doc = GetRestDoc()
    doc:BeginChange()
    if type(doc.data.activities) ~= "table" then
        doc.data.activities = {}
    end
    if activityId == REST_NONE then
        doc.data.activities[tokenid] = nil
    else
        doc.data.activities[tokenid] = activityId
    end
    -- Choosing anything other than Tend Wounds drops a stale target, so the
    -- pairing can never outlive the activity that created it.
    if activityId ~= REST_TEND and type(doc.data.tendTargets) == "table" then
        doc.data.tendTargets[tokenid] = nil
    end
    doc:CompleteChange("Set rest activity", {undoable = false})
end

local function GetTendTarget(tokenid)
    local targets = GetRestDoc().data.tendTargets
    if type(targets) ~= "table" then return nil end
    return targets[tokenid]
end

local function SetTendTarget(tokenid, targetid)
    local doc = GetRestDoc()
    doc:BeginChange()
    if type(doc.data.tendTargets) ~= "table" then
        doc.data.tendTargets = {}
    end
    doc.data.tendTargets[tokenid] = targetid
    doc:CompleteChange("Set tend wounds target", {undoable = false})
end

-- Clear every crow's activity. Called once a rest is finished so the next rest
-- starts from a blank slate rather than silently repeating the last one.
local function ClearRestActivities()
    local doc = GetRestDoc()
    doc:BeginChange()
    doc.data.activities = {}
    doc.data.tendTargets = {}
    doc:CompleteChange("Clear rest activities", {undoable = false})
end

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

-- Weather is no longer a separate daily roll. Playtest 2 folded it into the
-- travel encounter table as a "Bad Weather" result (21-25 on the d100), whose
-- climate row the Ref reads off The Ref Book. The season dropdown and the 1d6
-- weather roll that stood here are gone with it.

local function GetDay()
    local n = GetWildernessDoc().data.day
    if type(n) ~= "number" or n < 1 then return 1 end
    return math.floor(n)
end

-- Advance to the next travel day: bump the counter and clear everything the
-- day's rolls banked -- the role EN and hex adjustments, and the rest EN. Pace,
-- speed band, terrain, role assignments and the lost flag persist, because none
-- of those reset overnight: a lost group wakes up still lost.
local function AdvanceDay()
    local doc = GetWildernessDoc()
    doc:BeginChange()
    doc.data.day = GetDay() + 1
    doc.data.enRoles = 0
    doc.data.enBase = nil
    doc.data.restEn = nil
    doc.data.hexAdjust = 0
    doc.data.tasks = {}
    doc:CompleteChange("End of day", {undoable = false})
end

----------------------------------------------------------------------
-- Role roll prompts.
----------------------------------------------------------------------

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
-- Build the roll for a task. Every task names the characteristic(s) it may use;
-- offering several checks lets the player pick, which is what "2d10 + A or M"
-- means. No test adds an expertise any more -- an expertise is spent after the
-- roll to improve its tier, so nothing is added to the roll here.
local function BuildTaskChecks(task)
    if task == nil then return nil end
    local labels = { agility = "Agility", mind = "Mind", strength = "Strength" }
    local checks = {}
    for _, attr in ipairs(task.attrs or {}) do
        checks[#checks + 1] = RollCheck.new{
            type = "test_power_roll",
            id = attr,
            text = labels[attr] or attr,
            options = { tiers = task.tiers },
        }
    end
    if #checks == 0 then return nil end
    return checks
end

local function RoleDisplayName(roleId)
    return ROLE_NAMES[roleId] or roleId
end

-- Send a task's test to the crow's controlling player and show the Director a
-- result summary. Returns the action request id so the caller can watch it and
-- apply whatever the tier does to the day.
local function PromptTaskRoll(token, roleId, task)
    local checks = BuildTaskChecks(task)
    if checks == nil then return nil end

    local pace = PACE_INFO[GetPace()]
    local title = string.format("%s -- %s: %s", token.name or "Crow",
        RoleDisplayName(roleId), task.text)
    if pace.note ~= "" then
        title = string.format("%s  (%s)", title, pace.note)
    end

    local actionid = dmhub.SendActionRequest(RollRequest.new{
        title = title,
        checks = checks,
        tokens = { [token.id] = {} },
        dicetower = false,
    })
    gamehud:ShowRollSummaryDialog(actionid)
    return actionid
end

-- Apply whatever a completed task tier states outright. Tiers that offer the
-- party a choice record nothing and are left to the Director; the tier text is
-- on the roll summary either way. Returns a short description of what changed.
local function ApplyTaskTier(task, tier)
    if task == nil or tier == nil then return nil end
    local notes = {}

    local en = task.en and task.en[tier]
    if en ~= nil and en ~= 0 then
        AddEnRoles(en)
        notes[#notes + 1] = string.format("EN %+d", en)
    end

    local hexes = task.hexes and task.hexes[tier]
    if hexes ~= nil and hexes ~= 0 then
        AddHexAdjust(hexes)
        notes[#notes + 1] = string.format("%+d hex", hexes)
    end

    local restEn = task.restEn and task.restEn[tier]
    if restEn ~= nil and restEn ~= 0 then
        AddRestEn(restEn)
        notes[#notes + 1] = string.format("rest EN %+d", restEn)
    end

    local lost = task.lost and task.lost[tier]
    if lost ~= nil then
        SetLost(lost)
        notes[#notes + 1] = cond(lost, "LOST", "no longer lost")
    end

    if #notes == 0 then return nil end
    return table.concat(notes, ", ")
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

----------------------------------------------------------------------
-- Finishing a rest.
----------------------------------------------------------------------

-- Refill every Usage Dice pool on this crow whose item recharges on a rest
-- (The Rules, Equipment Usage Dice: a "Rest" entry restores the item's maximum
-- when the carrier finishes a rest). CrowdexInventory's own RestoreUsageDice
-- takes a UI row/env pair and cannot be driven headlessly, so this walks the
-- slots with the exported accessors instead. A nil `ud` reads as full, which is
-- how the inventory stores "untouched", so clearing the field IS the refill.
-- Returns the number of pools refilled.
local function RefillRestUsageDice(props)
    local inv = CrowdexInventoryUI
    if inv == nil or inv.GetSlot == nil then return 0 end
    local refilled = 0
    for _, kind in ipairs({"hands", "belt", "backpack"}) do
        for i = 1, (inv.ROW_CAPACITY[kind] or 0) do
            local slot = inv.GetSlot(props, kind, i)
            if slot ~= nil and slot.itemid ~= nil
                    and (inv.UsageDiceForItem(slot.itemid) or 0) > 0
                    and inv.UsageDiceRestore(slot.itemid) == "rest"
                    and slot.ud ~= nil then
                slot.ud = nil
                inv.SetSlot(props, kind, i, slot)
                refilled = refilled + 1
            end
        end
    end
    return refilled
end

-- Resolve a rest for every crow on the map (The Rules, Resting): full Stamina,
-- one wound cleared -- two for anyone being tended -- rest-recharging Usage
-- Dice refilled, and every expertise use restored.
--
-- Expertises are CharacterResources with usageLimit "long", and the engine
-- reads a resource as spent only while its recorded refreshid matches the
-- creature's current one (creature:GetResourceUsage in Resource.lua). So
-- handing the crow a fresh longRestId restores all thirty pools at once. The
-- whole party shares one id, because they share one rest. Draw Steel's own
-- creature:Rest is deliberately not used -- it also moves xp, victories and
-- class levels, none of which Crows has.
--
-- Resting in the Miasma is the exception: "When you finish a rest in the
-- Miasma, you don't regain any uses of your expertises, but all of the other
-- normal effects of resting apply." That is why the id is withheld rather than
-- the rest being skipped.
--
-- Returns a summary table:
--   { crows, wounds, dice, tended, miasma, expertises }.
local function FinishRest()
    local inv = CrowdexInventoryUI
    local crows = dmhub.GetTokens({ playerControlled = true })

    -- Who is being tended, and by whom. Tend Wounds targets a creature with at
    -- least 2 wounds who is not the tender, so a target only counts once even
    -- if two crows nominate them.
    local tendedBy = {}
    for _, tok in ipairs(crows) do
        if tok ~= nil and tok.valid then
            if GetRestActivity(tok.id) == REST_TEND then
                local target = GetTendTarget(tok.id)
                if target ~= nil and target ~= tok.id then
                    tendedBy[target] = tok.id
                end
            end
        end
    end

    -- The Miasma is an outdoor phenomenon and cannot enter enclosed stone or
    -- metal, so it applies in Wilderness only: villages sit inside sealed ruins
    -- and dungeons are indoors.
    local inMiasma = GetMode() == MODE_WILDERNESS
    local restId = dmhub.GenerateGuid()

    local summary = { crows = 0, wounds = 0, dice = 0, tended = 0, miasma = 0, expertises = 0 }

    for _, tok in ipairs(crows) do
        if tok ~= nil and tok.valid and tok.properties ~= nil then
            local isTended = tendedBy[tok.id] ~= nil
            tok:ModifyProperties{
                description = "Finish a rest",
                combine = true,
                execute = function()
                    local props = tok.properties

                    -- "At the end of a rest, you regain all your Stamina."
                    props.damage_taken = 0

                    -- "...and the number of wounds you have decreases by 1."
                    -- Tend Wounds makes it 2 for its target.
                    local toRemove = isTended and 2 or 1
                    for _ = 1, toRemove do
                        if inv ~= nil and inv.RemoveWound ~= nil
                                and inv.RemoveWound(props) ~= nil then
                            summary.wounds = summary.wounds + 1
                        end
                    end

                    summary.dice = summary.dice + RefillRestUsageDice(props)

                    -- Expertise uses come back with a fresh long-rest id --
                    -- unless the rest was spent in the Miasma.
                    if not inMiasma then
                        props.longRestId = restId
                        summary.expertises = summary.expertises + 1
                    end
                end,
            }
            summary.crows = summary.crows + 1
            if isTended then summary.tended = summary.tended + 1 end
        end
    end

    if inMiasma then
        summary.miasma = FireMiasmaCheck()
    end

    ClearRestActivities()
    return summary
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
    -- Reset to the configured turn length, not the 30-minute default, so a
    -- table running 20- or 60-minute turns does not silently snap back.
    local duration = GetDuration(doc.data)
    doc:BeginChange()
    doc.data.duration = duration
    doc.data.remaining = duration
    doc.data.running = false
    doc.data.endTime = nil
    doc:CompleteChange("Reset Dungeon Turn timer", {undoable = false})
end

-- Change how long a dungeon turn lasts. The remaining time is clamped to the
-- new length rather than reset, so shortening the turn mid-countdown does not
-- hand the party time back, and lengthening it does not extend the turn they
-- are already in. A running timer keeps ticking against the clamped value.
local function SetDuration(seconds)
    local doc = GetDoc()
    seconds = math.max(60, math.floor(seconds))
    local remaining = math.min(ComputeRemaining(doc.data), seconds)
    doc:BeginChange()
    doc.data.duration = seconds
    doc.data.remaining = remaining
    if doc.data.running then
        doc.data.endTime = dmhub.serverTime + remaining
    end
    doc:CompleteChange("Set Dungeon Turn length", {undoable = false})
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
    local paceDropdown
    local paceNote
    local speedDropdown
    local crowListPanel
    local emptyLabel
    local guideWarning
    local enValueLabel
    local enRoleNote
    local lostBanner
    local backOnTrackButton
    local tableDropdown
    local lastResultLabel
    local dayLabel
    local travelLabel

    -- A prompted task roll records itself here so its tier can be applied once
    -- the player finishes. Director-local: only the Director prompts rolls.
    local pending = {}

    local function ApplyPendingRolls()
        for key, entry in pairs(pending) do
            local action = dmhub.GetPlayerActionRequest(entry.actionid)
            if action == nil then
                pending[key] = nil
            else
                local info = action.info.tokens[entry.tokenid]
                if info ~= nil then
                    if info.status == "complete" then
                        local tier = TierFromResult(info.result)
                        if tier ~= nil then
                            local note = ApplyTaskTier(entry.task, tier)
                            if note ~= nil and lastResultLabel ~= nil then
                                lastResultLabel.text = string.format("%s -- tier %d: %s",
                                    entry.task.text, tier, note)
                                lastResultLabel:SetClass("collapsed", false)
                            end
                        end
                        pending[key] = nil
                    elseif info.status == "cancel" then
                        pending[key] = nil
                    end
                end
            end
        end
    end

    ------------------------------------------------------------------
    -- One crow: role, task, and a prompt button.
    ------------------------------------------------------------------

    local function CreateCrowRow(tokenid)
        local nameLabel
        local roleDropdown
        local taskDropdown
        local promptButton

        nameLabel = gui.Label{
            classes = {"sizeXs"},
            width = 96,
            height = 22,
            valign = "center",
        }

        roleDropdown = gui.Dropdown{
            classes = {"sizeXs"},
            options = ROLE_OPTIONS,
            idChosen = GetRole(tokenid),
            width = 104,
            height = 24,
            valign = "center",
            change = function(element)
                -- Only one creature can be the Guide. Taking the role moves it.
                if element.idChosen == ROLE_GUIDE then
                    local held = GuideTokenId()
                    if held ~= nil and held ~= tokenid then
                        SetRole(held, ROLE_NONE)
                    end
                end
                SetRole(tokenid, element.idChosen)
                block:FireEvent("refreshWilderness")
            end,
        }

        taskDropdown = gui.Dropdown{
            classes = {"sizeXs"},
            options = { { id = TASK_NONE, text = "(pick task)" } },
            idChosen = TASK_NONE,
            width = 156,
            height = 24,
            hmargin = 4,
            valign = "center",
            change = function(element)
                SetTask(tokenid, element.idChosen)
                block:FireEvent("refreshWilderness")
            end,
        }

        promptButton = gui.Button{
            classes = {"sizeXs"},
            text = "Prompt Roll",
            width = 92,
            height = 24,
            halign = "right",
            valign = "center",
            hover = function(element)
                gui.Tooltip("Ask this crow's player to roll their task's test")(element)
            end,
            press = function(element)
                local tok = dmhub.GetCharacterById(tokenid)
                if tok == nil then return end
                local roleId = GetRole(tokenid)
                local task = nil
                if roleId == ROLE_GUIDE and GetLost() then
                    task = BACK_ON_TRACK
                else
                    task = TaskInfo(roleId, GetTask(tokenid))
                end
                if task == nil then return end
                local actionid = PromptTaskRoll(tok, roleId, task)
                if actionid ~= nil then
                    pending[tokenid] = { actionid = actionid, tokenid = tokenid, task = task }
                end
            end,
        }

        return gui.Panel{
            flow = "horizontal",
            width = "100%",
            height = "auto",
            vmargin = 1,

            nameLabel,
            roleDropdown,
            taskDropdown,
            promptButton,

            refreshRow = function(element)
                local tok = dmhub.GetCharacterById(tokenid)
                if tok == nil then return end
                nameLabel.text = tok.name or "Crow"

                local roleId = GetRole(tokenid)
                roleDropdown.idChosen = roleId

                -- While lost the Guide's job is finding the way again, so their
                -- task picker is replaced by that single fixed test.
                local guideLost = (roleId == ROLE_GUIDE and GetLost())
                if guideLost then
                    taskDropdown.options = { { id = "backontrack", text = BACK_ON_TRACK.text } }
                    taskDropdown.idChosen = "backontrack"
                elseif roleId == ROLE_NONE then
                    taskDropdown.options = { { id = TASK_NONE, text = "--" } }
                    taskDropdown.idChosen = TASK_NONE
                else
                    taskDropdown.options = TaskOptions(roleId)
                    taskDropdown.idChosen = GetTask(tokenid)
                end

                taskDropdown:SetClass("collapsed", roleId == ROLE_NONE)

                local ready = guideLost or
                    (roleId ~= ROLE_NONE and TaskInfo(roleId, GetTask(tokenid)) ~= nil)
                promptButton:SetClass("collapsed", not ready)
            end,
        }
    end

    ------------------------------------------------------------------
    -- Day, pace and distance.
    ------------------------------------------------------------------

    dayLabel = gui.Label{
        classes = {"sizeXs"},
        width = "auto-grow",
        height = "auto",
        halign = "left",
        color = "#ddd",
    }

    travelLabel = gui.Label{
        classes = {"sizeXs"},
        width = "100%",
        height = "auto",
        color = "#9a9a9a",
        bmargin = 2,
    }

    local endDayButton = gui.Button{
        classes = {"sizeXs"},
        text = "End Day",
        width = 78,
        height = 24,
        halign = "right",
        hover = function(element)
            gui.Tooltip("Advance the day and clear what today's rolls banked")(element)
        end,
        press = function(element)
            AdvanceDay()
            block:FireEvent("refreshWilderness")
        end,
    }

    paceDropdown = gui.Dropdown{
        classes = {"sizeXs"},
        options = PACE_OPTIONS,
        idChosen = GetPace(),
        width = 176,
        height = 24,
        valign = "center",
        hover = function(element)
            gui.Tooltip("Pace sets both the distance covered and the day's encounter number")(element)
        end,
        change = function(element)
            SetPace(element.idChosen)
            block:FireEvent("refreshWilderness")
        end,
    }

    paceNote = gui.Label{
        classes = {"sizeXs"},
        width = "auto-grow",
        height = "auto",
        halign = "left",
        hmargin = 6,
        valign = "center",
        color = "#9a9a9a",
    }

    speedDropdown = gui.Dropdown{
        classes = {"sizeXs"},
        options = SPEED_BAND_OPTIONS,
        idChosen = GetSpeedBand(),
        width = 236,
        height = 24,
        valign = "center",
        hover = function(element)
            gui.Tooltip("The group travels at the speed of its slowest member (or its mount or vehicle)")(element)
        end,
        change = function(element)
            SetSpeedBand(element.idChosen)
            block:FireEvent("refreshWilderness")
        end,
    }

    local function TerrainToggle(key, label, tip)
        return gui.Check{
            classes = {"sizeXs"},
            text = label,
            value = GetTerrain(key),
            width = 150,
            height = 22,
            hover = function(element)
                gui.Tooltip(tip)(element)
            end,
            change = function(element)
                SetTerrain(key, element.value)
                block:FireEvent("refreshWilderness")
            end,
            refreshTerrain = function(element)
                element.value = GetTerrain(key)
            end,
        }
    end

    local terrainRow = gui.Panel{
        flow = "horizontal",
        width = "100%",
        height = "auto",
        wrap = true,
        tmargin = 2,

        TerrainToggle("road", "Road all day",
            "Following a road for the whole travel day: +1 hex, but the EN drops by 1."),
        TerrainToggle("downstream", "Downstream",
            "Moving downstream on a body of water: +1 hex."),
        TerrainToggle("upstream", "Upstream / river crossing",
            "Moving upstream, or crossing a river without a water vehicle: -1 hex."),
    }

    ------------------------------------------------------------------
    -- Encounter number.
    ------------------------------------------------------------------

    local function enStep(delta)
        return gui.Button{
            classes = {"sizeXs"},
            text = delta > 0 and "+" or "-",
            width = 26,
            height = 24,
            valign = "center",
            press = function(element)
                SetEnBase(GetEnBase() + delta)
                block:FireEvent("refreshWilderness")
            end,
        }
    end

    enValueLabel = gui.Label{
        classes = {"sizeXs"},
        width = 34,
        height = "auto",
        halign = "center",
        textAlignment = "center",
        valign = "center",
        color = "white",
        bold = true,
    }

    enRoleNote = gui.Label{
        classes = {"sizeXs"},
        width = "auto-grow",
        height = "auto",
        halign = "left",
        hmargin = 6,
        valign = "center",
        color = "#9a9a9a",
    }

    local checkButton = gui.Button{
        classes = {"sizeXs"},
        text = "Encounter Check",
        width = 130,
        height = 24,
        halign = "right",
        valign = "center",
        hover = function(element)
            gui.Tooltip("Roll 1d10. An encounter occurs on a result equal to or higher than the EN.")(element)
        end,
        press = function(element)
            local en = GetEffectiveEn()
            local roll = dmhub.RollInstant("1d10")
            local hit = roll >= en
            lastResultLabel.text = string.format(
                "Encounter check: rolled %d against EN %d -- %s",
                roll, en, hit and "ENCOUNTER" or "no encounter")
            lastResultLabel:SetClass("collapsed", false)
        end,
    }

    ------------------------------------------------------------------
    -- Lost.
    ------------------------------------------------------------------

    lostBanner = gui.Label{
        classes = {"sizeXs", "collapsed"},
        width = "auto-grow",
        height = "auto",
        halign = "left",
        valign = "center",
        color = "#e06b6b",
        text = "The group is lost. The Ref tracks where they actually are.",
    }

    backOnTrackButton = gui.Button{
        classes = {"sizeXs", "collapsed"},
        text = "Not Lost",
        width = 84,
        height = 24,
        halign = "right",
        valign = "center",
        hover = function(element)
            gui.Tooltip("Clear the lost flag -- they found a map, a landmark, or someone gave directions")(element)
        end,
        press = function(element)
            SetLost(false)
            block:FireEvent("refreshWilderness")
        end,
    }

    ------------------------------------------------------------------
    -- Encounter table + Miasma.
    ------------------------------------------------------------------

    tableDropdown = gui.Dropdown{
        classes = {"sizeXs"},
        options = GetEncounterTableOptions(),
        idChosen = GetEncounterTableId(),
        width = 200,
        height = 24,
        valign = "center",
        change = function(element)
            SetEncounterTableId(element.idChosen)
        end,
    }

    local rollTableButton = gui.Button{
        classes = {"sizeXs"},
        text = "Roll Encounter",
        width = 122,
        height = 24,
        halign = "right",
        valign = "center",
        press = function(element)
            local id = GetEncounterTableId()
            if id == "" then return end
            ShowEncounterTableRoll(id, function(total, text)
                lastResultLabel.text = string.format("Encounter: %s", text)
                lastResultLabel:SetClass("collapsed", false)
            end)
        end,
    }

    local miasmaButton = gui.Button{
        classes = {"sizeXs"},
        text = "Miasma Check",
        width = 122,
        height = 24,
        halign = "left",
        tmargin = 4,
        hover = function(element)
            gui.Tooltip("Prompt every crow's Mind test against the Miasma. Normally this happens at the end of a rest -- the Finish Rest button does it for you.")(element)
        end,
        press = function(element)
            local n = FireMiasmaCheck()
            lastResultLabel.text = string.format("Miasma test prompted for %d crow%s.",
                n, n == 1 and "" or "s")
            lastResultLabel:SetClass("collapsed", false)
        end,
    }

    lastResultLabel = gui.Label{
        classes = {"sizeXs", "collapsed"},
        width = "100%",
        height = "auto",
        color = "#9a9a9a",
        tmargin = 2,
    }

    ------------------------------------------------------------------
    -- Crow list.
    ------------------------------------------------------------------

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
        text = "No Guide assigned -- the group cannot choose its route.",
        width = "100%",
        height = "auto",
        color = "#e06b6b",
        tmargin = 2,
    }

    ------------------------------------------------------------------
    -- Assembly.
    ------------------------------------------------------------------

    local function Row(...)
        return gui.Panel{
            flow = "horizontal",
            width = "100%",
            height = "auto",
            valign = "center",
            tmargin = 2,
            ...
        }
    end

    block = gui.Panel{
        flow = "vertical",
        width = "100%",
        height = "auto",
        tmargin = 8,

        Row(dayLabel, endDayButton),
        travelLabel,
        Row(paceDropdown, paceNote),
        Row(speedDropdown),
        terrainRow,
        Row(
            gui.Label{
                classes = {"sizeXs"},
                width = 26,
                height = "auto",
                valign = "center",
                color = "#9a9a9a",
                text = "EN",
            },
            enStep(-1), enValueLabel, enStep(1), enRoleNote, checkButton
        ),
        Row(lostBanner, backOnTrackButton),
        crowListPanel,
        emptyLabel,
        guideWarning,
        Row(tableDropdown, rollTableButton),
        miasmaButton,
        lastResultLabel,

        refreshWilderness = function(element)
            ApplyPendingRolls()

            dayLabel.text = string.format("Day %d", GetDay())
            travelLabel.text = "Travel: " .. GetTravelDistanceText()

            paceDropdown.idChosen = GetPace()
            paceNote.text = PACE_INFO[GetPace()].note
            speedDropdown.idChosen = GetSpeedBand()
            terrainRow:FireEventTree("refreshTerrain")

            enValueLabel.text = tostring(GetEffectiveEn())
            local roles = GetEnRoles()
            if roles ~= 0 then
                enRoleNote.text = string.format("base %d, role results %+d", GetEnBase(), roles)
            else
                enRoleNote.text = string.format("base %d from pace", GetEnBase())
            end

            local lost = GetLost()
            lostBanner:SetClass("collapsed", not lost)
            backOnTrackButton:SetClass("collapsed", not lost)

            local crows = dmhub.GetTokens({ playerControlled = true })
            table.sort(crows, function(a, b)
                return (a.name or "") < (b.name or "")
            end)

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

            emptyLabel:SetClass("collapsed", #crows > 0)
            guideWarning:SetClass("collapsed", #crows == 0 or GuideTokenId() ~= nil)
        end,
    }

    return block
end

local function CreateRestBlock()
    local block
    local crowListPanel
    local emptyLabel
    local resultLabel

    -- Legal Tend Wounds targets: another crow carrying at least 2 wounds
    -- ("Pick a creature who has at least 2 wounds who rests with you. You can't
    -- choose yourself.").
    local function TendCandidates(selfId)
        local options = { { id = "none", text = "(pick target)" } }
        local inv = CrowdexInventoryUI
        for _, tok in ipairs(dmhub.GetTokens({ playerControlled = true })) do
            if tok ~= nil and tok.valid and tok.id ~= selfId and tok.properties ~= nil then
                local wounds = 0
                if inv ~= nil and inv.CountWoundedSlots ~= nil then
                    wounds = inv.CountWoundedSlots(tok.properties) or 0
                end
                if wounds >= 2 then
                    options[#options + 1] = {
                        id = tok.id,
                        text = string.format("%s (%d)", tok.name or "Crow", wounds),
                    }
                end
            end
        end
        return options
    end

    local function CreateRestRow(tokenid)
        local nameLabel
        local activityDropdown
        local tendDropdown

        nameLabel = gui.Label{
            classes = {"sizeXs"},
            width = 110,
            height = 22,
            valign = "center",
        }

        activityDropdown = gui.Dropdown{
            classes = {"sizeXs"},
            options = REST_ACTIVITY_OPTIONS,
            idChosen = GetRestActivity(tokenid),
            width = 132,
            height = 24,
            valign = "center",
            change = function(element)
                SetRestActivity(tokenid, element.idChosen)
                block:FireEvent("refreshRest")
            end,
        }

        tendDropdown = gui.Dropdown{
            classes = {"sizeXs", "collapsed"},
            options = TendCandidates(tokenid),
            idChosen = GetTendTarget(tokenid) or "none",
            width = 132,
            height = 24,
            hmargin = 4,
            valign = "center",
            hover = function(element)
                gui.Tooltip("Who this crow tends. They lose 2 wounds instead of 1.")(element)
            end,
            change = function(element)
                SetTendTarget(tokenid, element.idChosen ~= "none" and element.idChosen or nil)
            end,
        }

        return gui.Panel{
            flow = "horizontal",
            width = "100%",
            height = "auto",
            vmargin = 1,

            nameLabel,
            activityDropdown,
            tendDropdown,

            refreshRow = function(element)
                local tok = dmhub.GetCharacterById(tokenid)
                if tok == nil then return end

                local inv = CrowdexInventoryUI
                local wounds = 0
                if inv ~= nil and inv.CountWoundedSlots ~= nil and tok.properties ~= nil then
                    wounds = inv.CountWoundedSlots(tok.properties) or 0
                end
                nameLabel.text = string.format("%s%s", tok.name or "Crow",
                    wounds > 0 and string.format("  (%d)", wounds) or "")

                local activity = GetRestActivity(tokenid)
                activityDropdown.idChosen = activity

                local tending = activity == REST_TEND
                tendDropdown:SetClass("collapsed", not tending)
                if tending then
                    -- Rebuild the candidate list each refresh: wound counts move
                    -- as the party takes damage, so who is a legal target moves
                    -- with them.
                    tendDropdown.options = TendCandidates(tokenid)
                    tendDropdown.idChosen = GetTendTarget(tokenid) or "none"
                end
            end,
        }
    end

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

    resultLabel = gui.Label{
        classes = {"sizeXs", "collapsed"},
        width = "100%",
        height = "auto",
        color = "#9a9a9a",
        tmargin = 2,
    }

    local finishButton = gui.Button{
        classes = {"sizeXs"},
        text = "Finish Rest",
        width = 110,
        height = 24,
        halign = "left",
        tmargin = 4,
        hover = function(element)
            gui.Tooltip("Full Stamina, one wound cleared (two if tended), rest-recharging Usage Dice refilled, and expertise uses restored for every crow. A rest in the Wilderness restores no expertises and prompts the Miasma test.")(element)
        end,
        press = function(element)
            local s = FinishRest()
            local parts = {
                string.format("%d crow%s rested", s.crows, s.crows == 1 and "" or "s"),
                string.format("%d wound%s cleared", s.wounds, s.wounds == 1 and "" or "s"),
            }
            if s.tended > 0 then
                parts[#parts + 1] = string.format("%d tended", s.tended)
            end
            if s.dice > 0 then
                parts[#parts + 1] = string.format("%d usage die pool%s refilled", s.dice, s.dice == 1 and "" or "s")
            end
            if s.expertises > 0 then
                parts[#parts + 1] = "expertises restored"
            end
            if s.miasma > 0 then
                parts[#parts + 1] = string.format(
                    "no expertise recovery in the Miasma; test prompted for %d", s.miasma)
            end
            resultLabel.text = table.concat(parts, ", ") .. "."
            resultLabel:SetClass("collapsed", false)
            block:FireEvent("refreshRest")
        end,
    }

    block = gui.Panel{
        flow = "vertical",
        width = "100%",
        height = "auto",
        tmargin = 8,

        gui.Label{
            classes = {"sizeXs"},
            text = "REST",
            width = "100%",
            height = "auto",
            color = "#9a9a9a",
            bmargin = 2,
        },
        crowListPanel,
        emptyLabel,
        finishButton,
        resultLabel,

        refreshRest = function(element)
            local crows = dmhub.GetTokens({ playerControlled = true })
            table.sort(crows, function(a, b)
                return (a.name or "") < (b.name or "")
            end)

            local ids = {}
            for _, c in ipairs(crows) do ids[#ids + 1] = c.id end
            local signature = table.concat(ids, ",")

            if signature ~= crowListPanel.data.signature then
                local oldRows = crowListPanel.data.rowsById
                local newRows = {}
                local children = {}
                for _, c in ipairs(crows) do
                    local r = oldRows[c.id] or CreateRestRow(c.id)
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

            emptyLabel:SetClass("collapsed", #crows > 0)
            finishButton:SetClass("collapsed", #crows == 0)
        end,
    }

    return block
end

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
    local lengthDropdown

    -- Forward-declared so updateDisplay (defined below) can close over them
    -- before they are assigned further down.
    local modeSelector
    local dungeonTurnBlock
    local wildernessBlock
    local restBlock

    if isDM then
        -- Editable clock: click to type a new time as "mm:ss" or a number of
        -- minutes. While running it counts down live, but we never overwrite the
        -- text while the Director has it focused (mid-edit).
        timeLabel = gui.Input{
            classes = {"timerInput"},
            text = FormatTime(ComputeRemaining(GetDoc().data)),
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
                gui.Tooltip(string.format("Reset to %s", FormatTime(GetDuration(GetDoc().data))))(element)
            end,
            press = function(element)
                ResetTimer()
            end,
        }

        -- Turn length. Reads the synced duration on every refresh so a change
        -- made on another Director client shows up here too.
        lengthDropdown = gui.Dropdown{
            classes = {"sizeXs"},
            options = DUNGEON_TURN_LENGTH_OPTIONS,
            idChosen = tostring(math.floor(GetDuration(GetDoc().data))),
            width = 140,
            height = 24,
            valign = "center",
            hover = function(element)
                gui.Tooltip("How long a dungeon turn lasts (The Rules, Adjusting DT Time)")(element)
            end,
            change = function(element)
                local secs = tonumber(element.idChosen)
                if secs ~= nil then
                    SetDuration(secs)
                end
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
            lengthDropdown,
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
        if restBlock ~= nil then
            restBlock:FireEvent("refreshRest")
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

            -- Reflect a length set on another Director client. Only write when
            -- it actually differs, so we don't fight the dropdown mid-interaction.
            if lengthDropdown ~= nil then
                local durationId = tostring(math.floor(duration))
                if lengthDropdown.idChosen ~= durationId then
                    lengthDropdown.idChosen = durationId
                end
            end
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
    -- The rest block sits below both and shows in every mode: crows rest in
    -- dungeons, in the wild and in town alike.
    if isDM then
        wildernessBlock = CreateWildernessBlock()
        restBlock = CreateRestBlock()
    end

    local children = { modeHeader, modeSelector, dungeonTurnBlock }
    if wildernessBlock ~= nil then
        children[#children + 1] = wildernessBlock
    end
    if restBlock ~= nil then
        children[#children + 1] = restBlock
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
            mod:GetDocumentPath(REST_DOC),
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
