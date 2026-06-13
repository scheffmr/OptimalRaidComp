# CLAUDE.md — Optimal Raid Comp Manager (ORC)

Guidance for Claude Code when working in this repository.

## What this is

ORC is a **World of Warcraft 3.3.5a (Wrath of the Lich King, Interface 30300)** addon that
automates AI **playerbot** raid management. It builds a composition in a UI, then summons,
spec-assigns, gears, buffs, and sorts a full party/raid of bots without manual command spam.

> **Important — this fork targets the Warstorm server.** Warstorm uses a different bot command
> vocabulary than other 3.3.5a playerbot servers (e.g. `mod-playerbots` defaults). The command
> strings in this addon are Warstorm-specific. Do **not** "correct" them to match generic
> `mod-playerbots` syntax — that would break this fork. See [Bot command reference](#bot-command-reference).

### Upstream / original

This is a fork. The original thread is:
- https://forum.warstorm.org/showthread.php?tid=73

Credits: Authors **Runshouse** and **Marco**, original design by **Xhausted**.

## Files

| File | Purpose |
|------|---------|
| `OptimalRaidComp.toc` | Addon manifest. Declares `Interface: 30300` and `SavedVariables: OptimalRaidCompDB`. |
| `OptimalRaidComp.lua` | Entire addon — UI, data tables, summon state machine, bot commands, sorting. |
| `readme.md` | User-facing documentation. |
| `CLAUDE.md` | This file. |

> **Version note:** `.lua` header, `.toc`, and `readme.md` are all on **v2.8**.

## How to use it in-game

- Open/close UI: `/orc` slash command, or left-click the floating **ORC** launcher button.
- **Move the main window:** left-click-drag the window background.
- **Move the launcher button:** **right**-click-drag (left-click = Quick Create).
- **Resize the main window:** mouse-wheel over it (scale clamped 0.5–2.0, persisted).

## Code map (`OptimalRaidComp.lua`)

- **Saved variables** (`OptimalRaidCompDB`, ~line 9): `comps`, `currentComp`, `buttonPos`, `scale`, `raidSize`.
- **Data tables** (~line 20): `classes`, `specsByClass`, `CLASS_TO_CMD`, `UNIT_TO_SHORT`.
- **`STRAT_MAP`** (~line 33): translates friendly UI labels (`kings`, `devotion`, `fire res`…)
  into Warstorm strategy tokens (`bstats`, `barmor`, `rfire`…).
- **`TOTEM_TOOLTIPS`** (~line 51) + **`GetOptionsForClassSpec`** (~line 61): context-aware,
  spec-dependent buff/aura/totem dropdown options (Paladin, Shaman, Priest). Warriors have no
  options dropdown — the server has no shout strategy tokens.
- **`PushAutogear` / `PushWorldBuffs`** (~line 235): manual party/raid broadcast actions.
- **Spec push helpers** (~line 272, ~314): whisper per-bot talent spec + strategy/totems.
- **`SummonComp` / summon state machine** (~line 367): an `OnUpdate` frame driving phases
  1→4 (first summon → wait for join → ConvertToRaid → mass summon → init → specs → gear →
  buffs → sort). Paces invites against group size to survive server lag.
- **`SafeSummon`** (~line 518) + `ORC_CONFIRM_SUMMON` popup: confirms before wiping an existing group.
- **`SortRaidGroup`**: role-based subgroup packing (melee/tanks → ranged/casters → healers).
- **UI build** (~line 526+): main frame, per-row dropdowns, bottom action row, launcher (~line 798).
- **`ApplyElvUISkin`** (near the end, before the login handler): optional — if `_G.ElvUI`
  exists, skins every widget via `E:GetModule("Skins")` (`HandleButton`/`HandleDropDownBox`/
  `HandleCheckBox`/`HandleCloseButton`/`HandleScrollBar`, plus `SetTemplate("Transparent")` on
  the main frame and launcher). Whole body is `pcall`-wrapped and runs once (`elvSkinned`
  guard) from `PLAYER_LOGIN`. No-ops cleanly when ElvUI is absent. `.toc` lists
  `## OptionalDeps: ElvUI` so ElvUI loads first when present.
- **Slash command** (~line 848): `SLASH_ORC1 = "/orc"`.

## Bot command reference

These are the exact strings ORC sends. **Warstorm-specific — preserve verbatim.**

### Server commands (sent to `SAY`)
| Command | Purpose |
|---------|---------|
| `.warstormbot bot addclass <class>` | Summon/invite a bot of a class (`warrior`, `paladin`, … `dk`). |
| `.warstormbot bot init=epic <name>` | Initialize/gear a named bot to epic. |
| `.warstormbot bot remove *` | Remove all bots (clears roster before a fresh summon). |

### Bot whispers / group broadcasts
| Command | Channel | Purpose |
|---------|---------|---------|
| `talents spec <spec> pve` | WHISPER | Set a bot's talent spec (e.g. `talents spec holy pve`). |
| `nc +<token>` | WHISPER / RAID / PARTY | Enable a strategy/buff token (see `STRAT_MAP`). |
| `nc totems <set>` | WHISPER | Set Shaman totem set (`melee`, `caster`, `healing`, `fire res`…). |
| `nc +worldbuff` | RAID / PARTY | Apply world buffs to the group. |
| `autogear` | RAID / PARTY | Re-gear the whole group. |

### Strategy tokens (`STRAT_MAP`)
`might→bdps`, `wisdom→bmana`, `kings→bstats`, `sanctuary→bhealth`, `devotion→barmor`,
`retribution→baoe`, `concentration→bcast`, `fire res→rfire`, `frost res→rfrost`,
`shadow res→rshadow`, `crusader→bspeed`.

## Conventions when editing

- This is a single-file Lua addon for the 3.3.5a (WotLK) client API. Use only **WoW 3.3.5a
  API** calls — no Retail-era functions. Note the codebase already uses deprecated-in-Retail
  calls that are correct here: `GetNumRaidMembers`, `GetNumPartyMembers`, `ConvertToRaid`,
  `UIDropDownMenu_*`, `StaticPopupDialogs`.
- Match existing style: terse, multiple statements per line separated by `;`, `local` frames.
- Bot command strings are a server contract — do not reword them without confirming against Warstorm.
- There is no build step and no tests; verification is manual in-game.

## TODO

- [x] **Bug pass (first round)** — fixed:
  - Localized `slots` and the `UpdateVisibleRows` / `RefreshCompList` / `RefreshSizeDD`
    functions (were leaking as globals; `slots` is a high-collision name with other addons).
  - STOP button now aborts during the initial 5s "remove bots" wait (previously the
    pre-summon watch frame wasn't tracked, so STOP did nothing and summoning fired anyway).
- [x] **Bug pass — remaining findings (resolved):**
  - **Same-class spec ambiguity:** accepted as-is. `PushSpecs` / `SummonComp.Finalize` use
    per-class queues that pop each desired spec exactly once, so two same-class bots are
    guaranteed to each get one of the specs. Which bot gets which (e.g. Holy vs Ret Paladin)
    can still swap by roster order, but that's intentionally fine — both specs are covered.
  - **Warrior shout options removed:** Warstorm has no shout strategy tokens, so the Warrior
    options dropdown was removed from `GetOptionsForClassSpec` and the default comp's Warrior
    `opt1` reset to `none` (was `commanding`).
  - **Overwriting "Default 5-Man" in a non-5 size:** fixed. Removed the three hardcoded
    "Default 5-Man → size 5" overrides (`RefreshCompList`, `currSize`, login handler); the
    stored `size` field is now authoritative for every profile.
  - Cosmetic: `delBtn` now sets the dropdown text to "Select Profile" to match `RefreshCompList`.
- [x] **Save / overwrite profiles** — `Save` now overwrites the selected profile (with an
      "Overwrite?" confirm) and falls back to a name prompt when nothing is selected; added a
      dedicated **Save As** button for creating new profiles.
- [x] **UI overhaul with ElvUI support** — `ApplyElvUISkin()` detects `_G.ElvUI` at login and
      skins all frames/buttons/dropdowns/checkboxes/scrollbar via the ElvUI Skins module, with
      `SetTemplate("Transparent")` on the main window and launcher. Defensive (`pcall`, runs
      once) and falls back to the Blizzard look when ElvUI is absent. Confirmed working in-game.
- [x] **Version sync** — `.lua`, `.toc`, and `readme.md` are all on v2.8; readme "What's New"
      refreshed with a v2.8 section.
