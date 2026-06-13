# Optimal Raid Comp Manager (ORC) v2.8

A lightweight, powerful composition manager designed specifically for World of Warcraft 3.3.5a (Wrath of the Lich King) servers utilizing `.warstormbot` and `mod-playerbots` mechanics. ORC eliminates the tedious macro-spamming of bot management by fully automating summoning, spec assignment, AI strategy configuration, gearing, buffing, and raid sorting.

## 🌟 What's New in v2.8

* **Overwrite-on-Save Profiles:** Saving with a profile selected now overwrites it (after an "Overwrite?" confirm), with a dedicated **Save As** button for creating new profiles.
* **ElvUI Skinning:** When ElvUI is installed, ORC automatically skins all of its frames, buttons, dropdowns, checkboxes, and the scrollbar to match the ElvUI look. Falls back cleanly to the default Blizzard look when ElvUI is absent.
* **Profile Size Consistency:** Profiles now always honor their saved raid size — overwriting any profile (including the built-in *Default 5-Man*) while in a different size no longer snaps it back to 5.
* **Warrior Shout Dropdown Removed:** Warriors no longer show a buff/strategy dropdown, since the server has no shout strategy tokens.
* **Window Controls:** Move the main window by left-click-dragging its background; move the launcher with **right**-click-drag; mouse-wheel over the window to resize (0.5–2.0, persisted).

## What's New in v2.4

* **Playerbots Strategy Mapping:** Seamlessly translates user-friendly UI selections (e.g., Kings, Devotion) into the correct `mod-playerbots` AI strategy commands (e.g., `nc +bstats`, `nc +barmor`) behind the scenes.
* **Context-Aware Dropdowns:** The UI has been widened to include two new columns for mutually exclusive buffs and auras. These dropdowns only appear for relevant classes (Paladins, Shamans, Warriors, Priests) and dynamically adjust based on spec (e.g., Blessing of Sanctuary is only available if the Paladin is set to `prot`).
* **Shaman Totem Tooltips:** Added descriptive hover tooltips to the Shaman dropdown menus detailing exactly which four totems are cast for sets like "Melee", "Caster", or "Healing".
* **Unified Automation:** The mass summon sequence now automatically whispers the assigned AI strategies and totem sets to individual bots immediately following their talent spec initialization.

## Core Features

* **Dynamic Roster Pacing:** The summoning engine actively monitors your group size and waits for a bot to successfully join before inviting the next, eliminating dropped invites due to server lag.
* **Instance & Range Checking:** The **Zone** button utilizes a 100-yard visibility check to ensure all your bots are physically in the same instance as you and haven't dropped offline or phased.
* **Advanced Roster Validation:** The **Roster** check is slot-based. It cross-references your exact template to pinpoint precisely which spec is missing (e.g., *Missing Slot: Paladin (holy)*).
* **Safe Summoning:** Accidental clicks no longer wipe your raid. If you are already in a group, clicking **Create** triggers a standard WoW confirmation prompt before proceeding.
* **Custom Profile Naming:** Profiles can be custom-named via a text box prompt when saving, or auto-filled with a random ID if you prefer to just hit Enter.
* **Dynamic Sizing:** Seamlessly swap between 5-man, 10-man, and 25-man configurations. 5-man mode intelligently bypasses raid-conversion delays.
* **Role-Based Auto-Sort:** Automatically organizes the raid frame by packing Melee/Tanks into the first available groups, followed by Ranged/Casters, dynamically flexing Healers to fill the gaps.
* **On-the-Fly Tweaks:** Every row features a dedicated **Spec** button to whisper targeted spec changes and AI strategy updates to specific bots without needing to target them manually.

---

## Bot Control (Control tab)

The window now has two tabs: **Compose** (build & summon a comp, as above) and **Control** for live, in-the-field bot orders. This folds in the functionality of the now-discontinued *Warstorm Bot Manager* addon — disable that one to avoid duplicate keybinds.

