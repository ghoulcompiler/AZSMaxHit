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
local WIDTH = 550
local ME = "@me"          -- key for your own data, whatever your hero is called
local SOLID = "Interface\\Buttons\\WHITE8X8"
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
	["Water Elemental"] = ICON_DIR .. "Spell_Frost_SummonWaterElemental",
	["Wolf"] = ICON_DIR .. "Ability_Hunter_Pet_Wolf",
	["Spirit Wolf"] = ICON_DIR .. "Spell_Nature_SpiritWolf",
	["Raptor"] = ICON_DIR .. "Ability_Hunter_Pet_Raptor",
	["Treant"] = ICON_DIR .. "Ability_Druid_ForceofNature",
	-- Survivors upgrades that are not in the spellbook or talent tree.
	["Corpse Explosion"] = ICON_DIR .. "Spell_Shadow_CorpseExplode",
}

local function asTexture(tex)
	if not tex or tex == "" then
		return nil
	end
	if string.find(string.lower(tex), "questionmark", 1, true) then
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
			local tex = (db and (db.icons[n] or db.iconsLC[string.lower(n)])) or FALLBACK_ICONS[n]
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

-- Returns true when this hit is a new top hit for the spell in that book.
local function record(book, spell, amount, crit, target, at)
	local r = book.spells[spell]
	if not r then
		r = { max = 0 }
		book.spells[spell] = r
	end
	if crit then
		if amount > (r.maxCrit or 0) then r.maxCrit = amount end
		r.crits = (r.crits or 0) + 1
	else
		if amount > (r.maxHit or 0) then r.maxHit = amount end
	end
	r.hits = (r.hits or 0) + 1
	r.total = (r.total or 0) + amount
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

	local at = runTime()
	local t = now()
	local book = run
	record(book, spell, amount, crit, target, at)

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
	if (r.hits or 0) > 0 then return (r.total or 0) / r.hits end
	return 0
end
local function critPctOf(r)
	if (r.hits or 0) > 0 then return (r.crits or 0) * 100 / r.hits end
	return 0
end

local COLS = {
	{ key = "hit",   label = "Hit",   right = 200, width = 54, value = function(r) return r.maxHit or 0 end },
	{ key = "crit",  label = "Crit",  right = 256, width = 54, value = function(r) return r.maxCrit or 0 end },
	{ key = "at",    label = "At",    right = 298, width = 40, value = function(r) return r.at or 999999 end, asc = true,
		text = function(r) return fmtTime(r.at) end },
	{ key = "burst", label = "Burst", right = 358, width = 58, value = function(r) return r.burst or 0 end },
	{ key = "total", label = "Total", right = 428, width = 66, value = function(r) return r.total or 0 end },
	{ key = "avg",   label = "Avg",   right = 474, width = 44, value = avgOf },
	{ key = "hits",  label = "Hits",  right = 512, width = 36, value = function(r) return r.hits or 0 end },
	{ key = "critp", label = "Crit%", right = 544, width = 30, value = critPctOf,
		text = function(r)
			if (r.hits or 0) == 0 then return "-" end
			return string.format("%d%%", math.floor(critPctOf(r) + 0.5))
		end },
}
local BEST = { key = "best", value = function(r) return r.max or 0 end }

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

