-- AZS Max Hit: the biggest single hit of each spell, for Azeroth Survivors.
-- Reads the WoW 1.12 combat log (English wording), the same way AZS Spell Meter does.
-- Lua 5.0: no '#', no string.match, no '%' operator.

local ADDON = "AZSMaxHit"
local DB_VERSION = 4
local ROWS = 40           -- rows created; how many show depends on the window height
local MIN_HEIGHT = 140
local MAX_HEIGHT = 720
local DEFAULT_HEIGHT = 250
local ROW_H = 14
local TAB_H = 18
local WIDTH = 500         -- 42 more with the At column on (AZSMaxHit_ApplyColumns)
local ME = "@me"          -- key for your own data, whatever your hero is called
local SOLID = "Interface\\Buttons\\WHITE8X8"
local BAR_W = 203          -- fill bars: from the row's left edge to the Total column
local NAME_W = 138         -- the Ability column
local PARTY_BAR_W = 142    -- fill bars in the Party tab: the Hero column
local BURST_WINDOW = 1.0   -- seconds

local db            -- AZSMaxHitDB (settings, icons and window position only)
local run           -- your book for this run: { spells = {}, burst = {} }
-- db.run.players[name] holds a book per hero this run; ME is you.
-- Nothing from a run is kept: it is cleared on load and when a new run starts.
local PARTY = "@party"
local selected = ME -- open tab: ME (your spells) or PARTY (everyone, from the game)
-- Co-op heroes from the game's party meter, read every 2 seconds:
-- { name, dmg, dps, top, topdps, share, class }. Partners' hits are not parsed:
-- the game doesn't send them to your combat log.
local party = {}
-- Proc lines from the game's own meter (proc=1), read every half second:
-- { name, dmg }. The combat log reports these hits under the spell that
-- triggered them, so they are shown indented under that spell.
local meterProcs = {}
-- Each proc's meter total at the last reset. Only damage after that counts, so
-- a reset (or a new run whose meter hasn't cleared yet) doesn't show old procs.
local procBase = {}
local sortKey = "best"
local offset = 0
local dirty = true

-- Rolling 1-second windows (not saved), per hero: one per spell, plus one total.
local windows = {}

local frame, title, rows, tabs

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function say(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMaxHit:|r " .. msg)
end

local function now()
	if GetTime then
		return GetTime()
	end
	return 0
end

local function fmt(n)
	if not n or n <= 0 then
		return "-"
	end
	local s = tostring(math.floor(n + 0.5))
	local k
	repeat
		s, k = string.gsub(s, "^(%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

function AZSMaxHit_FmtShort(n)
	if n >= 999500 then
		return string.format("%.2fM", n / 1000000)
	elseif n >= 100000 then
		return string.format("%.0fK", n / 1000)
	elseif n >= 1000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(math.floor(n + 0.5))
end

-- Total and Burst columns: short numbers, "-" when there are none.
function AZSMaxHit_FmtColumn(n)
	if not n or n <= 0 then
		return "-"
	end
	return AZSMaxHit_FmtShort(n)
end

local function fmtTime(t)
	if not t then
		return "-"
	end
	t = math.floor(t)
	return string.format("%d:%02d", math.floor(t / 60), t - math.floor(t / 60) * 60)
end

local function runTime()
	if not AZS_GetRunTime then
		return nil
	end
	local ok, t = pcall(AZS_GetRunTime)
	t = ok and tonumber(t) or nil
	if t and t > 0 then
		return t
	end
	return nil
end

local function strip(msg)
	msg = string.gsub(msg or "", "|c%x%x%x%x%x%x%x%x", "")
	msg = string.gsub(msg, "|r", "")
	msg = string.gsub(msg, "|H.-|h(.-)|h", "%1")
	return msg
end

local function clean(name)
	if not name then
		return nil
	end
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, " %(Critical%)$", "")
	name = string.gsub(name, "%.$", "")
	name = string.gsub(name, "%s+$", "")
	if name == "" then
		return nil
	end
	return name
end

-- Extra minions that log as friendly NPCs rather than as "pet".
local SUMMONS = {
	["Imp"] = true, ["Felhunter"] = true, ["Voidwalker"] = true, ["Succubus"] = true,
	["Felguard"] = true, ["Infernal"] = true, ["Inferno"] = true, ["Doomguard"] = true,
	["Dread Lord"] = true, ["Pit Lord"] = true, ["Wolf"] = true, ["Raptor"] = true,
	["Spirit Wolf"] = true, ["Treant"] = true, ["Water Elemental"] = true,
}

local function isMine(owner)
	owner = clean(owner)
	if not owner then
		return nil
	end
	owner = string.gsub(owner, "^Your ", "")
	if UnitExists("pet") and owner == UnitName("pet") then
		if db and db.owners then db.owners[owner] = true end
		return owner
	end
	if SUMMONS[owner] then
		return owner
	end
	return nil
end

-------------------------------------------------------------------------------
-- Icons: spellbook, pet spellbook and talents, remembered in saved data.
-- If AZS Spell Meter is installed, its spell-to-icon table fills the gaps.
-------------------------------------------------------------------------------

local ICON_DIR = "Interface\\Icons\\"
local QUESTION = ICON_DIR .. "INV_Misc_QuestionMark"
local FALLBACK_ICONS = {
	["Melee"] = ICON_DIR .. "INV_Sword_04",
	["Damage Shield"] = ICON_DIR .. "Spell_Nature_Thorns",
	["Imp"] = ICON_DIR .. "Spell_Shadow_SummonImp",
	["Felhunter"] = ICON_DIR .. "Spell_Shadow_SummonFelHunter",
	["Voidwalker"] = ICON_DIR .. "Spell_Shadow_SummonVoidWalker",
	["Succubus"] = ICON_DIR .. "Spell_Shadow_SummonSuccubus",
	["Infernal"] = ICON_DIR .. "Spell_Shadow_SummonInfernal",
	["Doomguard"] = ICON_DIR .. "Spell_Shadow_AntiMagicShell",
	["Dread Lord"] = ICON_DIR .. "Spell_Shadow_UnholyStrength",
	["Water Elemental"] = ICON_DIR .. "Spell_Frost_SummonWaterElemental",
	["Wolf"] = ICON_DIR .. "Ability_Hunter_Pet_Wolf",
	["Spirit Wolf"] = ICON_DIR .. "Spell_Nature_SpiritWolf",
	["Raptor"] = ICON_DIR .. "Ability_Hunter_Pet_Raptor",
	["Treant"] = ICON_DIR .. "Ability_Druid_ForceofNature",
	-- Survivors upgrades that are not in the spellbook or talent tree.
	["Corpse Explosion"] = ICON_DIR .. "Spell_Shadow_CorpseExplode",
	["Shadowy Apparitions"] = ICON_DIR .. "Spell_Shadow_Haunting",
	["Shadowform"] = ICON_DIR .. "Spell_Shadow_Shadowform",
	["Shadow Weaving"] = ICON_DIR .. "Spell_Shadow_BlackPlague",
	["Seed of Corruption"] = ICON_DIR .. "Spell_Shadow_CurseOfMannoroth",
	["Thorns"] = ICON_DIR .. "Spell_Nature_Thorns",
	["Fireball"] = ICON_DIR .. "Spell_Fire_FlameBolt",       -- also cast by non-Mages (Imp, upgrades)
	["Frostbolt"] = ICON_DIR .. "Spell_Frost_FrostBolt02",
	["Fire Blast"] = ICON_DIR .. "Spell_Fire_Fireball",
	["Blizzard"] = ICON_DIR .. "Spell_Frost_IceStorm",
	["Pyroclasm"] = ICON_DIR .. "Spell_Fire_Fireball02",
	["Blast Wave"] = ICON_DIR .. "Spell_Holy_Excorcism_02", -- also outside a Mage's spellbook
	["Rampage"] = ICON_DIR .. "Spell_Shadow_UnholyFrenzy",
	["Omen of Clarity"] = ICON_DIR .. "Spell_Nature_CrystalBall",
	["Killing Spree"] = ICON_DIR .. "Ability_Rogue_Sprint",
	["Divine Storm"] = ICON_DIR .. "Spell_Holy_SealOfRighteousness",
	["Piercing Shots"] = ICON_DIR .. "Ability_PierceDamage",
	["Pets"] = ICON_DIR .. "Ability_Hunter_BeastCall", -- the game's meter line for all your pets
	["Other"] = ICON_DIR .. "INV_Misc_Gear_01", -- the game's meter line for uncredited damage
	["Deep Wounds"] = ICON_DIR .. "Ability_BackStab",
	["Blood Frenzy"] = ICON_DIR .. "Ability_GhoulFrenzy",
	["Toxic Bloom"] = ICON_DIR .. "Spell_Nature_NullifyPoison",
	["Seal Fate"] = ICON_DIR .. "Spell_Shadow_ChillTouch",
	["Searing Totem"] = ICON_DIR .. "Spell_Fire_SearingTotem",
	["Stormstrike"] = ICON_DIR .. "Spell_Holy_SealOfMight",
	["Rockbiter Weapon"] = ICON_DIR .. "Spell_Nature_RockBiter",
	["Fire Nova"] = ICON_DIR .. "Spell_Fire_SealOfFire",
	-- Jewelry whose procs the game's meter lists as "Item: Spell".
	["Eye of the Splitting Sky"] = ICON_DIR .. "INV_Jewelry_Necklace_16",
	["Stormcaller's Amulet"] = ICON_DIR .. "INV_Jewelry_Necklace_AhnQiraj_02",
	["Heart of the Earthshaker"] = ICON_DIR .. "INV_Jewelry_Necklace_AhnQiraj_03",
	["Amulet of the Inferno"] = ICON_DIR .. "INV_Jewelry_Necklace_AhnQiraj_04",
	["Talisman of the Tempest"] = ICON_DIR .. "INV_Jewelry_Necklace_30Naxxramas",
	["Medallion of the Bladestorm"] = ICON_DIR .. "INV_Jewelry_Necklace_18",
	["Pendant of the Plague"] = ICON_DIR .. "INV_Jewelry_Necklace_28Naxxramas",
	["The Reaper's Amulet"] = ICON_DIR .. "INV_Jewelry_Necklace_27Naxxramas",
	["Breath of the Black Dragon"] = ICON_DIR .. "INV_Jewelry_Necklace_19",
	["Choker of the Fire Lord"] = ICON_DIR .. "INV_Jewelry_Amulet_05",
	["The Eternal Talisman"] = ICON_DIR .. "INV_Jewelry_Necklace_21",
	["The Legionlord's Medallion"] = ICON_DIR .. "INV_Jewelry_Necklace_13",
	["Amulet of the Ancients"] = ICON_DIR .. "INV_Jewelry_Necklace_23",
}

local function asTexture(tex)
	if not tex or tex == "" then
		return nil
	end
	-- "Temp" is the placeholder icon of spells that never got a real one.
	local lower = string.lower(tex)
	if string.find(lower, "questionmark", 1, true) or lower == "temp" or string.find(lower, "\\temp$") then
		return nil
	end
	if string.find(tex, "\\", 1, true) or string.find(tex, "/", 1, true) then
		return tex
	end
	return ICON_DIR .. tex
end

local function rememberIcon(name, tex)
	if type(tex) ~= "string" then
		return
	end
	tex = asTexture(tex)
	if db and name and name ~= "" and tex then
		db.icons[name] = tex
		db.iconsLC[string.lower(name)] = tex
	end
end

local function scanIcons()
	if not db then
		return
	end
	if GetSpellName and GetSpellTexture then
		local books = { BOOKTYPE_SPELL or "spell", BOOKTYPE_PET or "pet" }
		local b
		for b = 1, 2 do
			local i = 1
			while i < 1000 do
				local ok, name = pcall(GetSpellName, i, books[b])
				if not ok or not name then
					break
				end
				local ok2, tex = pcall(GetSpellTexture, i, books[b])
				if ok2 then
					rememberIcon(name, tex)
				end
				i = i + 1
			end
		end
	end
	-- Talents cover procs such as Ignite, Flurry or Deep Wounds.
	if GetNumTalentTabs and GetNumTalents and GetTalentInfo then
		local ok, tabs = pcall(GetNumTalentTabs)
		if ok and tabs then
			local tab, i
			for tab = 1, tabs do
				local ok2, count = pcall(GetNumTalents, tab)
				if ok2 and count then
					for i = 1, count do
						local ok3, name, tex = pcall(GetTalentInfo, tab, i)
						if ok3 then
							rememberIcon(name, tex)
						end
					end
				end
			end
		end
	end
end

-- "Imp: Firebolt" looks up Firebolt, then Imp.
local function iconFor(name)
	if not name then
		return QUESTION
	end
	-- "Shadow Word: Pain" has a colon too, so only split off a known summon.
	local tries = { name }
	local _, _, owner, spell = string.find(name, "^(.-): (.+)$")
	if owner and (SUMMONS[owner] or (db and db.owners and db.owners[owner])
			or (UnitExists("pet") and UnitName("pet") == owner)) then
		tries = { spell, owner }
	else
		owner = nil
	end
	local i
	for i = 1, table.getn(tries) do
		local n = tries[i]
		if n ~= "Melee" or not owner then
			-- Saved icons outlive the addon, so a bad one must not win. "Pets" is the
			-- meter's combined line: never trust an icon the game gave it.
			local tex = (n ~= "Pets" and db and asTexture(db.icons[n] or db.iconsLC[string.lower(n)]))
				or FALLBACK_ICONS[n]
			if not tex and type(AZSSpellMeterIcon) == "table" then
				tex = asTexture(AZSSpellMeterIcon[n])
			end
			if tex then
				return tex
			end
		end
	end
	return QUESTION
end

-------------------------------------------------------------------------------
-- Combat log parsing. Each parser returns: spell, amount, crit, target
-- Crit patterns come before hit patterns so "crits" is never read as "hits".
-------------------------------------------------------------------------------

local function parseYours(msg)
	local _, _, spell, target, amount
	_, _, spell, target, amount = string.find(msg, "^Your (.+) crits (.+) for ([%d,]+)")
	if spell then return clean(spell), amount, true, clean(target) end
	_, _, spell, target, amount = string.find(msg, "^Your (.+) hits (.+) for ([%d,]+)")
	if spell then return clean(spell), amount, false, clean(target) end
	_, _, spell, target, amount = string.find(msg, "^Your (.+) causes (.+) ([%d,]+) damage")
	if spell then return clean(spell), amount, false, clean(target) end
	_, _, target, amount = string.find(msg, "^You crit (.+) for ([%d,]+)")
	if amount then return "Melee", amount, true, clean(target) end
	_, _, target, amount = string.find(msg, "^You hit (.+) for ([%d,]+)")
	if amount then return "Melee", amount, false, clean(target) end
	_, _, amount, target = string.find(msg, "^You reflect ([%d,]+).+ to (.+)")
	if amount then return "Damage Shield", amount, false, clean(target) end
	return nil
end

-- A spell cast by your summon becomes "Imp: Firebolt". Anyone else's: nil.
local function attribute(owner, spell)
	local mine = isMine(owner)
	if mine then
		return mine .. ": " .. spell
	end
	return nil
end

-- Returns: spell, amount, crit, target
local function parsePeriodic(msg)
	local crit = string.find(msg, "%(Critical%)") and true or false
	local _, _, target, amount, spell = string.find(msg, "^(.+) suffers ([%d,]+) .-damage from your (.+)$")
	if spell then return clean(spell), amount, crit, clean(target) end
	local owner
	_, _, target, amount, owner, spell = string.find(msg, "^(.+) suffers ([%d,]+) .-damage from (.+)'s (.+)$")
	if spell then
		spell = attribute(owner, clean(spell))
		if spell then return spell, amount, crit, clean(target) end
	end
	return nil
end

-- Pet and summon lines: "Imp's Firebolt hits X for N." or "Wolf hits X for N."
-- Returns: spell, amount, crit, target
local function parseOther(msg, melee)
	local _, _, owner, spell, target, amount
	_, _, owner, spell, target, amount = string.find(msg, "^(.+)'s (.+) crits (.+) for ([%d,]+)")
	if owner then
		spell = attribute(owner, clean(spell))
		if spell then return spell, amount, true, clean(target) end
		return nil
	end
	_, _, owner, spell, target, amount = string.find(msg, "^(.+)'s (.+) hits (.+) for ([%d,]+)")
	if owner then
		spell = attribute(owner, clean(spell))
		if spell then return spell, amount, false, clean(target) end
		return nil
	end
	if melee then
		local crit = false
		_, _, owner, target, amount = string.find(msg, "^(.+) crits (.+) for ([%d,]+)")
		if owner then
			crit = true
		else
			_, _, owner, target, amount = string.find(msg, "^(.+) hits (.+) for ([%d,]+)")
		end
		if owner then
			local mine = isMine(owner)
			if mine then return mine .. ": Melee", amount, crit, clean(target) end
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Rolling 1-second burst windows
-------------------------------------------------------------------------------

local function newWindow()
	return { first = 1, last = 0, t = {}, a = {}, sum = 0 }
end

-- Adds a hit and returns the damage dealt in the last BURST_WINDOW seconds.
local function pushWindow(w, t, amount)
	w.last = w.last + 1
	w.t[w.last] = t
	w.a[w.last] = amount
	w.sum = w.sum + amount
	local cutoff = t - BURST_WINDOW
	while w.first <= w.last and w.t[w.first] <= cutoff do
		w.sum = w.sum - w.a[w.first]
		w.t[w.first] = nil
		w.a[w.first] = nil
		w.first = w.first + 1
	end
	return w.sum
end

local function resetWindows()
	windows = {}
end

local function windowsFor(who)
	local w = windows[who]
	if not w then
		w = { spells = {}, total = newWindow() }
		windows[who] = w
	end
	return w
end

-------------------------------------------------------------------------------
-- Recording
-------------------------------------------------------------------------------

local function newBook()
	return { spells = {}, burst = {} }
end

-- This run's book for a hero (ME = you), created on first use.
local function runBook(who)
	local book = db.run.players[who]
	if not book then
		book = newBook()
		db.run.players[who] = book
	end
	return book
end

-- For /maxhit top: per kind of combat-log event, how many hits a spell had, the
-- biggest one, and the game's exact message for it. Tells direct hits apart from
-- damage over time (an item explosion logged under a DoT's name, for example).
function AZSMaxHit_NoteSource(r, amount, evt, line)
	local kind = evt or event or "?"
	line = line or arg1
	r.src = r.src or {}
	local s = r.src[kind]
	if not s then
		s = { n = 0, max = 0 }
		r.src[kind] = s
	end
	s.n = s.n + 1
	-- Damage school: "... for 408 Shadow damage." / "suffers 408 Shadow damage
	-- from ...". Melee and pet swings name none: Physical.
	if type(line) == "string" then
		local _, _, school = string.find(line, "%d (%a+) damage")
		r.school = school or r.school or "Physical"
	end
	if amount > s.max then
		s.max = amount
		s.line = line
	end
end

function AZSMaxHit_DumpTop(book, say)
	local list = {}
	local spell, r
	for spell, r in pairs(book.spells) do
		table.insert(list, { name = spell, r = r })
	end
	table.sort(list, function(a, b) return (a.r.max or 0) > (b.r.max or 0) end)
	if table.getn(list) == 0 then
		say("no hits yet this run.")
		return
	end
	say("biggest hit of each ability, by kind of combat-log message:")
	local i
	for i = 1, math.min(10, table.getn(list)) do
		local item = list[i]
		local kind, s
		local shown = item.r.label or item.name
		if item.r.extraOf and string.sub(item.name, 1, 6) == "@proc:" then
			shown = shown .. " (matched from " .. item.r.extraOf .. ")"
		end
		for kind, s in pairs(item.r.src or {}) do
			local short = string.gsub(kind, "^CHAT_MSG_", "")
			say(shown .. " |cff999999[" .. short .. "]|r " .. s.n .. " hits, biggest " .. s.max
				.. ": |cffcccccc" .. tostring(s.line) .. "|r")
		end
	end
end

-- Returns true when this hit is a new top hit for the spell in that book.
local function record(book, spell, amount, crit, target, at, evt, line)
	local r = book.spells[spell]
	if not r then
		r = { max = 0 }
		book.spells[spell] = r
	end
	if crit then
		if amount > (r.maxCrit or 0) then
			r.maxCrit = amount
			r.critAt = at
			r.critTarget = target
		end
		r.crits = (r.crits or 0) + 1
	else
		if amount > (r.maxHit or 0) then r.maxHit = amount end
	end
	r.hits = (r.hits or 0) + 1
	r.total = (r.total or 0) + amount
	AZSMaxHit_NoteSource(r, amount, evt, line)
	if amount > (r.max or 0) then
		r.max = amount
		r.crit = crit
		r.target = target
		r.at = at
		return true
	end
	return false
end

local function recordBurst(book, spell, sum, at)
	local r = book.spells[spell]
	if r and sum > (r.burst or 0) then
		r.burst = sum
		r.burstAt = at
	end
end

local function recordTotalBurst(book, sum, at)
	if sum > (book.burst.amount or 0) then
		book.burst.amount = sum
		book.burst.at = at
	end
end

-- Spells that only deal damage over time. A direct "Your X hits ..." under one
-- of these names is something else the game logs under it: Shadow Weaving
-- strikes, an item's explosion (Pendant of the Plague). Those hits get a row of
-- their own, indented under the spell, so the spell's Hit and Avg are its ticks.
local DOT_ONLY = {
	["Shadow Word: Pain"] = true, ["Devouring Plague"] = true,
	-- Not Corruption or Curse of Agony: seen in game, they also hit when cast.
	["Serpent Sting"] = true, ["Rend"] = true, ["Deep Wounds"] = true,
	["Rupture"] = true, ["Blood Frenzy"] = true,
	["Insect Swarm"] = true, ["Ignite"] = true,
}

function AZSMaxHit_IsDotOnly(spell)
	return DOT_ONLY[spell]
end

-- Breath of the Black Dragon's burn is logged as "Ignite" in the spell's own school,
-- while a Mage's real Ignite is Fire. Returns the neck's meter line for such a tick.
function AZSMaxHit_NeckBurn(spell, msg)
	if spell ~= "Ignite" or string.find(msg, " Fire damage", 1, true) then
		return nil
	end
	local i
	for i = 1, table.getn(meterProcs) do
		if string.find(meterProcs[i].name, "^Breath of the Black Dragon: ") then
			return meterProcs[i].name
		end
	end
	-- Ticks can come before the first read of the meter.
	return "Breath of the Black Dragon: Mind Flay"
end

-- Abilities the combat log spells differently from the game's meter and talents.
local LOG_NAME = {
	["Deep Wound"] = "Deep Wounds",
	["Rip"] = "Blood Frenzy", -- no Rip ability in this game: it is the talent's bleed
	["Noxious Cloud"] = "Toxic Bloom", -- the talent's "toxic cloud"
	-- The damage of these abilities comes from a separate "... Effect" spell.
	["Immolation Trap Effect"] = "Immolation Trap",
	["Explosive Trap Effect"] = "Explosive Trap",
	["Hellfire Effect"] = "Hellfire",
	["Frost Trap Aura"] = "Frost Trap",
	["Soul Fire"] = "Soulfire", -- the meter and the game's own text write it as one word
	["Inferno"] = "Infernal", -- the Infernal's landing, on the meter's Infernal line
}

function AZSMaxHit_LogName(spell, msg)
	-- Searing Totem's bolts are logged as "Your Attack ... Fire damage".
	if spell == "Attack" and msg and string.find(msg, " Fire damage", 1, true) then
		return "Searing Totem"
	end
	-- A Priest's Penance bolts are logged as Holy Shock, a Paladin's own spell.
	if spell == "Holy Shock" and UnitClass("player") == "Priest" then
		return "Penance"
	end
	-- A Warlock's Imp is logged as "Your Fireball", a Mage's own spell. The meter says Imp.
	if spell == "Fireball" and UnitClass("player") == "Warlock" then
		return "Imp"
	end
	return LOG_NAME[spell] or spell
end

-- Direct hits under a DoT's name wait here until the next read of the game's
-- meter tells which proc they were (AZSMaxHit_PlaceDirect).
AZSMaxHit_pending = {}

-- Shadow Weaving strikes for 0.5% of the target's maximum health and is logged under the
-- spell that triggered it, so its size repeats per enemy across spells. Sizes are learned
-- from strikes matched on tick-only spells, then Mind Blast and other direct hits of the
-- same size on the same enemy can be told apart from the spell's own hits.
AZSMaxHit_weavingSizes = {}

function AZSMaxHit_NoteWeaving(target, amount)
	if not target then
		return
	end
	local sizes = AZSMaxHit_weavingSizes[target]
	if not sizes then
		sizes = {}
		AZSMaxHit_weavingSizes[target] = sizes
	end
	sizes[amount] = true
end

-- On a spell that also hits directly, only sizes above its biggest crit count: on weak
-- enemies a strike and a real hit can be the same small number, and smaller strikes
-- don't make Hit wrong.
function AZSMaxHit_IsWeavingStrike(book, spell, target, amount, msg)
	local sizes = target and AZSMaxHit_weavingSizes[target]
	if not (sizes and sizes[amount] and book.spells["@proc:Shadow Weaving"]
			and string.find(msg, " Shadow damage", 1, true)) then
		return false
	end
	if AZSMaxHit_IsDotOnly(spell) then
		return true
	end
	local r = book.spells[spell]
	return r and AZSMaxHit_AboveCrit(r, amount) or false
end

-- A strike can land before its size is known, so a spell's biggest normal hits are kept
-- with their enemy. Once the size is known they move to Weaving, and Hit falls back to
-- the next biggest. Burst can't be undone this way and may stay a little high.
function AZSMaxHit_NoteTop(r, amount, target, at, evt, line)
	if not r.topHits then
		r.topHits = {}
	end
	local top = r.topHits
	local n = table.getn(top)
	local i
	for i = 1, n do
		if top[i].amount == amount and top[i].target == target then
			top[i].n = top[i].n + 1
			return
		end
	end
	if n >= 20 then
		local last = top[n]
		if amount <= last.amount then
			r.topFloor = math.max(r.topFloor or 0, amount)
			return
		end
		r.topFloor = math.max(r.topFloor or 0, last.amount)
		table.remove(top)
	end
	table.insert(top, { amount = amount, target = target, at = at, evt = evt, line = line, n = 1 })
	table.sort(top, function(a, b) return a.amount > b.amount end)
end

function AZSMaxHit_RedoTop(r)
	local first
	local i
	for i = 1, table.getn(r.topHits) do
		if not r.topHits[i].strike then
			first = r.topHits[i]
			break
		end
	end
	local hit = first and first.amount or r.topFloor or 0
	r.maxHit = hit > 0 and hit or nil
	if (r.maxCrit or 0) > 0 and r.maxCrit >= hit then
		r.max, r.crit, r.target, r.at = r.maxCrit, true, r.critTarget, r.critAt
	elseif first then
		r.max, r.crit, r.target, r.at = hit, false, first.target, first.at
	elseif hit > 0 then
		r.max, r.crit = hit, false -- only known as a size: its enemy and time are gone
	else
		r.max, r.crit, r.target, r.at = 0, nil, nil, nil
	end
end

function AZSMaxHit_MoveToWeaving(book, r, target, amount)
	local top = r.topHits
	if not top then
		return
	end
	local i
	for i = 1, table.getn(top) do
		local e = top[i]
		if e.amount == amount and e.target == target then
			if AZSMaxHit_AboveCrit(r, amount) then
				table.remove(top, i)
				r.hits = r.hits - e.n
				r.total = r.total - amount * e.n
				local k
				for k = 1, e.n do
					record(book, "@proc:Shadow Weaving", amount, false, target, e.at, e.evt, e.line)
				end
			else
				-- Too small to move safely, since a real hit can be the same size. It stays
				-- in Avg and Hits, where one wrong match costs little, but can't be Hit.
				e.strike = true
			end
			AZSMaxHit_RedoTop(r)
			return
		end
	end
end

-- The Weaving row must exist in `book`.
function AZSMaxHit_LearnWeaving(book, target, amount)
	local sizes = target and AZSMaxHit_weavingSizes[target]
	if sizes and sizes[amount] then
		return
	end
	AZSMaxHit_NoteWeaving(target, amount)
	local spell, r
	for spell, r in pairs(book.spells) do
		if string.sub(spell, 1, 6) ~= "@proc:" then
			AZSMaxHit_MoveToWeaving(book, r, target, amount)
		end
	end
end

function AZSMaxHit_AboveCrit(r, amount)
	return (r.maxCrit or 0) > 0 and amount > r.maxCrit
end

function AZSMaxHit_WeavingRow(book, spell)
	if not book.spells["@proc:Shadow Weaving"] then
		book.spells["@proc:Shadow Weaving"] = { max = 0, extraOf = spell, label = "Shadow Weaving" }
	end
end

-- Moves the spell's biggest normal hits that are strikes: a size known for that enemy, or
-- one that no real hit could reach. A normal hit is about half a crit, so with a few crits
-- seen, a hit 1.5x the biggest crit is about 3x the spell's real size. A boss that only one
-- spell hits gets found this way (Mind Flay on Sir Zeliek: Hit 2,431, Crit 1,000).
function AZSMaxHit_SweepTop(book, spell, r)
	local top = r.topHits
	while top and top[1] do
		local e = top[1]
		local sizes = AZSMaxHit_weavingSizes[e.target]
		local known = sizes and sizes[e.amount]
		local tooBig = (r.crits or 0) >= 5 and e.amount > (r.maxCrit or 0) * 1.5
		if not (AZSMaxHit_AboveCrit(r, e.amount) and (known or tooBig)) then
			return
		end
		AZSMaxHit_WeavingRow(book, spell)
		if known then
			AZSMaxHit_MoveToWeaving(book, r, e.target, e.amount)
		else
			AZSMaxHit_LearnWeaving(book, e.target, e.amount)
		end
	end
end

-- Called for a direct hit. Two spells landing the same size on the same enemy is also
-- a strike, but small real hits can match by chance, so only sizes above both spells'
-- biggest crits count: those are the ones that make Hit wrong.
function AZSMaxHit_AfterDirectHit(book, spell, amount, crit, target, at, evt, msg)
	if not target or string.sub(spell, 1, 6) == "@proc:" or UnitClass("player") ~= "Priest"
			or not string.find(msg, " Shadow damage", 1, true) then
		return
	end
	local r = book.spells[spell]
	if not crit then
		AZSMaxHit_NoteTop(r, amount, target, at, evt, msg)
		local sizes = AZSMaxHit_weavingSizes[target]
		if sizes and sizes[amount] then
			AZSMaxHit_MoveToWeaving(book, r, target, amount)
		end
	end
	if (AZSMaxHit_ProcTotal("Shadow Weaving") or 0) <= 0 then
		return
	end
	if not crit and AZSMaxHit_AboveCrit(r, amount) then
		local other, o
		for other, o in pairs(book.spells) do
			if other ~= spell and string.sub(other, 1, 6) ~= "@proc:" and AZSMaxHit_AboveCrit(o, amount) then
				local i
				for i = 1, table.getn(o.topHits or {}) do
					if o.topHits[i].amount == amount and o.topHits[i].target == target then
						AZSMaxHit_WeavingRow(book, spell)
						AZSMaxHit_LearnWeaving(book, target, amount)
						return
					end
				end
			end
		end
	end
	-- A crit can also show that a hit kept earlier was too big, so this runs for both.
	AZSMaxHit_SweepTop(book, spell, r)
end

function AZSMaxHit_HoldDirect(book, spell, amount, crit, target, at, t)
	if not book.spells[spell] then
		book.spells[spell] = { max = 0 } -- the spell's row, even before its first tick
	end
	if not AZS_GetMeter then
		-- No game meter to match against: straight to the spell's Other hits row.
		local key = spell .. " (other)"
		if not book.spells[key] then
			book.spells[key] = { max = 0, extraOf = spell, label = spell .. " (other hits)" }
		end
		record(book, key, amount, crit, target, at)
		return
	end
	table.insert(AZSMaxHit_pending, { spell = spell, amount = amount, crit = crit, target = target,
		at = at, t = t, age = 0, evt = event, line = arg1 })
end

local function ingest(msg, kind, evt)
	if not msg then
		return
	end
	msg = strip(msg)
	local spell, amount, crit, target
	if kind == "yours" then
		spell, amount, crit, target = parseYours(msg)
	elseif kind == "periodic" then
		spell, amount, crit, target = parsePeriodic(msg)
	elseif kind == "pet" then
		spell, amount, crit, target = parseOther(msg, false)
	elseif kind == "petmelee" then
		spell, amount, crit, target = parseOther(msg, true)
	end
	if amount then
		amount = tonumber((string.gsub(amount, ",", "")))
	end
	if not spell or not amount or amount <= 0 then
		return
	end
	spell = AZSMaxHit_LogName(spell, msg)

	local at = runTime()
	local t = now()
	local book = run
	local neck = AZSMaxHit_NeckBurn(spell, msg)
	if neck then
		-- Its numbers go on the neck's row, as with matched direct hits.
		local _, _, item, parent = string.find(neck, "^(.-): (.+)$")
		spell = "@proc:" .. neck
		if not book.spells[spell] then
			book.spells[spell] = { max = 0, extraOf = parent, label = item }
		end
	end
	if kind == "yours" and not crit and AZSMaxHit_IsWeavingStrike(book, spell, target, amount, msg) then
		spell = "@proc:Shadow Weaving"
	end
	if kind == "yours" and AZSMaxHit_IsDotOnly(spell) then
		AZSMaxHit_HoldDirect(book, spell, amount, crit, target, at, t)
		recordTotalBurst(book, pushWindow(windowsFor(ME).total, t, amount), at)
		dirty = true
		return
	end
	record(book, spell, amount, crit, target, at)
	if kind == "yours" then
		AZSMaxHit_AfterDirectHit(book, spell, amount, crit, target, at, evt, msg)
	end

	local hw = windowsFor(ME)
	local sw = hw.spells[spell]
	if not sw then
		sw = newWindow()
		hw.spells[spell] = sw
	end
	recordBurst(book, spell, pushWindow(sw, t, amount), at)
	recordTotalBurst(book, pushWindow(hw.total, t, amount), at)
	dirty = true
end

local function resetRun(quiet)
	procBase = {}
	local i
	for i = 1, table.getn(meterProcs) do
		procBase[meterProcs[i].name] = meterProcs[i].raw
	end
	meterProcs = {}
	local name, raw
	for name, raw in pairs(AZSMaxHit_meterRaw or {}) do
		procBase[name] = raw
	end
	AZSMaxHit_meterOwn = {}
	AZSMaxHit_meterSum = 0
	AZSMaxHit_ResetDirect()
	AZSMaxHit_onePet = nil
	db.run = { players = {} }
	run = runBook(ME)
	resetWindows()
	offset = 0
	dirty = true
	if not quiet then
		say("this run's numbers were reset.")
	end
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

-- Each column: sort key, header, right edge, width, value, text, ascending sort
local function avgOf(r)
	if (r.hits or 0) > 0 then return (r.logTotal or r.total or 0) / r.hits end -- combat-log hits
	return 0
end
local function critPctOf(r)
	if (r.hits or 0) > 0 then return (r.crits or 0) * 100 / r.hits end
	return 0
end

local COLS = {
	{ key = "total", label = "Total", right = 207, width = 46, value = function(r) return r.total or 0 end,
		text = function(r) return AZSMaxHit_FmtColumn(r.total) end },
	{ key = "hit",   label = "Hit",   right = 263, width = 54, value = function(r) return r.maxHit or 0 end, bright = true },
	{ key = "crit",  label = "Crit",  right = 319, width = 54, value = function(r) return r.maxCrit or 0 end, bright = true },
	{ key = "at",    label = "At",    right = 361, width = 40, value = function(r) return r.at or 999999 end, asc = true,
		text = function(r) return fmtTime(r.at) end },
	{ key = "burst", label = "Burst", right = 375, width = 50, value = function(r) return r.burst or 0 end,
		text = function(r) return AZSMaxHit_FmtColumn(r.burst) end },
	{ key = "avg",   label = "Avg",   right = 421, width = 44, value = avgOf },
	{ key = "hits",  label = "Hits",  right = 459, width = 36, value = function(r) return r.hits or 0 end },
	{ key = "critp", label = "Crit%", right = 493, width = 30, value = critPctOf,
		text = function(r)
			if (r.hits or 0) == 0 then return "-" end
			return string.format("%d%%", math.floor(critPctOf(r) + 0.5))
		end },
}
local BEST = { key = "best", value = function(r) return r.max or 0 end }
-- Where Hit and Crit sit, for highlighting the bigger one.
local HIT_I, CRIT_I
do
	local i
	for i = 1, table.getn(COLS) do
		if COLS[i].key == "hit" then HIT_I = i end
		if COLS[i].key == "crit" then CRIT_I = i end
		if COLS[i].key == "at" then AZSMaxHit_AtIndex = i end
	end
end

local function columnByKey(key)
	local i
	for i = 1, table.getn(COLS) do
		if COLS[i].key == key then return COLS[i] end
	end
	return BEST
end

-- Your spells this run.
local function currentBook()
	return run
end

-- Co-op: is anyone in the party meter besides you?
local function inParty()
	local me = UnitName("player")
	local i
	for i = 1, table.getn(party) do
		if party[i].name ~= me then
			return true
		end
	end
	return false
end

-- Procs whose hits the combat log prints under another spell's name.
-- Items need no entry: "Pendant of the Plague: Shadow Word: Pain" names its spell.
local PROC_PARENT = {
	-- Built from the talent tooltips (game 0.130-0.132): talents that cast one
	-- named spell. The game's meter names the damage after the talent, while the
	-- combat log prints the spell. Talents that copy several spells (Windfury,
	-- "any spell strikes twice") get a row of their own instead.
	-- If the combat log uses the talent's own name, that row is used as is.

	-- Priest
	["Shadowy Apparitions"] = "Mind Blast",      -- "a free Mind Blast"
	["Shadowform"] = "Corpse Explosion",         -- the burst; seen in game as Corpse Explosion
	["Radiance"] = "Holy Nova",                  -- "A Holy Nova bursts from you on its own"
	["Chastise"] = "Holy Nova",                  -- "sets off a free Holy Nova"
	-- Mage
	["Arcane Concentration"] = "Arcane Explosion", -- "a free Arcane Explosion"
	["Presence of Mind"] = "Arcane Missiles",
	["Hot Streak"] = "Pyroblast",                -- "casts a free Pyroblast"
	["Pyroclasm"] = "Blast Wave",                -- its explosion is logged as Blast Wave
	["Choker of the Fire Lord"] = "Blast Wave",  -- the necklace's blasts, in the spell's own school
	["Splitting Ice"] = "Frostbolt",
	-- Warlock
	["Nightfall"] = "Shadow Bolt",               -- "fire a free Shadow Bolt"
	["Shadow Cleave"] = "Shadow Bolt",
	["Legion Gate"] = "Death Coil",              -- "kills trigger a Death Coil"
	["Rain of Chaos"] = "Rain of Fire",          -- "A second Rain of Fire falls"
	["Corpse Explosion"] = "Seed of Corruption",
	["Seed of Corruption"] = "Corpse Explosion", -- seen in game: Seed's bursts are logged as Corpse Explosion
	["Dread Lord"] = "Searing Pain",             -- "Felseeker inherits your Searing Pain upgrades"
	["Doomguard"] = "Shadow Bolt",               -- "Its Shadow Bolts hit 2 enemies"
	-- Hunter
	["Frenzy"] = "Multi-Shot",                   -- "a free Multi-Shot"
	["Rapid Fire"] = "Aimed Shot",               -- "a free Aimed Shot"
	["Kill Shot"] = "Aimed Shot",
	["Piercing Shots"] = "Auto Shot",
	["Counterattack"] = "Explosive Trap",        -- "a free Explosive Trap"
	["Wyvern Sting"] = "Explosive Trap",
	-- Paladin
	["Divine Favor"] = "Holy Shock",
	["Daybreak"] = "Holy Wrath",                 -- "a free Holy Wrath"
	["Light's Grace"] = "Holy Wrath",
	["Hallowed Ground"] = "Consecration",        -- "a free Consecration"
	["Divine Intervention"] = "Consecration",
	["Seal of Command"] = "Judgement",
	["The Art of War"] = "Exorcism",             -- "a free Exorcism"
	["Divine Storm"] = "Exorcism",
	["Righteous Hammer"] = "Hammer of Wrath",
	-- Warrior
	["Rampage"] = "Whirlwind",                   -- "a free Whirlwind"
	["Bladestorm"] = "Whirlwind",
	["Mortal Wounds"] = "Mortal Strike",
	["Last Stand"] = "Shield Slam",              -- "a free Shield Slam"
	["Shockwave"] = "Shield Slam",
	-- Shaman
	["Elemental Mastery"] = "Chain Lightning",   -- "a second Chain Lightning"
	["Maelstrom Weapon"] = "Chain Lightning",    -- "a free Chain Lightning"
	["Flametongue Weapon"] = "Fire Nova",        -- "casts a free Fire Nova"
	-- The neck's Stormstrike can cast a free Chain Lightning, logged under that name. Under
	-- Stormstrike, as the meter's name suggests, the row counted twice (owner's report, 0.138).
	["Eye of the Tempest"] = "Chain Lightning",
	["Eye of the Tempest: Stormstrike"] = "Chain Lightning",
	["Frostbrand Weapon"] = "Frost Shock",       -- a proc line of its own on the meter since 0.134's note (seen on 0.138)
	-- No Resonant Shocks: the game's meter lists the Shocks it casts under those Shocks (0.134).
	-- Druid
	["Omen of Clarity"] = "Starfire",            -- "a free Starfire"
	["Starfall"] = "Starfire",
	["Enrage"] = "Swipe",                        -- "a free Swipe"
	["Dire Bear Form"] = "Swipe",
	["Nature's Grasp"] = "Entangling Roots",
	-- Rogue
	["Riposte"] = "Ghostly Strike",              -- "a free Ghostly Strike"
	["Killing Spree"] = "Sinister Strike",       -- "a free Sinister Strike"
	["Preparation"] = "Gouge",                   -- "A free Gouge"
	["Seal Fate"] = "Eviscerate",                -- "At 5 points a free Eviscerate"; a non-proc meter line
}

-- Where a meter proc line goes: "skip" (the log already has a row by that
-- name), "child" plus the parent spell, or "alone" (a row of its own).
-- Also returns the label to show: an item proc shows just the item's name.
local function procPlace(p, book)
	if book.splitRows and book.splitRows[p.name] then
		return "split"
	end
	-- Also a summon's proc line with "Owner: Spell" rows (Treant: Melee).
	if book.spells[p.name] or not AZSMaxHit_MeterOnly(p.name) then
		return "skip"
	end
	local parent, label = PROC_PARENT[p.name], p.name
	local _, _, item, spell = string.find(p.name, "^(.-): (.+)$")
	if item then
		parent, label = parent or spell, item
	end
	-- The feed's own word beats the hand-built list, when the proc only borrows one spell.
	local stats = book.spells["@proc:" .. p.name]
	if stats and stats.abilityCount == 1 then
		parent = next(stats.abilities)
	end
	if parent and book.spells[parent] then
		return "child", parent, label
	end
	return "alone", nil, p.name
end

-- Places held direct hits (see AZSMaxHit_HoldDirect) with the proc whose total
-- in the game's meter went up since the last read: Pendant of the Plague under
-- Devouring Plague, Shadow Weaving, ... Biggest hits go first, to the proc with
-- the most new damage. A hit no proc accounts for after two reads goes to the
-- spell's "Other hits" row. Called twice a second from the meter read.
local procLast, procCredit = {}, {}

-- The one proc with damage placed under `spell`, and its label; nil if none or several.
function AZSMaxHit_OnlyChild(procs, spell, book)
	local name, label
	local i
	for i = 1, table.getn(procs) do
		local p = procs[i]
		if p.dmg > 0 then
			local where, parent, l = procPlace(p, book)
			if where == "child" and parent == spell then
				if name then
					return nil
				end
				name, label = p.name, l
			end
		end
	end
	return name, label
end

-- A proc of its own (Shadow Weaving) with its usual hit size known doesn't take a hit
-- 10x that when the spell has its own proc: Pendant of the Plague's 141,900 explosion
-- could land on Weaving, whose hits average a few hundred, just because Weaving's
-- total rose the most at that moment.
function AZSMaxHit_TooBigFor(procName, where, h, procs, book)
	if where ~= "alone" or not AZSMaxHit_OnlyChild(procs, h.spell, book) then
		return false
	end
	local stats = book.spells["@proc:" .. procName]
	if not stats or (stats.hits or 0) < 10 then
		return false
	end
	return h.amount > 10 * (stats.total or 0) / stats.hits
end

function AZSMaxHit_PlaceDirect(procs)
	local book = run
	local i
	-- New damage per proc since the last read; unused credit lasts one more read.
	local credit = {}
	for i = 1, table.getn(procs) do
		local p = procs[i]
		local delta = p.dmg - (procLast[p.name] or 0)
		procLast[p.name] = p.dmg
		if delta > 0 then
			credit[p.name] = delta + (procCredit[p.name] or 0)
		end
	end
	procCredit = credit
	local pending = AZSMaxHit_pending
	if table.getn(pending) == 0 then
		return
	end
	table.sort(pending, function(a, b) return a.amount > b.amount end)
	local keep = {}
	for i = 1, table.getn(pending) do
		local h = pending[i]
		-- A proc fits when its new damage covers the hit. The meter counts only
		-- damage that landed, so a hit may be up to 4x its new damage (overkill).
		local best, bestCredit, bestLabel, bestFits = nil, 0, nil, false
		local j
		for j = 1, table.getn(procs) do
			local p = procs[j]
			local where, parent, label = procPlace(p, book)
			local c = credit[p.name] or 0
			if c > 0 and ((where == "child" and parent == h.spell) or where == "alone")
					and h.amount <= c * 4
					and not AZSMaxHit_TooBigFor(p.name, where, h, procs, book) then
				local fits = h.amount <= c
				if (fits and not bestFits) or (fits == bestFits and c > bestCredit) then
					best, bestCredit, bestLabel, bestFits = p.name, c, label, fits
				end
			end
		end
		local key, label
		if best then
			credit[best] = credit[best] - h.amount
			key, label = "@proc:" .. best, bestLabel
		elseif h.age >= 1 then
			-- Mostly overkill can make a hit too big for the rise it caused. With one
			-- proc under the spell, that is whose it is (Pendant of the Plague).
			local only, onlyLabel = AZSMaxHit_OnlyChild(procs, h.spell, book)
			if only then
				key, label = "@proc:" .. only, onlyLabel
			else
				key, label = h.spell .. " (other)", h.spell .. " (other hits)"
			end
		end
		if key then
			if not book.spells[key] then
				book.spells[key] = { max = 0, extraOf = h.spell, label = label }
			end
			record(book, key, h.amount, h.crit, h.target, h.at, h.evt, h.line)
			if key == "@proc:Shadow Weaving" and not h.crit then
				AZSMaxHit_LearnWeaving(book, h.target, h.amount)
			end
			local hw = windowsFor(ME)
			local sw = hw.spells[key]
			if not sw then
				sw = newWindow()
				hw.spells[key] = sw
			end
			recordBurst(book, key, pushWindow(sw, h.t, h.amount), h.at)
			dirty = true
		else
			h.age = h.age + 1
			table.insert(keep, h)
		end
	end
	AZSMaxHit_pending = keep
end

function AZSMaxHit_ResetDirect()
	AZSMaxHit_pending = {}
	AZSMaxHit_weavingSizes = {}
	AZSMaxHit_recentBites = {}
	AZSMaxHit_feedSeen = {}
	AZSMaxHit_heldFeed = {}
	AZSMaxHit_splitExact = {}
	procLast, procCredit = {}, {}
end

-- Combat-log numbers for a proc row, when direct hits were placed with it.
function AZSMaxHit_ProcStats(book, procName)
	return book.spells["@proc:" .. procName]
end

-- Proc damage the game's meter puts under each spell, by spell name.
-- A proc whose hits differ a lot by spell gets a row under each (Windfury Weapon: about 1,350
-- off Stormstrike, 300 off Rockbiter). The meter has one line for it, so that line's total is
-- shared out: by the meter snapshot's own numbers per source when it has them, else by the
-- feed's totals, which include overkill. Either way the rows still add up to the line.
AZSMaxHit_SPLIT_PROC = { ["Windfury Weapon"] = true }
AZSMaxHit_splitExact = {}

function AZSMaxHit_SplitShares(p, book)
	local shares = {}
	local exactSum, feedSum, allExact = 0, 0, true
	local ability, key
	for ability, key in pairs(book.splitRows[p.name]) do
		local stats = book.spells[key] or {}
		local exact = 0
		local known = false
		local sourceKey
		for sourceKey in pairs(stats.sourceKeys or {}) do
			if AZSMaxHit_splitExact[sourceKey] then
				exact = exact + AZSMaxHit_splitExact[sourceKey]
				known = true
			end
		end
		if not known then
			allExact = false
		end
		table.insert(shares, { ability = ability, name = string.sub(key, 7), exact = exact, feed = stats.total or 0 })
		exactSum = exactSum + exact
		feedSum = feedSum + (stats.total or 0)
	end
	local useExact = allExact and exactSum > 0
	local i
	for i = 1, table.getn(shares) do
		local s = shares[i]
		if useExact then
			s.dmg = p.dmg * s.exact / exactSum
		elseif feedSum > 0 then
			s.dmg = p.dmg * s.feed / feedSum
		else
			s.dmg = 0
		end
	end
	return shares
end

function AZSMaxHit_KidSums(book)
	local sums = {}
	local i
	for i = 1, table.getn(meterProcs) do
		local p = meterProcs[i]
		if p.dmg > 0 then
			local where, parent = procPlace(p, book)
			if where == "child" then
				sums[parent] = (sums[parent] or 0) + p.dmg
			elseif where == "split" then
				local shares = AZSMaxHit_SplitShares(p, book)
				local s
				for s = 1, table.getn(shares) do
					sums[shares[s].ability] = (sums[shares[s].ability] or 0) + shares[s].dmg
				end
			end
		end
	end
	return sums
end

-- A spell's row as shown: Total is the spell's own damage from the game's meter
-- (no procs, no overkill) when the meter has a line for it; everything else
-- comes from the combat log. `group` adds the procs under it, for sorting.
-- A spell the meter doesn't list keeps its combat-log total, unless procs sit
-- under it (Corpse Explosion: the meter calls it Shadowform), then Total is empty.
-- Abilities the combat log names by spell but the game's meter by caster.
local OWN_ALIAS = {
	["Searing Totem"] = "attack", -- in case the meter keeps the spell's own name
}

-- This run's damage on the meter's proc line of exactly this name, if any.
function AZSMaxHit_ProcTotal(name)
	local i
	for i = 1, table.getn(meterProcs) do
		local p = meterProcs[i]
		if p.name == name and p.dmg > 0 then
			return p.dmg
		end
	end
	return nil
end

-- Spells a summon casts under your name. With no meter line of their own (spell
-- not learned), their damage is on the summon's line, so Total stays empty.
local SUMMON_SPELL = {
	["Hellfire"] = "infernal",  -- "it burns nearby enemies with Hellfire"
	["Death Coil"] = "succubus", -- "Their kills trigger a Death Coil"
}

-- Which of a summon's rows shows the meter's one line for it, so it counts once:
-- a row named just the summon, else the first "Owner: Spell" row by name.
function AZSMaxHit_OwnerTakes(spell, owner)
	if run.spells[owner] then
		return false
	end
	local lower = string.lower(owner)
	local log, target
	for log, target in pairs(OWN_ALIAS) do
		if target == lower and run.spells[log] then
			return false
		end
	end
	local prefix = owner .. ": "
	local s
	for s in pairs(run.spells) do
		if string.sub(s, 1, string.len(prefix)) == prefix and AZSMaxHit_RowFirst(s, spell) then
			return false
		end
	end
	return true
end

-- Which of a summon's rows leads its group: its melee, else the first by name, so a
-- rare spell (Succubus: Death Coil) doesn't take the top spot from Succubus: Melee.
function AZSMaxHit_RowFirst(a, b)
	local ma = string.find(string.lower(a), ": melee$") and true or false
	local mb = string.find(string.lower(b), ": melee$") and true or false
	if ma ~= mb then
		return ma
	end
	return a < b
end

function AZSMaxHit_OwnView(spell, r, mine, kids)
	local meter = mine and AZSMaxHit_meterOwn
	local own = meter and meter[string.lower(spell)]
	if not own and meter and OWN_ALIAS[spell] then
		own = meter[OWN_ALIAS[spell]]
	end
	-- A proc with a combat-log row of its own name (Deep Wounds): no separate
	-- proc row is shown, so the row's Total is the meter's number.
	if not own and mine then
		own = AZSMaxHit_ProcTotal(spell)
	end
	-- A summon's row ("Voidwalker: Melee"): the meter has one line per summon.
	if not own and meter then
		local _, _, owner = string.find(spell, "^(.-): ")
		local line = owner and (meter[string.lower(owner)] or AZSMaxHit_ProcTotal(owner))
		if not line and owner and SUMMONS[owner] and meter["pets"] then
			-- On the meter's combined Pets line. With several kinds of summon it can't
			-- be split, so it keeps its own row and these rows show "-".
			line = AZSMaxHit_PetsLabel() == owner and meter["pets"] or 0
		end
		if line then
			own = AZSMaxHit_OwnerTakes(spell, owner) and line or 0
		end
		if not own and SUMMON_SPELL[spell] and meter[SUMMON_SPELL[spell]] then
			own = 0
		end
	end
	if not own then
		if not (mine and kids[spell]) then
			return r, r.total or 0
		end
		-- All its hits are the procs' damage (Seal Fate before Eviscerate is learned,
		-- Shadowform's Corpse Explosion). Its log total would count them again with
		-- overkill, so Total stays empty ("-") and the procs carry the number.
		own = 0
	end
	local view = setmetatable({ total = own, logTotal = r.total }, { __index = r })
	return view, own + (kids[spell] or 0)
end

-- The row a summon's other attack is grouped under: Infernal: Melee and Hellfire under
-- Infernal. That row shows the meter's one line, so these show "-". nil for a row of its
-- own, and when several kinds of summon share the Pets line, which keeps its own row.
function AZSMaxHit_GroupParent(spell)
	local meter = AZSMaxHit_meterOwn
	if not meter or meter[string.lower(spell)] then
		return nil
	end
	local _, _, owner = string.find(spell, "^(.-): ")
	local lower = owner and string.lower(owner) or SUMMON_SPELL[spell]
	if not lower then
		return nil
	end
	if not meter[lower] and not (owner and AZSMaxHit_ProcTotal(owner))
			and not (owner and meter["pets"] and AZSMaxHit_PetsLabel() == owner) then
		return nil
	end
	local prefix = lower .. ": "
	local first
	local s, r
	for s, r in pairs(run.spells) do
		if not r.extraOf then
			local name = string.lower(s)
			if name == lower then
				first = s
				break
			end
			if string.sub(name, 1, string.len(prefix)) == prefix and (not first or AZSMaxHit_RowFirst(s, first)) then
				first = s
			end
		end
	end
	local log, target
	for log, target in pairs(OWN_ALIAS) do
		if target == lower and run.spells[log] then
			first = log
		end
	end
	if first == spell then
		return nil
	end
	return first
end

-- A meter line no combat-log row stands for, like Seal Fate, whose hits are logged
-- as Eviscerate. It is placed like a proc, or the rows would not add up to TOTAL.
-- Summons log as "Owner: Spell" while the meter names just the owner.
function AZSMaxHit_MeterOnly(name)
	local lower = string.lower(name)
	-- The Pets line, when its one kind of summon has rows from the log (Treant: Melee):
	-- that row shows the line, so the line needs no row of its own.
	if lower == "pets" then
		lower = string.lower(AZSMaxHit_PetsLabel())
	end
	local prefix = lower .. ": "
	local spell, target
	for spell in pairs(run.spells) do
		local s = string.lower(spell)
		if s == lower or string.sub(s, 1, string.len(prefix)) == prefix then
			return false
		end
	end
	for spell, target in pairs(OWN_ALIAS) do
		if target == lower and run.spells[spell] then
			return false
		end
	end
	return true
end

-- Puts each spell's procs right after it, biggest first.
function AZSMaxHit_ExpandProcs(list, book)
	local kids = {}
	local i
	for i = 1, table.getn(meterProcs) do
		local p = meterProcs[i]
		local where, parent, label = "skip"
		if p.dmg > 0 then
			where, parent, label = procPlace(p, book)
		end
		if where == "split" then
			local shares = AZSMaxHit_SplitShares(p, book)
			local s
			for s = 1, table.getn(shares) do
				local share = shares[s]
				kids[share.ability] = kids[share.ability] or {}
				table.insert(kids[share.ability], { name = share.name, label = p.name, dmg = share.dmg, child = true,
					parent = share.ability, parentTotal = book.spells[share.ability] and book.spells[share.ability].total })
			end
		end
		if where == "child" then
			kids[parent] = kids[parent] or {}
			table.insert(kids[parent], { name = p.name, label = label, dmg = p.dmg, child = true,

				parent = parent, parentTotal = book.spells[parent].total })
		end
	end
	local grand = 0
	local spell, r
	for spell, r in pairs(book.spells) do
		if not r.fromFeed then
			grand = grand + (r.total or 0)
		end
	end
	local out = {}
	for i = 1, table.getn(list) do
		local item = list[i]
		if item.procOnly then
			item.grand = grand
		end
		table.insert(out, item)
		local extra = not item.procOnly and book.spells[item.name .. " (other)"]
		-- Under 1% of the spell's logged damage is noise: a stray hit or two the meter's
		-- timing couldn't place. A spell that really hits directly still shows them.
		local own = book.spells[item.name]
		if extra and (extra.hits or 0) > 0
				and (extra.total or 0) * 100 >= ((own and own.total) or 0) then
			table.insert(out, { name = item.name .. " (other)", label = "Other hits", r = extra,
				extra = true, parent = item.name })
		end
		local grouped = AZSMaxHit_grouped and AZSMaxHit_grouped[item.name]
		if grouped then
			table.sort(grouped, function(a, b) return a.m > b.m end)
			local j
			for j = 1, table.getn(grouped) do
				table.insert(out, grouped[j])
			end
		end
		local k = kids[item.name]
		if k then
			table.sort(k, function(a, b) return a.dmg > b.dmg end)
			local j
			for j = 1, table.getn(k) do
				table.insert(out, k[j])
			end
		end
	end
	return out
end

local function sorted()
	local book = currentBook()
	local col = columnByKey(sortKey)
	local list = {}
	local mine = selected == ME
	local kids = mine and AZSMaxHit_KidSums(book) or {}
	AZSMaxHit_grouped = {}
	local spell, r
	for spell, r in pairs(book.spells) do
		if r.extraOf then
			-- shown under its spell by AZSMaxHit_ExpandProcs
		else
		local view, group = AZSMaxHit_OwnView(spell, r, mine, kids)
		local v = col.value(view)
		if col.key == "total" then v = group end
		local under = mine and AZSMaxHit_GroupParent(spell)
		if under then
			AZSMaxHit_grouped[under] = AZSMaxHit_grouped[under] or {}
			table.insert(AZSMaxHit_grouped[under], { name = spell, r = view, m = r.max or 0, attached = true })
		else
			table.insert(list, { name = spell, r = view, v = v, m = r.max or 0 })
		end
		end
	end
	if mine and next(book.spells) then
		local i
		for i = 1, table.getn(meterProcs) do
			local p = meterProcs[i]
			if p.dmg > 0 and procPlace(p, book) == "alone" then
				-- Hits matched to this row sort with it, so sorting by Hit finds it.
				local pr = setmetatable({ total = p.dmg }, { __index = AZSMaxHit_ProcStats(book, p.name) or {} })
				local label = p.name == "Pets" and AZSMaxHit_PetsLabel() or nil
				table.insert(list, { name = p.name, label = label, r = pr, v = col.value(pr), m = 0, procOnly = true })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.v ~= b.v then
			if col.asc then return a.v < b.v end
			return a.v > b.v
		end
		return a.m > b.m
	end)
	return list
end

-- Layout, top to bottom: title bar, summary strip, divider, hero tabs (co-op
-- only), column headers, rows. The height is yours to set with the grip in
-- the bottom-right corner; rows that don't fit scroll with the mouse wheel.
local PAD = 8
local SUMMARY_Y = -24      -- top of the summary strip
local CONTENT_Y = -66      -- below the divider
local header, partyHeader, emptyText, tiles, scrollTrack, scrollThumb
local visibleRows = 1
local lastLayout

local function layout(showTabs)
	local height = math.floor(frame:GetHeight() or DEFAULT_HEIGHT)
	local key = (showTabs and "t" or "-") .. height
	if key == lastLayout then
		return
	end
	lastLayout = key
	local y = CONTENT_Y
	if showTabs then
		y = y - TAB_H - 2
	end
	header:ClearAllPoints()
	header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, y)
	partyHeader:ClearAllPoints()
	partyHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, y)
	-- Rows that fit between the header and the bottom edge.
	visibleRows = math.floor((height + y - PAD) / ROW_H) - 1
	if visibleRows < 1 then visibleRows = 1 end
	if visibleRows > ROWS then visibleRows = ROWS end
	local i
	for i = 1, ROWS do
		rows[i]:ClearAllPoints()
		rows[i]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, y - i * ROW_H)
	end
	emptyText:ClearAllPoints()
	emptyText:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, y - ROW_H)
	scrollTrack:ClearAllPoints()
	scrollTrack:SetPoint("TOPRIGHT", frame, "TOPLEFT", WIDTH - 3, y - ROW_H)
	scrollTrack:SetHeight(visibleRows * ROW_H)
