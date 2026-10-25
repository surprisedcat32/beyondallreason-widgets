function widget:GetInfo()
	return {
		name    = "Frontline Tracker",
		desc    = "Frontline momentum: blue arrows = you advancing, red = enemy pushing, trails, instability and breakthrough alerts. /frontline help",
		author  = "Surprised_cat And Claude",
		date    = "2026",
		license = "MIT",
		layer   = 0,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Install: put this file in  <BAR install>/data/LuaUI/Widgets/gui_frontline_tracker.lua
-- then press F11 in game (or /luaui reload) and enable "Frontline Tracker".
--
-- How it works
--   1. Every unit that holds ground spreads strength onto a coarse grid. Armed
--      mobile units and defences hold the most; buildings of every kind count,
--      and each building also emits a much weaker, much wider "halo" so a
--      spread-out base still registers as one territory.
--   2. Your side vs the enemy gives a control value per cell in [-1, 1]. The
--      frontline is where that crosses 0, drawn only where both sides are present.
--   3. Momentum: the front's displacement against a slow memory of the map gives a
--      push per region. A fast average of that push is the current momentum; a
--      slow average is the trend. Momentum drives everything visible:
--
--        slow advance      thin, steady arrow
--        rapid advance     thick, fast-pulsing arrow
--        stalemate         faint arrow that fades as the last real push gets old
--        counterattack     arrow reverses direction and flashes
--        major breakthrough a large expanding ring on the map
--
--   4. Trails: contested ground leaves a heat trail that dissipates over time.
--   5. Instability: cells whose ownership keeps flipping flash yellow.
--
--   BLUE arrow pointing OUT toward the enemy = you are advancing
--   RED  arrow pointing IN toward your side  = the enemy is pushing you back
--
--   Enemy units you can't currently see are remembered as ghosts (mobile units
--   fade after ~60 s, buildings stay until you see the spot empty).
--
-- Commands
--   /frontline .................. show / hide everything
--   /frontline help ............. list commands
--   /frontline sens <1-5> ....... how big a push must be to get an arrow (default 5)
--   /frontline window <10-90> ... seconds of history for the trend (default 12)
--   /frontline lines|arrows|minimap|trail|instab|alerts   toggle that part
--   /frontline heat ............. debug overlay of the control map
--   /frontline reset ............ restore defaults
--
-- Memory notes: all grids, bins, segment, arrow and ring buffers are allocated
-- once at load. Drawing uses module-level emitter functions (no closures or
-- tables created while drawing). Enemy ghosts are pooled.
--------------------------------------------------------------------------------

-- Localised engine calls ------------------------------------------------------
local spGetMyAllyTeamID     = Spring.GetMyAllyTeamID
local spGetTeamList         = Spring.GetTeamList
local spGetTeamInfo         = Spring.GetTeamInfo
local spGetGaiaTeamID       = Spring.GetGaiaTeamID
local spGetTeamUnits        = Spring.GetTeamUnits
local spGetUnitDefID        = Spring.GetUnitDefID
local spGetUnitPosition     = Spring.GetUnitPosition
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spIsPosInLos          = Spring.IsPosInLos
local spGetGroundHeight     = Spring.GetGroundHeight
local spGetGameSeconds      = Spring.GetGameSeconds
local spGetGameFrame        = Spring.GetGameFrame
local spIsGUIHidden         = Spring.IsGUIHidden
local spEcho                = Spring.Echo

local glColor      = gl.Color
local glVertex     = gl.Vertex
local glBeginEnd   = gl.BeginEnd
local glLineWidth  = gl.LineWidth
local glDepthTest  = gl.DepthTest
local glPushMatrix = gl.PushMatrix
local glPopMatrix  = gl.PopMatrix
local glTranslate  = gl.Translate
local glScale      = gl.Scale
local GL_LINES, GL_TRIANGLES, GL_QUADS = GL.LINES, GL.TRIANGLES, GL.QUADS

local floor, ceil, max, min, abs, sqrt, exp, sin, cos = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt, math.exp, math.sin, math.cos
local clock = os.clock
local TWO_PI = 2 * math.pi

-- Settings --------------------------------------------------------------------
local cfg = {
	enabled = true,
	lines   = true,
	arrows  = true,
	minimap = true,
	heat    = false,
	trail   = true,
	instab  = true,
	alerts  = true,
	sens    = 5,            -- 1..5
	window  = 12,           -- seconds the trend / slow map remembers
}

local REFRESH     = 0.25     -- real seconds between recalculationsR
local TAU_FAST    = 1.0     -- game seconds smoothing of the "current" map
local GHOST_TTL   = 5      -- game seconds before a hidden mobile enemy is forgotten
local RADAR_W     = 150     -- strength given to an unidentified radar blip
local RADAR_R     = 450
local DMAX        = 2500    -- cap on a single segment's measured push (elmos)

local HALO_W      = 0.25    -- buildings: weight of the weak, wide halo ...
local HALO_RF     = 2.4     -- ... and its radius multiplier (lets spread bases count)
local TRAIL_HL    = 7      -- game seconds for trail heat to halve
local INSTAB_TAU  = 40      -- game seconds of memory for ownership flips
local FLIP_DEAD   = 0.08    -- control must cross this band to count as a side change
local UNSTABLE_AT = 1.2     -- a cell is "unstable" above this flip score
local BREAK_MULT  = 2.5     -- breakthrough: one refresh moves the front this many T_SHIFTs
local BREAK_COOL  = 10      -- game seconds between alerts in one region
local STALE_T     = 40      -- game seconds a stalemate arrow lingers after the last push
local RING_LIFE   = 3.5     -- real seconds an alert ring lives
local MAXRING     = 8
local RING_SEG    = 24

