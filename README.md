# AZS Max Hit

[![Latest release](https://img.shields.io/github/v/release/GhoulCompiler/AZSMaxHit)](https://github.com/GhoulCompiler/AZSMaxHit/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/GhoulCompiler/AZSMaxHit/total)](https://github.com/GhoulCompiler/AZSMaxHit/releases)
[![Tested with game 0.132.0](https://img.shields.io/badge/tested%20with%20game-0.132.0-brightgreen)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

An addon for [Azeroth Survivors](https://wow.aethus.pl/) that shows each spell's **biggest hit**, **biggest crit**, **burst** and **total damage** for the current run.

Damage meters tell you which spell did the most damage overall. AZS Max Hit tells you how hard each spell actually hits: the single biggest number it put on an enemy, and the most damage it did in one second.

![AZS Max Hit: your spells this run](images/main.png)

**[Download the latest version](https://github.com/GhoulCompiler/AZSMaxHit/releases/latest)** · [What's new](CHANGELOG.md)

## Features

- **Summary at the top:** your top hit (with the spell, whether it crit, and when), your best burst, and your total damage this run.
- **A row per spell** (melee, pets and procs included) with its biggest normal hit, biggest crit, run time of its top hit, burst, total, average hit, hit count and crit rate. Click a column header to sort by it.
- **Pets and summons** get their own rows, e.g. `Water Elemental: Waterbolt`.
- **Party view in co-op:** a Party tab compares every hero side by side: top spell, its DPS, DPS, total and share, straight from the game's party meter. See [Co-op](#co-op).
- **Icons** from your spellbook, talents and the game's own meter.
- **Fresh every run:** the window clears by itself when a new run starts. Nothing from past runs is kept.
- **Resizable:** drag the grip in the bottom-right corner to set the height; scroll with the mouse wheel.

Pure Lua (`.toc` and `.lua` only): no DLLs or executables. Works in the browser and desktop editions. Tested with game version **0.132.0**.

## Co-op

In co-op, two tabs appear under the summary: one with your name for your own spells, and **Party** to compare everyone.

| Your tab | Party tab |
|---|---|
| ![Your spells in co-op](images/coop.png) | ![Party tab: every hero side by side](images/party.png) |

The Party tab shows each hero with their class icon and color, their top spell and its DPS, their DPS, total damage and share of the party's damage.

## Install

Download the `AZSMaxHit-<version>.zip` file from the [latest release](https://github.com/GhoulCompiler/AZSMaxHit/releases/latest).

**Browser:** in game, open **Options → AddOns → Install AddOns** and pick the zip. Make sure AZS Max Hit is switched on; it loads at your next run.

**Windows / Linux:** open **Options → AddOns → Open AddOns Folder** and unzip there, so the path ends in `AddOns/AZSMaxHit/AZSMaxHit.toc`.

> If you use GitHub's green **Code → Download ZIP** instead of the release, the folder is called `AZSMaxHit-main`. The browser edition doesn't mind; on desktop, rename the folder to `AZSMaxHit`.

## Game settings

The addon reads the damage the game reports, so turn these on in **Options → Combat**:

| Setting | Why |
|---|---|
| **Show Target Damage** | Required: with it off, the game reports no damage and the window stays empty |
| **Periodic Damage** | Damage over time (Shadow Word: Pain, Ignite, ...) |
| **Pet Damage** | Pets and summons (Water Elemental, Imp, ...) |

<img src="images/settings.png" alt="Options → Combat: Show Target Damage, Periodic Damage and Pet Damage turned on" width="420">

## Commands

| Command | What it does |
|---|---|
| `/maxhit` or `/mh` | Show or hide the window |
| `/maxhit reset` | Clear the numbers now (they also clear by themselves at every new run) |
| `/maxhit lock` | Lock the window's position and size |
| `/maxhit icons` | Icons on or off |
| `/maxhit meter` | List what the game's own meter reports, and spells still missing an icon |
| `/maxhit party` | List what the game's party meter reports (co-op) |
| `/maxhit help` | List all commands in game |

## Columns

| Column | Meaning |
|---|---|
| **Hit** | Biggest normal (non-crit) hit |
| **Crit** | Biggest crit. Whichever of Hit and Crit is larger is highlighted |
| **At** | Run time when the spell's top hit landed |
| **Burst** | Most damage the spell did within any one second |
| **Total** | All damage the spell did this run |
| **Avg** | Average hit |
| **Hits** | Number of hits |
| **Crit%** | Share of hits that crit |

## Good to know

- **Empty window, or DoTs and pets missing?** Check the [game settings](#game-settings).
- The addon reads the combat log, which is in **English**. A game set to another language may need its own patterns; open an issue if that's you.
- **Totals** come from the combat log, so they can differ a little from the game's own meter.
- **Max hits are yours only.** The game doesn't send a partner's hits to your combat log, so the Party tab uses the game's party meter: total, DPS, share and top spell for each hero.

## Feedback

Found a bug or a spell with a question-mark icon? [Open an issue](https://github.com/GhoulCompiler/AZSMaxHit/issues) with a screenshot, and for icons the output of `/maxhit meter`.

## Credits

Combat log reading follows the approach of [AZS Spell Meter](https://github.com/kex0/AZSSpellMeter) by kex0. If AZS Spell Meter is installed, AZS Max Hit also uses its icon table.

Azeroth Survivors is a fan game by Aethus. This addon is unofficial and not affiliated with Aethus or Blizzard Entertainment.

## License

[MIT](LICENSE)