end

-- Thin bar on the right: only when there are more spells than rows.
local function paintScroll(n)
	if n <= visibleRows then
		scrollTrack:Hide()
		scrollThumb:Hide()
		return
	end
	local trackH = visibleRows * ROW_H
	local thumbH = math.floor(trackH * visibleRows / n)
	if thumbH < 10 then thumbH = 10 end
	local room = trackH - thumbH
	local pos = 0
	if n > visibleRows then
		pos = math.floor(room * offset / (n - visibleRows))
	end
	scrollThumb:ClearAllPoints()
	scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, -pos)
	scrollThumb:SetHeight(thumbH)
	scrollTrack:Show()
	scrollThumb:Show()
end

local function setTile(tile, label, value)
	if value then
		tile.label:SetText(label)
		tile.value:SetText(value)
		tile.label:Show()
		tile.value:Show()
	else
		tile.label:Hide()
		tile.value:Hide()
	end
end

-------------------------------------------------------------------------------
-- Party table (co-op), straight from the game's party meter
-------------------------------------------------------------------------------

-- left / right edges and justification of each party column
local PCOLS = {
	{ label = "Top ability", left = 150, width = 118, justify = "LEFT" },
	{ label = "Top DPS",   right = 318, width = 48 },
	{ label = "DPS",       right = 370, width = 48 },
	{ label = "Total",     right = 432, width = 58 },
	{ label = "Share",     right = 493, width = 46 },
}