-- sensitivity presets: how far the line must have moved (elmos), how much strength
-- both sides need near the line, and how much front length a region needs (x bin size)
local SENS = {
	{ shift = 650, side = 300, len = 1.2 },
	{ shift = 450, side = 200, len = 0.8 },
	{ shift = 300, side = 120, len = 0.5 },
	{ shift = 200, side =  75, len = 0.3 },
	{ shift = 120, side =  35, len = 0.18 },
}
local T_SHIFT, MIN_SIDE, MIN_LEN = 500, 150, 1000   -- set by applySens()

--------------------------------------------------------------------------------
-- Map grid and region bins (allocated once)
--------------------------------------------------------------------------------

local mapX, mapZ = Game.mapSizeX, Game.mapSizeZ
local mapMax = max(mapX, mapZ)

local CELL = max(128, 16 * ceil(mapMax / 96 / 16))
local GX, GZ = ceil(mapX / CELL), ceil(mapZ / CELL)
local N = GX * GZ

local BINSIZE = CELL * ceil(1400 / CELL)
local NBX, NBZ = ceil(mapX / BINSIZE), ceil(mapZ / BINSIZE)
local NB = NBX * NBZ

local function newArray(n, v)
	local t = {}
	for i = 1, n do t[i] = v end
	return t
end

-- raw strength this refresh
local own, foe = newArray(N, 0), newArray(N, 0)
-- fast (current) and slow (remembered) smoothed strength
local ownF, foeF = newArray(N, 0), newArray(N, 0)
local ownS, foeS = newArray(N, 0), newArray(N, 0)
-- control maps in [-1, 1]  (+ = you, - = enemy)
local ctrlF, ctrlS = newArray(N, 0), newArray(N, 0)
-- trail heat, ownership-flip memory, last settled side per cell
local trail, instab, sgn = newArray(N, 0), newArray(N, 0), newArray(N, 0)
local cellH = nil                                    -- ground height per grid CORNER (overlays)
local CW = GX + 1                                    -- corners per row
local prevC = newArray(N, 0)                         -- last control value per cell (movement)

-- draws one overlay quad using the ground height at each of its four corners
local function cornerQuad(i, j)
	local a = j * CW + i + 1
	local b, c, d = a + 1, a + CW + 1, a + CW
	local x0, z0 = i * CELL, j * CELL
	local x1, z1 = x0 + CELL, z0 + CELL
	glVertex(x0, cellH[a], z0); glVertex(x1, cellH[b], z0)
	glVertex(x1, cellH[c], z1); glVertex(x0, cellH[d], z1)
end

-- which region each cell belongs to, and how many cells each region has
local cellReg = newArray(N, 0)
local rCells  = newArray(NB, 0)
local rUnst   = newArray(NB, 0)
local rInst   = newArray(NB, 0)                      -- fraction of unstable cells per region
for j = 0, GZ - 1 do
	for i = 0, GX - 1 do
		local bi = min(NBX - 1, floor((i * CELL + CELL * 0.5) / BINSIZE))
		local bj = min(NBZ - 1, floor((j * CELL + CELL * 0.5) / BINSIZE))
		local b = bj * NBX + bi + 1
		cellReg[j * GX + i + 1] = b
		rCells[b] = rCells[b] + 1
	end
end

-- smooths the fast control map with a separable [1 2 1] blur (x then y). The front
-- is extracted from this map, so its contour loses most of the per-cell zigzag.
local ctrlTmp = newArray(N, 0)
local function smoothControl()
	for k = 1, N do ctrlTmp[k] = ctrlF[k] end
	for j = 0, GZ - 1 do
		local row = j * GX + 1
		for i = 1, GX - 2 do
			local idx = row + i
			ctrlTmp[idx] = 0.25 * ctrlF[idx - 1] + 0.5 * ctrlF[idx] + 0.25 * ctrlF[idx + 1]
		end
	end
	for j = 1, GZ - 2 do
		local row = j * GX + 1
		for i = 0, GX - 1 do
			local idx = row + i
			ctrlF[idx] = 0.25 * ctrlTmp[idx - GX] + 0.5 * ctrlTmp[idx] + 0.25 * ctrlTmp[idx + GX]
		end
	end
end

-- frontline segments (world coords, y cached)
local MAXSEG = N * 2
local segX1, segZ1, segY1 = newArray(MAXSEG, 0), newArray(MAXSEG, 0), newArray(MAXSEG, 0)
local segX2, segZ2, segY2 = newArray(MAXSEG, 0), newArray(MAXSEG, 0), newArray(MAXSEG, 0)
local segCount = 0

-- per-region accumulators (reset every refresh)
local accLen, accD, accX, accZ, accNX, accNZ =
	newArray(NB, 0), newArray(NB, 0), newArray(NB, 0), newArray(NB, 0), newArray(NB, 0), newArray(NB, 0)

-- per-region persistent state
local bEma      = newArray(NB, 0)       -- fast momentum (smoothed push, elmos)
local bSlow     = newArray(NB, 0)       -- slow trend (smoothed push, elmos)
local bState    = newArray(NB, 0)       -- +1 advancing, -1 pushed back, 0 none
local bDir      = newArray(NB, 0)       -- last settled direction (+1 / -1), persists through stalemates
local bLastStrong = newArray(NB, -1e9)  -- game second of the last sustained push
local bCool     = newArray(NB, -1e9)    -- game second of the last breakthrough alert
local bRev      = newArray(NB, -1e9)    -- real clock time of the last counterattack reversal
local bAX, bAZ  = newArray(NB, 0), newArray(NB, 0)   -- smoothed anchor on the front
local bNX, bNZ  = newArray(NB, 0), newArray(NB, 0)   -- smoothed unit normal pointing toward the enemy
local bValid    = newArray(NB, false)

-- arrows to draw this frame
local aX, aZ, aDX, aDZ, aLen = newArray(NB, 0), newArray(NB, 0), newArray(NB, 0), newArray(NB, 0), newArray(NB, 0)
local aGain  = newArray(NB, true)
local aWidth, aSpeed, aAmp, aAlpha = newArray(NB, 1), newArray(NB, 1), newArray(NB, 0), newArray(NB, 1)
local aKind  = newArray(NB, 0)          -- 0 normal, 1 stalemate (faint), 2 counterattack flash
local nArrows = 0

