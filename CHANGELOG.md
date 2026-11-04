# Changelog

## 1.5.3

Tested with game 0.140.0, in game on Shadow Priest, Hunter and Enhancement Shaman.

- Numbers no longer reset when you switch away from the browser and come back during a run. The addon now goes by the game's id for the run, on games that have one.
- The window now sorts by Total by default. If you already clicked a column header, your choice is kept.
- Hunter: Kill Command has its own row with its own Hit, Crit and Burst, so its big hits no longer count as the pet's.
- Shaman: the game now reports all of Windfury Weapon together, so its Total under each spell is shared out by how much it hit there. The two Totals are an estimate and still add up to the game's meter.
- Updated for game 0.140's new names in every language, including Kill Command and the Tier 0.5 sets' damage lines.

## 1.5.2

Tested with game 0.139.0, in game in Russian on Warlock and Shadow Priest.

- Every language the game offers is now supported on game 0.139 and later. Rows show spell, demon and proc names in your game's language, using the game's own translations, and group the same way as in English. The window's own text, like column names, stays in English.
- In co-op, names from a host playing in another language are understood too.
- Older game versions still need the game set to English.

## 1.5.1

Tested with game 0.139.0.

- Compact and Mini now stay on between games. The window used to open at full width every time.
- `/maxhit help` now says no game settings are needed on game 0.139 and later.

## 1.5.0

Tested with game 0.139.0, in game on Shadow Priest, Warlock, Hunter and Enhancement Shaman.

- Exact numbers for procs, thanks to the game's new data. On game 0.139 and later, the game says which damage meter line each hit counts toward, and the addon now uses that for all classes. Shadow Weaving, Shadowy Apparitions, demons, pets and item procs get their own true Hit, Crit, Burst, Avg, Hits and Crit%, and a spell's row only counts its own hits. Hit should no longer end up above Crit because of a proc.
- Grouping stays: procs sit under the ability they borrow, like Shadowy Apparitions under Mind Blast, and a demon under the spell it casts, like the Dread Lord under Searing Pain, each with its own numbers. That spell's row shows `-` until you cast it yourself, so nothing jumps when you learn it. A summon's attacks stay under it, like Infernal: Melee and Hellfire under Infernal. Shadowform stands alone, since Corpse Explosion isn't a spell you pick.
- Shaman: Windfury Weapon has a row under each spell that triggers it, like Stormstrike and Rockbiter Weapon, each with its own numbers, because its hits differ a lot between them. Eye of the Tempest now sits under Chain Lightning, so its damage no longer counts twice.
- Hunter: Bestial Wrath's splashes are on its own row, so a pet's Hit, Crit and Avg only count its bites.
- New `/maxhit feed` command lists which meter line the game credits each ability's hits to.
- Older game versions keep working the way they did.
- New Compact and Mini views, with C and M buttons next to R. Compact, or `/maxhit compact`, leaves only Total, Hit, Crit and Burst, with no OVERKILL tile. Mini, or `/maxhit mini`, leaves only Total, with TOP HIT and TOTAL on top. Both narrow the window, and the Party tab keeps its full width.
- The title bar has - and + buttons next to R that make the whole window smaller or bigger, in steps of 0.1. The window's top-right corner stays in place while you click. `/maxhit scale` still sets an exact size.

## 1.4.0

Tested with game 0.138.0.

- Hunter pets now have real numbers. On game 0.138 and later, a Hunter's pet shows Hit, Crit, Burst, Avg, Hits and Crit% on its row, and can be your TOP HIT and count toward BURST. A pet's special attacks share its one row, and OVERKILL still leaves pets out. A Frost Mage's Water Elemental still shows only its Total, because the game doesn't report its single hits.
- Hunter: Bestial Wrath's splashes go on its own row with their own numbers, so a pet's Hit, Avg and Hits only count its bites.
- Shaman: Frostbrand Weapon now sits under Frost Shock.
- Warlock: the Imp's row is now called Imp, with the Imp's icon, instead of Fireball.

## 1.3.4