-- Globals: keeps createUI and refresh under Lua 5.0's 32-upvalue limit.
function AZSMaxHit_PartyHeader()
	local h = CreateFrame("Frame", nil, frame)
	h:SetWidth(WIDTH)
	h:SetHeight(ROW_H)
	local function label(textValue, left, width, justify)
		local fs = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", h, "LEFT", left, 0)
		fs:SetWidth(width)
		fs:SetHeight(ROW_H)
		fs:SetJustifyH(justify)
		fs:SetTextColor(0.55, 0.55, 0.55)
		fs:SetText(textValue)
	end
	label("Hero", 22, 120, "LEFT")
	local i
	for i = 1, table.getn(PCOLS) do
		local c = PCOLS[i]
		label(c.label, c.left or (c.right - c.width), c.width, c.justify or "RIGHT")
	end
	h:Hide()
	return h
end

function AZSMaxHit_PartyCells(row)
	row.pcells = {}
	local i
	for i = 1, table.getn(PCOLS) do
		local c = PCOLS[i]
		local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetWidth(c.width)
		fs:SetHeight(ROW_H)
		if c.left then
			fs:SetPoint("LEFT", row, "LEFT", c.left, 0)
			fs:SetJustifyH("LEFT")
		else
			fs:SetPoint("RIGHT", row, "LEFT", c.right, 0)
			fs:SetJustifyH("RIGHT")
		end
		fs:SetTextColor(0.75, 0.75, 0.75)
		fs:Hide()
		row.pcells[i] = fs
	end
