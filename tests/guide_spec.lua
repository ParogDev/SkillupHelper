-- Guide.lua: which NPC serves the step to do now, the nearest one, distance and direction.
local function load()
	local ns = {}
	assert(loadfile("Guide.lua"))("SkillupHelper", ns)
	return ns.Guide
end

local THREAD, SALT, DYE, LEATHER = 2321, 4289, 4340, 2318

-- A flat test world: maps 1 and 2 on continent 1414 (map 2 offset 1000 yards north), map 9 on 1415.
-- Percent to yards: 1 percent = 10 yards; map x grows east (world y shrinks), map y grows south (world x shrinks).
local OFFSET = { [1] = { 1414, 0 }, [2] = { 1414, 1000 }, [9] = { 1415, 0 } }
local function world(map, x, y)
	local o = OFFSET[map]
	if not o then
		return nil
	end
	return o[1], o[2] - y * 10, -x * 10
end

local function here(map, x, y)
	local c, wx, wy = world(map, x, y)
	return { continent = c, x = wx, y = wy }
end

describe("Guide", function()
	local G
	before_each(function()
		G = load()
	end)

	it("reads the npc id from a creature GUID and nothing from a player's", function()
		assert.equal(3005, G.npcId("Creature-0-4372-1-5-3005-000012ABCD"))
		assert.is_nil(G.npcId("Player-4372-0ABC1234"))
		assert.is_nil(G.npcId("Pet-0-1-2-3-3005-0000"))
		assert.is_nil(G.npcId(nil))
	end)

	it("turns a step into the visits it needs", function()
		local craft = {
			kind = "craft",
			buy = {
				{ item = THREAD, count = 5, where = "vendor" },
				{ item = LEATHER, count = 10, where = "ah" },
			},
		}
		local n = G.needsOf(craft, "Leatherworking")
		assert.equal(2, #n)
		assert.same({ "vendor", THREAD, 5 }, { n[1].kind, n[1].items[1].item, n[1].items[1].count })
		assert.same({ "auction", LEATHER }, { n[2].kind, n[2].items[1].item })
		local t = G.needsOf({ kind = "train", name = "Hillman's Shoulders", at = 130 }, "Leatherworking")
		assert.same({ "trainer", "Leatherworking", 130 }, { t[1].kind, t[1].profession, t[1].at })
		assert.equal("auction", G.needsOf({ kind = "buyRecipe", item = 7 }, "Cooking")[1].kind)
		assert.same({}, G.needsOf({ kind = "craft", used = {} }, "Cooking"))
		assert.same({}, G.needsOf(nil, "Cooking"))
	end)

	it("drops a need once the bags hold enough", function()
		local needs = { { kind = "vendor", items = { { item = THREAD, count = 5 } } }, { kind = "trainer" } }
		local have = { [THREAD] = 5 }
		local left = G.pending(needs, function(i)
			return have[i]
		end)
		assert.equal(1, #left)
		assert.equal("trainer", left[1].kind)
		have[THREAD] = 4
		assert.equal(2, #G.pending(needs, function(i)
			return have[i]
		end))
	end)

	it("picks the nearest vendor that sells everything over a nearer one that sells part", function()
		local npcs = G.seedRecords({
			{ id = 1, name = "Near Partial", map = 1, x = 50, y = 50, role = "trade", sells = { THREAD } },
			{ id = 2, name = "Far Full", map = 1, x = 80, y = 50, role = "trade", sells = { THREAD, SALT } },
			{ id = 3, name = "Farther Full", map = 1, x = 90, y = 50, role = "trade", sells = { THREAD, SALT } },
			{ id = 4, name = "Trainer", map = 1, x = 51, y = 50, role = "lwtrainer" },
		})
		local need = { kind = "vendor", items = { { item = THREAD, count = 1 }, { item = SALT, count = 1 } } }
		local pick, servers = G.nearest(npcs, need, here(1, 50, 50), world)
		assert.equal(3, servers)
		assert.equal(2, pick.npc.id)
		assert.near(300, pick.distance, 1e-6)
		assert.is_false(pick.partial)
		assert.equal("east", G.compass(pick.bearing))
	end)

	it("falls back to a partial vendor and says so", function()
		local npcs = G.seedRecords({ { id = 1, name = "A", map = 1, x = 50, y = 60, sells = { THREAD } } })
		local need = { kind = "vendor", items = { { item = THREAD, count = 1 }, { item = DYE, count = 1 } } }
		local pick = G.nearest(npcs, need, here(1, 50, 50), world)
		assert.is_true(pick.partial)
		assert.equal("south", G.compass(pick.bearing))
		assert.near(100, pick.distance, 1e-6)
	end)

	it("measures across maps of one continent and puts other continents last", function()
		local npcs = G.seedRecords({
			{ id = 10, name = "Other continent", map = 9, x = 50, y = 50, role = "lwtrainer" },
			{ id = 11, name = "Next zone north", map = 2, x = 50, y = 50, role = "lwtrainer" },
		})
		local need = { kind = "trainer", profession = "Leatherworking" }
		local pick = G.nearest(npcs, need, here(1, 50, 50), world)
		assert.equal(11, pick.npc.id)
		assert.near(1000, pick.distance, 1e-6)
		assert.equal("north", G.compass(pick.bearing))
		-- only the other continent left: chosen, but without a distance
		local only = G.nearest({ npcs[1] }, need, here(1, 50, 50), world)
		assert.equal(10, only.npc.id)
		assert.is_nil(only.distance)
		assert.is_false(only.sameContinent)
		assert.equal("away", G.phase(only))
	end)

	it("has no distance without a player position (an instance) and none for unknown maps", function()
		local npcs = G.seedRecords({ { id = 1, name = "A", map = 77, x = 1, y = 1, role = "auction" } })
		local pick = G.nearest(npcs, { kind = "auction" }, nil, world)
		assert.equal(1, pick.npc.id)
		assert.is_nil(pick.distance)
		local none, servers = G.nearest(npcs, { kind = "trainer", profession = "Cooking" }, here(1, 0, 0), world)
		assert.is_nil(none)
		assert.equal(0, servers)
		assert.equal("none", G.phase(none))
	end)

	it("matches a trainer by profession name either way round", function()
		local t = { trains = "Leatherworking" }
		assert.equal(1, G.serves(t, { kind = "trainer", profession = "Leatherworking" }))
		assert.equal(1, G.serves(t, { kind = "trainer", profession = "Classic Leatherworking" }))
		assert.equal(0, G.serves(t, { kind = "trainer", profession = "Cooking" }))
		assert.equal(0, G.serves({}, { kind = "trainer", profession = "Cooking" }))
		-- an empty or partial name matches nothing
		assert.equal(0, G.serves({ trains = "" }, { kind = "trainer", profession = "Cooking" }))
		assert.equal(0, G.serves({ trains = "Cooking" }, { kind = "trainer", profession = "" }))
		assert.equal(0, G.serves({ trains = "Leather" }, { kind = "trainer", profession = "Leatherworking" }))
	end)

	describe("which trainer teaches a named recipe", function()
		local TEA = "Goldthorn Tea"
		local need = { kind = "trainer", profession = "Cooking", name = TEA }

		it("ranks a trainer known to teach it over a nearer one that only may", function()
			local npcs = G.seedRecords({
				{ id = 1, name = "Zamja", map = 1, x = 51, y = 50, role = "cooktrainer" },
				{ id = 2, name = "Far Cook", map = 1, x = 90, y = 50, role = "cooktrainer" },
			})
			local learned = {}
			G.learn(learned, { id = 2, name = "Far Cook", map = 1, x = 90, y = 50, teaches = { " goldthorn TEA " } }, 1)
			local all = G.known(npcs, learned)
			local pick = G.nearest(all, need, here(1, 50, 50), world)
			assert.equal(2, pick.npc.id)
			assert.is_true(pick.certain)
			-- without the learned list both may: the nearer one, not certain
			local maybe = G.nearest(npcs, need, here(1, 50, 50), world)
			assert.equal(1, maybe.npc.id)
			assert.is_false(maybe.certain)
		end)

		it("leaves out a trainer whose full list lacks it and keeps one read in part", function()
			local learned = {}
			G.learn(learned, { id = 1, name = "Zamja", map = 1, x = 51, y = 50, teaches = { "Spiced Wolf Meat" } }, 1)
			G.learn(learned, {
				id = 2,
				name = "Partial",
				map = 1,
				x = 90,
				y = 50,
				teaches = { "Spiced Wolf Meat" },
				teachesPartial = true,
			}, 1)
			local seeds = G.seedRecords({
				{ id = 1, name = "Zamja", map = 1, x = 51, y = 50, role = "cooktrainer" },
				{ id = 2, name = "Partial", map = 1, x = 90, y = 50, role = "cooktrainer" },
			})
			local all = G.known(seeds, learned)
			local pick, servers, excluded = G.nearest(all, need, here(1, 50, 50), world)
			assert.equal(2, pick.npc.id)
			assert.is_false(pick.certain)
			assert.same({ 1, 1 }, { servers, excluded })
			-- the partial one read in full later, still without it: nobody left
			G.learn(learned, { id = 2, name = "Partial", map = 1, x = 90, y = 50, teaches = { "Herb Baked Egg" } }, 2)
			local none, n, ex = G.nearest(G.known(seeds, learned), need, here(1, 50, 50), world)
			assert.is_nil(none)
			assert.same({ 0, 2 }, { n, ex })
			-- a need without a name still goes to any trainer of the profession
			local any = G.nearest(G.known(seeds, learned), { kind = "trainer", profession = "Cooking" }, nil, world)
			assert.is_true(any.certain)
		end)

		it("replaces the service list on each visit and keeps the trainer line", function()
			local learned = {}
			G.learn(learned, { id = 3, map = 1, x = 1, y = 1, trains = "Cooking", teaches = { "A", "B" } }, 1)
			G.learn(learned, { id = 3, map = 1, x = 1, y = 1, teaches = { "C" }, teachesPartial = true }, 2)
			assert.same({ c = true }, learned[3].teaches)
			assert.is_true(learned[3].teachesPartial)
			assert.equal("Cooking", learned[3].trains)
			G.learn(learned, { id = 3, map = 1, x = 1, y = 1, teaches = { "D" } }, 3)
			assert.is_nil(learned[3].teachesPartial)
			-- a vendor visit leaves the trainer's list alone
			G.learn(learned, { id = 3, map = 1, x = 1, y = 1, sells = { THREAD } }, 4)
			assert.same({ d = true }, learned[3].teaches)
		end)

		it("takes a trainer's list once it has filled: SHOW empty, then UPDATE full, never a smaller read", function()
			local learned, visit = {}, nil
			local function read(names, partial, n, at)
				local teaches, tp, why
				teaches, tp, visit, why = G.trainerRead(visit, 7, names, partial, n)
				G.learn(learned, { id = 7, map = 1, x = 1, y = 1, teaches = teaches, teachesPartial = tp }, at)
				return why
			end
			-- TRAINER_SHOW: the list has not filled yet
			assert.matches("^not yet", read({}, true, 0, 1))
			assert.is_nil(learned[7].teaches)
			-- TRAINER_UPDATE: the whole list
			assert.is_nil(read({ "A", "B", "C" }, false, 3, 2))
			assert.same({ a = true, b = true, c = true }, learned[7].teaches)
			assert.is_nil(learned[7].teachesPartial)
			-- a later update of the same visit that reads less is held back
			assert.matches("fuller list", read({ "A" }, true, 1, 3))
			assert.same({ a = true, b = true, c = true }, learned[7].teaches)
			-- a new visit (another trainer, or the window reopened: visit reset) reads afresh
			visit = nil
			assert.is_nil(read({ "D" }, false, 1, 4))
			assert.same({ d = true }, learned[7].teaches)
		end)

		it("repairs an empty partial list saved by a read made before the list filled", function()
			local learned = { [8] = { id = 8, map = 1, x = 1, y = 1, teaches = {}, teachesPartial = true } }
			local teaches, tp = G.trainerRead(nil, 8, {}, true, 0)
			G.learn(learned, { id = 8, map = 1, x = 1, y = 1, teaches = teaches, teachesPartial = tp }, 2)
			assert.is_nil(learned[8].teaches)
			assert.is_nil(learned[8].teachesPartial)
			-- a real list read in part stays as it is
			learned[9] = { id = 9, map = 1, x = 1, y = 1, teaches = { a = true }, teachesPartial = true }
			G.learn(learned, { id = 9, map = 1, x = 1, y = 1 }, 2)
			assert.same({ a = true }, learned[9].teaches)
			assert.is_true(learned[9].teachesPartial)
		end)

		it("finds a rank-up listed with the rank before the profession", function()
			local t = { trains = "Cooking", teaches = G.teachesSet({ "Expert Cooking" }) }
			assert.equal(2, G.serves(t, { kind = "trainer", profession = "Cooking", name = "Expert" }))
			assert.equal(2, G.serves(t, { kind = "trainer", profession = "Cooking", name = "Expert Cooking" }))
			assert.equal(0, G.serves(t, { kind = "trainer", profession = "Cooking", name = "Artisan" }))
		end)

		it("reads a train-rank step's name, falling back to its rank", function()
			local r = G.needsOf({ kind = "trainRank", rank = "Expert", at = 125 }, "Cooking")
			assert.same({ "trainer", "Cooking", "Expert", 125 }, { r[1].kind, r[1].profession, r[1].name, r[1].at })
			local n = G.needsOf({ kind = "trainRank", name = "Expert Cooking", rank = "Expert" }, "Cooking")
			assert.equal("Expert Cooking", n[1].name)
			assert.equal(TEA, G.needsOf({ kind = "train", name = TEA, at = 215 }, "Cooking")[1].name)
		end)

		it("says a trainer only may teach it, and when no trainer opened does", function()
			local far = G.describe({ phase = "far", need = need, name = "Zamja", distance = 140, certain = false })
			assert.equal("May teach Goldthorn Tea: not checked yet", far.l2)
			assert.equal("Target Zamja (when in sight)", far.action)
			local near = G.describe({ phase = "near", need = need, name = "Zamja", distance = 40, certain = false })
			assert.same({ "May teach Goldthorn Tea: not checked yet", "arrow" }, { near.l2, near.icon })
			local sure =
				G.describe({ phase = "far", need = need, name = "Zamja", certain = true, profession = "Cooking" })
			assert.equal("Cooking trainer", sure.l2)
			assert.equal("Learn Goldthorn Tea here", G.describe({ phase = "here", need = need, certain = true }).l2)
			assert.equal(
				"Look for Goldthorn Tea in the list",
				G.describe({ phase = "here", need = need, certain = false }).l2
			)
			local none = G.describe({ phase = "unknown", need = need, excluded = 2 })
			assert.same({ "No trainer found", "None you've opened teaches Goldthorn Tea" }, { none.l1, none.l2 })
			assert.equal("No known trainer yet", G.describe({ phase = "unknown", need = need, excluded = 0 }).l1)
			assert.equal(
				"No trainer you've opened teaches Goldthorn Tea. It may come from a special NPC or a recipe item.",
				G.unknownText(need, nil, 2)
			)
			assert.truthy(G.unknownText(need, nil, 0):find("No Cooking trainer known yet", 1, true))
		end)
	end)

	it("merges a learned NPC over its seed: role and place kept, sells joined", function()
		local seeds = G.seedRecords({
			{
				id = 8,
				name = "Seed",
				map = 1,
				x = 1,
				y = 1,
				role = "cooktrainer",
				place = "Orgrimmar",
				sells = { SALT },
			},
		})
		local learned = {}
		G.learn(learned, { id = 8, name = "Learned", map = 1, x = 2, y = 2, sells = { THREAD } }, 1)
		local m = G.known(seeds, learned)[1]
		assert.same({ "Learned", 2, "Cooking", "Orgrimmar" }, { m.name, m.x, m.trains, m.place })
		assert.is_true(m.sells[SALT] and m.sells[THREAD])
		assert.is_nil(m.seed)
		-- the saved record is not changed by the merge
		assert.is_nil(learned[8].trains)
		assert.is_nil(learned[8].sells[SALT])
	end)

	it("goes far, near, arrived, targeted, here", function()
		assert.equal("far", G.phase({ distance = 200 }))
		assert.equal("near", G.phase({ distance = G.NEAR }))
		assert.equal("arrived", G.phase({ distance = 5 }))
		assert.equal("targeted", G.phase({ distance = 30 }, false, true))
		assert.equal("here", G.phase({ distance = 30 }, true, true))
	end)

	it("turns the arrow by the player's facing", function()
		-- target due west (bearing pi/2); facing west: straight ahead; facing north: a quarter turn left
		assert.near(0, G.arrowAngle(math.pi / 2, math.pi / 2), 1e-9)
		assert.near(math.pi / 2, G.arrowAngle(math.pi / 2, 0), 1e-9)
		assert.near(3 * math.pi / 2, G.arrowAngle(0, math.pi / 2), 1e-9)
	end)

	it("rounds the distance so it does not flicker", function()
		assert.equal("35 yd", G.distanceText(33))
		assert.equal("420 yd", G.distanceText(417))
		assert.equal("1.5k yd", G.distanceText(1500))
		assert.is_nil(G.distanceText(nil))
	end)

	it("learns a vendor, keeps what an earlier visit saw and overrides the seed", function()
		local learned = {}
		G.learn(learned, { id = 5, name = "Vendor", map = 1, x = 12.345, y = 67.891, sells = { THREAD } }, 100)
		G.learn(learned, { id = 5, name = "Vendor", map = 1, x = 12.4, y = 67.9, sells = { SALT } }, 200)
		local v = learned[5]
		assert.same({ 12.4, 67.9, 200 }, { v.x, v.y, v.seen })
		assert.is_true(v.sells[THREAD] and v.sells[SALT])
		assert.is_nil(G.learn(learned, { id = 6, name = "No position" }, 1))
		local seeds = G.seedRecords({ { id = 5, name = "Vendor", map = 1, x = 1, y = 1, role = "trade" } })
		local all = G.known(seeds, learned)
		assert.equal(1, #all)
		assert.is_nil(all[1].seed)
		assert.equal(12.4, all[1].x)
	end)

	it("names the need and says honestly when no NPC is known", function()
		local nameOf = function(i)
			return ({ [THREAD] = "Fine Thread", [SALT] = "Salt", [DYE] = "Gray Dye" })[i] or "?"
		end
		local need = {
			kind = "vendor",
			items = { { item = THREAD, count = 1 }, { item = SALT, count = 1 }, { item = DYE, count = 1 } },
		}
		assert.equal("Fine Thread, Salt, 1 more", G.needLabel(need, nameOf))
		assert.truthy(G.unknownText(need, nameOf):find("No known vendor for Fine Thread", 1, true))
		assert.truthy(G.unknownText({ kind = "trainer", profession = "Cooking" }, nameOf):find("Cooking trainer"))
	end)

	it("holds near out to G.FAR so the chip does not flicker at the edge", function()
		assert.equal("far", G.phase({ distance = 70 }))
		assert.equal("near", G.phase({ distance = 70 }, false, false, "near"))
		assert.equal("near", G.phase({ distance = 70 }, false, false, "targeted"))
		assert.equal("far", G.phase({ distance = G.FAR + 1 }, false, false, "near"))
		assert.equal("far", G.phase({ distance = 70 }, false, false, "far"))
	end)

	it("picks between a learned name-keyed NPC and a seed at the same spot without an error", function()
		local npcs = G.seedRecords({ { id = 7, name = "Seed", map = 1, x = 50, y = 50, role = "auction" } })
		npcs[2] = { id = "name:Learned", name = "Learned", map = 1, x = 50, y = 50, auction = true }
		local pick, servers = G.nearest(npcs, { kind = "auction" }, here(1, 40, 50), world)
		assert.equal(2, servers)
		assert.equal(7, pick.npc.id)
	end)

	it("keys a step, finds the most common trainer line and builds the Target macro", function()
		assert.equal("craft:3:", G.stepKey({ kind = "craft", spell = 3 }))
		assert.equal("train:130:", G.stepKey({ kind = "train", from = 130 }))
		assert.is_nil(G.stepKey(nil))
		assert.equal("Cooking", G.mostCommon({ "Cooking", nil, "Riding", "Cooking" }))
		assert.is_nil(G.mostCommon({}))
		assert.equal("/targetexact Tamar\n/tm !1", G.macro("Tamar", true))
		assert.equal("/targetexact Tamar", G.macro("Tamar", false))
		assert.is_nil(G.macro("", true))
	end)

	it("writes the chip's copy for every state", function()
		local vendor = { kind = "vendor", items = { { item = THREAD, count = 1 } } }
		local base = { need = vendor, name = "Tamar", place = "Orgrimmar", thing = "Fine Thread", color = "yellow" }
		local function with(t)
			local s = {}
			for k, v in pairs(base) do
				s[k] = v
			end
			for k, v in pairs(t) do
				s[k] = v
			end
			return G.describe(s)
		end
		local far = with({ phase = "far", distance = 140 })
		assert.same({ "Tamar", "140 yd", "Sells Fine Thread, Orgrimmar" }, { far.l1, far.r1, far.l2 })
		assert.same(
			{ "Target Tamar (when in sight)", "quiet", "arrow", "bone" },
			{ far.action, far.style, far.icon, far.tint }
		)
		local near = with({ phase = "near", distance = 42 })
		assert.same({ "primary", "yellow", "Target Tamar" }, { near.style, near.tint, near.action })
		local blind = with({ phase = "far", distance = 140, compass = "west" })
		assert.same({ "140 yd west", nil }, { blind.r1, blind.icon })
		local away = with({ phase = "away", place = false })
		assert.equal("Sells Fine Thread, another continent", away.l2)
		assert.equal("star", with({ phase = "targeted", marked = true }).icon)
		local atVendor = with({ phase = "here" })
		assert.same(
			{ "You are here", "Buy Fine Thread from this window", nil },
			{ atVendor.l1, atVendor.l2, atVendor.action }
		)
		local trainer = { kind = "trainer", profession = "Cooking" }
		assert.equal("Trained", with({ phase = "done", need = trainer, profession = "Cooking" }).l1)
		local unknown = with({ phase = "unknown", need = trainer, profession = "Cooking", why = "no seed" })
		assert.same({ "No known trainer yet", "no seed" }, { unknown.l1, unknown.why })
		assert.equal("No directions in here", with({ phase = "notnow" }).l1)
		assert.is_nil(with({ phase = "none" }))
	end)
end)

describe("Guide over the shipped Data/Trainers.lua", function()
	local ns = {}
	assert(loadfile("Guide.lua"))("SkillupHelper", ns)
	assert(loadfile("Data/Trainers.lua"))("SkillupHelper", ns)
	local G, ROWS = ns.Guide, ns.Data.trainers

	-- Real uiMap ids: Kalimdor's zones on continent 1, the others on 0; every map its own 1000 yd square, 100000 yd
	-- from the next, so "the same map" is always nearer than another one.
	local KALIMDOR = { [1411] = 1, [1412] = 1, [1413] = 1, [1454] = 1, [1456] = 1, [1457] = 1 }
	local function realWorld(map, x, y)
		if type(map) ~= "number" or type(x) ~= "number" then
			return nil
		end
		local cont = (KALIMDOR[map] or (map >= 1438 and map <= 1452)) and 1 or 0
		return cont, map * 1e5 - y * 10, -x * 10
	end
	local function at(map, x, y)
		local c, wx, wy = realWorld(map, x, y)
		return { continent = c, x = wx, y = wy }
	end
	local function knownFor(faction, learned, seeds)
		local shipped, foreign = G.shippedRecords(ROWS, faction)
		return G.known(seeds or {}, learned or {}, shipped, foreign)
	end

	local PROFESSIONS = {
		"Alchemy",
		"Blacksmithing",
		"Cooking",
		"Enchanting",
		"Engineering",
		"First Aid",
		"Fishing",
		"Herbalism",
		"Leatherworking",
		"Mining",
		"Skinning",
		"Tailoring",
	}

	it("resolves a trainer need for every profession and both factions, with a position", function()
		local missing = {}
		for _, faction in ipairs({ "Horde", "Alliance" }) do
			local all = knownFor(faction)
			for _, p in ipairs(PROFESSIONS) do
				local list, stats = G.ranked(all, { kind = "trainer", profession = p }, nil, realWorld)
				if #list == 0 or list[1].nopos then
					missing[#missing + 1] = ("%s/%s"):format(p, faction)
				end
				assert.equal(#list, stats.servers)
				assert.equal(stats.servers, stats.bySource.shipped)
				for _, pick in ipairs(list) do
					assert.equal("shipped", pick.source)
					assert.is_true(pick.npc.id ~= nil and type(pick.name) == "string")
				end
			end
		end
		assert.same({}, missing)
	end)

	it("resolves the top rank-up of every profession to a trainer of that rank or one without a rank", function()
		local missing = {}
		for _, faction in ipairs({ "Horde", "Alliance" }) do
			local all = knownFor(faction)
			for _, p in ipairs(PROFESSIONS) do
				local need = { kind = "trainer", profession = p, name = "Artisan", cap = 300 }
				local list = G.ranked(all, need, nil, realWorld)
				if #list == 0 then
					missing[#missing + 1] = ("%s/%s"):format(p, faction)
				end
				for _, pick in ipairs(list) do
					local cap = G.RANK_CAP[pick.npc.rank or ""]
					assert.is_true(cap == nil or cap >= 300)
					assert.is_false(pick.certain)
				end
			end
		end
		assert.same({}, missing)
	end)

	it("keeps the other faction's trainers out, and neutral ones in", function()
		local horde = knownFor("Horde")
		local ids = {}
		for _, npc in ipairs(horde) do
			ids[npc.id] = npc
		end
		assert.is_nil(ids[1215]) -- Alchemist Mallory, Alliance
		assert.equal("Alchemy", ids[1386].trains) -- Rogvar, Horde
		assert.equal("Alchemy", ids[2837].trains) -- Jaxin Chong, both
		-- a Data/Npcs.lua seed of the other side is dropped with it; with no faction every side is kept
		local seeds =
			G.seedRecords({ { id = 3399, name = "Zamja", map = 1454, x = 57.4, y = 53.4, role = "cooktrainer" } })
		local alliance = knownFor("A", nil, seeds)
		for _, npc in ipairs(alliance) do
			assert.is_true(npc.id ~= 3399)
		end
		local shipped, foreign = G.shippedRecords(ROWS, nil)
		assert.is_nil(next(foreign))
		assert.is_true(#shipped > #horde)
	end)

	it("picks the nearest first: the same map by distance, then the continent, then the rest", function()
		local need = { kind = "trainer", profession = "Blacksmithing" }
		-- at the Orgrimmar forge: Borgosh Corebender (79.4, 23.7) is a step away
		local list = G.ranked(knownFor("Horde"), need, at(1454, 79.4, 24), realWorld)
		assert.equal("Borgosh Corebender", list[1].name)
		assert.near(3, list[1].distance, 1e-6)
		assert.same(
			{ "Orgrimmar", "shipped", "classic", "Position from Classic, unconfirmed" },
			{ list[1].zone, list[1].source, list[1].confidence, list[1].note }
		)
		local nearest = G.nearest(knownFor("Horde"), need, at(1454, 79.4, 24), realWorld)
		assert.equal(list[1].npc.id, nearest.npc.id)
		local tier, last = 0, -1
		for _, pick in ipairs(list) do
			local t = pick.nopos and 2 or (pick.sameContinent and 0 or 1)
			assert.is_true(t >= tier)
			if t > tier then
				tier, last = t, -1
			end
			if t == 0 then
				assert.is_true(pick.distance >= last)
				last = pick.distance
			else
				assert.is_nil(pick.distance)
			end
		end
		assert.equal(2, tier)
		-- every Orgrimmar trainer comes before the Thunder Bluff and Crossroads ones
		local seenOther = false
		for _, pick in ipairs(list) do
			if pick.npc.map == 1454 then
				assert.is_false(seenOther)
			else
				seenOther = true
			end
		end
	end)

	it("leaves a trainer of a lower rank out of a higher rank-up", function()
		local dwukk = { trains = "Blacksmithing", rank = "journeyman" }
		local expert = { kind = "trainer", profession = "Blacksmithing", name = "Expert", cap = 225 }
		assert.same({ 0, "rank" }, { G.serves(dwukk, expert) })
		assert.equal(1, (G.serves({ trains = "Blacksmithing", rank = "expert" }, expert)))
		assert.equal(1, (G.serves({ trains = "Blacksmithing", rank = "master" }, expert)))
		assert.equal(1, (G.serves({ trains = "Blacksmithing" }, expert)))
		-- a recipe learned at skill 200 needs an Artisan trainer, one at 125 an Expert; one at 124 a Journeyman teaches
		local recipe = { kind = "trainer", profession = "Blacksmithing", name = "Golden Scale Coif", at = 200 }
		assert.equal(0, (G.serves(dwukk, recipe)))
		recipe.at = 125
		assert.equal(0, (G.serves(dwukk, recipe)))
		recipe.at = 124
		assert.equal(1, (G.serves(dwukk, recipe)))
		assert.equal(0, (G.serves({ trains = "Blacksmithing", rank = "apprentice" }, expert)))
		-- an opened trainer's own list wins over its title
		local opened = { trains = "Blacksmithing", rank = "journeyman", teaches = G.teachesSet({ "Expert" }) }
		assert.equal(2, (G.serves(opened, expert)))
		-- in Durotar the Journeyman next door is passed over for Orgrimmar's Expert
		local need = G.needsOf({ kind = "trainRank", name = "Expert", cap = 225, at = 125 }, "Blacksmithing")[1]
		assert.equal(225, need.cap)
		local pick, _, excluded, stats = G.nearest(knownFor("Horde"), need, at(1411, 52, 40.7), realWorld)
		assert.is_true(pick.npc.rank ~= "journeyman")
		assert.equal(0, excluded)
		assert.is_true(stats.belowRank >= 5)
		assert.is_nil(G.needsOf({ kind = "train", name = "X", at = 10, cap = 75 }, "Cooking")[1].cap)
	end)

	describe("trainer tiers", function()
		local LW = "Leatherworking"
		local hillman = { kind = "trainer", profession = LW, name = "Hillman's Shoulders", at = 130 }
		local function undercity(learned)
			local list = {}
			for _, npc in ipairs(knownFor("Horde", learned)) do
				if npc.id == 223 or npc.id == 4588 then
					list[#list + 1] = npc
				end
			end
			return list
		end

		it("names the rank a recipe or rank-up needs, never one past the top", function()
			local function rankAt(n)
				return G.needRank({ kind = "trainer", at = n })
			end
			assert.same(
				{ "Apprentice", "Journeyman", "Journeyman", "Expert", "Expert", "Artisan", "Artisan", "Artisan" },
				{
					rankAt(0),
					rankAt(50),
					rankAt(124),
					rankAt(125),
					rankAt(199),
					rankAt(200),
					rankAt(274),
					rankAt(290),
				}
			)
			assert.equal("Expert", G.needRank({ kind = "trainer", name = "Expert", cap = 225 }))
			assert.is_nil(G.needRank({ kind = "trainer" }))
			-- a recipe learned at 290 is still taught by an Artisan (or Master) trainer
			assert.is_true(G.rankReaches({ rank = "artisan" }, { at = 290 }))
			assert.is_true(G.rankReaches({ rank = "master" }, { at = 290 }))
			assert.is_false(G.rankReaches({ rank = "expert" }, { at = 200 }))
		end)

		it("sends Hillman's Shoulders (learned at 130) to Arthur Moore, not Dan Golthas", function()
			local list = undercity()
			assert.equal(2, #list)
			local dan, arthur
			for _, npc in ipairs(list) do
				if npc.id == 223 then
					dan = npc
				else
					arthur = npc
				end
			end
			-- the rank ladder under test, not the shipped ranks: wow-professions.com lists both Undercity trainers as
			-- Journeyman in Forever (Data/Trainers.lua site rows), Classic had Arthur Moore as Expert
			dan.rank, arthur.rank = "journeyman", "expert"
			assert.same({ 0, "rank" }, { G.serves(dan, hillman) })
			assert.equal(1, (G.serves(arthur, hillman)))
			-- standing next to Dan Golthas
			local pick, servers, excluded, stats = G.nearest(list, hillman, at(1458, dan.x, dan.y), realWorld)
			assert.equal("Arthur Moore", pick.name)
			assert.same({ 1, 0, 1 }, { servers, excluded, stats.belowRank })
		end)

		it("applies the rank to a list read in part, and a whole list with the name wins over it", function()
			local partial = { trains = LW, rank = "journeyman", teaches = G.teachesSet({ "X" }), teachesPartial = true }
			assert.same({ 0, "rank" }, { G.serves(partial, hillman) })
			local whole = { trains = LW, rank = "journeyman", teaches = G.teachesSet({ "Hillman's Shoulders" }) }
			assert.equal(2, (G.serves(whole, hillman)))
			local lacks = { trains = LW, rank = "expert", teaches = G.teachesSet({ "Other" }) }
			assert.equal(0, (G.serves(lacks, hillman)))
		end)

		it("says which rank is missing when every known trainer is below it", function()
			local dan = {}
			for _, npc in ipairs(undercity()) do
				if npc.id == 223 then
					dan = { npc }
				end
			end
			local pick, _, excluded, stats = G.nearest(dan, hillman, nil, realWorld)
			assert.is_nil(pick)
			assert.same({ 0, 1 }, { excluded, stats.belowRank })
			local s = { phase = "unknown", need = hillman, profession = LW, excluded = 0, belowRank = 1 }
			local d = G.describe(s)
			assert.same(
				{ "No Expert trainer known", "Hillman's Shoulders needs an Expert Leatherworking trainer or better" },
				{ d.l1, d.l2 }
			)
			assert.equal("No Expert Leatherworking trainer known", G.strip(s).a)
			assert.matches("needs an Expert Leatherworking trainer or better", G.unknownText(hillman, nil, 0, 1))
			-- opened trainers lacking the name are named first, as on the chip and the strip
			assert.matches("No trainer you've opened teaches", G.unknownText(hillman, nil, 1, 1))
		end)

		it("names the trainer's rank in its role line", function()
			local s = { phase = "far", need = hillman, name = "Arthur Moore", distance = 300, profession = LW }
			s.rank = "expert"
			assert.equal("Expert Leatherworking trainer", G.describe(s).l2)
			s.rank = "grand master"
			assert.equal("Grand Master Leatherworking trainer", G.describe(s).l2)
			s.rank = nil
			assert.equal("Leatherworking trainer", G.describe(s).l2)
		end)

		it("stops re-reading a visit once the whole list reads the same twice, or after the read cap", function()
			local _, _, visit = G.trainerRead(nil, 223, {}, true, 0)
			assert.is_true((G.trainerWants(visit)))
			-- a short list that looks whole (still filling) keeps the visit reading, and the fuller one is saved
			_, _, visit = G.trainerRead(visit, 223, { "A" }, false, 1)
			assert.is_true((G.trainerWants(visit)))
			local teaches
			teaches, _, visit = G.trainerRead(visit, 223, { "A", "B" }, false, 2)
			assert.same({ "A", "B" }, teaches)
			assert.is_true((G.trainerWants(visit)))
			-- the same count again: whole, stop
			_, _, visit = G.trainerRead(visit, 223, { "A", "B" }, false, 2)
			local wants, why = G.trainerWants(visit)
			assert.is_false(wants)
			assert.matches("whole list", why)
			-- a list that stays in part stops at the cap
			visit = nil
			for _ = 1, G.TRAINER_READS do
				_, _, visit = G.trainerRead(visit, 4588, { "A" }, true, 1)
			end
			wants, why = G.trainerWants(visit)
			assert.is_false(wants)
			assert.matches("in part", why)
			-- a new trainer is a new visit
			_, _, visit = G.trainerRead(visit, 5811, { "A" }, true, 1)
			assert.is_true((G.trainerWants(visit)))
		end)
	end)

	it("gives a row without a position its zone only: no distance, no bearing, last in the list", function()
		local need = { kind = "trainer", profession = "Blacksmithing" }
		local list = G.ranked(knownFor("Horde"), need, at(1454, 79.4, 24), realWorld)
		local gurdok
		for _, pick in ipairs(list) do
			if pick.npc.id == 256658 then
				gurdok = pick
			end
		end
		assert.same(
			{ "Riverglades", "nopos", true, "In Riverglades, position not known" },
			{ gurdok.zone, gurdok.confidence, gurdok.nopos, gurdok.note }
		)
		assert.is_nil(gurdok.distance)
		assert.is_nil(gurdok.bearing)
		assert.is_nil(gurdok.npc.x)
		assert.is_true(list[#list].nopos)
		-- alone, it is the pick: "away", with the zone in the chip and the strip, and no arrow
		local only = G.nearest({ gurdok.npc }, need, at(1454, 79.4, 24), realWorld)
		assert.equal("away", G.phase(only))
		local s = { phase = "away", need = need, name = only.name, place = only.zone, confidence = only.confidence }
		local d = G.describe(s)
		assert.same({ "Gur'dok", "In Riverglades, position not known", nil }, { d.l1, d.l2, d.icon })
		assert.equal("Gur'dok, in Riverglades, position not known", G.strip(s).a)
		assert.equal("Position not known", G.confidenceText("nopos"))
	end)

	it("says a Classic position is unconfirmed, and nothing for a learned one", function()
		local need = { kind = "trainer", profession = "Blacksmithing" }
		local s = { phase = "far", need = need, name = "Snarl", place = "Orgrimmar", distance = 140 }
		s.confidence = "classic"
		local d = G.describe(s)
		assert.equal("Orgrimmar, position from Classic, unconfirmed", d.l2)
		assert.equal("Position from Classic, unconfirmed", d.note)
		assert.equal("arrow", d.icon)
		local strip = G.strip(s)
		assert.same({ "Snarl, Orgrimmar", "Position from Classic, unconfirmed" }, { strip.a, strip.b })
		-- close by, the chip says what to do; the note stays for the tooltip
		s.phase = "near"
		assert.same(
			{ "Close. Target them to see who it is", "Position from Classic, unconfirmed" },
			{ G.describe(s).l2, G.describe(s).note }
		)
		s.phase, s.confidence = "far", "confirmed"
		assert.same({ "Blacksmithing trainer, Orgrimmar", nil }, { G.describe(s).l2, G.describe(s).note })
		assert.is_nil(G.strip(s).b)
		-- a named need to a trainer never opened: both doubts in the note, the place on the chip
		s.need = { kind = "trainer", profession = "Blacksmithing", name = "Expert" }
		s.certain, s.confidence = false, "classic"
		d = G.describe(s)
		assert.equal("Orgrimmar, position from Classic, unconfirmed", d.l2)
		assert.equal("May teach Expert: not checked yet. Position from Classic, unconfirmed", d.note)
		-- a seed (Data/Npcs.lua) is a Classic position too; the player's own Custom.lua row is confirmed
		local seeds = G.seedRecords({
			{ id = 1, name = "Seed", map = 1, x = 1, y = 1, role = "auction" },
			{ id = 2, name = "Own", map = 1, x = 1, y = 1, role = "auction" },
		}, { [2] = true })
		assert.same({ "classic", "confirmed" }, { G.confidenceOf(seeds[1]), G.confidenceOf(seeds[2]) })
		assert.same({ "seed", "seed" }, { G.sourceOf(seeds[1]), G.sourceOf(seeds[2]) })
	end)

	it("sends a recipe-vendor need to the shipped vendor that sells the recipe", function()
		-- Abigail Shiel (Tirisfal Glades, Horde) sells recipe item 12226
		local need = G.needsOf({ kind = "buyRecipe", item = 12226, where = "vendor" }, "Cooking")[1]
		assert.same({ "vendor", 12226 }, { need.kind, need.items[1].item })
		local pick, servers, _, stats = G.nearest(knownFor("Horde"), need, at(1420, 60, 52), realWorld)
		assert.same({ 2118, "Abigail Shiel", "Tirisfal Glades" }, { pick.npc.id, pick.name, pick.zone })
		assert.same({ "shipped", "classic", false }, { pick.source, pick.confidence, pick.partial })
		assert.near(math.sqrt(10 * 10 + 4 * 4), pick.distance, 1e-6)
		assert.equal(1, servers)
		assert.same({ shipped = 1, learned = 0, seed = 0 }, stats.bySource)
		-- she is the other side's for an Alliance character: nobody, and the why names the data and the faction
		local none, n, _, st = G.nearest(knownFor("Alliance"), need, at(1420, 60, 52), realWorld)
		assert.is_nil(none)
		assert.equal(0, n)
		assert.equal(
			"Data/Trainers.lua has no vendor selling Recipe: Test for Alliance, and none in Data/Npcs.lua or learned",
			G.whyNone(need, { stats = st, faction = "Alliance", thing = "Recipe: Test" })
		)
		-- a creature that only drops a recipe is no vendor
		for _, npc in ipairs(knownFor(nil)) do
			assert.is_true(npc.trains ~= nil or npc.sells ~= nil)
		end
	end)

	it("lets what the character learned win over the shipped row of the same NPC, as confirmed", function()
		local learned = {}
		-- Snarl (1383), shipped at 79.6, 23.3 in Orgrimmar as an Expert: seen at another spot, teaching Artisan
		G.learn(learned, {
			id = 1383,
			name = "Snarl",
			map = 1454,
			x = 70,
			y = 30,
			trains = "Blacksmithing",
			teaches = { "Artisan" },
		}, 5)
		local all = knownFor("Horde", learned)
		local need = { kind = "trainer", profession = "Blacksmithing", name = "Artisan", cap = 300 }
		local pick, _, _, stats = G.nearest(all, need, at(1454, 79.4, 24), realWorld)
		assert.same({ 1383, "learned", "confirmed", true }, { pick.npc.id, pick.source, pick.confidence, pick.certain })
		assert.is_nil(pick.note)
		assert.same({ 70, 30, "Orgrimmar", "expert" }, { pick.npc.x, pick.npc.y, pick.zone, pick.npc.rank })
		assert.equal(1, stats.bySource.learned)
		assert.is_true(stats.bySource.shipped > 0)
		-- one record for the NPC, and the saved one is left as it was
		local n = 0
		for _, npc in ipairs(all) do
			n = n + (npc.id == 1383 and 1 or 0)
		end
		assert.equal(1, n)
		assert.is_nil(learned[1383].rank)
		assert.is_nil(learned[1383].place)
		-- learned over a seed over the shipped row: still one record, learned
		local seeds = G.seedRecords({ { id = 1383, name = "Snarl", map = 1454, x = 79, y = 23, role = "trade" } })
		local three = G.nearest(knownFor("Horde", learned, seeds), need, at(1454, 79.4, 24), realWorld)
		assert.same({ 1383, "learned", 70 }, { three.npc.id, three.source, three.npc.x })
		-- and a seed over the shipped row keeps the seed's position and the shipped profession
		local two = G.nearest(
			knownFor("Horde", nil, seeds),
			{ kind = "trainer", profession = "Blacksmithing" },
			at(1454, 79, 23),
			realWorld
		)
		assert.same({ 1383, "seed", 79, "classic" }, { two.npc.id, two.source, two.npc.x, two.confidence })
		-- a learned NPC of the other faction's list stays: the player opened its window
		local mallory = {}
		G.learn(
			mallory,
			{ id = 1215, name = "Alchemist Mallory", map = 1429, x = 39.8, y = 48.2, trains = "Alchemy" },
			1
		)
		local got = G.nearest(
			knownFor("Horde", mallory),
			{ kind = "trainer", profession = "Alchemy" },
			at(1429, 39, 48),
			realWorld
		)
		assert.same({ 1215, "learned" }, { got.npc.id, got.source })
	end)

	it("shows the empty state only when shipped, seeded and learned data have nothing, and says which link", function()
		local need = { kind = "trainer", profession = "Blacksmithing" }
		local pick, servers, excluded, stats = G.nearest(G.known({}, {}, {}, {}), need, at(1454, 50, 50), realWorld)
		assert.is_nil(pick)
		assert.same({ 0, 0 }, { servers, excluded })
		assert.same({ shipped = 0, learned = 0, seed = 0 }, stats.bySource)
		assert.equal("none", G.phase(pick))
		assert.equal(
			"Data/Trainers.lua has no Blacksmithing trainer for Horde, and no Blacksmithing trainer learned or seeded",
			G.whyNone(need, { stats = stats, faction = "Horde" })
		)
		assert.equal(
			"Data/Trainers.lua is not loaded, and no Blacksmithing trainer learned or seeded",
			G.whyNone(need, { stats = stats, faction = "Horde", shipped = false })
		)
		assert.matches("an unknown faction %(UnitFactionGroup gave none%)", G.whyNone(need, { stats = stats }))
		assert.equal("Data/Npcs.lua has no auctioneer, and none learned", G.whyNone({ kind = "auction" }, {}))
		local d = G.describe({ phase = "unknown", need = need, profession = "Blacksmithing" })
		assert.same({ "No known trainer yet", "Ask a city guard for the Blacksmithing trainer" }, { d.l1, d.l2 })
		-- with the shipped data the same need has a trainer for either side: the empty card cannot show
		for _, faction in ipairs({ "Horde", "Alliance" }) do
			assert.is_truthy(G.nearest(knownFor(faction), need, at(1454, 50, 50), realWorld))
		end
		-- trainers known, all below the rank: its own words and why
		local low = {
			{
				id = 1,
				name = "J",
				map = 1454,
				x = 1,
				y = 1,
				trains = "Blacksmithing",
				rank = "journeyman",
				shipped = true,
			},
		}
		local up = { kind = "trainer", profession = "Blacksmithing", name = "Artisan", cap = 300 }
		local none, _, _, st = G.nearest(low, up, nil, realWorld)
		assert.is_nil(none)
		assert.same({ 1, 0, 1 }, { st.belowRank, st.excluded, st.profession })
		assert.equal(
			"Data/Trainers.lua has 1 Blacksmithing trainer(s) for Horde, none of a rank that teaches Artisan (skill 300)",
			G.whyNone(up, { stats = st, faction = "H" })
		)
		assert.equal("No Artisan trainer known", G.describe({ phase = "unknown", need = up, belowRank = 1 }).l1)
		-- a need that names no skill keeps the generic line
		local bare = { kind = "trainer", profession = "Blacksmithing", name = "X" }
		assert.equal("No trainer of that rank known", G.describe({ phase = "unknown", need = bare, belowRank = 1 }).l1)
		-- opened trainers whose lists lack the name
		assert.equal(
			"2 Cooking trainer(s) opened, none lists Goldthorn Tea",
			G.whyNone(
				{ kind = "trainer", profession = "Cooking", name = "Goldthorn Tea" },
				{ stats = { excluded = 2 } }
			)
		)
	end)
end)

describe("Guide strip and towns", function()
	local G = load()
	local trainer = { kind = "trainer", profession = "Leatherworking" }
	local vendor = { kind = "vendor", items = { { item = THREAD, count = 2 } } }

	it("words the strip shorter than the chip, with the next place as a Then line", function()
		local s = G.strip({
			phase = "far",
			need = vendor,
			name = "Tamar",
			distance = 140,
			place = "Orgrimmar",
			thenNeed = trainer,
			profession = "Leatherworking",
		})
		assert.same(
			{ "Tamar, Orgrimmar", "140 yd", "ash", "Then: Leatherworking trainer" },
			{ s.a, s.ar, s.arTint, s.b }
		)
		local near = G.strip({ phase = "near", need = vendor, name = "Tamar", distance = 42, color = "orange" })
		assert.same({ "Tamar is close", "orange", "arrow" }, { near.a, near.arTint, near.icon })
		local at = G.strip({ phase = "here", need = vendor, name = "Tamar" })
		assert.same({ "You are here", "", "dot" }, { at.a, at.ar, at.icon })
		local star = G.strip({ phase = "targeted", need = vendor, name = "Tamar", marked = true })
		assert.equal("Right-click Tamar (the star)", star.a)
	end)

	it("is gone when the need is covered or there is no guide", function()
		assert.is_nil(G.strip({ phase = "done", need = vendor }))
		assert.is_nil(G.strip({ phase = "none" }))
	end)

	it("says what is missing when no NPC is known, and why there are no directions", function()
		local u = G.strip({ phase = "unknown", need = vendor, thing = "Coarse Thread" })
		assert.equal("No known vendor for Coarse Thread yet", u.a)
		assert.matches("Coarse Thread", u.tip, 1, true)
		local t = G.strip({ phase = "unknown", need = trainer, profession = "Leatherworking" })
		assert.equal("No known Leatherworking trainer yet", t.a)
		assert.equal("No directions inside an instance", G.strip({ phase = "notnow", instance = true }).a)
		assert.equal("No directions right now", G.strip({ phase = "notnow" }).a)
	end)

	it("names a learned NPC's town from a seed nearby, else the map", function()
		local seeds = {
			{ map = 1413, x = 52, y = 30, place = "Crossroads" },
			{ map = 1454, x = 50, y = 50, place = "Orgrimmar" },
		}
		assert.equal("Crossroads", G.placeNear(1413, 51.5, 31, seeds, "The Barrens"))
		assert.equal("The Barrens", G.placeNear(1413, 20, 80, seeds, "The Barrens"))
		assert.is_nil(G.placeNear(1, 0, 0, seeds, nil))
		-- a record without y (an old save) falls back to the map, no error
		assert.equal("The Barrens", G.placeNear(1413, 52, nil, seeds, "The Barrens"))
	end)
end)
