# Crowdex Character Panel Design

Side-panel (~340px) and detail-panel layout for the Crows VTT module inside DMHub.
The Draw Steel `MCDMCharacterPanel.lua` is the idiom reference; this is not a port
of it. Crows is a fragile-PC inventory game, so the panel is built around the
4-row inventory sheet, not around a big stamina bar.

Conventions used in mockups: `[X]` = filled, `[ ]` = empty cell, `|` and `-` are
panel borders, `*` = wound marker, `o` = unfilled AD pip, `@` = filled AD pip.

---

## 1. Side-panel layout (340px wide)

The whole side panel is a stack of collapsible sections (`TacPanel.CollapsiblePanel`
idiom) so players can hide the bits they aren't actively using. Default expanded:
Summary, Vitals, Inventory, Characteristics. Default collapsed: Skills, Conditions.

```
+--------------------------------------------------+ <- 340px
|  [ avatar 96x96 ]   Mira Brassknuckle           |
|                     Acolyte of the Healer        |
|                     A:+1  M:+2  S:0   Spd 5     |
+--------------------------------------------------+
|  STAMINA                          [ 5 / 7 ]  +   | <- input + dmg button
|  [@@@@@.@@]   wounds 0 / 10       SPD 5          | <- Speed lives here
+--------------------------------------------------+
|  !! UNASSIGNED WOUNDS x3 !!     [ Assign... ]    | <- flashes when > 0
+--------------------------------------------------+
|  ARMOR DEFENSE                                   |
|  Light Armor      [@@@@@]  5/5                   |
|  Shield           [@@@_@]  4/5                   |
+--------------------------------------------------+
|  CONDITIONS                                      |
|  ( Grabbed ) ( Boned x2 )      + Add             |
+--------------------------------------------------+
|  HANDS                              [ swap ]     |
|  +------+ +------+                               |
|  | Sword| | Shld | <- each cell 60x80           |
|  +------+ +------+                               |
|                                                  |
|  BELT                                            |
|  +------+ +------+                               |
|  | Pot5 | | empty|                               |
|  +------+ +------+                               |
|                                                  |
|  BACKPACK                                        |
|   1     2     3     4     5                      |
|  +----+ +----+ +----+ +----+ +----+              |
|  |Lant| |LtAr| |LtAr| |    | |  * |  <- *=wound |
|  +----+ +----+ +----+ +----+ +----+              |
|   6     7     8     9    10                      |
|  +----+ +----+ +----+ +----+ +----+              |
|  |Rope| |Rat5| |    | |Tor2| |    |              |
|  +----+ +----+ +----+ +----+ +----+              |
+--------------------------------------------------+
|  WORN (magic)                       [ toggle ]   |
|  Head [ ] Neck[ ] Arms[ ] Waist[ ] Ring[ ] Feet[ ]
+--------------------------------------------------+
|  CHARACTERISTICS                                 |
|  +----+ +----+ +----+                           |
|  |  +1| |  +2| |  0 |   <- click to test        |
|  | AGI| | MND| | STR|                           |
|  +----+ +----+ +----+                           |
+--------------------------------------------------+
|  SKILLS (22)              [ filter: combat v ]   |
|  Alchemy +1  Bashing +1  Religious Lore +2 ...   |
+--------------------------------------------------+
```

Section order is `reorderSections`-draggable, same as Draw Steel.

**Interaction affordances:**

- Avatar: click = open token, right-click = portrait submenu.
- Stamina number: typing edits directly; the `+` opens a damage-application
  dialog that lets the player choose which AD source eats the hit (see section 5).
- AD row: click an armor name = open its card. Click a single AD pip = mark it
  spent / un-spent (GMs and the owner only).
- Condition chip: click = remove, `+ Add` opens a condition menu.
- Inventory cell: hover = tooltip with the card summary; click = popup full card;
  drag = relocate within row; drag to another row = blocked unless current
  rules allow (out of combat = always, in combat = triggers a maneuver dialog,
  see section 7).
- Worn slot: click empty = picker for magic items; click filled = card popup.
- Characteristic block: click = roll 2d10 + char in chat. Hover = breakdown.
- Skills row: collapsed shows count; expanded shows a flat list with a filter
  dropdown (All / Combat / Lore / Spellcasting / Weapon) since the full list is
  too long for the sidebar.

---

## 2. Character Sheet tab (full-screen, registered via `CharSheet.RegisterTab`)