-- breakthrough rings (expanding pulses)
local rgX, rgZ = newArray(MAXRING, 0), newArray(MAXRING, 0)
local rgT0     = newArray(MAXRING, -1e9)
local rgGain   = newArray(MAXRING, true)

local ARROW_BASE = max(300, mapMax * 0.022)

--------------------------------------------------------------------------------
-- Unit weights (computed once)
--------------------------------------------------------------------------------

-- w = ground-holding strength, r = influence radius, static = never moves
local defs = {}
for defID, ud in pairs(UnitDefs) do
	local cp         = ud.customParams or {}
	local cost       = ud.metalCost or 0
	local mobile     = (ud.speed or 0) > 0
	local hasWeapons = ud.weapons and #ud.weapons > 0
	local isBuilder  = ud.isBuilder and (ud.buildSpeed or 0) > 0

	local w, r = 0, 0
	if cp.iscommander ~= nil then
		w, r = 500, 450
	elseif mobile then
		-- constructors, scouts without guns, transports... hold no ground
		if hasWeapons and not isBuilder then
			w, r = min(cost, 6000), 450
			if ud.canFly then w = w * 0.35 end        -- aircraft pass over, they don't hold
		end
	else
		-- every building counts as a unit now; the floors keep cheap ones visible
		if ud.isFactory then
			w, r = max(120, min(cost, 1500) * 0.25), 400
		elseif hasWeapons then
			w, r = min(cost, 4000), 550               -- defences really do hold ground
		elseif isBuilder then
			w, r = max(60, min(cost, 800) * 0.2), 350 -- nano turrets
		else
			w, r = max(40, min(cost, 2000) * 0.25), 380   -- eco / utility / walls
		end
	end
	defs[defID] = { w = w, r = r, static = not mobile }
end

--------------------------------------------------------------------------------
-- Teams
--------------------------------------------------------------------------------

local alliedTeams, nAllied = {}, 0
local enemyTeams, nEnemy   = {}, 0
local enemyFlag = {}                 -- enemyFlag[teamID] = true for enemy teams
local myAllyTeam = 0
local lastTeamRefresh = -999

local function refreshTeams()
	nAllied, nEnemy = 0, 0
	for k in pairs(enemyFlag) do enemyFlag[k] = nil end
	myAllyTeam = spGetMyAllyTeamID()
	local gaia = spGetGaiaTeamID()
	local list = spGetTeamList()
	for i = 1, #list do
		local t = list[i]
		if t ~= gaia then
			local _, _, isDead, _, _, allyT = spGetTeamInfo(t, false)
			if not isDead then
				if allyT == myAllyTeam then
					nAllied = nAllied + 1
					alliedTeams[nAllied] = t
				else
					nEnemy = nEnemy + 1
					enemyTeams[nEnemy] = t
					enemyFlag[t] = true
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Enemy memory ("ghosts"), pooled
--------------------------------------------------------------------------------

local foes = {}                      -- unitID -> entry
local entryPool, nPool = {}, 0
local stamp = 0

local function takeEntry()
	if nPool > 0 then
		local e = entryPool[nPool]
		entryPool[nPool] = nil
		nPool = nPool - 1
		return e
	end
	return { x = 0, z = 0, w = 0, r = 0, static = false, t = 0, stamp = 0 }
end

local function dropFoe(uid)
	local e = foes[uid]
	if e then
		foes[uid] = nil
		nPool = nPool + 1
		entryPool[nPool] = e
	end
end

-- record / update an enemy unit we can currently see (LOS or radar)
local function observe(uid, stampVal, gs)
	local defID = spGetUnitDefID(uid)
	local info = defID and defs[defID]
	local w, r, static
	if info then
		w, r, static = info.w, info.r, info.static
		if static and w > 0 and (spGetUnitIsBeingBuilt(uid)) then w = 0 end   -- unfinished building
	else
		w, r, static = RADAR_W, RADAR_R, false                                -- unidentified radar blip
	end
	if w <= 0 then
		dropFoe(uid)
		return
	end
	local x, _, z = spGetUnitPosition(uid)
	if not x then return end
	local e = foes[uid]
	if not e then
		e = takeEntry()
		foes[uid] = e
	end
	e.x, e.z, e.w, e.r, e.static = x, z, w, r, static
	e.t, e.stamp = gs, stampVal
end

--------------------------------------------------------------------------------
-- Influence splatting
--------------------------------------------------------------------------------

local function splat(arr, x, z, w, r)
	local gx0 = max(0, floor((x - r) / CELL))
	local gx1 = min(GX - 1, floor((x + r) / CELL))
	local gz0 = max(0, floor((z - r) / CELL))
	local gz1 = min(GZ - 1, floor((z + r) / CELL))
	local r2 = r * r
	for j = gz0, gz1 do
		local dz = (j + 0.5) * CELL - z
		local dz2 = dz * dz
		local row = j * GX + 1
		for i = gx0, gx1 do
			local dx = (i + 0.5) * CELL - x
			local d2 = dx * dx + dz2
			if d2 < r2 then
				local idx = row + i
				arr[idx] = arr[idx] + w * (1 - d2 / r2)
			end
		end
	end
end

-- a unit, plus (for buildings) its weak, far-reaching halo
local function splatUnit(arr, x, z, w, r, static)
	splat(arr, x, z, w, r)
	if static then splat(arr, x, z, w * HALO_W, r * HALO_RF) end
end

--------------------------------------------------------------------------------
-- Frontline extraction (marching squares on the fast control map)
--------------------------------------------------------------------------------

local function groundY(x, z)
	return max(spGetGroundHeight(x, z), 0) + 12
end

