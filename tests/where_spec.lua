-- Where.lua: band maths, spot choice, routes, travel, mobs and the journal's view-models, on small fixtures; then
-- the same builders over the shipped Data/Spots.lua for every world skill and both factions.
local F = dofile("tests/fixtures.lua")
local SECRET = {}

local function load(files)
	local ns = {}
	for _, f in ipairs(files or { "Logic.lua", "Guide.lua", "Where.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

-- One map, 3000 x 2000 yd: 1 map percent is 30 yd across and 20 yd down.
local MAPS = { [1] = { name = "Testlands", w = 3000, h = 2000 }, [2] = { name = "Otherlands", w = 3000, h = 2000 } }

-- A 6-point lock spot on two floors with two tiers: a 30 x 15 yd rectangle walked 1 -> 6 (90 yd).
local function fort()
	return {
		id = "lock:testlands:40-30",
		map = 1,
		zone = "Testlands",
		area = "Fort Test",
		x = 40.5,
		y = 30.4,
		r = 1,
		sites = 6,
		pts = { 40, 30, 40.5, 30, 41, 30, 41, 30.75, 40.5, 30.75, 40, 30.75 },
		pk = { 1, 1, 2, 2, 1, 2 },
		z = { 10, 10, 10, 22, 22, 22 },
		loopYd = 90,
		startA = 1,
		startH = 4,
		gets = { { t = "battered-70", n = 3 }, { t = "dented-175", n = 3 } },
		req = 70,
		top = 175,
		mobs = { min = 38, max = 40, list = { { 1, "Fort Guard", 38, 39 }, { 2, "Fort Captain", 40, 40 } } },
		fp = {
			A = { name = "Alpha Camp", map = 1, x = 30.5, y = 30.4, yd = 300 },
			H = { name = "Horde Post", map = 2, x = 80, y = 80, yd = 1150 },
		},
		note = "Battered upstairs, Dented downstairs.",
		classic = true,
	}
end

local function lockData()
	return {
		bands = { yellow = 25, green = 50, grey = 100 },
		bandsConfirmed = false,
		maps = MAPS,
		skills = {
			[633] = {
				name = "Lockpicking",
				kind = "lock",
				capPerLevel = 5,
				learnLevel = 16,
				targets = {
					["practice-1"] = { name = "Practice Lockbox", req = 1, n = 3 },
					["battered-70"] = { name = "Battered Footlocker", req = 70, n = 3 },
					["dented-175"] = { name = "Dented Footlocker", req = 175, n = 3 },
					["new-250"] = { req = 250, new = true, n = 0, note = "new in Forever, position unknown" },
					["lockbox-item"] = { name = "Iron Lockbox", req = 100, item = 4634 },
				},
				spots = {
					{
						id = "lock:testlands:10-10",
						map = 1,
						zone = "Testlands",
						x = 10,
						y = 10,
						r = 0.5,
						sites = 3,
						pts = { 10, 10, 10.5, 10, 10.5, 10.5 },
						pk = { 1, 1, 1 },
						z = { 5, 5, 6 },
						loopYd = 43,
						startA = 1,
						startH = 1,
						gets = { { t = "practice-1", n = 3 } },
						req = 1,
						top = 1,
						fp = { A = { name = "Alpha Camp", map = 1, x = 30.5, y = 30.4, yd = 730 } },
						classic = true,
					},
					fort(),
				},
			},
		},
	}
end

local function nodeData()
	return {
		bands = { yellow = 25, green = 50, grey = 100 },
		maps = MAPS,
		skills = {
			[186] = {
				name = "Mining",
				kind = "node",
				targets = {
					["copper"] = { name = "Copper Vein", req = 1, n = 40 },
					["tin"] = { name = "Tin Vein", req = 65, n = 30 },
					["iron"] = { name = "Iron Deposit", req = 125, n = 20 },
					["new-25"] = { req = 25, new = true, n = 0 },
				},
				spots = {
					{
						id = "mine:testlands:50-50",
						map = 1,
						zone = "Testlands",
						x = 50,
						y = 50,
						r = 2,
						sites = 4,
						pts = { 49, 49, 51, 49, 51, 51, 49, 51 },
						pk = { 1, 1, 2, 1 },
						loopYd = 200,
						startA = 1,
						startH = 3,
						poolsOf = 2,
						gets = { { t = "copper", n = 3 }, { t = "tin", n = 3 } },
						req = 1,
						top = 65,
						mobs = { min = 10, max = 12, list = { { 9, "Kobold", 10, 12 } } },
						fp = { A = { name = "Alpha Camp", map = 1, x = 30.5, y = 30.4, yd = 700 } },
						classic = true,
					},
				},
			},
			[393] = {
				name = "Skinning",
				kind = "skin",
				tiers = {
					{ to = 10, mul = 0, add = 1 },
					{ to = 19, mul = 10, add = -100 },
					{ to = 999, mul = 5, add = 0 },
				},
				targets = {
					["n1"] = { name = "Gray Bear", req = 110, npc = 1, min = 21, max = 22 },
					["n2"] = { name = "Mountain Lion", req = 165, npc = 2, min = 32, max = 33 },
				},
				spots = {
					{
						id = "skin:testlands:60-60",
						map = 1,
						zone = "Testlands",
						x = 60,
						y = 60,
						r = 3,
						sites = 5,
						pts = { 59, 59, 61, 59, 61, 61, 59, 61, 60, 60 },
						pk = { 1, 1, 1, 2, 2 },
						loopYd = 230,
						startA = 1,
						startH = 1,
						gets = { { t = "n1", n = 3 }, { t = "n2", n = 2 } },
						req = 110,
						top = 165,
						mobs = { min = 21, max = 33 },
						classic = true,
					},
				},
			},
			[356] = {
				name = "Fishing",
				kind = "fish",
				zones = {
					{ map = 1, zone = "Testlands", base = -70, classic = true },
					{ map = 2, zone = "Otherlands", base = 130, classic = true },
					{ zone = "The Deep", base = -20, instance = true, classic = true },
				},
			},
		},
	}
end

local function lockQ(W, extra)
	local ctx = { data = lockData(), line = 633, skill = 100, cap = 150, level = 38, faction = "A", class = "ROGUE" }
	for k, v in pairs(extra or {}) do
		if v == SECRET then
			ctx[k] = nil
		else
			ctx[k] = v
		end
	end
	return (W.query(ctx))
end

describe("Where", function()
	local ns, W
	before_each(function()
		_G.issecretvalue = function(v)
			return v == SECRET
		end
		ns = load()
		W = ns.Where
	end)
	after_each(function()
		_G.issecretvalue = nil
	end)

	describe("numbers as text", function()
		it("writes yards the way the chips show them", function()
			assert.equal("38 yd", W.yd(38.2))
			assert.equal("215 yd", W.yd(214))
			assert.equal("1,150 yd", W.yd(1151))
			assert.equal("12,340 yd", W.yd(12338))
			assert.is_nil(W.yd(nil))
			assert.is_nil(W.yd(SECRET))
		end)

		it("writes thousands and clocks", function()
			assert.equal("1,240", W.int(1240))
			assert.equal("86", W.int(86))
			assert.equal("1,000,000", W.int(1000000))
			assert.equal("3:40", W.clock(220))
			assert.equal("0:05", W.clock(5))
			assert.equal("0:00", W.clock(-3))
		end)
	end)

	describe("band maths", function()
		it("names the state at every threshold", function()
			local b = { yellow = 25, green = 50, grey = 100 }
			assert.equal("locked", W.stateAt(69, 70, b))
			assert.equal("orange", W.stateAt(70, 70, b))
			assert.equal("orange", W.stateAt(94, 70, b))
			assert.equal("yellow", W.stateAt(95, 70, b))
			assert.equal("green", W.stateAt(120, 70, b))
			assert.equal("green", W.stateAt(169, 70, b))
			assert.equal("grey", W.stateAt(170, 70, b))
		end)

		it("has no state without a skill, also a secret one", function()
			assert.is_nil(W.stateAt(nil, 70))
			assert.is_nil(W.stateAt(SECRET, 70))
			assert.is_nil(W.stateAt(100, nil))
		end)

		it("gives the skill of the next colour change", function()
			assert.equal(70, W.changeAt(10, 70))
			assert.equal(95, W.changeAt(70, 70))
			assert.equal(120, W.changeAt(100, 70))
			assert.equal(170, W.changeAt(150, 70))
			assert.is_nil(W.changeAt(170, 70))
			assert.is_nil(W.changeAt(nil, 70))
		end)

		it("builds and clips the bar segments", function()
			assert.same({
				{ from = 70, to = 95, color = "orange" },
				{ from = 95, to = 120, color = "yellow" },
				{ from = 120, to = 170, color = "green" },
			}, W.segs(70))
			assert.same(
				{ { from = 100, to = 120, color = "yellow" }, { from = 120, to = 150, color = "green" } },
				W.segs(70, nil, 100, 150)
			)
			assert.same({}, W.segs(70, nil, 200, 300))
		end)

		it("uses the skinning level formula, from tiers or the built-in rule", function()
			local tiers =
				{ { to = 10, mul = 0, add = 1 }, { to = 19, mul = 10, add = -100 }, { to = 999, mul = 5, add = 0 } }
			for _, t in ipairs({ { 1, 1 }, { 10, 1 }, { 11, 10 }, { 19, 90 }, { 20, 100 }, { 33, 165 }, { 60, 300 } }) do
				assert.equal(t[2], W.skinReq(t[1], tiers))
				assert.equal(t[2], W.skinReq(t[1]))
			end
			assert.is_nil(W.skinReq(nil))
		end)

		it("gives the share of fish that get away", function()
			assert.is_nil(W.fishAway(100, 130))
			assert.near(0.95, W.fishAway(130, 130), 1e-9)
			assert.near(0.24, W.fishAway(1, -70), 1e-9)
			assert.equal(0, W.fishAway(225, 130))
			assert.equal(0, W.fishAway(300, -70))
			assert.is_nil(W.fishAway(nil, 0))
		end)

		it("colours a recipe over a stretch", function()
			assert.same({
				{ from = 140, to = 150, color = "orange" },
				{ from = 150, to = 170, color = "yellow" },
				{ from = 170, to = 180, color = "green" },
			}, W.recipeBands(140, 180, 150, 190))
			assert.same({ { from = 100, to = 110, color = "orange" } }, W.recipeBands(100, 110, 150, 190))
			assert.is_nil(W.recipeBands(100, 110, nil, 190))
		end)
	end)

	describe("counts", function()
		it("weighs what still gives points", function()
			local q = lockQ(W)
			local c = W.counts(q, fort(), 100)
			assert.same({ 6, 3, 3, 3 }, { c.total, c.yellow, c.locked, c.usable })
			assert.near(2.25, c.value, 1e-9)
			assert.same({ "yellow", "battered-70", 70 }, { c.best, c.bestKey, c.bestReq })
		end)

		it("prefers the higher requirement among equal colours", function()
			local c = W.counts(lockQ(W), fort(), 190)
			-- battered 70 is grey at 170; dented 175 is orange until 200
			assert.same({ "orange", "dented-175", 3, 3 }, { c.best, c.bestKey, c.grey, c.usable })
		end)

		it("counts everything as usable with no skill", function()
			local c = W.counts(lockQ(W), fort(), nil)
			assert.same({ 6, 6, 6 }, { c.total, c.usable, c.value })
			assert.is_nil(c.best)
		end)

		it("is all grey past the last band", function()
			local c = W.counts(lockQ(W), fort(), 300)
			assert.same({ 0, 6, 0 }, { c.usable, c.grey, c.value })
		end)

		it("survives a spot with no gets", function()
			local c = W.counts(lockQ(W), { req = 50 }, 60)
			assert.same({ 1, 1, "orange" }, { c.total, c.usable, c.best })
		end)
	end)

	describe("mobs and danger", function()
		it("grades the camp against the player", function()
			local m = { min = 38, max = 40 }
			assert.same({ "deadly", "warn", 5 }, { W.danger(m, 35) })
			assert.same({ "dangerous", "orange", 3 }, { W.danger(m, 37) })
			assert.same({ "even", "yellow", 2 }, { W.danger(m, 38) })
			assert.same({ "even", "yellow", -2 }, { W.danger(m, 42) })
			assert.same({ "easy", "green", -3 }, { W.danger(m, 43) })
			assert.same({ "trivial", "grey", -20 }, { W.danger(m, 60) })
		end)

		it("has no grade without a level, also a secret one", function()
			assert.same({ nil, "bone", nil }, { W.danger({ max = 40 }, nil) })
			assert.same({ nil, "bone", nil }, { W.danger({ max = 40 }, SECRET) })
			assert.same({ nil, "bone", nil }, { W.danger(nil, 30) })
		end)

		it("knows the grey level", function()
			assert.same(
				{ 0, 13, 31, 47, 51 },
				{ W.greyLevel(5), W.greyLevel(20), W.greyLevel(39), W.greyLevel(60 - 1), W.greyLevel(60) }
			)
		end)

		it("builds the chip", function()
			local m = W.mobs(fort().mobs, 37)
			assert.same(
				{ "Mobs 38-40", "orange", "3 above you", "dangerous", false },
				{ m.label, m.tone, m.phrase, m.state, m.elite }
			)
			assert.same({ "Fort Guard 38-39", "Fort Captain 40" }, m.names)
			assert.equal("your level", W.mobs({ min = 40, max = 40 }, 40).phrase)
			assert.equal("Mobs 40", W.mobs({ min = 40, max = 40 }, 40).label)
			assert.equal("4 below you", W.mobs({ min = 30, max = 36 }, 40).phrase)
		end)

		it("drops the tone and the phrase with no level", function()
			local m = W.mobs(fort().mobs, nil)
			assert.same({ "Mobs 38-40", "bone" }, { m.label, m.tone })
			assert.is_nil(m.phrase)
			assert.is_nil(W.mobs(nil, 30))
		end)
	end)

	describe("rate and rank", function()
		it("adds up the documented parts", function()
			local q = lockQ(W)
			local r = W.rate(q, fort())
			assert.near(37.5, r.parts.gain, 1e-9) -- 2.25 of 6
			assert.near(-3, r.parts.loop, 1e-9) -- 90 yd over 3 usable points, / 10
			assert.equal(-5, r.parts.danger) -- mobs 40 at level 38: even
			assert.near(-1, r.parts.flight, 1e-9) -- 300 yd / 300
			assert.equal(0, r.parts.player) -- no position
			assert.equal(0, r.parts.place)
			assert.near(28.5, r.score, 1e-9)
			assert.is_true(r.usable)
		end)

		it("charges for the distance from the player, or a flat sum on another map", function()
			local q = lockQ(W, { here = { map = 1, x = 0.405, y = 0.054 } })
			-- 25 map percent north of the centre: 500 yd
			local r = W.rate(q, fort())
			assert.near(500, r.playerYd, 1e-6)
			assert.near(-1, r.parts.player, 1e-9)
			q = lockQ(W, { here = { map = 2, x = 0.5, y = 0.5 } })
			assert.equal(-5, W.rate(q, fort()).parts.player)
		end)

		it("charges for no flight point, an instance, water and a roof", function()
			local q = lockQ(W, { faction = "H" })
			local s = fort()
			s.fp.H = nil
			assert.equal(-10, W.rate(q, s).parts.flight)
			s.instance, s.indoor, s.note = "Test Keep", true, "Waterlogged Footlockers, underwater."
			assert.equal(-40, W.rate(q, s).parts.place)
		end)

		it("does not penalise a Classic position or an unknown level", function()
			local a, b = fort(), fort()
			b.classic = nil
			local q = lockQ(W, { level = SECRET })
			assert.equal(W.rate(q, a).score, W.rate(q, b).score)
			assert.equal(0, W.rate(q, a).parts.danger)
		end)

		it("sorts spots into now, locked and grey", function()
			local rk = W.rank(lockQ(W, { skill = 50 }))
			assert.same({ "lock:testlands:10-10" }, { rk.now[1].spot.id })
			assert.same({ "lock:testlands:40-30" }, { rk.locked[1].spot.id })
			rk = W.rank(lockQ(W, { skill = 120 }))
			assert.equal("lock:testlands:40-30", rk.now[1].spot.id)
			assert.equal("lock:testlands:10-10", rk.grey[1].spot.id)
			rk = W.rank(lockQ(W, { skill = SECRET }))
			assert.equal(2, #rk.now)
		end)

		it("ranks nothing with no data", function()
			local rk = W.rank({ data = {}, line = 633, skill = 10 })
			assert.same({ 0, 0, 0 }, { #rk.now, #rk.locked, #rk.grey })
		end)
	end)

	describe("route", function()
		it("drops grey and locked points, re-closes in order and starts at the faction's point", function()
			local q = lockQ(W, { faction = "H" })
			local r = W.route(q, fort())
			-- Horde starts at point 4: tour 4 5 6 1 2 3; at 100 only the Battered ones (5, 1, 2) give points
			local src, ns2 = {}, {}
			for i, p in ipairs(r.pts) do
				src[i], ns2[i] = p.src, p.n
			end
			assert.same({ 5, 1, 2 }, src)
			assert.same({ 1, 2, 3 }, ns2)
			assert.equal(3, #r.skipped)
			assert.equal("locked", r.skipped[1].band)
			assert.is_true(r.closed)
			-- 5 -> 1: 15 yd across, 15 down; 1 -> 2: 15; 2 -> 5: 15
			assert.equal(51, r.loopYd)
			assert.same({ 0.405, 0.3075, 22 }, { r.pts[1].x, r.pts[1].y, r.pts[1].z })
		end)

		it("keeps the data's length when nothing was dropped", function()
			local r = W.route(lockQ(W, { skill = SECRET }), fort())
			assert.equal(6, #r.pts)
			assert.equal(90, r.loopYd)
			assert.equal(1, r.pts[1].src)
		end)

		it("groups heights into floors and marks every change as stairs", function()
			local r = W.route(lockQ(W, { skill = SECRET }), fort())
			assert.same({
				{ id = 1, label = "Lower", count = 3, z = 10 },
				{ id = 2, label = "Upper", count = 3, z = 22 },
			}, r.floors)
			assert.same(
				{ 1, 1, 1, 2, 2, 2 },
				{ r.pts[1].floor, r.pts[2].floor, r.pts[3].floor, r.pts[4].floor, r.pts[5].floor, r.pts[6].floor }
			)
			assert.equal(2, #r.stairs)
			assert.same({ 1, 2, 3 }, { r.stairs[1].from, r.stairs[1].to, r.stairs[1].after })
			assert.same({ 2, 1, 6 }, { r.stairs[2].from, r.stairs[2].to, r.stairs[2].after })
			assert.near(0.41, r.stairs[1].x, 1e-9)
		end)

		it("counts floors over the stops left", function()
			local r = W.route(lockQ(W, { skill = 190 }), fort())
			-- Dented only: points 3 (lower), 4 and 6 (upper)
			assert.same({ 1, 2 }, { r.floors[1].count, r.floors[2].count })
		end)

		it("names each type with its colour now", function()
			local r = W.route(lockQ(W), fort())
			assert.same(
				{ "Battered Footlocker", "yellow", 70 },
				{ r.types["battered-70"].name, r.types["battered-70"].band, r.types["battered-70"].req }
			)
			assert.equal("locked", r.types["dented-175"].band)
			assert.equal("VignetteLoot", r.types["dented-175"].icon)
		end)

		it("says how many are up only when the data knows", function()
			local s = fort()
			assert.equal("how many are up at once: not known", W.route(lockQ(W), s).poolsText)
			s.poolsOf = 2.4
			assert.equal("about 2 boxes up", W.route(lockQ(W), s).poolsText)
		end)

		it("is empty when every point is grey", function()
			local r = W.route(lockQ(W, { skill = 300 }), fort())
			assert.equal(0, #r.pts)
			assert.equal(6, #r.skipped)
			assert.is_false(r.closed)
			assert.same({ nil, "nothing on this route gives points at your skill" }, { W.nextStop(r, nil) })
		end)

		it("scales the data's length when the map size is unknown", function()
			local q = lockQ(W, { faction = "H", maps = {} })
			local r = W.route(q, fort())
			assert.equal(51, r.loopYd)
			assert.matches("map size unknown", r.loopWhy, 1, true)
		end)

		it("gives nil for a spot with no points and reads a target key in pk", function()
			assert.is_nil(W.route(lockQ(W), { id = "lock:instance:x", instance = "Keep" }))
			local s = fort()
			s.pk = { "battered-70", "battered-70", 0, 9, "battered-70", "nope" }
			local r = W.route(lockQ(W, { skill = SECRET }), s)
			assert.same(
				{ "battered-70", "other", "other", "other" },
				{ r.pts[1].pk, r.pts[3].pk, r.pts[4].pk, r.pts[6].pk }
			)
			assert.equal("Other", r.types.other.name)
		end)

		it("takes a mining site as its best ore: a copper pin may hold tin", function()
			local q = W.query({ data = nodeData(), line = 186, skill = 120, faction = "A" })
			local spot = q.def.spots[1]
			local r = W.route(q, spot)
			-- copper (1) is grey at 101, tin (65) is green at 120: every site stays
			assert.equal(4, #r.pts)
			assert.equal("green", r.pts[1].band)
			assert.equal("grey", r.types.copper.band)
			assert.equal("about 2 veins up", r.poolsText)
			q = W.query({ data = nodeData(), line = 186, skill = 170, faction = "A" })
			assert.equal(0, #W.route(q, spot).pts)
		end)
	end)

	describe("floors", function()
		it("splits at gaps over four yards and labels three floors", function()
			local ids, floors = W.floors({ 0, 3, 9, 10, 30 })
			assert.same({ 1, 1, 2, 2, 3 }, ids)
			assert.same({ "Lower", "Middle", "Upper" }, { floors[1].label, floors[2].label, floors[3].label })
		end)

		it("is nil for one floor, no heights or nil", function()
			assert.is_nil(W.floors({ 5, 6, 7 }))
			assert.is_nil(W.floors({}))
			assert.is_nil(W.floors(nil))
		end)

		it("numbers many floors", function()
			local _, floors = W.floors({ 0, 10, 20, 30 })
			assert.equal("Floor 4", floors[4].label)
		end)
	end)

	describe("next stop", function()
		local route
		before_each(function()
			route = W.route(lockQ(W, { skill = SECRET }), fort())
		end)

		it("is the nearest stop before any visit, with yards and bearing", function()
			-- 1 percent east of stop 3 (41, 30): 30 yd, the stop is due west
			local nx = W.nextStop(route, { x = 0.42, y = 0.30 }, { size = MAPS[1] })
			assert.equal(3, nx.index)
			assert.near(30, nx.yards, 1e-6)
			assert.near(270, nx.bearing, 1e-6)
			assert.equal("west", nx.compass)
		end)

		it("is the first unvisited stop ahead of the last one", function()
			local visited = W.visit(nil, 3, 1000, 300)
			W.visit(visited, 4, 1010, 300)
			local nx = W.nextStop(
				route,
				{ x = 0.40, y = 0.30 },
				{ visited = visited, now = 1020, last = 3, size = MAPS[1] }
			)
			assert.equal(5, nx.index)
			nx = W.nextStop(route, nil, { visited = visited, now = 1020, last = 6 })
			assert.equal(1, nx.index)
			assert.is_nil(nx.yards)
		end)

		it("returns to a stop once its respawn window is over", function()
			local visited = W.visit(nil, 4, 1000, 300)
			assert.equal(5, W.nextStop(route, nil, { visited = visited, now = 1200, last = 3 }).index)
			assert.equal(4, W.nextStop(route, nil, { visited = visited, now = 1300, last = 3 }).index)
		end)

		it("is the first stop with no position and no visit", function()
			assert.equal(1, W.nextStop(route, nil).index)
		end)

		it("says so when every stop was just visited", function()
			local visited = {}
			for i = 1, 6 do
				W.visit(visited, i, 0, 300)
			end
			assert.same(
				{ nil, "every stop was just visited" },
				{ W.nextStop(route, nil, { visited = visited, now = 10 }) }
			)
		end)

		it("points the compass the map's way: north is up", function()
			assert.near(0, W.bearing(0.5, 0.5, 0.5, 0.4), 1e-9)
			assert.near(90, W.bearing(0.5, 0.5, 0.6, 0.5), 1e-9)
			assert.near(180, W.bearing(0.5, 0.5, 0.5, 0.6), 1e-9)
			assert.equal("northeast", W.compass(W.bearing(0.5, 0.5, 0.6, 0.4, MAPS[1])))
			assert.equal("southwest", W.compass(225))
			assert.is_nil(W.compass(nil))
		end)
	end)

	describe("visits", function()
		it("keeps live visits and words the wait", function()
			local v = W.visit(nil, 2, 100)
			W.visit(v, 5, 180, 60)
			assert.same({ [2] = 400, [5] = 240 }, v)
			assert.same({ [2] = 400 }, W.fresh(v, 300))
			assert.equal("2 visited, the first is back in 0:20", W.visitedLine(v, 220))
			assert.is_nil(W.visitedLine(v, 500))
			assert.is_nil(W.visitedLine(nil, 0))
		end)
	end)

	describe("travel", function()
		it("gives the flight point, the walk from it and the note", function()
			local t = W.travel(lockQ(W), fort())
			assert.same({ name = "Alpha Camp", yards = 300, map = 1 }, t.flight)
			assert.equal(2, #t.legs)
			assert.same(
				{ "flight", "Fly to Alpha Camp", 0.305, 60 },
				{ t.legs[1].icon, t.legs[1].text, t.legs[1].x, t.legs[1].doneYd }
			)
			assert.equal("Go to Fort Test, 300 yd east (unconfirmed)", t.legs[2].text)
			assert.equal(70, t.legs[2].doneYd) -- radius 30 yd + 40
			assert.equal("classic", t.legs[2].confidence)
			assert.same({ yards = 300, label = "300 yd", points = { { 0.305, 0.304 }, { 0.405, 0.304 } } }, t.leadIn)
			assert.equal("Battered upstairs, Dented downstairs.", t.note)
		end)

		it("has no direction or lead-in from a flight point on another map", function()
			local t = W.travel(lockQ(W, { faction = "H" }), fort())
			assert.equal("Go to Fort Test, 1,150 yd (unconfirmed)", t.legs[2].text)
			assert.is_nil(t.leadIn)
		end)

		it("says when the faction has no flight point, and nothing when the faction is unknown", function()
			local s = fort()
			s.fp.H = nil
			local t = W.travel(lockQ(W, { faction = "H" }), s)
			assert.is_nil(t.flight)
			assert.equal("No flight point known for your side.", t.noFlight)
			assert.equal("Go to Fort Test (unconfirmed)", t.legs[1].text)
			t = W.travel(lockQ(W, { faction = SECRET }), s)
			assert.is_nil(t.noFlight)
			assert.equal(1, #t.legs)
		end)

		it("leads with the crossing when the player is on the other continent", function()
			local q = lockQ(W, { here = { map = 2, x = 0.5, y = 0.5 }, continentOf = { [1] = 0, [2] = 1 } })
			local t = W.travel(q, fort())
			assert.is_true(t.otherContinent)
			assert.equal("On another continent: cross by boat or zeppelin first.", t.legs[1].text)
			assert.equal(3, #t.legs)
		end)

		it("drops the unconfirmed tag once the character stood there", function()
			local q = lockQ(W, { confirmed = { ["lock:testlands:40-30"] = true } })
			assert.equal("Go to Fort Test, 300 yd east", W.travel(q, fort()).legs[2].text)
		end)
	end)

	describe("yields", function()
		it("lists what the spot gives, usable first, on one axis", function()
			local y = W.yields(lockQ(W), fort())
			assert.same({ lo = 60, hi = 175 }, y.axis) -- capped at the rank cap + 25
			assert.equal(100, y.skill)
			local a, b = y.rows[1], y.rows[2]
			assert.same(
				{ "Battered Footlocker", "yellow", "to 120", "yellow", 70 },
				{ a.name, a.state, a.right, a.tone, a.req }
			)
			assert.same({ "Dented Footlocker", "locked", "needs 175", "warn" }, { b.name, b.state, b.right, b.tone })
			assert.same({
				{ from = 70, to = 95, color = "orange" },
				{ from = 95, to = 120, color = "yellow" },
				{ from = 120, to = 170, color = "green" },
			}, a.segs)
			assert.same({}, b.segs) -- its bands start at the axis' end
			assert.is_false(y.bandsConfirmed)
			assert.matches("needs 70. Orange to 95, yellow to 120, green to 170. 3 positions here.", a.tip, 1, true)
			assert.matches("not yet confirmed in Forever", a.tip, 1, true)
			assert.is_nil(y.more)
		end)

		it("says none for grey and shows only requirements with no skill", function()
			local y = W.yields(lockQ(W, { skill = 190, cap = 225 }), fort())
			assert.same(
				{ "Dented Footlocker", "orange", "to 200" },
				{ y.rows[1].name, y.rows[1].state, y.rows[1].right }
			)
			assert.same({ "grey", "none", "grey" }, { y.rows[2].state, y.rows[2].right, y.rows[2].tone })
			y = W.yields(lockQ(W, { skill = SECRET }), fort())
			assert.is_nil(y.skill)
			assert.same({ "from 70", "bone" }, { y.rows[1].right, y.rows[1].tone })
			assert.is_nil(y.rows[1].state)
			assert.matches("Skill unknown until the first skill-up message", y.note, 1, true)
		end)

		it("counts rows past four as more", function()
			local q = lockQ(W)
			local s = fort()
			for i = 1, 4 do
				q.def.targets["t" .. i] = { name = "Box " .. i, req = 80 + i }
				s.gets[#s.gets + 1] = { t = "t" .. i, n = 1 }
			end
			assert.equal(2, W.yields(q, s).more)
		end)

		it("names skinning rows by beast and level", function()
			local q = W.query({ data = nodeData(), line = 393, skill = 120, level = 30 })
			local y = W.yields(q, q.def.spots[1])
			assert.same({ "Gray Bear 21-22", "orange", "to 135" }, { y.rows[1].name, y.rows[1].state, y.rows[1].right })
			assert.same({ "Mountain Lion 32-33", "needs 165" }, { y.rows[2].name, y.rows[2].right })
			assert.equal("VignetteKill", y.rows[1].icon)
		end)

		it("gives fishing two tones: get away, then clean", function()
			local q = W.query({ data = nodeData(), line = 356, skill = 150 })
			local y = W.fishYields(q, q.def.zones[2])
			local row = y.rows[1]
			assert.same({ "Otherlands", 130, "75% get away", "grey" }, { row.name, row.req, row.right, row.state })
			assert.same(
				{ { from = 130, to = 225, color = "grey" }, { from = 225, to = 250, color = "green" } },
				row.segs
			)
			assert.equal(
				"clean catch",
				W.fishYields(W.query({ data = nodeData(), line = 356, skill = 240 }), q.def.zones[2]).rows[1].right
			)
			assert.equal(
				"needs 130",
				W.fishYields(W.query({ data = nodeData(), line = 356, skill = 90 }), q.def.zones[2]).rows[1].right
			)
			assert.is_nil(W.yields(q, {}))
		end)
	end)

	describe("where", function()
		it("builds the whole model of a loop", function()
			local w = W.where(lockQ(W), fort())
			assert.same(
				{ "loop", "lock:testlands:40-30", "Lockpicking", "yellow", 1 },
				{ w.kind, w.key, w.profession, w.color, w.map }
			)
			assert.same({ "Fort Test", "Testlands, 41, 30" }, { w.title, w.sub })
			assert.same({ text = "Open the locks", gain = "20 points to 120" }, w.verb)
			assert.same({ "classic", "from Classic, unconfirmed" }, { w.confidence, w.tag })
			assert.same({ shape = "circle", x = 0.405, y = 0.304, r = 0.01 }, w.area)
			assert.same({ 70, 150 }, { w.enterYd, w.leaveYd })
			assert.equal("Alpha Camp", w.flight.name)
			assert.equal(2, #w.travel)
			assert.equal("flight", w.pins[1].kind)
			assert.equal("Flight point: Alpha Camp", w.pins[1].tip)
			assert.equal(3, #w.route.pts)
			assert.equal("Mobs 38-40", w.mobs.label)
			assert.equal(2, #w.yields.rows)
			assert.equal("Loop 50 yd, 3 stops, mobs 38-40", w.caption.line1)
			assert.matches("2 floors: Lower 2, Upper 1.", w.caption.line3, 1, true)
			assert.matches("3 positions skipped (grey or too hard).", w.caption.line3, 1, true)
			assert.matches("Boxes up at once: not known.", w.caption.line3, 1, true)
			assert.matches("Position from Classic data, not yet seen in Forever.", w.caption.line3, 1, true)
			assert.equal("pin", w.actions[1].id)
			assert.is_nil(w.empty)
		end)

		it("frames the approach and the loop", function()
			local w = W.where(lockQ(W), fort())
			-- travel: from the flight point (30.5) to the disc's east edge (41.5), padded 12% each side
			assert.near(0.36, w.views.travel.cx, 1e-9)
			assert.near(0.11 * 1.24, w.views.travel.span, 1e-9)
			-- spot: the six points, 1 percent across, padded 15% each side; never under 60 yd
			assert.near(0.405, w.views.spot.cx, 1e-9)
			assert.near(0.30375, w.views.spot.cy, 1e-9)
			assert.near(0.02, w.views.spot.span, 1e-9)
		end)

		it("previews the spot the route moves to next", function()
			local w = W.where(lockQ(W, { skill = 20, cap = 190 }), lockData().skills[633].spots[1])
			assert.same({ "lock:testlands:40-30", 70 }, { w.next.key, w.next.at })
			assert.equal("At 70: Fort Test, Testlands", w.next.text)
			assert.equal("Mobs 38-40, 2 above you. Flight: Alpha Camp, 300 yd.", w.next.sub)
			assert.equal("yellow", w.next.tone)
			-- at level 16 the fort's mobs are deadly: the route stays at the practice boxes until they are grey
			w = W.where(lockQ(W, { skill = 20, cap = 80, level = 16 }), lockData().skills[633].spots[1])
			assert.same(
				{ 101, "Mobs 38-40, 19 above you. Flight: Alpha Camp, 300 yd.", "warn" },
				{ w.next.at, w.next.sub, w.next.tone }
			)
			assert.is_nil(W.where(lockQ(W), fort(), { next = false }).next)
		end)

		it("says what a locked or spent spot lacks", function()
			assert.equal("needs 70, you have 50", W.where(lockQ(W, { skill = 50 }), fort()).verb.gain)
			assert.equal("warn", W.where(lockQ(W, { skill = 50 }), fort()).color)
			local w = W.where(lockQ(W, { skill = 290 }), fort())
			assert.same({ "nothing here gives points now", "grey", "spot" }, { w.verb.gain, w.color, w.kind })
		end)

		it("holds with nothing known about the player", function()
			local w = W.where(lockQ(W, { skill = SECRET, level = SECRET, faction = SECRET, cap = SECRET }), fort())
			assert.equal("bone", w.color)
			assert.is_nil(w.verb.gain)
			assert.is_nil(w.flight)
			assert.equal("bone", w.mobs.tone)
			assert.equal(6, #w.route.pts)
			assert.matches("Faction unknown: no flight point shown.", w.caption.line3, 1, true)
			assert.is_nil(w.next)
		end)

		it("shows a scattered spot as an area with no loop claim", function()
			local s = fort()
			s.scattered = true
			local w = W.where(lockQ(W, { skill = SECRET }), s)
			assert.equal("spot", w.kind)
			assert.is_false(w.route.closed)
			assert.equal("6 positions spread over the zone, no set loop, mobs 38-40", w.caption.line1)
		end)

		it("shows an instance as its entrance", function()
			local s = { id = "lock:instance:keep", instance = "Test Keep", map = 1, zone = "Testlands", x = 20, y = 20 }
			s.gets, s.req, s.top, s.classic = { { t = "dented-175", n = 4 } }, 175, 175, true
			local w = W.where(lockQ(W, { skill = 180, cap = 225 }), s)
			assert.same({ "spot", "Test Keep" }, { w.kind, w.title })
			assert.is_nil(w.route)
			assert.equal("entrance", w.pins[1].kind)
			assert.equal("Enter Test Keep (unconfirmed)", w.travel[#w.travel].text)
			assert.equal("Inside Test Keep", w.caption.line1)
		end)

		it("says where the data ends instead of a map", function()
			local w = W.emptyWhere(
				lockQ(W, { skill = 280, cap = 300 }),
				275,
				300,
				"1 target: new in Forever, position not known yet"
			)
			assert.equal("Nothing mapped for Lockpicking 275 to 300", w.empty.title)
			assert.matches("new in Forever, position not known yet", w.empty.text, 1, true)
			assert.same(
				{ "selectSpot", "Show the nearest lower spot", "lock:testlands:40-30" },
				{ w.empty.action.id, w.empty.action.label, w.empty.action.spot }
			)
			assert.equal(w.empty.title, W.where(lockQ(W), nil).empty.title:gsub("%d+ to %d+", "275 to 300"))
		end)

		it("builds a fishing zone with no route", function()
			local q = W.query({ data = nodeData(), line = 356, skill = 150 })
			local w = W.fishWhere(q, q.def.zones[2])
			assert.same({ "spot", "fish:Otherlands", "grey", 2 }, { w.kind, w.key, w.color, w.map })
			assert.same({ text = "Fish here", gain = "75% get away" }, w.verb)
			assert.same({ cx = 0.5, cy = 0.5, span = 1 }, w.views.travel)
			assert.equal("Fishing in Otherlands", w.caption.line1)
			assert.is_nil(w.route)
		end)
	end)

	describe("itinerary", function()
		it("orders the brackets and names the hole", function()
			local it2 = W.itinerary(lockQ(W), 1, 300)
			local legs = {}
			for i, leg in ipairs(it2.legs) do
				legs[i] = leg.text
			end
			-- Battered (70) is grey from 170 and Dented needs 175: five ranks nothing covers
			assert.same(
				{ "1 to 70: Testlands", "70 to 170: Fort Test, Testlands", "175 to 275: Fort Test, Testlands" },
				legs
			)
			assert.same({
				{ from = 170, to = 175, reason = "nothing in the data gives points here" },
				{ from = 275, to = 300, reason = "1 target: new in Forever, position not known yet" },
			}, it2.holes)
			assert.is_false(it2.complete)
			assert.equal(2, it2.spots)
			assert.equal("2 spots, nothing mapped for 170-175, 275-300", it2.text)
		end)

		it("stays at a spot until another leads by ten points", function()
			-- at 70 the practice boxes (grey from 101, green at 70) still give points, but Fort Test leads by far
			local it2 = W.itinerary(lockQ(W), 60, 120)
			assert.same({ 60, 70 }, { it2.legs[1].from, it2.legs[1].to })
			assert.equal("lock:testlands:40-30", it2.legs[2].key)
		end)

		it("is complete when the spots reach the top", function()
			local it2 = W.itinerary(lockQ(W), 1, 170)
			assert.is_true(it2.complete)
			assert.equal("2 spots, complete 1-170", it2.text)
		end)

		it("has nothing to plan at the top and one hole with no data", function()
			assert.equal("Lockpicking is at 300: nothing left to plan", W.itinerary(lockQ(W), 300, 300).text)
			local it2 = W.itinerary({ data = {}, line = 182, name = "Herbalism" }, 1, 300)
			assert.same({ { from = 1, to = 300, reason = "no data for this skill" } }, it2.holes)
			assert.is_false(it2.complete)
		end)

		it("names targets that have too few positions to make a spot", function()
			local d = lockData()
			d.skills[633].targets["new-250"] = { name = "Small Thorium Box", req = 250, n = 2 }
			local it2 = W.itinerary({ data = d, line = 633, faction = "A" }, 250, 300)
			assert.equal(
				"Small Thorium Box (2 positions): too few positions in the data to make a spot",
				it2.holes[1].reason
			)
			assert.same({ 275, 300 }, { it2.holes[1].from, it2.holes[1].to })
		end)

		it("does not let the player's position change the plan", function()
			local a = W.itinerary(lockQ(W), 1, 300)
			local b = W.itinerary(lockQ(W, { here = { map = 1, x = 0.1, y = 0.1 } }), 1, 300)
			assert.same(a.legs[2].key, b.legs[2].key)
			assert.same(a.holes, b.holes)
		end)

		it("covers fishing from the zones", function()
			local it2 = W.itinerary({ data = nodeData(), line = 356 }, 1, 300)
			assert.is_true(it2.complete)
			assert.equal("fish:Testlands", it2.legs[1].key)
			assert.equal("1 spot, complete 1-300", it2.text)
		end)

		it("reports a mining stretch only new Forever nodes cover", function()
			local d = nodeData()
			d.skills[186].targets["new-300"] = { req = 200, new = true, n = 0 }
			local it2 = W.itinerary({ data = d, line = 186 }, 1, 300)
			-- copper and tin run out at 165 (tin 65 + 100). Iron (125) is in the data with no spot; it is grey from 225,
			-- and above that only the new node (200) is left
			local holes = {}
			for i, h in ipairs(it2.holes) do
				holes[i] = ("%d-%d: %s"):format(h.from, h.to, h.reason)
			end
			assert.same({
				"165-225: Iron Deposit (20 positions): too few positions in the data to make a spot",
				"225-300: 1 target: new in Forever, position not known yet",
			}, holes)
		end)
	end)

	describe("where list", function()
		it("lists what gives points now, the next move and what waits", function()
			local list = W.whereList(lockQ(W, { skill = 50, cap = 190 }))
			assert.same({ title = "Lockpicking 50 / 190", sub = "Spots that still give points, best first" }, list.head)
			local a, b = list.spots[1], list.spots[2]
			assert.same({ "lock:testlands:10-10", "Testlands", "now", true }, { a.key, a.title, a.right, a.selected })
			assert.equal("Testlands. Flight: Alpha Camp, 730 yd", a.sub)
			assert.same({ "Practice Lockbox, yellow to 51", "yellow" }, { a.yield, a.yieldTone })
			assert.same({ "lock:testlands:40-30", "at 70", "At 70 move here" }, { b.key, b.right, b.yield })
			assert.same({ label = "Mobs 38-40", tone = "yellow", phrase = "2 above you" }, b.mobs)
			assert.equal(70, list.nextAt)
			assert.equal("lock:testlands:10-10", list.selected.key)
			assert.equal(2, #list.spots)
		end)

		it("honours the user's pick", function()
			local list = W.whereList(lockQ(W, { skill = 50, selected = "lock:testlands:40-30" }))
			assert.equal("lock:testlands:40-30", list.selected.key)
			assert.is_true(list.spots[2].selected)
			assert.is_false(list.spots[1].selected)
		end)

		it("marks a spot above the skill as locked", function()
			local d = lockData()
			d.skills[633].spots[1].gets[1].t = "dented-175"
			d.skills[633].spots[1].req = 175
			local list = W.whereList({ data = d, line = 633, skill = 20, faction = "H" })
			assert.is_truthy(list.empty)
			-- the fort opens first (70): it is the next move; the other spot only waits
			local row = list.spots[1]
			assert.same({ "lock:testlands:40-30", "at 70", "At 70 move here" }, { row.key, row.right, row.yield })
			assert.is_nil(row.locked)
			assert.equal("Flight: Horde Post, 1,150 yd", row.flight)
			row = list.spots[2]
			assert.same({ "needs 175, you have 20", "later", "warn" }, { row.locked, row.right, row.yieldTone })
			assert.equal("No flight point known for your side.", row.flight)
			assert.equal(2, #list.spots)
		end)

		it("names the hole when nothing gives points", function()
			local list = W.whereList(lockQ(W, { skill = 280, cap = 300, level = 60 }))
			assert.equal(
				"Nothing mapped for Lockpicking 280 to 300: 1 target: new in Forever, position not known yet.",
				list.empty
			)
			assert.equal("Nothing mapped for Lockpicking 280 to 300", list.selected.empty.title)
			assert.equal(0, #list.spots)
		end)

		it("works in preview with no skill and says why the bars are bare", function()
			local list = W.whereList(lockQ(W, { skill = SECRET, cap = SECRET }))
			assert.equal("Lockpicking skill unknown", list.head.title)
			assert.matches("Skill unknown until the first skill-up message", list.head.sub, 1, true)
			assert.equal(2, #list.spots)
			assert.same({ "from 1", "from 70" }, { list.spots[1].yield, list.spots[2].yield })
		end)

		it("says so with no data for the skill", function()
			local list = W.whereList({ data = {}, line = 182, name = "Herbalism", skill = 10 })
			assert.equal("No data for Herbalism.", list.empty)
			assert.equal("Nothing mapped for Herbalism 10 to 300", list.selected.empty.title)
		end)

		it("lists fishing zones, clean catches first, locked ones last", function()
			local list = W.whereList({ data = nodeData(), line = 356, skill = 100, cap = 150 })
			assert.same(
				{ "Testlands", "The Deep", "Otherlands" },
				{ list.spots[1].title, list.spots[2].title, list.spots[3].title }
			)
			assert.same({ "no fish get away", "green" }, { list.spots[1].yield, list.spots[1].yieldTone })
			assert.equal("needs 130, you have 100", list.spots[3].locked)
			assert.equal("fish:Testlands", list.selected.key)
		end)
	end)

	describe("the route to 300 of a world skill", function()
		it("lists done, current and coming brackets and the gap", function()
			local p = W.worldPath(lockQ(W, { skill = 100 }))
			local rows = {}
			for i, r in ipairs(p.rows) do
				rows[i] = { r.state, r.title }
			end
			assert.same({
				{ "done", "1 to 70: Testlands" },
				{ "now", "70 to 170: Fort Test, Testlands" },
				{ "gap", "Nothing mapped from 170 to 175" },
				{ "todo", "175 to 275: Fort Test, Testlands" },
				{ "gap", "Nothing mapped from 275 to 300" },
			}, rows)
			assert.equal("Mobs 38-40, flight: Alpha Camp, from Classic, unconfirmed", p.rows[2].sub)
			assert.equal("1 target: new in Forever, position not known yet", p.rows[5].sub)
			assert.equal("lock:testlands:40-30", p.rows[2].action.spot)
			assert.is_false(p.complete)
		end)
	end)

	describe("live", function()
		local where
		before_each(function()
			where = W.where(lockQ(W, { skill = SECRET }), fort())
		end)

		it("names the broken link with no position", function()
			local live = W.live(where, nil, nil, { now = 0 })
			assert.is_false(live.ok)
			assert.equal("Position hidden here (in an instance). It comes back outside.", live.why)
			local s = W.whereLive(where, live)
			assert.same(
				{ "no position", "Position hidden here (in an instance). It comes back outside." },
				{ s.dist, s.line2 }
			)
			assert.same({ "no position", "ash" }, { W.tracker(where, live).right, W.tracker(where, live).rightTone })
		end)

		it("stays in travel mode far away and gives the distance to the spot", function()
			-- 10 percent west of the centre: 300 yd
			local live = W.live(where, { map = 1, x = 0.305, y = 0.304 }, nil, { now = 0, maps = MAPS })
			assert.same({ true, true, "travel" }, { live.ok, live.onMap, live.mode })
			assert.near(300, live.yards, 1e-6)
			assert.equal("east", live.compass)
			assert.same({ true, false }, live.legsDone) -- standing at the flight point
			local s = W.whereLive(where, live)
			assert.equal("300 yd", s.dist)
			assert.equal("Go to Fort Test, 300 yd east (unconfirmed). Now 300 yd east", s.line2)
			local t = W.tracker(where, live)
			assert.same(
				{ "Fort Test", "300 yd", "Go to Fort Test, 300 yd east (unconfirmed)" },
				{ t.title, t.right, t.sub }
			)
			assert.equal("band", t.bar.kind)
			assert.same({ label = "Mobs 38-40", tone = "yellow" }, t.mobs)
		end)

		it("zooms in at the edge and holds until well outside", function()
			local inside = W.live(where, { map = 1, x = 0.42, y = 0.304 }, nil, { now = 0, maps = MAPS }) -- 45 yd
			assert.equal("spot", inside.mode)
			local between = W.live(where, { map = 1, x = 0.44, y = 0.304 }, inside, { now = 1, maps = MAPS }) -- 105 yd
			assert.equal("spot", between.mode)
			local out = W.live(where, { map = 1, x = 0.46, y = 0.304 }, between, { now = 2, maps = MAPS }) -- 165 yd
			assert.equal("travel", out.mode)
			assert.equal("travel", W.live(where, { map = 1, x = 0.44, y = 0.304 }, out, { now = 3, maps = MAPS }).mode)
			assert.equal(
				"spot",
				W.live(where, { map = 1, x = 0.46, y = 0.304 }, out, { now = 3, maps = MAPS, mode = "spot" }).mode
			)
		end)

		it("words the next stop, the floor and the visits", function()
			local prev = { visited = W.visit(nil, 3, 100, 300), mode = "spot" }
			local live = W.live(where, { map = 1, x = 0.42, y = 0.3075 }, prev, { now = 160, maps = MAPS, last = 3 })
			assert.same({ 4, 1 }, { live.nextIndex, live.floor })
			assert.near(30, live.yards, 1e-6)
			local s = W.whereLive(where, live, 160)
			assert.equal("Stop 4 of 6: Dented Footlocker, 30 yd west, upstairs", s.line2)
			assert.equal("upstairs", s.floorWord)
			assert.equal("1 visited, the first is back in 4:00", s.visitedLine)
			assert.same({ state = "done", raised = true }, s.ticks[3])
			assert.same({ state = "next", raised = false }, s.ticks[4])
			assert.same({ state = "todo", raised = true }, s.ticks[1])
			local t = W.tracker(where, live, 160)
			assert.same(
				{ "Stop 4 of 6", "30 yd", "Dented Footlocker", "ticks" },
				{ t.title, t.right, t.sub, t.bar.kind }
			)
			assert.equal(6, #t.bar.ticks)
		end)

		it("gives the colour of the stop and how long it lasts", function()
			local w = W.where(lockQ(W), fort())
			local live = W.live(w, { map = 1, x = 0.40, y = 0.30 }, { mode = "spot" }, { now = 0, maps = MAPS })
			local t = W.tracker(w, live, 0)
			assert.same({ "Battered Footlocker", "yellow to 120", "yellow" }, { t.sub, t.gain, t.gainTone })
		end)

		it("turns to a plain bar past twenty stops", function()
			local s = fort()
			s.pts, s.pk, s.z = {}, {}, nil
			for i = 1, 22 do
				s.pts[#s.pts + 1], s.pts[#s.pts + 2] = 40 + i / 100, 30
				s.pk[i] = 1
			end
			local w = W.where(lockQ(W, { skill = SECRET }), s)
			local live = W.live(
				w,
				{ map = 1, x = 0.40, y = 0.30 },
				{ mode = "spot", visited = { [2] = 999 } },
				{ now = 0, maps = MAPS }
			)
			assert.same({ kind = "steps", done = 1, total = 22 }, W.tracker(w, live, 0).bar)
		end)

		it("points at the first leg from another zone", function()
			local live = W.live(where, { map = 2, x = 0.5, y = 0.5 }, { mode = "spot" }, { now = 0, maps = MAPS })
			assert.same({ false, "travel" }, { live.onMap, live.mode })
			local s = W.whereLive(where, live)
			assert.equal("via Alpha Camp", s.dist)
			assert.equal("Fly to Alpha Camp. You are in another zone. The route shows when you arrive.", s.line2)
		end)

		it("says no distance when the map's size is missing", function()
			local live = W.live(where, { map = 1, x = 0.3, y = 0.3 }, nil, { now = 0, maps = {} })
			assert.equal("no distance: the size of this map is not in the data", live.why)
			assert.equal("no distance", W.whereLive(where, live).dist)
		end)

		it("shows the empty card's title on the tracker", function()
			local e = W.emptyWhere(lockQ(W), 275, 300)
			assert.equal("Nothing mapped for Lockpicking 275 to 300", W.tracker(e, {}).title)
			assert.equal("Nothing mapped for Lockpicking 275 to 300", W.whereLive(e, {}).line2)
		end)
	end)

	describe("errands", function()
		local I = F.ITEM
		local function npcs()
			return ns.Guide.seedRecords({
				{
					id = 1,
					name = "Trainer Tess",
					map = 1,
					x = 50,
					y = 50,
					role = "trainer",
					trains = "Leatherworking",
					place = "Test City",
				},
				{
					id = 2,
					name = "Vendor Vic",
					map = 1,
					x = 51,
					y = 50,
					role = "trade",
					place = "Test City",
					sells = { I.THREAD, I.DYE },
				},
				{ id = 3, name = "Auctioneer Al", map = 1, x = 50, y = 52, role = "auction", place = "Test City" },
				{
					id = 4,
					name = "Vendor Far",
					map = 2,
					x = 10,
					y = 10,
					role = "trade",
					place = "Far Town",
					sells = { I.THREAD },
				},
			})
		end
		local step = {
			kind = "craft",
			spell = 2167,
			name = "Gray Leather Boots",
			buy = {
				{ item = I.THREAD, count = 4, where = "vendor", each = 100 },
				{ item = I.DYE, count = 2, where = "vendor", each = 350 },
				{ item = I.MEDIUM, count = 8, where = "ah", each = 99 },
			},
		}
		local function ctx(extra)
			local c = {
				step = step,
				profession = "Leatherworking",
				npcs = npcs(),
				data = { maps = MAPS },
				here = { map = 1, x = 0.5, y = 0.51 },
				money = ns.Logic.money,
				nameOf = function(item)
					return ({ [I.THREAD] = "Fine Thread", [I.DYE] = "Gray Dye", [I.MEDIUM] = "Medium Leather" })[item]
				end,
			}
			for k, v in pairs(extra or {}) do
				c[k] = v
			end
			return c
		end

		it("groups stops by city, the one serving everything first, in walking order", function()
			local list = W.errands(ctx())
			assert.same({ "Test City", "Far Town" }, { list[1].title, list[2].title })
			local w = list[1]
			assert.same({ "errand", "2 stops", 1 }, { w.kind, w.sub, w.map })
			local a, b = w.stops[1], w.stops[2]
			-- the player stands 20 yd south of the trainer; the auctioneer is 20 yd further south, the vendor 36 yd off
			assert.same(
				{ "Auctioneer Al", "auction", "Buy 8 Medium Leather", "7s 92c", "now", "20 yd" },
				{ a.name, a.kind, a.what, a.cost, a.state, a.leg }
			)
			assert.same(
				{ "Vendor Vic", "vendor", "Buy 4 Fine Thread, 2 Gray Dye", "11s 0c", "todo", "+50 yd" },
				{ b.name, b.kind, b.what, b.cost, b.state, b.leg }
			)
			assert.same(
				{ "stop", 1, "now", "Auctioneer Al: Buy 8 Medium Leather" },
				{ w.pins[1].kind, w.pins[1].n, w.pins[1].state, w.pins[1].tip }
			)
			assert.equal("Run the errands in Test City", w.verb.text)
			assert.equal("classic", w.confidence)
			assert.equal("1 stop, 1 of 2 errands", list[2].sub)
			assert.equal("Buy 4 Fine Thread, 2 Gray Dye (sells only some)", list[2].stops[1].what)
		end)

		it("puts the trainer before any purchase", function()
			local w = W.errand(ctx({ step = { kind = "train", name = "Gray Leather Boots", at = 100, cost = 500 } }))
			assert.same(
				{ "Trainer Tess", "Learn Gray Leather Boots", "5s 0c" },
				{ w.stops[1].name, w.stops[1].what, w.stops[1].cost }
			)
			assert.equal("Trainer Tess", w.stops[1].target)
		end)

		it("drops what the bags already hold and marks done stops", function()
			local have = function(item)
				return item == I.MEDIUM and 8 or 0
			end
			local w = W.errand(ctx({ have = have }))
			assert.equal(1, #w.stops)
			assert.equal("vendor", w.stops[1].kind)
			w = W.errand(ctx({ done = { auction = true } }))
			assert.same({ "done", "now" }, { w.stops[1].state, w.stops[2].state })
			local t = W.tracker(w, { ok = true, onMap = true, yards = 50 })
			assert.same({ "2 of 2: Vendor Vic", "Buy 4 Fine Thread, 2 Gray Dye" }, { t.title, t.sub })
			assert.same({ kind = "steps", done = 1, total = 2 }, t.bar)
			assert.same({ name = "Vendor Vic" }, t.target)
		end)

		it("names what follows on the tracker", function()
			local t = W.tracker(W.errand(ctx()), { ok = true, onMap = true, yards = 20 })
			assert.same({ "1 of 2: Auctioneer Al", "then vendor" }, { t.title, t.gain })
		end)

		it("has no legs without a position and a plain card with no errand", function()
			local w = W.errand(ctx({ here = SECRET }))
			-- the walk to the first stop is unknown; the legs between stops still hold
			assert.equal("", w.stops[1].leg)
			assert.equal("+50 yd", w.stops[2].leg)
			w = W.errand(ctx({ step = { kind = "craft", buy = {} } }))
			assert.equal("Nothing to fetch right now.", w.empty.title)
			local c = ctx()
			c.step = nil
			assert.equal(0, #W.errands(c))
		end)

		it("turns trainer data rows into records for one faction", function()
			local recs = W.trainerRecords({
				{
					id = 1,
					name = "A",
					map = 1,
					x = 1,
					y = 1,
					role = "trainer",
					trains = "Mining",
					faction = "A",
					classic = true,
				},
				{ id = 2, name = "H", map = 1, x = 1, y = 1, role = "trainer", trains = "Mining", faction = "H" },
				{
					id = 3,
					name = "B",
					map = 1,
					x = 1,
					y = 1,
					role = "recipes",
					faction = "B",
					sells = { 5 },
					limited = { [5] = 1 },
				},
				{ id = 4, name = "N", role = "trainer", trains = "Mining", nopos = true },
				{ id = 5, name = "D", map = 1, x = 1, y = 1, role = "recipedrop", recipes = { 7 } },
			}, "A")
			assert.same({ 1, 3 }, { recs[1].id, recs[2].id })
			assert.same({ "Mining", "classic" }, { recs[1].trains, recs[1].confidence })
			assert.same({ [5] = true }, recs[2].sells)
			assert.equal(2, #recs)
			assert.equal(1, ns.Guide.serves(recs[1], { kind = "trainer", profession = "Mining" }))
		end)
	end)

	describe("overview", function()
		local function profs()
			return {
				[165] = { name = "Leatherworking", to = 300, recipes = {} },
				[185] = { name = "Cooking", to = 300, recipes = {} },
				[171] = { name = "Alchemy", to = 300, recipes = {} },
				[186] = {
					name = "Mining",
					to = 300,
					ranks = {
						{ name = "Apprentice", cap = 75, cost = 10 },
						{ name = "Journeyman", cap = 150, cost = 500 },
					},
				},
			}
		end
		local function costFn(line, _, from, to)
			if line == 165 then
				return {
					total = 250000,
					spent = 260000,
					back = 40000,
					trainingCost = 10000,
					recipesToBuy = { { name = "Pattern", price = 20000 } },
					gaps = {},
					unknownPrices = 1,
					unknownItems = { 4234 },
				}
			elseif line == 185 then
				return {
					total = 5000,
					spent = 5000,
					back = 0,
					trainingCost = 0,
					recipesToBuy = {},
					gaps = { { from = 225, to = 240, why = "no recipe gives skill" } },
					unknownPrices = 3,
					unknownItems = { 1, 2, 3 },
				}
			end
			return nil, ("no recipes priced from %d to %d"):format(from, to)
		end
		local function ctx(extra)
			local d = lockData()
			d.skills[186] = nodeData().skills[186]
			local c = {
				professions = profs(),
				data = d,
				costFn = costFn,
				money = ns.Logic.money,
				level = 38,
				faction = "A",
				nameOf = function(item)
					return "Item" .. item
				end,
				skills = {
					[165] = { rank = 150, cap = 150, learned = true, available = true },
					[633] = { available = false, learned = false, why = "not available: Rogues only" },
					[186] = { rank = 40, cap = 75, learned = true, available = true },
				},
			}
			for k, v in pairs(extra or {}) do
				c[k] = v
			end
			return c
		end
		local function byName(o)
			local m = {}
			for _, r in ipairs(o.rows) do
				m[r.name] = r
			end
			return m
		end

		it("has one row per profession and world skill, by name", function()
			local o = W.overview(ctx())
			local names = {}
			for i, r in ipairs(o.rows) do
				names[i] = r.name
			end
			assert.same({ "Alchemy", "Cooking", "Leatherworking", "Lockpicking", "Mining" }, names)
		end)

		it("splits a crafting cost into materials, recipes and training", function()
			local r = byName(W.overview(ctx())).Leatherworking
			assert.same({
				total = "25g 0s 0c",
				copper = 250000,
				mats = "22g 0s 0c",
				recipes = "2g 0s 0c",
				training = "1g 0s 0c",
			}, r.cost)
			assert.same(
				{ "complete", "complete", "TSM lacks 1 price", "ash" },
				{ r.status, r.statusText, r.line, r.lineTone }
			)
			assert.same(
				{ 150, 150, true, "150 / 150", "at rank cap" },
				{ r.skill, r.cap, r.learned, r.skillText, r.state }
			)
			assert.equal(1, r.tsmMissing)
		end)

		it("names each gap of a crafting profession and what TSM lacks", function()
			local o = W.overview(ctx())
			local r = byName(o).Cooking
			assert.same({ "gaps", "1 gap", "warn" }, { r.status, r.statusText, r.lineTone })
			assert.equal("225 to 240: no recipe gives skill. TSM lacks 3 prices", r.line)
			assert.same(
				{ from = 225, to = 240, reason = "no recipe gives skill", lacks = { "Item1", "Item2", "Item3" } },
				r.coverage.gaps[1]
			)
			assert.same(
				{ false, "not learned", "not learned", "none" },
				{ r.learned, r.skillText, r.state, r.cost.recipes }
			)
			assert.equal(4, o.totals.tsmMissing)
		end)

		it("says no data, with the reason, when the planner gives nothing", function()
			local r = byName(W.overview(ctx())).Alchemy
			assert.same(
				{ "nodata", "no data", "1 to 300: no recipes priced from 1 to 300" },
				{ r.status, r.statusText, r.line }
			)
			assert.is_nil(r.cost.total)
			local c = ctx()
			c.costFn = nil
			r = byName(W.overview(c)).Alchemy
			assert.equal("1 to 300: no cost function (the planner is not loaded)", r.line)
		end)

		it("reports a world skill's spots or its uncovered brackets, and its training", function()
			local r = byName(W.overview(ctx())).Mining
			assert.same({
				"gaps",
				"2 gaps",
				"165 to 225: Iron Deposit (20 positions): too few positions in the data to make a spot",
			}, { r.status, r.statusText, r.line })
			assert.same({ "5s 0c", "5s 0c", "none" }, { r.cost.training, r.cost.total, r.cost.mats })
			assert.equal("1 spot, nothing mapped for 165-225, 225-300", r.note)
			assert.equal(1, r.spots)
		end)

		it("dims a skill the class cannot have", function()
			local r = byName(W.overview(ctx())).Lockpicking
			assert.same(
				{ false, "nodata", "Rogues only", "Rogues only", "Rogues only" },
				{ r.usable, r.status, r.statusText, r.why, r.skillText }
			)
			assert.equal(0, #r.coverage.gaps)
		end)

		it("plans a rogue's Lockpicking from the skill it has", function()
			local c = ctx()
			c.skills[633] = { rank = 100, cap = 190, learned = true, available = true }
			local r = byName(W.overview(c)).Lockpicking
			assert.same(
				{ "gaps", "2 gaps", "170 to 175: nothing in the data gives points here", "no materials" },
				{ r.status, r.statusText, r.line, r.cost.total }
			)
			assert.equal("1 target: new in Forever, position not known yet", r.coverage.gaps[2].reason)
		end)

		it("lists every hole with profession, bracket and reason", function()
			local o = W.overview(ctx())
			local out = {}
			for i, h in ipairs(o.holes) do
				out[i] = ("%s %d-%d: %s"):format(h.name, h.from, h.to, h.reason)
			end
			assert.same({
				"Alchemy 1-300: no recipes priced from 1 to 300",
				"Cooking 225-240: no recipe gives skill",
				"Mining 165-225: Iron Deposit (20 positions): too few positions in the data to make a spot",
				"Mining 225-300: nothing in the data gives points here",
			}, out)
		end)

		it("words the two lines of each card: the cost to the top and the state of the path", function()
			local by = byName(W.overview(ctx()))
			local function card(r)
				return { r.costText, r.costTone, r.coverText, r.coverTone }
			end
			-- priced, with one price TSM lacks: the cost stands and is marked
			assert.same({ "To 300: 25g 0s 0c + unpriced", "warn", "Path complete", "green" }, card(by.Leatherworking))
			assert.same({ "1 gap: 225 to 240", "warn" }, { by.Cooking.coverText, by.Cooking.coverTone })
			-- no plan: the reason takes the cost's place, in sentence case
			assert.same({ "No recipes priced from 1 to 300", "ash", "No plan yet", "ash" }, card(by.Alchemy))
			-- a gathering skill costs its training only; its holes are counted with the first one named
			assert.same({ "To 300: 5s 0c for training", "bone", "2 gaps, first 165 to 225", "warn" }, card(by.Mining))
			-- a skill the class cannot have: no cost, the reason once
			assert.same({ "", "ash", "Rogues only", "ash" }, card(by.Lockpicking))
			local c = ctx()
			c.skills[165] = { rank = 300, cap = 300, learned = true }
			assert.same(
				{ "At 300: nothing left to level", "ash", "Path complete", "green" },
				card(byName(W.overview(c)).Leatherworking)
			)
			-- the plan's own unpriced items are named for the tooltip
			c = ctx()
			local cost = c.costFn
			c.costFn = function(line, ...)
				local r, why = cost(line, ...)
				if type(r) == "table" and line == 165 then
					r.unpriced =
						{ count = 2, items = { { item = 7, name = "Odd Hide", count = 3 }, { item = 8, count = 1 } } }
				end
				return r, why
			end
			local lw = byName(W.overview(c)).Leatherworking
			assert.same({ "Odd Hide", "Item8" }, lw.unpriced)
			assert.equal("To 300: 25g 0s 0c + unpriced", lw.costText)
		end)

		it("calls a skill at 300 done", function()
			local c = ctx()
			c.skills[165] = { rank = 300, cap = 300, learned = true }
			local r = byName(W.overview(c)).Leatherworking
			assert.same(
				{ "complete", "at cap", "At 300: nothing left to level.", "0c" },
				{ r.status, r.state, r.line, r.cost.total }
			)
		end)

		it("is empty with nothing loaded", function()
			local o = W.overview({})
			assert.same({ 0, 0 }, { #o.rows, #o.holes })
			assert.equal("prices not read yet", o.totals.priceAge)
		end)
	end)

	describe("path of a crafting profession", function()
		local function plan()
			local full = load({ "Logic.lua", "Planner.lua", "Guide.lua", "Where.lua" })
			return full.Planner.run(F.cooking()), full.Where, full.Logic
		end
		local RANKS = {
			{ name = "Apprentice", cap = 75 },
			{ name = "Journeyman", cap = 150, skill = 50 },
			{ name = "Expert", cap = 225, skill = 125 },
		}

		it("turns the planner's steps into segments, markers and rows", function()
			local p, W2, L = plan()
			local path = W2.path({ profession = "Cooking", skill = 173, plan = p, ranks = RANKS, money = L.money })
			assert.same({ at = 150, label = "Journeyman 150" }, path.caps[2])
			assert.same({ 50, 125 }, path.gates)
			assert.same({ from = 1, to = 173, name = "Done", done = true }, path.segments[1])
			-- one row per line of W.lines, numbered without a hole; no "done" fold row
			local lines = W2.lines(p.steps)
			assert.equal(#lines, #path.rows)
			assert.equal(#lines, #path.lines)
			local crafts, unlocks = 0, 0
			for _, st in ipairs(p.steps) do
				crafts = crafts + (st.kind == "craft" and 1 or 0)
				unlocks = unlocks + ((st.kind ~= "craft" and st.kind ~= "gap") and 1 or 0)
			end
			for i, row in ipairs(path.rows) do
				local line, st = lines[i], p.steps[lines[i].step]
				assert.same({ i, line.step, line.title }, { row.n, row.step, row.title })
				assert.same({ "selectStep", line.step }, { row.action.id, row.action.step })
				if line.kind == "craft" then
					assert.equal("step", row.kind)
					assert.equal(st.color, row.rangeTone)
					assert.equal(("%d to %d"):format(line.from, line.to), row.range)
					assert.is_true(#row.sub <= W2.PATH_SUB + 12, row.sub)
					assert.is_nil(row.sub:find("...", 1, true))
				end
				assert.is_nil(row.ways) -- no "N ways" on a row: the alternatives are in the detail
			end
			assert.is_true(crafts >= 1)
			assert.equal(unlocks, #path.markers)
			-- every row is in exactly one stretch, no stretch is longer than the page holds, one is shown
			local count = 0
			for _, s in ipairs(path.stretches) do
				assert.is_true(#s.rows >= 1 and #s.rows <= W2.PATH_MAX)
				assert.same({ "selectStretch", s.index }, { s.action.id, s.action.index })
				count = count + #s.rows
			end
			assert.equal(#path.rows, count)
			assert.is_true(path.stretches[path.stretch].selected)
			assert.same({ path.stretches[path.stretch].from, path.stretches[path.stretch].to }, {
				path.shade.from,
				path.shade.to,
			})
			assert.equal(crafts + 1, #path.segments)
			for _, seg in ipairs(path.segments) do
				if not seg.done then
					assert.is_true(#seg.bands >= 1)
					assert.equal(seg.from, seg.bands[1].from)
					assert.equal(seg.to, seg.bands[#seg.bands].to)
				end
			end
			-- the default selection: the first line that is not done
			local first
			for _, row in ipairs(path.rows) do
				first = first or (not row.done and row or nil)
			end
			assert.same({ first.step, true, first.title }, { path.selected, first.selected, path.crumb })
			assert.is_truthy(path.detail.title)
		end)

		it("builds rows, markers and the detail of each step kind", function()
			local steps = {
				{ kind = "trainRank", name = "Expert", cap = 225, by = 150, skill = 150, cost = 5000 },
				{
					kind = "buyRecipe",
					spell = 7828,
					name = "Recipe: Rockscale Cod",
					item = 6369,
					price = 2811,
					where = "ah",
					learn = 175,
				},
				{
					kind = "craft",
					spell = 7828,
					name = "Rockscale Cod",
					crafts = 14,
					expected = 9.2,
					source = "buy",
					from = 175,
					to = 195,
					color = "orange",
					thresholds = { 190, 230, 1 },
					buy = { { item = 6362, count = 14, where = "ah", each = 15 } },
					used = { { item = 159, count = 2 } },
					cash = { out = 210, back = 84 },
					others = { { spell = 3398, name = "Hot Lion Chops", extra = 420 } },
					shortcuts = {
						{
							spell = 9,
							name = "Secret Stew",
							saves = 300,
							bop = true,
							why = "its recipe binds when picked up",
						},
					},
				},
				{ kind = "train", spell = 13028, name = "Goldthorn Tea", at = 195, unchecked = true, cost = 900 },
				{
					kind = "gap",
					from = 195,
					to = 215,
					why = "no known or buyable recipe gives skill here",
					shortcuts = {},
				},
			}
			local path = W.path({
				profession = "Cooking",
				skill = 150,
				plan = { steps = steps },
				ranks = RANKS,
				money = ns.Logic.money,
				selected = 3,
				nameOf = function(item)
					return item == 6362 and "Raw Rockscale Cod" or "Spring Water"
				end,
				have = function(item)
					return item == 159 and 5 or 0
				end,
				errand = function(st)
					return { kind = "errand", key = "e:" .. st.spell }
				end,
			})
			-- three lines: the recipe is folded into its craft, the rank training hangs on it, the lone trainer
			-- recipe and the hole stay lines of their own
			local r = path.rows
			assert.equal(3, #r)
			assert.same({
				1,
				3,
				"step",
				"Buy the recipe and craft 14 Rockscale Cod",
				"Usually 10 crafts. Buy 14 Raw Rockscale Cod",
				"175 to 195",
				"orange",
				"30s 21c",
				true,
			}, {
				r[1].n,
				r[1].step,
				r[1].kind,
				r[1].title,
				r[1].sub,
				r[1].range,
				r[1].rangeTone,
				r[1].cost,
				r[1].selected,
			})
			assert.is_nil(r[1].costNote)
			assert.same(
				{ "unlock", 4, "Learn Goldthorn Tea", "Not checked at a trainer yet.", "at 195", "9s 0c" },
				{ r[2].kind, r[2].step, r[2].title, r[2].sub, r[2].range, r[2].cost }
			)
			assert.same(
				{ "gap", "No recipe from 195 to 215", "No known or buyable recipe gives skill here.", "warn" },
				{ r[3].kind, r[3].title, r[3].sub, r[3].rangeTone }
			)
			-- the stretch: Expert's range, with the training that the plan asks for inside it
			assert.equal(1, #path.stretches)
			local s = path.stretches[1]
			assert.same({ "175 to 215", "Expert, 175 to 215", "you are here", true }, {
				s.label,
				s.head.title,
				s.state,
				s.selected,
			})
			assert.same({ "Train Expert at 150, 50s 0c: needed to pass 150" }, s.head.lines)
			assert.same({ 3, "Buy the recipe and craft 14 Rockscale Cod" }, { path.selected, path.crumb })
			local kinds, selects = {}, {}
			for i, m in ipairs(path.markers) do
				kinds[i] = m.kind .. "@" .. m.at
				selects[i] = m.step
			end
			assert.same({ "train@150", "ah@175", "bop@175", "train@195" }, kinds)
			-- a marker selects the line it belongs to
			assert.same({ 3, 3, 3, 4 }, selects)
			assert.same({ reason = "no known or buyable recipe gives skill here" }, path.segments[3].gap)
			assert.same(
				{ { from = 175, to = 190, color = "orange" }, { from = 190, to = 195, color = "yellow" } },
				path.segments[2].bands
			)
			local d = path.detail
			assert.same({ "Rockscale Cod", "orange", 1 }, { d.title, d.color, d.n })
			assert.same({
				{ text = "Craft up to 14. Usually 10 are enough.", tone = "bone" },
				{ text = "Skill 175 to 195, orange at the start.", tone = "orange" },
			}, d.dothis)
			assert.same({ text = "Buy the recipe on the auction house, 28s 11c.", tone = "bone" }, d.recipe)
			assert.is_nil(d.note)
			assert.same({
				name = "Spring Water",
				need = 2,
				have = 5,
				source = "your bags",
				right = "from your bags",
				tone = "green",
			}, d.materials[1])
			assert.same({
				name = "Raw Rockscale Cod",
				need = 14,
				have = 0,
				source = "auction",
				price = "15c",
				right = "auction, 15c each",
				tone = "bone",
			}, d.materials[2])
			assert.equal("Other ways from 175 to 195", d.ways.title)
			assert.same({ label = "Rockscale Cod", right = "the plan's pick", picked = true }, d.ways.rows[1])
			assert.same(
				{ "Hot Lion Chops", "+4s 20c", false, "swap" },
				{ d.ways.rows[2].label, d.ways.rows[2].right, d.ways.rows[2].picked, d.ways.rows[2].action.id }
			)
			-- "shortcut" is said only of an alternative that is not in the plan
			assert.same(
				{ "Secret Stew", "shortcut, saves 3s 0c", "allow" },
				{ d.ways.rows[3].label, d.ways.rows[3].right, d.ways.rows[3].action.id }
			)
			assert.same({ "Secret Stew", "its recipe binds when picked up" }, d.ways.rows[3].tip)
			for _, row in ipairs(r) do
				assert.is_nil((row.title .. row.sub):lower():find("shortcut", 1, true))
			end
			assert.equal("e:7828", d.where.key)
			assert.same({ "Open in Where", true }, { d.actions[1].label, d.actions[1].enabled })
		end)

		it("selects by any step of a line, shows the stretch a button chose, and words the other kinds", function()
			local steps = {
				{ kind = "train", spell = 1, name = "Spice Bread", at = 1, cost = 10 },
				{
					kind = "craft",
					spell = 1,
					name = "Spice Bread",
					crafts = 40,
					expected = 40,
					from = 1,
					to = 40,
					color = "orange",
					buy = {
						{ item = 1, count = 40, where = "vendor", each = 10 },
						{ item = 2, count = 40, where = "ah", unpriced = true },
						{ item = 3, count = 5, where = "ah", each = 3 },
						{ item = 4, count = 5, where = "ah", each = 3 },
						{ item = 5, count = 5, where = "ah", each = 3 },
					},
					unpriced = { { item = 2, name = "Mild Spices", count = 40 } },
				},
				{ kind = "trainRank", name = "Journeyman", cap = 150, at = 50, cost = 500, level = 10, have = 8 },
				{
					kind = "craft",
					spell = 2,
					name = "Smoked Bear Meat",
					crafts = 50,
					from = 40,
					to = 80,
					color = "yellow",
				},
				{
					kind = "gap",
					from = 80,
					to = 100,
					reason = "norecipe",
					why = "no recipe in the data gives skill here",
				},
			}
			local names = { "Simple Flour", "Mild Spices", "Refreshing Spring Water", "Holiday Spices", "Small Egg" }
			local function build(extra)
				local ctx = {
					profession = "Cooking",
					skill = 20,
					plan = { steps = steps },
					ranks = RANKS,
					money = ns.Logic.money,
					nameOf = function(item)
						return names[item]
					end,
					have = function()
						error("the bag scan failed")
					end,
				}
				for k, v in pairs(extra or {}) do
					ctx[k] = v
				end
				return W.path(ctx)
			end
			-- the docked panel's step 1 (the training) selects the line it is folded into
			local path = build({ selected = 1 })
			assert.same({ 2, "Learn and craft 40 Spice Bread" }, { path.selected, path.rows[1].title })
			-- line 2: the materials are fitted to the row with "and N more", the whole list is in the tooltip
			local row = path.rows[1]
			assert.equal("Buy 40 Simple Flour, 40 Mild Spices and 3 more", row.sub)
			assert.is_true(#row.sub <= W.PATH_SUB)
			assert.matches("5 Holiday Spices, 5 Small Egg$", row.subFull)
			assert.equal(row.subFull, row.tip[2])
			-- an unpriced item is never a hole: the cost stands, marked, and the names are said
			assert.same({ "4s 55c", "+ unpriced" }, { row.cost, row.costNote })
			assert.same({ "Price unknown for 1 item: Mild Spices. Not in the cost.", "warn" }, row.tip[3])
			assert.equal("Price unknown for 1 item: Mild Spices. Not in the cost.", path.detail.note)
			assert.same({ text = "From the trainer at 1, 10c.", tone = "bone" }, path.detail.recipe)
			-- a failing bag scan does not break the page: nothing is held
			assert.same({ 0, "vendor, 10c each", "bone" }, {
				path.detail.materials[1].have,
				path.detail.materials[1].right,
				path.detail.materials[1].tone,
			})
			assert.same({ "auction, price unknown", "warn" }, {
				path.detail.materials[2].right,
				path.detail.materials[2].tone,
			})
			-- two stretches (cut at 75); the rank training with the level only because it is too low
			assert.same({ "1 to 80", "80 to 100" }, { path.stretches[1].label, path.stretches[2].label })
			assert.same(
				{ "Train Journeyman at 50, 5s 0c, needs level 10, you are 8: needed to pass 75" },
				path.stretches[1].head.lines
			)
			assert.same({ 1, 1, 80 }, { path.stretch, path.shade.from, path.shade.to })
			-- a stretch button: the list shows that stretch, the selection and its detail stay
			local other = build({ selected = 1, stretch = 2 })
			assert.same({ 2, 2, true, false }, {
				other.stretch,
				other.selected,
				other.stretches[2].selected,
				other.stretches[1].selected,
			})
			assert.equal("Spice Bread", other.detail.title)
			-- a stretch that does not exist falls back to the selected line's
			assert.equal(1, build({ selected = 1, stretch = 9 }).stretch)
			-- the hole: a line with its reason, no cost, and a detail that says so
			local hole = build({ selected = 5 })
			assert.same(
				{ "gap", "No recipe from 80 to 100", "No recipe in the data gives skill here.", "warn" },
				{ hole.rows[3].kind, hole.rows[3].title, hole.rows[3].sub, hole.rows[3].rangeTone }
			)
			assert.same(
				{ "No recipe from 80 to 100", "warn", 2 },
				{ hole.detail.title, hole.detail.color, hole.stretch }
			)
			assert.is_nil(hole.detail.ways)
			-- a line without a recipe step is known
			local known = build({ selected = 4 })
			assert.same(
				{ text = "Known, or learned earlier on this path.", tone = "green", known = true },
				known.detail.recipe
			)
			assert.equal("From your bags.", known.rows[2].sub)
			-- done lines: at 80 the first two are behind, the selection moves to the first that is not
			local later = build({ skill = 80 })
			assert.same({ true, true, false, 5 }, {
				later.rows[1].done,
				later.rows[2].done,
				later.rows[3].done,
				later.selected,
			})
			assert.same({ true, "done" }, { later.stretches[1].done, later.stretches[1].state })
		end)

		it("pathSelect serves any rows with from and to (the world skills' path)", function()
			local rows = {}
			for i = 1, 20 do
				rows[i] =
					{ n = i, step = i, title = "Leg " .. i, from = (i - 1) * 15, to = i * 15, done = i * 15 <= 100 }
			end
			local p = W.pathSelect({ rows = rows, skill = 100 }, {})
			-- no ranks given: the default caps cut it (75, 150, 225, 300), five legs each
			assert.same({ 4, 5, 5 }, { #p.stretches, #p.stretches[1].rows, #p.stretches[4].rows })
			assert.same({ "Apprentice, 0 to 75", "Skill 300 to 300" }, {
				p.stretches[1].head.title,
				W.pathSelect({ rows = { { n = 1, step = 1, from = 300, to = 300 } }, skill = 1 }, {}).stretches[1].head.title,
			})
			assert.same({ 7, "Leg 7", 2 }, { p.selected, p.crumb, p.stretch })
			assert.same({ id = "selectStretch", index = 2, enabled = true }, p.stretches[2].action)
			assert.same(
				{ 0, 0 },
				{ #W.pathSelect({ rows = {} }, {}).stretches, W.pathSelect({ rows = {} }, {}).stretch }
			)
		end)

		it("says why there is no plan", function()
			local path = W.path({ profession = "Cooking", skill = 1 })
			assert.matches("No plan yet", path.empty, 1, true)
			assert.same({ 0, 0, 0 }, { #path.rows, #path.stretches, path.stretch })
			assert.is_nil(path.selected)
			assert.is_nil(path.detail)
		end)
	end)

	describe("journal shell and data rows", function()
		it("lists the tabs and the professions, learned first", function()
			local j = W.journal({
				page = "where",
				profession = 165,
				counts = { shopping = 3 },
				pips = { settings = true },
				overview = {
					rows = {
						{ key = 1, name = "B", usable = true, learned = false },
						{ key = 2, name = "C", usable = true, learned = true },
						{ key = 3, name = "A", usable = false },
					},
				},
			})
			assert.same({ "where", true }, { j.page, j.showProfession })
			-- a count comes with its noun (the tab's tooltip); Overview never carries one; no noun, no count
			assert.same({
				id = "shopping",
				label = "Shopping",
				count = 3,
				tip = "3 things to buy",
				tone = "ash",
				pip = false,
			}, j.tabs[4])
			local counted =
				W.journal({ counts = { overview = 4, shopping = 1, where = 2 }, tips = { where = "2 spots" } })
			assert.same({ nil, nil }, { counted.tabs[1].count, counted.tabs[1].tip })
			assert.same({ 1, "1 thing to buy" }, { counted.tabs[4].count, counted.tabs[4].tip })
			assert.same({ 2, "2 spots" }, { counted.tabs[3].count, counted.tabs[3].tip })
			assert.is_nil(W.journal({ counts = { path = 5 } }).tabs[2].count)
			assert.same({ "bone", true }, { j.tabs[3].tone, j.tabs[6].pip })
			assert.same(
				{ { key = 2, name = "C", learned = true }, { key = 1, name = "B", learned = false } },
				j.professions
			)
			assert.same({ "overview", false }, { W.journal({ page = "nope" }).page, W.journal({}).showProfession })
		end)

		it("says which data layers loaded and which did not", function()
			local rows = W.dataRows({
				recipes = { build = "0.3.0", professions = { [1] = { recipes = { 1, 2 } } } },
				spots = lockData(),
				confirmed = { ["lock:testlands:40-30"] = true },
				trainers = { { id = 1 }, { id = 2, nopos = true } },
				tsm = { age = "2 h ago", missing = 13 },
				custom = { loaded = true, errors = { "line 14: unknown item 99999" } },
			})
			local by = {}
			for _, r in ipairs(rows) do
				by[r.id] = r
			end
			assert.same({ "ok", "build 0.3.0, 2 recipes, 1 professions" }, { by.recipes.state, by.recipes.detail })
			assert.equal("2 spots, 1 confirmed in Forever", by.spots.detail)
			assert.equal("2 listed, 1 without a position", by.trainers.detail)
			assert.same({ "absent", "not present" }, { by.priceFile.state, by.priceFile.detail })
			assert.same({ "read 2 h ago, 13 missing", "List them" }, { by.tsm.detail, by.tsm.action.label })
			assert.same(
				{ "broken", "loaded, 1 error", { "line 14: unknown item 99999" } },
				{ by.custom.state, by.custom.detail, by.custom.errors }
			)
			by = {}
			for _, r in ipairs(W.dataRows({})) do
				by[r.id] = r
			end
			assert.same({ "broken", "Data/Spots.lua did not load" }, { by.spots.state, by.spots.detail })
			assert.equal("not read: TradeSkillMaster gave no prices", by.tsm.detail)
		end)
	end)

	describe("query", function()
		it("tolerates nil, secrets and long faction names", function()
			local q = W.query(nil)
			assert.is_nil(q.skill)
			assert.equal("position unknown", q.hereWhy)
			q = W.query({
				skill = SECRET,
				level = SECRET,
				faction = "Horde",
				here = { map = 1, x = SECRET, y = 0.5 },
				hereWhy = "in an instance",
			})
			assert.same({ nil, nil, "H", nil, "in an instance" }, { q.skill, q.level, q.faction, q.here, q.hereWhy })
			assert.equal(q, W.query(q))
			assert.equal("herb", W.query({ data = { skills = { [182] = { kind = "node" } } }, line = 182 }).kind)
		end)
	end)
end)

-- The shipped data: every rank of every world skill either has a spot that gives points or lies in a named hole.
describe("Where over the shipped Data/Spots.lua", function()
	local ns, W
	local NAMES =
		{ [633] = "Lockpicking", [186] = "Mining", [182] = "Herbalism", [393] = "Skinning", [356] = "Fishing" }

	setup(function()
		ns = load({ "Logic.lua", "Guide.lua", "Where.lua" })
		assert(loadfile("Data/Spots.lua"))("SkillupHelper", ns)
		W = ns.Where
	end)

	for _, line in ipairs({ 633, 186, 182, 393, 356 }) do
		for _, faction in ipairs({ "A", "H" }) do
			it(("%s, %s: every fifth rank has a spot or a named hole"):format(NAMES[line], faction), function()
				local data = ns.Data.spots
				assert.is_table(data.skills[line])
				local base = { data = data, line = line, faction = faction, level = 60, class = "ROGUE" }
				local it2 = W.itinerary(W.query(base), 1, 300)
				for _, h in ipairs(it2.holes) do
					assert.is_string(h.reason)
					assert.is_true(#h.reason > 0)
					assert.is_true(h.to > h.from)
					print(("HOLE %s (%s) %d-%d: %s"):format(NAMES[line], faction, h.from, h.to, h.reason))
				end
				print(("ROUTE %s (%s): %s"):format(NAMES[line], faction, it2.text))
				for _, leg in ipairs(it2.legs) do
					assert.is_true(leg.to > leg.from)
					if leg.band == "green" then
						print(("SLOW %s (%s) %s: green at best when it starts"):format(NAMES[line], faction, leg.text))
					end
				end
				local ranks = { 1 }
				for s = 5, 300, 5 do
					ranks[#ranks + 1] = s
				end
				for _, s in ipairs(ranks) do
					local q = W.query({
						data = data,
						line = line,
						faction = faction,
						level = 60,
						class = "ROGUE",
						skill = s,
						cap = 300,
					})
					local now = line == 356 and W.rankFish(q, s).now or W.rank(q, s).now
					local list = W.whereList(q)
					if #now > 0 then
						assert.is_true(#list.spots > 0)
						assert.is_table(list.selected)
						assert.is_nil(list.selected.empty)
						assert.is_string(list.selected.title)
						assert.is_string(list.selected.caption.line1)
					elseif s < 300 then
						local hole
						for _, h in ipairs(it2.holes) do
							if s >= h.from and s < h.to then
								hole = h
							end
						end
						assert.is_truthy(
							hole,
							("%s %s rank %d: no spot gives points and no hole names it"):format(NAMES[line], faction, s)
						)
						assert.is_string(list.empty)
						assert.is_table(list.selected.empty)
					end
				end
			end)
		end
	end

	it("builds a model for every spot without a skill, a level or a faction", function()
		local n = 0
		for line, def in pairs(ns.Data.spots.skills) do
			local q = W.query({ data = ns.Data.spots, line = line })
			for _, spot in ipairs(def.spots or {}) do
				local w = W.where(q, spot, { next = false })
				assert.is_string(w.title)
				assert.is_string(w.caption.line1)
				if w.route then
					for _, p in ipairs(w.route.pts) do
						assert.is_true(p.x >= 0 and p.x <= 1 and p.y >= 0 and p.y <= 1)
					end
				end
				n = n + 1
			end
		end
		assert.is_true(n > 50)
	end)

	it("reports the world skills in the overview with every hole named", function()
		local skills = {}
		for line in pairs(NAMES) do
			skills[line] = { learned = false, available = true }
		end
		local o = W.overview({ professions = {}, data = ns.Data.spots, skills = skills, level = 60, faction = "H" })
		assert.equal(5, #o.rows)
		for _, r in ipairs(o.rows) do
			assert.is_true(r.status == "complete" or r.status == "gaps")
			if r.status == "gaps" then
				assert.is_string(r.line)
			end
			print(("OVERVIEW %s: %s. %s"):format(r.name, r.statusText, tostring(r.line)))
		end
	end)
end)

describe("Where: plan lines and stretches", function()
	local W
	before_each(function()
		W = load().Where
	end)

	local function craft(over)
		local st = {
			kind = "craft",
			spell = 2,
			name = "Copper Dagger",
			crafts = 43,
			expected = 30.2,
			from = 30,
			to = 65,
			color = "orange",
			buy = { { item = 1, count = 10, each = 5 } },
			cash = { out = 50 },
			others = {},
			shortcuts = {},
			unpriced = {},
		}
		for k, v in pairs(over or {}) do
			st[k] = v
		end
		return st
	end
	local function train(over)
		local st = { kind = "train", spell = 2, name = "Copper Dagger", at = 30, cost = 100 }
		for k, v in pairs(over or {}) do
			st[k] = v
		end
		return st
	end
	local function recipe(over)
		local st = {
			kind = "buyRecipe",
			spell = 2,
			name = "Copper Dagger",
			learn = 30,
			price = 500,
			where = "vendor",
			owned = false,
		}
		for k, v in pairs(over or {}) do
			st[k] = v
		end
		return st
	end

	describe("fitList", function()
		it("joins everything with commas when it fits", function()
			assert.equal("A, B, C", W.fitList({ "A", "B", "C" }, 100))
		end)

		it("says 'and N more' instead of an ellipsis on overflow", function()
			local s = W.fitList({ "Alpha", "Bravo", "Charlie", "Delta" }, 25)
			assert.equal("Alpha, Bravo and 2 more", s)
			assert.is_nil(s:find("...", 1, true))
			assert.is_nil(s:find("\226\128\166", 1, true))
		end)

		it("always shows the first part, even over budget", function()
			assert.equal("A very long first part and 1 more", W.fitList({ "A very long first part", "B" }, 3))
		end)

		it("returns a single part as is", function()
			assert.equal("Only", W.fitList({ "Only" }, 1))
		end)

		it("returns an empty string for an empty list", function()
			assert.equal("", W.fitList({}, 50))
		end)
	end)

	describe("lines", function()
		it("folds a train and its craft into one 'Learn and craft' line", function()
			local ls = W.lines({ train(), craft() })
			assert.equal(1, #ls)
			local l = ls[1]
			assert.equal("craft", l.kind)
			assert.equal("Learn and craft 43 Copper Dagger", l.title)
			assert.equal("train", l.learn.kind)
			assert.equal(100, l.learn.cost)
			assert.same({ 1, 2 }, l.steps)
			assert.equal(2, l.step)
			assert.equal(1, l.n)
		end)

		it("titles a bought recipe 'Buy the recipe and craft'", function()
			local ls = W.lines({ recipe(), craft() })
			assert.equal("Buy the recipe and craft 43 Copper Dagger", ls[1].title)
			assert.equal("buyRecipe", ls[1].learn.kind)
			assert.equal(550, ls[1].cost)
		end)

		it("titles an owned recipe 'Learn the recipe and craft'", function()
			local ls = W.lines({ recipe({ owned = true, price = false }), craft() })
			assert.equal("Learn the recipe and craft 43 Copper Dagger", ls[1].title)
			assert.same({}, ls[1].unpriced)
		end)

		it("lists an unpriced, unowned recipe as 'the recipe'", function()
			local ls = W.lines({ recipe({ price = false }), craft() })
			assert.same({ "the recipe" }, ls[1].unpriced)
		end)

		it("does not fold a train of another spell into the craft", function()
			local ls = W.lines({ train({ spell = 7, name = "Other" }), craft() })
			assert.equal(2, #ls)
			assert.equal("unlock", ls[1].kind)
			assert.equal("Learn Other", ls[1].title)
			assert.equal(1, ls[1].step)
			assert.equal("craft", ls[2].kind)
			assert.equal("Craft 43 Copper Dagger", ls[2].title)
			assert.is_nil(ls[2].learn)
		end)

		it("keeps a train whose craft never comes as an unlock line", function()
			local ls = W.lines({ craft({ spell = 3 }), train() })
			assert.equal(2, #ls)
			assert.equal("unlock", ls[2].kind)
			assert.equal("Learn Copper Dagger", ls[2].title)
			assert.equal(100, ls[2].cost)
			assert.equal(2, ls[2].step)
		end)

		it("hangs a trainRank step on the next line instead of making a line", function()
			local ls = W.lines({
				craft({ spell = 3 }),
				{ kind = "trainRank", name = "Journeyman", skill = 50, cap = 150, cost = 500 },
				craft({ spell = 4, name = "Next" }),
			})
			assert.equal(2, #ls)
			assert.is_nil(ls[1].rank)
			assert.same({ name = "Journeyman", skill = 50, cap = 150, cost = 500, step = 2, at = 50 }, ls[2].rank)
		end)

		it("makes a gap line with a title and the reason", function()
			local ls =
				W.lines({ { kind = "gap", from = 185, to = 215, reason = "norecipe", why = "nothing teaches it" } })
			assert.equal("gap", ls[1].kind)
			assert.equal("No recipe from 185 to 215", ls[1].title)
			assert.equal("norecipe", ls[1].reason)
			assert.equal("nothing teaches it", ls[1].why)
		end)

		it("numbers lines continuously from 1", function()
			local ls = W.lines({
				train({ spell = 7, name = "Other" }),
				craft(),
				{ kind = "gap", from = 65, to = 80 },
				craft({ spell = 5 }),
			})
			assert.equal(4, #ls)
			for i, l in ipairs(ls) do
				assert.equal(i, l.n)
			end
		end)

		it("sums the cash out and the learn cost", function()
			assert.equal(150, W.lines({ train(), craft() })[1].cost)
		end)

		it("falls back to buy each times count when there is no cash", function()
			local l = W.lines({
				craft({ cash = false, buy = { { item = 1, count = 10, each = 5 }, { item = 2, count = 2, each = 3 } } }),
			})[1]
			assert.equal(56, l.cost)
		end)

		it("has no cost when nothing is priced", function()
			local l = W.lines({ craft({ cash = false, buy = { { item = 1, count = 10 } } }) })[1]
			assert.is_nil(l.cost)
		end)

		it("names unpriced items from the step or from ctx.nameOf", function()
			local l = W.lines(
				{ craft({ unpriced = { { item = 9, name = "Odd Ore", count = 2 }, { item = 11, count = 1 } } }) },
				{
					nameOf = function(item)
						return "Item#" .. item
					end,
				}
			)[1]
			assert.same({ "Odd Ore", "Item#11" }, l.unpriced)
		end)

		it("counts ways as other recipes plus shortcuts", function()
			local l = W.lines({ craft({ others = { {}, {} }, shortcuts = { {} } }) })[1]
			assert.equal(3, l.ways)
		end)

		it("builds the short title with the skill range", function()
			local l = W.lines({ craft() })[1]
			assert.equal("Craft 43 Copper Dagger, 30 to 65", l.short)
			assert.equal(30, l.from)
			assert.equal(65, l.to)
		end)

		it("rounds the expected crafts up", function()
			assert.equal(31, W.lines({ craft({ expected = 30.2 }) })[1].expected)
			assert.equal(30, W.lines({ craft({ expected = 30 }) })[1].expected)
		end)
	end)

	describe("stretches", function()
		local CAPS = {
			{ at = 75, label = "Apprentice 75" },
			{ at = 150, label = "Journeyman 150" },
			{ at = 225, label = "Expert 225" },
		}
		local function row(from, to, rank)
			return { from = from, to = to, rank = rank }
		end

		it("cuts rows at the rank caps and names stretches from the cap label", function()
			local ss = W.stretches({ row(28, 50), row(50, 75), row(75, 100), row(100, 150), row(150, 160) }, CAPS, 1, 8)
			assert.equal(3, #ss)
			assert.equal("28 to 75", ss[1].label)
			assert.equal("Apprentice", ss[1].name)
			assert.equal("75 to 150", ss[2].label)
			assert.equal("Journeyman", ss[2].name)
			assert.equal("150 to 160", ss[3].label)
			assert.equal("Expert", ss[3].name)
		end)

		it("leaves the name nil past the last cap", function()
			local ss = W.stretches({ row(230, 250) }, CAPS, 1, 8)
			assert.is_nil(ss[1].name)
		end)

		it("splits a long group into equal parts of at most max", function()
			local rows = {}
			for i = 1, 10 do
				rows[i] = row(i, i + 1)
			end
			local ss = W.stretches(rows, CAPS, 1, 4)
			assert.equal(3, #ss)
			for _, s in ipairs(ss) do
				assert.is_true(#s.rows <= 4)
			end
			assert.same({ 4, 4, 2 }, { #ss[1].rows, #ss[2].rows, #ss[3].rows })
		end)

		it("puts every row in exactly one stretch, in order", function()
			local rows = {}
			for i = 1, 40 do
				rows[i] = row(i * 5 - 4, i * 5)
			end
			local ss = W.stretches(rows, CAPS, 1, 7)
			local seen = {}
			for i, s in ipairs(ss) do
				assert.equal(i, s.index)
				assert.is_true(#s.rows >= 1 and #s.rows <= 7)
				for _, r in ipairs(s.rows) do
					seen[#seen + 1] = r
				end
			end
			assert.equal(40, #seen)
			for i = 1, 40 do
				assert.equal(rows[i], seen[i])
			end
		end)

		it("collects the rank trainings hung on its rows", function()
			local r1, r2 = { name = "Journeyman" }, { name = "Expert" }
			local ss = W.stretches({ row(28, 50), row(75, 100, r1), row(150, 170, r2) }, CAPS, 1, 8)
			assert.same({}, ss[1].ranks)
			assert.same({ r1 }, ss[2].ranks)
			assert.same({ r2 }, ss[3].ranks)
		end)

		it("marks stretches that end at or below the skill as done", function()
			local ss = W.stretches({ row(28, 75), row(75, 150), row(150, 160) }, CAPS, 75, 8)
			assert.is_true(ss[1].done)
			assert.is_false(ss[2].done)
			assert.is_false(ss[3].done)
		end)

		it("flags exactly one current stretch, the first not done", function()
			local ss, cur = W.stretches({ row(28, 75), row(75, 150), row(150, 160) }, CAPS, 75, 8)
			assert.equal(2, cur)
			local n = 0
			for i, s in ipairs(ss) do
				if s.current then
					n = n + 1
					assert.equal(cur, i)
				end
			end
			assert.equal(1, n)
		end)

		it("makes the last stretch current when all are done", function()
			local ss, cur = W.stretches({ row(28, 75), row(75, 150) }, CAPS, 300, 8)
			assert.equal(2, cur)
			assert.is_true(ss[2].current)
			assert.is_nil(ss[1].current)
		end)

		it("returns an empty list and index 0 for no rows", function()
			local ss, cur = W.stretches({}, CAPS, 1, 8)
			assert.same({}, ss)
			assert.equal(0, cur)
		end)
	end)
end)
