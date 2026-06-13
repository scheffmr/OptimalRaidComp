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
| `OptimalRaidComp.toc` | Addon manifest. Declares `Interface: 30300`, `SavedVariables: OptimalRaidCompDB`, loads `Bindings.xml` then the `.lua`. |
| `OptimalRaidComp.lua` | Entire addon — UI, data tables, summon state machine, bot commands, sorting, bot control + Commands window, trade payout. |
| `Bindings.xml` | Key bindings (toggle/summon/attack/follow/stay/RTSC); calls `ORC_*` globals by name. |
| `readme.md` | User-facing documentation. |
| `CLAUDE.md` | This file. |

> **Version note:** `.lua` header, `.toc`, and `readme.md` are on **v2.8**. The bot-control
> merge (below) is committed but **awaiting an in-game test before the version is bumped** (to
> v2.9). Bump all three together when verified.

> **Supersedes `WarstormBotManager`.** ORC absorbed that addon's runtime bot-control features
> (behavior grid, formations, summon/release/drink/skull/CC, RTSC, trade payout, level-up
> reinit). WarstormBotManager is discontinued; disable it to avoid duplicate keybinds/handlers.

## How to use it in-game

- Open/close UI: `/orc` slash command, or left-click the floating **ORC** launcher button.
- **Main window** builds/summons a comp and holds the formation cycler, **Reinit**, **Loot FFA**,
  the two toggles (auto-reinit, trade-whisper), and a **Commands** button.