end

-- Show either the spell columns or the party columns of a row.
function AZSMaxHit_ShowCells(row, partyMode)
	local i
	for i = 1, table.getn(row.cells) do
		if partyMode or (i == AZSMaxHit_AtIndex and not db.showAt)
				or (AZSMaxHit_viewNow and AZSMaxHit_VIEW_HIDE[AZSMaxHit_viewNow][COLS[i].key]) then
			row.cells[i]:Hide()
		else
			row.cells[i]:Show()
		end
	end
	for i = 1, table.getn(row.pcells) do
		if partyMode then row.pcells[i]:Show() else row.pcells[i]:Hide() end
	end
end

-- Class icons: one sheet from character creation, the same one AZS Spell Meter uses.
local CLASS_SHEET = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local CLASS_ICON = {
	warrior = { 0, 0.25, 0, 0.25 },
	mage = { 0.25, 0.49609375, 0, 0.25 },
	rogue = { 0.49609375, 0.7421875, 0, 0.25 },
	druid = { 0.7421875, 0.98828125, 0, 0.25 },
	hunter = { 0, 0.25, 0.25, 0.5 },
	shaman = { 0.25, 0.49609375, 0.25, 0.5 },
	priest = { 0.49609375, 0.7421875, 0.25, 0.5 },
	warlock = { 0.7421875, 0.98828125, 0.25, 0.5 },
	paladin = { 0, 0.25, 0.5, 0.75 },
}

