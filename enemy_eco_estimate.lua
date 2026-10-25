function widget:GetInfo()
	return {
		name    = "Enemy Economy Estimate",
		desc    = "Estimates each enemy team's metal/energy from the economy structures you have seen, using live metal and wind values. Draggable, scalable panel. /enemyeco help",
		author  = "Surprised_cat And Claude",
		date    = "2026",
		license = "MIT",
		layer   = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Install: put this file in  <BAR install>/data/LuaUI/Widgets/enemy_eco_estimate.lua
-- then /luaui reload and enable "Enemy Economy Estimate".
--
-- How the numbers are made
--   Metal:  each enemy mex is scored from the metal under it (Spring.GetMetalAmount)
--           times its extractsMetal. The score is turned into metal/s with a factor
--           calibrated against YOUR OWN measured metal income (Spring.GetTeamResources).
--           Until you have a mex of your own, the factor is the frame rate (uncalibrated).
--   Wind:   each turbine produces the current wind strength, clamped to the map's
--           windMin/windMax (Spring.GetWind, Game.windMin/windMax).
--   Power:  solar, geothermal, fusion etc. use their energyMake from unit stats.
--
-- Every number is per enemy team, plus a combined line for all enemies. Each team
-- is a lower bound: structures you have never seen are not counted. Structures stay
-- remembered after you lose sight of them, until you look at the spot and they are
-- gone, or they are destroyed while visible.
--
-- Commands
--   /enemyeco ................ show / hide the panel
--   /enemyeco scale <0.5-2> .. set panel size (no number shows the current size)
--   /enemyeco reset .......... move the panel back and reset its scale
--   /enemyeco help ........... list commands
-- The panel can be dragged with the left mouse button. Position and scale are saved.
--------------------------------------------------------------------------------

-- Settings ---------------------------------------------------------------------
local REFRESH      = 1.0     -- real seconds between recalculations
local FRAMES_PER_S = 30      -- engine frames per second (uncalibrated metal factor)
local CALIB_SMOOTH = 0.3     -- how quickly the metal calibration follows new measurements

-- Localised engine calls ------------------------------------------------------
local spGetMyAllyTeamID     = Spring.GetMyAllyTeamID
local spGetMyTeamID         = Spring.GetMyTeamID
local spGetTeamList         = Spring.GetTeamList
local spGetTeamInfo         = Spring.GetTeamInfo
local spGetTeamColor        = Spring.GetTeamColor
local spGetPlayerInfo       = Spring.GetPlayerInfo
local spGetGaiaTeamID       = Spring.GetGaiaTeamID
local spGetTeamUnits        = Spring.GetTeamUnits
local spGetTeamResources    = Spring.GetTeamResources
local spGetUnitDefID        = Spring.GetUnitDefID
local spGetUnitPosition     = Spring.GetUnitPosition
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetMetalAmount      = Spring.GetMetalAmount
local spGetWind             = Spring.GetWind
local spIsPosInLos          = Spring.IsPosInLos
local spGetGroundHeight     = Spring.GetGroundHeight
local spGetGameFrame        = Spring.GetGameFrame
local spGetGameSeconds      = Spring.GetGameSeconds
local spGetViewGeometry     = Spring.GetViewGeometry
local spIsGUIHidden         = Spring.IsGUIHidden
local spEcho                = Spring.Echo

local glColor = gl.Color
local glRect  = gl.Rect
local glText  = gl.Text

local floor, max, min = math.floor, math.max, math.min
local format = string.format

-- Panel settings ---------------------------------------------------------------
local cfg = {
	show  = true,
	scale = 1.0,                    -- panel size multiplier (0.5 .. 2.0)
	px = 20, py = 300,              -- panel bottom-left corner in screen pixels
}

local BASE_W, BASE_ROW, BASE_TITLE, BASE_PAD = 270, 17, 24, 8
local PANEL_W, ROW_H, TITLE_H, PAD, PANEL_H = BASE_W, BASE_ROW, BASE_TITLE, BASE_PAD, 0
local lines = {}                    -- rebuilt each refresh: { text, r, g, b, size }
local clampPanel                    -- defined with the panel code below

local function applyScale()
	cfg.scale = max(0.5, min(2.0, cfg.scale or 1.0))
	local s = cfg.scale
	PANEL_W = floor(BASE_W * s + 0.5)
	ROW_H   = floor(BASE_ROW * s + 0.5)
	TITLE_H = floor(BASE_TITLE * s + 0.5)
	PAD     = floor(BASE_PAD * s + 0.5)
end
applyScale()

local function panelHeight()
	return TITLE_H + max(1, #lines) * ROW_H + PAD * 2
end

--------------------------------------------------------------------------------
-- Economy definitions (computed once)
--------------------------------------------------------------------------------

-- ecoOf[defID] = { cat = "mex"|"wind"|"power", extract = ..., make = ... }
local ecoOf = {}
for defID, ud in pairs(UnitDefs) do
	if (ud.speed or 0) == 0 then                      -- buildings only
		local extract = ud.extractsMetal or 0
		local make    = ud.energyMake or 0
		if extract > 0 then
			ecoOf[defID] = { cat = "mex", extract = extract, make = 0 }
		elseif (ud.windGenerator or 0) > 0 then
			ecoOf[defID] = { cat = "wind", extract = 0, make = 0 }
		elseif make > 0 then
			ecoOf[defID] = { cat = "power", extract = 0, make = make }
		end
	end
end

--------------------------------------------------------------------------------
-- Live values
--------------------------------------------------------------------------------

-- Sums metal over a 3x3 grid of samples across the mex's footprint. The footprint
-- size is an assumption; using the same sampling for your mexes and enemy mexes means
-- the calibration factor absorbs any scale error.
local function rawMetalAt(x, z, extract)
	local sum = 0
	for dx = -8, 8, 8 do
		for dz = -8, 8, 8 do
			sum = sum + (spGetMetalAmount(x + dx, z + dz) or 0)
		end
	end
	return extract * sum
end

-- current wind, clamped to the map's range; each turbine gets this value
local function currentWind()
	local _, _, _, strength = spGetWind()
	strength = strength or 0
	local lo, hi = Game.windMin or 0, Game.windMax or strength
	return max(lo, min(hi, strength))
end

-- metal/s per unit of raw score; frame rate until calibrated against your own income
local metalFactor = FRAMES_PER_S
local calibrated  = false

--------------------------------------------------------------------------------
-- Teams
--------------------------------------------------------------------------------

local enemyTeams, nEnemy = {}, 0
local enemyFlag = {}
local teamName, teamColor = {}, {}
local myAllyTeam, myTeam = 0, 0
local lastTeamRefresh = -999

local function refreshTeams()
	nEnemy = 0
	for k in pairs(enemyFlag) do enemyFlag[k] = nil end
	myAllyTeam = spGetMyAllyTeamID()
	myTeam = spGetMyTeamID()
	local gaia = spGetGaiaTeamID()
	local list = spGetTeamList()
	for i = 1, #list do
		local t = list[i]
		if t ~= gaia then
			local _, leader, isDead, _, _, allyT = spGetTeamInfo(t, false)
			if not isDead and allyT ~= myAllyTeam then
				nEnemy = nEnemy + 1
				enemyTeams[nEnemy] = t
				enemyFlag[t] = true

				local name = leader and leader >= 0 and spGetPlayerInfo(leader) or nil
				teamName[t] = name or ("Team " .. t)
				local r, g, b = spGetTeamColor(t)
				teamColor[t] = { r or 1, g or 0.3, b or 0.3 }
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Structure memory: each remembered structure belongs to one enemy team
--------------------------------------------------------------------------------

local known = {}          -- unitID -> { team, cat, raw, make, x, z, stamp }
local stamp = 0
local removedLast = 0     -- buildings deleted by the most recent check

local function observe(uid, team)
	local defID = spGetUnitDefID(uid)
	local eco = defID and ecoOf[defID]
	if not eco or spGetUnitIsBeingBuilt(uid) then
		known[uid] = nil                 -- not economy, or not finished
		return
	end
	local x, _, z = spGetUnitPosition(uid)
	if not x then return end
	local e = known[uid]
	if not e then
		e = {}
		known[uid] = e
	end
	e.team = team
	e.cat, e.make = eco.cat, eco.make
	e.raw = (eco.cat == "mex") and rawMetalAt(x, z, eco.extract) or 0
	e.x, e.z, e.stamp = x, z, stamp
end

--------------------------------------------------------------------------------
-- Calibration against your own income
--------------------------------------------------------------------------------

local function calibrate()
	local units = spGetTeamUnits(myTeam)
	if not units then return end
	local ownRaw = 0
	for k = 1, #units do
		local uid = units[k]
		local defID = spGetUnitDefID(uid)
		local eco = defID and ecoOf[defID]
		if eco and eco.cat == "mex" and not spGetUnitIsBeingBuilt(uid) then
			local x, _, z = spGetUnitPosition(uid)
			if x then ownRaw = ownRaw + rawMetalAt(x, z, eco.extract) end
		end
	end
	local _, _, _, income = spGetTeamResources(myTeam, "metal")
	if ownRaw > 0 and income and income > 0 then
		local measured = income / ownRaw
		if calibrated then
			metalFactor = metalFactor + CALIB_SMOOTH * (measured - metalFactor)
		else
			metalFactor = measured
			calibrated = true
		end
	end
end

--------------------------------------------------------------------------------
-- Per-team totals and panel lines (rebuilt once per refresh)
--------------------------------------------------------------------------------

-- stats[team] = { metal, energy, nMex, nWind, nPower, seen, remembered }
local stats = {}

local function clearStats()
	for t in pairs(stats) do stats[t] = nil end
end

local function statFor(t)
	local s = stats[t]
	if not s then
		s = { metal = 0, energy = 0, nMex = 0, nWind = 0, nPower = 0, seen = 0, remembered = 0 }
		stats[t] = s
	end
	return s
end

local windNow = 0

-- energy factor: scales raw energy values (energyMake, wind) to the game's energy/s,
-- calibrated against your own measured energy income the same way metal is
local energyFactor = 1
local energyCalibrated = false

local function calibrateEnergy()
	local units = spGetTeamUnits(myTeam)
	if not units then return end
	local ownRaw = 0
	for k = 1, #units do
		local uid = units[k]
		local defID = spGetUnitDefID(uid)
		local eco = defID and ecoOf[defID]
		if eco and eco.cat ~= "mex" and not spGetUnitIsBeingBuilt(uid) then
			ownRaw = ownRaw + ((eco.cat == "wind") and windNow or eco.make)
		end
	end
	local _, _, _, income = spGetTeamResources(myTeam, "energy")
	if ownRaw > 0 and income and income > 0 then
		local measured = income / ownRaw
		if energyCalibrated then
			energyFactor = energyFactor + CALIB_SMOOTH * (measured - energyFactor)
		else
			energyFactor = measured
			energyCalibrated = true
		end
	end
end

-- /enemyeco debug: prints the numbers the calibration is built from
local function debugReport()
	local units = spGetTeamUnits(myTeam) or {}
	local ownMex, ownRawM, ownRawE = 0, 0, 0
	for k = 1, #units do
		local uid = units[k]
		local defID = spGetUnitDefID(uid)
		local eco = defID and ecoOf[defID]
		if eco and not spGetUnitIsBeingBuilt(uid) then
			local x, _, z = spGetUnitPosition(uid)
			if x then
				if eco.cat == "mex" then
					ownMex = ownMex + 1
					ownRawM = ownRawM + rawMetalAt(x, z, eco.extract)
				else
					ownRawE = ownRawE + ((eco.cat == "wind") and windNow or eco.make)
				end
			end
		end
	end
	local _, _, _, mInc = spGetTeamResources(myTeam, "metal")
	local _, _, _, eInc = spGetTeamResources(myTeam, "energy")
	local wmin, wmax = Game.windMin or -1, Game.windMax or -1
	spEcho(format("[EnemyEco debug] own mexes %d, raw metal %.2f, metal income %.2f, metal factor %.4f (%s)",
		ownMex, ownRawM, mInc or 0, metalFactor, calibrated and "calibrated" or "default"))
	spEcho(format("[EnemyEco debug] own raw energy %.2f, energy income %.2f, energy factor %.4f (%s)",
		ownRawE, eInc or 0, energyFactor, energyCalibrated and "calibrated" or "default"))
	spEcho(format("[EnemyEco debug] wind now %.2f (map min %s, max %s)", windNow, tostring(wmin), tostring(wmax)))
	spEcho(format("[EnemyEco debug] remembered buildings %d, deleted on last check %d", (function()
		local n = 0
		for _ in pairs(known) do n = n + 1 end
		return n
	end)(), removedLast))
end

local function buildLines()
	lines = {}
	local function add(text, c, size)
		lines[#lines + 1] = { text = text, r = c[1], g = c[2], b = c[3], size = size }
	end
	local white, metalC, energyC, noteC = { 0.85, 0.85, 0.85 }, { 0.55, 0.85, 1.0 }, { 1.0, 0.95, 0.55 }, { 0.6, 0.6, 0.6 }

	if nEnemy == 0 then
		add("No enemy teams", noteC, 10)
		return
	end

	-- combined line first
	local tot = { metal = 0, energy = 0, seen = 0, remembered = 0 }
	for i = 1, nEnemy do
		local s = stats[enemyTeams[i]]
		if s then
			tot.metal, tot.energy = tot.metal + s.metal, tot.energy + s.energy
			tot.seen, tot.remembered = tot.seen + s.seen, tot.remembered + s.remembered
		end
	end
	if tot.remembered == 0 then
		add("No enemy economy seen yet", noteC, 10)
	else
		add(format("All enemies: metal >= %d/s   energy >= %d/s", floor(tot.metal + 0.5), floor(tot.energy + 0.5)), white, 11)
	end

	-- one block per enemy team
	for i = 1, nEnemy do
		local t = enemyTeams[i]
		local s = stats[t] or statFor(t)
		local c = teamColor[t] or { 1, 0.3, 0.3 }
		add(teamName[t] or ("Team " .. t), c, 11)
		if s.remembered == 0 then
			add("   nothing seen", noteC, 10)
		else
			add(format("   metal >= %d/s   energy >= %d/s", floor(s.metal + 0.5), floor(s.energy + 0.5)), metalC, 10)
			add(format("   mex %d   wind %d   power %d   seen %d / %d", s.nMex, s.nWind, s.nPower, s.seen, s.remembered), white, 10)
		end
	end

	-- footnote
	if calibrated and energyCalibrated then
		add("Metal and energy calibrated to your income.", noteC, 9)
	elseif calibrated then
		add("Metal calibrated. Energy uncalibrated: build a generator.", noteC, 9)
	else
		add("Uncalibrated: build a mex (metal) and a generator (energy).", noteC, 9)
	end
	PANEL_H = panelHeight()
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function refresh()
	if spGetGameFrame() == 0 then return end

	local gs = spGetGameSeconds()
	if gs - lastTeamRefresh > 5 then
		refreshTeams()
		lastTeamRefresh = gs
	end

	windNow = currentWind()
	calibrate()
	calibrateEnergy()
	stamp = stamp + 1

	-- what is visible right now, attributed to its team
	for ti = 1, nEnemy do
		local t = enemyTeams[ti]
		local units = spGetTeamUnits(t)
		if units then
			for k = 1, #units do observe(units[k], t) end
		end
	end

	-- every remembered building not seen this check: if it still reports a position it
	-- exists, so keep it. If we can see its spot and it is not there, delete it.
	-- Buildings outside our vision are kept as they were last seen.
	removedLast = 0
	for uid, e in pairs(known) do
		if e.stamp ~= stamp then
			if spGetUnitPosition(uid) then
				observe(uid, e.team)
			elseif spIsPosInLos(e.x, spGetGroundHeight(e.x, e.z), e.z, myAllyTeam) then
				known[uid] = nil
				removedLast = removedLast + 1
			end
		end
	end

	-- totals per team
	clearStats()
	for i = 1, nEnemy do statFor(enemyTeams[i]) end
	for _, e in pairs(known) do
		local s = stats[e.team]
		if s then
			s.remembered = s.remembered + 1
			if e.stamp == stamp then s.seen = s.seen + 1 end
			if e.cat == "mex" then
				s.nMex = s.nMex + 1
				s.metal = s.metal + e.raw * metalFactor
			elseif e.cat == "wind" then
				s.nWind = s.nWind + 1
				s.energy = s.energy + windNow * energyFactor
			else
				s.nPower = s.nPower + 1
				s.energy = s.energy + e.make * energyFactor
			end
		end
	end

	buildLines()
	clampPanel()
end

--------------------------------------------------------------------------------
-- Panel (screen space)
--------------------------------------------------------------------------------

local dragging = false
local dragOX, dragOY = 0, 0

function clampPanel()
	local vsx, vsy = spGetViewGeometry()
	cfg.px = max(0, min(cfg.px, vsx - PANEL_W))
	cfg.py = max(0, min(cfg.py, vsy - PANEL_H))
end

local function insidePanel(x, y)
	return cfg.show and x >= cfg.px and x <= cfg.px + PANEL_W
		and y >= cfg.py and y <= cfg.py + PANEL_H
end

function widget:DrawScreen()
	if not cfg.show or spIsGUIHidden() then return end
	local x, y, s = cfg.px, cfg.py, cfg.scale

	-- body and title bar
	glColor(0.03, 0.05, 0.08, 0.72)
	glRect(x, y, x + PANEL_W, y + PANEL_H)
	glColor(0.15, 0.32, 0.5, 0.9)
	glRect(x, y + PANEL_H - TITLE_H, x + PANEL_W, y + PANEL_H)

	glColor(0.85, 0.95, 1.0, 1)
	glText("Enemy economy (estimate)", x + PAD, y + PANEL_H - TITLE_H + 7 * s, 12 * s, "o")

	-- rows, top to bottom
	for i = 1, #lines do
		local L = lines[i]
		local ry = y + PANEL_H - TITLE_H - PAD - i * ROW_H + 4 * s
		glColor(L.r, L.g, L.b, 1)
		glText(L.text, x + PAD, ry, L.size * s, "o")
	end
end

function widget:MousePress(mx, my, button)
	if button == 1 and insidePanel(mx, my) then
		dragging = true
		dragOX, dragOY = mx - cfg.px, my - cfg.py
		return true
	end
	return false
end

function widget:MouseMove(mx, my, dx, dy, button)
	if dragging then
		cfg.px, cfg.py = mx - dragOX, my - dragOY
		clampPanel()
	end
end

function widget:MouseRelease(mx, my, button)
	if dragging then
		dragging = false
		return true
	end
	return false
end

function widget:ViewResize()
	clampPanel()
end

--------------------------------------------------------------------------------
-- Widget callins
--------------------------------------------------------------------------------

local acc = 0

function widget:Initialize()
	applyScale()
	refreshTeams()
	lastTeamRefresh = spGetGameSeconds()
	local _, vsy = spGetViewGeometry()
	if cfg.py == 300 then cfg.py = floor(vsy * 0.5) end   -- first run: place at mid-left
	PANEL_H = panelHeight()
	clampPanel()
end

function widget:Update(dt)
	acc = acc + dt
	if acc >= REFRESH then
		acc = 0
		refresh()
	end
end

function widget:UnitEnteredLos(unitID, unitTeam)
	if enemyFlag[unitTeam] then observe(unitID, unitTeam) end
end

function widget:UnitEnteredRadar(unitID, unitTeam)
	if enemyFlag[unitTeam] then observe(unitID, unitTeam) end
end

function widget:UnitDestroyed(unitID)
	known[unitID] = nil
end

function widget:PlayerChanged()
	refreshTeams()
	lastTeamRefresh = spGetGameSeconds()
	for uid in pairs(known) do known[uid] = nil end
	calibrated, metalFactor = false, FRAMES_PER_S
	energyCalibrated, energyFactor = false, 1
end

function widget:TextCommand(command)
	local w1, w2, w3 = command:match("^%s*(%S+)%s*(%S*)%s*(%S*)")
	if not w1 or w1:lower() ~= "enemyeco" then return false end
	local arg = (w2 or ""):lower()

	if arg == "" then
		cfg.show = not cfg.show
	elseif arg == "scale" then
		local n = tonumber(w3)
		if n then
			cfg.scale = n
			applyScale()
			PANEL_H = panelHeight()
			clampPanel()
		end
		spEcho(format("[EnemyEco] panel scale %.2f", cfg.scale))
	elseif arg == "reset" then
		local _, vsy = spGetViewGeometry()
		cfg.px, cfg.py, cfg.scale = 20, floor(vsy * 0.5), 1.0
		applyScale()
		PANEL_H = panelHeight()
		clampPanel()
	elseif arg == "debug" then
		debugReport()
	elseif arg == "help" then
		spEcho("[EnemyEco] /enemyeco toggles the panel; /enemyeco scale <0.5-2>; /enemyeco reset; drag with the left mouse button")
	else
		spEcho("[EnemyEco] /enemyeco | scale <0.5-2> | reset | help")
	end
	return true
end

function widget:GetConfigData()
	return { show = cfg.show, px = cfg.px, py = cfg.py, scale = cfg.scale }
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then return end
	if data.show ~= nil then cfg.show = data.show end
	if data.px then cfg.px = data.px end
	if data.py then cfg.py = data.py end
	if data.scale then
		cfg.scale = data.scale
		applyScale()
	end
end