- Priest: Shadow Weaving strikes logged under Mind Blast, Psychic Scream, Mind Flay and other Shadow spells now move to the Shadow Weaving row when they are bigger than the spell's biggest crit, including ones that landed earlier in the run. Smaller strikes of a size already seen on that enemy no longer set the spell's Hit either, so Hit gets closer to its real number and should less often beat Crit. Those smaller strikes still count in the spell's Avg and Hits, Shadowy Apparitions still count under Mind Blast, and Burst can stay a little high.
- New `/maxhit scale` command makes the whole window smaller or bigger, from 0.6 to 1.5, for example `/maxhit scale 0.8`. The setting is remembered.
- The BURST, TOTAL and PARTY TOTAL tiles now use short numbers like 388K and 16.49M. TOP HIT keeps the full number and has more room for the ability's name.

## 1.3.3

- Big hits that mostly overkill now go to the proc that caused them, when a damage-over-time spell has exactly one proc under it. For example, Pendant of the Plague's explosions no longer end up in an "Other hits" row under Devouring Plague.
- Procs like Shadow Weaving no longer take a hit far above their usual size when the spell has its own proc, so Pendant of the Plague's explosions stop inflating Shadow Weaving's Hit.

## 1.3.2

- A summon's attacks are grouped: Infernal: Melee and Hellfire sit indented under Infernal, with the summon's total on the top row and each attack keeping its own Hit, Crit and Avg.

## 1.3.1

- Total and Burst columns now use short numbers like 17.2K, 317K and 5.31M. Hit, Crit and Avg stay full numbers, and the TOTAL and BURST tiles at the top still show the exact number.
- The window is narrower, 500 instead of 550 wide, so it covers less of the game.
- Times are now off by default: the At column and the time next to TOP HIT and BURST. Turn them on with `/maxhit at`, which also widens the window a little.
- The Party tab's Total also uses short numbers.
- Priest: Breath of the Black Dragon's burn no longer appears a second time as an "Ignite" row. Its hits now show on the necklace's row under Mind Flay, and the rows add up to TOTAL.
- Choker of the Fire Lord now sits under Blast Wave, the name its blasts have in the combat log, so they no longer show as a separate total.
- The game meter's Other line, for damage it doesn't credit to a spell or item, has an icon instead of a question mark.
- An "Other hits" row only shows when it is at least 1% of the spell's logged damage, so a stray hit or two no longer adds a row. `/maxhit top` still lists them.

## 1.3.0

Every class has been played and checked against the game's meter on game 0.135.1, so the rows now add up to TOTAL in far more cases.

**All classes**

- Damage the game's meter lists with no matching combat log name now gets its own row, so it no longer goes missing.
- An ability whose hits all come from a proc under it now shows `-` as its Total, and the proc row shows the damage. Examples are Eviscerate with Seal Fate before you learn Eviscerate, and Corpse Explosion with Shadowform or Seed of Corruption. Its Hit, Crit, Burst, Avg and Hits still show.
- Pets: the game meter's Pets line has a row with an icon. With one kind of summon out, it is named after it, like Water Elemental. Summons whose hits are in the combat log show one row, not two.
- OVERKILL no longer shrinks or disappears when you have pets.
- New icons show up sooner at the start of a run.

**By class**

- Warrior: Deep Wounds is one row instead of two.
- Rogue: Seal Fate sits under Eviscerate. Toxic Bloom is one row instead of a separate "Noxious Cloud".
- Druid: Blood Frenzy is one row instead of a separate "Rip". Treants are one row.
- Hunter: Immolation Trap, Explosive Trap and Frost Trap are one row each.
- Warlock: Soulfire is one row. Each demon takes its Total from the game's meter and counts once. The Infernal's landing is part of its row. Dread Lord sits under Searing Pain and Doomguard under Shadow Bolt, the spells they cast, and both have icons.
- Priest: Penance is one row instead of a separate "Holy Shock".
- Shaman: Searing Totem's damage shows as Searing Totem with its icon, instead of "Attack".

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