local function classColor(class)
	local colors = RAID_CLASS_COLORS
	local c = class and colors and colors[string.upper(class)]
	if c then
		return c.r, c.g, c.b
	end
	return 1, 1, 1
end

function AZSMaxHit_RefreshParty()
	header:Hide()
	partyHeader:Show()
	local me = UnitName("player")
	local n = table.getn(party)
	if offset > n - visibleRows then offset = n - visibleRows end
	if offset < 0 then offset = 0 end

	local total, dps, best, most = 0, 0, nil, 0
	local i
	for i = 1, n do
		local h = party[i]
		if h.dmg > most then most = h.dmg end
		total = total + h.dmg
		dps = dps + h.dps
		if not best or h.dps > best.dps then
			best = h
		end
	end
	if best then
		setTile(tiles[1], "TOP DPS", "|cffffffff" .. fmt(best.dps) .. "|r  |cffbbbbbb" .. best.name .. "|r")
	else
		setTile(tiles[1], "TOP DPS", "|cff777777-|r")
	end
	setTile(tiles[2], "PARTY DPS", dps > 0 and fmt(dps) or "|cff777777-|r")
	setTile(tiles[3], "PARTY TOTAL", total > 0 and AZSMaxHit_FmtShort(total) or "|cff777777-|r")
	setTile(tiles[4], nil, nil)

	for i = 1, ROWS do
		local row = rows[i]
		local h = i <= visibleRows and party[i + offset]
		if h then
			AZSMaxHit_Indent(row, 0)
			row.name:SetWidth(120) -- the Party tab's layout doesn't change with the At column
			local pr, pg, pb = classColor(h.class)
			AZSMaxHit_Bar(row, most > 0 and h.dmg / most, pr, pg, pb, 0.3, PARTY_BAR_W)
			row.icon:SetAlpha(1)
			row.name:SetText(h.name == me and (h.name .. " |cff777777(you)|r") or h.name)
			row.name:SetTextColor(classColor(h.class))
			local coord = h.class and CLASS_ICON[string.lower(h.class)]
			if db.showIcons and coord then
				row.icon:SetTexture(CLASS_SHEET)
				row.icon:SetTexCoord(coord[1], coord[2], coord[3], coord[4])
				row.icon:Show()
			else
				row.icon:Hide()
			end
			local share = tonumber(h.share)
			if not share then
				share = total > 0 and h.dmg / total or 0
			end
			row.pcells[1]:SetText((h.top and h.top ~= "") and h.top or "-")
			row.pcells[2]:SetText(fmt(h.topdps))
			row.pcells[3]:SetText(fmt(h.dps))
			row.pcells[4]:SetText(AZSMaxHit_FmtColumn(h.dmg))
			row.pcells[5]:SetText(string.format("%d%%", math.floor(share * 100 + 0.5)))
			row.pcells[1]:SetTextColor(1, 1, 1)
			row.pcells[4]:SetTextColor(1, 1, 1)
			AZSMaxHit_ShowCells(row, true)
			row:Show()
		else
			row:Hide()
		end
	end
	if n == 0 then
		emptyText:SetText("The game's party meter is empty.")
		emptyText:Show()
	else
		emptyText:Hide()
	end
	paintScroll(n)
end

-- Shifts a row's icon and name right by `indent` pixels (0 = normal row).
function AZSMaxHit_Indent(row, indent)
	if row.indent == indent then
		return
	end
	row.indent = indent
	row.icon:ClearAllPoints()
	row.icon:SetPoint("LEFT", row, "LEFT", 6 + indent, 0)
	row.name:ClearAllPoints()
	row.name:SetPoint("LEFT", row, "LEFT", 22 + indent, 0)
	row.name:SetWidth(NAME_W - indent)
end

-- A proc row from the game's meter: indented under the spell that triggers
-- it (child), or a row of its own (procOnly), grayed like the indented ones. The game gives a
-- total per proc, not single hits, so the other columns show a faint dot.
function AZSMaxHit_PaintProc(row, item)
	local dmg = item.dmg or (item.r and item.r.total) or 0
	if item.child then
		AZSMaxHit_Indent(row, 14)
		row.name:SetText(item.label or item.name)
	else
		AZSMaxHit_Indent(row, 0)
		row.name:SetText(item.label or item.name)
	end
	row.name:SetTextColor(0.72, 0.72, 0.72)
	if db.showIcons then
		local tex = iconFor(item.label or item.name)
		if tex == QUESTION then
			local _, _, _, spell = string.find(item.name, "^(.-): (.+)$")
			if spell then tex = iconFor(spell) end
		end
		row.icon:SetTexture(tex)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.icon:SetAlpha(0.75)
		row.icon:Show()
	else
		row.icon:Hide()
	end
	-- Single hits, when direct hits were matched to this proc (AZSMaxHit_PlaceDirect).
	local stats = AZSMaxHit_ProcStats(currentBook(), item.name)
	local c
	for c = 1, table.getn(COLS) do
		local fs = row.cells[c]
		local col = COLS[c]
		if col.key == "total" then
			fs:SetText(AZSMaxHit_FmtColumn(dmg))
			fs:SetTextColor(0.72, 0.72, 0.72)
		elseif stats and (stats.hits or 0) > 0 then
			if col.text then
				fs:SetText(col.text(stats))
			else
				fs:SetText(fmt(col.value(stats)))
			end
			if col.key == "crit" and stats.crit then
				fs:SetTextColor(0.85, 0.7, 0.1)
			else
				fs:SetTextColor(0.72, 0.72, 0.72)
			end
		else
			fs:SetText("-") -- the game doesn't report single proc hits
			fs:SetTextColor(0.35, 0.35, 0.35)
		end
	end
	AZSMaxHit_ShowCells(row, false)
	row:Show()
end

-- TOTAL and OVERKILL tiles. The game's meter counts only damage that landed;
-- the combat log counts each hit in full. The gap is damage past the
-- enemies' remaining health.
function AZSMaxHit_TotalTiles(logTotal)
	local landed = (selected == ME) and AZSMaxHit_meterSum or 0
	if landed and landed > 0 then
		setTile(tiles[3], "TOTAL", AZSMaxHit_FmtShort(landed))
		-- Hits we never see can't be part of the gap: pets missing from the log, or in the
		-- feed's mode a summon missing from the feed (a Frost Mage's Water Elemental).
		local pets = AZSMaxHit_ProcTotal("Pets") or 0
		if AZSMaxHit_feedMode and currentBook().spells["@proc:Pets"] then
			pets = 0
		end
		local over = logTotal - (landed - pets)
		if AZSMaxHit_viewNow then
			setTile(tiles[4], nil, nil)
		elseif over > 0 then
			setTile(tiles[4], "OVERKILL", AZSMaxHit_FmtShort(over) .. "  |cff999999"
				.. math.floor(over / logTotal * 100 + 0.5) .. "%|r")
		else
			setTile(tiles[4], "OVERKILL", "|cff777777-|r")
		end
	else
		setTile(tiles[3], "TOTAL", logTotal > 0 and AZSMaxHit_FmtShort(logTotal) or "|cff777777-|r")
		setTile(tiles[4], nil, nil)
	end
end

-- Fill bar behind a row's name and total: `frac` of the biggest total in the
-- list, in class color. It stops at the Total column so the other numbers stay clean.
function AZSMaxHit_Bar(row, frac, r, g, b, a, width)
	if not frac or frac <= 0 then
		row.bar:Hide()
		return
	end
	if frac > 1 then frac = 1 end
	row.bar:SetWidth(math.max(1, frac * (width or BAR_W)))
	row.bar:SetVertexColor(r, g, b, a)
	row.bar:Show()
end

-- Bars always measure damage done, whatever the sort.
function AZSMaxHit_BarValue(item)
	if item.extra then
		return 0
	end
	if item.child or item.procOnly then
		return item.dmg or (item.r and item.r.total) or 0
	end
	return (item.r and item.r.total) or 0
end

function AZSMaxHit_BarMax(list)
	local m, i = 0, nil
	for i = 1, table.getn(list) do
		local v = AZSMaxHit_BarValue(list[i])
		if v > m then m = v end
	end
	return m
end

-- Bar colors by damage school.
local SCHOOL_COLOR = {
	Physical = { 0.78, 0.61, 0.43 },
	Holy = { 1, 0.9, 0.5 },
	Fire = { 1, 0.5, 0.1 },
	Nature = { 0.35, 0.9, 0.35 },
	Frost = { 0.45, 0.75, 1 },
	Shadow = { 0.63, 0.43, 0.9 },
	Arcane = { 1, 0.5, 1 },
}

-- A row's school: its own; a proc's is its parent's; a proc on its own row
-- takes the school you deal the most damage with.
function AZSMaxHit_SchoolColor(item, book)
	local school
	if item.child then
		local pr = book.spells[item.parent]
		school = pr and pr.school
	elseif item.r and not item.procOnly then
		school = item.r.school
	end
	if not school then
		local by, best, spell, r = {}, 0, nil, nil
		for spell, r in pairs(book.spells) do
			if r.school then
				by[r.school] = (by[r.school] or 0) + (r.total or 0)
				if by[r.school] > best then
					best = by[r.school]
					school = r.school
				end
			end
		end
	end
	local c = SCHOOL_COLOR[school or "Physical"] or SCHOOL_COLOR.Physical
	return c[1], c[2], c[3]
end

local function refresh()
	if not frame or not frame:IsShown() then
		return
	end
	dirty = false

	-- Tabs: you and Party, only in co-op.
	local showTabs = inParty()
	if not showTabs then
		selected = ME
	end
	AZSMaxHit_CheckCompact()
	local ti
	for ti = 1, 2 do
		local tab = tabs[ti]
		if showTabs then
			tab.who = (ti == 1) and ME or PARTY
			tab.label:SetText(ti == 1 and (UnitName("player") or "You") or "Party")
			if tab.who == selected then
				tab.label:SetTextColor(1, 0.82, 0)
				tab.bg:SetVertexColor(1, 0.82, 0, 0.22)
			else
				tab.label:SetTextColor(0.7, 0.7, 0.7)
				tab.bg:SetVertexColor(1, 1, 1, 0.06)
			end
			tab:Show()
		else
			tab:Hide()
		end
	end

	if selected == PARTY then
		layout(showTabs)
		AZSMaxHit_RefreshParty()
		return
	end
	header:Show()
	partyHeader:Hide()

	local book = currentBook()
	local list = AZSMaxHit_ExpandProcs(sorted(), book)
	layout(showTabs)
	local n = table.getn(list)
	if offset > n - visibleRows then offset = n - visibleRows end
	if offset < 0 then offset = 0 end

	-- Summary strip: the numbers that matter most.
	local topName, top, grand = nil, nil, 0
	local spell, r
	for spell, r in pairs(book.spells) do
		if not r.fromFeed then
			grand = grand + (r.total or 0)
		end
		if not top or (r.max or 0) > (top.max or 0) then
			topName, top = r.label or spell, r
		end
	end
	if top then
		local label = "TOP HIT"
		if top.crit then label = label .. "  |cffffd100CRIT|r" end
		if top.at and db.showAt then label = label .. "  |cff777777at " .. fmtTime(top.at) .. "|r" end
		setTile(tiles[1], label, (top.crit and "|cffffd100" or "|cffffffff") .. fmt(top.max)
			.. "|r  |cffbbbbbb" .. topName .. "|r")
	else
		setTile(tiles[1], "TOP HIT", "|cff777777-|r")
	end
	local burst = book.burst.amount
	setTile(tiles[2], "BURST" .. (book.burst.at and db.showAt and ("  |cff777777at " .. fmtTime(book.burst.at) .. "|r") or ""),
		burst and AZSMaxHit_FmtShort(burst) or "|cff777777-|r")
	if AZSMaxHit_viewNow == "mini" then
		setTile(tiles[2], nil, nil)
	end
	AZSMaxHit_TotalTiles(grand)

	-- Rows
	local barMax = AZSMaxHit_BarMax(list)
	local i, c
	for i = 1, ROWS do
		local row = rows[i]
		local item = i <= visibleRows and list[i + offset]
		if item then
			local isProc = item.child or item.procOnly
			local cr, cg, cb = AZSMaxHit_SchoolColor(item, book)
			AZSMaxHit_Bar(row, barMax > 0 and AZSMaxHit_BarValue(item) / barMax, cr, cg, cb, isProc and 0.16 or 0.32)
		end
		if item and (item.child or item.procOnly) then
			AZSMaxHit_PaintProc(row, item)
		elseif item then
			r = item.r
			AZSMaxHit_Indent(row, (item.extra or item.attached) and 14 or 0)
			row.name:SetText(item.label or item.name)
			if item.extra then
				row.name:SetTextColor(0.72, 0.72, 0.72)
			else
				row.name:SetTextColor(1, 1, 1)
			end
			if db.showIcons then
				row.icon:SetAlpha(item.extra and 0.75 or 1)
				row.icon:SetTexture(iconFor(item.parent or item.name))
				row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- the party view may have changed it
				row.icon:Show()
			else
				row.icon:Hide()
			end
			for c = 1, table.getn(COLS) do
				local col = COLS[c]
				local fs = row.cells[c]
				if col.text then
					fs:SetText(col.text(r))
				else
					fs:SetText(fmt(col.value(r)))
				end
				if not col.bright then
					fs:SetTextColor(0.75, 0.75, 0.75) -- a proc row may have grayed it
				end
			end
			AZSMaxHit_ShowCells(row, false)
			-- The bigger of Hit and Crit is the spell's top hit: highlight it.
			local hitCell, critCell = row.cells[HIT_I], row.cells[CRIT_I]
			if r.crit then
				hitCell:SetTextColor(0.75, 0.75, 0.75)
				critCell:SetTextColor(1, 0.82, 0)
			else
				hitCell:SetTextColor(1, 1, 1)
				critCell:SetTextColor(0.75, 0.6, 0.2)
			end
			if item.extra then
				-- Their damage is already in the game meter's Shadow Weaving or item
				-- row, so it isn't counted again here.
				for c = 1, table.getn(COLS) do
					if COLS[c].key == "total" then
						row.cells[c]:SetText("-")
						row.cells[c]:SetTextColor(0.35, 0.35, 0.35)
					end
				end
			end
			row:Show()
		else
			row:Hide()
		end
	end

	if n == 0 then
		emptyText:SetText("No hits yet. Go hit something.")
		emptyText:Show()
	else
		emptyText:Hide()
	end
	paintScroll(n)
end

local function text(parent, width, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetJustifyH(justify or "LEFT")
	if width then
		fs:SetWidth(width)
	end
	fs:SetHeight(ROW_H)
	return fs
end

local function button(parent, label, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(16)
	b:SetHeight(16)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("CENTER", b, "CENTER", 0, 0)
	fs:SetText(label)
	fs:SetTextColor(0.6, 0.6, 0.6)
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function() fs:SetTextColor(1, 0.82, 0) end)
	b:SetScript("OnLeave", function()
		if b.active then
			fs:SetTextColor(1, 0.82, 0)
		else
			fs:SetTextColor(0.6, 0.6, 0.6)
		end
	end)
	b.fs = fs
	return b
end

-- A button that stays gold while its view is on.
function AZSMaxHit_PaintViewButton(b, active)
	b.active = active
	if active then
		b.fs:SetTextColor(1, 0.82, 0)
	else
		b.fs:SetTextColor(0.6, 0.6, 0.6)
	end
end

-- Keep the window pinned by its top-left corner so it grows downward.
local function pinTopLeft()
	local left, topY = frame:GetLeft(), frame:GetTop()
	if not left or not topY then
		return false
	end
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, topY)
	db.pos = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = topY }
	return true