The expanded view does NOT live in the in-dock "detail" area underneath the
side panel -- that area stays empty (the sidebar is the operational view and
already covers normal play). Instead, the expanded view is a dedicated tab
registered into the engine's character-sheet dialog (`CharacterSheetFramework
.lua` -> `CharSheet.RegisterTab{}`), reached by opening a character's full
sheet (the dialog at `DMHub CharacterSheet Base/CharacterSheetMain.lua:15` ->
`CharSheet.CreateCharacterSheet`). The Draw Steel inventory tab
(`DrawSteelInventory.lua:3884`) is the closest existing analog -- mirror its
shape:

```lua
CharSheet.RegisterTab{
    id = "CrowsSheet",     -- unique id (DeregisterTab key)
    text = "Sheet",        -- tab label
    order = 1,             -- tabs sort by order then text
    panel = CreateCrowdexSheetTab,  -- returns the tab content panel
}
```

The tab content is the three-column layout below. It uses three columns when
the dialog is wide enough, collapsing to two and then one as it narrows. Crows
should probably ALSO deregister the Draw Steel tabs it doesn't need (Career,
Class, Kit, etc.) via `CharSheet.DeregisterTab(id)` from the same file, so the
Crows tab strip isn't littered with Draw Steel concepts -- the deregistration
calls would live in the Crowdex bootstrap right after the Draw Steel codex
finishes loading.

```
+----------------------------------------------------------------------------+
|  Mira Brassknuckle             Acolyte of the Healer        [edit]        |
+----------------------------------------------------------------------------+
| SKILLS (full grid)        | SPELLBOOKS                | TRAITS / FEATURES  |
| GENERAL          22 cols  | Healing Book             | Trait: Bedside    |
|  Alchemy   +1             |   UD [@@_]  3/5 (Rest)   |   Manner          |
|  Bashing   +1             |   Spells: Cure, Bless,   | Trait: Calm       |
|  Climb     0              |     Mend, Soothe, Ward   | Feature: -        |
|  Endurance 0              |                          |                    |
|  Handle An.+1             | Conjuration Book         | INJURIES (wounds) |
|  ...                      |   UD [@_]   2/4 (Rest)   |  Slot 1: Sword arm|
| SPELLCASTING              |   Spells: ...            |   "stabbed by orc"|
|  Alteration 0             |                          |  + Add note       |
|  Benefac.   +2            |                          |                    |
|  Necromancy 0  ...        |                          |                    |
| WEAPON SKILLS             |                          |                    |
|  Bashing   +1             |                          |                    |
|  Bow       0              |                          |                    |
|  Chopping  0  ...         |                          |                    |
+----------------------------------------------------------------------------+
|  CARD BINDER (all cards held)                          [ filter v ]        |
|  +-------+ +-------+ +-------+ +-------+ +-------+ +-------+              |
|  | Sword | | Shield| | LtArmr| | Potion| | Lantern| | Rope  |             |
|  | M1    | | AD@5  | | AD@5  | | x5    | | UD@@   | |       |             |
|  | 12-16 | | broken| | worn  | |       | | 2 left | |       |             |
|  | 17+   | |       | |       | |       | |        | |       |             |
|  +-------+ +-------+ +-------+ +-------+ +-------+ +-------+              |
|                                                                            |
|  ROLLS + LOG                                                               |
|  -- chronological list of test rolls, attack rolls, damage taken, --       |
|  -- UD rolls at end of DT, wound assignments, etc.                 --      |
+----------------------------------------------------------------------------+
```

The card binder duplicates inventory contents but as full cards: this is where
you check exact damage tiers, traits, crafting recipes, and gp values. It's
also the only place that shows ALL UD pools in one glance ("which of my items
will probably go away at end of DT?").

A narrower variant of the tab (e.g. when the character-sheet dialog is dragged
to a smaller width) collapses to columns 1 and 2 and hides the card binder,
then to a single column scroll at the narrowest.

Note: the in-dock detail area below the side panel stays empty (1px stub) --
the character-sheet tab supersedes it as the expanded view. We keep the
`CreateCharacterDetailsPanel` override returning the 1px stub so the engine
doesn't render the Draw Steel detail behaviour underneath.

---

## 3. Backpack-as-wound-tracker duality

The slot can hold (item only) | (wound only) | (item + wound). All three are
common. The visualization must read all three at a glance, never let the wound
hide the item, and obviously communicate "this slot is costing me speed".

### Recommended treatment: bevelled bottom-edge stripe + corner gash

```
+------+      +------+      +------+
| Lant |      |  *   |      | Lant |
| ern  |      |      |      | ern *|
|      |      |      |      |     /|
|======|      |======|      |======|
+------+      +------+      +------+
 item-only     wound-only    item+wound
 no stripe    full red       red stripe + corner gash
              fill            on item cell