local function addSegment(x1, z1, x2, z2, x0, z0, i00, i10, i01, i11)
	if segCount >= MAXSEG then return end

	local v00, v10, v01, v11 = ctrlF[i00], ctrlF[i10], ctrlF[i01], ctrlF[i11]
	local gx = ((v10 + v11) - (v00 + v01)) / (2 * CELL)
	local gz = ((v01 + v11) - (v00 + v10)) / (2 * CELL)
	local gm = sqrt(gx * gx + gz * gz)

	-- store the line segment for drawing
	segCount = segCount + 1
	segX1[segCount], segZ1[segCount], segY1[segCount] = x1, z1, groundY(x1, z1)
	segX2[segCount], segZ2[segCount], segY2[segCount] = x2, z2, groundY(x2, z2)

	-- movement measurement needs a usable gradient and a remembered map with substance
	if gm < 1e-6 then return end
	local slowMass = (ownS[i00] + ownS[i10] + ownS[i01] + ownS[i11] + foeS[i00] + foeS[i10] + foeS[i01] + foeS[i11]) * 0.25
	if slowMass < MIN_SIDE * 1.5 then return end

	local mx, mz = (x1 + x2) * 0.5, (z1 + z2) * 0.5
	local fx, fz = (mx - x0) / CELL, (mz - z0) / CELL
	local cS = (1 - fx) * (1 - fz) * ctrlS[i00] + fx * (1 - fz) * ctrlS[i10]
	         + (1 - fx) * fz * ctrlS[i01] + fx * fz * ctrlS[i11]

	-- the old map at the current front position says how far the front moved:
	--   old control < 0 there  -> that spot used to be enemy ground -> we gained
	local d = -cS / gm
	if d > DMAX then d = DMAX elseif d < -DMAX then d = -DMAX end

	local dx, dz = x2 - x1, z2 - z1
	local len = sqrt(dx * dx + dz * dz)

	local bi = min(NBX - 1, max(0, floor(mx / BINSIZE)))
	local bj = min(NBZ - 1, max(0, floor(mz / BINSIZE)))
	local b = bj * NBX + bi + 1
	accLen[b] = accLen[b] + len
	accD[b]   = accD[b]   + d * len
	accX[b]   = accX[b]   + mx * len
	accZ[b]   = accZ[b]   + mz * len
	accNX[b]  = accNX[b]  - (gx / gm) * len        -- normal pointing toward the enemy
	accNZ[b]  = accNZ[b]  - (gz / gm) * len
end

local function buildFront()
	segCount = 0
	for b = 1, NB do
		accLen[b], accD[b], accX[b], accZ[b], accNX[b], accNZ[b] = 0, 0, 0, 0, 0, 0
	end

	for j = 0, GZ - 2 do
		local z0 = (j + 0.5) * CELL
		for i = 0, GX - 2 do
			local i00 = j * GX + i + 1
			local i10, i01, i11 = i00 + 1, i00 + GX, i00 + GX + 1
			local v00, v10, v01, v11 = ctrlF[i00], ctrlF[i10], ctrlF[i01], ctrlF[i11]
			local p00, p10, p01, p11 = v00 > 0, v10 > 0, v01 > 0, v11 > 0

			if not (p00 == p10 and p10 == p01 and p01 == p11) then
				-- both sides must have real strength around here, otherwise there's no "front"
				local ao = (ownF[i00] + ownF[i10] + ownF[i01] + ownF[i11]) * 0.25
				local af = (foeF[i00] + foeF[i10] + foeF[i01] + foeF[i11]) * 0.25
				if ao >= MIN_SIDE and af >= MIN_SIDE then
					local x0 = (i + 0.5) * CELL
					local x1, z1 = x0 + CELL, z0 + CELL

					-- edge crossings: B (00-10), R (10-11), T (01-11), L (00-01)
					local hasB, hasR, hasT, hasL = p00 ~= p10, p10 ~= p11, p01 ~= p11, p00 ~= p01
					local bx, bz, rx, rz, tx, tz, lx, lz
					if hasB then bx, bz = x0 + v00 / (v00 - v10) * CELL, z0 end
					if hasR then rx, rz = x1, z0 + v10 / (v10 - v11) * CELL end
					if hasT then tx, tz = x0 + v01 / (v01 - v11) * CELL, z1 end
					if hasL then lx, lz = x0, z0 + v00 / (v00 - v01) * CELL end

					local n = (hasB and 1 or 0) + (hasR and 1 or 0) + (hasT and 1 or 0) + (hasL and 1 or 0)
					if n == 2 then
						local ax, az, cx, cz
						if hasB then ax, az = bx, bz end
						if hasR then if ax then cx, cz = rx, rz else ax, az = rx, rz end end
						if hasT then if ax then cx, cz = tx, tz else ax, az = tx, tz end end
						if hasL then cx, cz = lx, lz end
						addSegment(ax, az, cx, cz, x0, z0, i00, i10, i01, i11)
					elseif n == 4 then
						local center = (v00 + v10 + v01 + v11) * 0.25
						if (center > 0) == p00 then
							addSegment(bx, bz, rx, rz, x0, z0, i00, i10, i01, i11)
							addSegment(lx, lz, tx, tz, x0, z0, i00, i10, i01, i11)
						else
							addSegment(bx, bz, lx, lz, x0, z0, i00, i10, i01, i11)
							addSegment(rx, rz, tx, tz, x0, z0, i00, i10, i01, i11)
						end
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Momentum: arrows, stalemates, counterattacks, breakthrough rings
--------------------------------------------------------------------------------

local function spawnRing(x, z, gain)
	-- reuse the oldest slot
	local slot, oldest = 1, math.huge
	for k = 1, MAXRING do
		if rgT0[k] < oldest then oldest, slot = rgT0[k], k end
	end
	rgX[slot], rgZ[slot], rgT0[slot], rgGain[slot] = x, z, clock(), gain
end

