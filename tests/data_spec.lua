-- The data layers (Logic.effectivePlan), Data/Custom.lua's checks, learn ranks read at the trainer, recipe items
-- (tradeable, unpriced, bind on pickup) and the cost of levelling (Planner.costToCap).
local F = dofile("tests/fixtures.lua")
local I = F.ITEM

local function load()
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "Scan.lua", "TSM.lua", "View.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local ns, L, P
before_each(function()
	_G.issecretvalue = function()
		return false
	end
	ns = load()
	L, P = ns.Logic, ns.Planner
end)

local function shipped()
	return {
		version = 2,
		build = "1.60.1.1",
		source = "a test, 2026-01-01",
		counts = { [164] = 3, [185] = 1 },
		vendor = { [10] = 40 },
		items = { [1] = { name = "Bar", sell = 5 }, [2] = { name = "Stone", sell = 2 } },
		professions = {
			[164] = {
				name = "Blacksmithing",
				to = 300,
				ranks = { { name = "Apprentice", cap = 75, cost = 10, confirmed = false } },
				recipes = {
					[100] = { y = 15, g = 55, k = 1, name = "Stone", mats = { 1, 1 }, makes = 2, n = 1, src = "auto" },
					[101] = { y = 45, g = 65, k = 1, name = "Belt", mats = { 1, 2 }, src = "trainer" },
					[102] = { y = 70, g = 90, k = 1, name = "Axe", mats = { 1, 3 }, src = "trainer", learn = 60 },
				},
			},
			[185] = { name = "Cooking", to = 300, recipes = { [200] = { y = 1, g = 45, k = 1, mats = { 3, 1 } } } },
		},
	}
end