* **Behavior grid:** Order bots to **attack / stay / follow / flee**. The **all** and **tank** rows are shown by default; click **More** to reveal **heal / dps / melee / ranged** rows for role-targeted orders (e.g. only the tank attacks). Orders go to your raid in a raid, your party otherwise.
* **Smart attack reset:** `stay` and `flee` lock bots in place until you tell them to `follow` again, so a plain `attack` won't re-engage them. The **attack** button handles this for you — it automatically sends `follow` first when it knows the role is parked, and **double-tapping attack** (within ~1.5s) forces that reset for any situation it didn't track.
* **Formations:** Cycle through the 8 bot formations (Shield, Chaos, Circle, Line, Melee, Near, Queue, Arrow) and **Set** or **Check** the active one.
* **Footer actions:** **Summon** (teleport bots to you), **Release**, **Drink** (rest), **Skull** (marks + attacks the skull target), and **CC** (crowd-controls the moon target).
* **Reinit & Loot:** **Reinit** re-runs `init=epic` + spec + autogear on the current bots; **Loot FFA** sets the group to Free For All with an Epic threshold (also applied automatically on summon).
* **Auto-reinit on level up:** Optional (checkbox) — when you level, your bots re-init and re-gear automatically, firing a few seconds after combat ends so a bot still fighting isn't skipped.
* **Trade payout whisper:** Optional (checkbox) — when you place green-or-better items in a trade with a bot, ORC whispers the partner the payout (3× the items' vendor value) so the sale is instant. Verify with `/orc tradevalue`.
* **Spec-confirm gating:** During summon/reinit, ORC now waits for each bot to confirm its spec (`picking …`) before sending autogear, so gear is never applied for the wrong spec (it proceeds anyway after a short timeout).

### Slash commands & keybindings

* `/orc` — toggle the window. `/orc reinit`, `/orc loot`, `/orc tradewhisper [on|off]`, `/orc tradevalue`.
* **Esc → Key Bindings → "Optimal Raid Comp":** bind Toggle, Summon, Attack, Follow, Stay, and the RTSC waypoint controls.

---

## Installation

1. Download the latest release.
2. Extract the folder into your World of Warcraft directory: `\Interface\AddOns\`
3. Ensure the folder is named exactly `OptimalRaidComp` (remove any `-main` or `-master` suffixes).
4. Log in and ensure the addon is enabled in your character screen.

---

## Usage

Type `/orc` in chat or click the floating **ORC** mini-launcher button to open the main interface.

1.  **Select Size:** Choose 5, 10, or 25-Man from the bottom dropdown.
2.  **Build Your Comp:** Use the dropdowns on each row to select a Class and Spec. If applicable, select their specific Buff and Utility/Aura from the extended dropdowns.
3.  **Set the Player:** Check the **Player** box on the row that represents your character. The addon will skip bot commands for this slot.
4.  **Create Group:** Click **Create** to initiate the automated sequence. The addon handles the invites, waits for raid conversion, pushes specs and AI strategies, auto-gears, applies world buffs, and sorts the raid automatically.

### Manual Overrides (Bottom Action Row)

* **Roster:** Prints a report comparing your current group to the visible UI template, noting exact missing specs and extra bots.
* **Zone:** Scans your party/raid to verify everyone is online and within 100 yards of your character.
* **Specs:** Re-sends spec assignments and selected AI strategies/totem sets to all bots based on the visible UI.
* **Gear:** Re-sends the `autogear` command to the party/raid.
* **Buffs:** Broadcasts the `nc +worldbuff` command to the party/raid.
* **Sort:** Manually triggers the role-based subgroup sorting algorithm.

---

## Credits
* **Author:** Runshouse, Marco
* **Original Design:** Xhausted

## Original / Upstream

This addon is a fork. The original is **not on GitHub**; it lives on the Warstorm forums:

* https://forum.warstorm.org/showthread.php?tid=73