local function pushArrow(b, dirSign, len, width, speed, amp, alpha, kind)
	nArrows = nArrows + 1
	local k = nArrows
	aLen[k] = len
	aX[k], aZ[k] = bAX[b], bAZ[b]
	if dirSign > 0 then
		aDX[k], aDZ[k], aGain[k] = bNX[b], bNZ[b], true           -- out, toward the enemy
	else
		aDX[k], aDZ[k], aGain[k] = -bNX[b], -bNZ[b], false        -- in, toward you
	end
	aWidth[k], aSpeed[k], aAmp[k], aAlpha[k], aKind[k] = width, speed, amp, alpha, kind
end

local function updateArrows(gs, dtg)
	nArrows = 0
	local onT, offT = T_SHIFT, T_SHIFT * 0.6
	local aSlow = 1 - exp(-dtg / cfg.window)
	local now = clock()

	for b = 1, NB do
		local len = accLen[b]
		local ema = bEma[b]

		if len >= MIN_LEN then
			local avgD = accD[b] / len
			ema = ema + 0.35 * (avgD - ema)

			local nx, nz = accNX[b] / len, accNZ[b] / len
			local nm = sqrt(nx * nx + nz * nz)
			if nm > 0.05 then
				nx, nz = nx / nm, nz / nm
				local ax, az = accX[b] / len, accZ[b] / len
				if not bValid[b] or bState[b] == 0 then
					bAX[b], bAZ[b], bNX[b], bNZ[b] = ax, az, nx, nz
					bValid[b] = true
				else
					bAX[b] = bAX[b] + 0.3 * (ax - bAX[b])
					bAZ[b] = bAZ[b] + 0.3 * (az - bAZ[b])
					local sx, sz = bNX[b] + 0.3 * (nx - bNX[b]), bNZ[b] + 0.3 * (nz - bNZ[b])
					local sm = sqrt(sx * sx + sz * sz)
					if sm > 0.01 then bNX[b], bNZ[b] = sx / sm, sz / sm end
				end
			end

			-- major breakthrough: one refresh where a real front jumped a huge distance
			if cfg.alerts and abs(avgD) >= BREAK_MULT * onT and gs - bCool[b] > BREAK_COOL then
				bCool[b] = gs
				spawnRing(accX[b] / len, accZ[b] / len, avgD > 0)
			end
		else
			ema = ema * 0.7           -- not enough front here: let any old momentum fade out
		end
		bEma[b] = ema
		bSlow[b] = bSlow[b] + aSlow * (ema - bSlow[b])

		-- hysteresis: easy to keep an arrow once shown, hard to get one in the first place.
		-- A flip straight from one side to the other counts as a counterattack.
		local s = bState[b]
		if s == 0 then
			if ema >= onT then s = 1 elseif ema <= -onT then s = -1 end
		elseif s > 0 then
			if ema <= -onT then s = -1 elseif ema < offT then s = 0 end
		else
			if ema >= onT then s = 1 elseif ema > -offT then s = 0 end
		end
		bState[b] = s

		if s ~= 0 then
			if bDir[b] ~= 0 and s ~= bDir[b] then bRev[b] = now end
			bDir[b] = s
			bLastStrong[b] = gs
		end

		if s ~= 0 and bValid[b] then
			-- momentum decides the look: intensity -> thickness, rapid -> fast pulse
			local intensity = min(3, abs(ema) / onT)
			local rapid = min(1, max(0, (intensity - 1) / 2))
			local mag = min(2.5, max(0, (abs(ema) - onT) / onT))
			local kind = (now - bRev[b] < 2) and 2 or 0
			pushArrow(b, s, ARROW_BASE * (1 + mag), 0.55 + 0.45 * intensity,
				3 + 7 * rapid, 0.05 + 0.2 * rapid, 1, kind)
		elseif s == 0 and cfg.instab and bValid[b] and bDir[b] ~= 0
			and rInst[b] > 0.25 and gs - bLastStrong[b] < STALE_T then
			-- stalemate: contested ground that isn't moving; faint, fading with time
			local fade = 1 - (gs - bLastStrong[b]) / STALE_T
			pushArrow(b, bDir[b], ARROW_BASE * 0.8, 0.5, 1.5, 0.03, 0.3 * fade, 1)
		end
	end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local needInit = true
local lastGS = 0
local acc = 0

local function applySens()
	local p = SENS[cfg.sens] or SENS[3]
	T_SHIFT, MIN_SIDE, MIN_LEN = p.shift, p.side, p.len * BINSIZE
end

local function resetState()
	needInit = true
	segCount, nArrows = 0, 0
	for b = 1, NB do
		bEma[b], bSlow[b], bState[b], bDir[b], bValid[b] = 0, 0, 0, 0, false
		bLastStrong[b], bCool[b], bRev[b] = -1e9, -1e9, -1e9
	end
	for i = 1, N do
		trail[i], instab[i], sgn[i] = 0, 0, 0
	end
	for k = 1, MAXRING do rgT0[k] = -1e9 end
end