end

local function savePos()
	if not pinTopLeft() then
		local point, _, relPoint, x, y = frame:GetPoint()
		db.pos = { point = point, relPoint = relPoint, x = x, y = y }
	end
end

-- Offsets are in the window's own scale, so its corner is converted to stay in place: the
-- top-left, or with `keepRight` the top-right, where the - and + buttons stay under the mouse.
function AZSMaxHit_SetScale(value, keepRight)
	local scale = tonumber(value)
	if not scale or scale < 0.6 or scale > 1.5 then
		return false
	end
	local old = frame:GetScale() or 1
	local left, topY = frame:GetLeft(), frame:GetTop()
	local right = frame:GetRight()
	frame:SetScale(scale)
	db.scale = scale
	if left and topY then
		local x, y = left * old / scale, topY * old / scale
		if keepRight and right then
			x = right * old / scale - frame:GetWidth()
		end
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
		db.pos = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = x, y = y }
	end
	return true
end

local headerCells = {}
local function paintHeaders()
	local i
	for i = 1, table.getn(headerCells) do
		local h = headerCells[i]
		if h.key == sortKey then
			h.fs:SetTextColor(1, 0.82, 0)
		else
			h.fs:SetTextColor(0.55, 0.55, 0.55)
		end
	end
end

local function headerButton(parent, key, label, left, width, justify)
	local b = CreateFrame("Button", nil, parent)
	b:SetPoint("LEFT", parent, "LEFT", left, 0)
	b:SetWidth(width)
	b:SetHeight(ROW_H)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetAllPoints(b)
	fs:SetJustifyH(justify)
	fs:SetText(label)
	b:SetScript("OnClick", function()
		sortKey = key
		db.sort = key
		offset = 0
		paintHeaders()
		refresh()
	end)
	table.insert(headerCells, { key = key, fs = fs, b = b })
	return b
end

-- The title bar's - and + buttons. Past 0.6 or 1.5, and when the window is locked, nothing happens.
function AZSMaxHit_StepScale(delta)
	if db.locked then
		return
	end
	AZSMaxHit_SetScale(math.floor(((db.scale or 1) + delta) * 10 + 0.5) / 10, true)
end

-- Views (the C and M buttons, /maxhit compact, /maxhit mini). Compact: only Total, Hit, Crit
-- and Burst, no OVERKILL tile. Mini: only Total, with TOP HIT and TOTAL on top. Both are narrower.
-- The Party tab has its own columns, so it keeps the full width.
AZSMaxHit_VIEW_HIDE = {
	compact = { avg = true, hits = true, critp = true },
	mini = { hit = true, crit = true, at = true, burst = true, avg = true, hits = true, critp = true },
}

function AZSMaxHit_ViewWanted()
	if selected == PARTY then
		return nil
	end
	return db.view
end

function AZSMaxHit_CheckCompact()
	if AZSMaxHit_ViewWanted() ~= AZSMaxHit_viewNow then
		AZSMaxHit_ApplyColumns()
	end
end

-- Turns a view on, or off if it is on. The top-right corner stays in place, so the button
-- stays under the mouse.
function AZSMaxHit_SetView(view)
	local right, topY = frame:GetRight(), frame:GetTop()
	if db.view == view then
		db.view = nil
	else
		db.view = view
	end
	AZSMaxHit_ApplyColumns()
	if right and topY then
		local x = right - frame:GetWidth()
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, topY)
		db.pos = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = x, y = topY }
	end
end

-- The At column is off by default (/maxhit at). Turning it on widens the window by
-- 42 px and moves the columns after it; everything before it stays where it is.
function AZSMaxHit_ApplyColumns()
	local view = AZSMaxHit_ViewWanted()
	AZSMaxHit_viewNow = view
	-- From the setting, not `view`: it stays on while the Party tab shows the full width.
	AZSMaxHit_PaintViewButton(frame.compactButton, db.view == "compact")
	AZSMaxHit_PaintViewButton(frame.miniButton, db.view == "mini")
	local hide = view and AZSMaxHit_VIEW_HIDE[view] or {}
	local extra = (db.showAt and view ~= "mini") and 42 or 0
	WIDTH = (view == "mini" and 222 or view == "compact" and 382 or 500) + extra
	frame:SetWidth(WIDTH)
	frame.titleBtn:SetWidth(WIDTH - 140)
	frame.divider:SetWidth(WIDTH - 2 * PAD)
	header:SetWidth(WIDTH)
	lastLayout = nil -- the scrollbar sits at the window's right edge
	if (not db.showAt and sortKey == "at") or hide[sortKey] then
		sortKey = "total"
		db.sort = sortKey
	end
	local i, c
	for i = 1, table.getn(headerCells) do
		local h = headerCells[i]
		if hide[h.key] or (h.key == "at" and not db.showAt) then
			h.b:Hide()
		else
			h.b:Show()
		end
		for c = AZSMaxHit_AtIndex + 1, table.getn(COLS) do
			local col = COLS[c]
			if col.key == h.key then
				h.b:ClearAllPoints()
				h.b:SetPoint("LEFT", header, "LEFT", col.right - col.width + extra, 0)
			end
		end
	end
	for i = 1, table.getn(rows) do
		rows[i]:SetWidth(WIDTH)
		for c = AZSMaxHit_AtIndex + 1, table.getn(COLS) do
			local fs = rows[i].cells[c]
			fs:ClearAllPoints()
			fs:SetPoint("RIGHT", rows[i], "LEFT", COLS[c].right + extra, 0)
		end
		AZSMaxHit_ShowCells(rows[i], false)
	end
	-- With times on, BURST's label needs room for "at 12:34".
	local burstW = db.showAt and 92 or 60
	if view == "mini" then
		-- TOTAL lined up with its column's right edge.
		AZSMaxHit_MoveTile(tiles[1], PAD + 2, 137)
		AZSMaxHit_MoveTile(tiles[3], 149, 58)
	elseif view == "compact" then
		-- TOP HIT on the left, and the two sums as a pair on the right, with BURST lined
		-- up with its column's right edge.
		AZSMaxHit_MoveTile(tiles[1], PAD + 2, 228)
		AZSMaxHit_MoveTile(tiles[3], 240, 72)
		AZSMaxHit_MoveTile(tiles[2], 375 + extra - burstW, burstW)
	else
		AZSMaxHit_MoveTile(tiles[1], PAD + 2, 246)
		AZSMaxHit_MoveTile(tiles[2], 258, burstW)
		AZSMaxHit_MoveTile(tiles[3], 258 + burstW + 2, 72)
	end
	local justify = view and "RIGHT" or "LEFT"
	tiles[2].label:SetJustifyH(justify)
	tiles[2].value:SetJustifyH(justify)
	tiles[3].label:SetJustifyH(justify)
	tiles[3].value:SetJustifyH(justify)
	AZSMaxHit_MoveTile(tiles[4], 392 + extra, 102)
	paintHeaders()
end

local function makeTile(x, width)
	local tile = {}
	tile.label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	tile.label:SetPoint("TOPLEFT", frame, "TOPLEFT", x, SUMMARY_Y)
	tile.label:SetWidth(width)
	tile.label:SetJustifyH("LEFT")
	tile.label:SetTextColor(0.55, 0.55, 0.55)
	tile.value = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	tile.value:SetPoint("TOPLEFT", frame, "TOPLEFT", x, SUMMARY_Y - 13)
	tile.value:SetWidth(width)
	tile.value:SetHeight(20)
	tile.value:SetJustifyH("LEFT")
	pcall(tile.value.SetFont, tile.value, "Fonts\\FRIZQT__.TTF", 15)
	return tile
end

function AZSMaxHit_MoveTile(tile, x, width)
	tile.label:ClearAllPoints()
	tile.label:SetPoint("TOPLEFT", frame, "TOPLEFT", x, SUMMARY_Y)
	tile.label:SetWidth(width)
	tile.value:ClearAllPoints()
	tile.value:SetPoint("TOPLEFT", frame, "TOPLEFT", x, SUMMARY_Y - 13)
	tile.value:SetWidth(width)
end

-- Scrollbar and resize grip (kept apart from createUI: Lua 5.0 allows
-- only 32 outside variables per function).
local function createSizing()
	-- Scrollbar (display only; the mouse wheel scrolls).
	scrollTrack = frame:CreateTexture(nil, "BACKGROUND")
	scrollTrack:SetTexture(SOLID)
	scrollTrack:SetVertexColor(1, 1, 1, 0.05)
	scrollTrack:SetWidth(3)
	scrollThumb = frame:CreateTexture(nil, "ARTWORK")
	scrollThumb:SetTexture(SOLID)
	scrollThumb:SetVertexColor(1, 0.82, 0, 0.5)
	scrollThumb:SetWidth(3)

	-- Resize grip, bottom-right: drag to set the height. Done by following the
	-- cursor, like AZS Spell Meter, rather than relying on StartSizing.
	local grip = CreateFrame("Button", nil, frame)
	grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
	grip:SetWidth(14)
	grip:SetHeight(14)
	grip:SetFrameLevel((frame:GetFrameLevel() or 1) + 5)
	local gi
	for gi = 1, 3 do
		local mark = grip:CreateTexture(nil, "ARTWORK")
		mark:SetTexture(SOLID)
		mark:SetVertexColor(0.72, 0.56, 0.24, 0.95)
		mark:SetWidth(gi * 3)
		mark:SetHeight(1)
		mark:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -1, 1 + (gi - 1) * 3)
	end
	local function cursorY()
		local scale = frame.GetEffectiveScale and frame:GetEffectiveScale() or 1
		local _, cy = GetCursorPosition()
		return (cy or 0) / (scale or 1)
	end
	local function stopSizing()
		frame.sizing = false
		db.height = math.floor(frame:GetHeight())
		refresh()
	end
	grip:SetScript("OnMouseDown", function()
		if db.locked or not GetCursorPosition then
			return
		end
		frame.sizeY = cursorY()
		frame.sizeH = frame:GetHeight()
		frame.sizing = true
	end)
	grip:SetScript("OnMouseUp", function()
		if frame.sizing then
			stopSizing()
		end
	end)
	frame:SetScript("OnUpdate", function()
		if not frame.sizing then
			return
		end
		if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
			stopSizing()
			return
		end
		local h = frame.sizeH - (cursorY() - frame.sizeY)
		if h < MIN_HEIGHT then h = MIN_HEIGHT end
		if h > MAX_HEIGHT then h = MAX_HEIGHT end
		frame:SetHeight(h)
		refresh()
	end)
end

local function createUI()
	if frame then
		return
	end

	frame = CreateFrame("Frame", "AZSMaxHitFrame", UIParent)
	frame:SetWidth(WIDTH)
	frame:SetHeight(db.height or DEFAULT_HEIGHT)
	frame:SetScale(db.scale or 1)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = SOLID,
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.05, 0.85)
	frame:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
	if db.pos then
		frame:SetPoint(db.pos.point or "CENTER", UIParent, db.pos.relPoint or "CENTER", db.pos.x or 0, db.pos.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	end
	-- Older versions saved other anchors; switch to top-left once laid out.
	if not db.pos or db.pos.point ~= "TOPLEFT" or db.pos.relPoint ~= "BOTTOMLEFT" then
		pinTopLeft()
	end

	frame:EnableMouse(true)
	frame:EnableMouseWheel(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function()
		if not db.locked then this:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function()
		this:StopMovingOrSizing()
		savePos()
	end)
	frame:SetScript("OnMouseWheel", function()
		offset = offset - arg1 -- refresh() keeps it in range
		refresh()
	end)
	frame:SetScript("OnShow", function() refresh() end)

	-- Title bar: drag to move the window.
	local titleBtn = CreateFrame("Button", nil, frame)
	titleBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -5)
	titleBtn:SetWidth(WIDTH - 140)
	frame.titleBtn = titleBtn
	titleBtn:SetHeight(16)
	titleBtn:RegisterForDrag("LeftButton")
	titleBtn:SetScript("OnDragStart", function()
		if not db.locked then frame:StartMoving() end
	end)
	titleBtn:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		savePos()
	end)
	title = titleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", titleBtn, "LEFT", 0, 0)
	title:SetJustifyH("LEFT")
	title:SetText("Max Hit")

	local close = button(frame, "x", function() frame:Hide(); db.shown = false end)
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -5)
	local reset = button(frame, "R", function()
		resetRun()
		refresh()
	end)
	reset:SetPoint("RIGHT", close, "LEFT", -4, 0)
	local miniButton = button(frame, "M", function()
		AZSMaxHit_SetView("mini")
		refresh()
	end)
	miniButton:SetPoint("RIGHT", reset, "LEFT", -4, 0)
	local compactButton = button(frame, "C", function()
		AZSMaxHit_SetView("compact")
		refresh()
	end)
	compactButton:SetPoint("RIGHT", miniButton, "LEFT", -4, 0)
	frame.compactButton, frame.miniButton = compactButton, miniButton
	local bigger = button(frame, "+", function() AZSMaxHit_StepScale(0.1) end)
	bigger:SetPoint("RIGHT", compactButton, "LEFT", -4, 0)
	local smaller = button(frame, "-", function() AZSMaxHit_StepScale(-0.1) end)
	smaller:SetPoint("RIGHT", bigger, "LEFT", -4, 0)

	-- Summary strip
	tiles = {
		makeTile(PAD + 2, 246),
		makeTile(258, 60),
		makeTile(320, 72),
		makeTile(392, 102),
	}

	local divider = frame:CreateTexture(nil, "ARTWORK")
	divider:SetTexture(SOLID)
	divider:SetVertexColor(1, 1, 1, 0.08)
	divider:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, CONTENT_Y + 6)
	divider:SetWidth(WIDTH - 2 * PAD)
	frame.divider = divider
	divider:SetHeight(1)

	-- Tabs (co-op only): your spells, and the Party table.
	tabs = {}
	local ti
	for ti = 1, 2 do
		local tab = CreateFrame("Button", nil, frame)
		tab:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (ti - 1) * 106, CONTENT_Y)
		tab:SetWidth(102)
		tab:SetHeight(TAB_H - 2)
		tab.bg = tab:CreateTexture(nil, "BACKGROUND")
		tab.bg:SetAllPoints(tab)
		tab.bg:SetTexture(SOLID)
		tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		tab.label:SetAllPoints(tab)
		tab.label:SetJustifyH("CENTER")
		tab:SetScript("OnClick", function()
			selected = this.who or ME
			offset = 0
			refresh()
		end)
		tab:Hide()
		tabs[ti] = tab
	end

	-- Column headers: click one to sort by it. "Ability" sorts by top hit.
	header = CreateFrame("Frame", nil, frame)
	header:SetWidth(WIDTH)
	header:SetHeight(ROW_H)
	headerButton(header, "best", "Ability", 22, NAME_W, "LEFT")
	local c
	for c = 1, table.getn(COLS) do
		local col = COLS[c]
		headerButton(header, col.key, col.label, col.right - col.width, col.width, "RIGHT")
	end
	paintHeaders()
	partyHeader = AZSMaxHit_PartyHeader()

	rows = {}
	local i
	for i = 1, ROWS do
		local row = CreateFrame("Frame", nil, frame)
		row:SetWidth(WIDTH)
		row:SetHeight(ROW_H)
		row.bar = row:CreateTexture(nil, "BACKGROUND")
		row.bar:SetTexture(SOLID)
		row.bar:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.bar:SetHeight(ROW_H - 1)
		row.bar:Hide()
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetWidth(ROW_H - 2)
		row.icon:SetHeight(ROW_H - 2)
		row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.name = text(row, 120)
		row.name:SetPoint("LEFT", row, "LEFT", 22, 0)
		row.cells = {}
		for c = 1, table.getn(COLS) do
			local col = COLS[c]
			local fs = text(row, col.width, "RIGHT")
			fs:SetPoint("RIGHT", row, "LEFT", col.right, 0)
			if not col.bright then
				fs:SetTextColor(0.75, 0.75, 0.75)
			end
			row.cells[c] = fs
		end
		AZSMaxHit_PartyCells(row)
		rows[i] = row
	end
	AZSMaxHit_ApplyColumns()

	emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	emptyText:SetWidth(WIDTH - 40)
	emptyText:SetJustifyH("LEFT")
	emptyText:SetTextColor(0.55, 0.55, 0.55)

	createSizing()

	if db.shown == false then
		frame:Hide()
	end
	refresh()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local KIND = {
	CHAT_MSG_SPELL_SELF_DAMAGE = "yours",
	CHAT_MSG_COMBAT_SELF_HITS = "yours",
	CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF = "yours",
	CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE = "periodic",
	CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE = "periodic",
	CHAT_MSG_SPELL_PET_DAMAGE = "pet",
	CHAT_MSG_COMBAT_PET_HITS = "petmelee",
	-- Extra minions often log as friendly NPCs; only your summons are kept.
	CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE = "pet",
	CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS = "petmelee",
}

