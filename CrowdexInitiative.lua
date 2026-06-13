local mod = dmhub.GetModLoading()

-- Crows initiative. Loaded after the Draw Steel initiative (MCDMInitiativeQueue /
-- MCDMInitiativeBar), so the overrides here replace the Draw Steel behavior for
-- Crows games (the Crowdex module is only loaded for Crows).
--
-- Crows turn order (The Rules booklet, "Who Goes First?"):
--   At the start of each round of combat, a player of the Ref's choice rolls
--   1d10. On a 6+ the PCs and their allies take their turns first, followed by
--   their enemies; on a 5 or lower the enemies go first. Within a side the
--   players (or the Ref) choose the order their creatures act. This roll is
--   repeated at the start of every round.
--
-- This differs from Draw Steel in two ways, both handled below:
--   1. The "who goes first" side is re-rolled every round, not fixed for the
--      whole encounter (see NextRound).
--   2. The side that goes first moves ALL of its creatures before the other
--      side acts, instead of the two sides alternating turn-by-turn (see
--      NextTurn). Draw Steel's IsPlayersTurn already hands the turn to the only
--      side with unmoved entries; we just need to stop the per-turn side flip so
--      the active side keeps acting while it still has creatures to move.

-- 1. The active side keeps the turn until all of its creatures have moved.
--    Draw Steel's NextTurn flips playersTurn after every single turn (alternating
--    sides); Crows does not. We let the base method run (telemetry, SetTurnTaken,
--    end-of-round detection / NextRound) and then, as long as we did not roll over
--    into a new round, restore playersTurn so the same side continues. When a new
--    round does begin, NextRound (below) has already set the side for the new
--    round, so we leave its value alone.
local g_baseNextTurn = InitiativeQueue.NextTurn
function InitiativeQueue.NextTurn(self, initiativeid)
    local prevPlayersTurn = self.playersTurn
    local newRound = g_baseNextTurn(self, initiativeid)
    if not newRound then
        self.playersTurn = prevPlayersTurn
    end
    return newRound
end

-- 2. Re-roll who goes first at the start of every round, and skip the Draw Steel
--    malice / villain-action bookkeeping (Crows has neither). We pick a valid
--    random side here so the queue is always in a consistent state even with no
--    UI; the per-round "who goes first" banner (see the NewRound override) shows
--    the actual d10 roll and overwrites playersGoFirst with its result.
function InitiativeQueue.NextRound(self)
    self.playersGoFirst = math.random(1, 2) == 1
    self.playersTurn = self.playersGoFirst
    self.round = self.round + 1
    self.turn = 1
    self.priorityids = nil

    audio.DispatchSoundEvent("UI.RoundStart")
end

-- 3. Show the "who goes first" d10 banner at the start of every round. GameHud:NewRound
--    fires only when combat rolls over into round 2 or later (round 1's roll happens
--    during combat setup), which is exactly when Crows re-rolls turn order. NewRound
--    runs on the single client that advanced the round; the banner broadcasts itself to
--    the other users. The banner's roll overwrites the random side NextRound picked above.
local g_baseNewRound = GameHud.NewRound
function GameHud:NewRound()
    g_baseNewRound(self)

    if showDrawSteelRerollBanner ~= nil then
        showDrawSteelRerollBanner()
    end
end