local function refresh()
	local gs = spGetGameSeconds()
	local dtg = gs - lastGS
	if not needInit and dtg < 0.2 then return end      -- game paused
	if dtg < 0.5 then dtg = 0.5 end

	if gs - lastTeamRefresh > 5 then
		refreshTeams()
		lastTeamRefresh = gs
	end
	lastGS = gs

	for i = 1, N do own[i] = 0; foe[i] = 0 end

	-- your side (buildings included, with their halos) ----------------------------------
	for ti = 1, nAllied do
		local units = spGetTeamUnits(alliedTeams[ti])
		if units then
			for k = 1, #units do
				local uid = units[k]
				local defID = spGetUnitDefID(uid)
				local info = defID and defs[defID]
				if info and info.w > 0 and not (info.static and (spGetUnitIsBeingBuilt(uid))) then
					local x, _, z = spGetUnitPosition(uid)
					if x then splatUnit(own, x, z, info.w, info.r, info.static) end
				end
			end
		end
	end

	-- enemies: what we see now + what we remember ------------------------------------
	stamp = stamp + 1
	for ti = 1, nEnemy do
		local units = spGetTeamUnits(enemyTeams[ti])
		if units then
			for k = 1, #units do observe(units[k], stamp, gs) end
		end
	end

	for uid, e in pairs(foes) do
		if e.stamp ~= stamp then
			local vx = spGetUnitPosition(uid)
			if vx then
				observe(uid, stamp, gs)
			else
				local age = gs - e.t
				if (not e.static) and age > GHOST_TTL then
					dropFoe(uid)
				elseif spIsPosInLos(e.x, spGetGroundHeight(e.x, e.z), e.z, myAllyTeam) then
					dropFoe(uid)                         -- we can see the spot and it's empty: it's gone
				else
					local w = e.w
					if not e.static then w = w * max(0.25, 1 - age / GHOST_TTL) end
					splatUnit(foe, e.x, e.z, w, e.r, e.static)
				end
			end
		end
	end
	for uid, e in pairs(foes) do
		if e.stamp == stamp then splatUnit(foe, e.x, e.z, e.w, e.r, e.static) end
	end

	-- smoothing + control maps --------------------------------------------------------------
	local firstRun = needInit
	local aF = 1 - exp(-dtg / TAU_FAST)
	local aS = 1 - exp(-dtg / cfg.window)
	for i = 1, N do
		local o, f = own[i], foe[i]
		local of, ff, os, fs
		if needInit then
			of, ff, os, fs = o, f, o, f
		else
			of = ownF[i] + aF * (o - ownF[i])
			ff = foeF[i] + aF * (f - foeF[i])
			os = ownS[i] + aS * (o - ownS[i])
			fs = foeS[i] + aS * (f - foeS[i])
		end
		ownF[i], foeF[i], ownS[i], foeS[i] = of, ff, os, fs
		ctrlF[i] = (of - ff) / (of + ff + 1)
		ctrlS[i] = (os - fs) / (os + fs + 1)
	end
	needInit = false

	smoothControl()
	smoothControl()

	-- trails and instability, per cell ---------------------------------------------------------
	local dT = exp(-dtg * 0.693147 / TRAIL_HL)       -- half-life decay
	local dI = exp(-dtg / INSTAB_TAU)
	for i = 1, N do
		local c = ctrlF[i]
		local s = sgn[i]
		local flip = 0
		if c > FLIP_DEAD then
			if s == -1 then flip = 1 end
			s = 1
		elseif c < -FLIP_DEAD then
			if s == 1 then flip = 1 end
			s = -1
		end
		sgn[i] = s
		instab[i] = instab[i] * dI + flip

		-- trail: heat from ground that is actually changing hands, with a deadband so
		-- small wobble along a static front leaves nothing behind
		local dc = 0
		if not firstRun then dc = abs(c - prevC[i]) end
		prevC[i] = c
		local mv = dc - 0.03
		if mv < 0 then mv = 0 end
		trail[i] = trail[i] * dT + min(0.5, mv * 5)
	end

	-- region instability = fraction of its cells that keep flipping
	for b = 1, NB do rUnst[b] = 0 end
	for i = 1, N do
		if instab[i] >= UNSTABLE_AT then
			local b = cellReg[i]
			rUnst[b] = rUnst[b] + 1
		end
	end
	for b = 1, NB do
		rInst[b] = rCells[b] > 0 and rUnst[b] / rCells[b] or 0
	end

	buildFront()
	updateArrows(gs, dtg)
end

--------------------------------------------------------------------------------
-- Drawing (module-level emitters: nothing is allocated per frame)
--------------------------------------------------------------------------------

local scaleMul = 1
local dark = false

local function emitLinesWorld()
	for i = 1, segCount do
		glVertex(segX1[i], segY1[i], segZ1[i])
		glVertex(segX2[i], segY2[i], segZ2[i])
	end
end

local function emitLinesMini()
	for i = 1, segCount do
		glVertex(segX1[i], segZ1[i])
		glVertex(segX2[i], segZ2[i])
	end
end

local function vtx(x, z)
	glVertex(x, groundY(x, z), z)
end

local function emitArrowsWorld()
	local now = clock()
	for i = 1, nArrows do
		local speed = aSpeed[i]
		local pv = 1 + aAmp[i] * sin(now * speed)            -- pulse: arrow swells and retracts
		local L = aLen[i] * pv * scaleMul
		local dx, dz = aDX[i], aDZ[i]
		local px, pz = -dz, dx
		local shove = sin(now * speed * 0.8) * (L * 0.12)    -- forward push
		local cx, cz = aX[i] + dx * shove, aZ[i] + dz * shove
		local wd = aWidth[i]
		local sw, hw, hl = L * 0.07 * wd, L * 0.21 * wd, L * 0.42
		local sx, sz = cx - dx * L * 0.5, cz - dz * L * 0.5          -- tail
		local ex, ez = cx + dx * L * 0.5, cz + dz * L * 0.5          -- tip
		local bx, bz = ex - dx * hl, ez - dz * hl                    -- head base

		if dark then
			glColor(0, 0, 0, 0.55 * aAlpha[i])
		else
			local r, g, bl
			if aGain[i] then r, g, bl = 0.25, 0.6, 1.0 else r, g, bl = 1.0, 0.25, 0.2 end
			if aKind[i] == 2 then                                   -- counterattack flash
				r, g, bl = r + (1 - r) * 0.5, g + (1 - g) * 0.5, bl + (1 - bl) * 0.5
			end
			glColor(r, g, bl, aAlpha[i] * (0.8 + 0.2 * sin(now * speed * 1.3)))
		end

		-- shaft (two triangles)
		vtx(sx + px * sw, sz + pz * sw); vtx(sx - px * sw, sz - pz * sw); vtx(bx - px * sw, bz - pz * sw)
		vtx(sx + px * sw, sz + pz * sw); vtx(bx - px * sw, bz - pz * sw); vtx(bx + px * sw, bz + pz * sw)
		-- head
		vtx(bx + px * hw, bz + pz * hw); vtx(bx - px * hw, bz - pz * hw); vtx(ex, ez)
	end