- **Commands** button opens a separate movable **ORC Commands** window (the behavior grid +
  Summon/Release/Drink/Skull/CC footer + More). Drag it anywhere; position and open/closed state
  persist (it is intentionally NOT in `UISpecialFrames`, so Escape/loading screens don't close it).
- **Move the main window:** left-click-drag the window background.
- **Move the launcher button:** **right**-click-drag (left-click = Quick Create).
- **Resize the main window:** mouse-wheel over it (scale clamped 0.5–2.0, persisted).
- **Slash extras:** `/orc reinit`, `/orc loot`, `/orc tradewhisper [on|off]`, `/orc tradevalue`.
- **Keybinds:** Esc → Key Bindings → "Optimal Raid Comp" (toggle, summon, attack, follow, stay, RTSC).

## Code map (`OptimalRaidComp.lua`)

(Single file; line numbers drift, so this lists sections in load order.)

- **Saved variables** (`OptimalRaidCompDB`): `comps`, `currentComp`, `buttonPos`, `scale`,
  `raidSize`, plus control state `selectedTab`, `selectedFormation(+Index)`, `controlExpanded`,
  `autoLevelUp`, `tradeWhisper`. A `do` block seeds new keys into existing DBs at load.
- **`BuildCompFromSlots`**: snapshots the visible rows into a comp table (used by buttons,
  the level-up handler, and the control tab). Hoisted early so all of those can reach it.
- **Data tables**: `classes`, `specsByClass`, `CLASS_TO_CMD`, `UNIT_TO_SHORT`, `STRAT_MAP`
  (UI label → Warstorm strategy token), `TOTEM_TOOLTIPS`.
- **Shared infrastructure (bot control):**
  - `SendBotOrder(msg)` — raid-aware order broadcast (RAID in a raid, else PARTY).
  - `After(delay, fn)` — a single OnUpdate scheduler frame (`schedPending`); no `C_Timer` on 3.3.5a.
  - `confirmFrame` + `AwaitSpecConfirms(names, timeout, onDone)` + `WarnSpecMissing` — wait for
    each bot's `picking <spec>` WHISPER before autogear (6s timeout, warns on miss).
- **Control data**: `formations`, `roles` (each has a `@<role> ` prefix; `all` is bare),
  `actions` (`attack/stay/follow/flee`), `footer` (Summon/Release/Drink/Skull/CC).
- **`GetOptionsForClassSpec`**: spec-dependent buff/aura/totem dropdown options (Paladin,
  Shaman, Priest). Warriors have no options dropdown — the server has no shout tokens.
- **`PushAutogear` / `PushWorldBuffs` / `SetGroupLoot`** (`IsGroupLeader` → Free For All + Epic).
- **`WhisperCompSpecs`** (shared whisper loop, returns whispered names) + **`PushSpecs`**.
- **`SummonComp` / summon state machine**: an `OnUpdate` frame driving phases 1→4 (first summon
  → wait for join → ConvertToRaid → mass summon → init). Finalize whispers specs, sets loot,
  then **confirm-gates autogear** via `AwaitSpecConfirms` (replaces the old fixed 10s wait) →
  world buffs → sort. Paces invites against group size to survive server lag.
- **`SafeSummon`** + `ORC_CONFIRM_SUMMON` popup: confirms before wiping an existing group.
- **`ReinitBots(comp)`**: per-bot `init=epic` + re-spec + autogear; defers in combat (sets
  `reinitPending`/`pendingReinitComp`), and the `PLAYER_REGEN_ENABLED` handler retries 3s after
  combat ends. Auto-fires on `PLAYER_LEVEL_UP` (gated by `autoLevelUp`).
- **`SortRaidGroup`**: role-based subgroup packing (melee/tanks → ranged/casters → healers).
- **Trade payout**: hidden-tooltip vendor-value scan (`GetItemInfo` has no sell price on
  3.3.5a) → whisper partner 3× value on `TRADE_PLAYER_ITEM_CHANGED`. Gated by `tradeWhisper`.
- **UI build**: main frame (700×490), per-row dropdowns, bottom action row.
- **Bot control** (`do` block): no tabs — adds a top row to the main window (formation cycler +
  Set/Check, **Reinit**, **Loot FFA**, **Commands**) and the two toggles on the size row.
  **Commands** toggles a separate movable window `ORC_CommandsWindow` (`cmdWin`, position in
  `cmdWinPos`) holding the role×action grid (all+tank default; `More`/`Less` reveals the rest via
  `RefreshControlLayout`, which repositions the footer and resizes the window) and the
  Summon/Release/Drink/Skull/CC footer. **Attack-reset** lives in `GridClick`: tracks `lastOrder`
  per role and prepends `follow` when it was stay/flee, and a double-tap of attack within 1.5s
  forces the reset.
- **Launcher** + **`ApplyElvUISkin`** (optional, `pcall`-wrapped, runs once from `PLAYER_LOGIN`;
  also skins the control-tab buttons/checkboxes; no-ops without ElvUI; `.toc` `OptionalDeps: ElvUI`).
- **Keybinding globals** (`ORC_Toggle`/`ORC_Summon`/…, `BINDING_*` labels) — the only
  intentional globals, required because Bindings.xml calls functions by name.
- **Slash command**: `/orc` (+ `reinit`/`loot`/`tradewhisper`/`tradevalue` subcommands).

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

### Live bot orders (Commands window / main window / keybinds, via `SendBotOrder` → RAID or PARTY)
Bots reply to spec whispers with `picking <spec>` (listened for by `confirmFrame`).

| Command | Purpose |
|---------|---------|
| `formation <shield\|chaos\|circle\|line\|melee\|near\|queue\|arrow>` | Set bot formation. |
| `formation` | Query/check current formation. |
| `attack` / `stay` / `follow` / `flee` | Behavior for all bots. |
| `@<tank\|heal\|dps\|melee\|ranged> <action>` | Same behavior, role-scoped (e.g. `@tank attack`). |
| `summon` / `release` / `food` | Footer actions (teleport to you / release / rest — the "Drink" button sends `food`). |
| `rti skull` then `attack rti target` | Skull button: mark + attack the marked target. |
| `rti cc moon` | CC button: crowd-control the moon target. |
| `rtsc` / `rtsc save 1` / `rtsc go 1` | RTSC waypoint control (keybinds only). |

> **Attack-reset:** `stay`/`flee` lock bots until a `follow`. The grid's `attack` auto-prepends
> `follow` (0.3s gap) when ORC's tracked last order for that role was stay/flee; a double-tap of
> attack within 1.5s forces the same reset for locks ORC didn't set.

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
- [ ] **Merge WarstormBotManager → ORC (bot control)** — committed in stages: scheduler +
      spec-confirm gating + loot + reinit/level-up; trade payout; main-window controls (formation,
      Reinit, Loot FFA, toggles, Commands button) + a movable `ORC_CommandsWindow` (grid + footer
      + More) + attack-reset; keybindings (`Bindings.xml`); docs. **Pending in-game verification,
      then bump `.lua`/`.toc`/`readme.md` to v2.9.** Things to watch in testing:
  - RAID-channel bot orders actually reach bots in 10/25-man (WBM was party-only — fall back to
    PARTY if Warstorm ignores RAID-channel orders).
  - Main window unchanged below the new top row (window grew 465→490; list start moved to -70).
  - Commands window opens/moves/persists position; More/Less expands rows and resizes the window.
  - Spec-confirm gating doesn't hang summon if `picking` replies never arrive (6s timeout gears anyway).
  - Disable the old `WarstormBotManager` addon so its keybinds/handlers don't double-fire.