-- Nothing in the client clears the party meter, so after leaving a co-op run
-- with End Run it could keep the old party's lines. The run's context knows.
function AZSMaxHit_IsSolo()
	if not AZS_GetMeterContext then
		return false
	end
	local ok, context = pcall(AZS_GetMeterContext)
	return ok and type(context) == "table" and context.partyState == "solo"
end

-- Co-op heroes, straight from the game's party meter. Empty when playing solo.
local function readParty()
	local list = {}
	if AZS_GetPartyMeter and not AZSMaxHit_IsSolo() then
		local ok, lines = pcall(AZS_GetPartyMeter)
		if ok and type(lines) == "table" then
			local i
			for i = 1, table.getn(lines) do
				local line = lines[i]
				if type(line) == "table" and line.name and line.name ~= "" then
					table.insert(list, {
						name = clean(line.name) or line.name,
						dmg = tonumber(line.dmg) or 0,
						dps = tonumber(line.dps) or 0,
						top = line.top,
						topdps = tonumber(line.topdps) or 0,
						share = tonumber(line.share),
						class = line.class,
					})
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.dmg > b.dmg end)
	-- Redraw when the Party tab is open, or when someone joins or leaves.
	if selected == PARTY or table.getn(list) ~= table.getn(party) then
		dirty = true
	end
	party = list
end

-- /maxhit party: what the game's party meter reports, for bug reports.
local function dumpParty()
	if not AZS_GetPartyMeter then
		say("party meter: AZS_GetPartyMeter is missing in this game version.")
		return
	end
	local ok, lines = pcall(AZS_GetPartyMeter)
	if not ok or type(lines) ~= "table" then
		say("party meter: returned nothing readable.")
		return
	end
	say("party meter: " .. table.getn(lines) .. " lines (you are " .. tostring(UnitName("player")) .. ")")
	local i
	for i = 1, table.getn(lines) do
		local line = lines[i]
		if type(line) == "table" then
			local fields = {}
			local k, v
			for k, v in pairs(line) do table.insert(fields, tostring(k) .. "=" .. tostring(v)) end
			table.sort(fields)
			say("  " .. i .. ". " .. table.concat(fields, ", "))
		end
	end
end

local function widenCombatLog()
	if not SetCVar then
		return
	end
	local names = { "CombatLogRangeCreature", "CombatLogRangeFriendlyPlayers",
		"CombatLogRangeFriendlyPlayersPets", "CombatLogRangeParty", "CombatLogRangePartyPet" }
	local i
	for i = 1, table.getn(names) do
		pcall(SetCVar, names[i], "200")
	end
end

local function loadDB()
	AZSMaxHitDB = AZSMaxHitDB or {}
	db = AZSMaxHitDB
	db.version = DB_VERSION
	-- No history: the window starts empty whenever the game loads. Saved data
	-- holds only settings, the window position and icons found.
	db.run = { players = {} }
	db.best, db.alerts, db.alertChat, db.view = nil, nil, nil, nil -- left over from 1.1-1.5
	db.owners = db.owners or {}
	if db.showIcons == nil then db.showIcons = true end
	db.icons = db.icons or {}
	if not db.iconsLC then
		db.iconsLC = {}
		local n, tex
		for n, tex in pairs(db.icons) do
			db.iconsLC[string.lower(n)] = tex
		end
	end
	run = runBook(ME)
	sortKey = db.sort or "best"
	resetWindows()
end

local driver = CreateFrame("Frame", "AZSMaxHitDriver")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
local ICON_EVENTS = { SPELLS_CHANGED = true, LEARNED_SPELL_IN_TAB = true,
	CHARACTER_POINTS_CHANGED = true, PET_BAR_UPDATE = true, UNIT_PET = true }
local iconsDirty = true
for evtName in pairs(ICON_EVENTS) do
	driver:RegisterEvent(evtName)
end
local evtName
for evtName in pairs(KIND) do
	driver:RegisterEvent(evtName)
end

driver:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			loadDB()
		end
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		if not db then loadDB() end
		widenCombatLog()
		createUI()
		return
	end
	if not db then
		return
	end
	if ICON_EVENTS[event] then
		iconsDirty = true
		return
	end
	local kind = KIND[event]
	if kind and not AZSMaxHit_HoldLogHit(arg1, kind, event) then
		ingest(arg1, kind, event)
	end
end)

-- The meter's "Pets" line covers all your summons. With only one kind out this
-- run, the row can name it (Water Elemental); it stays "Pets" once there are more.
function AZSMaxHit_PetsLabel()
	if AZS_GetSummons and AZSMaxHit_onePet ~= false then
		local ok, list = pcall(AZS_GetSummons)
		if ok and type(list) == "table" then
			local i
			for i = 1, table.getn(list) do
				local name = list[i].name
				if name and name ~= "" then
					if AZSMaxHit_onePet and AZSMaxHit_onePet ~= name then
						AZSMaxHit_onePet = false
						return "Pets"
					end
					AZSMaxHit_onePet = name
					rememberIcon(name, list[i].icon)
					-- A named pet the game gives no icon for still gets the pet icon.
					if iconFor(name) == QUESTION then
						rememberIcon(name, FALLBACK_ICONS["Pets"])
					end
				end
			end
		end
	end
	return AZSMaxHit_onePet or "Pets"
end

-- Hunter pets and the like are on the meter's Pets line but not in the combat log, while
-- the game's combat text feed has their hits. Only for that case: summons with hits in
-- the log (Warlock demons, Treants) would count twice.
function AZSMaxHit_TakesPetHits()
	return (AZSMaxHit_ProcTotal("Pets") or 0) > 0 and AZSMaxHit_MeterOnly("Pets")
end

-- `presentedAt` is GetTime() when the hit landed, so Burst counts it at the right moment
-- even though the feed is read twice a second. `fromFeed` keeps these hits out of
-- OVERKILL, which compares the combat log with the meter.
function AZSMaxHit_RecordPetHit(book, e, at, procName)
	procName = procName or "Pets"
	local key = "@proc:" .. procName
	local r = book.spells[key]
	if not r then
		r = { max = 0, extraOf = "Pets", fromFeed = true }
		book.spells[key] = r
	end
	r.label = procName == "Pets" and AZSMaxHit_PetsLabel() or procName
	local amount = tonumber(e.amount)
	record(book, key, amount, e.critical and true or false, e.targetName, at, "COMBAT_TEXT_FEED",
		r.label .. (e.critical and " crits " or " hits ") .. tostring(e.targetName) .. " for " .. amount)
	local hw = windowsFor(ME)
	local sw = hw.spells[key]
	if not sw then
		sw = newWindow()
		hw.spells[key] = sw
	end
	local t = tonumber(e.presentedAt) or now()
	recordBurst(book, key, pushWindow(sw, t, amount), at)
	recordTotalBurst(book, pushWindow(hw.total, t, amount), at)
	dirty = true
end

-- Bestial Wrath: "bites tear through 2 more enemies nearby for {v}% of the bite". Seen on a
-- White Devilsaur: the splash is a plain pet hit about 0.28 s after the bite, on another enemy,
-- with the bite's exact amount and no crit flag, so a crit's splash looked like a normal hit as
-- big as the crit. Two bites can land at the same moment, so a shared moment proves nothing.
-- A bite is remembered across reads, since its splash can arrive in the next one.
AZSMaxHit_recentBites = {}

function AZSMaxHit_PlacePetHits(book, hits, at)
	local wrath = (AZSMaxHit_ProcTotal("Bestial Wrath") or 0) > 0
	local i
	for i = 1, table.getn(hits) do
		local e = hits[i]
		local t = tonumber(e.presentedAt) or 0
		local amount = tonumber(e.amount)
		local recent = AZSMaxHit_recentBites
		while recent[1] and t - recent[1].t > 1 do
			table.remove(recent, 1)
		end
		-- Since game 0.139 the hit names its meter line. The guess below is for older games,
		-- or a name that isn't a line we show.
		if e.meterSource and (AZSMaxHit_ProcTotal(e.meterSource) or 0) > 0 then
			AZSMaxHit_RecordPetHit(book, e, at, e.meterSource)
		else
			local bite
			if wrath and not e.critical then
				local j
				for j = 1, table.getn(recent) do
					local b = recent[j]
					local gap = t - b.t
					if b.amount == amount and b.targetId ~= e.targetId and b.splashes < 2
							and gap >= 0.1 and gap <= 0.45 then
						bite = b
						break
					end
				end
			end
			if bite then
				bite.splashes = bite.splashes + 1
				AZSMaxHit_RecordPetHit(book, e, at, "Bestial Wrath")
			else
				table.insert(recent, { t = t, amount = amount, targetId = e.targetId, splashes = 0 })
				AZSMaxHit_RecordPetHit(book, e, at)
			end
		end
	end
end

-- For /maxhit feed: how the combat text feed names this run's hits, per source, ability and
-- meter line. This is what shows whether the log's proc guessing can move to the feed.
AZSMaxHit_feedSeen = {}

function AZSMaxHit_NoteFeed(e)
	local kind = tostring(e.sourceKind)
	local ability = e.abilityName or e.damageType or "?"
	local source = e.meterSource or "(none)"
	local periodic = e.periodic and true or false
	local id = kind .. "|" .. ability .. "|" .. source .. "|" .. tostring(periodic)
	local s = AZSMaxHit_feedSeen[id]
	if not s then
		s = { kind = kind, ability = ability, source = source, periodic = periodic,
			key = e.meterSourceKey, hits = 0, total = 0, max = 0 }
		AZSMaxHit_feedSeen[id] = s
	end
	local amount = tonumber(e.amount)
	s.hits = s.hits + 1
	s.total = s.total + amount
	if amount > s.max then
		s.max = amount
	end
end

function AZSMaxHit_DumpFeed(say)
	local list = {}
	local _, s
	for _, s in pairs(AZSMaxHit_feedSeen) do
		table.insert(list, s)
	end
	if table.getn(list) == 0 then
		say("no damage in the game's combat text feed yet this run.")
		return
	end
	table.sort(list, function(a, b) return a.total > b.total end)
	say("combat text feed, this run: source, ability -> meter line")
	local i
	for i = 1, table.getn(list) do
		s = list[i]
		say(s.kind .. ", " .. s.ability .. (s.periodic and " (ticks)" or "") .. " -> " .. s.source
			.. " [" .. tostring(s.key) .. "]: " .. s.hits .. " hits, total " .. s.total .. ", biggest " .. s.max)
	end
end