describe("effectivePlan", function()
	it("is the shipped data alone when nothing else is there", function()
		local eff, report = L.effectivePlan(shipped(), nil, nil)
		assert.equal("1.60.1.1", eff.build)
		assert.equal(3, #report.shipped.professions + 1)
		assert.equal("Blacksmithing(164) 3 recipes", report.shipped.professions[1])
		assert.equal("absent (optional)", report.plan)
		assert.equal("absent (optional)", report.custom)
		assert.is_nil(eff.pricesAt)
		assert.is_nil(eff.professions[164].rows)
		assert.equal(40, eff.vendor[10])
	end)

	it("says so when no layer loaded, and returns nothing", function()
		local eff, report = L.effectivePlan(nil, nil, nil)
		assert.is_nil(eff)
		assert.matches("Data/Recipes.lua not loaded", report.shipped)
	end)

	it("layers a local plan over the professions and items it has, and leaves the rest shipped", function()
		local base = shipped()
		local plan = {
			version = 2,
			generatedAt = "2026-11-11 12:00:00",
			pricesAt = 1000,
			effort = 30,
			vendor = { [11] = 25 },
			items = { [1] = { name = "Bar", sell = 5, mv = 123 }, [9] = { name = "Gem", mv = 900 } },
			professions = {
				[164] = {
					name = "Blacksmithing",
					from = 28,
					to = 150,
					rows = { { from = 28, to = 40 } },
					buyRecipes = {},
					recipes = {
						[101] = { y = 45, g = 65, k = 1, mats = { 1, 2 }, src = "trainer", sell = 500, takes = 3 },
						[150] = { y = 80, g = 100, k = 1, mats = { 9, 1 }, src = "item", item = 77, learn = 75 },
					},
				},
			},
		}
		local eff, report = L.effectivePlan(base, plan, nil)
		local bs = eff.professions[164]
		assert.same({ 1000, 30, "2026-11-11 12:00:00" }, { eff.pricesAt, eff.effort, eff.generatedAt })
		assert.same({ 28, 1 }, { bs.from, #bs.rows })
		-- the shipped data reaches the top rank: an export made for 150 does not shorten it
		assert.equal(300, bs.to)
		assert.equal(1, #bs.ranks)
		-- the plan's sale value on the shipped row, the shipped-only recipes kept, the plan-only recipe added
		assert.same({ 500, 3, "Belt" }, { bs.recipes[101].sell, bs.recipes[101].takes, bs.recipes[101].name })
		assert.equal(60, bs.recipes[102].learn)
		assert.equal(75, bs.recipes[150].learn)
		assert.same({ 123, 900, 2 }, { eff.items[1].mv, eff.items[9].mv, eff.items[2].sell })
		assert.same({ 40, 25 }, { eff.vendor[10], eff.vendor[11] })
		-- Cooking is not in the plan: the shipped entry itself
		assert.equal(base.professions[185], eff.professions[185])
		assert.matches("^present, 1 profession, generated", report.plan)
		-- no layer was written to
		assert.is_nil(base.professions[164].recipes[101].sell)
		assert.is_nil(base.professions[164].recipes[150])
		assert.is_nil(base.items[1].mv)
	end)

	it("ignores the recipe rows of a version 1 plan and keeps its rows", function()
		local plan = { professions = { [164] = { from = 1, rows = {}, recipes = { [101] = { 45, 65, 1 } } } } }
		local eff, report = L.effectivePlan(shipped(), plan, nil)
		assert.same({ 1, 2 }, eff.professions[164].recipes[101].mats)
		assert.matches("version 1", report.plan)
		assert.is_true(L.isPlanV2(eff, eff.professions[164]))
	end)

	it("is the local plan alone when the shipped data is missing", function()
		local plan = { version = 2, professions = { [185] = { name = "Cooking", recipes = {} } } }
		local eff = L.effectivePlan(nil, plan, nil)
		assert.equal(plan.professions[185], eff.professions[185])
	end)

	it("applies Data/Custom.lua on top: fields, removal, a new recipe, vendor reagents, NPCs", function()
		local base = shipped()
		local custom = {
			recipes = {
				[164] = {
					[101] = { learn = 30, cost = 100 },
					[100] = false,
					[103] = { y = 90, g = 110, mats = { 1, 4 }, src = "trainer", name = "Helm" },
				},
			},
			vendor = { [1] = 55, [10] = false },
			items = { [2] = { sell = 9 } },
			npcs = {
				{ id = 7, name = "Smith", map = 1454, x = 10, y = 20, role = "trainer", trains = "Blacksmithing" },
			},
		}
		local eff, report = L.effectivePlan(base, nil, custom)
		local bs = eff.professions[164]
		assert.same({ 30, 100, 45 }, { bs.recipes[101].learn, bs.recipes[101].cost, bs.recipes[101].y })
		assert.is_nil(bs.recipes[100])
		assert.is_true(bs.removed[100])
		assert.equal("Helm", bs.recipes[103].name)
		assert.same({ 55, nil }, { eff.vendor[1], eff.vendor[10] })
		assert.same({ 9, "Stone" }, { eff.items[2].sell, eff.items[2].name })
		assert.equal("Smith", eff.npcs[1].name)
		assert.same({ applied = 7, errors = {} }, report.custom)
		assert.is_nil(base.professions[164].recipes[101].learn)
		assert.is_not_nil(base.professions[164].recipes[100])
	end)

	it("reports each bad custom entry by key and still applies the good ones", function()
		local custom = {
			recipes = {
				[164] = {
					[101] = { learn = "thirty" },
					[102] = { learn = 40, colour = "red" },
					[104] = { name = "No thresholds" },
					[100] = { src = "trainer", learn = 5 },
					abc = { learn = 1 },
				},
				[999] = { [1] = { learn = 1 } },
				smithing = {},
			},
			vendor = { [1] = "cheap", [2] = 30 },
			npcs = { { id = 7, name = "Smith" }, "not a table" },
			prices = {},
		}
		local eff, report = L.effectivePlan(shipped(), nil, custom)
		assert.same({
			"npcs[1]: map must be a uiMap id",
			"npcs[2]: must be a table { id, name, map, x, y, role }",
			"prices: unknown section (recipes, vendor, items, npcs, spots, trainers)",
			"recipes[164][101].learn: must be a number >= 0",
			"recipes[164][102].colour: unknown field",
			"recipes[164][104]: not in the data, and a new recipe needs y, g and mats",
			"recipes[164][abc]: the key must be a spell id",
			"recipes[999]: no profession with this skill line id in the data",
			"recipes[smithing]: the key must be a skill line id (164 = Blacksmithing)",
			"vendor[1]: must be the vendor's price in copper, or false",
		}, report.custom.errors)
		assert.equal(2, report.custom.applied)
		local bs = eff.professions[164]
		assert.same({ "trainer", 5 }, { bs.recipes[100].src, bs.recipes[100].learn })
		-- a bad entry changes nothing
		assert.is_nil(bs.recipes[101].learn)
		assert.equal(60, bs.recipes[102].learn)
		assert.equal(30, eff.vendor[2])
	end)

	it("never raises on a custom file that is not a table", function()
		local eff, report = L.effectivePlan(shipped(), nil, "oops")
		assert.is_not_nil(eff)
		assert.same({ "ns.Data.custom: must be a table" }, report.custom.errors)
		local _, errors = L.validateCustom({ recipes = 5, vendor = "x", npcs = true })
		assert.equal(3, #errors)
	end)

	it("accepts the shipped example file whole", function()
		local ex = {}
		assert(loadfile("Data/Custom.example.lua"))("SkillupHelper", ex)
		local _, errors = L.validateCustom(ex.Data.custom)
		assert.same({}, errors)
		local data = {}
		assert(loadfile("Data/Recipes.lua"))("SkillupHelper", data)
		local eff, report = L.effectivePlan(data.Data.recipes, nil, ex.Data.custom)
		assert.same({}, report.custom.errors)
		assert.equal(1, eff.professions[164].recipes[2660].learn)
		assert.is_nil(eff.professions[164].recipes[2663])
	end)
end)

describe("what is built at login", function()
	-- every profession entry of the real shipped file, with a tripwire on its recipe table
	local function tripwired()
		local data = {}
		assert(loadfile("Data/Recipes.lua"))("SkillupHelper", data)
		local real, touched = data.Data.recipes, {}
		local shippedCopy = {}
		for k, v in pairs(real) do
			shippedCopy[k] = v
		end
		shippedCopy.professions = {}
		for id, prof in pairs(real.professions) do
			local entry = {}
			for k, v in pairs(prof) do
				if k ~= "recipes" then
					entry[k] = v
				end
			end
			shippedCopy.professions[id] = setmetatable(entry, {
				__index = function(_, k)
					if k == "recipes" then
						touched[id] = (touched[id] or 0) + 1
						return prof.recipes
					end
				end,
			})
		end
		return shippedCopy, touched, real
	end

	it("touches no profession's recipes, and reports the counts the generator wrote", function()
		local data, touched, real = tripwired()
		local eff, report = L.effectivePlan(data, nil, nil)
		assert.same({}, touched)
		assert.equal(real.build, report.shipped.build)
		assert.is_string(report.shipped.source)
		local n = 0
		for id, prof in pairs(real.professions) do
			n = n + 1
			local count = 0
			for _ in pairs(prof.recipes) do
				count = count + 1
			end
			assert.equal(count, real.counts[id], prof.name)
		end
		assert.equal(n, #report.shipped.professions)
		assert.matches("^Alchemy%(171%) %d+ recipes$", report.shipped.professions[1])
		-- asked for one profession: only that one is read
		assert.is_table(eff.professions[164].recipes[2660])
		assert.same({ [164] = 1 }, touched)
	end)

	it("merges a local plan and a custom file only for a profession that is opened", function()
		local data, touched = tripwired()
		local plan = { version = 2, professions = { [185] = { name = "Cooking", from = 1, recipes = {} } } }
		local custom = { recipes = { [164] = { [2660] = { learn = 1 } } }, vendor = { [2880] = 100 } }
		local eff, report = L.effectivePlan(data, plan, custom)
		assert.same({}, report.custom.errors)
		-- the custom entry was checked against its own profession (one lookup); nothing else was read
		assert.same({ [164] = 1 }, touched)
		assert.equal(1, eff.professions[164].recipes[2660].learn)
		assert.equal(1, eff.professions[185].from)
		assert.is_table(eff.professions[185].recipes)
		assert.is_nil(touched[197])
		-- item rows read through to the shipped table without a copy
		assert.equal(data.items[2880], eff.items[2880])
	end)
end)

describe("dataStatus", function()
	it("says how old the data is, and that the game is newer only when it is", function()
		local data = { build = "1.60.1.70938", source = "Wowhead, Forever section, 2026-11-14" }
		local line, newer = L.dataStatus(data, "1.60.1", "70938")
		assert.equal(
			"Recipe data: build 1.60.1.70938, learn ranks and sources from Wowhead, Forever section, 2026-11-14."
				.. " Your game is build 1.60.1.70938.",
			line
		)
		assert.is_false(newer)
		line, newer = L.dataStatus(data, "1.60.2", 71000)
		assert.is_true(newer)
		assert.matches("Your game is build 1.60.2.71000: newer than the data", line, 1, true)
		-- an older game, or a build the client does not give: no claim
		assert.is_false(select(2, L.dataStatus(data, "1.60.1", "70000")))
		assert.is_false(select(2, L.dataStatus(data, nil, nil)))
		assert.matches("not loaded", (L.dataStatus(nil, "1.60.1", "70938")))
	end)
end)

describe("npcRows", function()
	it("adds custom NPCs and lets one replace a shipped NPC with the same id", function()
		local rows = L.npcRows(
			{ { id = 1, name = "A" }, { id = 2, name = "B" } },
			{ { id = 2, name = "B2" }, { id = 3, name = "C" } }
		)
		assert.same({ "A", "B2", "C" }, { rows[1].name, rows[2].name, rows[3].name })
	end)
end)

describe("learn ranks from the trainer", function()
	it("reads the skill and cost of every recipe service, keyed like trainerSeen", function()
		local NAMES = { "Apprentice", "Journeyman" }
		local req = ns.Scan.trainerReqSet({
			{ name = "Weapons", type = "header" },
			{ name = "Journeyman Blacksmith", type = "available", skillRank = 50, cost = 500 },
			{ name = "Copper Axe", type = "available", spellID = 101, skillRank = 20, cost = 50 },
			{ name = "Copper Mace", type = "unavailable", skillRank = 65 },
			{ name = "Secret", type = "available", spellID = 9 },
		}, NAMES)
		assert.same({ [101] = { skill = 20, cost = 50 }, ["copper mace"] = { skill = 65 } }, req)
	end)

	it("wins over the custom file, which wins over the shipped learn rank, which wins over yellow", function()
		local custom = { recipes = { [164] = { [101] = { learn = 30 }, [102] = { learn = 55 } } } }
		local eff = L.effectivePlan(shipped(), nil, custom)
		local prof = L.withTrainerReq(eff.professions[164], { [101] = { skill = 25, cost = 80 } })
		-- 101: trainer 25 over custom 30; 102: custom 55 over shipped 60; and the layers are untouched
		assert.same({ 25, 80, 55 }, { prof.recipes[101].learn, prof.recipes[101].cost, prof.recipes[102].learn })
		assert.equal(30, eff.professions[164].recipes[101].learn)
		local function at(profession, spell)
			local ctx = P.prepare({ skill = 1, cap = 75, recipes = profession.recipes, price = { [1] = { buy = 10 } } })
			for _, o in ipairs(ctx.options) do
				if o.spell == spell then
					return o.at
				end
			end
		end
		assert.equal(25, at(prof, 101))
		assert.equal(55, at(prof, 102))
		assert.equal(60, at(shipped().professions[164], 102))
		-- no learn rank anywhere: from yellow, as before
		assert.equal(45, at(shipped().professions[164], 101))
	end)

	it("matches a service keyed by name, and makes a listed recipe a trainer recipe that is in the game", function()
		local prof =
			{ recipes = { [5] = { name = "Iron Buckle", y = 10, g = 30, src = "item", item = 1, gone = true } } }
		local out = L.withTrainerReq(prof, { ["iron buckle"] = { skill = 5 } })
		assert.same({ "trainer", 5, false }, { out.recipes[5].src, out.recipes[5].learn, out.recipes[5].gone })
		assert.equal(prof, L.withTrainerReq(prof, {}))
		assert.equal(prof, L.withTrainerReq(prof, { [77] = { skill = 1 } }))
	end)
end)

-- A Blacksmithing start: skill 28, the two known recipes grey by 60, three trainer recipes learnable at 25, 40 and
-- 50 that only turn yellow at 58, 64 and 74.
local BAR = 1
local function smith(learn)
	local function rec(name, y, g, src, at)
		return { name = name, y = y, g = g, k = 1, mats = { BAR, 2 }, src = src, learn = learn and at or nil }
	end
	return {
		skill = 28,
		cap = 75,
		recipes = {
			[1] = rec("Rough Stone", 15, 55, "auto"),
			[2] = rec("Copper Belt", 20, 60, "auto"),
			[3] = rec("Copper Axe", 58, 70, "trainer", 25),
			[4] = rec("Copper Mace", 64, 72, "trainer", 40),
			[5] = rec("Runed Bar", 74, 95, "trainer", 50),
		},
		learned = { [1] = true, [2] = true },
		price = { [BAR] = { buy = 50, where = "ah", salvage = 10 } },
		have = {},
		effort = 20,
	}
end

local function totals(plan)
	local crafts, gaps, kinds = 0, 0, {}
	for _, st in ipairs(plan.steps) do
		kinds[#kinds + 1] = st.kind .. ":" .. tostring(st.spell or "")
		if st.kind == "craft" then
			crafts = crafts + st.crafts
		elseif st.kind == "gap" then
			gaps = gaps + 1
		end
	end
	return crafts, gaps, kinds
end

describe("a trainer recipe with a learn rank below yellow", function()
	it("leaves a gap and a long grind without learn ranks (the old behaviour)", function()
		local plan = P.run(smith(false))
		local crafts, gaps = totals(plan)
		assert.equal(1, gaps)
		assert.is_true(crafts > 100)
	end)

	it("is trained at its learn rank and crafted through its orange range: no gap, far fewer crafts", function()
		local old = totals(P.run(smith(false)))
		local plan = P.run(smith(true))
		local crafts, gaps, kinds = totals(plan)
		assert.equal(0, gaps)
		-- 47 points, nearly all orange: about one craft a point, not the 100+ of the yellow and green grind
		assert.is_true(crafts < 70, "crafts " .. crafts)
		assert.is_true(crafts < old / 2)
		-- the Axe is learnable at 25, below the current skill: train it first, then craft it from 28
		assert.same({ "train:3", "craft:3" }, { kinds[1], kinds[2] })
		assert.same({ 25, 28, "orange" }, { plan.steps[1].at, plan.steps[2].from, plan.steps[2].color })
		-- every later trainer recipe has its train step before its first craft, at its learn rank
		local trained, last = {}, 28
		for _, st in ipairs(plan.steps) do
			if st.kind == "train" then
				trained[st.spell] = st.at
			elseif st.kind == "craft" then
				assert.is_true(st.spell <= 2 or trained[st.spell] ~= nil, "trained before crafting " .. st.name)
				assert.is_true(math.abs(st.from - last) < 1e-6, "steps join at " .. st.from)
				last = st.to
			end
		end
		assert.equal(75, last)
		for spell, at in pairs(trained) do
			assert.equal(({ [3] = 25, [4] = 40, [5] = 50 })[spell], at)
		end
		assert.equal(25, trained[3])
	end)
end)

describe("recipe items", function()
	local COD = 7828
	local function cooking(change, extra)
		local input = F.cooking()
		local recipes = {}
		for spell, r in pairs(input.recipes) do
			recipes[spell] = r
		end
		local cod = {}
		for k, v in pairs(recipes[COD]) do
			cod[k] = v
		end
		for k, v in pairs(change or {}) do
			cod[k] = v
		end
		recipes[COD] = cod
		input.recipes = recipes
		for k, v in pairs(extra or {}) do
			input[k] = v
		end
		return input
	end
	local function find(plan, kind, spell)
		for _, st in ipairs(plan.steps) do
			if st.kind == kind and st.spell == spell then
				return st
			end
		end
	end
	local function shortcut(plan, spell)
		for _, st in ipairs(plan.steps) do
			for _, c in ipairs(st.shortcuts or {}) do
				if c.spell == spell then
					return c
				end
			end
		end
	end

	it("buys a tradeable recipe item that has a price, and puts it on the shopping list", function()
		local plan = P.run(cooking())
		local buy = find(plan, "buyRecipe", COD)
		assert.same({ I.CODRECIPE, 2811, "ah" }, { buy.item, buy.price, buy.where })
		assert.is_not_nil(find(plan, "craft", COD))
		local listed = false
		for _, r in ipairs(plan.trip and plan.trip.rows or {}) do
			listed = listed or r.item == I.CODRECIPE
		end
		assert.is_true(listed)
		assert.is_nil(shortcut(plan, COD))
	end)

	it("does not plan a tradeable recipe item without a price, and says why on a shortcut", function()
		-- learnable below the current skill, so it could replace a whole step (a shortcut covers its step end to end)
		local input = cooking({ learn = 150 })
		input.price[I.CODRECIPE] = nil
		local plan = P.run(input)
		assert.is_nil(find(plan, "buyRecipe", COD))
		assert.is_nil(find(plan, "craft", COD))
		local cut = shortcut(plan, COD)
		assert.equal("no auction price today", cut.why)
		local rows = ns.View.shortcutRows({ cut }, { money = L.money })
		assert.matches("^Shortcut: Rockscale Cod saves .* %(no auction price today%)$", rows[1].text)
	end)

	it("never buys a recipe item that binds when picked up: a shortcut that says so, with who has it", function()
		local plan = P.run(cooking({ learn = 150, bop = true, teacher = "sold by a fishing vendor" }))
		assert.is_nil(find(plan, "buyRecipe", COD))
		assert.is_nil(find(plan, "craft", COD))
		local cut = shortcut(plan, COD)
		assert.equal("its recipe binds when picked up: sold by a fishing vendor", cut.why)
		assert.is_true(cut.bop)
		-- "Use it": the player can get it, so the plan crafts it, still without an auction buy
		local used = P.run(cooking({ bop = true }, { exclude = { allow = { [COD] = true } } }))
		assert.is_not_nil(find(used, "craft", COD))
		-- with an explicit step in front of the crafts that says where it comes from, and no price made up
		local get = find(used, "buyRecipe", COD)
		assert.same(
			{ "source", "binds when picked up, source not known", true },
			{ get.where, get.source, get.priceUnknown }
		)
		assert.is_nil(get.price)
		assert.is_false(P.needsAh({ price = {} }, get))
		for _, r in ipairs(used.trip and used.trip.rows or {}) do
			assert.is_not.equal(I.CODRECIPE, r.item)
		end
		local card = ns.View.describe({
			profession = "Cooking",
			skill = 173,
			maxSkill = 225,
			planner = { steps = { get }, hold = {}, leftovers = {} },
		}, {
			money = L.money,
			nameOf = function(_, f)
				return f
			end,
			have = function()
				return 0
			end,
		}).now
		assert.same(
			{ "Get the recipe: binds when picked up, source not known", "recipe price unknown" },
			{ card.verb, card.cost }
		)
		assert.equal("Price unknown for the recipe", card.lines[1].text)
	end)

	it("names the source in the get-the-recipe step, and says the price is unknown in the cost", function()
		local function get(change, extra)
			local input = cooking(change, { exclude = { allow = { [COD] = true } } })
			for k, v in pairs(extra or {}) do
				input[k] = v
			end
			if not (change and change.bop) then
				input.price[I.CODRECIPE] = nil
			end
			return find(P.run(input), "buyRecipe", COD)
		end
		assert.equal("auction house, no price today", get().source)
		assert.equal("a drop; auction house, no price today", get({ from = "drop" }).source)
		assert.equal("a quest reward", get({ bop = true, from = "quest" }).source)
		local horde = { name = "Kelsey Yance", npc = 2664, a = 1, h = -1 }
		assert.equal(
			"sold by Kelsey Yance",
			get({ bop = true, from = "vendor", vendor = horde, buy = 2200 }, { faction = "Horde" }).source
		)
		-- costToCap: the recipe is listed with no price and counted as unknown, not as free
		local prof = { recipes = cooking({ bop = true, learn = 1 }).recipes }
		local r = P.costToCap(prof, 173, 225, function(item)
			-- the fish is cheap, so the cod is the plan's pick once the chops stop being orange
			return item ~= I.CODRECIPE and (item == I.COD and 1 or 50) or nil
		end, { cap = 225, learned = F.COOKING_LEARNED, exclude = { allow = { [COD] = true } } })
		assert.equal(1, r.unknownRecipePrices)
		assert.matches("1 recipe price unknown", ns.View.costLine("Cooking", 173, 225, r, { money = L.money }), 1, true)
	end)

	it("offers a gated recipe that is learnable part-way through a step, from its learn skill", function()
		-- learn 175 (the fixture), the step it would shorten starts at 173
		local plan = P.run(cooking({ bop = true, from = "drop" }))
		local cut = shortcut(plan, COD)
		assert.is_not_nil(cut)
		assert.equal(175, cut.from)
		assert.is_true(cut.saves > P.SHORTCUT_MIN)
	end)

	it("gates a recipe learned by character level until the character has it", function()
		local function spells(level)
			local ctx = P.prepare({
				skill = 100,
				cap = 300,
				level = level,
				price = { [1] = { buy = 10 } },
				recipes = {
					[9] = { name = "Deadly Poison", y = 130, g = 180, mats = { 1, 1 }, src = "trainer", level = 30 },
				},
			})
			return ctx.options[1], ctx.hidden[1]
		end
		local open, gated = spells(30)
		-- no learn skill: gated by level only, so usable through its orange range
		assert.same({ 9, 0 }, { open.spell, open.at })
		assert.is_nil(gated)
		open, gated = spells(29)
		assert.is_nil(open)
		assert.is_true(gated.tooLow)
		-- level not known: not assumed too low
		assert.is_not_nil((spells(nil)))
	end)

	it("asks TSM for no price of a bind-on-pickup recipe item", function()
		local asked = {}
		local prof = {
			recipes = {
				[1] = { mats = { 5, 1 }, src = "item", item = 6, bop = true },
				[2] = { mats = { 5, 1 }, item = 7 },
			},
		}
		local price = ns.TSM.prices({}, prof, function(_, item)
			asked[item] = true
			return 10
		end)
		assert.same({ true, nil, true }, { asked[5], asked[6], asked[7] })
		assert.is_nil(price[6])
	end)

	it("leaves out a recipe whose items are not in the game data, unless it is learned", function()
		local function spells(learned)
			local ctx = P.prepare({
				skill = 1,
				cap = 75,
				learned = learned,
				price = { [1] = { buy = 10 } },
				recipes = { [9] = { y = 10, g = 30, mats = { 1, 1 }, src = "trainer", gone = true } },
			})
			return #ctx.options + #ctx.hidden
		end
		assert.equal(0, spells({}))
		assert.equal(1, spells({ [9] = true }))
	end)
end)

describe("where a recipe comes from", function()
	local COD = 7828
	local VENDOR = { name = "Kelsey Yance", npc = 2664, zone = 33 }
	local function run(change, extra, noAhPrice)
		local input = F.cooking()
		local recipes = {}
		for spell, r in pairs(input.recipes) do
			recipes[spell] = r
		end
		local cod = { learn = 150 }
		for k, v in pairs(input.recipes[COD]) do
			cod[k] = cod[k] or v
		end
		for k, v in pairs(change or {}) do
			cod[k] = v
		end
		recipes[COD] = cod
		input.recipes = recipes
		if noAhPrice then
			input.price[I.CODRECIPE] = nil
		end
		for k, v in pairs(extra or {}) do
			input[k] = v
		end
		return P.run(input)
	end
	local function step(plan, kind)
		for _, st in ipairs(plan.steps) do
			if st.kind == kind and st.spell == COD then
				return st
			end
		end
	end
	local function cut(plan)
		for _, st in ipairs(plan.steps) do
			for _, c in ipairs(st.shortcuts or {}) do
				if c.spell == COD then
					return c
				end
			end
		end
	end

	it("buys a recipe item from its vendor when that is cheaper than the auction house", function()
		local plan = run({ from = "vendor", vendor = VENDOR, buy = 2200 })
		local buy = step(plan, "buyRecipe")
		assert.same({ "vendor", 2200, "Kelsey Yance" }, { buy.where, buy.price, buy.vendor.name })
		-- a vendor buy is no auction house trip, and sits with the vendor stops
		assert.is_false(P.needsAh({ price = {} }, buy))
		for _, r in ipairs(plan.trip and plan.trip.rows or {}) do
			assert.is_not.equal(I.CODRECIPE, r.item)
		end
		local atVendor = false
		for _, r in ipairs(plan.shopping.vendor) do
			atVendor = atVendor or (r.item == I.CODRECIPE and r.merchant == "Kelsey Yance")
		end
		assert.is_true(atVendor)
		assert.same(
			{ kind = "vendor", items = { { item = I.CODRECIPE, count = 1 } } },
			(function()
				local G = {}
				assert(loadfile("Guide.lua"))("SkillupHelper", G)
				return G.Guide.needsOf(buy, "Cooking")[1]
			end)()
		)
		-- the auction house wins when it is cheaper
		local ah = step(run({ from = "vendor", vendor = VENDOR, buy = 9000 }), "buyRecipe")
		assert.same({ "ah", 2811 }, { ah.where, ah.price })
		-- with no auction price the vendor alone makes it a plain buy
		local only = step(run({ from = "vendor", vendor = VENDOR, buy = 2200 }, nil, true), "buyRecipe")
		assert.equal("vendor", only.where)
	end)

	it("does not assume a vendor of the other faction, or one that asks for a reputation", function()
		local horde = { name = "Kelsey Yance", npc = 2664, a = 1, h = -1 }
		local plan = run({ vendor = horde, buy = 2200 }, { faction = "Horde" }, true)
		assert.is_nil(step(plan, "buyRecipe"))
		assert.equal("no auction price today; its vendor is the other faction's", cut(plan).why)
		assert.equal(
			"vendor",
			step(run({ vendor = horde, buy = 2200 }, { faction = "Alliance" }, true), "buyRecipe").where
		)
		-- faction not known: a vendor hostile to either side is not assumed
		assert.is_nil(step(run({ vendor = horde, buy = 2200 }, nil, true), "buyRecipe"))
		local rep = run({ vendor = VENDOR, buy = 2200, faction = 529, rep = 5 }, nil, true)
		assert.equal("no auction price today; its vendor asks for a reputation", cut(rep).why)
		-- with an auction price it is still a buy there
		assert.equal("ah", step(run({ vendor = horde, buy = 2200 }, { faction = "Horde" }), "buyRecipe").where)
	end)

	it("names the source of a bind-on-pickup recipe item on its shortcut", function()
		assert.equal(
			"its recipe binds when picked up: sold by Kelsey Yance",
			cut(
				run({ bop = true, from = "vendor", vendor = { name = "Kelsey Yance", npc = 2664, h = -1 }, buy = 2200 })
			).why
		)
		-- from a vendor the character can reach it is simply bought there, bind on pickup or not
		local buy = step(run({ bop = true, from = "vendor", vendor = VENDOR, buy = 2200 }), "buyRecipe")
		assert.same({ "vendor", 2200 }, { buy.where, buy.price })
		assert.equal("its recipe binds when picked up: a drop", cut(run({ bop = true, from = "drop" })).why)
		assert.equal("its recipe binds when picked up: a quest reward", cut(run({ bop = true, from = "quest" })).why)
	end)

	it("never plans a recipe the data does not list, until the player says they can get it", function()
		local plan = run({ src = "unlisted", item = false })
		assert.is_nil(step(plan, "craft"))
		assert.is_nil(step(plan, "train"))
		assert.equal("not confirmed obtainable in Forever", cut(plan).why)
		local used = run({ src = "unlisted", item = false }, { exclude = { allow = { [COD] = true } } })
		assert.is_not_nil(step(used, "craft"))
		assert.equal("not confirmed obtainable in Forever", step(used, "buyRecipe").source)
		-- a learned one is simply known
		local known = run({ src = "unlisted", item = false }, { learned = { [COD] = true, [3398] = true } })
		assert.is_not_nil(step(known, "craft"))
	end)

	it("shows the trainer's price on the train step and counts it", function()
		local prof = shipped().professions[164]
		prof.recipes[101].cost = 250
		local r = P.costToCap(prof, 1, 60, function()
			return 10
		end, { cap = 75 })
		local train
		for _, st in ipairs(r.steps) do
			train = train or (st.kind == "train" and st.spell == 101 and st)
		end
		assert.equal(250, train.cost)
		assert.equal(250, r.trainingCost)
		local planned = P.run({
			skill = 1,
			cap = 75,
			recipes = prof.recipes,
			learned = { [100] = true },
			price = { [1] = { buy = 10 } },
		})
		local env = {
			money = L.money,
			nameOf = function(_, f)
				return f
			end,
			have = function()
				return 0
			end,
		}
		local d = ns.View.describe({ profession = "B", skill = 1, maxSkill = 75, planner = planned }, env)
		-- the card of that training step, once it is the step to do
		local belt
		for _, st in ipairs(planned.steps) do
			belt = belt or (st.kind == "train" and tostring(st.name):find("^Belt") and st)
		end
		local card = ns.View.describe({
			profession = "B",
			skill = 45,
			maxSkill = 75,
			planner = { steps = { belt }, hold = {}, leftovers = {} },
		}, env).now
		assert.same({ "Train " .. belt.name, "At the trainer from skill 45, 2s 50c" }, { card.title, card.sub })
		-- and the Shopping page totals what trainers are paid, on its own line
		assert.matches("^Training 2s 50c: %d recipes? %(1 price unknown%)$", d.shopping.training)
	end)
end)

describe("costToCap", function()
	local function prof()
		local p = shipped().professions[164]
		p.ranks = {
			{ name = "Apprentice", cap = 75, cost = 10 },
			{ name = "Journeyman", cap = 150, skill = 50, cost = 500 },
		}
		p.recipes[101].learn, p.recipes[101].cost = 30, 100
		p.recipes[102].cost = 200
		return p
	end
	local function flat(item)
		return item == 1 and 50 or nil
	end

	it("totals materials, sales back, training and recipes for a profession not learned yet", function()
		local r = P.costToCap(prof(), 1, 90, flat, { items = shipped().items })
		assert.is_true(r.complete)
		assert.same({}, r.gaps)
		assert.equal(90, r.reached)
		-- Apprentice 10c + Journeyman 5s + the two trainer recipes
		assert.equal(10 + 500 + 100 + 200, r.trainingCost)
		assert.equal(0, r.unknownPrices)
		assert.is_true(r.spent > 0 and r.back > 0)
		assert.equal(r.spent - r.back + r.trainingCost, r.total)
		assert.same({}, r.recipesToBuy)
	end)

	it("names the stretch no recipe covers, and the prices it lacks", function()
		local p = prof()
		p.recipes[101] = nil
		local r = P.costToCap(p, 1, 90, flat, {})
		assert.is_false(r.complete)
		assert.same({ 55, 60 }, { r.gaps[1].from, r.gaps[1].to })
		local none = P.costToCap(prof(), 1, 90, function() end, {})
		assert.equal(1, none.unknownPrices)
		assert.same({ 1 }, none.unknownItems)
		-- a missing price is never a hole: the stretch is planned, and the plan names what it could not price
		assert.is_true(none.complete)
		assert.same({}, none.gaps)
		assert.equal(1, none.unpriced.count)
		assert.equal(1, none.unpriced.items[1].item)
	end)

	it("stops at the top of the recipes and says so", function()
		local r = P.costToCap(prof(), 1, 150, flat, {})
		assert.is_false(r.complete)
		assert.same({ 90, 150 }, { r.gaps[#r.gaps].from, r.gaps[#r.gaps].to })
		assert.matches("past 90", r.gaps[#r.gaps].why)
	end)

	it("starts from the character's own skill and cap without charging the first rank again", function()
		local r = P.costToCap(prof(), 40, 90, flat, { cap = 75, learned = { [100] = true } })
		assert.is_true(r.complete)
		assert.equal(500 + 100 + 200, r.trainingCost)
	end)

	it("prints one line per profession", function()
		local env = { money = L.money }
		local r = P.costToCap(prof(), 1, 90, flat, { items = shipped().items })
		local line = ns.View.costLine("Blacksmithing", 1, 90, r, env)
		assert.matches("^Blacksmithing 1 to 90: .* %(training 8s 10c%); complete; every price from TSM$", line)
		local p = prof()
		p.recipes[101] = nil
		local holes = P.costToCap(p, 1, 90, function() end, {})
		assert.matches(
			"nothing gives skill at 55%-60; 1 price missing from TSM$",
			ns.View.costLine("B", 1, 90, holes, env)
		)
		assert.equal(
			"B 300 to 300: no estimate (already there)",
			ns.View.costLine("B", 300, 300, nil, env, "already there")
		)
	end)
end)
