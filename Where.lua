-- Where to go and what it gives: every view-model of the journal, the field card and the tracker, as plain tables.
-- Pure and deterministic: no frames and no client calls; the data (Data/Spots.lua, Data/Trainers.lua), the skill, the
-- level, the faction, the player's position and the cost function all come in through one context table, so busted
-- tests it whole. All text the frames show is written here; a frame never builds a sentence.
-- Shapes, the score and every choice made where the design left one open: docs/where-model.md.
--
-- Units. Data positions are map percent (0-100). Everything a view-model carries, and `here`, is normalised (0-1),
-- as C_Map.GetPlayerMapPosition gives it. Distances are yards, from the map's size in Data/Spots.lua (`maps`).
local _, ns = ...
local W = {}
ns.Where = W

W.LOCKPICKING, W.MINING, W.HERBALISM, W.SKINNING, W.FISHING = 633, 186, 182, 393, 356
W.WORLD = { 633, 186, 182, 393, 356 }
W.TOP = 300
W.DEFAULT_BANDS = { yellow = 25, green = 50, grey = 100 }
W.WEIGHT = { orange = 1, yellow = 0.75, green = 0.25, grey = 0, locked = 0 } -- skill-up chance by colour (a guess)
W.SWITCH = 10 -- score points a new spot must lead by before the itinerary moves on
W.FLOOR_GAP = 4 -- yards of height between two floors (docs/spots-data.md)
W.RESPAWN = 300 -- seconds a visited stop stays marked when the data has no respawn time
W.ENTER_PAD, W.LEAVE_PAD = 40, 120 -- yards past the spot's radius: zoom in, zoom back out
W.FISH_CLEAN = 95 -- skill over the zone's base at which no fish get away (cmangos' rule, unconfirmed)
W.LIST_MAX = 8 -- spots listed per bracket
W.YIELD_ROWS = 4 -- yield rows a card shows before "N more"
W.ASPECT = 2 / 3 -- a zone map's height over its width, when its size in yards is not known

-- Eastern Kingdoms = 0, Kalimdor = 1, by uiMap, for "another continent". A map not listed makes no claim.
W.CONTINENT =
	{ [1411] = 1, [1412] = 1, [1413] = 1, [1453] = 0, [1454] = 1, [1455] = 0, [1456] = 1, [1457] = 1, [1458] = 0 }
for map = 1416, 1437 do
	W.CONTINENT[map] = 0
end
for map = 1438, 1452 do
	W.CONTINENT[map] = 1
end

local KIND = {
	lock = { verb = "Open the locks", units = "boxes", icon = "VignetteLoot", stop = "lock" },
	mine = { verb = "Mine the veins", units = "veins", icon = "Professions_Tracking_Ore", stop = "vein" },
	herb = { verb = "Pick the herbs", units = "herbs", icon = "Professions_Tracking_Herb", stop = "herb" },
	skin = { verb = "Skin the beasts", units = "beasts", icon = "VignetteKill", stop = "beast" },
	fish = { verb = "Fish here", units = "pools", icon = "Professions_Tracking_Fish", stop = "water" },
}

-- Every broken or not-now state has its own sentence, naming the link.
W.TEXT = {
	noPosition = "Position hidden here (in an instance). It comes back outside.",
	noPositionShort = "no position",
	noDistance = "no distance",
	noSkill = "Skill unknown until the first skill-up message. Bars show what each needs.",
	classic = "from Classic, unconfirmed",
	classicLong = "Position from Classic data, not yet seen in Forever.",
	approx = "area approximate",
	bands = "Colour bands are the vanilla rule, not yet confirmed in Forever.",
	otherMap = "You are in another zone. The route shows when you arrive.",
	otherContinent = "On another continent: cross by boat or zeppelin first.",
	noFlight = "No flight point known for your side.",
	combat = "Target after the fight",
	notLearned = "not learned",
	newTarget = "new in Forever, position not known yet",
	poolsUnknown = "how many are up at once: not known",
	noErrand = "Nothing to fetch right now.",
}

local function secret(v)
	return issecretvalue ~= nil and v ~= nil and issecretvalue(v)
end

local function num(v)
	if secret(v) then
		return nil
	end
	return type(v) == "number" and v == v and v or nil
end

local function round(n)
	return math.floor(n + 0.5)
end