local function sorted()
	local book = currentBook()
	local col = columnByKey(sortKey)
	local list = {}
	local spell, r
	for spell, r in pairs(book.spells) do
		table.insert(list, { name = spell, r = r, v = col.value(r), m = r.max or 0 })
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
	{ label = "Top spell", left = 150, width = 150, justify = "LEFT" },
	{ label = "Top DPS",   right = 350, width = 56 },
	{ label = "DPS",       right = 420, width = 60 },
	{ label = "Total",     right = 492, width = 66 },
	{ label = "Share",     right = 544, width = 46 },
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
		if partyMode then row.cells[i]:Hide() else row.cells[i]:Show() end
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

	local total, dps, best = 0, 0, nil
	local i
	for i = 1, n do
		local h = party[i]
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
	setTile(tiles[3], "PARTY TOTAL", total > 0 and fmt(total) or "|cff777777-|r")
	setTile(tiles[4], nil, nil)

	for i = 1, ROWS do
		local row = rows[i]
		local h = i <= visibleRows and party[i + offset]
		if h then
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
			row.pcells[4]:SetText(fmt(h.dmg))
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
	local list = sorted()
	layout(showTabs)
	local n = table.getn(list)
	if offset > n - visibleRows then offset = n - visibleRows end
	if offset < 0 then offset = 0 end

	-- Summary strip: the numbers that matter most.
	local topName, top, grand = nil, nil, 0
	local spell, r
	for spell, r in pairs(book.spells) do
		grand = grand + (r.total or 0)
		if not top or (r.max or 0) > (top.max or 0) then
			topName, top = spell, r
		end
	end
	if top then
		local label = "TOP HIT"
		if top.crit then label = label .. "  |cffffd100CRIT|r" end
		if top.at then label = label .. "  |cff777777at " .. fmtTime(top.at) .. "|r" end
		setTile(tiles[1], label, (top.crit and "|cffffd100" or "|cffffffff") .. fmt(top.max)
			.. "|r  |cffbbbbbb" .. topName .. "|r")
	else
		setTile(tiles[1], "TOP HIT", "|cff777777-|r")
	end
	local burst = book.burst.amount
	setTile(tiles[2], "BURST" .. (book.burst.at and ("  |cff777777at " .. fmtTime(book.burst.at) .. "|r") or ""),
		burst and fmt(burst) or "|cff777777-|r")
	setTile(tiles[3], "TOTAL", grand > 0 and fmt(grand) or "|cff777777-|r")
	setTile(tiles[4], nil, nil)

	-- Rows
	local i, c
	for i = 1, ROWS do
		local row = rows[i]
		local item = i <= visibleRows and list[i + offset]
		if item then
			r = item.r
			row.name:SetText(item.name)
			if db.showIcons then
				row.icon:SetTexture(iconFor(item.name))
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
			end
			AZSMaxHit_ShowCells(row, false)
			-- The bigger of Hit and Crit is the spell's top hit: highlight it.
			local hitCell, critCell = row.cells[1], row.cells[2]
			if r.crit then
				hitCell:SetTextColor(0.75, 0.75, 0.75)
				critCell:SetTextColor(1, 0.82, 0)
			else
				hitCell:SetTextColor(1, 1, 1)
				critCell:SetTextColor(0.75, 0.6, 0.2)
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
	b:SetScript("OnLeave", function() fs:SetTextColor(0.6, 0.6, 0.6) end)
	return b
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
	table.insert(headerCells, { key = key, fs = fs })
	return b
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
	titleBtn:SetWidth(WIDTH - 60)
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

	-- Summary strip
	tiles = {
		makeTile(PAD + 2, 230),
		makeTile(256, 120),
		makeTile(384, 80),
		makeTile(468, 78),
	}

	local divider = frame:CreateTexture(nil, "ARTWORK")
	divider:SetTexture(SOLID)
	divider:SetVertexColor(1, 1, 1, 0.08)
	divider:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, CONTENT_Y + 6)
	divider:SetWidth(WIDTH - 2 * PAD)
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

	-- Column headers: click one to sort by it. "Spell" sorts by top hit.
	header = CreateFrame("Frame", nil, frame)
	header:SetWidth(WIDTH)
	header:SetHeight(ROW_H)
	headerButton(header, "best", "Spell", 22, 120, "LEFT")
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
			if c > 2 then
				fs:SetTextColor(0.75, 0.75, 0.75)
			end
			row.cells[c] = fs
		end
		AZSMaxHit_PartyCells(row)
		rows[i] = row
	end

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

-- Co-op heroes, straight from the game's party meter. Empty when playing solo.
local function readParty()
	local list = {}
	if AZS_GetPartyMeter then
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
	if kind then
		ingest(arg1, kind, event)
	end
end)

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
		local i
		for i = 1, table.getn(list) do
			local line = list[i]
			if type(line) == "table" then
				sum = sum + (tonumber(line.dmg) or 0)
				if line.name and line.icon and not db.icons[line.name] then
					rememberIcon(line.name, line.icon)
					if db.icons[line.name] then dirty = true end
				end
			end
		end
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
	elseif msg == "lock" then
		db.locked = not db.locked
		say(db.locked and "window locked." or "window unlocked.")
	elseif msg == "icons" then
		db.showIcons = not db.showIcons
		say(db.showIcons and "icons on." or "icons off.")
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
		for spell in pairs(currentBook().spells) do
			if iconFor(spell) == QUESTION then
				table.insert(missing, spell)
			end
		end
		if table.getn(missing) > 0 then
			say("no icon yet: " .. table.concat(missing, ", "))
		end
	elseif msg == "party" then
		dumpParty()
	elseif msg == "help" then
		say("/maxhit - show or hide the window")
		say("/maxhit reset - clear the numbers (they also clear by themselves at every new run)")
		say("/maxhit lock - lock the window;  /maxhit icons - icons on/off")
		say("/maxhit meter - list what the game's meter reports, and spells still missing an icon")
		say("/maxhit party - list what the game's party meter reports (co-op)")
		say("Hit / Crit: biggest normal hit and biggest crit (the larger is highlighted).")
		say("At: run time of the top hit.  Burst: most damage the spell did in any 1 second.")
		say("Total: all damage the spell did (from the combat log; may differ a little from the game's meter).")
		say("Click a column to sort by it. Mouse wheel scrolls.")
		say("Co-op: a Party tab compares everyone, using the game's own party meter.")
		say("Needs Options > Combat > Show Target Damage. Turn on Periodic Damage for DoTs and Pet Damage for pets.")
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