end

local function emitArrowsMini()
	local Lmin = mapMax * 0.07
	local now = clock()
	for i = 1, nArrows do
		if aGain[i] then glColor(0.25, 0.6, 1.0, aAlpha[i]) else glColor(1.0, 0.25, 0.2, aAlpha[i]) end
		local L = max(aLen[i], Lmin) * (1 + aAmp[i] * sin(now * aSpeed[i]))
		local dx, dz = aDX[i], aDZ[i]
		local px, pz = -dz, dx
		local sx, sz = aX[i] - dx * L * 0.5, aZ[i] - dz * L * 0.5
		local ex, ez = aX[i] + dx * L * 0.5, aZ[i] + dz * L * 0.5
		local hl, hw = L * 0.4, L * 0.25
		glVertex(sx, sz); glVertex(ex, ez)
		glVertex(ex, ez); glVertex(ex - dx * hl + px * hw, ez - dz * hl + pz * hw)
		glVertex(ex, ez); glVertex(ex - dx * hl - px * hw, ez - dz * hl - pz * hw)
	end
end

-- expanding breakthrough pulses (world)
local function emitRingsWorld()
	local now = clock()
	for k = 1, MAXRING do
		local age = now - rgT0[k]
		if age >= 0 and age < RING_LIFE then
			local p = age / RING_LIFE
			local R = ARROW_BASE * (1.5 + 5 * p)
			local a = 1 - p
			if rgGain[k] then glColor(0.25, 0.6, 1.0, 0.85 * a) else glColor(1.0, 0.25, 0.2, 0.85 * a) end
			local cx, cz = rgX[k], rgZ[k]
			for s = 0, RING_SEG - 1 do
				local a0 = s * TWO_PI / RING_SEG
				local a1 = (s + 1) * TWO_PI / RING_SEG
				vtx(cx + cos(a0) * R, cz + sin(a0) * R)
				vtx(cx + cos(a1) * R, cz + sin(a1) * R)
			end
		end
	end
end

local function emitRingsMini()
	local now = clock()
	for k = 1, MAXRING do
		local age = now - rgT0[k]
		if age >= 0 and age < RING_LIFE then
			local p = age / RING_LIFE
			local R = ARROW_BASE * (1.5 + 5 * p)
			local a = 1 - p
			if rgGain[k] then glColor(0.25, 0.6, 1.0, 0.85 * a) else glColor(1.0, 0.25, 0.2, 0.85 * a) end
			local cx, cz = rgX[k], rgZ[k]
			for s = 0, RING_SEG - 1 do
				local a0 = s * TWO_PI / RING_SEG
				local a1 = (s + 1) * TWO_PI / RING_SEG
				glVertex(cx + cos(a0) * R, cz + sin(a0) * R)
				glVertex(cx + cos(a1) * R, cz + sin(a1) * R)
			end
		end
	end
end

local function emitHeat()
	local heatMin = MIN_SIDE * 0.5
	for j = 0, GZ - 1 do
		local z0 = j * CELL
		for i = 0, GX - 1 do
			local idx = j * GX + i + 1
			if ownF[idx] + foeF[idx] >= heatMin then
				local c = ctrlF[idx]
				local a = 0.10 + 0.25 * abs(c)
				if c > 0 then glColor(0.2, 0.6, 1.0, a) else glColor(1.0, 0.3, 0.2, a) end
				cornerQuad(i, j)
			end
		end
	end
end

-- heat trail left behind by fighting; dissipates over time
local function emitTrail()
	for j = 0, GZ - 1 do
		local z0 = j * CELL
		for i = 0, GX - 1 do
			local idx = j * GX + i + 1
			local t = trail[idx]
			if t > 0.12 then
				glColor(0.85, 0.7, 0.45, min(0.3, t * 0.2))
				cornerQuad(i, j)
			end
		end
	end
end

-- cells whose ownership keeps flipping: flash
local function emitInstab()
	local pulseI = 0.5 + 0.5 * sin(clock() * 5)
	for j = 0, GZ - 1 do
		local z0 = j * CELL
		for i = 0, GX - 1 do
			local idx = j * GX + i + 1
			local f = instab[idx]
			if f >= UNSTABLE_AT then
				glColor(1.0, 0.9, 0.3, (0.12 + 0.25 * pulseI) * min(1, f / 3))
				cornerQuad(i, j)
			end
		end
	end
end

local function ensureCellHeights()
	if cellH then return end
	cellH = newArray(CW * (GZ + 1), 0)
	for j = 0, GZ do
		for i = 0, GX do
			cellH[j * CW + i + 1] = groundY(i * CELL, j * CELL) - 4
		end
	end
end

function widget:DrawWorldPreUnit()
	if not cfg.enabled or spIsGUIHidden() then return end

	glDepthTest(true)

	if cfg.heat or cfg.trail or cfg.instab then ensureCellHeights() end
	if cfg.trail then glBeginEnd(GL_QUADS, emitTrail) end
	if cfg.instab then glBeginEnd(GL_QUADS, emitInstab) end
	if cfg.heat then glBeginEnd(GL_QUADS, emitHeat) end

	if cfg.lines and segCount > 0 then
		glLineWidth(8); glColor(0, 0, 0, 0.3)                -- soft shadow
		glBeginEnd(GL_LINES, emitLinesWorld)
		glLineWidth(12); glColor(0.5, 0.8, 1.0, 0.12)        -- outer glow
		glBeginEnd(GL_LINES, emitLinesWorld)
		glLineWidth(6); glColor(0.5, 0.8, 1.0, 0.3)          -- inner glow
		glBeginEnd(GL_LINES, emitLinesWorld)
		glLineWidth(2.5); glColor(0.85, 0.95, 1.0, 0.95)     -- bright core
		glBeginEnd(GL_LINES, emitLinesWorld)
	end

	if cfg.arrows and nArrows > 0 then
		dark, scaleMul = true, 1.3
		glBeginEnd(GL_TRIANGLES, emitArrowsWorld)
		dark, scaleMul = false, 1
		glBeginEnd(GL_TRIANGLES, emitArrowsWorld)
	end

	if cfg.alerts then
		glLineWidth(3)
		glBeginEnd(GL_LINES, emitRingsWorld)
	end

	glLineWidth(1)
	glColor(1, 1, 1, 1)
	glDepthTest(false)
