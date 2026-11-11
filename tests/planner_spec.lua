-- The planner (Planner.lua) against the design note's unit and scenario cases and its two worked examples.
local F = dofile("tests/fixtures.lua")
local I = F.ITEM

local function load()
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "TSM.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local function crafts(plan)
	local out = {}
	for _, st in ipairs(plan.steps) do
		out[#out + 1] = st.kind == "craft" and (st.name .. " " .. st.source) or st.kind
	end
	return out
end

local function has(list, x)
	for _, v in ipairs(list) do
		if v == x then
			return true
		end
	end
	return false
end

local function verdict(plan, name)
	for _, e in ipairs(plan.fromStock) do
		if e.name == name then
			return e
		end
	end
end

describe("Planner unit cases", function()
	local P
	before_each(function()
		P = load().Planner
	end)

	it("U1 cost per point of Gray Leather Boots at 109 is 1030", function()
		local ctx = P.prepare(F.leather())
		local boots
		for _, o in ipairs(ctx.options) do
			if o.spell == 2167 then
				boots = o
			end
		end
		local c, p, net = P.costPt(ctx, boots, 109, 0, nil, P.chance)
		assert.near(0.64, p, 1e-9)
		assert.equal(639, net)
		assert.near(1030, c, 0.5)
	end)

	it("U2 a yellow recipe at 355 net beats an orange one at 834", function()
		local input = F.input(
			{ [2169] = F.LEATHER[2169], [2168] = F.LEATHER[2168] },
			{ [2169] = true, [2168] = true },
			109,
			110
		)
		local plan = P.run(input)
		assert.equal("Dark Leather Tunic", plan.steps[1].name)
		assert.near(586, plan.steps[1].costPt, 0.5)
		local ctx = P.prepare(input)
		for _, o in ipairs(ctx.options) do
			if o.spell == 2168 then
				assert.near(854, (P.costPt(ctx, o, 109, 0, nil, P.chance)), 0.5)
			end
		end
	end)

	it("U3 the effort charge stops a profitable 17% recipe winning; without it the 17% one wins", function()
		local recipes = { [6418] = F.COOKING[6418], [3398] = F.COOKING[3398] }
		local learned = { [6418] = true, [3398] = true }
		local plan = P.run(F.input(recipes, learned, 173, 174))
		assert.equal("Hot Lion Chops", plan.steps[1].name)
		assert.near(58, plan.steps[1].costPt, 0.5)
		local ctx = P.prepare(F.input(recipes, learned, 173, 174))
		for _, o in ipairs(ctx.options) do
			if o.spell == 6418 then
				assert.near(114, (P.costPt(ctx, o, 173, 0, nil, P.chance)), 0.5)
			end
		end
		plan = P.run(F.input(recipes, learned, 173, 174, {}, { effort = 0 }))
		assert.equal("Crispy Lizard Tail", plan.steps[1].name)
	end)

	it("U4 product value: the first `takes` crafts at AH value, the rest at vendor", function()
		local recipes = { [1] = { name = "Widget", y = 200, g = 220, k = 1, mats = { I.SPICES, 1 }, src = "trainer" } }
		local input = F.input(recipes, { [1] = true }, 100, 112)
		input.product = { [1] = { vendor = 10, sell = 100, takes = 8 } }
		local plan = P.run(input)
		local st = plan.steps[1]
		assert.equal(12, st.crafts)
		assert.equal(8 * 100 + 4 * 10, st.cash.back)
		assert.is_true(has(st.tags, "needs AH sale"))
	end)

	it("U5 a reagent with no price anywhere and none owned skips the recipe and says why", function()
		local recipes = {
			[1] = { name = "Unpriced", y = 120, g = 140, k = 1, mats = { 999, 1 }, src = "trainer" },
			[2] = { name = "Cheap", y = 120, g = 140, k = 1, mats = { I.SPICES, 1 }, src = "trainer" },
		}
		local plan = P.run(F.input(recipes, { [1] = true, [2] = true }, 100, 105))
		assert.same({ "Cheap buy" }, crafts(plan))
		assert.equal(1, #plan.skipped)
		assert.equal("no price for item 999", plan.skipped[1].why)
	end)

	it("U6 the client's grey wins over the thresholds and is counted", function()
		local recipes = { [1] = { name = "Greyed", y = 120, g = 140, k = 1, mats = { I.SPICES, 1 }, src = "trainer" } }
		local input = F.input(recipes, { [1] = true }, 130, 135)
		input.difficulty = { [1] = 3 }
		local plan = P.run(input)
		assert.equal("gap", plan.steps[1].kind)
		assert.equal(1, #plan.colourMismatch)
		assert.same({ spell = 1, client = "grey", data = "green" }, plan.colourMismatch[1])
	end)

	it("U7 parity with skillup.py: same recipe per level with no stock, effort 0, no caps", function()
		-- tools/tsm/tests/test_skillup.py TABLES: Cheap Belt (known, 100/120, 2 Leather + Thread) and Fancy Gloves
		-- (pattern 500c, learn 100, 130/150, 3 Leather). skillup.py says Fancy Gloves 110-120 (pattern bought), and
		-- Cheap Belt 110-120 when the pattern costs 100000.
		local LEATHER, THREAD, PATTERN = 10, 2320, 22
		local recipes = {
			[301] = { name = "Cheap Belt", y = 100, g = 120, k = 1, mats = { LEATHER, 2, THREAD, 1 }, src = "trainer" },
			[302] = {
				name = "Fancy Gloves",
				y = 130,
				g = 150,
				k = 1,
				mats = { LEATHER, 3 },
				src = "item",
				item = PATTERN,
				learn = 100,
			},
		}
		local function run(patternPrice)
			local plan = P.run({
				skill = 110,
				cap = 120,
				recipes = recipes,
				learned = { [301] = true },
				price = {
					[LEATHER] = { buy = 100, where = "ah", salvage = 50 },
					[THREAD] = { buy = 10, where = "vendor", salvage = 2 },
					[PATTERN] = { buy = patternPrice, where = "ah", salvage = 100 },
				},
				product = { [301] = { vendor = 50, takes = 0 }, [302] = { vendor = 60, takes = 0 } },
				effort = 0,
			})
			local names = {}
			for _, st in ipairs(plan.steps) do
				if st.kind == "craft" then
					names[#names + 1] = st.name
				end
			end
			return names, plan
		end
		local names, plan = run(500)
		assert.same({ "Fancy Gloves" }, names)
		assert.equal("buyRecipe", plan.steps[1].kind)
		assert.equal(10, plan.steps[2].crafts)
		assert.same({ "Cheap Belt" }, (run(100000)))
	end)
end)

describe("Planner scenarios", function()
	local P
	local X, Y = 1, 2
	local A = { name = "A", y = 90, g = 110, k = 1, mats = { X, 1 }, src = "trainer" }
	local C = { name = "C", y = 120, g = 140, k = 1, mats = { Y, 1 }, src = "trainer" }
	local B = { name = "B", y = 110, g = 130, k = 1, mats = { X, 1 }, src = "trainer", learn = 105 }
	local function scenario(recipes, learned, have)
		return {
			skill = 100,
			cap = 110,
			recipes = recipes,
			learned = learned,
			price = { [X] = { salvage = 10 }, [Y] = { buy = 50, where = "vendor", salvage = 5 } },
			items = { [X] = { name = "X" }, [Y] = { name = "Y" } },
			have = have,
			effort = 20,
		}
	end
	before_each(function()
		P = load().Planner
	end)

	it("S1 uses stock before its recipe greys", function()
		local plan = P.run(scenario({ [10] = A, [12] = C }, { [10] = true, [12] = true }, { [X] = 5 }))
		assert.same({ "A stock", "C buy" }, crafts(plan))
		local a, c = plan.steps[1], plan.steps[2]
		assert.equal(5, a.crafts)
		assert.near(2.35, a.points, 0.05)
		assert.is_true(has(a.tags, "last use"))
		assert.equal(8, c.crafts)
		assert.same({ { item = Y, count = 8, where = "vendor", each = 50 } }, c.buy)
		assert.near(110, c.to, 1e-9)
		assert.equal(0, #plan.leftovers)
	end)

	it("S2 keeps the stock for a better recipe later", function()
		local plan = P.run(scenario({ [10] = A, [11] = B, [12] = C }, { [10] = true, [12] = true }, { [X] = 5 }))
		assert.same({ "C buy", "train", "B stock" }, crafts(plan))
		assert.equal(5, plan.steps[1].crafts)
		assert.equal(105, plan.steps[2].at)
		assert.equal(5, plan.steps[3].crafts)
		assert.equal("orange", plan.steps[3].color)
		assert.near(5, plan.steps[3].points, 1e-9)
		assert.same({ { item = X, count = 5, spell = 11, name = "B", at = 105 } }, plan.hold)
		assert.equal("later", verdict(plan, "A").verdict)
	end)

	it("S3 a reagent without a price and none owned never appears", function()
		local plan = P.run(scenario({ [10] = A, [12] = C }, { [10] = true, [12] = true }, {}))
		assert.same({ "C buy" }, crafts(plan))
		assert.equal(10, plan.steps[1].crafts)
		assert.equal("A", plan.skipped[1].name)
	end)

	it("S4 Leatherworking 109 with four known recipes: stock first, then buy, then a gap", function()
		local only = {}
		for _, s in ipairs({ 2167, 2168, 2169, 7135 }) do
			only[s] = F.LEATHER[s]
		end
		local plan = P.run(F.input(only, F.LEATHER_LEARNED, 109, 150, { [I.MEDIUM] = 92 }, { noRecipeBuys = true }))
		assert.same({ "Dark Leather Pants stock", "Dark Leather Pants buy", "gap" }, crafts(plan))
		local s1, s2, gap = plan.steps[1], plan.steps[2], plan.steps[3]
		assert.equal(7, s1.crafts)
		assert.equal(3150, s1.cash.out) -- 7 Gray Dye and 7 Fine Thread: 31s 50c
		assert.near(7, s1.points, 1e-9)
		assert.near(116, s1.to, 1e-9)
		assert.is_true(s2.crafts >= 90 and s2.crafts <= 100)
		local medium = s2.buy[1]
		assert.equal(I.MEDIUM, medium.item)
		assert.is_true(medium.count >= 1080 and medium.count <= 1200)
		assert.same({ 140, 150 }, { gap.from, gap.to })
		local boots = verdict(plan, "Gray Leather Boots")
		assert.equal("wasteful", boots.verdict)
		assert.near(461, boots.extra, 1)
		assert.equal(23, boots.crafts)
	end)

	it("S5 TSM returns nil: prices from the export, every step tagged", function()
		local ns = load()
		local _, items = F.prices()
		local plan = {
			items = items,
			vendor = { [I.SPICES] = 40, [I.WATER] = 25 },
			sellShare = 0.5,
		}
		local prof = { recipes = F.COOKING }
		local price, product, counts = ns.TSM.prices(plan, prof, function()
			return nil
		end)
		assert.equal(0, counts.live)
		assert.is_true(counts.export > 5)
		assert.equal(123, price[I.LION].buy)
		assert.is_true(price[I.LION].export)
		local input = F.cooking()
		input.price, input.product, input.items = price, product, items
		local result = ns.Planner.run(input)
		local n = 0
		for _, st in ipairs(result.steps) do
			if st.kind == "craft" then
				n = n + 1
				assert.is_true(has(st.tags, "prices from export"), st.name)
			end
		end
		assert.is_true(n >= 3)
	end)

	it("S6 passes 2 to 4 stay under 2 ms on the Leatherworking fixture with 80 options", function()
		local recipes = {}
		for s, r in pairs(F.LEATHER) do
			recipes[s] = r
		end
		local learned = {}
		for s in pairs(F.LEATHER_LEARNED) do
			learned[s] = true
		end
		for k = 1, 72 do
			local y = 95 + (k % 50)
			recipes[50000 + k] = {
				name = "Filler " .. k,
				y = y,
				g = y + 25,
				k = 1,
				mats = { I.MEDIUM, 2 + k % 7, I.THREAD, 1, I.LIGHT, k % 3 },
				src = "trainer",
			}
			learned[50000 + k] = k % 2 == 0 or nil
		end
		local input = F.input(recipes, learned, 109, 150, { [I.MEDIUM] = 92, [I.LIGHT] = 40 })
		local ctx = P.prepare(input)
		assert.is_true(#ctx.options >= 80)
		local base = P.baseline(ctx)
		local runs = 20
		local t0 = os.clock()
		for _ = 1, runs do
			P.finish(ctx, base, input.have)
		end
		local ms = (os.clock() - t0) * 1000 / runs
		print(("S6: passes 2 to 4 took %.3f ms a run over %d options"):format(ms, #ctx.options))
		assert.is_true(ms < 2, ("%.3f ms"):format(ms))
	end)
end)

describe("Worked examples", function()
	local P
	before_each(function()
		P = load().Planner
	end)

	it("Cooking 173, 7 Lion Meat and 1 Big Bear Meat", function()
		local input = F.cooking()
		local plan = P.run(input)
		print("\nCooking 173 -> 225, 7 Lion Meat, 1 Big Bear Meat")
		for _, l in ipairs(F.describe(plan, input.items)) do
			print("  " .. l)
		end
		assert.same({
			"Big Bear Steak stock",
			"Hot Lion Chops stock",
			"buyRecipe",
			"Rockscale Cod buy",
			"train",
			"Goldthorn Tea buy",
		}, crafts(plan))
		local bear, lion, recipe, cod, _, tea = unpack(plan.steps)
		assert.equal(1, bear.crafts)
		assert.near(0.425, bear.points, 1e-3)
		assert.same({ { item = I.SPICES, count = 1, where = "vendor", each = 40 } }, bear.buy)
		assert.is_true(has(bear.tags, "last use"))
		assert.is_true(has(bear.tags, "chance model")) -- the flat colour guess drops the single steak
		assert.equal(7, lion.crafts)
		assert.near(6.8, lion.points, 0.1)
		assert.near(180.2, lion.to, 0.1)
		assert.equal(280, lion.cash.out)
		assert.equal(2811, recipe.price)
		assert.equal(175, recipe.learn)
		assert.equal("Hot Lion Chops", recipe.alt.name)
		assert.is_true(cod.crafts >= 45 and cod.crafts <= 52)
		assert.is_true(has(tea.tags, "needs AH sale"))
		assert.near(225, tea.to, 1e-9)
		assert.equal(0, #plan.leftovers)
		assert.equal("Thunder Lizard Tail", input.items[I.TAIL].name)
		for _, st in ipairs(plan.steps) do
			assert.is_not.equal("Crispy Lizard Tail", st.name)
		end
	end)

	it("Cooking 173 with 60 Lion Meat rations the meat and lists the rest as leftovers", function()
		local input = F.cooking({ [I.LION] = 60, [I.BEAR] = 1 })
		local plan = P.run(input)
		print("\nCooking 173 -> 225, 60 Lion Meat, 1 Big Bear Meat")
		for _, l in ipairs(F.describe(plan, input.items)) do
			print("  " .. l)
		end
		local lion = plan.steps[2]
		assert.equal("Hot Lion Chops", lion.name)
		assert.is_true(lion.crafts >= 33 and lion.crafts <= 37)
		assert.equal(I.LION, plan.leftovers[1].item)
		assert.is_true(plan.leftovers[1].count >= 23 and plan.leftovers[1].count <= 27)
	end)

	it("Leatherworking 109, 92 Medium Leather", function()
		local input = F.leather()
		local plan = P.run(input)
		print("\nLeatherworking 109 -> 150, 92 Medium Leather")
		for _, l in ipairs(F.describe(plan, input.items)) do
			print("  " .. l)
		end
		local seq = crafts(plan)
		assert.equal("Light Leather Pants buy", seq[1])
		assert.equal("buyRecipe", seq[2])
		assert.equal("Dark Leather Shoulders mixed", seq[3])
		assert.equal("Dark Leather Shoulders buy", seq[4])
		assert.equal("train", seq[5])
		assert.equal("Heavy Leather Ammo Pouch buy", seq[6])
		local llp = plan.steps[1]
		assert.same({ { item = I.CURED, count = llp.crafts, spell = 3816 } }, llp.pre)
		assert.equal("Dark Leather Pants", llp.alt.name)
		assert.is_true(llp.alt.extra > 1500 and llp.alt.extra < 4500) -- "about 30s more"
		assert.equal(7, plan.steps[3].crafts)
		assert.same(
			{ { item = I.MEDIUM, count = 92, spell = 3769, name = "Dark Leather Shoulders", at = 115 } },
			plan.hold
		)
		assert.equal("alternative", verdict(plan, "Dark Leather Pants").verdict)
		for _, n in ipairs({ "Dark Leather Tunic", "Dark Leather Cloak", "Gray Leather Boots" }) do
			assert.equal("wasteful", verdict(plan, n).verdict)
		end
	end)
end)
