-- SkillupHelperDB.learned (Learned.lua): its shape, the move of the pre-0.3.0 fields into it, and that the old
-- readers in Core still answer from it.
local function load(ns, files)
	for _, f in ipairs(files) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local function core()
	local frame = setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
	_G.CreateFrame = function()
		return frame
	end
	_G.SlashCmdList = {}
	_G.C_AddOns = {
		GetAddOnMetadata = function()
			return "@project-version@"
		end,
	}
	_G.GetBuildInfo = function()
		return "1.60.1", "70938"
	end
	_G.GetLocale = function()
		return "enUS"
	end
	return load(
		{},
		{ "Logic.lua", "Learned.lua", "Planner.lua", "Scan.lua", "TSM.lua", "View.lua", "UI.lua", "Core.lua" }
	)
end

local L
before_each(function()
	_G.issecretvalue = function()
		return false
	end
	_G.GetBuildInfo = nil
	L = load({}, { "Learned.lua" }).Learned
end)

local KEYS = { "build", "colors", "locale", "npcs", "ranks", "skillups", "trainers", "vendors", "version" }

local function keysOf(t)
	local out = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	table.sort(out)
	return out
end

-- A SavedVariables table as 0.3.0 wrote it, with the private fields a real one has.
local function oldDB()
	return {
		shown = true,
		trainerReq = { [165] = { [2153] = { skill = 15, cost = 50 }, ["light armor kit"] = { skill = 1 } } },
		ranks = { [165] = { [150] = { name = "Journeyman", cap = 150, skill = 50, cost = 500, seen = 1700000000 } } },
		colorSeen = { [9999] = { o = 127, y = 131 } },
		trainerSeen = { [165] = { [2153] = true } },
		guide = {
			npcs = { [3007] = { id = 3007, name = "Una", map = 1456, x = 41.4, y = 42.6, trains = "Leatherworking" } },
			stopped = {},
			pin = { map = 1456, x = 1, y = 2 },
		},
		mailQueue = { ["Horde - Somerealm"] = { Somechar = { { to = "Otherchar", item = 2318, count = 3 } } } },
		trips = { Cooking = { rows = {}, at = "2026-11-10 10:00:00" } },
		skills = { [165] = { rank = 120 } },
	}
end