```

A wounded slot grows a thick red bottom stripe (the `=` band) regardless of
whether it has an item, and a diagonal "gash" decoration appears in the top-right
corner of the item icon. The stripe alone signals the speed penalty (because
every wound costs 1, regardless of item presence), and the gash is the
content-overlay marker for the wound itself. The item card underneath stays
fully legible because nothing covers the icon body. Hover gives a tooltip with
the player's wound note (e.g. "shoulder, stabbed by gnoll on DT 4").

Why this wins over the two alternatives I considered:

| Alternative | Tradeoff |
|---|---|
| **Overlay icon (red drop on top of item)** | Obscures item icon, makes item-only vs item+wound distinguishable only by overlay opacity. Bad in a 60x80 cell. |
| **Side-by-side mini cell (slot split in half: item left, wound right)** | Halves your icon area for the more common item-only case just to support wound display. Doesn't scale to small cells. |

The recommended bevelled-stripe approach pays no cost when there's no wound,
and the speed-cost signal lines up vertically across all 10 cells: at a glance
you can count "the bottom row of stripes" and know your speed without doing
arithmetic.

**Speed indicator** lives on the vitals strip (top right of the STAMINA row;
see section 1 mockup), NOT inline with the BACKPACK heading. It's a derived
combat stat that needs to be glanceable at all times. It's red when reduced
below base and tooltip-explains the calculation ("base 5, -2 from wounds in
slots 5 and 8 = 3"). Click it for a "which wound to remove next rest?"
picker.

---

## 4. Card representation in a cell

A 60x80 cell is too small for the full card. Recommended compact layout
(applies identically to hand, belt, backpack, worn cells - which keeps drag
between rows visually coherent):

```
+--------+
| ICON   |    <- 36x36 art (category icon or item-specific glyph)
|  ICN   |
|        |
| Lanter |    <- name, 2 lines max, ellipsis
|--------|
| UD @@ x5  | <- bottom strip: UD pips left, stack count right (`xN`)
+--------+
```

Color = category. A 3px left-edge stripe on the cell, with a small palette:

- weapon (red), armor / shield (steel blue), consumable (green),
  light source (amber), tool / kit (purple), spellbook (indigo),
  magic item (gold), mundane / misc (grey).

This means scanning the backpack you can see "weapons in 1-3, consumables in
4-6, tools in 7-9" without reading names. Multi-slot items render as a single
wide cell that spans 2 (or 3, or 4) cells with the name centered; the slot
numbers under the cells still show as `1` `2` etc, and the wound stripe still
attaches to each underlying slot independently (this is the key reason multi-slot
items must not span the wound stripe area visually - the stripe is per-slot).

UD pips: a row of up to 6 small filled / hollow circles. >6 falls back to
`UD 7+` numeric. Stack count omitted when stack=1; shown as `x3` for stacks.

Hover tooltip = compressed card view (name, range, tier results, traits,
UD state). Click = popup full card overlay (same template as the binder card)
with edit affordances (decrement stack, manually roll UD, drop, repair AD if
this is an armor card).

---

## 5. AD display

Each worn armor piece has its own AD pool, and the player CHOOSES which pool
eats incoming damage, so the AD display must be:

1. enumerable per piece (no aggregate bar),
2. clickable as a damage target,
3. visible from the same place where you apply damage.

Recommended: dedicated ARMOR DEFENSE row in the vitals strip (shown in the
section 1 mockup). Each line is `Name [pips] cur/max`, color-codes by armor
piece, and turns red + crosses out the name when broken. **Not** inline on
the armor's inventory card -- inline would force the player to scroll between
backpack and stamina during a damage application, which is the worst possible
ergonomic.

When the player clicks the `+` (apply damage) next to STAMINA they get a
dialog:

```
   Apply damage to Mira: [ 6 ]  [ piercing? ]
   Absorb with:
     ( ) Light Armor  AD 5  (3 left)
     ( ) Shield       AD 5  (4 left)
     ( ) Stamina      5/7
     ( ) Custom split: [ ][ ][ ]
   [Apply]  [Cancel]
