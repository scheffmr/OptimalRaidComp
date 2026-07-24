# Optimal Raid Comp Manager — Codex Guide

## Project context

Optimal Raid Comp Manager (ORC) is a World of Warcraft **3.3.5a / Wrath of the
Lich King** addon targeting client interface version **30300**. It automates the
creation and management of AI playerbot party and raid compositions on the
**Warstorm** server.

This is a single-file addon. Most implementation work belongs in
`OptimalRaidComp.lua`.

## Repository layout

| File | Purpose |
| --- | --- |
| `OptimalRaidComp.toc` | Addon manifest; interface version, saved-variable declaration, and load order. |
| `OptimalRaidComp.lua` | Addon logic, UI, persistent state, bot commands, and keybinding globals. |
| `Bindings.xml` | Keybindings that call the required global `ORC_*` functions. |
| `readme.md` | Player-facing documentation. |

The current release version is `3.1.1`. When intentionally releasing a version
bump, keep the Lua header, `.toc`, and `readme.md` version/notes in sync.

## Compatibility rules

- Use the WoW **3.3.5a API only**. Do not introduce Retail WoW APIs or assume
  `C_Timer` exists; delayed work uses the addon's `OnUpdate` scheduler (`After`).
- Keep the manifest interface field at `30300` unless the addon target changes.
- Preserve the existing compact Lua style: local state, terse functions, and
  semicolon-separated statements where the surrounding code uses them.
- Keep `ORC_*` keybinding functions global: `Bindings.xml` resolves them by name.
  Other new symbols should be local unless a WoW callback requires otherwise.
- Saved-variable updates must preserve existing users' data. Seed new defaults
  in the early `OptimalRaidCompDB` defaults block rather than replacing tables.

## Warstorm bot-command contract

All bot command strings are server-specific. Do not normalize or replace them
with generic `mod-playerbots` commands without explicit confirmation that the
Warstorm server accepts the change.

Key examples that must remain exact where applicable:

- `.warstormbot bot addclass <class>` — summon/invite a class.
- `.warstormbot bot init=epic <name>` — initialize a named bot.
- `.warstormbot bot remove *` — remove bots before a fresh composition.
- `talents spec <spec> pve` — set a bot spec by whisper.
- `nc +<token>`, `nc totems <set>`, `nc +worldbuff`, and `autogear` — strategy,
  totem, buff, and gear commands.

For live commands, `SendBotOrder` deliberately sends to `RAID` when in a raid
and `PARTY` otherwise. Preserve this behavior unless fixing a verified
server-side delivery issue.

## Editing and verification

- Read the relevant nearby code before changing the single Lua file; UI and
  asynchronous summon/reinit behavior share state in several places.
- Keep additions safe during combat and preserve cancellation/state-machine
  handling for summon and reinit flows.
- There is no automated build or test suite. Validate Lua syntax and manifest
  load order locally when possible, then verify behavior in the 3.3.5a client.
- For UI or bot behavior changes, state the precise in-game path to test (for
  example, party vs. raid, existing group replacement, and combat deferral).
- Avoid unrelated reformatting: compact diffs are especially valuable in this
  large single-file addon.

## Important implementation notes

- `OptimalRaidCompDB` contains user profiles and UI/control state; never reset
  it as part of ordinary feature work.
- Spec changes are confirmation-gated: wait for bot `picking <spec>` whispers
  through `AwaitSpecConfirms` before autogear.
- `GetNumRaidMembers`, `GetNumPartyMembers`, `ConvertToRaid`,
  `UIDropDownMenu_*`, and `StaticPopupDialogs` are intentionally appropriate
  for this legacy client, even though some are deprecated in Retail.
- ElvUI skinning is optional and must remain defensive (`pcall` and a no-op when
  ElvUI is absent).
