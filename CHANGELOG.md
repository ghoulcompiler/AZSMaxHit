# Changelog

## 1.2.2

- Warrior: Deep Wounds no longer appears twice. It is now one row with its icon and its total from the game's meter.

## 1.2.1

- Updated for the Enhancement Shaman rework (game 0.134 and 0.135): Stormstrike and Rockbiter Weapon have their icons, Flametongue Weapon sits under Fire Nova, and Eye of the Tempest sits under Stormstrike.
- Procs and necklaces without a known icon now take theirs from the game's meter, so new ones stop showing a question mark.
- After you leave a co-op run with End Run, your next solo run no longer shows the old party in the Party tab.

## 1.2.0

- Each row has a fill bar behind the ability name and total, so your biggest damage dealers stand out at a glance. The bar is colored by damage school: Shadow purple, Fire orange, Frost blue, Holy gold, Nature green, Arcane pink, Physical tan. Bars always measure total damage, whatever you sort by, and stop at the Total column so the other numbers stay clean.
- Total now comes from the game's own meter: each ability's own damage, without its procs or overkill, so the rows add up and match the in-game meter. Hit, Crit, Burst and the rest still come from the combat log. Sorting by Total sorts an ability together with its procs, so Mind Blast with Shadowy Apparitions stays on top.
- Damage-over-time spells (Shadow Word: Pain, Devouring Plague, Serpent Sting, Rend, Rupture, ...) now show only their own ticks in Hit, Crit, Avg and Hits. Other hits the game logs under their name are matched to the right proc by watching the game's meter, so Shadow Weaving strikes and Pendant of the Plague's explosions now get real Hit, Crit, At, Burst and Avg numbers in their own rows. Hits that can't be matched go to an **Other hits** row under the spell.
- New OVERKILL tile in the summary: damage past what enemies had left, the gap between the combat log and the game's meter.
- Procs get a fainter bar. In the Party tab, each hero's bar shows their total damage in their class color.
- Item procs like Pendant of the Plague show the item's own icon instead of the spell's.
- Warlock: Seed of Corruption now sits under Corpse Explosion (the game logs its bursts by that name), and the Imp's Fireball takes its total from the game meter's Imp line. Icons for Fireball, Seed of Corruption, Thorns and a few other procs outside the spellbook.
- New `/maxhit top` command: prints the game's exact message for each ability's biggest hits, split into direct hits and damage over time.

## 1.1.0

- Procs from items and talents now show indented under the spell that triggers them, with their total from the game's own meter. For example Pendant of the Plague under Shadow Word: Pain, Shadowy Apparitions under Mind Blast, and Shadowform under Corpse Explosion.
- Procs that don't belong to one spell, like Shadow Weaving, get a grayed row of their own.
- Talent procs for all nine classes are placed under the spell they cast (Hot Streak under Pyroblast, The Art of War under Exorcism, Omen of Clarity under Starfire, ...).
- Total is now the first column, and the first column is called Ability, since it lists melee, pets and procs too.
- The summary has more room for big totals.

## 1.0.0

First public release. Tested with game 0.132.0.

- One row per spell (melee, pets and procs included) with its biggest hit, biggest crit, run time of the top hit, burst, total, average hit, hit count and crit rate. Click a column header to sort.
- Summary at the top: top hit, best burst and total damage for the run.
- Party tab in co-op: every hero's top spell, DPS, total and share from the game's party meter, with class icons.
- Icons from your spellbook, talents and the game's own meter.
- Starts fresh every run; nothing from past runs is kept.
- Resizable window with scrolling.