```

Default selection is the AD pool with the most remaining; piercing skips AD
selection and goes straight to stamina/wounds. After Apply, any wounds
generated go into an **unassigned wounds queue** (see section 5b) -- the
damage dialog closes immediately and play continues. The player resolves slot
assignment later from the queue's flashing tray in the vitals strip, so
combat doesn't halt on UI flow.

A broken armor card is greyed in the inventory and a `Repair Armor` rest-activity
button appears in the rest dialog (out of scope for this design doc, but the
AD row is where the broken state lives -- single source of truth).

---

## 5b. Unassigned wounds tray

Wounds don't halt the game. When the damage dialog generates wounds, they go
into a per-character **unassigned wounds queue** stored on the character (e.g.
`token.properties.unassignedWounds = N`). The character panel grows a
high-contrast tray directly under the Stamina row:

```
+--------------------------------------------------+
|  !! UNASSIGNED WOUNDS x3 !!     [ Assign... ]    |
+--------------------------------------------------+
```

Visual behaviour:

- Hidden entirely while count == 0.
- When count > 0: red bgcolor, pulses brightness on a ~600ms cycle, count
  badge prominent. The whole row is clickable and so is the explicit button.
- Persists across turns. Other players can see it (it's diegetic: "Mira has
  three open wounds she hasn't placed yet").

Click behaviour:

- Click the tray (or `[ Assign... ]`): expands a sub-panel directly under
  the tray containing a mini backpack grid -- the same 5x2 cell layout as
  the BACKPACK section but rendered inline here. Clicking a slot assigns
  one wound to it (decrementing the unassigned counter and adding the wound
  to that slot). The sub-panel stays open until either count == 0 or the
  player clicks elsewhere.
- Right-click a slot in the mini grid: tooltip explains the consequence
  ("This slot will hold a wound. -1 speed. Slot already contains Lantern --
  it stays.").
- The mini grid uses the same wound-marker visuals (red stripe + corner
  gash) as the live backpack so the player learns the visual vocabulary
  consistently.

This resolves the question of WHERE the slot-picker lives -- it lives in the
tray, not in the damage dialog and not as a modal overlay on the live
backpack. The live backpack still shows the assigned wounds, but
ASSIGNMENT only happens through the tray. Single code path, single widget.

---

## 6. Worn / magic slots

Six magic-item slots (Head, Neck, Arms, Waist, Ring, Feet). They get their own
band BELOW the four inventory rows but ABOVE characteristics, default collapsed
to a single line of slot dots (since most early-game PCs have zero magic items),
expandable to full cells.

Collapsed:
```
WORN (magic)  H( ) N( ) A( ) W( ) R( ) F( )    [v]
```

Expanded:
```
WORN (magic)                                    [^]
+----+ +----+ +----+ +----+ +----+ +----+
|    | |Amlt| |    | |    | |Ring| |    |
|Head| |Neck| |Arms| |Wast| |Fngr| |Feet|
+----+ +----+ +----+ +----+ +----+ +----+
```

Why below the inventory rows, not interleaved: thematically these are not part
of the carrying-capacity system (they don't tax slots, you can't draw from
them in combat, they're permanently equipped). Putting them near hands or belt
would imply they share rules. Putting them below characteristics would make
them feel buried; right after inventory keeps them in the "stuff I own" zone.

The double-equipped-in-same-slot wound rule (1d6 wounds at end of DT for each
overstuffed slot) needs an active warning indicator on the section header
when triggered -- a red `!` badge that, hovered, says "Head slot has 2 items;
will roll 1d6 wounds at end of DT".

---

## 7. Draw-from-backpack interaction model

In combat, drawing from backpack costs a maneuver AND requires `1d10 >= slot
number`. Out of combat, free movement of items between slots.

Recommended: **trigger inline on the drag itself, no separate button**.

- Out of combat: drag backpack item to hand or belt -> immediate move, no roll.
- In combat: drag backpack item to hand -> a small confirmation popup appears
  at the drop site:

```
   Draw Lantern from Backpack slot 4?
   This uses a maneuver + roll 1d10 vs 4.
   [ Roll & Draw ]  [ Cancel ]
```

  Clicking Roll & Draw triggers the dice roller (use the same DSRollDialog
  serialization channel as Draw Steel), then on success the item moves and the
  maneuver indicator on the action bar ticks. On failure, the item stays put,
  the maneuver is still spent, and the player gets a chat line "Mira fumbles
  for the Lantern in slot 4 (rolled 3, needed 4+)."

Why drag-triggered rather than a button on the card:

- Drag is already how you'd expect to relocate items, so we get muscle memory
  for free.
- A button on the card would either always be visible (cluttering the cell at
  60x80) or hidden in a hover/context menu (extra clicks for the most common
  combat action).
- A contextual prompt on drag also lets us communicate the slot number cost
  clearly, which the player otherwise has to compute mentally ("which slot was
  that in again?").

Belt-to-hand draw in combat is also a maneuver but no roll; the popup shows
`uses a maneuver. [ Draw ] [ Cancel ]` with no dice tier.

Out of combat, a `[ * ]` overflow icon in each section header lets you toggle
"force combat rules" so the player can rehearse the roll during prep without
having to start an encounter.

---

## Resolved design decisions

1. **Card binder is in the character-sheet `Sheet` tab.** The side panel
   stays purely operational. Cards expand to a popup overlay (tear-off / pin
   later); the full binder lives in the Sheet tab where you can compare and
   filter cards without crowding the side panel.

2. **Wound assignment uses the unassigned-wounds tray.** Damage dialog
   never blocks: any generated wounds drop into `unassignedWounds` and the
   tray (section 5b) flashes until the player assigns them. The
   slot-picker is the mini-backpack-grid embedded in the tray -- a single
   widget, no duplication.

3. **Speed lives in the vitals strip** (top right of the STAMINA row,
   per section 1 mockup). It is a combat-critical glance stat, not a
   teaching aid for the wound mechanic.