describe("Learned.attach", function()
	it("makes the table with every section and nothing else", function()
		local db = {}
		local l = L.attach(db, "1.60.1.70938", "enUS")
		assert.equal(l, db.learned)
		assert.same(KEYS, keysOf(l))
		assert.same({ 1, "1.60.1.70938", "enUS" }, { l.version, l.build, l.locale })
		for _, k in ipairs({ "trainers", "ranks", "vendors", "npcs", "colors", "skillups" }) do
			assert.same({}, l[k])
		end
		assert.is_nil(L.attach(nil))
	end)

	it("moves the pre-0.3.0 fields in and removes them, leaving the private ones where they were", function()
		local db = oldDB()
		local l = L.attach(db, "1.60.1.70938", "enUS")
		assert.same({ skill = 15, cost = 50 }, l.trainers[165][2153])
		assert.same({ skill = 1 }, l.trainers[165]["light armor kit"])
		assert.equal(500, l.ranks[165][150].cost)
		assert.same({ o = 127, y = 131 }, l.colors[9999])
		assert.equal("Una", l.npcs[3007].name)
		assert.is_nil(db.trainerReq)
		assert.is_nil(db.ranks)
		assert.is_nil(db.colorSeen)
		assert.is_nil(db.guide.npcs)
		-- not game facts: they stay outside the shared table
		assert.same(KEYS, keysOf(l))
		assert.is_table(db.mailQueue["Horde - Somerealm"].Somechar)
		assert.is_table(db.trips.Cooking)
		assert.is_table(db.trainerSeen[165])
		assert.is_table(db.skills[165])
		assert.same({ map = 1456, x = 1, y = 2 }, db.guide.pin)
	end)

	it("holds no name of a character or realm after the move", function()
		local db = oldDB()
		local l = L.attach(db, "1.60.1.70938", "enUS")
		local function walk(v, seen)
			if type(v) == "table" then
				for k, x in pairs(v) do
					walk(k, seen)
					walk(x, seen)
				end
			elseif type(v) == "string" then
				seen[#seen + 1] = v
			end
		end
		local strings = {}
		walk(l, strings)
		for _, s in ipairs(strings) do
			assert.is_nil(s:find("Somerealm", 1, true))
			assert.is_nil(s:find("Somechar", 1, true))
			assert.is_nil(s:find("Otherchar", 1, true))
		end
	end)

	it("can run twice, and keeps what the table already holds over an old field", function()
		local db = oldDB()
		L.attach(db, "1.60.1.70938")
		-- a later session wrote into learned; an old field reappears (a file edited by hand, an old backup merged)
		db.learned.trainers[165][2153] = { skill = 20, cost = 60, seenAt = "1.60.1.70938" }
		db.trainerReq =
			{ [165] = { [2153] = { skill = 15 }, [2160] = { skill = 55 } }, [171] = { [2329] = { skill = 1 } } }
		local l = L.attach(db, "1.60.1.70938")
		assert.same({ skill = 20, cost = 60, seenAt = "1.60.1.70938" }, l.trainers[165][2153])
		assert.same({ skill = 55 }, l.trainers[165][2160])
		assert.same({ skill = 1 }, l.trainers[171][2329])
		assert.is_nil(db.trainerReq)
		assert.equal(l, L.attach(db))
	end)

	it("merges an old rank row into the newer one field by field, and old colours by the colour rules", function()
		local db = oldDB()
		db.learned = {
			ranks = { [165] = { [150] = { cap = 150, skill = 55, seenAt = "1.60.1.70938" } } },
			colors = { [9999] = { o = 120, y = 135, g = 160 } },
		}
		local l = L.attach(db, "1.60.1.70938")
		-- the newer row keeps its values and its stamp, and gains what only the old row knew
		assert.same(
			{ name = "Journeyman", cap = 150, skill = 55, cost = 500, seen = 1700000000, seenAt = "1.60.1.70938" },
			l.ranks[165][150]
		)
		-- orange seen up to 127 (old), yellow from 131 (old, lower), grey from 160 (new only)
		assert.same({ o = 127, y = 131, g = 160 }, l.colors[9999])
		assert.is_nil(db.ranks)
		assert.is_nil(db.colorSeen)
	end)

	it("keeps the newest build that wrote", function()
		local db = {}
		assert.equal("1.60.1.70938", L.attach(db, "1.60.1.70938").build)
		assert.equal("1.60.1.70938", L.attach(db, "1.60.1.70888").build)
		assert.equal("1.60.2.100", L.attach(db, "1.60.2.100").build)
		assert.equal("1.60.2.100", L.attach(db, nil).build)
		assert.is_true(L.olderBuild("1.60.1.70888", "1.60.1.70938"))
		assert.is_false(L.olderBuild("1.60.1.70938", "1.60.1.70938"))
		assert.equal("1.60.1.70938", L.buildText("1.60.1", "70938"))
		assert.is_nil(L.buildText(nil, "70938"))
	end)
end)

describe("What the game teaches", function()
	local l
	before_each(function()
		l = L.attach({}, "1.60.1.70938", "enUS")
	end)

	it("keeps what a trainer asks, stamped with the build", function()
		assert.equal(2, L.noteTrainer(l, 165, { [2153] = { skill = 15, cost = 50 }, ["x"] = { cost = 9 } }, "b1"))
		assert.same({ skill = 15, cost = 50, seenAt = "b1" }, l.trainers[165][2153])
		L.noteTrainer(l, 165, { [2153] = { skill = 20, cost = 50 } }, "b2")
		assert.same({ skill = 20, cost = 50, seenAt = "b2" }, l.trainers[165][2153])
		assert.same({ cost = 9, seenAt = "b1" }, l.trainers[165].x)
	end)

	it("stamps rank rows", function()
		l.ranks[165] = { [150] = { name = "Journeyman", cap = 150 }, [225] = { name = "Expert", cap = 225 } }
		L.stampRanks(l, 165, { { cap = 150 } }, "b1")
		assert.equal("b1", l.ranks[165][150].seenAt)
		assert.is_nil(l.ranks[165][225].seenAt)
		L.stampRanks(l, 999, { { cap = 150 } }, "b1")
	end)

	it("brackets the yellow and the grey threshold from the colours seen", function()
		local c = l.colors
		assert.is_true(L.noteColor(c, 5, 120, 0, "b1")) -- orange at 120
		assert.is_false(L.noteColor(c, 5, 118, 0, "b1"))
		assert.is_true(L.noteColor(c, 5, 124, 0, "b1"))
		assert.is_true(L.noteColor(c, 5, 125, 1, "b1")) -- yellow at 125: the threshold is 125
		assert.is_true(L.noteColor(c, 5, 140, 2, "b2")) -- green: still not grey
		assert.is_true(L.noteColor(c, 5, 150, 3, "b2")) -- grey at 150
		assert.is_false(L.noteColor(c, 5, 160, 3, "b2"))
		assert.same({ o = 124, y = 125, n = 140, g = 150, seenAt = "b2" }, c[5])
		assert.is_false(L.noteColor(c, 5, nil, 0))
		assert.is_false(L.noteColor(c, "name", 1, 0))
		assert.is_false(L.noteColor(c, 6, 10, nil))
		assert.is_nil(c[6])
	end)

	it("records nothing from a secret value", function()
		_G.issecretvalue = function()
			return true
		end
		assert.is_false(L.noteColor(l.colors, 5, 120, 0, "b1"))
		assert.is_false(L.noteTry(l, 165, 5, 120, true))
		assert.same({}, l.colors)
		assert.same({}, l.skillups)
	end)

	it("never keys a table or computes with a secret id, item, skill line or position", function()
		local SECRET = setmetatable({}, {
			__tostring = function()
				return "secret"
			end,
		})
		_G.issecretvalue = function(v)
			return v == SECRET
		end
		assert.is_false(L.noteColor(l.colors, SECRET, 120, 0, "b1"))
		assert.is_false(L.noteTry(l, SECRET, 5, 120, true))
		assert.is_false(L.noteTry(l, 165, SECRET, 120, true))
		assert.is_nil(L.noteVendor(l, { id = SECRET }, { { item = 1 } }, "b1"))
		-- a secret item is left out; a secret price, stock or position is not recorded
		local v = L.noteVendor(
			l,
			{ id = 3005, map = SECRET, x = SECRET, y = 40 },
			{ { item = SECRET, price = 1 }, { item = 2320, price = SECRET, stock = SECRET } },
			"b1"
		)
		assert.same({ y = 40, seenAt = "b1", items = { [2320] = {} } }, v)
		assert.equal(0, L.noteTrainer(l, SECRET, { [1] = { skill = 1 } }, "b1"))
		assert.equal(1, L.noteTrainer(l, 165, { [SECRET] = { skill = 1 }, [2] = { skill = SECRET, cost = 5 } }, "b1"))
		assert.same({ [2] = { cost = 5, seenAt = "b1" } }, l.trainers[165])
		-- a secret skill now: not now, the crafts stay for the next scan
		assert.equal(0, L.settle(l, 165, { [2153] = { n = 2, skill = 100 } }, SECRET, 150))
		assert.same({}, l.colors)
		assert.same({}, l.skillups)
	end)

	it("keeps a vendor's list with prices and stock", function()
		local v = L.noteVendor(
			l,
			{ id = 3005, name = "Mahu", map = 1456, x = 43.82, y = 44.96 },
			{ { item = 2320, price = 10 }, { item = 5786, price = 550, stock = 1 }, { item = 8343 }, { price = 3 } },
			"b1"
		)
		assert.same({
			map = 1456,
			x = 43.8,
			y = 45,
			seenAt = "b1",
			items = { [2320] = { price = 10 }, [5786] = { price = 550, stock = 1 }, [8343] = {} },
		}, v)
		assert.equal(v, l.vendors[3005])
		assert.is_nil(L.noteVendor(l, { id = "name:Mahu" }, { { item = 1 } }, "b1"))
		assert.is_nil(L.noteVendor(l, { id = 3006 }, {}, "b1"))
		assert.is_nil(l.vendors[3006])
	end)

	it("counts tries and skill-ups in buckets of five skill points", function()
		assert.is_true(L.noteTry(l, 165, 2153, 101, true))
		L.noteTry(l, 165, 2153, 104, false)
		L.noteTry(l, 165, 2153, 105, true)
		L.noteTry(l, 633, "practice-lockbox", 12, true)
		assert.same({ [100] = { t = 2, u = 1 }, [105] = { t = 1, u = 1 } }, l.skillups[165][2153])
		assert.same({ [10] = { t = 1, u = 1 } }, l.skillups[633]["practice-lockbox"])
		assert.is_false(L.noteTry(l, 165, nil, 1, true))
	end)

	it("settles the crafts between two scans", function()
		-- five crafts from skill 100, the skill is 103 afterwards: three skill-ups in five tries
		assert.equal(5, L.settle(l, 165, { [2153] = { n = 5, skill = 100 } }, 103, 150))
		assert.same({ [100] = { t = 5, u = 3 } }, l.skillups[165][2153])
		-- two recipes at once cannot be told apart; at the rank cap a craft is no try
		assert.equal(0, L.settle(l, 165, { [1] = { n = 1, skill = 100 }, [2] = { n = 1, skill = 100 } }, 101, 150))
		assert.equal(0, L.settle(l, 165, { [7] = { n = 3, skill = 150 } }, 150, 150))
		assert.is_nil(l.skillups[165][7])
		assert.equal(0, L.settle(l, 165, {}, 101, 150))
	end)

	it("counts itself for the selftest", function()
		L.noteTrainer(l, 165, { [1] = { skill = 1 }, [2] = { skill = 2 } }, "b1")
		L.noteTry(l, 165, 2153, 101, true)
		local s = L.status(l)
		assert.same(
			{ 1, "1.60.1.70938", "enUS", 2, 0, 1 },
			{ s.version, s.build, s.locale, s.trainers, s.vendors, s.skillups }
		)
		assert.equal("SkillupHelperDB.learned absent", L.status(nil))
	end)
end)

describe("Scan with the learned table", function()
	it("gives the cost line the character's level, as the plan does (a secret level is none)", function()
		local ns = core()
		local level = 42
		_G.UnitLevel = function()
			return level
		end
		local got = {}
		ns.Scan.worldFor = function(line, _, _, lvl)
			got[#got + 1] = { line, lvl }
		end
		ns.TSM.prices = function()
			return {}, {}
		end
		ns.Planner.costToCap = function()
			return { total = 1 }
		end
		assert.is_table((ns.Scan.costOf({ items = {} }, 186, { recipes = {}, to = 300 }, nil, {})))
		assert.same({ 186, 42 }, got[1])
		_G.issecretvalue = function(v)
			return v == level
		end
		assert.is_nil(ns.Scan.level())
		_G.UnitLevel = nil
		assert.is_nil(ns.Scan.level())
	end)

	it("finds the skill line by the client's id, not by a name two entries share", function()
		local ns = core()
		local a, b = { name = "Mining" }, { name = "Mining" }
		local plan = { professions = { [186] = a, [9999] = b } }
		assert.equal(9999, ns.Scan.skillLine(plan, b, { 9999 }))
		assert.equal(186, ns.Scan.skillLine(plan, a, { nil, 186 }))
		-- no client id matches (found by name): the entry's own key, by identity
		assert.equal(9999, ns.Scan.skillLine(plan, b, {}))
		assert.is_nil(ns.Scan.skillLine(plan, { name = "Mining" }, { 186 }))
	end)

	it("applies what the trainers asked once per profession, again only after a trainer read", function()
		local ns = core()
		local db = ns.initDB(nil)
		ns.capTables(db)
		local calls = 0
		local real = ns.Logic.withTrainerReq
		ns.Logic.withTrainerReq = function(...)
			calls = calls + 1
			return real(...)
		end
		local prof = { recipes = { [5] = { name = "Belt", src = "trainer" } } }
		ns.Learned.noteTrainer(db.learned, 165, { [5] = { skill = 10 } }, "b1")
		local req = ns.savedTrainerReq(165)
		local one = ns.Scan.withTrainerReq(prof, req)
		assert.equal(one, ns.Scan.withTrainerReq(prof, req))
		assert.equal(1, calls)
		assert.equal(10, one.recipes[5].learn)
		ns.Learned.noteTrainer(db.learned, 165, { [5] = { skill = 20 } }, "b1")
		assert.equal(20, ns.Scan.withTrainerReq(prof, req).recipes[5].learn)
		assert.equal(2, calls)
	end)

	it("writes a recipe's colour through one writer, only when its skill or colour changed", function()
		local ns = core()
		local writes = 0
		local real = ns.Learned.noteColor
		ns.Learned.noteColor = function(...)
			writes = writes + 1
			return real(...)
		end
		local seen = {}
		assert.is_true(ns.Scan.noteColor(seen, 1, 127, 0))
		for _ = 1, 5 do
			assert.is_false(ns.Scan.noteColor(seen, 1, 127, 0)) -- the next refreshes: nothing new
		end
		assert.equal(1, writes)
		assert.is_true(ns.Scan.noteColor(seen, 1, 131, 1))
		assert.same({ o = 127, y = 131, n = 131 }, { o = seen[1].o, y = seen[1].y, n = seen[1].n })
		assert.equal(2, writes)
		assert.is_false(ns.Scan.noteColor(seen, 1, 131, nil))
	end)
end)

describe("Core after the move", function()
	it("answers the old readers from the learned table", function()
		local ns = core()
		local db = ns.initDB(oldDB())
		ns.capTables(db)
		assert.equal(db.learned, ns.learned())
		assert.same({ "1.60.1.70938", "enUS" }, { db.learned.build, db.learned.locale })
		assert.equal(500, ns.savedRanks(165)[150].cost)
		assert.equal(15, ns.savedTrainerReq(165)[2153].skill)
		assert.same({ o = 127, y = 131 }, ns.savedColorSeen()[9999])
		assert.equal(1, ns.ranksSeen())
		assert.is_nil(ns.savedRanks(171))
		-- the planner's settings are untouched
		assert.is_table(db.exclude.notNow)
		assert.is_true(db.trainerSeen[165][2153])
		assert.is_nil(db.ranks)
	end)

	it("starts empty on a fresh install", function()
		local ns = core()
		local db = ns.initDB(nil)
		ns.capTables(db)
		assert.same({}, db.learned.trainers)
		assert.equal(0, ns.ranksSeen())
		assert.same({}, ns.savedColorSeen())
	end)

	it("annotates a copy of the data layers' report for the selftest, never the shared report", function()
		local ns = core()
		local layers = { plan = "absent (optional)" }
		local out =
			ns.selftest.dataReport(layers, { build = "1.60.1.70938", source = "Wowhead, Forever" }, "1.60.1", "71000")
		assert.same({ plan = "absent (optional)" }, layers)
		assert.equal("absent (optional)", out.plan)
		assert.equal("Wowhead, Forever", out.overlayRetrieved)
		assert.is_true(out.gameIsNewer)
		assert.is_string(out.status)
		assert.is_nil(ns.selftest.dataReport(nil))
	end)

	it("counts crafts of a client-only recipe, and settles them with the panel hidden", function()
		local now = 100
		_G.GetTime = function()
			return now
		end
		_G.C_Timer = {
			After = function(_, fn)
				fn()
			end,
		}
		local skill = 100
		_G.C_TradeSkillUI = {
			GetBaseProfessionInfo = function()
				return { professionID = 165, skillLevel = skill, maxSkillLevel = 150 }
			end,
		}
		local ns = core()
		local db = ns.initDB(nil)
		ns.capTables(db)
		ns.tradeSkillOpen = true
		-- a scan: recipe 999 is learned but not in the data (no plan entry at all)
		ns.craftCounter.settle({ professionID = 165, skill = 100, maxSkill = 150, learned = { [999] = true } })
		ns.craftCounter.cast(999)
		ns.craftCounter.cast(999)
		ns.craftCounter.cast(12345) -- not a recipe of this window
		assert.equal(2, ns.craftCounter.pending()[999].n)
		-- the panel is hidden (no frame): the refresh settles from the client's skill once SETTLE has passed
		skill, now = 101, 102
		ns.refresh()
		assert.same({ [100] = { t = 2, u = 1 } }, db.learned.skillups[165] and db.learned.skillups[165][999])
		assert.is_nil(next(ns.craftCounter.pending()))
		-- a failed scan (no profession) neither settles nor drops what is pending
		ns.craftCounter.cast(999)
		ns.craftCounter.settle({ why = "scan failed" })
		assert.equal(1, ns.craftCounter.pending()[999].n)
		_G.C_Timer, _G.C_TradeSkillUI, _G.GetTime = nil, nil, nil
	end)

	it("answers nil, not an error, when a section of the learned table is missing", function()
		local ns = core()
		local db = ns.initDB(nil)
		ns.capTables(db)
		db.learned.trainers, db.learned.ranks = nil, nil
		assert.is_nil(ns.savedTrainerReq(165))
		assert.is_nil(ns.savedRanks(165))
		assert.equal(0, ns.ranksSeen())
	end)
end)
