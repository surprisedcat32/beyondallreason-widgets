function widget:GetInfo()
	return {
		name    = "Army Overview",
		desc    = "Tech split, army/builder/eco value, buildpower, idle builders. /armyinfo detailed adds full metal & energy flow breakdowns, army stats and a kill/loss tally. /armyinfo help",
		author  = "Surprised_cat + Claude",
		date    = "2026",
		license = "MIT",
		layer   = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Install: put this file in  <BAR install>/data/LuaUI/Widgets/gui_army_overview.lua
-- then press F11 in game (or /luaui reload) and enable "Army Overview".
--
-- Controls
--   Left-drag the main panel ... move it (docked detail panels follow)
--   Left-drag a detail panel ... pull it out and place it anywhere (it stays put)
--   Right-click a detail panel . dock it back next to the main panel
--   Right-click the main panel . dock every detail panel back
--   Ctrl + mouse wheel ......... scale (docked panels auto-shrink to fit your screen)
--   /armyinfo .................. show / hide
--   /armyinfo detailed [on|off]  toggle the detailed panels
--   /armyinfo metal|energy|army  toggle an individual detailed panel
--   /armyinfo eco|value|tech|bp  toggle a section of the main panel
--   /armyinfo techmode ......... tech split by army units only <-> everything
--   /armyinfo scale <0.5-3> .... set scale
--   /armyinfo dock ............. dock all detail panels back
--   /armyinfo resettally ....... zero the kill/loss tally
--   /armyinfo reset ............ reset position, scale and toggles
--
-- Memory notes
--   * No GL resources (display lists, fonts, textures, shaders) are created.
--   * Stat tables, row tables, per-unit-def tallies and the history ring are
--     allocated once and reused, so steady-state garbage is just a few short
--     strings per refresh plus the unit list the engine returns.
--   * Every table that is keyed by something dynamic (unit defs, teams) is
--     bounded by the number of unit defs / teams in the game.
--------------------------------------------------------------------------------

-- Localised engine calls ------------------------------------------------------
local spGetMyTeamID         = Spring.GetMyTeamID
local spGetSpectatingState  = Spring.GetSpectatingState
local spGetTeamUnits        = Spring.GetTeamUnits
local spGetUnitDefID        = Spring.GetUnitDefID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitIsBuilding   = Spring.GetUnitIsBuilding
local spGetUnitWorkerTask   = Spring.GetUnitWorkerTask       -- may be nil on older engines
local spGetUnitCommandCount = Spring.GetUnitCommandCount     -- may be nil on older engines
local spGetUnitCommands     = Spring.GetUnitCommands
local spGetFactoryCommands  = Spring.GetFactoryCommands
local spGetUnitResources    = Spring.GetUnitResources
local spGetUnitHealth       = Spring.GetUnitHealth
local spGetTeamResources    = Spring.GetTeamResources
local spGetGameSeconds      = Spring.GetGameSeconds
local spAreTeamsAllied      = Spring.AreTeamsAllied
local spGetViewGeometry     = Spring.GetViewGeometry
local spGetMouseState       = Spring.GetMouseState
local spGetModKeyState      = Spring.GetModKeyState
local spIsGUIHidden         = Spring.IsGUIHidden
local spEcho                = Spring.Echo

local glColor = gl.Color
local glRect  = gl.Rect
local glText  = gl.Text

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local format  = string.format
local tsort   = table.sort

-- Settings --------------------------------------------------------------------
local FONT   = 12            -- base font size
local LINE_H = 16            -- base row height
local PAD    = 8
local GAP    = 6             -- gap between panels
local MAXTECH = 6

local cfg = {
	x        = nil,          -- left edge of the panel group
	top      = nil,          -- top edge (panels grow downward)
	scale    = 1.0,
	visible  = true,
	detailed = false,
	techMode = "army",       -- "army" = combat units only, "all" = everything except commanders
	interval = 0.5,          -- seconds between stat refreshes
	sections  = { eco = true, value = true, tech = true, bp = true },
	dsections = { metal = true, energy = true, army = true },
}

local vsx, vsy = spGetViewGeometry()

-- Colours ---------------------------------------------------------------------
local C = {
	text   = { 0.92, 0.92, 0.92, 1 },
	dim    = { 0.62, 0.65, 0.70, 1 },
	head   = { 0.45, 0.80, 1.00, 1 },
	good   = { 0.40, 1.00, 0.50, 1 },
	bad    = { 1.00, 0.40, 0.40, 1 },
	warn   = { 1.00, 0.80, 0.30, 1 },
	metal  = { 0.80, 0.88, 1.00, 1 },
	energy = { 1.00, 0.95, 0.35, 1 },
	bg     = { 0.00, 0.00, 0.00, 0.62 },
	bar_bg = { 1.00, 1.00, 1.00, 0.10 },
}
local TECH_COLORS = {
	{ 0.45, 0.90, 0.45, 1 },   -- T1
	{ 0.40, 0.65, 1.00, 1 },   -- T2
	{ 0.85, 0.50, 1.00, 1 },   -- T3
	{ 1.00, 0.50, 0.30, 1 },   -- T4+
}

-- Categories / groups -----------------------------------------------------------
local CATS    = { "army", "con", "factory", "nano", "eco", "defense", "utility" }
local CATNAME = { army = "Army units", con = "Constructors", factory = "Factories", nano = "Nano/static",
                  eco = "Economy", defense = "Defense", utility = "Utility" }

-- "resource groups": who makes / uses metal and energy
local RGROUPS = { "comm", "mex", "conv", "gen", "store", "con", "factory", "nano", "army", "defense", "utility" }
local RGNAME  = { comm = "Commander", mex = "Extractors", conv = "Converters", gen = "Generators",
                  store = "Storage", con = "Constructors", factory = "Factories", nano = "Nano/static",
                  army = "Army units", defense = "Defense", utility = "Utility" }

local DOMAINS = { "land", "air", "naval", "hover" }
local DOMNAME = { land = "Land", air = "Air", naval = "Naval", hover = "Hover" }

--------------------------------------------------------------------------------
-- Unit definition classification (done once at load)
--------------------------------------------------------------------------------

local function positive(v) return v ~= nil and v > 0 end

local function isEcoDef(ud, cp)
	return positive(ud.extractsMetal)
		or positive(ud.metalMake)
		or positive(ud.makesMetal)
		or positive(ud.energyMake)
		or (ud.energyUpkeep ~= nil and ud.energyUpkeep < 0)   -- BAR solars/fusions use negative upkeep
		or positive(ud.windGenerator)
		or positive(ud.tidalGenerator)
		or positive(ud.metalStorage)
		or positive(ud.energyStorage)
		or positive(tonumber(cp.energyconv_capacity))
end

local function resGroup(ud, cp, cat, isCom)
	if isCom then return "comm" end
	if cat == "con" or cat == "factory" or cat == "nano" or cat == "army" or cat == "defense" then
		return cat
	end
	if cat == "eco" then
		if positive(ud.extractsMetal) then return "mex" end
		if positive(tonumber(cp.energyconv_capacity)) or positive(ud.makesMetal) then return "conv" end
		if positive(ud.energyMake) or (ud.energyUpkeep ~= nil and ud.energyUpkeep < 0)
			or positive(ud.windGenerator) or positive(ud.tidalGenerator) then
			return "gen"
		end
		if positive(ud.metalStorage) or positive(ud.energyStorage) then return "store" end
		return "gen"
	end
	return "utility"
end

local function domainOf(ud)
	if ud.canFly then return "air" end
	if ud.isHoverUnit then return "hover" end
	local md = ud.moveDef
	local n = type(md) == "table" and md.name
	if type(n) == "string" then
		n = n:lower()
		if n:find("boat") or n:find("ship") then return "naval" end
		if n:find("hover") then return "hover" end
	end
	return "land"
end

-- Rough damage-per-second estimate from the weapon defs. Beam weapons, special
-- damage types and unusual reload setups can be off, so the UI labels it "est".
local function unitDps(ud)
	local total = 0
	local defaultArmor = (Game and Game.armorTypes and Game.armorTypes.default) or 0
	local weapons = ud.weapons
	if not weapons then return 0 end
	for i = 1, #weapons do
		local wd = WeaponDefs[weapons[i].weaponDef]
		if wd and not wd.paralyzer and wd.type ~= "Shield"
			and not (wd.interceptor and wd.interceptor ~= 0)
			and not wd.manualFire
			and not (wd.customParams and wd.customParams.bogus) then
			local dmg = wd.damages and wd.damages[defaultArmor] or 0
			local reload = max(wd.reload or 1, 1 / 30)
			total = total + dmg * (wd.salvoSize or 1) * (wd.projectiles or 1) / reload
		end
	end
	return total
end

-- cat: army | con | factory | nano | eco | defense | utility
local defInfo = {}
for defID, ud in pairs(UnitDefs) do
	local cp      = ud.customParams or {}
	local mobile  = (ud.speed or 0) > 0
	local weapons = ud.weapons and #ud.weapons > 0
	local bp      = ud.buildSpeed or 0
	local isCom   = cp.iscommander ~= nil

	local cat
	if isCom or (ud.isBuilder and bp > 0) then
		if ud.isFactory then
			cat = "factory"
		elseif mobile then
			cat = "con"
		else
			cat = "nano"
		end
	elseif mobile then
		cat = weapons and "army" or "utility"
	else
		if isEcoDef(ud, cp) then
			cat = "eco"
		elseif weapons then
			cat = "defense"
		else
			cat = "utility"
		end
	end

	local okD, domain = pcall(domainOf, ud)
	local okP, dps = pcall(unitDps, ud)
	local tech = tonumber(cp.techlevel) or 1                 -- units without a techlevel count as T1
	tech = max(1, min(MAXTECH, floor(tech)))

	defInfo[defID] = {
		cat    = cat,
		rgroup = resGroup(ud, cp, cat, isCom),
		cost   = ud.metalCost or 0,
		bp     = bp,
		isCom  = isCom,
		tech   = tech,
		domain = okD and domain or "land",
		dps    = (okP and dps) or 0,
		name   = ud.translatedHumanName or ud.humanName or ud.name or "?",
	}
end

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

local function fmt(n)
	local a = abs(n)
	if a >= 1e6 then return format("%.2fM", n / 1e6)
	elseif a >= 1e4 then return format("%.1fk", n / 1e3)
	elseif a >= 1e3 then return format("%.2fk", n / 1e3)
	end
	return format("%d", floor(n + 0.5))
end

local function fmtRate(n)
	if abs(n) >= 1000 then return format("%.2fk", n / 1000) end
	return format("%.1f", n)
end

local function fmtNet(n)
	if abs(n) >= 1000 then return format("%+.2fk", n / 1000) end
	return format("%+.1f", n)
end

local function pct(part, total)
	if not total or total <= 0 then return 0 end
	return part / total * 100
end

local function fmtPct(p)
	return format("%d%%", floor(p + 0.5))
end

local function fmtTime(sec)
	if sec >= 3600 then return ">1h" end
	return format("%d:%02d", floor(sec / 60), floor(sec % 60))
end

local function tierStr(arr, maxT)
	local s = ""
	for t = 1, maxT do
		if arr[t] > 0 then s = s .. (s ~= "" and " " or "") .. "T" .. t .. ":" .. arr[t] end
	end
	return s ~= "" and s or "-"
end

local function shortName(name, n)
	if #name <= n then return name end
	return name:sub(1, n)
end

local function queueCount(uid, isFactory)
	local n
	if isFactory and spGetFactoryCommands then
		n = spGetFactoryCommands(uid, 0)
	elseif spGetUnitCommandCount then
		n = spGetUnitCommandCount(uid)
	elseif spGetUnitCommands then
		n = spGetUnitCommands(uid, 0)
	end
	if type(n) ~= "number" then return 0 end
	return n
end

local function isWorking(uid)
	if spGetUnitIsBuilding and spGetUnitIsBuilding(uid) ~= nil then
		return true
	end
	if spGetUnitWorkerTask and spGetUnitWorkerTask(uid) ~= nil then
		return true   -- also catches reclaim / repair / resurrect
	end
	return false
end

--------------------------------------------------------------------------------
-- Persistent, reused state (nothing below is re-created on refresh)
--------------------------------------------------------------------------------

local function zeroArray(t, n) for i = 1, n do t[i] = 0 end end
local function zeroMap(t) for k in pairs(t) do t[k] = 0 end end

local function catTable()
	local t = {}
	for i = 1, #CATS do t[CATS[i]] = 0 end
	return t
end
local function domTable()
	local t = {}
	for i = 1, #DOMAINS do t[DOMAINS[i]] = 0 end
	return t
end
local function tierArray()
	local t = {}
	for i = 1, MAXTECH do t[i] = 0 end
	return t
end
local function resTable()
	return { cur = 0, stor = 1, pull = 0, inc = 0, exp = 0, share = 0, sent = 0, recv = 0, excess = 0 }
end

local st = {
	teamID = 0, spec = false,
	val = catTable(), cnt = catTable(),
	total = 0, unitCount = 0,
	wip = 0, wipCount = 0, wipRemain = 0,
	tech = tierArray(), techTotal = 0, maxTech = 3,
	bp = { con = 0, factory = 0, nano = 0, total = 0, active = 0 },
	idleCons = 0, totalCons = 0, idleFacs = 0, totalFacs = 0,
	metal = resTable(), energy = resTable(),
	-- detailed-only
	armyTech = tierArray(), armyTechCnt = tierArray(),
	domVal = domTable(), domCnt = domTable(),
	conCnt = tierArray(), conBP = tierArray(), facCnt = tierArray(), facBP = tierArray(),
	mexCnt = tierArray(),
	comCnt = 0, comBP = 0, queueTotal = 0,
	armyHP = 0, armyMaxHP = 0, armyDPS = 0,
	maxTechA = 3,
	builderSpend = 0,
	hasRate = false, armyRate = 0, totalRate = 0, rateWindow = 0,
}

-- per resource-group accumulators
local gr = {}
for i = 1, #RGROUPS do
	gr[RGROUPS[i]] = { cnt = 0, mMake = 0, mUse = 0, eMake = 0, eUse = 0 }
end

-- per unit-def accumulators (bounded by #UnitDefs); `touched` lists the active ones
local perDef = {}
local touched, nTouched = {}, 0

-- top-N lists (store defIDs, preallocated)
local TOP_M, TOP_E = 5, 6
local topM, topE = {}, {}
local nTopM, nTopE = 0, 0

local function resetDetailed()
	for i = nTouched, 1, -1 do
		local pd = perDef[touched[i]]
		pd.count, pd.mMake, pd.mUse, pd.eMake, pd.eUse = 0, 0, 0, 0, 0
		touched[i] = nil
	end
	nTouched = 0
	for i = 1, #RGROUPS do
		local g = gr[RGROUPS[i]]
		g.cnt, g.mMake, g.mUse, g.eMake, g.eUse = 0, 0, 0, 0, 0
	end
	zeroArray(st.armyTech, MAXTECH); zeroArray(st.armyTechCnt, MAXTECH)
	zeroArray(st.conCnt, MAXTECH);   zeroArray(st.conBP, MAXTECH)
	zeroArray(st.facCnt, MAXTECH);   zeroArray(st.facBP, MAXTECH)
	zeroArray(st.mexCnt, MAXTECH)
	zeroMap(st.domVal); zeroMap(st.domCnt)
	st.comCnt, st.comBP, st.queueTotal = 0, 0, 0
	st.armyHP, st.armyMaxHP, st.armyDPS = 0, 0, 0
	st.maxTechA = 3
	st.builderSpend = 0
end

local function resetStats()
	zeroMap(st.val); zeroMap(st.cnt)
	st.total, st.unitCount = 0, 0
	st.wip, st.wipCount, st.wipRemain = 0, 0, 0
	zeroArray(st.tech, MAXTECH)
	st.techTotal, st.maxTech = 0, 3
	zeroMap(st.bp)
	st.idleCons, st.totalCons, st.idleFacs, st.totalFacs = 0, 0, 0, 0
end

-- comparators (module-level so sorting allocates no closures)
local function cmpMMake(a, b)
	local pa, pb = perDef[a], perDef[b]
	if pa.mMake ~= pb.mMake then return pa.mMake > pb.mMake end
	return a < b
end
local function cmpEMake(a, b)
	local pa, pb = perDef[a], perDef[b]
	if pa.eMake ~= pb.eMake then return pa.eMake > pb.eMake end
	return a < b
end

local function extractTop(cmp, key, out, limit)
	local n = 0
	if nTouched > 0 then
		tsort(touched, cmp)
		for i = 1, min(limit, nTouched) do
			local id = touched[i]
			if perDef[id][key] > 0.05 then
				n = n + 1
				out[n] = id
			end
		end
	end
	return n
end

-- value history ring buffer (fixed size, numbers only) ---------------------------
local HIST = 121                       -- ~60 s at 0.5 s interval
local histT, histArmy, histTotal = {}, {}, {}
for i = 1, HIST do histT[i], histArmy[i], histTotal[i] = 0, 0, 0 end
local histHead, histCount = 0, 0

local function resetHistory()
	histHead, histCount = 0, 0
end

local function pushHistory(t, army, total)
	histHead = histHead % HIST + 1
	histT[histHead], histArmy[histHead], histTotal[histHead] = t, army, total
	if histCount < HIST then histCount = histCount + 1 end
end

-- kill / loss tally, keyed by team (bounded by team count) -----------------------
local lossValue, lossCount, killValue, killCount = {}, {}, {}, {}

local function resetTally()
	for k in pairs(lossValue) do lossValue[k] = nil end
	for k in pairs(lossCount) do lossCount[k] = nil end
	for k in pairs(killValue) do killValue[k] = nil end
	for k in pairs(killCount) do killCount[k] = nil end
end

--------------------------------------------------------------------------------
-- Stat collection
--------------------------------------------------------------------------------

local function readResources(teamID, name, out)
	local cur, stor, pull, inc, exp, share, sent, recv, excess = spGetTeamResources(teamID, name)
	out.cur, out.stor = cur or 0, stor or 1
	out.pull, out.inc, out.exp = pull or 0, inc or 0, exp or 0
	out.share, out.sent, out.recv, out.excess = share or 0, sent or 0, recv or 0, excess or 0
end

local function computeStats(detailed)
	resetStats()
	if detailed then resetDetailed() end

	local teamID = spGetMyTeamID()
	st.teamID = teamID
	st.spec = spGetSpectatingState()

	local armyOnly = (cfg.techMode == "army")
	local units = spGetTeamUnits(teamID)
	local nUnits = units and #units or 0

	for i = 1, nUnits do
		local uid = units[i]
		local defID = spGetUnitDefID(uid)
		local info = defID and defInfo[defID]
		if info then
			local beingBuilt, progress = spGetUnitIsBeingBuilt(uid)
			if beingBuilt then
				st.wip = st.wip + info.cost * (progress or 0)
				st.wipRemain = st.wipRemain + info.cost * (1 - (progress or 0))
				st.wipCount = st.wipCount + 1
			else
				local cat, cost, tech = info.cat, info.cost, info.tech
				st.val[cat] = st.val[cat] + cost
				st.cnt[cat] = st.cnt[cat] + 1
				st.total = st.total + cost
				st.unitCount = st.unitCount + 1

				-- tech split (main panel)
				if not info.isCom and ((not armyOnly) or cat == "army") then
					st.tech[tech] = st.tech[tech] + cost
					st.techTotal = st.techTotal + cost
					if tech > st.maxTech then st.maxTech = tech end
				end

				-- buildpower
				local isBuilder = (cat == "con" or cat == "factory" or cat == "nano")
				local working = false
				if isBuilder then
					st.bp[cat] = st.bp[cat] + info.bp
					st.bp.total = st.bp.total + info.bp
					working = isWorking(uid)
					if working then st.bp.active = st.bp.active + info.bp end

					if cat == "con" and not info.isCom then
						st.totalCons = st.totalCons + 1
						if not working and queueCount(uid, false) == 0 then
							st.idleCons = st.idleCons + 1
						end
					elseif cat == "factory" then
						st.totalFacs = st.totalFacs + 1
						local q = (detailed or not working) and queueCount(uid, true) or 0
						if detailed then st.queueTotal = st.queueTotal + q end
						if not working and q == 0 then
							st.idleFacs = st.idleFacs + 1
						end
					end
				end

				-- everything below is detailed-mode only
				if detailed then
					local g = gr[info.rgroup]
					g.cnt = g.cnt + 1
					local mMake, mUse, eMake, eUse = spGetUnitResources(uid)
					if mMake then
						g.mMake = g.mMake + mMake
						g.mUse  = g.mUse  + mUse
						g.eMake = g.eMake + eMake
						g.eUse  = g.eUse  + eUse

						local pd = perDef[defID]
						if not pd then
							pd = { count = 0, mMake = 0, mUse = 0, eMake = 0, eUse = 0 }
							perDef[defID] = pd
						end
						if pd.count == 0 then
							nTouched = nTouched + 1
							touched[nTouched] = defID
						end
						pd.count = pd.count + 1
						pd.mMake = pd.mMake + mMake
						pd.mUse  = pd.mUse  + mUse
						pd.eMake = pd.eMake + eMake
						pd.eUse  = pd.eUse  + eUse
					end

					if not info.isCom and tech > st.maxTechA then st.maxTechA = tech end

					if cat == "army" then
						local dom = info.domain
						st.domVal[dom] = st.domVal[dom] + cost
						st.domCnt[dom] = st.domCnt[dom] + 1
						st.armyTech[tech] = st.armyTech[tech] + cost
						st.armyTechCnt[tech] = st.armyTechCnt[tech] + 1
						st.armyDPS = st.armyDPS + info.dps
						local hp, maxHp = spGetUnitHealth(uid)
						if hp then
							st.armyHP = st.armyHP + hp
							st.armyMaxHP = st.armyMaxHP + (maxHp or hp)
						end
					elseif isBuilder then
						if info.isCom then
							st.comCnt = st.comCnt + 1
							st.comBP = st.comBP + info.bp
						elseif cat == "con" then
							st.conCnt[tech] = st.conCnt[tech] + 1
							st.conBP[tech] = st.conBP[tech] + info.bp
						elseif cat == "factory" then
							st.facCnt[tech] = st.facCnt[tech] + 1
							st.facBP[tech] = st.facBP[tech] + info.bp
						end
					elseif info.rgroup == "mex" then
						st.mexCnt[tech] = st.mexCnt[tech] + 1
					end
				end
			end
		end
	end

	readResources(teamID, "metal", st.metal)
	readResources(teamID, "energy", st.energy)

	if detailed then
		nTopM = extractTop(cmpMMake, "mMake", topM, TOP_M)
		nTopE = extractTop(cmpEMake, "eMake", topE, TOP_E)
		st.builderSpend = gr.comm.mUse + gr.con.mUse + gr.factory.mUse + gr.nano.mUse
	end

	-- value history + rate of change
	local now = spGetGameSeconds()
	pushHistory(now, st.val.army, st.total)
	local oldest = ((histHead - histCount) % HIST) + 1
	local dt = now - histT[oldest]
	if dt >= 5 then
		st.hasRate = true
		st.armyRate = (st.val.army - histArmy[oldest]) / dt * 60
		st.totalRate = (st.total - histTotal[oldest]) / dt * 60
		st.rateWindow = dt
	else
		st.hasRate = false
	end
end

--------------------------------------------------------------------------------
-- Row lists (pooled: row tables are created once and overwritten)
--------------------------------------------------------------------------------

local ROWH = { title = 1.7, head = 1.5, kv = 1.0, bar = 1.2, gap = 0.3 }

local function newList() return { n = 0, pool = {}, baseH = 0 } end

local function pushRow(list)
	local n = list.n + 1
	list.n = n
	local r = list.pool[n]
	if not r then
		r = {}
		list.pool[n] = r
	end
	return r
end

local function setRow(r, t, text, label, v1, v2, c0, c1, c2, indent, frac, color)
	r.t, r.text, r.label, r.v1, r.v2 = t, text, label, v1, v2
	r.c0, r.c1, r.c2, r.indent, r.frac, r.color = c0, c1, c2, indent, frac, color
end

local function addTitle(l, text) setRow(pushRow(l), "title", text) end
local function addHead(l, text)  setRow(pushRow(l), "head", text) end
local function addGap(l)         setRow(pushRow(l), "gap") end
local function addKV(l, label, v1, v2, c0, c1, c2, indent)
	setRow(pushRow(l), "kv", nil, label, v1, v2, c0, c1, c2, indent)
end
local function addBar(l, label, frac, color, v1, v2)
	setRow(pushRow(l), "bar", nil, label, v1, v2, nil, nil, nil, nil, frac, color)
end

local function finishList(l)
	local h = PAD * 2
	local pool = l.pool
	for i = 1, l.n do h = h + (ROWH[pool[i].t] or 1) * LINE_H end
	l.baseH = h
end

-- Panels ------------------------------------------------------------------------
-- detached = the panel has its own position (px, ptop) instead of docking next to main
local panels = {}
do
	local defs = { { "main", 270, true }, { "metal", 270, false }, { "energy", 270, false }, { "army", 280, false } }
	for i = 1, #defs do
		panels[i] = {
			id = defs[i][1], w = defs[i][2], active = defs[i][3],
			list = newList(), rect = { x1 = 0, y1 = 0, x2 = 0, y2 = 0 },
			detached = false, px = 0, ptop = 0,      -- saved position when detached
			drawX = 0, drawTop = 0,                  -- position used this frame
		}
	end
end

-- draw order (last = on top); reordered in place when a panel is clicked
local drawOrder = {}
for i = 1, #panels do drawOrder[i] = panels[i] end

local function dockAll()
	for i = 1, #panels do panels[i].detached = false end
end

--------------------------------------------------------------------------------
-- Main panel rows (same content as before)
--------------------------------------------------------------------------------

local function buildMain(l)
	addTitle(l, "Army Overview" .. (st.spec and "  (spectating)" or ""))

	if cfg.sections.eco then
		addHead(l, "Economy")
		local m, e = st.metal, st.energy
		local mNet, eNet = m.inc - m.exp, e.inc - e.exp
		addKV(l, "Metal", fmtRate(m.inc) .. "/" .. fmtRate(m.exp), fmtNet(mNet), C.metal, nil,
			mNet >= 0 and C.good or C.bad)
		local mFill = pct(m.cur, m.stor)
		addKV(l, "stored", fmt(m.cur), fmtPct(mFill), nil, C.dim, (mFill < 5) and C.bad or C.dim, 1)
		addKV(l, "Energy", fmtRate(e.inc) .. "/" .. fmtRate(e.exp), fmtNet(eNet), C.energy, nil,
			eNet >= 0 and C.good or C.bad)
		local eFill = pct(e.cur, e.stor)
		addKV(l, "stored", fmt(e.cur), fmtPct(eFill), nil, C.dim, (eFill < 5) and C.bad or C.dim, 1)
	end

	if cfg.sections.value then
		addGap(l)
		addHead(l, "Value (metal cost)")
		local v, tot = st.val, st.total
		local builders = v.con + v.factory + v.nano

		addKV(l, "Total", fmt(tot), nil, nil, C.head)
		addKV(l, "Army", fmt(v.army), fmtPct(pct(v.army, tot)))
		addKV(l, "Builders", fmt(builders), fmtPct(pct(builders, tot)))
		addKV(l, "constructors", fmt(v.con),     fmtPct(pct(v.con, tot)),     C.dim, nil, nil, 1)
		addKV(l, "factories",    fmt(v.factory), fmtPct(pct(v.factory, tot)), C.dim, nil, nil, 1)
		addKV(l, "nano/static",  fmt(v.nano),    fmtPct(pct(v.nano, tot)),    C.dim, nil, nil, 1)
		addKV(l, "Economy",  fmt(v.eco),     fmtPct(pct(v.eco, tot)))
		addKV(l, "Defense",  fmt(v.defense), fmtPct(pct(v.defense, tot)))
		addKV(l, "Utility",  fmt(v.utility), fmtPct(pct(v.utility, tot)))
		addKV(l, "In production", fmt(st.wip), st.wipCount .. " units", C.warn, nil, C.dim)
		local avg = st.cnt.army > 0 and (v.army / st.cnt.army) or 0
		addKV(l, "Army units", tostring(st.cnt.army), "avg " .. fmt(avg), nil, nil, C.dim)
	end

	if cfg.sections.tech then
		addGap(l)
		addHead(l, (cfg.techMode == "army") and "Tech split (army value)" or "Tech split (all, no comm)")
		if st.techTotal <= 0 then
			addKV(l, "no units yet", nil, nil, C.dim)
		else
			for lvl = 1, st.maxTech do
				local val = st.tech[lvl]
				local p = pct(val, st.techTotal)
				addBar(l, "T" .. lvl, p / 100, TECH_COLORS[min(lvl, #TECH_COLORS)], fmt(val), fmtPct(p))
			end
		end
	end

	if cfg.sections.bp then
		addGap(l)
		addHead(l, "Build power")
		local bp = st.bp
		addKV(l, "Total", fmt(bp.total), nil, nil, C.head)
		addKV(l, "constructors", fmt(bp.con),     fmtPct(pct(bp.con, bp.total)),     C.dim, nil, nil, 1)
		addKV(l, "factories",    fmt(bp.factory), fmtPct(pct(bp.factory, bp.total)), C.dim, nil, nil, 1)
		addKV(l, "nano/static",  fmt(bp.nano),    fmtPct(pct(bp.nano, bp.total)),    C.dim, nil, nil, 1)
		local activeP = pct(bp.active, bp.total)
		addKV(l, "Working", fmt(bp.active), fmtPct(activeP), nil, nil,
			(activeP < 50 and bp.total > 0) and C.warn or C.good)
		addKV(l, "Idle constructors", st.idleCons .. "/" .. st.totalCons, nil, nil,
			(st.idleCons > 0) and C.warn or C.text)
		addKV(l, "Idle factories", st.idleFacs .. "/" .. st.totalFacs, nil, nil,
			(st.idleFacs > 0) and C.warn or C.text)
		local ratio = (st.metal.inc > 0.01) and (bp.total / st.metal.inc) or 0
		addKV(l, "BP per metal/s", format("%.1f", ratio))
	end

	finishList(l)
end

--------------------------------------------------------------------------------
-- Detailed panels
--------------------------------------------------------------------------------

local function buildResPanel(l, isMetal)
	local r      = isMetal and st.metal or st.energy
	local other  = isMetal and st.energy or st.metal
	local c      = isMetal and C.metal or C.energy
	local makeK  = isMetal and "mMake" or "eMake"
	local useK   = isMetal and "mUse" or "eUse"
	local topArr = isMetal and topM or topE
	local nTop   = isMetal and nTopM or nTopE

	addTitle(l, isMetal and "Metal detail" or "Energy detail")
	l.pool[l.n].c0 = c   -- tint the title

	-- flow ------------------------------------------------------------------------
	addHead(l, "Flow")
	local net = r.inc - r.exp
	addKV(l, "Income",  fmtRate(r.inc), nil, nil, c)
	addKV(l, "Expense", fmtRate(r.exp), nil, nil, c)
	addKV(l, "Net",     fmtNet(net), nil, nil, net >= 0 and C.good or C.bad)
	if r.pull > 0.05 then
		local sat = min(100, pct(r.exp, r.pull))
		addKV(l, "Demand", fmtRate(r.pull), fmtPct(sat) .. " met", nil, nil,
			sat < 90 and C.bad or (sat < 99 and C.warn or C.good))
	else
		addKV(l, "Demand", fmtRate(r.pull), nil)
	end
	if r.inc > 0.05 then
		addKV(l, "Spent / income", fmtPct(pct(r.exp, r.inc)), nil, nil,
			(r.exp > r.inc * 1.02) and C.warn or C.text)
	end
	local fill = pct(r.cur, r.stor)
	addKV(l, "Stored", fmt(r.cur) .. "/" .. fmt(r.stor), fmtPct(fill), nil, nil,
		(fill < 5) and C.bad or C.dim)
	if net > 0.01 and r.stor > r.cur then
		addKV(l, "Full in", fmtTime((r.stor - r.cur) / net), nil, nil, C.good)
	elseif net < -0.01 and r.cur > 0 then
		addKV(l, "Empty in", fmtTime(r.cur / -net), nil, nil, C.bad)
	end
	if r.excess > 0.05 then
		addKV(l, "Wasted (excess)", fmtRate(r.excess), nil, C.warn, C.warn)
	end
	if r.sent > 0.05 or r.recv > 0.05 then
		addKV(l, "Sent / received", fmtRate(r.sent), fmtRate(r.recv), nil, nil, C.dim)
	end
	if isMetal then
		if st.energy.inc > 0.01 and r.inc > 0.01 then
			addKV(l, "Energy per metal", format("%.1f", st.energy.inc / r.inc), nil, nil, C.dim)
		end
	else
		if gr.conv.eUse > 0.05 then
			addKV(l, "Converters E>M", fmtRate(gr.conv.eUse), fmtRate(gr.conv.mMake), nil, nil, C.metal)
		end
		if other.inc > 0.01 and r.inc > 0.01 then
			addKV(l, "Energy per metal", format("%.1f", r.inc / other.inc), nil, nil, C.dim)
		end
	end

	-- income by source --------------------------------------------------------------
	addGap(l)
	addHead(l, "Income by source")
	local sumMake = 0
	for i = 1, #RGROUPS do
		local g = RGROUPS[i]
		local v = gr[g][makeK]
		sumMake = sumMake + v
		if v > 0.05 then
			addKV(l, RGNAME[g] .. " (" .. gr[g].cnt .. ")", fmtRate(v), fmtPct(pct(v, r.inc)), nil, nil, C.dim)
		end
	end
	local rest = r.inc - sumMake
	if rest > 0.05 then
		addKV(l, "Reclaim/shared/other", fmtRate(rest), fmtPct(pct(rest, r.inc)), C.dim, nil, C.dim)
	end
	if sumMake <= 0.05 and rest <= 0.05 then
		addKV(l, "none", nil, nil, C.dim)
	end

	-- spending by group ---------------------------------------------------------------
	addGap(l)
	addHead(l, "Spending by")
	local sumUse = 0
	for i = 1, #RGROUPS do
		local g = RGROUPS[i]
		local v = gr[g][useK]
		sumUse = sumUse + v
		if v > 0.05 then
			addKV(l, RGNAME[g] .. " (" .. gr[g].cnt .. ")", fmtRate(v), fmtPct(pct(v, r.exp)), nil, nil, C.dim)
		end
	end
	local restUse = r.exp - sumUse
	if restUse > 0.05 then
		addKV(l, "Other/unattributed", fmtRate(restUse), fmtPct(pct(restUse, r.exp)), C.dim, nil, C.dim)
	end
	if sumUse <= 0.05 and restUse <= 0.05 then
		addKV(l, "none", nil, nil, C.dim)
	end

	-- top producers by unit type --------------------------------------------------------
	addGap(l)
	addHead(l, "Top producers")
	if nTop == 0 then
		addKV(l, "none", nil, nil, C.dim)
	else
		for i = 1, nTop do
			local id = topArr[i]
			local pd = perDef[id]
			local make = pd[makeK]
			addKV(l, shortName(defInfo[id].name, 12) .. " x" .. pd.count, fmtRate(make),
				fmtRate(make / pd.count) .. " ea", nil, nil, C.dim)
		end
	end

	finishList(l)
end

local function buildArmyPanel(l)
	addTitle(l, "Army & builders")

	-- unit overview ---------------------------------------------------------------------
	addHead(l, "Units")
	addKV(l, "Total (finished)", tostring(st.unitCount), st.wipCount .. " building", nil, C.head, C.dim)
	for i = 1, #CATS do
		local cat = CATS[i]
		local n = st.cnt[cat]
		if n > 0 then
			addKV(l, CATNAME[cat], tostring(n), "avg " .. fmt(st.val[cat] / n), nil, nil, C.dim, 1)
		end
	end

	-- army composition --------------------------------------------------------------------
	addGap(l)
	addHead(l, "Army composition")
	local armyVal = st.val.army
	if st.cnt.army == 0 then
		addKV(l, "no army units", nil, nil, C.dim)
	else
		for i = 1, #DOMAINS do
			local d = DOMAINS[i]
			if st.domCnt[d] > 0 then
				addKV(l, DOMNAME[d] .. " (" .. st.domCnt[d] .. ")", fmt(st.domVal[d]),
					fmtPct(pct(st.domVal[d], armyVal)))
			end
		end
		for t = 1, st.maxTechA do
			if st.armyTechCnt[t] > 0 then
				addKV(l, "T" .. t .. " (" .. st.armyTechCnt[t] .. ")", fmt(st.armyTech[t]),
					fmtPct(pct(st.armyTech[t], armyVal)), TECH_COLORS[min(t, #TECH_COLORS)])
			end
		end
	end

	-- combat strength --------------------------------------------------------------------
	addGap(l)
	addHead(l, "Combat strength")
	if st.cnt.army > 0 then
		local hpP = pct(st.armyHP, st.armyMaxHP)
		addKV(l, "Army HP", fmt(st.armyHP) .. "/" .. fmt(st.armyMaxHP), fmtPct(hpP), nil, nil,
			hpP < 60 and C.bad or (hpP < 90 and C.warn or C.good))
		addKV(l, "Est. DPS (rough)", fmt(st.armyDPS), nil)
		if armyVal > 0 then
			addKV(l, "DPS per 1k metal", format("%.1f", st.armyDPS / (armyVal / 1000)), nil, nil, C.dim)
			addKV(l, "HP per metal", format("%.1f", st.armyMaxHP / armyVal), nil, nil, C.dim)
		end
	end
	if st.hasRate then
		addKV(l, "Army value/min", fmtNet(st.armyRate), format("%ds", floor(st.rateWindow + 0.5)),
			nil, st.armyRate >= 0 and C.good or C.bad, C.dim)
		addKV(l, "Total value/min", fmtNet(st.totalRate), nil, nil,
			st.totalRate >= 0 and C.good or C.bad)
	else
		addKV(l, "Value/min", "collecting...", nil, nil, C.dim)
	end

	-- builders --------------------------------------------------------------------------------
	addGap(l)
	addHead(l, "Builders")
	if st.comCnt > 0 then
		addKV(l, "Commander x" .. st.comCnt, fmt(st.comBP), fmtPct(pct(st.comBP, st.bp.total)), nil, nil, C.dim)
	end
	for t = 1, st.maxTechA do
		if st.conCnt[t] > 0 then
			addKV(l, "Con T" .. t .. " x" .. st.conCnt[t], fmt(st.conBP[t]),
				fmtPct(pct(st.conBP[t], st.bp.total)), nil, nil, C.dim)
		end
	end
	for t = 1, st.maxTechA do
		if st.facCnt[t] > 0 then
			addKV(l, "Fac T" .. t .. " x" .. st.facCnt[t], fmt(st.facBP[t]),
				fmtPct(pct(st.facBP[t], st.bp.total)), nil, nil, C.dim)
		end
	end
	addKV(l, "Nano/static x" .. st.cnt.nano, fmt(st.bp.nano), fmtPct(pct(st.bp.nano, st.bp.total)), nil, nil, C.dim)
	addKV(l, "Factory queue", tostring(st.queueTotal) .. " units")
	local remainTxt = "--"
	if st.wipRemain > 0 and st.builderSpend > 0.01 then
		remainTxt = "ETA " .. fmtTime(st.wipRemain / st.builderSpend)
	end
	addKV(l, "Left to build", fmt(st.wipRemain), remainTxt, nil, nil, C.dim)
	addKV(l, "Build spend", fmtRate(st.builderSpend) .. " M/s", nil, nil, C.metal)

	-- structures -------------------------------------------------------------------------------
	addGap(l)
	addHead(l, "Structures")
	addKV(l, "Extractors x" .. gr.mex.cnt, nil, tierStr(st.mexCnt, st.maxTechA), nil, nil, C.dim)
	addKV(l, "Generators x" .. gr.gen.cnt, nil, nil)
	addKV(l, "Converters x" .. gr.conv.cnt, nil, nil)
	addKV(l, "Storage x" .. gr.store.cnt, nil, nil)
	addKV(l, "Defense x" .. st.cnt.defense, fmt(st.val.defense), nil, nil, C.dim)
	addKV(l, "Utility x" .. st.cnt.utility, fmt(st.val.utility), nil, nil, C.dim)

	-- kill / loss tally -------------------------------------------------------------------------
	addGap(l)
	addHead(l, "Kills/losses (seen)")
	local lv, lc = lossValue[st.teamID] or 0, lossCount[st.teamID] or 0
	local kv, kc = killValue[st.teamID] or 0, killCount[st.teamID] or 0
	addKV(l, "Lost", fmt(lv), lc .. " units", nil, C.bad, C.dim)
	addKV(l, "Killed", fmt(kv), kc .. " units", nil, C.good, C.dim)
	local ratio = lv > 0 and format("K/L %.2f", kv / lv) or (kv > 0 and "K/L inf" or "K/L --")
	addKV(l, "Net", fmtNet(kv - lv), ratio, nil, (kv >= lv) and C.good or C.bad, C.dim)

	finishList(l)
end

local function refresh()
	local detailed = cfg.detailed
	computeStats(detailed)

	panels[1].active = true
	panels[2].active = detailed and cfg.dsections.metal
	panels[3].active = detailed and cfg.dsections.energy
	panels[4].active = detailed and cfg.dsections.army

	panels[1].list.n = 0
	buildMain(panels[1].list)
	if panels[2].active then panels[2].list.n = 0; buildResPanel(panels[2].list, true) end
	if panels[3].active then panels[3].list.n = 0; buildResPanel(panels[3].list, false) end
	if panels[4].active then panels[4].list.n = 0; buildArmyPanel(panels[4].list) end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local dragPanel, dragOffX, dragOffY = nil, 0, 0

local function setColor(c) glColor(c[1], c[2], c[3], c[4] or 1) end

local function drawList(p, x, top, s)
	local list = p.list
	local fs  = FONT * s
	local lh  = LINE_H * s
	local pad = PAD * s
	local w   = p.w * s
	local h   = list.baseH * s
	local rect = p.rect
	rect.x1, rect.y1, rect.x2, rect.y2 = x, top - h, x + w, top

	-- background + thin border
	setColor(C.bg)
	glRect(x, top - h, x + w, top)
	glColor(1, 1, 1, 0.14)
	glRect(x, top - 1, x + w, top)
	glRect(x, top - h, x + w, top - h + 1)
	glRect(x, top - h, x + 1, top)
	glRect(x + w - 1, top - h, x + w, top)

	local colV1 = x + w - pad - 56 * s     -- right edge of 1st value column
	local colV2 = x + w - pad              -- right edge of 2nd value column
	local y = top - pad
	local pool = list.pool

	for i = 1, list.n do
		local row = pool[i]
		local rh = (ROWH[row.t] or 1) * lh
		local cy = y - rh / 2
		local t = row.t

		if t == "title" then
			setColor(row.c0 or C.text)
			glText(row.text, x + pad, cy, fs * 1.2, "vo")

		elseif t == "head" then
			setColor(C.head)
			glText(row.text, x + pad, y - rh * 0.6, fs, "vo")
			glColor(C.head[1], C.head[2], C.head[3], 0.35)
			glRect(x + pad, y - rh + 2 * s, x + w - pad, y - rh + 3 * s)

		elseif t == "kv" then
			setColor(row.c0 or C.text)
			glText(row.label, x + pad + (row.indent or 0) * 12 * s, cy, fs, "vo")
			if row.v1 then
				setColor(row.c1 or C.text)
				glText(row.v1, colV1, cy, fs, "vro")
			end
			if row.v2 then
				setColor(row.c2 or C.dim)
				glText(row.v2, colV2, cy, fs, "vro")
			end

		elseif t == "bar" then
			setColor(C.text)
			glText(row.label, x + pad, cy, fs, "vo")
			local bx = x + pad + 26 * s
			local bw = (colV1 - 46 * s) - bx
			local bh = 8 * s
			setColor(C.bar_bg)
			glRect(bx, cy - bh / 2, bx + bw, cy + bh / 2)
			setColor(row.color)
			glRect(bx, cy - bh / 2, bx + bw * max(0, min(1, row.frac)), cy + bh / 2)
			setColor(C.dim)
			glText(row.v1, colV1, cy, fs, "vro")
			setColor(C.text)
			glText(row.v2, colV2, cy, fs, "vro")
		end

		y = y - rh
	end
end

local function drawAll()
	-- measure at scale 1: docked group width/height, and tallest panel overall
	local dockedW, nDocked, dockedTallest, tallest = 0, 0, 0, 0
	for i = 1, #panels do
		local p = panels[i]
		if p.active and p.list.n > 0 then
			local h = p.list.baseH
			if h > tallest then tallest = h end
			if not p.detached then
				nDocked = nDocked + 1
				dockedW = dockedW + p.w
				if h > dockedTallest then dockedTallest = h end
			end
		end
	end
	if nDocked == 0 then return end            -- can't happen: main is never detached
	dockedW = dockedW + (nDocked - 1) * GAP

	-- auto-fit: neither the docked group nor any panel may exceed the screen
	local s = min(cfg.scale, (vsx - 4) / dockedW, (vsy - 4) / tallest)

	cfg.x   = max(0, min(cfg.x, vsx - dockedW * s))
	cfg.top = max(dockedTallest * s, min(cfg.top, vsy))

	-- pass 1: work out where every panel goes this frame
	local px = cfg.x
	for i = 1, #panels do
		local p = panels[i]
		if p.active and p.list.n > 0 then
			if p.detached then
				p.px   = max(0, min(p.px, vsx - p.w * s))
				p.ptop = max(p.list.baseH * s, min(p.ptop, vsy))
				p.drawX, p.drawTop = p.px, p.ptop
			else
				p.drawX, p.drawTop = px, cfg.top
				px = px + (p.w + GAP) * s
			end
		end
	end

	-- pass 2: draw back-to-front
	for i = 1, #drawOrder do
		local p = drawOrder[i]
		if p.active and p.list.n > 0 then
			drawList(p, p.drawX, p.drawTop, s)
		end
	end
	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- Widget callins
--------------------------------------------------------------------------------

local function resetLayout()
	cfg.scale = 1.0
	cfg.x = 12
	cfg.top = floor(vsy * 0.72)
	cfg.sections.eco, cfg.sections.value, cfg.sections.tech, cfg.sections.bp = true, true, true, true
	cfg.dsections.metal, cfg.dsections.energy, cfg.dsections.army = true, true, true
	dockAll()
end

function widget:Initialize()
	vsx, vsy = spGetViewGeometry()
	if not cfg.x or not cfg.top then
		cfg.x = 12
		cfg.top = floor(vsy * 0.72)
	end
	resetHistory()
	refresh()
end

function widget:Shutdown()
	-- drop references so a reload doesn't keep big tables alive
	for i = 1, #panels do
		panels[i].list.pool = {}
		panels[i].list.n = 0
	end
	resetTally()
	for k in pairs(perDef) do perDef[k] = nil end
	for i = #touched, 1, -1 do touched[i] = nil end
	nTouched = 0
end

function widget:ViewResize(newX, newY)
	vsx, vsy = newX, newY
end

function widget:PlayerChanged()
	resetHistory()
	refresh()
end

local timer = 0
function widget:Update(dt)
	timer = timer + dt
	if timer >= cfg.interval then
		timer = 0
		if cfg.visible then refresh() end
	end
end

function widget:DrawScreen()
	if not cfg.visible or spIsGUIHidden() then return end
	drawAll()
end

-- Kill / loss tally ---------------------------------------------------------------
function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
	if not attackerTeam or not unitTeam or attackerTeam == unitTeam then return end
	if spAreTeamsAllied(unitTeam, attackerTeam) then return end
	local info = defInfo[unitDefID]
	if not info then return end
	local value = info.cost
	local beingBuilt, progress = spGetUnitIsBeingBuilt(unitID)
	if beingBuilt then value = value * (progress or 0) end
	lossValue[unitTeam] = (lossValue[unitTeam] or 0) + value
	lossCount[unitTeam] = (lossCount[unitTeam] or 0) + 1
	killValue[attackerTeam] = (killValue[attackerTeam] or 0) + value
	killCount[attackerTeam] = (killCount[attackerTeam] or 0) + 1
end

-- Mouse: drag panels, right-click to dock, Ctrl+wheel to scale ------------------------
local function panelAt(x, y)
	for i = #drawOrder, 1, -1 do               -- topmost first
		local p = drawOrder[i]
		if p.active and p.list.n > 0 then
			local r = p.rect
			if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then return p end
		end
	end
	return nil
end

local function bringToFront(p)
	local n = #drawOrder
	for i = 1, n do
		if drawOrder[i] == p then
			for j = i, n - 1 do drawOrder[j] = drawOrder[j + 1] end
			drawOrder[n] = p
			return
		end
	end
end

function widget:IsAbove(x, y)
	return cfg.visible and panelAt(x, y) ~= nil
end

function widget:MousePress(x, y, button)
	if not cfg.visible then return false end
	local p = panelAt(x, y)
	if not p then return false end

	if button == 1 then
		bringToFront(p)
		dragPanel = p
		dragOffX, dragOffY = x - p.rect.x1, y - p.rect.y2
		return true
	elseif button == 3 then
		if p.id == "main" then dockAll() else p.detached = false end
		return true
	end
	return false
end

function widget:MouseMove(x, y)
	local p = dragPanel
	if not p then return end
	if p.id == "main" then
		cfg.x, cfg.top = x - dragOffX, y - dragOffY
	else
		-- a detail panel detaches the moment it is actually dragged (not on a plain click)
		p.detached = true
		p.px, p.ptop = x - dragOffX, y - dragOffY
	end
end

function widget:MouseRelease()
	dragPanel = nil
end

function widget:MouseWheel(up, value)
	if not cfg.visible then return false end
	local mx, my = spGetMouseState()
	if not panelAt(mx, my) then return false end
	local _, ctrl = spGetModKeyState()
	if not ctrl then return false end
	cfg.scale = max(0.5, min(3.0, cfg.scale + (up and 0.1 or -0.1)))
	return true
end

-- Chat commands ---------------------------------------------------------------------------
function widget:TextCommand(command)
	local w1, w2, w3 = command:match("^%s*(%S+)%s*(%S*)%s*(%S*)")
	if not w1 or w1:lower() ~= "armyinfo" then return false end
	local arg = w2:lower()
	local arg2 = w3:lower()

	if arg == "" then
		cfg.visible = not cfg.visible
		if cfg.visible then resetHistory() end
	elseif arg == "detailed" or arg == "detail" then
		if arg2 == "on" then cfg.detailed = true
		elseif arg2 == "off" then cfg.detailed = false
		else cfg.detailed = not cfg.detailed end
		cfg.visible = true
		spEcho("[Army Overview] detailed mode: " .. (cfg.detailed and "on" or "off"))
	elseif arg == "scale" then
		local n = tonumber(w3)
		if n then cfg.scale = max(0.5, min(3.0, n)) end
	elseif arg == "techmode" then
		cfg.techMode = (cfg.techMode == "army") and "all" or "army"
		spEcho("[Army Overview] tech split mode: " .. cfg.techMode)
	elseif arg == "eco" or arg == "value" or arg == "tech" or arg == "bp" then
		cfg.sections[arg] = not cfg.sections[arg]
	elseif arg == "metal" or arg == "energy" or arg == "army" then
		cfg.dsections[arg] = not cfg.dsections[arg]
	elseif arg == "dock" then
		dockAll()
	elseif arg == "resettally" then
		resetTally()
	elseif arg == "reset" then
		resetLayout()
	else
		spEcho("[Army Overview] /armyinfo | detailed [on|off] | metal | energy | army | eco | value | tech | bp | techmode | scale <n> | dock | resettally | reset")
	end
	refresh()
	return true
end

-- Persist settings between games ---------------------------------------------------------------
function widget:GetConfigData()
	local panelPos = {}
	for i = 2, #panels do
		local p = panels[i]
		if p.detached then panelPos[p.id] = { x = p.px, top = p.ptop } end
	end
	return {
		x = cfg.x, top = cfg.top, scale = cfg.scale, visible = cfg.visible,
		detailed = cfg.detailed, techMode = cfg.techMode,
		sections = cfg.sections, dsections = cfg.dsections,
		panelPos = panelPos,
	}
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then return end
	cfg.x        = data.x or cfg.x
	cfg.top      = data.top or cfg.top
	cfg.scale    = data.scale or cfg.scale
	if data.visible ~= nil then cfg.visible = data.visible end
	if data.detailed ~= nil then cfg.detailed = data.detailed end
	cfg.techMode = data.techMode or cfg.techMode
	if type(data.sections) == "table" then
		for k, v in pairs(data.sections) do cfg.sections[k] = v end
	end
	if type(data.dsections) == "table" then
		for k, v in pairs(data.dsections) do cfg.dsections[k] = v end
	end
	if type(data.panelPos) == "table" then
		for i = 2, #panels do
			local pos = data.panelPos[panels[i].id]
			if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.top) then
				panels[i].detached = true
				panels[i].px, panels[i].ptop = pos.x, pos.top
			end
		end
	end
end