-- 1150 -> "1,150"
function W.int(n)
	local s = tostring(math.abs(round(n)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (n < 0 and round(n) ~= 0) and ("-" .. out) or out
end

-- Yards as text: whole yards under 50, fives under 1,000, tens above ("38 yd", "215 yd", "1,150 yd"). nil for nil.
function W.yd(n)
	n = num(n)
	if not n then
		return nil
	end
	if n >= 1000 then
		n = round(n / 10) * 10
	elseif n >= 50 then
		n = round(n / 5) * 5
	end
	return W.int(n) .. " yd"
end

-- "3:40"
function W.clock(sec)
	sec = math.max(0, round(sec or 0))
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function plural(n, one, many)
	return ("%d %s"):format(n, n == 1 and one or (many or (one .. "s")))
end

------------------------------------------------------------------------------------------------------ the context

-- The context every builder takes. ctx = { data (ns.Data.spots), line, skill, cap, level, faction ("A" | "H"),
-- class, here = { map, x, y } normalised or nil, hereWhy, maps (override of data.maps: { [map] = { w, h } }),
-- confirmed = { [spot id] = true }, continentOf = { [map] = id }, selected (spot id), mode, money = fn(copper) }.
-- Secret or missing numbers become nil; nothing here fails on them.
function W.query(ctx)
	if type(ctx) == "table" and ctx._q then
		return ctx
	end
	ctx = type(ctx) == "table" and ctx or {}
	local data = type(ctx.data) == "table" and ctx.data or {}
	local q = { _q = true, data = data, line = ctx.line }
	q.def = type(data.skills) == "table" and data.skills[ctx.line] or nil
	q.bands = type(data.bands) == "table" and data.bands or W.DEFAULT_BANDS
	q.bandsConfirmed = data.bandsConfirmed == true
	q.skill, q.cap, q.level = num(ctx.skill), num(ctx.cap), num(ctx.level)
	local f = not secret(ctx.faction) and ctx.faction or nil
	q.faction = (f == "A" or f == "Alliance") and "A" or ((f == "H" or f == "Horde") and "H" or nil)
	q.class = not secret(ctx.class) and ctx.class or nil
	q.maps = ctx.maps or data.maps or {}
	q.confirmed = ctx.confirmed or {}
	q.continentOf = ctx.continentOf or W.CONTINENT
	q.selected, q.mode, q.money = ctx.selected, ctx.mode, ctx.money
	q.top = ctx.top or W.TOP
	local h = ctx.here
	if type(h) == "table" and num(h.map) and num(h.x) and num(h.y) then
		q.here = { map = h.map, x = h.x, y = h.y }
	else
		q.hereWhy = ctx.hereWhy or "position unknown"
	end
	q.name = q.def and q.def.name or ctx.name or "Skill"
	local kind = q.def and q.def.kind or nil
	if kind == "node" then
		kind = ctx.line == W.HERBALISM and "herb" or "mine"
	end
	q.kind = kind
	q.words = KIND[kind] or KIND.lock
	return q
end

-- Yards between two normalised points of one map. size = { w, h } in yards; nil when the size is not known.
function W.yards(size, x1, y1, x2, y2)
	if type(size) ~= "table" or not num(size.w) then
		return nil
	end
	local h = num(size.h) or size.w * W.ASPECT
	local dx, dy = (x2 - x1) * size.w, (y2 - y1) * h
	return math.sqrt(dx * dx + dy * dy)
end

-- Direction from a to b on a map (x grows east, y grows south), in degrees clockwise from north, 0-360.
function W.bearing(x1, y1, x2, y2, size)
	local w = type(size) == "table" and num(size.w) or 1
	local h = type(size) == "table" and num(size.h) or w * W.ASPECT
	local deg = math.deg(math.atan2((x2 - x1) * w, -(y2 - y1) * h))
	if deg < 0 then
		deg = deg + 360
	end
	return deg
end

-- The eight-way compass word for a bearing in degrees (Guide.compass's words: it takes radians counter-clockwise).
function W.compass(deg)
	if not num(deg) then
		return nil
	end
	return ns.Guide.compass(math.rad((360 - deg) % 360))
end

------------------------------------------------------------------------------------------------------ band maths

-- The skill a skinning target of `level` needs: the data's tiers, else the vanilla rule.
function W.skinReq(level, tiers)
	level = num(level)
	if not level then
		return nil
	end
	for _, t in ipairs(tiers or {}) do
		if level <= t.to then
			return math.max(1, level * t.mul + t.add)
		end
	end
	if level <= 10 then
		return 1
	elseif level < 20 then
		return (level - 10) * 10
	end
	return level * 5
end

-- The colour thresholds of a requirement: { req, yellow, green, grey } (orange from req, grey from `grey`).
function W.bandsOf(req, bands)
	bands = bands or W.DEFAULT_BANDS
	return { req = req, yellow = req + bands.yellow, green = req + bands.green, grey = req + bands.grey }
end

-- "locked" | "orange" | "yellow" | "green" | "grey" at `skill`; nil when the skill or the requirement is unknown.
function W.stateAt(skill, req, bands)
	skill, req = num(skill), num(req)
	if not skill or not req then
		return nil
	end
	local b = W.bandsOf(req, bands)
	if skill < b.req then
		return "locked"
	elseif skill < b.yellow then
		return "orange"
	elseif skill < b.green then
		return "yellow"
	elseif skill < b.grey then
		return "green"
	end
	return "grey"
end

-- The skill at which the state changes next (the requirement while locked); nil once grey or unknown.
function W.changeAt(skill, req, bands)
	local state = W.stateAt(skill, req, bands)
	local b = state and W.bandsOf(req, bands)
	if state == "locked" then
		return b.req
	elseif state == "orange" then
		return b.yellow
	elseif state == "yellow" then
		return b.green
	elseif state == "green" then
		return b.grey
	end
	return nil
end

-- The band bar's segments for a requirement, clipped to [lo, hi]: { { from, to, color } }.
function W.segs(req, bands, lo, hi)
	local b = W.bandsOf(req, bands)
	local out = {}
	for _, s in ipairs({ { b.req, b.yellow, "orange" }, { b.yellow, b.green, "yellow" }, { b.green, b.grey, "green" } }) do
		local from, to = math.max(s[1], lo or s[1]), math.min(s[2], hi or s[2])
		if to > from then
			out[#out + 1] = { from = from, to = to, color = s[3] }
		end
	end
	return out
end

-- A crafted recipe's colours over the stretch [from, to] (yellow at y, grey at g, green from their midpoint).
function W.recipeBands(from, to, y, g)
	if not (num(from) and num(to) and num(y) and num(g)) then
		return nil
	end
	local mid = math.floor((y + g) / 2)
	local out = {}
	for _, s in ipairs({
		{ -math.huge, y, "orange" },
		{ y, mid, "yellow" },
		{ mid, g, "green" },
		{ g, math.huge, "grey" },
	}) do
		local a, b = math.max(s[1], from), math.min(s[2], to)
		if b > a then
			out[#out + 1] = { from = a, to = b, color = s[3] }
		end
	end
	return out
end

-- The share of fishing casts that get away in a zone, 0-1; nil when the skill is below the zone's base (cannot fish
-- there) or unknown. cmangos: a catch needs skill >= base and a roll of 1-100 at most skill - base + 5.
function W.fishAway(skill, base)
	skill, base = num(skill), num(base)
	if not skill or not base or skill < base then
		return nil
	end
	return math.max(0, math.min(1, (100 - (skill - base + 5)) / 100))
end

local STATE_ORDER = { orange = 1, yellow = 2, green = 3, locked = 4, grey = 5 }

-- The target a route point stands for: its key and row. pk is an index into the spot's `gets` (a key string is
-- accepted too); 0 or missing = a target outside `gets`, shown as "Other" at the spot's lowest requirement.
local function targetOf(q, spot, i)
	local pk = spot.pk and spot.pk[i]
	local key = type(pk) == "string" and pk or nil
	if type(pk) == "number" and spot.gets and spot.gets[pk] then
		key = spot.gets[pk].t
	elseif pk == nil and spot.gets and spot.gets[1] then
		key = spot.gets[1].t
	end
	local t = key and q.def and q.def.targets and q.def.targets[key] or nil
	if t then
		return key, t
	end
	return "other", { name = "Other", req = spot.req or 1 }
end

local function targetName(q, key, t)
	if q.kind == "skin" and t.min then
		return t.min == t.max and ("%s %d"):format(t.name, t.min) or ("%s %d-%d"):format(t.name, t.min, t.max)
	end
	return t.name or ("Unnamed (" .. tostring(key) .. ")")
end

-- The best state among a list (usable colours first, then locked, then grey); nil for an empty list or no skill.
local function bestState(states)
	local best
	for _, s in ipairs(states) do
		if s and (not best or STATE_ORDER[s] < STATE_ORDER[best]) then
			best = s
		end
	end
	return best
end

-- What a route point is worth at `skill`. A lock or a beast is its own target. A node site holds its pin's ore or
-- herb or any higher one the spot gives (sites are pooled), so its state is the best of those.
local function pointState(q, spot, i, skill)
	local _, t = targetOf(q, spot, i)
	if q.kind ~= "mine" and q.kind ~= "herb" then
		return W.stateAt(skill, t.req, q.bands)
	end
	local states = { W.stateAt(skill, t.req, q.bands) }
	for _, g in ipairs(spot.gets or {}) do
		local o = q.def.targets and q.def.targets[g.t]
		if o and o.req and o.req >= (t.req or 0) then
			states[#states + 1] = W.stateAt(skill, o.req, q.bands)
		end
	end
	return bestState(states)
end

-- How much of a spot still gives points at `skill`, weighted by how many positions each target has there:
-- { total, orange, yellow, green, grey, locked, usable, value, best (state), bestKey, bestReq }. With no skill
-- everything counts as usable (state unknown).
function W.counts(q, spot, skill)
	q = W.query(q)
	local c = { total = 0, orange = 0, yellow = 0, green = 0, grey = 0, locked = 0, usable = 0, value = 0 }
	local gets = spot.gets
	if not gets or #gets == 0 then
		gets = { { n = 1, req = spot.req or 1 } }
	end
	skill = num(skill)
	for _, g in ipairs(gets) do
		local t = g.t and q.def and q.def.targets and q.def.targets[g.t] or nil
		local req = t and t.req or g.req or spot.req or 1
		local n = math.max(1, g.n or 1)
		c.total = c.total + n
		local state = W.stateAt(skill, req, q.bands)
		if not state then
			c.usable, c.value = c.usable + n, c.value + n
		else
			c[state] = c[state] + n
			if state ~= "grey" and state ~= "locked" then
				c.usable = c.usable + n
				c.value = c.value + n * W.WEIGHT[state]
			end
			local better = not c.best or STATE_ORDER[state] < STATE_ORDER[c.best]
			if better or (state == c.best and req > (c.bestReq or 0) and state ~= "locked") then
				c.best, c.bestKey, c.bestReq = state, g.t, req
			end
		end
	end
	return c
end

------------------------------------------------------------------------------------------------------------ mobs

-- The level below which a creature gives no experience (the vanilla rule): "trivial".
function W.greyLevel(level)
	if level <= 5 then
		return 0
	elseif level <= 39 then
		return level - math.floor(level / 10) - 5
	elseif level <= 59 then
		return level - math.floor(level / 5) - 1
	end
	return level - 9
end

local DANGER_TONE = { deadly = "warn", dangerous = "orange", even = "yellow", easy = "green", trivial = "grey" }
W.DANGER_COST = { deadly = 40, dangerous = 20, even = 5, easy = 0, trivial = 0 }

-- How the camp's top level sits against the player's: d = mobs.max - level. "deadly" d >= 5, "dangerous" 3-4,
-- "even" -2..2, "easy" below that, "trivial" at or under the grey level. Returns state, tone, d; nil state (tone
-- "bone") when the level or the mobs are unknown.
function W.danger(mobs, level)
	level = num(level)
	local max = type(mobs) == "table" and num(mobs.max) or nil
	if not level or not max then
		return nil, "bone", nil
	end
	local d = max - level
	local state
	if d >= 5 then
		state = "deadly"
	elseif d >= 3 then
		state = "dangerous"
	elseif d >= -2 then
		state = "even"
	elseif max > W.greyLevel(level) then
		state = "easy"
	else
		state = "trivial"
	end
	return state, DANGER_TONE[state], d
end

-- The mob chip: { min, max, elite, label, tone, state, phrase, names }. nil when the spot has no mobs listed.
function W.mobs(mobs, level)
	if type(mobs) ~= "table" or not num(mobs.max) then
		return nil
	end
	local min = num(mobs.min) or mobs.max
	local state, tone, d = W.danger(mobs, level)
	local m = { min = min, max = mobs.max, elite = mobs.elite == true, tone = tone, state = state, names = {} }
	m.label = min == mobs.max and ("Mobs %d"):format(min) or ("Mobs %d-%d"):format(min, mobs.max)
	if d then
		m.phrase = d > 0 and ("%d above you"):format(d) or (d == 0 and "your level" or ("%d below you"):format(-d))
	end
	for _, row in ipairs(mobs.list or {}) do
		local name, lo, hi = row.name or row[2], row.min or row[3], row.max or row[4]
		if name then
			local lv = lo and (lo == hi and tostring(lo) or (lo .. "-" .. tostring(hi))) or nil
			m.names[#m.names + 1] = lv and (name .. " " .. lv) or name
		end
	end
	return m
end

---------------------------------------------------------------------------------------------------------- scoring

local function underwater(spot)
	return spot.underwater == true
		or (type(spot.note) == "string" and spot.note:lower():find("underwater", 1, true) ~= nil)
end

local function centreYards(q, spot)
	if not q.here or q.here.map ~= spot.map or not num(spot.x) then
		return nil
	end
	return W.yards(q.maps[spot.map], q.here.x, q.here.y, spot.x / 100, spot.y / 100)
end

-- A spot's score at a skill (higher is better) and what it is made of:
--   gain    +100 x the share of its positions that still give points (orange 1, yellow 0.75, green 0.25)
--   loop    -(loop yards per usable position) / 10, at most 20
--   danger  -40 deadly, -20 dangerous, -5 even (W.danger; nothing when the level is unknown)
--   flight  -(yards from the faction's flight point) / 300, at most 10; -10 when the faction has none
--   player  -(yards from the player) / 500, at most 10; -5 when the player is on another map
--   place   -25 in an instance, -10 underwater, -5 indoors
-- A Classic-only position is tagged, never penalised.
-- Returns { spot, score, parts, counts, usable, locked, danger, tone, playerYd, flightYd }.
function W.rate(q, spot, skill, level)
	q = W.query(q)
	if skill == nil then
		skill = q.skill
	end
	if level == nil then
		level = q.level
	end
	local c = W.counts(q, spot, skill)
	local r = { spot = spot, counts = c, usable = c.usable > 0 }
	r.locked = not r.usable and c.locked > 0
	local p = {}
	p.gain = c.total > 0 and 100 * c.value / c.total or 0
	local points = spot.pts and #spot.pts / 2 or (spot.sites or c.total)
	local usablePts = math.max(1, points * (c.total > 0 and c.usable / c.total or 0))
	p.loop = -math.min(20, (num(spot.loopYd) or 0) / usablePts / 10)
	local state, tone = W.danger(spot.mobs, level)
	r.danger, r.tone = state, tone
	p.danger = -(W.DANGER_COST[state or ""] or 0)
	local fp = q.faction and type(spot.fp) == "table" and spot.fp[q.faction] or nil
	r.flightYd = fp and num(fp.yd) or nil
	p.flight = 0
	if q.faction then
		p.flight = r.flightYd and -math.min(10, r.flightYd / 300) or -10
	end
	r.playerYd = centreYards(q, spot)
	p.player = 0
	if q.here then
		p.player = r.playerYd and -math.min(10, r.playerYd / 500) or -5
	end
	p.place = -((spot.instance and 25 or 0) + (underwater(spot) and 10 or 0) + (spot.indoor and 5 or 0))
	r.parts = p
	r.score = p.gain + p.loop + p.danger + p.flight + p.player + p.place
	return r
end

local function byScore(a, b)
	if a.score ~= b.score then
		return a.score > b.score
	end
	return tostring(a.spot.id) < tostring(b.spot.id)
end

-- Every spot of the skill at a rank: `now` (gives points, best first), `locked` (needs more skill, lowest
-- requirement first) and `grey` (nothing left there).
function W.rank(q, skill, level)
	q = W.query(q)
	local out = { now = {}, locked = {}, grey = {} }
	for _, spot in ipairs(q.def and q.def.spots or {}) do
		local r = W.rate(q, spot, skill, level)
		local list = r.usable and out.now or (r.locked and out.locked or out.grey)
		list[#list + 1] = r
	end
	table.sort(out.now, byScore)
	table.sort(out.grey, byScore)
	table.sort(out.locked, function(a, b)
		local ra, rb = a.spot.req or 0, b.spot.req or 0
		if ra ~= rb then
			return ra < rb
		end
		return byScore(a, b)
	end)
	return out
end

-- Fishing: every zone at a rank. `now` = can fish there (fewest get-aways first, then the lowest base, then name;
-- instances last), `locked` = base above the skill.
function W.rankFish(q, skill)
	q = W.query(q)
	if skill == nil then
		skill = q.skill
	end
	local out = { now = {}, locked = {}, grey = {} }
	for _, zone in ipairs(q.def and q.def.zones or {}) do
		local away = W.fishAway(skill, zone.base)
		local r = { zone = zone, away = away, usable = away ~= nil or num(skill) == nil }
		r.score = 100 - (away or 0) * 100 - (zone.instance and 25 or 0)
		local list = r.usable and out.now or out.locked
		list[#list + 1] = r
	end
	local function order(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if (a.zone.base or 0) ~= (b.zone.base or 0) then
			return (a.zone.base or 0) < (b.zone.base or 0)
		end
		return tostring(a.zone.zone) < tostring(b.zone.zone)
	end
	table.sort(out.now, order)
	table.sort(out.locked, function(a, b)
		if (a.zone.base or 0) ~= (b.zone.base or 0) then
			return (a.zone.base or 0) < (b.zone.base or 0)
		end
		return tostring(a.zone.zone) < tostring(b.zone.zone)
	end)
	return out
end

-------------------------------------------------------------------------------------------------------- itinerary

-- The level the character has at least when the skill is s: Lockpicking's cap is capPerLevel x level, so skill s
-- needs level s / capPerLevel. Other skills: the level now.
local function levelAt(q, s)
	local per = q.def and num(q.def.capPerLevel)
	if not per then
		return q.level
	end
	local need = math.max(math.ceil(s / per), num(q.def.learnLevel) or 1)
	return q.level and math.max(q.level, need) or need
end

-- Why nothing gives points on [from, to): the targets whose band covers it but that have no usable position.
local function holeReason(q, from)
	local new, thin, names = 0, 0, {}
	for key, t in pairs(q.def and q.def.targets or {}) do
		local state = t.req and W.stateAt(from, t.req, q.bands)
		if state and state ~= "grey" and state ~= "locked" and not t.item then
			if t.new then
				new = new + 1
			else
				thin = thin + 1
				local n = num(t.n)
				local count = n and (n > 0 and (" (%s)"):format(plural(n, "position")) or " (no positions)") or ""
				names[#names + 1] = targetName(q, key, t) .. count
			end
		end
	end
	table.sort(names)
	if thin > 0 then
		local shown = table.concat(names, ", ", 1, math.min(3, #names))
		if #names > 3 then
			shown = shown .. (" and %d more"):format(#names - 3)
		end
		return ("%s: too few positions in the data to make a spot"):format(shown)
	elseif new > 0 then
		return ("%s: %s"):format(plural(new, "target", "targets"), W.TEXT.newTarget)
	end
	return "nothing in the data gives points here"
end

-- The skill's thresholds between from and to: every requirement and colour change of a target, placed or not (an
-- unplaced one changes the reason a hole gives).
local function breaksOf(q, from, to)
	local set, list = { [from] = true }, { from }
	for _, t in pairs(q.def and q.def.targets or {}) do
		if t.req and not t.item then
			local b = W.bandsOf(t.req, q.bands)
			for _, v in ipairs({ b.req, b.yellow, b.green, b.grey }) do
				if v > from and v < to and not set[v] then
					set[v] = true
					list[#list + 1] = v
				end
			end
		end
	end
	table.sort(list)
	return list
end

-- The best spot at a skill for the itinerary (no player position: a plan must not change as the player walks).
local function bestAt(q, s, keep)
	local iq = q.here and setmetatable({ here = false }, { __index = q }) or q
	local best, kept
	for _, spot in ipairs(q.def and q.def.spots or {}) do
		local r = W.rate(iq, spot, s, levelAt(q, s))
		if r.usable then
			if not best or byScore(r, best) then
				best = r
			end
			if keep and spot == keep then
				kept = r
			end
		end
	end
	if kept and best and kept.score >= best.score - W.SWITCH then
		return kept
	end
	return best
end

-- The whole skill from `from` to `to`: ordered legs with the best spot each, and the stretches nothing covers.
-- Returns { from, to, legs = { { from, to, spot | zone, key, title, zone, text } }, holes = { { from, to, reason } },
-- complete, spots (distinct places used), text }. A leg changes only when another spot leads by W.SWITCH.
function W.itinerary(q, from, to)
	q = W.query(q)
	from = math.max(1, num(from) or 1)
	to = num(to) or q.top
	local it = { from = from, to = to, legs = {}, holes = {}, spots = 0 }
	if not q.def then
		it.holes[1] = { from = from, to = to, reason = "no data for this skill" }
	elseif from >= to then
		it.complete = true
		it.text = ("%s is at %d: nothing left to plan"):format(q.name, from)
		return it
	elseif q.kind == "fish" then
		local list = breaksOf(q, from, to)
		for _, zone in ipairs(q.def.zones or {}) do
			for _, v in ipairs({ zone.base or 0, (zone.base or 0) + W.FISH_CLEAN }) do
				if v > from and v < to then
					list[#list + 1] = v
				end
			end
		end
		table.sort(list)
		local prev
		for i, a in ipairs(list) do
			local b = list[i + 1] or to
			if b > a then
				local best = W.rankFish(q, a).now[1]
				if not best then
					local h = it.holes[#it.holes]
					if h and h.to == a then
						h.to = b
					else
						it.holes[#it.holes + 1] =
							{ from = a, to = b, reason = "no fishing zone in the data is this low" }
					end
					prev = nil
				elseif prev and prev.zone == best.zone then
					prev.to = b
				else
					prev = { from = a, to = b, zone = best.zone, key = "fish:" .. tostring(best.zone.zone) }
					prev.title, prev.zoneName = best.zone.zone, best.zone.zone
					it.legs[#it.legs + 1] = prev
				end
			end
		end
	else
		local list = breaksOf(q, from, to)
		local prev
		for i, a in ipairs(list) do
			local b = list[i + 1] or to
			local best = bestAt(q, a, prev and prev.spot or nil)
			if not best then
				local reason = holeReason(q, a)
				local h = it.holes[#it.holes]
				if h and h.to == a and h.reason == reason then
					h.to = b
				else
					it.holes[#it.holes + 1] = { from = a, to = b, reason = reason }
				end
				prev = nil
			elseif prev and prev.spot == best.spot then
				prev.to = b
			else
				local spot = best.spot
				-- band: the best colour the spot gives when the leg starts ("green" = slow going)
				prev = { from = a, to = b, spot = spot, key = spot.id, zoneName = spot.zone, band = best.counts.best }
				prev.title = spot.area or spot.instance or spot.zone
				it.legs[#it.legs + 1] = prev
			end
		end
	end
	local seen = {}
	for _, leg in ipairs(it.legs) do
		if not seen[leg.key] then
			seen[leg.key] = true
			it.spots = it.spots + 1
		end
		local place = leg.title ~= leg.zoneName and ("%s, %s"):format(leg.title, leg.zoneName) or leg.title
		leg.text = ("%d to %d: %s"):format(leg.from, leg.to, place)
	end
	it.complete = #it.holes == 0
	if it.complete then
		it.text = ("%s, complete %d-%d"):format(plural(it.spots, "spot"), from, to)
	else
		local parts = {}
		for _, h in ipairs(it.holes) do
			parts[#parts + 1] = ("%d-%d"):format(h.from, h.to)
		end
		it.text = ("%s, nothing mapped for %s"):format(plural(it.spots, "spot"), table.concat(parts, ", "))
	end
	return it
end

------------------------------------------------------------------------------------------------------------ route

-- Heights into floors: sorted, split where two neighbours differ by more than `gap` yards. zs may have holes (nil).
-- Returns the floor id per index (1 = lowest) and { { id, label, count, z } }; nil when fewer than two floors.
function W.floors(zs, gap)
	gap = gap or W.FLOOR_GAP
	local sorted = {}
	for i, z in pairs(zs or {}) do
		if num(z) then
			sorted[#sorted + 1] = { i = i, z = z }
		end
	end
	table.sort(sorted, function(a, b)
		if a.z ~= b.z then
			return a.z < b.z
		end
		return a.i < b.i
	end)
	local ids, floors = {}, {}
	for k, e in ipairs(sorted) do
		if k == 1 or e.z - sorted[k - 1].z > gap then
			floors[#floors + 1] = { id = #floors + 1, count = 0, z = e.z }
		end
		local f = floors[#floors]
		f.count = f.count + 1
		ids[e.i] = f.id
	end
	if #floors < 2 then
		return nil, nil
	end
	local names = #floors == 2 and { "Lower", "Upper" } or (#floors == 3 and { "Lower", "Middle", "Upper" } or nil)
	for _, f in ipairs(floors) do
		f.label = names and names[f.id] or ("Floor " .. f.id)
	end
	return ids, floors
end

local function legUnits(a, b, aspect)
	local dx, dy = b.x - a.x, (b.y - a.y) * aspect
	return math.sqrt(dx * dx + dy * dy)
end

-- The loop to walk at the current skill. Points that give nothing (grey) or cannot be opened yet (locked) leave the
-- tour and it closes again in the same order; the tour is rotated to the faction's start. Returns nil for a spot
-- with no points (an instance), else
-- { pts = { { n, src, x, y, z, pk, band, floor } }, skipped = { { src, x, y, pk, band } }, closed, loopYd, loopWhy,
--   poolsOf, poolsText, respawnSec, floors, stairs = { { x, y, from, to, after } }, types = { [pk] = { name, icon,
--   band, req } }, sampled, scattered }.
function W.route(q, spot)
	q = W.query(q)
	local flat = spot.pts
	local n = flat and math.floor(#flat / 2) or 0
	if n == 0 then
		return nil
	end
	local floorOf, floors = W.floors(spot.z)
	local start = q.faction and num(spot["start" .. q.faction]) or 1
	if start < 1 or start > n then
		start = 1
	end
	local route =
		{ pts = {}, skipped = {}, types = {}, floors = floors, sampled = spot.sampled, scattered = spot.scattered }
	local all = {}
	for k = 0, n - 1 do
		local i = (start - 1 + k) % n + 1
		local key, t = targetOf(q, spot, i)
		local band = pointState(q, spot, i, q.skill)
		local p =
			{ src = i, x = flat[2 * i - 1] / 100, y = flat[2 * i] / 100, z = spot.z and spot.z[i] or nil, pk = key }
		p.band, p.floor = band, floorOf and floorOf[i] or nil
		all[#all + 1] = p
		local own = W.stateAt(q.skill, t.req, q.bands)
		local ty = route.types[key]
		if not ty then
			ty = { name = targetName(q, key, t), icon = q.words.icon, band = own, req = t.req }
			route.types[key] = ty
		end
		if band == "grey" or band == "locked" then
			route.skipped[#route.skipped + 1] = p
		else
			p.n = #route.pts + 1
			route.pts[#route.pts + 1] = p
		end
	end
	local kept = route.pts
	route.closed = #kept >= 3 and not spot.scattered
	local size = q.maps[spot.map]
	local aspect = type(size) == "table" and num(size.w) and num(size.h) and size.h / size.w or W.ASPECT
	local function length(list, closed)
		local sum = 0
		for i = 1, #list - 1 do
			sum = sum + legUnits(list[i], list[i + 1], aspect)
		end
		if closed and #list >= 3 then
			sum = sum + legUnits(list[#list], list[1], aspect)
		end
		return sum
	end
	local units = length(kept, route.closed)
	if #kept == n and num(spot.loopYd) and not spot.scattered then
		route.loopYd = spot.loopYd
	elseif type(size) == "table" and num(size.w) then
		route.loopYd = round(units * size.w)
	elseif num(spot.loopYd) and length(all, true) > 0 then
		-- no map size: the data's length, scaled by how much of the tour is left
		route.loopYd = round(spot.loopYd * units / length(all, true))
		route.loopWhy = "map size unknown: length scaled from the full loop"
	else
		route.loopWhy = "map size unknown"
	end
	route.stairs = floors and {} or nil
	if floors then
		local last = route.closed and #kept or #kept - 1
		for i = 1, last do
			local a, b = kept[i], kept[i % #kept + 1]
			if a.floor and b.floor and a.floor ~= b.floor then
				route.stairs[#route.stairs + 1] =
					{ x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, from = a.floor, to = b.floor, after = i }
			end
		end
		for _, f in ipairs(floors) do
			f.count = 0
		end
		for _, p in ipairs(kept) do
			if p.floor then
				floors[p.floor].count = floors[p.floor].count + 1
			end
		end
	end
	route.poolsOf = num(spot.poolsOf)
	route.poolsText = route.poolsOf and ("about %d %s up"):format(round(route.poolsOf), q.words.units)
		or W.TEXT.poolsUnknown
	route.respawnSec = num(spot.respawnSec) or W.RESPAWN
	return route
end

-- The stop to go to next. here = { x, y } normalised on the route's map, or nil. opts = { visited = { [n] =
-- expiresAt }, now, last (the stop visited last), size = { w, h } }. After a visit: the first unvisited stop ahead
-- in tour order. Before any: the unvisited stop nearest the player (the first one when the position is unknown).
-- Returns { index, yards, bearing (degrees clockwise from north), compass } or nil and why.
function W.nextStop(route, here, opts)
	opts = opts or {}
	local pts = type(route) == "table" and route.pts or nil
	if not pts or #pts == 0 then
		return nil, "nothing on this route gives points at your skill"
	end
	local visited, now = opts.visited or {}, opts.now or 0
	local function open(i)
		return not (visited[i] and visited[i] > now)
	end
	local pick
	local last = num(opts.last)
	if last and pts[last] then
		for k = 1, #pts do
			local i = (last - 1 + k) % #pts + 1
			if open(i) then
				pick = i
				break
			end
		end
	else
		local bestD
		for i, p in ipairs(pts) do
			if open(i) then
				local d = here and legUnits(here, p, W.ASPECT) or i
				if not bestD or d < bestD then
					pick, bestD = i, d
				end
			end
		end
	end
	if not pick then
		return nil, "every stop was just visited"
	end
	local out = { index = pick }
	if here then
		local p = pts[pick]
		out.yards = W.yards(opts.size, here.x, here.y, p.x, p.y)
		out.bearing = W.bearing(here.x, here.y, p.x, p.y, opts.size)
		out.compass = W.compass(out.bearing)
	end
	return out
end

-- Marks stop `index` visited until now + respawn. Returns the table (a new one when `visited` is nil).
function W.visit(visited, index, now, respawnSec)
	visited = visited or {}
	visited[index] = now + (respawnSec or W.RESPAWN)
	return visited
end

-- The visits still inside their respawn window, as a new table.
function W.fresh(visited, now)
	local out = {}
	for i, at in pairs(visited or {}) do
		if at > now then
			out[i] = at
		end
	end
	return out
end

-- "3 visited, the first is back in 3:40", or nil with no live visit.
function W.visitedLine(visited, now)
	local n, soonest = 0, nil
	for _, at in pairs(W.fresh(visited, now)) do
		n = n + 1
		if not soonest or at < soonest then
			soonest = at
		end
	end
	if n == 0 then
		return nil
	end
	return ("%d visited, the first is back in %s"):format(n, W.clock(soonest - now))
end

----------------------------------------------------------------------------------------------------------- yields

local function axisOf(reqs, bands, cap)
	local lo, hi
	for _, req in ipairs(reqs) do
		lo = math.min(lo or req, req)
		hi = math.max(hi or req, req + bands.grey)
	end
	if not lo then
		return nil
	end
	lo = math.floor(lo / 10) * 10 - 10
	hi = math.ceil(hi / 10) * 10
	if cap then
		hi = math.max(lo + 10, math.min(hi, cap + 25))
	end
	return { lo = lo, hi = hi }
end

local RIGHT_TONE = { orange = "orange", yellow = "yellow", green = "green", grey = "grey", locked = "warn" }

-- "Here you get": one row per target of the spot with its band bar. Rows that give points come first (orange, then
-- yellow, then green), then the ones that need more skill, then the grey ones. `more` counts rows past
-- W.YIELD_ROWS. With no skill the rows carry their bars and "from 110" only.
function W.yields(q, spot)
	q = W.query(q)
	local rows, reqs = {}, {}
	for _, g in ipairs(spot.gets or {}) do
		local t = q.def and q.def.targets and q.def.targets[g.t]
		if t and t.req then
			local state = W.stateAt(q.skill, t.req, q.bands)
			local b = W.bandsOf(t.req, q.bands)
			local row =
				{ pk = g.t, icon = q.words.icon, name = targetName(q, g.t, t), req = t.req, state = state, n = g.n }
			local change = W.changeAt(q.skill, t.req, q.bands)
			if not state then
				row.right, row.tone = ("from %d"):format(t.req), "bone"
			elseif state == "locked" then
				row.right, row.tone = ("needs %d"):format(t.req), "warn"
			elseif state == "grey" then
				row.right, row.tone = "none", "grey"
			else
				row.right, row.tone = ("to %d"):format(change), RIGHT_TONE[state]
			end
			row.tag = t.quest and "quest" or nil
			row.tip = ("%s: needs %d. Orange to %d, yellow to %d, green to %d. %s here."):format(
				row.name,
				t.req,
				b.yellow,
				b.green,
				b.grey,
				plural(g.n or 1, "position")
			)
			if not q.bandsConfirmed then
				row.tip = row.tip .. " " .. W.TEXT.bands
			end
			rows[#rows + 1] = row
			reqs[#reqs + 1] = t.req
		end
	end
	if #rows == 0 then
		return nil
	end
	local axis = axisOf(reqs, q.bands, q.cap)
	for _, row in ipairs(rows) do
		row.segs = W.segs(row.req, q.bands, axis.lo, axis.hi)
	end
	table.sort(rows, function(a, b)
		local sa, sb = STATE_ORDER[a.state or "orange"], STATE_ORDER[b.state or "orange"]
		if sa ~= sb then
			return sa < sb
		end
		if a.req ~= b.req then
			return a.req < b.req
		end
		return a.name < b.name
	end)
	local y = { axis = axis, skill = q.skill, rows = rows, bandsConfirmed = q.bandsConfirmed }
	y.more = #rows > W.YIELD_ROWS and #rows - W.YIELD_ROWS or nil
	y.note = (not q.skill and W.TEXT.noSkill) or (not q.bandsConfirmed and W.TEXT.bands) or nil
	return y
end

-- A fishing zone's row: grey while fish get away, green once the catch is clean.
function W.fishYields(q, zone)
	q = W.query(q)
	local base = num(zone.base) or 0
	local clean = base + W.FISH_CLEAN
	local axis = { lo = math.max(0, math.floor(base / 10) * 10 - 10), hi = math.max(clean + 25, 50) }
	if q.cap then
		axis.hi = math.max(axis.lo + 10, math.min(axis.hi, q.cap + 25))
	end
	local away = W.fishAway(q.skill, base)
	local row = { pk = "fish", icon = KIND.fish.icon, name = zone.zone, req = math.max(1, base), segs = {} }
	for _, s in ipairs({ { math.max(base, axis.lo), clean, "grey" }, { clean, axis.hi, "green" } }) do
		local from, to = math.max(s[1], axis.lo), math.min(s[2], axis.hi)
		if to > from then
			row.segs[#row.segs + 1] = { from = from, to = to, color = s[3] }
		end
	end
	if not q.skill then
		row.right, row.tone = ("from %d"):format(row.req), "bone"
	elseif not away then
		row.state, row.right, row.tone = "locked", ("needs %d"):format(base), "warn"
	elseif away <= 0 then
		row.state, row.right, row.tone = "green", "clean catch", "green"
	else
		row.state, row.right, row.tone = "grey", ("%d%% get away"):format(round(away * 100)), "grey"
	end
	row.tip = ("%s: fish from %d, none get away from %d. Zone values are from Classic, unconfirmed."):format(
		tostring(zone.zone),
		row.req,
		math.max(1, clean)
	)
	return { axis = axis, skill = q.skill, rows = { row }, fishing = true, bandsConfirmed = false }
end

----------------------------------------------------------------------------------------------------------- travel

-- Getting there for the faction: at most 3 legs { icon, text, x, y, map, doneYd, confidence }, the nearest flight
-- point { name, yards } (nil when the faction has none), the dashed lead-in and a note line.
function W.travel(q, spot)
	q = W.query(q)
	local out = { legs = {} }
	local conf = (spot.classic and not q.confirmed[spot.id]) and "classic" or "confirmed"
	local fp = q.faction and type(spot.fp) == "table" and spot.fp[q.faction] or nil
	local place = spot.area or spot.instance or spot.zone or "the spot"
	local hereCont = q.here and q.continentOf[q.here.map]
	local spotCont = spot.map and q.continentOf[spot.map]
	if hereCont and spotCont and hereCont ~= spotCont then
		out.otherContinent = true
		out.legs[#out.legs + 1] = { icon = "boat", text = W.TEXT.otherContinent, confidence = "confirmed" }
	end
	if fp then
		out.flight = { name = fp.name, yards = num(fp.yd), map = fp.map }
		out.legs[#out.legs + 1] = {
			icon = "flight",
			text = ("Fly to %s"):format(tostring(fp.name)),
			map = fp.map,
			x = num(fp.x) and fp.x / 100 or nil,
			y = num(fp.y) and fp.y / 100 or nil,
			doneYd = 60,
			confidence = conf,
		}
	elseif q.faction then
		out.noFlight = W.TEXT.noFlight
	end
	local dir
	if fp and fp.map == spot.map and num(fp.x) and num(spot.x) then
		dir = W.compass(W.bearing(fp.x / 100, fp.y / 100, spot.x / 100, spot.y / 100, q.maps[spot.map]))
		out.leadIn = { points = { { fp.x / 100, fp.y / 100 }, { spot.x / 100, spot.y / 100 } }, yards = num(fp.yd) }
		out.leadIn.label = W.yd(fp.yd)
	end
	local go = spot.instance and "Enter %s" or "Go to %s"
	local text = go:format(place)
	if fp and num(fp.yd) then
		text = dir and ("%s, %s %s"):format(text, W.yd(fp.yd), dir) or ("%s, %s"):format(text, W.yd(fp.yd))
	end
	if conf == "classic" then
		text = text .. " (unconfirmed)"
	end
	local r = num(spot.r) and q.maps[spot.map] and num(q.maps[spot.map].w) and spot.r / 100 * q.maps[spot.map].w or 0
	out.legs[#out.legs + 1] = {
		icon = spot.instance and "entrance" or "spot",
		text = text,
		map = spot.map,
		x = num(spot.x) and spot.x / 100 or nil,
		y = num(spot.y) and spot.y / 100 or nil,
		doneYd = round(r + W.ENTER_PAD),
		confidence = conf,
	}
	out.note = spot.note
	return out
end

------------------------------------------------------------------------------------------------------- the model

local function bbox(points, pad, minSpan)
	local x0, y0, x1, y1
	for _, p in ipairs(points) do
		local x, y = p.x or p[1], p.y or p[2]
		x0, y0 = math.min(x0 or x, x), math.min(y0 or y, y)
		x1, y1 = math.max(x1 or x, x), math.max(y1 or y, y)
	end
	if not x0 then
		return nil
	end
	-- span is a share of the map's width; a tall box needs the span its height takes at the map's 3:2 shape
	local span = math.max(x1 - x0, (y1 - y0) * 1.5) * (1 + 2 * pad)
	span = math.max(span, minSpan or 0.02)
	return { cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, span = math.min(1, span) }
end

local function confidenceOf(q, spot)
	if spot.classic and not q.confirmed[spot.id] then
		return "classic", W.TEXT.classic
	end
	return "confirmed", nil
end

local function sideName(f)
	return f == "A" and "Alliance" or (f == "H" and "Horde" or "your side")
end

-- The card when nothing is mapped for a bracket (design section 6): names the bracket and offers the nearest
-- lower spot when there is one.
function W.emptyWhere(q, from, to, reason)
	q = W.query(q)
	from, to = from or q.skill or 1, to or q.top
	local w =
		{ kind = "spot", key = ("empty:%s:%d"):format(tostring(q.line), from), profession = q.name, color = "warn" }
	w.title, w.sub, w.actions = q.name, "", {}
	local lower
	if q.def and q.kind ~= "fish" then
		for _, r in ipairs(W.rank(q, q.skill).grey) do
			if not lower or (r.spot.top or 0) > (lower.top or 0) then
				lower = r.spot
			end
		end
	end
	w.empty = {
		title = ("Nothing mapped for %s %d to %d"):format(q.name, from, to),
		text = ("No %s spot in the data covers this bracket yet (%s). Only the place is missing."):format(
			q.name,
			reason or "nothing in the data gives points here"
		),
		action = lower
				and { id = "selectSpot", label = "Show the nearest lower spot", enabled = true, spot = lower.id }
			or nil,
	}
	return w
end

local function spotActions(key)
	return {
		{ id = "pin", label = "Pin on the map", enabled = true, spot = key },
		{ id = "openMap", label = "Open zone map", enabled = true, spot = key },
		{ id = "journal", label = "Open the journal", enabled = true, page = "where", spot = key },
	}
end

-- The spot after this one: where the itinerary goes when this spot stops being the best.
local function nextOf(q, spot)
	if not q.skill then
		return nil
	end
	local it = W.itinerary(q, q.skill, q.top)
	for _, leg in ipairs(it.legs) do
		if leg.from > q.skill and leg.spot ~= spot and (leg.spot or leg.zone) then
			local n = { key = leg.key, at = leg.from, tone = "bone" }
			local place = leg.title ~= leg.zoneName and ("%s, %s"):format(leg.title, leg.zoneName) or leg.title
			n.text = ("At %d: %s"):format(leg.from, place)
			if leg.spot then
				local m = W.mobs(leg.spot.mobs, levelAt(q, leg.from))
				local fp = q.faction and leg.spot.fp and leg.spot.fp[q.faction]
				local parts = {}
				if m then
					parts[#parts + 1] = m.phrase and ("%s, %s."):format(m.label, m.phrase) or (m.label .. ".")
					n.tone = m.tone
				end
				if fp then
					parts[#parts + 1] = ("Flight: %s, %s."):format(tostring(fp.name), W.yd(fp.yd) or "distance unknown")
				end
				n.sub = table.concat(parts, " ")
			else
				n.sub = "Any water there."
			end
			return n
		end
	end
	return nil
end

-- One spot as the `where` view-model (design section 7.1). opts.next = false leaves the next-spot preview out (the
-- list builds many of these).
function W.where(q, spot, opts)
	q = W.query(q)
	opts = opts or {}
	if type(spot) ~= "table" then
		return W.emptyWhere(q)
	end
	local c = W.counts(q, spot, q.skill)
	local route = W.route(q, spot)
	local size = q.maps[spot.map]
	local w = { key = spot.id, profession = q.name, map = spot.map, bands = q.bands, bandsConfirmed = q.bandsConfirmed }
	w.kind = (route and #route.pts >= 2 and not spot.scattered) and "loop" or "spot"
	w.color = (c.best and c.best ~= "locked" and c.best)
		or (q.skill and (c.best == "locked" and "warn" or "grey"))
		or "bone"
	w.title = spot.area or spot.instance or spot.zone or "Unnamed spot"
	w.sub = num(spot.x) and ("%s, %d, %d"):format(tostring(spot.zone), round(spot.x), round(spot.y))
		or tostring(spot.zone)
	w.confidence, w.tag = confidenceOf(q, spot)
	w.note = spot.note
	w.scattered, w.sampled, w.instance = spot.scattered, spot.sampled, spot.instance

	-- the verb line
	w.verb = { text = q.words.verb }
	if c.usable == 0 and q.skill then
		w.verb.gain = c.locked > 0 and ("needs %d, you have %d"):format(spot.req or 0, q.skill)
			or "nothing here gives points now"
	elseif q.skill and c.bestReq then
		local change = W.changeAt(q.skill, c.bestReq, q.bands)
		w.verb.gain = change and ("%s to %d"):format(plural(change - q.skill, "point"), change) or nil
	end

	-- the area and the two crops
	local r = num(spot.r) and spot.r / 100 or 0.01
	if num(spot.x) then
		w.area = { shape = "circle", x = spot.x / 100, y = spot.y / 100, r = r }
	end
	local rYd = type(size) == "table" and num(size.w) and r * size.w or 60
	w.enterYd, w.leaveYd = round(rYd + W.ENTER_PAD), round(rYd + W.LEAVE_PAD)

	local t = W.travel(q, spot)
	w.travel, w.flight, w.leadIn = t.legs, t.flight, t.leadIn
	w.pins = {}
	local fp = q.faction and type(spot.fp) == "table" and spot.fp[q.faction] or nil
	if fp and fp.map == spot.map and num(fp.x) then
		w.pins[#w.pins + 1] = {
			id = "flight",
			kind = "flight",
			x = fp.x / 100,
			y = fp.y / 100,
			state = "todo",
			confidence = w.confidence,
			tip = ("Flight point: %s"):format(tostring(fp.name)),
			label = fp.name,
		}
	end
	if spot.instance and num(spot.x) then
		w.pins[#w.pins + 1] = {
			id = "entrance",
			kind = "entrance",
			x = spot.x / 100,
			y = spot.y / 100,
			state = "todo",
			confidence = w.confidence,
			tip = ("Entrance of %s"):format(spot.instance),
		}
	end
	local views = {}
	if w.area then
		local pts = { { w.area.x - r, w.area.y - r }, { w.area.x + r, w.area.y + r } }
		if fp and fp.map == spot.map and num(fp.x) then
			pts[#pts + 1] = { fp.x / 100, fp.y / 100 }
		end
		views.travel = bbox(pts, 0.12)
		local minSpan = type(size) == "table" and num(size.w) and 60 / size.w or 0.02
		local rp = {}
		for _, p in ipairs(route and route.pts or {}) do
			rp[#rp + 1] = p
		end
		for _, p in ipairs(route and route.skipped or {}) do
			rp[#rp + 1] = p
		end
		views.spot = bbox(#rp > 0 and rp or pts, 0.15, minSpan)
	end
	w.views = views

	if route then
		for _, s in ipairs(route.stairs or {}) do
			w.pins[#w.pins + 1] = {
				id = "stairs" .. s.after,
				kind = "stairs",
				x = s.x,
				y = s.y,
				state = "todo",
				confidence = w.confidence,
				tip = s.to > s.from and "Stairs up" or "Stairs down",
			}
		end
		w.route = route
	end
	w.mobs = W.mobs(spot.mobs, q.level)
	w.yields = W.yields(q, spot)

	-- the caption
	local facts = {}
	if spot.instance then
		facts[#facts + 1] = ("Inside %s"):format(spot.instance)
	elseif spot.scattered then
		facts[#facts + 1] = ("%s spread over the zone, no set loop"):format(
			plural(spot.sites or (route and #route.pts) or 0, "position")
		)
	elseif route and w.kind == "loop" then
		facts[#facts + 1] = route.loopYd and ("Loop %s"):format(W.yd(route.loopYd)) or "Loop, length unknown"
		facts[#facts + 1] = plural(#route.pts, "stop")
		if route.poolsOf then
			facts[#facts + 1] = route.poolsText
		end
	else
		facts[#facts + 1] = plural(spot.sites or 1, "position")
	end
	if w.mobs then
		facts[#facts + 1] = w.mobs.label:lower()
	end
	w.caption = { line1 = table.concat(facts, ", ") }
	local l3 = {}
	if route and route.floors then
		local fl = {}
		for _, f in ipairs(route.floors) do
			fl[#fl + 1] = ("%s %d"):format(f.label, f.count)
		end
		l3[#l3 + 1] = ("%d floors: %s."):format(#route.floors, table.concat(fl, ", "))
	end
	if route and #route.skipped > 0 then
		l3[#l3 + 1] = ("%s skipped (grey or too hard)."):format(plural(#route.skipped, "position"))
	end
	if spot.sampled then
		l3[#l3 + 1] = ("Shows %d of %d positions."):format(
			route and (#route.pts + #route.skipped) or 0,
			spot.sites or 0
		)
	end
	if route and not route.poolsOf and w.kind == "loop" then
		l3[#l3 + 1] = ("%s %s."):format(
			q.words.units:sub(1, 1):upper() .. q.words.units:sub(2),
			W.TEXT.poolsUnknown:gsub("^how many are ", "")
		)
	end
	if w.confidence == "classic" then
		l3[#l3 + 1] = W.TEXT.classicLong
	end
	if #l3 == 0 then
		l3[1] = ("The view zooms in at %s."):format(W.yd(w.enterYd))
	end
	w.caption.line3 = table.concat(l3, " ")
	if not q.faction then
		w.caption.line3 = w.caption.line3 .. " Faction unknown: no flight point shown."
	elseif not fp then
		w.caption.line3 = w.caption.line3 .. (" No %s flight point known near here."):format(sideName(q.faction))
	end

	if opts.next ~= false then
		w.next = nextOf(q, spot)
	end
	w.actions = spotActions(spot.id)
	return w
end

-- A fishing zone as a `where`: the whole zone map, no route.
function W.fishWhere(q, zone)
	q = W.query(q)
	local away = W.fishAway(q.skill, zone.base)
	local w = { kind = "spot", key = "fish:" .. tostring(zone.zone), profession = q.name, map = zone.map }
	w.title = zone.zone
	w.sub = zone.instance and "Inside the instance" or "Any water in the zone"
	w.color = (not q.skill and "bone") or (not away and "warn") or (away <= 0 and "green" or "grey")
	w.confidence, w.tag = "classic", W.TEXT.classic
	w.verb = { text = KIND.fish.verb }
	if q.skill and not away then
		w.verb.gain = ("needs %d, you have %d"):format(zone.base or 0, q.skill)
	elseif away then
		w.verb.gain = away <= 0 and "no fish get away" or ("%d%% get away"):format(round(away * 100))
	end
	w.views = { travel = { cx = 0.5, cy = 0.5, span = 1 }, spot = { cx = 0.5, cy = 0.5, span = 1 } }
	w.pins, w.travel = {}, {}
	if zone.map then
		w.travel[1] = { icon = "spot", text = ("Go to %s"):format(tostring(zone.zone)), map = zone.map, doneYd = 0 }
		w.travel[1].confidence = "classic"
	end
	w.yields = W.fishYields(q, zone)
	w.caption = { line1 = ("Fishing in %s"):format(tostring(zone.zone)) }
	w.caption.line3 = "Skill-ups come from catches anywhere; this zone only decides how many fish get away. "
		.. "Zone values are from Classic, unconfirmed."
	w.actions = spotActions(w.key)
	return w
end

------------------------------------------------------------------------------------------------------- where list

local function listRow(q, r, right)
	local spot = r.spot
	local c = r.counts
	local conf = confidenceOf(q, spot)
	local row = { key = spot.id, title = spot.area or spot.instance or spot.zone, confidence = conf, right = right }
	local fp = q.faction and type(spot.fp) == "table" and spot.fp[q.faction] or nil
	row.flight = fp and ("Flight: %s, %s"):format(tostring(fp.name), W.yd(fp.yd) or "distance unknown")
		or W.TEXT.noFlight
	row.sub = ("%s. %s"):format(tostring(spot.zone), row.flight)
	local m = W.mobs(spot.mobs, q.level)
	row.mobs = m and { label = m.label, tone = m.tone, phrase = m.phrase } or nil
	local t = c.bestKey and q.def.targets and q.def.targets[c.bestKey]
	if r.locked then
		row.locked = q.skill and ("needs %d, you have %d"):format(spot.req or 0, q.skill)
			or ("needs %d"):format(spot.req or 0)
		row.yield, row.yieldTone = row.locked, "warn"
	elseif t and c.best then
		local change = W.changeAt(q.skill, t.req, q.bands)
		row.yield = ("%s, %s to %d"):format(targetName(q, c.bestKey, t), c.best, change)
		row.yieldTone = c.best
	else
		row.yield, row.yieldTone = ("from %d"):format(spot.req or 1), "bone"
	end
	row.score = r.score
	row.selected = false
	return row
end

-- The Where page's list: the spots that give points now (best first), the spot the route moves to next, then the
-- ones that need more skill. Returns { head = { title, sub }, spots, selected (a `where`), empty, nextAt }.
function W.whereList(q)
	q = W.query(q)
	local out = { spots = {} }
	local rank = q.skill and (q.cap and ("%d / %d"):format(q.skill, q.cap) or tostring(q.skill)) or "skill unknown"
	out.head = { title = ("%s %s"):format(q.name, rank), sub = "Spots that still give points, best first" }
	if not q.def then
		out.empty = ("No data for %s."):format(q.name)
		out.selected = W.emptyWhere(q, q.skill or 1, q.top, "no data for this skill")
		return out
	end
	if not q.skill then
		out.head.sub = W.TEXT.noSkill
	end
	local chosen
	if q.kind == "fish" then
		local rk = W.rankFish(q, q.skill)
		for i, r in ipairs(rk.now) do
			if i > W.LIST_MAX then
				break
			end
			local w = W.fishWhere(q, r.zone)
			out.spots[#out.spots + 1] = {
				key = w.key,
				title = w.title,
				sub = w.sub,
				flight = "",
				yield = w.verb.gain or ("from %d"):format(math.max(1, r.zone.base or 1)),
				yieldTone = w.color,
				right = "now",
				confidence = "classic",
				selected = false,
				zone = r.zone,
			}
		end
		for i, r in ipairs(rk.locked) do
			if i > 3 then
				break
			end
			out.spots[#out.spots + 1] = {
				key = "fish:" .. tostring(r.zone.zone),
				title = r.zone.zone,
				sub = "Any water in the zone",
				flight = "",
				locked = ("needs %d, you have %d"):format(r.zone.base or 0, q.skill or 0),
				yield = ("needs %d"):format(r.zone.base or 0),
				yieldTone = "warn",
				right = "later",
				confidence = "classic",
				selected = false,
				zone = r.zone,
			}
		end
		for _, row in ipairs(out.spots) do
			if row.key == q.selected then
				chosen = row
			end
		end
		chosen = chosen or out.spots[1]
		if chosen then
			chosen.selected = true
			out.selected = W.fishWhere(q, chosen.zone)
		end
	else
		local rk = W.rank(q, q.skill, q.level)
		local byKey = {}
		for i, r in ipairs(rk.now) do
			if i > W.LIST_MAX then
				break
			end
			local row = listRow(q, r, "now")
			out.spots[#out.spots + 1] = row
			byKey[row.key] = r.spot
		end
		-- the next bracket: where the route goes once the best spot here runs dry
		if q.skill then
			local it = W.itinerary(q, q.skill, q.top)
			for _, leg in ipairs(it.legs) do
				if leg.from > q.skill and leg.spot and not byKey[leg.spot.id] then
					local row =
						listRow(q, W.rate(q, leg.spot, leg.from, levelAt(q, leg.from)), ("at %d"):format(leg.from))
					row.yield, row.yieldTone = ("At %d move here"):format(leg.from), "bone"
					out.spots[#out.spots + 1] = row
					byKey[row.key] = leg.spot
					out.nextAt = leg.from
					break
				end
			end
			if #rk.now == 0 then
				local hole = it.holes[1]
				out.empty = hole
						and ("Nothing mapped for %s %d to %d: %s."):format(q.name, hole.from, hole.to, hole.reason)
					or ("Nothing gives %s points at %d."):format(q.name, q.skill)
			end
		end
		for i, r in ipairs(rk.locked) do
			if i > 3 then
				break
			end
			if not byKey[r.spot.id] then
				local row = listRow(q, r, "later")
				out.spots[#out.spots + 1] = row
				byKey[row.key] = r.spot
			end
		end
		for _, row in ipairs(out.spots) do
			if row.key == q.selected then
				chosen = row
			end
		end
		chosen = chosen or out.spots[1]
		if chosen then
			chosen.selected = true
			out.selected = W.where(q, byKey[chosen.key])
		elseif q.skill then
			local hole = W.itinerary(q, q.skill, q.top).holes[1]
			out.selected =
				W.emptyWhere(q, hole and hole.from or q.skill, hole and hole.to or q.top, hole and hole.reason)
		end
	end
	if #out.spots == 0 and not out.empty then
		out.empty = ("No %s spot in the data."):format(q.name)
	end
	return out
end

-- The stretches of a world skill its nodes level, for the planner (Planner.prepare's input.world): the route's legs
-- from `from` to `to` as { from, to, text = "Mine nodes: <place>", spot, why = "from mining nodes" }; a stretch no
-- spot covers is left out (it stays a hole). q as W.query's.
local GATHER = { [186] = { "Mine nodes", "from mining nodes" }, [182] = { "Gather herbs", "from herb nodes" } }
function W.worldStretches(q, from, to)
	q = W.query(q)
	local out = {}
	local words = GATHER[q.line] or { "Gather in the world", "from gathering nodes" }
	local it = W.itinerary(q, from, to)
	for _, leg in ipairs(it.legs or {}) do
		if num(leg.from) and num(leg.to) and leg.to > leg.from then
			local place = leg.title or leg.text
			out[#out + 1] = {
				from = leg.from,
				to = leg.to,
				text = place and ("%s: %s"):format(words[1], tostring(place)) or words[1],
				spot = leg.key,
				why = words[2],
			}
		end
	end
	return out
end

-- The journal's Path page of a world skill: "the route to 300". { profession, skill, to, rows = { { from, to,
-- title, sub, key, state = "done" | "now" | "todo" | "gap", tone } }, holes, complete, text }.
function W.worldPath(q)
	q = W.query(q)
	local it = W.itinerary(q, 1, q.top)
	local out =
		{ profession = q.name, skill = q.skill, to = q.top, rows = {}, holes = it.holes, complete = it.complete }
	out.text = it.text
	local all = {}
	for _, leg in ipairs(it.legs) do
		all[#all + 1] = leg
	end
	for _, h in ipairs(it.holes) do
		all[#all + 1] = { from = h.from, to = h.to, hole = h }
	end
	table.sort(all, function(a, b)
		return a.from < b.from
	end)
	for _, e in ipairs(all) do
		local row = { from = e.from, to = e.to, key = e.key }
		if e.hole then
			row.state, row.tone = "gap", "warn"
			row.title = ("Nothing mapped from %d to %d"):format(e.from, e.to)
			row.sub = e.hole.reason
		else
			row.title = e.text
			local s = q.skill
			row.state = s and (s >= e.to and "done" or (s >= e.from and "now" or "todo")) or "todo"
			row.tone = row.state == "done" and "ash" or (row.state == "now" and "bone" or "ash")
			if e.spot then
				local m = W.mobs(e.spot.mobs, levelAt(q, e.from))
				local fp = q.faction and e.spot.fp and e.spot.fp[q.faction]
				local parts = {}
				if m then
					parts[#parts + 1] = m.label
				end
				if fp then
					parts[#parts + 1] = ("flight: %s"):format(tostring(fp.name))
				end
				if e.spot.classic and not q.confirmed[e.spot.id] then
					parts[#parts + 1] = W.TEXT.classic
				end
				row.sub = table.concat(parts, ", ")
				row.action = { id = "selectSpot", label = "Open in Where", enabled = true, spot = e.spot.id }
			else
				row.sub = "any water in the zone"
			end
		end
		out.rows[#out.rows + 1] = row
	end
	return out
end

------------------------------------------------------------------------------------------------------------- live

-- The live values for one tick (design 7.1 `live`), from the model and the player's position. here = { map, x, y,
-- facing } normalised, or nil with `why`. prev = the last result (mode hysteresis, visits, legs done). opts = { now,
-- mode ("auto" | "travel" | "spot"), last (stop visited last), maps }.
function W.live(where, here, prev, opts)
	opts, prev = opts or {}, prev or {}
	local now = opts.now or 0
	local live =
		{ visited = W.fresh(prev.visited, now), legsDone = {}, mode = prev.mode or "travel", floor = prev.floor }
	for i, done in ipairs(prev.legsDone or {}) do
		live.legsDone[i] = done
	end
	if opts.mode == "travel" or opts.mode == "spot" then
		live.mode = opts.mode
	end
	if type(here) ~= "table" or not num(here.x) or not num(here.y) then
		live.ok, live.why = false, opts.why or W.TEXT.noPosition
		return live
	end
	live.ok, live.x, live.y, live.facing = true, here.x, here.y, num(here.facing)
	live.onMap = here.map == where.map
	local size = (opts.maps or {})[where.map]
	for i, leg in ipairs(where.travel or {}) do
		if not live.legsDone[i] and leg.x and leg.map == here.map then
			local d = W.yards((opts.maps or {})[leg.map], here.x, here.y, leg.x, leg.y)
			if d and d <= (leg.doneYd or 0) then
				live.legsDone[i] = true
			end
		end
		live.legsDone[i] = live.legsDone[i] or false
	end
	if not live.onMap then
		if opts.mode ~= "spot" then
			live.mode = "travel"
		end
		return live
	end
	local a = where.area
	local centre = a and W.yards(size, here.x, here.y, a.x, a.y) or nil
	if centre and opts.mode ~= "travel" and opts.mode ~= "spot" then
		if centre <= (where.enterYd or 0) then
			live.mode = "spot"
		elseif centre >= (where.leaveYd or math.huge) then
			live.mode = "travel"
		end
	end
	if where.route and live.mode == "spot" then
		local nx = W.nextStop(where.route, here, { visited = live.visited, now = now, last = opts.last, size = size })
		if nx then
			live.nextIndex, live.yards, live.bearing, live.compass = nx.index, nx.yards, nx.bearing, nx.compass
			local lastPt = opts.last and where.route.pts[opts.last]
			live.floor = lastPt and lastPt.floor or live.floor
		end
	end
	if not live.yards and a then
		live.yards = centre
		if centre then
			live.bearing = W.bearing(here.x, here.y, a.x, a.y, size)
			live.compass = W.compass(live.bearing)
		end
	end
	if not live.yards then
		live.why = "no distance: the size of this map is not in the data"
	end
	return live
end

-- The strings for one tick (design 7.1 V.whereLive): { dist, line2, visitedLine, trackerTitle, trackerRight, ticks,
-- floorWord }.
function W.whereLive(where, live, now)
	live = live or {}
	local out = { ticks = {} }
	if where.empty then
		out.dist, out.line2 = "", where.empty.title
		out.trackerTitle, out.trackerRight = where.empty.title, ""
		return out
	end
	local route = where.route
	out.trackerTitle = where.title
	if live.ok == false then
		out.dist, out.trackerRight = W.TEXT.noPositionShort, W.TEXT.noPositionShort
		out.line2 = live.why or W.TEXT.noPosition
		return out
	end
	if live.ok and not live.onMap then
		local leg = where.travel and where.travel[1]
		out.dist = where.flight and ("via " .. tostring(where.flight.name)) or "another zone"
		out.trackerRight = out.dist
		out.line2 = leg and (leg.text .. ". " .. W.TEXT.otherMap) or W.TEXT.otherMap
		return out
	end
	out.dist = W.yd(live.yards) or W.TEXT.noDistance
	out.trackerRight = out.dist
	local stop = route and live.nextIndex and route.pts[live.nextIndex]
	if stop then
		local ty = route.types[stop.pk] or {}
		if stop.floor and live.floor then
			out.floorWord = stop.floor == live.floor and "this floor"
				or (stop.floor > live.floor and "upstairs" or "downstairs")
		end
		local parts = { ("Stop %d of %d: %s"):format(stop.n, #route.pts, tostring(ty.name or "stop")) }
		if live.yards then
			parts[#parts + 1] = live.compass and ("%s %s"):format(W.yd(live.yards), live.compass) or W.yd(live.yards)
		end
		parts[#parts + 1] = out.floorWord
		out.line2 = table.concat(parts, ", ")
		out.trackerTitle = ("Stop %d of %d"):format(stop.n, #route.pts)
		for i, p in ipairs(route.pts) do
			local seen = live.visited and live.visited[i] and (not now or live.visited[i] > now)
			out.ticks[i] = {
				state = i == live.nextIndex and "next" or (seen and "done" or "todo"),
				raised = (p.floor and stop.floor and p.floor ~= stop.floor) or false,
			}
		end
	elseif where.kind == "errand" then
		local cur
		for _, s in ipairs(where.stops or {}) do
			if s.state == "now" then
				cur = s
			end
		end
		out.line2 = cur and ("%s: %s"):format(cur.name, cur.what) or W.TEXT.noErrand
		if cur and live.yards then
			out.line2 = live.compass and ("%s, %s %s"):format(out.line2, W.yd(live.yards), live.compass) or out.line2
		end
	else
		local legText
		for i, leg in ipairs(where.travel or {}) do
			if not (live.legsDone and live.legsDone[i]) then
				legText = leg.text
				break
			end
		end
		local dir = live.yards and live.compass and ("%s %s"):format(W.yd(live.yards), live.compass) or nil
		out.line2 = legText and (dir and ("%s. Now %s"):format(legText, dir) or legText) or (dir or where.sub)
	end
	out.visitedLine = now and W.visitedLine(live.visited, now) or nil
	return out
end

-- The tracker (design 7.2): the compact state of a `where` at this tick.
function W.tracker(where, live, now)
	live = live or {}
	local s = W.whereLive(where, live, now)
	local t =
		{ key = where.key, color = where.color, title = s.trackerTitle, right = s.trackerRight, rightTone = "bone" }
	if live.ok == false or (live.ok and not live.onMap) then
		t.rightTone = "ash"
	end
	t.mobs = where.mobs and { label = where.mobs.label, tone = where.mobs.tone } or nil
	if where.empty then
		t.sub, t.bar = where.empty.text, { kind = "steps", done = 0, total = 0 }
		return t
	end
	local route = where.route
	local stop = route and live.nextIndex and route.pts[live.nextIndex]
	if where.kind == "errand" then
		local stops, done, cur = where.stops or {}, 0, nil
		for _, st in ipairs(stops) do
			if st.state == "done" then
				done = done + 1
			elseif st.state == "now" and not cur then
				cur = st
			end
		end
		if cur then
			t.title = ("%d of %d: %s"):format(cur.n, #stops, cur.name)
			t.sub = cur.what
			t.target = cur.target and { name = cur.target } or nil
			local rest = {}
			for _, st in ipairs(stops) do
				if st.n > cur.n then
					rest[#rest + 1] = st.kind == "auction" and "AH" or st.kind
				end
			end
			t.gain = #rest > 0 and ("then " .. table.concat(rest, ", ")) or nil
			t.gainTone = "ash"
		else
			t.sub = "All stops done"
		end
		t.bar = { kind = "steps", done = done, total = #stops }
	elseif stop then
		local ty = route.types[stop.pk] or {}
		t.sub = ty.name
		local band = stop.band
		if band and ty.req then
			-- the colour holds until the skill reaches the band's end
			local b = W.bandsOf(ty.req, where.bands)
			local to = band == "orange" and b.yellow or (band == "yellow" and b.green or b.grey)
			t.gain, t.gainTone = ("%s to %d"):format(band, to), band
		end
		if #route.pts > 20 then
			local done = 0
			for _, tk in ipairs(s.ticks) do
				done = done + (tk.state == "done" and 1 or 0)
			end
			t.bar = { kind = "steps", done = done, total = #route.pts }
		else
			t.bar = { kind = "ticks", ticks = s.ticks }
		end
	else
		local leg
		for i, l in ipairs(where.travel or {}) do
			if not (live.legsDone and live.legsDone[i]) then
				leg = l
				break
			end
		end
		t.sub = leg and leg.text or where.sub
		local y = where.yields
		local row = y and y.rows[1]
		if row then
			t.gain = row.right
			t.gainTone = row.tone
			t.bar = { kind = "band", segs = row.segs, axis = y.axis, skill = y.skill }
		else
			t.bar = { kind = "steps", done = 0, total = 0 }
		end
	end
	return t
end

----------------------------------------------------------------------------------------------------------- errand

-- Data/Trainers.lua rows as Guide NPC records for one faction: rows without a position, of the other faction, or
-- that only drop a recipe are left out; role "recipes" rows are vendors (their `sells`). Each record carries
-- confidence "classic" when its position is from Classic data.
function W.trainerRecords(rows, faction)
	local out = {}
	for _, r in ipairs(rows or {}) do
		local side = r.faction
		local mine = side == nil or side == "B" or faction == nil or side == faction
		if mine and not r.nopos and r.map and num(r.x) and r.role ~= "recipedrop" then
			local sells
			if r.sells then
				sells = {}
				for _, item in ipairs(r.sells) do
					sells[item] = true
				end
			end
			out[#out + 1] = {
				id = r.id,
				name = r.name,
				map = r.map,
				x = r.x,
				y = r.y,
				place = r.place,
				sells = sells,
				trains = r.role == "trainer" and r.trains or nil,
				seed = true,
				limited = r.limited,
				unsure = r.unsure,
				confidence = r.classic and "classic" or "confirmed",
			}
		end
	end
	return out
end

local STOP_ORDER = { trainer = 1, vendor = 2, auction = 3 }

-- The errand of a city step: per city that serves the step's needs, the stops in walking order. ctx = { step,
-- profession, npcs (Guide.known records, positions in map percent), here, maps, have = fn(item), nameOf =
-- fn(item), money = fn(copper), done = { [kind] = true }, color }. Cities that serve every need come first, then
-- the nearest. Returns a list of `where` models (kind "errand"), best first; empty when the step needs no visit.
-- The needs and who serves them are Guide.lua's (needsOf, pending, serves); the grouping is by the NPC's `place`.
function W.errands(ctx)
	local G = ns.Guide
	local q = W.query(ctx)
	local step = ctx.step
	local needs = G.needsOf(step, ctx.profession)
	if ctx.have then
		needs = G.pending(needs, ctx.have)
	end
	if #needs == 0 then
		return {}
	end
	local each = {}
	for _, b in ipairs(type(step) == "table" and step.buy or {}) do
		each[b.item] = b.each
	end
	local nameOf = ctx.nameOf or function(item)
		return "item " .. tostring(item)
	end
	local cities, order = {}, {}
	for _, npc in ipairs(ctx.npcs or {}) do
		local city = npc.place or (q.maps[npc.map] and q.maps[npc.map].name) or ("map " .. tostring(npc.map))
		for ni, need in ipairs(needs) do
			local s = G.serves(npc, need)
			if s > 0 then
				local c = cities[city]
				if not c then
					c = { name = city, picks = {} }
					cities[city] = c
					order[#order + 1] = c
				end
				local d = q.here
						and q.here.map == npc.map
						and W.yards(q.maps[npc.map], q.here.x, q.here.y, npc.x / 100, npc.y / 100)
					or nil
				local cur = c.picks[ni]
				local better = not cur or s > cur.s
				if cur and s == cur.s then
					if (d or math.huge) ~= (cur.d or math.huge) then
						better = (d or math.huge) < (cur.d or math.huge)
					else
						better = tostring(npc.id) < tostring(cur.npc.id)
					end
				end
				if better then
					c.picks[ni] = { npc = npc, s = s, d = d, need = need }
				end
			end
		end
	end
	local out = {}
	for _, c in ipairs(order) do
		local stops = {}
		for ni = 1, #needs do
			if c.picks[ni] then
				stops[#stops + 1] = c.picks[ni]
			end
		end
		c.served = #stops
		-- walking order: trainers first (a rank or recipe gates the purchase), then nearest neighbour from the player
		local pos = q.here
				and stops[1]
				and q.here.map == stops[1].npc.map
				and { x = q.here.x * 100, y = q.here.y * 100 }
			or nil
		local sorted, left = {}, {}
		for _, s in ipairs(stops) do
			left[#left + 1] = s
		end
		while #left > 0 do
			local bi, bk
			for i, s in ipairs(left) do
				local d = pos and s.npc.map == (sorted[#sorted] or s).npc.map and legUnits(pos, s.npc, W.ASPECT) or 0
				local key = (s.need.kind == "trainer" and 0 or 1) * 1e6 + d * 1e3 + (STOP_ORDER[s.need.kind] or 9)
				if not bk or key < bk then
					bi, bk = i, key
				end
			end
			local s = table.remove(left, bi)
			sorted[#sorted + 1] = s
			pos = { x = s.npc.x, y = s.npc.y }
		end
		local w = { kind = "errand", profession = ctx.profession, color = ctx.color or "gold", title = c.name }
		w.key = ("errand:%s:%s"):format(tostring(G.stepKey(step)), c.name)
		w.map = sorted[1].npc.map
		w.stops, w.pins = {}, {}
		local prevPt = q.here and q.here.map == w.map and { x = q.here.x, y = q.here.y } or nil
		local total, anyClassic, nowSet = 0, false, false
		for n, s in ipairs(sorted) do
			local npc, need = s.npc, s.need
			local stop = { n = n, kind = need.kind, name = npc.name, place = npc.place or c.name }
			stop.x, stop.y, stop.map = npc.x / 100, npc.y / 100, npc.map
			stop.confidence = npc.confidence or ((npc.seed and not npc.seen) and "classic" or "confirmed")
			anyClassic = anyClassic or stop.confidence == "classic"
			stop.target = npc.name
			if need.kind == "trainer" then
				stop.what = need.name and ("Learn %s"):format(tostring(need.name))
					or ("Train %s"):format(tostring(ctx.profession))
				local cost = type(step) == "table" and num(step.cost) or nil
				stop.cost = cost and q.money and q.money(cost) or nil
			else
				local names, sum, priced = {}, 0, true
				for i, it in ipairs(need.items) do
					if i <= 2 then
						names[#names + 1] = ("%d %s"):format(it.count, nameOf(it.item))
					end
					if each[it.item] then
						sum = sum + each[it.item] * it.count
					else
						priced = false
					end
				end
				if #need.items > 2 then
					names[#names + 1] = ("%d more"):format(#need.items - 2)
				end
				stop.what = "Buy " .. table.concat(names, ", ")
				stop.cost = priced and q.money and q.money(sum) or nil
				if need.kind == "vendor" and s.s < #need.items then
					stop.what = stop.what .. " (sells only some)"
				end
			end
			if ctx.done and ctx.done[need.kind] then
				stop.state = "done"
			elseif not nowSet then
				stop.state, nowSet = "now", true
			else
				stop.state = "todo"
			end
			local d = prevPt and stop.map == w.map and W.yards(q.maps[stop.map], prevPt.x, prevPt.y, stop.x, stop.y)
				or nil
			stop.yards = d
			stop.leg = d and ((n == 1 and "" or "+") .. W.yd(d)) or ""
			total = total + (d or 0)
			prevPt = { x = stop.x, y = stop.y }
			w.stops[n] = stop
			w.pins[n] = {
				id = "stop" .. n,
				kind = "stop",
				x = stop.x,
				y = stop.y,
				n = n,
				state = stop.state,
				confidence = stop.confidence,
				tip = ("%s: %s"):format(stop.name, stop.what),
				label = stop.name,
			}
		end
		c.yards = sorted[1].d
		w.sub = plural(#sorted, "stop") .. (c.served < #needs and (", %d of %d errands"):format(c.served, #needs) or "")
		w.verb = { text = ("Run the errands in %s"):format(c.name), gain = total > 0 and W.yd(total) or nil }
		w.confidence = anyClassic and "classic" or "confirmed"
		w.tag = anyClassic and W.TEXT.classic or nil
		local view = bbox(w.stops, 0.12, 0.05)
		w.views = { travel = view, spot = view }
		w.enterYd, w.leaveYd = 0, 0
		w.travel = {}
		w.caption = { line1 = ("%s, %s"):format(c.name, w.sub) }
		w.caption.line3 = c.served < #needs and "This city cannot serve every errand of the step." or nil
		w.actions = {
			{ id = "pin", label = "Pin stop 1 on the map", enabled = true, stop = 1 },
			{ id = "journal", label = "Open the journal", enabled = true, page = "where" },
		}
		c.where = w
		out[#out + 1] = c
	end
	table.sort(out, function(a, b)
		if a.served ~= b.served then
			return a.served > b.served
		end
		if (a.yards or math.huge) ~= (b.yards or math.huge) then
			return (a.yards or math.huge) < (b.yards or math.huge)
		end
		return a.name < b.name
	end)
	local list = {}
	for i, c in ipairs(out) do
		list[i] = c.where
	end
	return list
end

-- The best city's errand, or the "nothing to fetch" card.
function W.errand(ctx)
	local list = W.errands(ctx)
	if list[1] then
		return list[1]
	end
	return {
		kind = "errand",
		key = "errand:none",
		profession = ctx.profession,
		color = "ash",
		title = "No errand",
		sub = "",
		stops = {},
		pins = {},
		actions = {},
		empty = {
			title = W.TEXT.noErrand,
			text = ctx.nextTrip or "The step to do now needs no trainer, vendor or auction house.",
		},
	}
end

--------------------------------------------------------------------------------------------------------- overview

local function moneyOf(ctx)
	return ctx.money or (ns.Logic and ns.Logic.money) or tostring
end

local function sentenceCase(s)
	s = tostring(s or "")
	return s:sub(1, 1):upper() .. s:sub(2)
end

local function sortedLines(set)
	local list = {}
	for line in pairs(set) do
		list[#list + 1] = line
	end
	table.sort(list)
	return list
end

-- The journal's Overview: one row per profession of the shipped recipes plus the world skills, also ones the
-- character lacks. ctx = { professions (ns.Data.recipes.professions), data (ns.Data.spots), skills = { [line] =
-- Skills.read result }, costFn = fn(line, prof, from, to) -> Planner.costToCap result | nil, why; level, faction,
-- class, money, nameOf = fn(item), icons = { [line] = texture }, priceAge }.
-- A row is "complete" or names every missing bracket and its reason; `holes` lists them all.
function W.overview(ctx)
	ctx = ctx or {}
	local money = moneyOf(ctx)
	local profs = ctx.professions or {}
	local world = type(ctx.data) == "table" and ctx.data.skills or {}
	local set = {}
	for line in pairs(profs) do
		set[line] = true
	end
	for line in pairs(world) do
		set[line] = true
	end
	local out = { rows = {}, holes = {}, totals = { tsmMissing = 0, priceAge = ctx.priceAge or "prices not read yet" } }
	for _, line in ipairs(sortedLines(set)) do
		local prof, def = profs[line], world[line]
		local name = (def and def.name) or (prof and prof.name) or ("Skill " .. tostring(line))
		local s = (ctx.skills or {})[line] or {}
		local row = { key = line, name = name, icon = ctx.icons and ctx.icons[line] or nil, tsmMissing = 0 }
		row.usable = s.available ~= false
		row.learned = s.learned == true or num(s.rank) ~= nil
		row.skill, row.cap = num(s.rank), num(s.cap)
		row.why = (not row.usable and s.why and (s.why:gsub("^not available: ", ""))) or nil
		row.cost = { mats = "none", recipes = "none", training = "none" }
		row.coverage = { done = row.skill or 0, gaps = {} }
		local top = (prof and num(prof.to)) or W.TOP
		local from = row.skill or 1
		if not row.usable then
			row.status, row.statusText, row.state = "nodata", row.why or "not available", "not available"
			row.line, row.lineTone = row.why, "ash"
		elseif from >= top then
			row.status, row.statusText, row.state = "complete", "complete", "at cap"
			row.line, row.lineTone = ("At %d: nothing left to level."):format(from), "ash"
			row.cost.total, row.cost.copper = money(0), 0
		elseif def then
			-- a world skill: the spots cover it or the row names what is missing
			local q = W.query({
				data = ctx.data,
				line = line,
				skill = row.skill,
				cap = row.cap,
				level = ctx.level,
				faction = ctx.faction,
				class = ctx.class,
			})
			local it = W.itinerary(q, from, top)
			for _, h in ipairs(it.holes) do
				row.coverage.gaps[#row.coverage.gaps + 1] = { from = h.from, to = h.to, reason = h.reason, lacks = {} }
			end
			row.spots = it.spots
			row.cost.total, row.cost.copper = "no materials", 0
			local training = 0
			for _, rk in ipairs(prof and prof.ranks or {}) do
				if (rk.cap or 0) > (row.cap or 0) and num(rk.cost) then
					training = training + rk.cost
				end
			end
			if training > 0 then
				row.cost.training, row.cost.total, row.cost.copper = money(training), money(training), training
			end
			row.note = it.text
		else
			local r, why
			if ctx.costFn then
				r, why = ctx.costFn(line, prof, from, top)
			else
				why = "no cost function (the planner is not loaded)"
			end
			if type(r) ~= "table" then
				row.coverage.gaps[1] =
					{ from = from, to = top, reason = why or "the planner gave no result", lacks = {} }
				row.status = "nodata"
			else
				local lacks = {}
				for _, item in ipairs(r.unknownItems or {}) do
					lacks[#lacks + 1] = ctx.nameOf and ctx.nameOf(item) or ("item " .. tostring(item))
				end
				row.tsmMissing = num(r.unknownPrices) or #lacks
				-- items the plan uses that have no price (they never make a hole): named on the card's tooltip
				row.unpriced = {}
				for _, u in ipairs(type(r.unpriced) == "table" and r.unpriced.items or {}) do
					local item = type(u) == "table" and u.item or u
					row.unpriced[#row.unpriced + 1] = type(u) == "table" and u.name
						or (ctx.nameOf and ctx.nameOf(item))
						or ("item " .. tostring(item))
				end
				for _, g in ipairs(r.gaps or {}) do
					row.coverage.gaps[#row.coverage.gaps + 1] =
						{ from = g.from, to = g.to, reason = g.why or "no recipe gives skill", lacks = lacks }
				end
				local recipes = 0
				for _, b in ipairs(r.recipesToBuy or {}) do
					recipes = recipes + (num(b.price) or 0)
				end
				local mats = (num(r.spent) or 0) - (num(r.back) or 0)
				if not num(r.spent) and num(r.total) then
					mats = r.total - recipes - (num(r.trainingCost) or 0)
				end
				row.cost.copper = num(r.total)
				row.cost.total = num(r.total) and money(r.total) or nil
				row.cost.mats = mats ~= 0 and money(mats) or "none"
				row.cost.recipes = recipes > 0 and money(recipes) or "none"
				row.cost.training = (num(r.trainingCost) or 0) > 0 and money(r.trainingCost) or "none"
				if row.tsmMissing > 0 then
					row.note = ("TSM lacks %s"):format(plural(row.tsmMissing, "price"))
				end
			end
		end
		if not row.status then
			local gaps = row.coverage.gaps
			if #gaps == 0 then
				row.status, row.statusText = "complete", "complete"
				row.line, row.lineTone = row.note, "ash"
			else
				row.status = "gaps"
				row.statusText = plural(#gaps, "gap")
				local g = gaps[1]
				row.line = ("%d to %d: %s"):format(g.from, g.to, g.reason)
				if row.tsmMissing > 0 then
					row.line = row.line .. (". TSM lacks %s"):format(plural(row.tsmMissing, "price"))
				end
				row.lineTone = "warn"
			end
		elseif row.status == "nodata" and row.usable then
			local g = row.coverage.gaps[1]
			row.statusText = "no data"
			row.line, row.lineTone = g and ("%d to %d: %s"):format(g.from, g.to, g.reason) or "no data", "warn"
		end
		-- the card's two lines: what it costs and whether the path is whole
		local gaps = row.coverage.gaps
		row.unpriced = row.unpriced or {}
		local unknown = math.max(#row.unpriced, row.tsmMissing or 0)
		if not row.usable then
			row.costText, row.costTone = "", "ash"
			row.coverText, row.coverTone = sentenceCase(row.why or "not available"), "ash"
		elseif from >= top then
			row.costText, row.costTone = ("At %d: nothing left to level"):format(from), "ash"
			row.coverText, row.coverTone = "Path complete", "green"
		else
			if def then
				row.costText = row.cost.copper > 0 and ("To %d: %s for training"):format(top, row.cost.total)
					or "No cost: gathering"
				row.costTone = "bone"
			elseif row.cost.total then
				row.costText = ("To %d: %s%s"):format(top, row.cost.total, unknown > 0 and " + unpriced" or "")
				row.costTone = unknown > 0 and "warn" or "bone"
			elseif unknown > 0 then
				row.costText, row.costTone = ("Price unknown for %s"):format(plural(unknown, "item")), "warn"
			else
				row.costText, row.costTone = sentenceCase(gaps[1] and gaps[1].reason or "no cost yet"), "ash"
			end
			if row.status == "complete" then
				row.coverText, row.coverTone = "Path complete", "green"
			elseif row.status == "gaps" then
				row.coverText = #gaps == 1 and ("1 gap: %d to %d"):format(gaps[1].from, gaps[1].to)
					or ("%d gaps, first %d to %d"):format(#gaps, gaps[1].from, gaps[1].to)
				row.coverTone = "warn"
			else
				row.coverText, row.coverTone = "No plan yet", "ash"
			end
		end
		row.state = row.state
			or (
				row.learned and (row.cap and row.skill and row.skill >= row.cap and "at rank cap" or "learned")
				or "not learned"
			)
		row.skillText = row.skill and (row.cap and ("%d / %d"):format(row.skill, row.cap) or tostring(row.skill))
			or (row.usable and W.TEXT.notLearned or (row.why or "not available"))
		for _, g in ipairs(row.coverage.gaps) do
			out.holes[#out.holes + 1] =
				{ key = line, name = name, from = g.from, to = g.to, reason = g.reason, lacks = g.lacks }
		end
		out.totals.tsmMissing = out.totals.tsmMissing + row.tsmMissing
		out.rows[#out.rows + 1] = row
	end
	table.sort(out.rows, function(a, b)
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.key < b.key
	end)
	table.sort(out.holes, function(a, b)
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.from < b.from
	end)
	return out
end

------------------------------------------------------------------------------------------------------------- path

local function stepStart(steps, i, skill)
	for k = i, #steps do
		local st = steps[k]
		if st.kind == "craft" or st.kind == "gap" or st.kind == "world" then
			return st.from
		end
	end
	for k = i - 1, 1, -1 do
		local st = steps[k]
		if st.kind == "craft" or st.kind == "gap" or st.kind == "world" then
			return st.to
		end
	end
	return skill
end

local function buyCost(st)
	if st.cash and num(st.cash.out) then
		return st.cash.out
	end
	local sum, any = 0, false
	for _, b in ipairs(st.buy or {}) do
		if num(b.each) then
			sum, any = sum + b.each * b.count, true
		end
	end
	return any and sum or nil
end

-- Joins names with commas inside a budget of characters: what does not fit becomes "and N more", so a line never
-- ends in an ellipsis. Always shows at least the first part.
function W.fitList(parts, budget)
	local out, used = {}, 0
	for i, s in ipairs(parts) do
		local rest = #parts - i
		local tail = rest > 0 and (#(" and %d more"):format(rest)) or 0
		if i > 1 and used + 2 + #s + tail > budget then
			return table.concat(out, ", ") .. (" and %d more"):format(#parts - i + 1)
		end
		out[#out + 1] = s
		used = used + #s + (i > 1 and 2 or 0)
	end
	return table.concat(out, ", ")
end

-- The plan as the lines a person reads: one line per stretch of crafting. "Train X" or "Buy recipe X" directly
-- before "Craft X" is folded into it ("Learn and craft 43 Copper Dagger"); a rank training is not a line, it hangs
-- on the line it comes before (`rank`), so the page can show it with the stretch it unlocks. Numbers are continuous.
-- steps = the planner's steps. Returns lines = { { n, kind = "craft"|"gap"|"unlock", step (index of the craft, the
-- gap or the lone unlock: what a click selects), steps = { indices folded in }, verb, title, short, from, to,
-- color, crafts, expected, learn = { kind = "train"|"buyRecipe", at, cost, where, owned, unchecked } | nil,
-- rank = { name, skill, cap, cost, step, at, by, level, have } | nil, cost (copper, priced parts only) | nil,
-- unpriced = { names },
-- ways } }.
function W.lines(steps, ctx)
	ctx = ctx or {}
	local nameOf = ctx.nameOf or function(item)
		return "item " .. tostring(item)
	end
	local lines, pending, rank = {}, {}, nil
	local function push(line)
		line.n = #lines + 1
		line.rank, rank = rank, nil
		lines[line.n] = line
	end
	-- an unlock whose craft never came: it stays a line of its own
	local function flush()
		for _, u in ipairs(pending) do
			local st = steps[u]
			local at = math.floor(num(st.at) or num(st.learn) or 0)
			push({
				kind = "unlock",
				step = u,
				steps = { u },
				verb = st.kind == "buyRecipe" and "Buy the recipe for" or "Learn",
				title = ("%s %s"):format(st.kind == "buyRecipe" and "Buy the recipe for" or "Learn", tostring(st.name)),
				from = at,
				to = at,
				color = "gold",
				cost = num(st.cost) or num(st.price),
				unpriced = {},
				ways = 0,
			})
			lines[#lines].short = lines[#lines].title
		end
		pending = {}
	end
	for i, st in ipairs(steps or {}) do
		if st.kind == "trainRank" then
			rank = {
				name = tostring(st.name or "the next rank"),
				skill = math.floor(num(st.skill) or num(st.at) or num(st.by) or 0),
				cap = num(st.cap),
				cost = num(st.cost),
				step = i,
				at = num(st.at) or num(st.skill),
				by = num(st.by),
				level = num(st.level),
				have = num(st.have),
			}
		elseif st.kind == "train" or st.kind == "buyRecipe" then
			pending[#pending + 1] = i
		elseif st.kind == "craft" then
			local learn, folded, keep = nil, { i }, {}
			for _, u in ipairs(pending) do
				local us = steps[u]
				if us.spell ~= nil and us.spell == st.spell and not learn then
					learn = {
						kind = us.kind,
						at = math.floor(num(us.at) or num(us.learn) or 0),
						cost = num(us.cost) or num(us.price),
						where = us.where,
						owned = us.owned,
						unchecked = us.unchecked,
						step = u,
					}
					table.insert(folded, 1, u)
				else
					keep[#keep + 1] = u
				end
			end
			pending = keep
			flush()
			local verb = "Craft"
			if learn then
				verb = learn.kind == "buyRecipe"
						and (learn.owned and "Learn the recipe and craft" or "Buy the recipe and craft")
					or "Learn and craft"
			end
			local from, to = math.floor(st.from), math.floor(st.to + 0.5)
			local cost, unpriced = buyCost(st), {}
			if learn and learn.cost then
				cost = (cost or 0) + learn.cost
			end
			for _, u in ipairs(st.unpriced or {}) do
				unpriced[#unpriced + 1] = tostring(u.name or nameOf(u.item))
			end
			if learn and learn.kind == "buyRecipe" and not learn.cost and not learn.owned then
				unpriced[#unpriced + 1] = "the recipe"
			end
			local title = ("%s %d %s"):format(verb, st.crafts or 0, tostring(st.name))
			push({
				kind = "craft",
				step = i,
				steps = folded,
				verb = verb,
				title = title,
				short = ("%s, %d to %d"):format(title, from, to),
				from = from,
				to = to,
				color = st.color or "bone",
				crafts = st.crafts or 0,
				expected = num(st.expected) and math.ceil(st.expected) or nil,
				learn = learn,
				cost = cost,
				unpriced = unpriced,
				ways = #(st.others or {}) + #(st.shortcuts or {}),
			})
		elseif st.kind == "gap" then
			flush()
			local from, to = math.floor(st.from), math.floor(st.to)
			local title = ("No recipe from %d to %d"):format(from, to)
			push({
				kind = "gap",
				step = i,
				steps = { i },
				verb = "No recipe",
				title = title,
				short = title,
				from = from,
				to = to,
				color = "warn",
				reason = st.reason,
				why = st.why or "no recipe in the data gives skill here",
				unpriced = {},
				ways = #(st.shortcuts or {}),
			})
		elseif st.kind == "world" then
			-- levelled on nodes (Mining between its smelting recipes): no gold cost, never a hole
			flush()
			local from, to = math.floor(st.from), math.floor(st.to)
			local title = tostring(st.name or "Gather in the world")
			push({
				kind = "world",
				step = i,
				steps = { i },
				verb = "Gather",
				title = title,
				short = ("%s, %d to %d"):format(title, from, to),
				from = from,
				to = to,
				color = "bone",
				spot = st.spot,
				why = st.why or "from gathering nodes",
				unpriced = {},
				ways = 0,
			})
		end
	end
	flush()
	return lines
end

-- Cuts rows that carry `from` and `to` into stretches that each fit a list of `max` rows: first at the rank caps
-- (1-75, 75-150, ...), then a stretch that is still too long is cut into equal parts. Every row is in exactly one
-- stretch, in order. Returns stretches = { { index, from, to, label = "75 to 150", name = "Journeyman" | nil,
-- rows, ranks = { the rank trainings hung on its rows }, done, current } } and the index of the current one (the
-- first that ends above `skill`; the last when all are behind).
function W.stretches(rows, caps, skill, max)
	max = math.max(1, max or 8)
	skill = num(skill) or 1
	local bounds = {}
	for _, c in ipairs(caps or {}) do
		if num(c.at) then
			bounds[#bounds + 1] = { at = c.at, name = c.label and tostring(c.label):match("^(%a[%a ]-)%s+%d+$") or nil }
		end
	end
	table.sort(bounds, function(a, b)
		return a.at < b.at
	end)
	local groups, cur = {}, nil
	local function capOf(from)
		for _, b in ipairs(bounds) do
			if from < b.at then
				return b
			end
		end
		return nil
	end
	for _, r in ipairs(rows or {}) do
		local b = capOf(num(r.from) or 0)
		if not cur or cur.cap ~= b then
			cur = { cap = b, rows = {} }
			groups[#groups + 1] = cur
		end
		cur.rows[#cur.rows + 1] = r
	end
	local out = {}
	for _, g in ipairs(groups) do
		local parts = math.ceil(#g.rows / max)
		local per = math.ceil(#g.rows / parts)
		for p = 1, parts do
			local s = { rows = {}, ranks = {}, name = g.cap and g.cap.name or nil }
			for k = (p - 1) * per + 1, math.min(#g.rows, p * per) do
				local r = g.rows[k]
				s.rows[#s.rows + 1] = r
				if r.rank then
					s.ranks[#s.ranks + 1] = r.rank
				end
			end
			if #s.rows > 0 then
				s.from, s.to = s.rows[1].from, s.rows[#s.rows].to
				for _, r in ipairs(s.rows) do
					s.to = math.max(s.to or 0, num(r.to) or 0)
				end
				s.label = ("%d to %d"):format(s.from or 0, s.to or 0)
				s.index = #out + 1
				s.done = (s.to or 0) <= skill
				out[s.index] = s
			end
		end
	end
	local current = #out
	for i, s in ipairs(out) do
		if not s.done then
			current = i
			break
		end
	end
	if out[current] then
		out[current].current = true
	end
	return out, current
end

W.PATH_MAX = 6 -- lines in one stretch of the Path page: JournalUI lays 6 rows of 46 px under the stretch header
W.PATH_SUB = 54 -- characters of a row's second line (about 280 px of 10-px text)
W.CAPS = {
	{ at = 75, label = "Apprentice 75" },
	{ at = 150, label = "Journeyman 150" },
	{ at = 225, label = "Expert 225" },
	{ at = 300, label = "Artisan 300" },
}
local BAND_WORD = { orange = "orange", yellow = "yellow", green = "green", grey = "grey" }

local function sentence(s)
	s = tostring(s or "")
	if s == "" then
		return s
	end
	s = s:sub(1, 1):upper() .. s:sub(2)
	return s:match("[%.%?!]$") and s or (s .. ".")
end

-- "Price unknown for 2 items: A, B. Not in the cost."
local function unpricedText(names)
	return ("Price unknown for %s: %s. Not in the cost."):format(plural(#names, "item"), table.concat(names, ", "))
end

-- A material count the bags hold, or nil when the client cannot say (a failing lookup never breaks the page).
local function haveOf(ctx, item)
	if type(ctx.have) ~= "function" then
		return nil
	end
	local ok, n = pcall(ctx.have, item)
	return ok and num(n) or nil
end

-- "Train Journeyman at 50, 5s: needed to pass 75". The character level is said only when it is too low, or when
-- the rank asks for one and the level is not known (then without "unknown": "needs level 10").
local function rankText(rank, ctx, money)
	local parts = {}
	if rank.at then
		parts[#parts + 1] = ("at %d"):format(rank.at)
	elseif rank.by then
		parts[#parts + 1] = ("by %d"):format(rank.by)
	end
	parts[#parts + 1] = rank.cost and money(rank.cost) or "price not known yet"
	local need, have = rank.level, rank.have or num(ctx.level)
	if need and have and have < need then
		parts[#parts + 1] = ("needs level %d, you are %d"):format(need, have)
	elseif need and need > 1 and not have then
		parts[#parts + 1] = ("needs level %d"):format(need)
	end
	local pass
	for _, rk in ipairs(ctx.ranks or {}) do
		if num(rk.cap) and rank.cap and rk.cap < rank.cap and (not pass or rk.cap > pass) then
			pass = rk.cap
		end
	end
	return ("Train %s %s%s"):format(
		rank.name,
		table.concat(parts, ", "),
		pass and (": needed to pass %d"):format(pass) or ""
	)
end

-- "Get the recipe" of a craft line: { text, tone, known }.
local function recipeText(line, st, ctx, money)
	local learn = line.learn
	if not learn then
		local known = ctx.known and ctx.known[st.spell] == true
		return { text = known and "Known." or "Known, or learned earlier on this path.", tone = "green", known = true }
	end
	if learn.kind == "train" then
		local text = ("From the trainer at %d, %s."):format(
			learn.at,
			learn.cost and money(learn.cost) or "price not known yet"
		)
		if learn.unchecked then
			return { text = text .. " Not checked at a trainer yet.", tone = "parch" }
		end
		return { text = text, tone = "bone" }
	end
	if learn.owned then
		return { text = "The recipe is in your bags: learn it.", tone = "bone" }
	end
	return {
		text = ("Buy the recipe %s, %s."):format(
			learn.where == "vendor" and "from a vendor" or "on the auction house",
			learn.cost and money(learn.cost) or "price unknown"
		),
		tone = learn.cost and "bone" or "warn",
	}
end

-- A not-in-plan alternative of "Other ways": the only place the word shortcut is used.
local function shortcutWay(cut, money)
	return {
		label = tostring(cut.name),
		right = num(cut.saves) and ("shortcut, saves " .. money(cut.saves)) or "shortcut",
		picked = false,
		tip = (cut.needs or cut.why) and { tostring(cut.name), tostring(cut.needs or cut.why) } or nil,
		action = { id = "allow", label = "Use this shortcut", enabled = true, spell = cut.spell },
	}
end

-- The list row of one line: line 1 is the title (never cut), line 2 the usual count and the materials to buy,
-- fitted to W.PATH_SUB characters with "and N more" (the full list is `subFull`, in the tooltip).
local function lineRow(line, st, money, nameOf, skill)
	local row = {
		n = line.n,
		step = line.step,
		kind = line.kind == "craft" and "step" or line.kind,
		icon = st and st.icon or nil,
		title = line.title,
		from = line.from,
		to = line.to,
		rank = line.rank,
		rangeTone = line.color,
		done = line.kind ~= "unlock" and line.to <= skill,
		action = { id = "selectStep", step = line.step, enabled = true },
	}
	row.range = line.kind == "unlock" and ("at %d"):format(line.from) or ("%d to %d"):format(line.from, line.to)
	local tip = { line.title }
	if line.kind == "craft" then
		local lead = {}
		if line.expected and line.expected < line.crafts then
			lead[#lead + 1] = ("Usually %s."):format(plural(line.expected, "craft"))
		end
		local mats = {}
		for _, b in ipairs(st.buy or {}) do
			mats[#mats + 1] = ("%d %s"):format(b.count, nameOf(b.item))
		end
		local head = table.concat(lead, " ")
		if #mats > 0 then
			local pre = (head ~= "" and (head .. " ") or "") .. "Buy "
			row.sub = pre .. W.fitList(mats, W.PATH_SUB - #pre)
			row.subFull = pre .. table.concat(mats, ", ")
		else
			local tail = st.source ~= "buy" and "From your bags." or ""
			row.sub = head .. ((head ~= "" and tail ~= "") and " " or "") .. tail
			row.subFull = row.sub
		end
		tip[#tip + 1] = row.subFull
		row.cost = line.cost and money(line.cost) or nil
		if #line.unpriced > 0 then
			row.costNote = row.cost and "+ unpriced" or "price unknown"
			tip[#tip + 1] = { unpricedText(line.unpriced), "warn" }
		end
	elseif line.kind == "gap" then
		row.sub = sentence(line.why)
		row.subFull = row.sub
		tip[#tip + 1] = { row.sub, "warn" }
	elseif line.kind == "world" then
		row.sub = sentence(("%d to %d, %s, no gold"):format(line.from, line.to, line.why))
		row.subFull = row.sub
		tip[#tip + 1] = row.sub
	else
		local learn = st or {}
		row.sub = learn.kind == "buyRecipe"
				and (learn.owned and "In your bags: learn it." or (learn.where == "vendor" and "From a vendor." or "On the auction house."))
			or (learn.unchecked and "Not checked at a trainer yet." or "At the trainer.")
		row.subFull = row.sub
		row.cost = line.cost and money(line.cost) or nil
		tip[#tip + 1] = row.sub
	end
	row.tip = tip
	return row
end

-- Picks the selected row and the stretch shown, for a path whose `rows` carry from / to / step / done (W.path's and
-- the world skills' alike). ctx = { selected (a row's step), stretch (index a stretch button chose), max }. Sets
-- p.stretches (W.stretches' plus action, selected, head = { title, lines }), p.stretch, p.selected, p.shade (the
-- skill range the timeline shades) and p.crumb. The default selection is the first row that is not done.
function W.pathSelect(p, ctx)
	ctx = ctx or {}
	local rows = p.rows or {}
	local sel
	for _, r in ipairs(rows) do
		r.selected = false
		if ctx.selected ~= nil and r.step == ctx.selected then
			sel = r
		end
	end
	if not sel then
		for _, r in ipairs(rows) do
			if not r.done then
				sel = r
				break
			end
		end
	end
	sel = sel or rows[1]
	local caps = (p.caps and #p.caps > 0) and p.caps or W.CAPS
	local stretches, current = W.stretches(rows, caps, p.skill, ctx.max or W.PATH_MAX)
	local shown = num(ctx.stretch)
	if not (shown and stretches[shown]) then
		shown = nil
		for i, s in ipairs(stretches) do
			for _, r in ipairs(s.rows) do
				if r == sel then
					shown = i
				end
			end
		end
		shown = shown or current
	end
	for i, s in ipairs(stretches) do
		s.selected = i == shown
		s.action = { id = "selectStretch", index = i, enabled = true }
		s.state = s.current and "you are here" or (s.done and "done" or nil)
		s.head = { title = s.name and ("%s, %s"):format(s.name, s.label) or ("Skill " .. s.label), lines = {} }
		for _, rank in ipairs(s.ranks) do
			s.head.lines[#s.head.lines + 1] = rank.text or ("Train %s"):format(tostring(rank.name))
		end
		s.tip = { s.head.title, plural(#s.rows, "line") }
		for _, l in ipairs(s.head.lines) do
			s.tip[#s.tip + 1] = l
		end
	end
	p.stretches, p.stretch = stretches, stretches[shown] and shown or 0
	if sel then
		sel.selected = true
		p.selected = sel.step
		p.crumb = sel.title
	end
	local s = stretches[shown]
	p.shade = s and { from = s.from, to = s.to } or nil
	return p
end

-- The journal's Path page of a crafting profession, from the planner's plan (Planner.finish's or costToCap's
-- `steps`). ctx = { profession, skill, plan = { steps }, ranks (Data/Recipes.lua's), money, nameOf = fn(item),
-- have = fn(item), known = { [spell] = true }, selected (step index), stretch (index a stretch button chose),
-- level, errand = fn(step, line) -> where | nil }. Returns { profession, skill, caps, gates, segments, markers
-- (the timeline), lines (W.lines), rows (one per line, all of them), stretches, stretch, selected (the selected
-- line's step), shade, crumb, detail = { title, n, color, dothis = { { text, tone } }, recipe = { text, tone },
-- note, materials = { { name, need, have, right, tone } }, ways = { title, rows }, where, actions } }.
function W.path(ctx)
	ctx = ctx or {}
	local money = moneyOf(ctx)
	local steps = type(ctx.plan) == "table" and ctx.plan.steps or {}
	local skill = num(ctx.skill) or (type(ctx.plan) == "table" and num(ctx.plan.skill)) or 1
	local nameOf = ctx.nameOf or function(item)
		return "item " .. tostring(item)
	end
	local p =
		{ profession = ctx.profession, skill = skill, caps = {}, gates = {}, segments = {}, markers = {}, rows = {} }
	for _, rk in ipairs(ctx.ranks or {}) do
		if num(rk.cap) then
			p.caps[#p.caps + 1] = { at = rk.cap, label = ("%s %d"):format(tostring(rk.name or "Rank"), rk.cap) }
		end
		if num(rk.skill) then
			p.gates[#p.gates + 1] = rk.skill
		end
	end
	if skill > 1 then
		p.segments[1] = { from = 1, to = skill, name = "Done", done = true }
	end
	for i, st in ipairs(steps) do
		local at = math.floor(stepStart(steps, i, skill) or skill)
		-- `row` only words the markers' tooltips here; the list's rows are made from W.lines below
		local row = { n = i, ways = 0 }
		if st.kind == "craft" then
			local y, g = st.thresholds and st.thresholds[1], st.thresholds and st.thresholds[2]
			p.segments[#p.segments + 1] = {
				step = i,
				from = st.from,
				to = st.to,
				name = st.name,
				bands = W.recipeBands(st.from, st.to, y, g),
				done = false,
			}
			for _, cut in ipairs(st.shortcuts or {}) do
				if cut.bop then
					p.markers[#p.markers + 1] = {
						at = at,
						kind = "bop",
						step = i,
						confidence = "classic",
						tip = ("Shortcut: %s. %s"):format(
							tostring(cut.name),
							tostring(cut.why or "its recipe binds when picked up")
						),
					}
				end
			end
		elseif st.kind == "gap" then
			p.segments[#p.segments + 1] = {
				step = i,
				from = st.from,
				to = st.to,
				name = "No recipe",
				gap = { reason = st.why or "no recipe gives skill here" },
				done = false,
			}
		elseif st.kind == "world" then
			p.segments[#p.segments + 1] = {
				step = i,
				from = st.from,
				to = st.to,
				name = tostring(st.name or "Gather"),
				bands = { { from = st.from, to = st.to, color = "bone" } },
				world = true,
				done = false,
			}
		else
			local m = { step = i, confidence = "confirmed" }
			if st.kind == "buyRecipe" then
				m.at = num(st.learn) or at
				m.kind = st.where == "vendor" and "vendor" or "ah"
				row.title = ("Buy the recipe for %s"):format(tostring(st.name))
				row.sub = st.owned and "in your bags: learn it"
					or (m.kind == "vendor" and "from a vendor" or "on the auction house")
				row.cost = num(st.price) and money(st.price) or nil
				m.tip = ("%s, %s%s"):format(row.title, row.sub, row.cost and (", " .. row.cost) or "")
			elseif st.kind == "trainRank" then
				m.at = math.floor(num(st.skill) or num(st.at) or num(st.by) or at)
				m.kind = "train"
				row.title = ("Train %s"):format(tostring(st.name or "the next rank"))
				row.sub = st.cap and ("raises the cap to %d"):format(st.cap) or ""
				row.cost = num(st.cost) and money(st.cost) or nil
				m.tip = ("%s at the trainer%s"):format(row.title, row.cost and (", " .. row.cost) or "")
			else
				m.at = num(st.at) or at
				m.kind = "train"
				row.title = ("Learn %s"):format(tostring(st.name))
				row.sub = st.unchecked and "not checked at a trainer yet" or "at the trainer"
				m.confidence = st.unchecked and "classic" or "confirmed"
				row.cost = num(st.cost) and money(st.cost) or nil
				m.tip = ("%s %s%s"):format(row.title, row.sub, row.cost and (", " .. row.cost) or "")
			end
			p.markers[#p.markers + 1] = m
		end
	end
	table.sort(p.markers, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return (a.step or 0) < (b.step or 0)
	end)
	if #steps == 0 then
		p.empty = ctx.why or "No plan yet: open the profession window once so the recipes can be read."
	end
	-- the list: one row per line of W.lines; a marker or a folded step selects the line it belongs to
	local lines = W.lines(steps, { nameOf = nameOf })
	p.lines = lines
	local lineOf = {}
	for _, line in ipairs(lines) do
		for _, s in ipairs(line.steps) do
			lineOf[s] = line
		end
		if line.rank then
			lineOf[line.rank.step] = line
			line.rank.text = rankText(line.rank, ctx, money)
		end
		p.rows[line.n] = lineRow(line, steps[line.step], money, nameOf, skill)
	end
	for _, m in ipairs(p.markers) do
		m.step = lineOf[m.step] and lineOf[m.step].step or nil
	end
	local wanted = num(ctx.selected)
	W.pathSelect(p, {
		selected = wanted and lineOf[wanted] and lineOf[wanted].step or nil,
		stretch = ctx.stretch,
		max = ctx.max,
	})
	local line = p.selected and lineOf[p.selected] or nil
	local st = line and steps[line.step] or nil
	if st then
		local d = { title = tostring(st.name or "Step"), n = line.n, dothis = {}, materials = {}, actions = {} }
		d.color = (line.kind == "craft" or line.kind == "world") and (st.color or "bone")
			or (line.kind == "gap" and "warn" or "gold")
		if #line.unpriced > 0 then
			d.note = unpricedText(line.unpriced)
		end
		if line.kind == "craft" then
			local text = ("Craft %d."):format(st.crafts or 0)
			if line.expected and line.expected < (st.crafts or 0) then
				text = ("Craft up to %d. Usually %d are enough."):format(st.crafts or 0, line.expected)
			end
			d.dothis[1] = { text = text, tone = "bone" }
			local letter = BAND_WORD[st.color]
			d.dothis[2] = {
				text = ("Skill %d to %d%s"):format(
					line.from,
					line.to,
					letter and (", " .. letter .. " at the start.") or "."
				),
				tone = st.color or "bone",
			}
			d.recipe = recipeText(line, st, ctx, money)
			for _, u in ipairs(st.used or {}) do
				d.materials[#d.materials + 1] = {
					name = nameOf(u.item),
					need = u.count,
					have = haveOf(ctx, u.item) or u.count,
					source = "your bags",
					right = "from your bags",
					tone = "green",
				}
			end
			for _, b in ipairs(st.buy or {}) do
				local source = b.where == "vendor" and "vendor" or (b.where == "ah" and "auction" or nil)
				local each = num(b.each) and not b.unpriced and (money(b.each) .. " each") or "price unknown"
				d.materials[#d.materials + 1] = {
					name = nameOf(b.item),
					need = b.count,
					have = haveOf(ctx, b.item) or 0,
					source = source or "unknown source",
					price = num(b.each) and money(b.each) or nil,
					right = source and (source .. ", " .. each) or each,
					tone = (num(b.each) and not b.unpriced) and "bone" or "warn",
				}
			end
			local rows = { { label = tostring(st.name), right = "the plan's pick", picked = true } }
			for _, o in ipairs(st.others or {}) do
				rows[#rows + 1] = {
					label = tostring(o.name or o.spell),
					right = num(o.extra) and ("+" .. money(o.extra)) or "",
					picked = false,
					action = {
						id = "swap",
						label = "Use this",
						enabled = not o.gated,
						spell = o.spell,
						from = st.swapFrom or st.spell,
					},
				}
			end
			for _, cut in ipairs(st.shortcuts or {}) do
				rows[#rows + 1] = shortcutWay(cut, money)
			end
			d.ways = { title = ("Other ways from %d to %d"):format(line.from, line.to), rows = rows }
		elseif line.kind == "world" then
			d.title = line.title
			d.dothis[1] =
				{ text = sentence(("%d to %d %s. No gold cost"):format(line.from, line.to, line.why)), tone = "bone" }
		elseif line.kind == "gap" then
			d.title = line.title
			d.dothis[1] = { text = sentence(line.why), tone = "warn" }
			local rows = {}
			for _, cut in ipairs(st.shortcuts or {}) do
				rows[#rows + 1] = shortcutWay(cut, money)
			end
			if #rows > 0 then
				d.ways = { title = "Ways to fill it", rows = rows }
			end
		else
			d.title = line.title
			d.dothis[1] = { text = sentence(p.rows[line.n].sub), tone = "ash" }
		end
		d.where = ctx.errand and ctx.errand(st, line) or nil
		d.actions[1] =
			{ id = "page", label = "Open in Where", enabled = d.where ~= nil, page = "where", step = line.step }
		d.actions[1].tip = d.where == nil and "This line needs no trip." or nil
		if st.spell then
			d.actions[2] = { id = "showRecipe", label = "Show recipe", enabled = true, spell = st.spell }
		end
		if line.kind == "world" and line.spot then
			-- a node stretch opens its spot on the Where page
			d.actions[1] = { id = "selectSpot", label = "Open in Where", enabled = true, spot = line.spot }
		end
		p.detail = d
	end
	return p
end

---------------------------------------------------------------------------------------------- journal and settings

W.PAGES = { "overview", "path", "where", "shopping", "alts", "settings" }
W.PAGE_LABEL = {
	overview = "Overview",
	path = "Path",
	where = "Where",
	shopping = "Shopping",
	alts = "Alts and mail",
	settings = "Settings and data",
}

W.TAB_NOUN = { shopping = { "thing to buy", "things to buy" }, alts = { "mail to send", "mails to send" } }

-- The journal's shell (design 7.3 `journal`). ctx = { page, profession (key), counts = { [page] = n }, tips = {
-- [page] = text }, pips = { [page] = true }, overview (W.overview's result, for the dropdown), status }.
function W.journal(ctx)
	ctx = ctx or {}
	local page = W.PAGE_LABEL[ctx.page] and ctx.page or "overview"
	local j = { page = page, profession = ctx.profession, tabs = {}, professions = {}, status = ctx.status or "" }
	for _, id in ipairs(W.PAGES) do
		-- a count shows only with the noun that says what is counted (the tab's tooltip), and never on Overview
		local count = id ~= "overview" and ctx.counts and num(ctx.counts[id]) or nil
		local noun = W.TAB_NOUN[id]
		local tip = ctx.tips and ctx.tips[id] or nil
		if count and count > 0 and noun and not tip then
			tip = plural(count, noun[1], noun[2])
		end
		j.tabs[#j.tabs + 1] = {
			id = id,
			label = W.PAGE_LABEL[id],
			count = (count and count > 0 and tip) and count or nil,
			tip = tip,
			tone = id == page and "bone" or "ash",
			pip = (ctx.pips and ctx.pips[id]) == true,
		}
	end
	for _, row in ipairs(ctx.overview and ctx.overview.rows or {}) do
		if row.usable then
			j.professions[#j.professions + 1] = { key = row.key, name = row.name, learned = row.learned }
		end
	end
	table.sort(j.professions, function(a, b)
		if a.learned ~= b.learned then
			return a.learned
		end
		return a.name < b.name
	end)
	j.showProfession = page ~= "overview" and page ~= "settings"
	return j
end

-- The Data section of Settings (design 4.10): which layers loaded. ctx = { recipes (ns.Data.recipes), spots
-- (ns.Data.spots), trainers (ns.Data.trainers), confirmed = { [id] = true }, tsm = { age, missing }, custom = {
-- loaded, errors = { string } }, priceFile }.
function W.dataRows(ctx)
	ctx = ctx or {}
	local rows = {}
	local function add(id, label, state, detail, errors)
		rows[#rows + 1] = { id = id, label = label, state = state, detail = detail, errors = errors }
	end
	local rec = ctx.recipes
	if type(rec) == "table" and type(rec.professions) == "table" then
		local profs, n = 0, 0
		for _, p in pairs(rec.professions) do
			profs = profs + 1
			for _ in pairs(p.recipes or {}) do
				n = n + 1
			end
		end
		add(
			"recipes",
			"Shipped recipes",
			"ok",
			("build %s, %s recipes, %d professions"):format(tostring(rec.build or "?"), W.int(n), profs)
		)
	else
		add("recipes", "Shipped recipes", "broken", "Data/Recipes.lua did not load")
	end
	local spots = ctx.spots
	if type(spots) == "table" and type(spots.skills) == "table" then
		local n, seen = 0, 0
		for _, def in pairs(spots.skills) do
			for _, s in ipairs(def.spots or {}) do
				n = n + 1
				if not s.classic or (ctx.confirmed and ctx.confirmed[s.id]) then
					seen = seen + 1
				end
			end
		end
		add("spots", "Shipped places", "ok", ("%s spots, %s confirmed in Forever"):format(W.int(n), W.int(seen)))
	else
		add("spots", "Shipped places", "broken", "Data/Spots.lua did not load")
	end
	if type(ctx.trainers) == "table" then
		local nopos = 0
		for _, r in ipairs(ctx.trainers) do
			nopos = nopos + (r.nopos and 1 or 0)
		end
		add(
			"trainers",
			"Trainers and recipe vendors",
			"ok",
			("%s listed, %s without a position"):format(W.int(#ctx.trainers), W.int(nopos))
		)
	else
		add("trainers", "Trainers and recipe vendors", "broken", "Data/Trainers.lua did not load")
	end
	add("priceFile", "Local price file", ctx.priceFile and "ok" or "absent", ctx.priceFile or "not present")
	local tsm = ctx.tsm
	if type(tsm) == "table" then
		add(
			"tsm",
			"TSM prices",
			"ok",
			("read %s, %d missing"):format(tostring(tsm.age or "just now"), tsm.missing or 0)
		)
		rows[#rows].action = (tsm.missing or 0) > 0
				and { id = "setting", label = "List them", enabled = true, key = "listMissing" }
			or nil
	else
		add("tsm", "TSM prices", "broken", "not read: TradeSkillMaster gave no prices")
	end
	local custom = ctx.custom
	if type(custom) == "table" and custom.loaded then
		local errs = custom.errors or {}
		add(
			"custom",
			"Your Custom file",
			#errs > 0 and "broken" or "ok",
			#errs > 0 and ("loaded, %s"):format(plural(#errs, "error")) or "loaded",
			#errs > 0 and errs or nil
		)
	else
		add("custom", "Your Custom file", "absent", "not present: no SkillupHelper_Custom addon loaded")
	end
	return rows
end

return W