end

function widget:DrawInMiniMap()
	if not cfg.enabled or not cfg.minimap then return end
	if segCount == 0 and nArrows == 0 then return end

	glPushMatrix()
	glTranslate(0, 1, 0)
	glScale(1 / mapX, -1 / mapZ, 1)

	if cfg.lines and segCount > 0 then
		glLineWidth(2.5); glColor(0.35, 0.7, 1.0, 0.95)
		glBeginEnd(GL_LINES, emitLinesMini)
	end
	if cfg.arrows and nArrows > 0 then
		glLineWidth(3)
		glBeginEnd(GL_LINES, emitArrowsMini)
	end
	if cfg.alerts then
		glLineWidth(2)
		glBeginEnd(GL_LINES, emitRingsMini)
	end

	glLineWidth(1)
	glColor(1, 1, 1, 1)
	glPopMatrix()
end

--------------------------------------------------------------------------------
-- Widget callins
--------------------------------------------------------------------------------

function widget:Initialize()
	applySens()
	refreshTeams()
	lastTeamRefresh = spGetGameSeconds()
	resetState()
end

function widget:Shutdown()
	for uid in pairs(foes) do foes[uid] = nil end
	for i = nPool, 1, -1 do entryPool[i] = nil end
	nPool = 0
	segCount, nArrows = 0, 0
end

function widget:PlayerChanged()
	refreshTeams()
	lastTeamRefresh = spGetGameSeconds()
	for uid in pairs(foes) do dropFoe(uid) end
	resetState()
end

function widget:Update(dt)
	if not cfg.enabled then return end
	acc = acc + dt
	if acc >= REFRESH then
		acc = 0
		if spGetGameFrame() > 0 then refresh() end
	end
end

function widget:UnitDestroyed(unitID)
	dropFoe(unitID)
end

-- enemy units popping into vision: remember them immediately
function widget:UnitEnteredLos(unitID, unitTeam)
	if cfg.enabled and enemyFlag[unitTeam] then observe(unitID, stamp, lastGS) end
end

function widget:UnitEnteredRadar(unitID, unitTeam)
	if cfg.enabled and enemyFlag[unitTeam] then observe(unitID, stamp, lastGS) end
end

-- Chat commands ---------------------------------------------------------------------
function widget:TextCommand(command)
	local w1, w2, w3 = command:match("^%s*(%S+)%s*(%S*)%s*(%S*)")
	if not w1 or w1:lower() ~= "frontline" then return false end
	local arg = w2:lower()

	if arg == "" then
		cfg.enabled = not cfg.enabled
		if cfg.enabled then resetState() end
	elseif arg == "help" then
		spEcho("[Frontline] blue arrow = you advancing, red = enemy pushing, thin/steady = slow, thick/fast = rapid,")
		spEcho("[Frontline] faint = stalemate, flash/reversal = counterattack, expanding ring = breakthrough")
		spEcho("[Frontline] /frontline | sens <1-5> | window <10-90> | lines | arrows | minimap | trail | instab | alerts | heat | reset")
	elseif arg == "sens" then
		local n = tonumber(w3)
		if n then
			cfg.sens = max(1, min(5, floor(n + 0.5)))
			applySens()
			spEcho("[Frontline] sensitivity " .. cfg.sens .. ": arrow needs ~" .. T_SHIFT .. " elmo push")
		end
	elseif arg == "window" then
		local n = tonumber(w3)
		if n then cfg.window = max(10, min(90, n)) end
	elseif arg == "lines" then
		cfg.lines = not cfg.lines
	elseif arg == "arrows" then
		cfg.arrows = not cfg.arrows
	elseif arg == "minimap" then
		cfg.minimap = not cfg.minimap
	elseif arg == "trail" then
		cfg.trail = not cfg.trail
	elseif arg == "instab" then
		cfg.instab = not cfg.instab
	elseif arg == "alerts" then
		cfg.alerts = not cfg.alerts
	elseif arg == "heat" then
		cfg.heat = not cfg.heat
	elseif arg == "reset" then
		cfg.enabled, cfg.lines, cfg.arrows, cfg.minimap, cfg.heat = true, true, true, true, false
		cfg.trail, cfg.instab, cfg.alerts = true, true, true
		cfg.sens, cfg.window = 5, 12
		applySens()
		resetState()
	else
		spEcho("[Frontline] /frontline | help | sens <1-5> | window <10-90> | lines | arrows | minimap | trail | instab | alerts | heat | reset")
	end
	return true
end

-- Persist settings between games ---------------------------------------------------------------
function widget:GetConfigData()
	return {
		enabled = cfg.enabled, lines = cfg.lines, arrows = cfg.arrows, minimap = cfg.minimap,
		trail = cfg.trail, instab = cfg.instab, alerts = cfg.alerts,
		sens = cfg.sens, window = cfg.window,
	}
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then return end
	for _, k in ipairs({ "enabled", "lines", "arrows", "minimap", "trail", "instab", "alerts" }) do
		if data[k] ~= nil then cfg[k] = data[k] end
	end
	cfg.sens   = data.sens or cfg.sens
	cfg.window = data.window or cfg.window
end
