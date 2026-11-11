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
	end)
end)