-- Since game 0.139 the feed says which meter line each hit counts toward, so a row's Hit, Crit
-- and the rest are exact: a Shadow Weaving strike that the log calls Shadow Word: Pain goes on
-- Shadow Weaving's row. In that mode the combat log isn't read at all, and all the guessing
-- from it (hit matching, DOT_ONLY, LOG_NAME, summons' rows) stays out of the way.
-- nil until decided: a run's first hit can name no line, so one event can't tell an older
-- game apart. Log hits wait meanwhile, and are read after all if the feed turns out too old.
AZSMaxHit_feedMode = nil
AZSMaxHit_heldLog = {}
AZSMaxHit_heldFeed = {}
AZSMaxHit_unnamedHits = 0

local FEED_SCHOOL = {
	[1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature", [16] = "Frost", [32] = "Shadow", [64] = "Arcane",
}

function AZSMaxHit_HoldLogHit(msg, kind, evt)
	if AZSMaxHit_feedMode ~= nil then
		return AZSMaxHit_feedMode
	end
	if not AZS_GetCombatTextEvents then
		AZSMaxHit_feedMode = false
		return false
	end
	table.insert(AZSMaxHit_heldLog, { msg = msg, kind = kind, evt = evt, t = now() })
	return true
end

function AZSMaxHit_DecideFeed(useFeed)
	AZSMaxHit_feedMode = useFeed
	local held = AZSMaxHit_heldLog
	AZSMaxHit_heldLog = {}
	if not useFeed then
		local keepEvent, keepArg = event, arg1
		local i
		for i = 1, table.getn(held) do
			event, arg1 = held[i].evt, held[i].msg
			ingest(held[i].msg, held[i].kind, held[i].evt)
		end
		event, arg1 = keepEvent, keepArg
	end
end

-- The row a hit goes on: its key, and for a meter line under another name its label and the
-- ability it borrows. A summon's swing may name the summon while the meter only has Pets.
function AZSMaxHit_FeedRow(e)
	local summon = e.sourceKind == "summon" or e.sourceKind == "pet"
	local ability = e.abilityName
	if not ability and not summon then
		ability = e.reflected and "Damage Shield" or "Melee"
	end
	local source = e.meterSource
	-- AZSMaxHit_LogName reads the school from the log's sentence (Attack in Fire is Searing Totem).
	local sentence = " " .. (FEED_SCHOOL[e.schoolMask] or "Physical") .. " damage."
	if summon then
		local own = AZSMaxHit_meterOwn
		local listed = source and ((own and own[string.lower(source)]) or AZSMaxHit_ProcTotal(source))
		if not source or (not listed and (AZSMaxHit_ProcTotal("Pets") or 0) > 0) then
			source = "Pets"
		end
	end
	if not source then
		return AZSMaxHit_LogName(ability, sentence)
	end
	-- A summon's attacks keep their grouped rows under its meter line: Infernal, then
	-- Infernal: Melee and Hellfire (AZSMaxHit_GroupParent, AZSMaxHit_OwnerTakes).
	-- One that casts a spell you also cast (Dread Lord, Searing Pain) is a proc under that spell.
	-- A pet's swing can count for a talent or item (Bestial Wrath's splash): that is a proc's row.
	local key = e.meterSourceKey or ""
	local byItem = string.find(key, "^talent:") or string.find(key, "^amulet:")
		or string.find(key, "^jewel:") or string.find(key, "^item:") or string.find(key, "^set:")
	if source ~= "Pets" and not PROC_PARENT[source] and not byItem and (summon or SUMMONS[source]) then
		local name = ability and AZSMaxHit_LogName(ability, sentence)
		if name and string.lower(name) == string.lower(source) then
			return source
		end
		-- Hellfire is only ever the Infernal's. A Succubus's Death Coil stays apart from your own.
		if name == "Hellfire" then
			return name
		end
		return source .. ": " .. (ability or "Melee")
	end
	-- The log's other names count as the spell's own (Deep Wound, Attack for Searing Totem).
	local named = ability and AZSMaxHit_LogName(ability, sentence)
	if named and string.lower(named) == string.lower(source) then
		return source
	end
	local _, _, item = string.find(source, "^(.-): ")
	local label = item or source
	if source == "Pets" then
		label = AZSMaxHit_PetsLabel()
	end
	if named and AZSMaxHit_SPLIT_PROC[source] then
		return "@proc:" .. source .. "@" .. named, label, named
	end
	return "@proc:" .. source, label, named or "Pets"
end

function AZSMaxHit_PlaceFeedHit(book, e, at)
	local key, label, extraOf = AZSMaxHit_FeedRow(e)
	local r = book.spells[key]
	if extraOf and not r then
		r = { max = 0, extraOf = extraOf }
		book.spells[key] = r
	end
	if r and label then
		r.label = label
	end
	local _, _, splitProc = string.find(key, "^@proc:(.-)@")
	if splitProc then
		book.splitRows = book.splitRows or {}
		book.splitRows[splitProc] = book.splitRows[splitProc] or {}
		book.splitRows[splitProc][extraOf] = key
		if not book.spells[extraOf] then
			book.spells[extraOf] = { max = 0 }
		end
		-- A new rank is a new key in the meter's snapshot.
		r.sourceKeys = r.sourceKeys or {}
		if e.meterSourceKey then
			r.sourceKeys[e.meterSourceKey] = true
		end
	end
	-- A demon always sits under the spell it casts, which gets a row with dashes until you cast
	-- it too, so the layout doesn't jump when you pick the spell (Dread Lord, Searing Pain).
	local demon = extraOf and string.sub(key, 7)
	if demon and SUMMONS[demon] and PROC_PARENT[demon] and not book.spells[PROC_PARENT[demon]] then
		book.spells[PROC_PARENT[demon]] = { max = 0 }
	end
	-- Which spells this proc borrows. With just one it sits under that spell, which gets a row
	-- of dashes until you learn it (Shadowy Apparitions, Mind Blast), so the layout doesn't jump.
	-- Corpse Explosion is no spell you pick, so Shadowform stands alone. `procPlace` reads this.
	-- A talent not known to belong to one spell may follow several (Shadow Weaving), and its
	-- first hit can't tell: it stands alone from the start instead of moving out later.
	local freeTalent = e.meterSourceKey and string.sub(e.meterSourceKey, 1, 7) == "talent:"
		and not PROC_PARENT[string.sub(key, 7)]
	if extraOf and extraOf ~= "Pets" and not freeTalent then
		r.abilities = r.abilities or {}
		if not r.abilities[extraOf] then
			r.abilities[extraOf] = true
			r.abilityCount = (r.abilityCount or 0) + 1
			if r.abilityCount == 1 and extraOf ~= "Corpse Explosion" and not book.spells[extraOf] then
				book.spells[extraOf] = { max = 0 }
			end
		end
	end
	local name = label or key
	if e.icon and iconFor(name) == QUESTION then
		rememberIcon(name, e.icon)
	end
	local amount = tonumber(e.amount)
	local line = name .. (e.critical and " crits " or " hits ") .. tostring(e.targetName) .. " for " .. amount
		.. " " .. (FEED_SCHOOL[e.schoolMask] or "Physical") .. " damage."
	record(book, key, amount, e.critical and true or false, e.targetName, at, "COMBAT_TEXT_FEED", line)
	local hw = windowsFor(ME)
	local sw = hw.spells[key]
	if not sw then
		sw = newWindow()
		hw.spells[key] = sw
	end
	local t = tonumber(e.presentedAt) or now()
	recordBurst(book, key, pushWindow(sw, t, amount), at)
	recordTotalBurst(book, pushWindow(hw.total, t, amount), at)
	dirty = true
end

AZSMaxHit_feedCursor = nil

function AZSMaxHit_ReadFeed()
	if not AZS_GetCombatTextEvents then
		return
	end
	-- The feed never answering shouldn't lose the log's hits.
	local firstHeld = AZSMaxHit_heldLog[1]
	if AZSMaxHit_feedMode == nil and firstHeld and now() - firstHeld.t > 5 then
		AZSMaxHit_DecideFeed(false)
	end
	local page
	for page = 1, 8 do
		local ok, r, err = pcall(AZS_GetCombatTextEvents, AZSMaxHit_feedCursor, 256)
		if not ok then
			return
		end
		if not r then
			-- A new world starts a new stream, which the old cursor doesn't belong to.
			if err and err.code == "STREAM_CHANGED" then
				AZSMaxHit_feedCursor = nil
			end
			return
		end
		AZSMaxHit_feedCursor = r.cursor or AZSMaxHit_feedCursor
		local events = r.events or {}
		local i
		for i = 1, table.getn(events) do
			local e = events[i]
			if e.kind == "damage" and (tonumber(e.amount) or 0) > 0 then
				AZSMaxHit_NoteFeed(e)
				table.insert(AZSMaxHit_heldFeed, e)
				if AZSMaxHit_feedMode == nil then
					if e.meterSource then
						AZSMaxHit_DecideFeed(true)
					else
						AZSMaxHit_unnamedHits = AZSMaxHit_unnamedHits + 1
						if AZSMaxHit_unnamedHits >= 10 then
							AZSMaxHit_DecideFeed(false)
						end
					end
				end
			end
		end
		if AZSMaxHit_feedMode ~= nil and table.getn(AZSMaxHit_heldFeed) > 0 then
			local held = AZSMaxHit_heldFeed
			AZSMaxHit_heldFeed = {}
			local at = runTime()
			if AZSMaxHit_feedMode then
				for i = 1, table.getn(held) do
					AZSMaxHit_PlaceFeedHit(run, held[i], at)
				end
			elseif AZSMaxHit_TakesPetHits() then
				local hits = {}
				for i = 1, table.getn(held) do
					if held[i].sourceKind == "summon" or held[i].sourceKind == "pet" then
						table.insert(hits, held[i])
					end
				end
				AZSMaxHit_PlacePetHits(run, hits, at)
			end
		end
		if not r.hasMore then
			return
		end
	end
end

-- Meter lines carry no icon, but the game's meter snapshot knows one for each
-- damage source (new necklaces and the like). Asked only while a line still has
-- no icon, at most every 3 seconds: a source's icon can still be loading at first.
local nextIconRead = 0

function AZSMaxHit_ReadSourceIcons()
	if not AZS_GetMeterContext or not AZS_GetMeterSnapshot or GetTime() < nextIconRead then
		return
	end
	local missing = false
	for name in pairs(AZSMaxHit_meterRaw or {}) do
		-- An item proc ("Item: Spell") shows the item's icon.
		local _, _, item = string.find(name, "^(.-): .+$")
		if iconFor(name) == QUESTION and (not item or iconFor(item) == QUESTION) then
			missing = true
		end
	end
	if not missing then
		return
	end
	nextIconRead = GetTime() + 3
	local ok, context = pcall(AZS_GetMeterContext)
	if not ok or type(context) ~= "table" or not context.runId then
		return
	end
	local snapshot
	ok, snapshot = pcall(AZS_GetMeterSnapshot, {
		apiVersion = 1, runId = context.runId, metric = "damage", scope = "self",
		period = "run", groupBy = "source", windowSeconds = 0,
	})
	if not ok or type(snapshot) ~= "table" or type(snapshot.sources) ~= "table" then
		return
	end
	for _, s in pairs(snapshot.sources) do
		if type(s) == "table" and s.name and not db.icons[s.name]
				and type(s.icon) == "table" and s.icon.status == "ready" then
			rememberIcon(s.name, s.icon.path)
			dirty = true
		end
	end
end

-- The meter snapshot's total per source, for procs shared out by spell (AZSMaxHit_SplitShares).
local nextSplitRead = 0

function AZSMaxHit_ReadSplitTotals()
	if not (run and run.splitRows) or not AZS_GetMeterContext or not AZS_GetMeterSnapshot or GetTime() < nextSplitRead then
		return
	end
	nextSplitRead = GetTime() + 2
	local ok, context = pcall(AZS_GetMeterContext)
	if not ok or type(context) ~= "table" or not context.runId then
		return
	end
	local snapshot
	ok, snapshot = pcall(AZS_GetMeterSnapshot, {
		apiVersion = 1, runId = context.runId, metric = "damage", scope = "self",
		period = "run", groupBy = "source", windowSeconds = 0,
	})
	if not ok or type(snapshot) ~= "table" or type(snapshot.rows) ~= "table" then
		return
	end
	local exact = {}
	local i
	for i = 1, table.getn(snapshot.rows) do
		local row = snapshot.rows[i]
		-- Only the proc's own row: a spell's casts can share the key at the same rank
		-- (Stormstrike's hits and its Windfury are both ability:stormstrike:r<rank>).
		if type(row) == "table" and row.sourceKey and row.nativeProc and tonumber(row.displayAmount) then
			exact[row.sourceKey] = (exact[row.sourceKey] or 0) + tonumber(row.displayAmount)
		end
	end
	AZSMaxHit_splitExact = exact
	dirty = true
end

-- Total damage on the game's built-in meter, or nil if it can't be read.
-- Also takes the icon of each meter line: the game knows icons for its own
-- upgrades (Corpse Explosion and the like) that are not in your spellbook.
function AZSMaxHit_GameMeterTotal()
	if not AZS_GetMeter then
		return nil
	end
	local ok, list, total = pcall(AZS_GetMeter)
	if not ok then
		return nil
	end
	local sum = 0
	if type(list) == "table" then
		local procs, procSum = {}, 0
		local own, raws, runSum = {}, {}, 0
		local i
		for i = 1, table.getn(list) do
			local line = list[i]
			if type(line) == "table" then
				sum = sum + (tonumber(line.dmg) or 0)
				local isProc = line.proc == 1 or line.proc == "1" or line.proc == true
				local raw, base, dmg = tonumber(line.dmg) or 0, nil, 0
				if line.name and line.name ~= "" then
					-- This run's share of the line: the meter can carry over
					-- the last run's numbers until it starts over.
					base = procBase[line.name]
					if base and raw < base then
						-- The game's meter started over: the baseline no longer applies.
						procBase[line.name] = nil
						base = nil
					end
					dmg = raw - (base or 0)
					if dmg < 0 then dmg = 0 end
					raws[line.name] = raw
					runSum = runSum + dmg
					if not isProc then
						local key = string.lower(line.name)
						own[key] = (own[key] or 0) + dmg
					end
				end
				if line.name and line.name ~= "" and (isProc or AZSMaxHit_MeterOnly(line.name)) then
					if dmg > 0 then
						table.insert(procs, { name = line.name, dmg = dmg, raw = raw })
						procSum = procSum + dmg
					elseif base then
						-- Keep it listed (at 0) so the next reset still knows its baseline.
						table.insert(procs, { name = line.name, dmg = 0, raw = raw })
					end
				end
				if line.name and line.icon and not db.icons[line.name] then
					rememberIcon(line.name, line.icon)
					if db.icons[line.name] then dirty = true end
				end
			end
		end
		-- Redraw when proc damage moved, even if no combat line came in.
		if procSum ~= AZSMaxHit_lastProcSum or table.getn(procs) ~= table.getn(meterProcs) then
			dirty = true
		end
		AZSMaxHit_lastProcSum = procSum
		meterProcs = procs
		if runSum ~= AZSMaxHit_meterSum then
			dirty = true
		end
		AZSMaxHit_meterOwn = own
		AZSMaxHit_meterRaw = raws
		AZSMaxHit_meterSum = runSum
		AZSMaxHit_PlaceDirect(procs)
		AZSMaxHit_ReadSourceIcons()
		AZSMaxHit_ReadSplitTotals()
	elseif not tonumber(total) then
		return nil
	end
	if tonumber(total) then
		return tonumber(total)
	end
	return sum
end

-- Redraw at most twice a second, and start a fresh run when a new one begins.
local elapsedSum = 0
local partnerTimer = 3
driver:SetScript("OnUpdate", function()
	elapsedSum = elapsedSum + (arg1 or 0)
	if elapsedSum < 0.5 then
		return
	end
	elapsedSum = 0
	if db then
		-- A new run is spotted when the run clock is behind the last one we
		-- saved (this survives a UI reload between runs), or when your level
		-- drops (every run starts low). runTime() ignores 0, so a finished run
		-- stays readable on the death screen until the next one starts.
		local t = runTime()
		local lvl = UnitLevel and UnitLevel("player")
		local newRun = false
		if t and db.run.lastTime and t + 2 < db.run.lastTime then
			newRun = true
		end
		if lvl and lvl > 0 and db.run.level and lvl < db.run.level then
			newRun = true
		end
		AZSMaxHit_ReadFeed()
		-- The game's own damage meter starts over with each run.
		local meter = AZSMaxHit_GameMeterTotal()
		if meter and db.run.meter and meter + 1 < db.run.meter then
			newRun = true
		end
		if newRun then
			resetRun(true)
		end
		if t then db.run.lastTime = t end
		if lvl and lvl > 0 then db.run.level = lvl end
		if meter then db.run.meter = meter end

		partnerTimer = partnerTimer + 1
		if partnerTimer >= 4 then -- every 2 seconds
			partnerTimer = 0
			readParty()
		end
	end
	-- Spell changes come in bursts (level-ups); scan once they settle.
	if iconsDirty and db then
		iconsDirty = false
		scanIcons()
		dirty = true
	end
	if dirty then
		refresh()
	end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

SLASH_AZSMAXHIT1 = "/maxhit"
SLASH_AZSMAXHIT2 = "/mh"
SlashCmdList["AZSMAXHIT"] = function(msg)
	msg = string.lower(msg or "")
	if not db then loadDB() end
	createUI()
	if msg == "reset" then
		resetRun()
		refresh()
	elseif string.find(msg, "^scale") then
		local _, _, value = string.find(msg, "^scale%s+(.+)$")
		if value and AZSMaxHit_SetScale(value) then
			say("window scale " .. db.scale .. ".")
		else
			say("window scale is " .. (db.scale or 1) .. ". Use /maxhit scale 0.6 to 1.5, for example /maxhit scale 0.8.")
		end
	elseif msg == "compact" then
		AZSMaxHit_SetView("compact")
		say(db.view == "compact" and "Compact on: Total, Hit, Crit and Burst only." or "Compact off.")
		refresh()
	elseif msg == "mini" then
		AZSMaxHit_SetView("mini")
		say(db.view == "mini" and "Mini on: Total only." or "Mini off.")
		refresh()
	elseif msg == "lock" then
		db.locked = not db.locked
		say(db.locked and "window locked." or "window unlocked.")
	elseif msg == "icons" then
		db.showIcons = not db.showIcons
		say(db.showIcons and "icons on." or "icons off.")
		refresh()
	elseif msg == "at" then
		db.showAt = not db.showAt
		AZSMaxHit_ApplyColumns()
		say(db.showAt and "Times on." or "Times off.")
		refresh()
	elseif msg == "meter" then
		-- What the game's own meter reports, to match names and icons.
		if not AZS_GetMeter then
			say("the game's meter can't be read (AZS_GetMeter is missing).")
			return
		end
		local ok, list = pcall(AZS_GetMeter)
		if not ok or type(list) ~= "table" then
			say("the game's meter returned nothing readable.")
			return
		end
		say("game meter lines: " .. table.getn(list))
		local i
		for i = 1, table.getn(list) do
			local line = list[i]
			if type(line) == "table" then
				local fields = {}
				local k, v
				for k, v in pairs(line) do
					table.insert(fields, tostring(k) .. "=" .. tostring(v))
				end
				table.sort(fields)
				say(i .. ". " .. table.concat(fields, ", "))
			end
		end
		local missing = {}
		local spell
		local r
		for spell, r in pairs(currentBook().spells) do
			if not r.extraOf and iconFor(spell) == QUESTION then
				table.insert(missing, spell)
			end
		end
		if table.getn(missing) > 0 then
			say("no icon yet: " .. table.concat(missing, ", "))
		end
		if AZSMaxHit_meterRaw and AZSMaxHit_meterRaw["Pets"] then
			local label = AZSMaxHit_PetsLabel()
			say("Pets row: " .. label .. ", icon " .. tostring(iconFor(label)))
		end
	elseif msg == "party" then
		dumpParty()
	elseif msg == "top" then
		AZSMaxHit_DumpTop(currentBook(), say)
	elseif msg == "feed" then
		AZSMaxHit_DumpFeed(say)
	elseif msg == "help" then
		say("/maxhit - show or hide the window")
		say("/maxhit reset - clear the numbers (they also clear by themselves at every new run)")
		say("/maxhit lock - lock the window;  /maxhit icons - icons on/off;  /maxhit at - times of top hits on/off")
		say("/maxhit scale 0.8 - make the whole window smaller or bigger (0.6 to 1.5)")
		say("/maxhit compact - only Total, Hit, Crit and Burst, in a narrower window;  /maxhit mini - only Total (also the C and M buttons)")
		say("/maxhit meter - list what the game's meter reports, and abilities still missing an icon")
		say("/maxhit party - list what the game's party meter reports (co-op)")
		say("/maxhit top - the game's exact message for each ability's biggest hits")
		say("/maxhit feed - list which meter line the game credits each ability's hits to")
		say("Hit / Crit: biggest normal hit and biggest crit (the larger is highlighted).")
		say("At (if on): run time of the top hit.  Burst: most damage the ability did in any 1 second.")
		say("Total: the ability's own damage from the game's meter (no procs, no overkill). Indented rows are its procs.")
		say("Damage-over-time spells show only their ticks. Other hits the game logs under their name (Shadow Weaving strikes, Pendant of the Plague's explosion) go to that proc's row, matched by the game's meter; what can't be matched shows as Other hits.")
		say("Overkill: damage past what enemies had left (combat log minus the game's meter).")
		say("Click a column to sort by it. Mouse wheel scrolls.")
		say("Co-op: a Party tab compares everyone, using the game's own party meter.")
		say("No game settings needed on game 0.139 and later. Before that: Options > Combat > Show Target Damage, Periodic Damage and Pet Damage.")
	else
		if frame:IsShown() then
			frame:Hide()
			db.shown = false
		else
			frame:Show()
			db.shown = true
			refresh()
		end
	end
end
