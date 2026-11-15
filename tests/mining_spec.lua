-- Mining where smelting gives no points: the plan shows node stretches drawn from Where's route (world steps, no
-- gold), never a red hole, in the planner, costToCap, the path lines, the panel strip and the cost line.
local function load(files)
	local ns = {}
	for _, f in ipairs(files) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local RANKS = {
	{ name = "Apprentice", cap = 75, cost = 10, where = "trainer" },
	{ name = "Journeyman", cap = 150, skill = 50, cost = 500, where = "trainer" },
	{ name = "Expert", cap = 225, skill = 125, cost = 5000, where = "trainer" },
	{ name = "Artisan", cap = 300, skill = 200, cost = 50000, where = "trainer" },
}

describe("Planner world stretches (input.world)", function()
	local P
	before_each(function()
		P = load({ "Logic.lua", "Planner.lua" }).Planner
	end)

	local function input(world)
		return {
			skill = 1,
			cap = 80,
			recipes = { [1] = { name = "Smelt", y = 30, g = 50, k = 1, mats = { 10, 1 }, src = "auto" } },
			learned = { [1] = true },
			price = { [10] = { buy = 5, where = "vendor", salvage = 0 } },
			items = { [10] = { name = "Ore" } },
			have = {},
			effort = 20,
			world = world,
		}
	end

	it(
		"splits a hole by the world stretches: a world step where nodes give points, a gap where nothing does",
		function()
			local plan = P.run(
				input({ { from = 50, to = 70, text = "Mine nodes: Testlands", spot = "s1", why = "from mining nodes" } })
			)
			local kinds = {}
			for _, st in ipairs(plan.steps) do
				if st.kind == "world" or st.kind == "gap" then
					kinds[#kinds + 1] = ("%s %d-%d"):format(st.kind, st.from, st.to)
				end
			end
			assert.same({ "world 50-70", "gap 70-80" }, kinds)
			local w
			for _, st in ipairs(plan.steps) do
				w = st.kind == "world" and st or w
			end
			assert.equal("Mine nodes: Testlands", w.name)
			assert.equal("s1", w.spot)
			assert.equal("from mining nodes", w.why)
			-- without world stretches the whole stretch is one gap, as before
			local none = {}
			for _, st in ipairs(P.run(input(nil)).steps) do
				if st.kind == "gap" then
					none[#none + 1] = ("%d-%d"):format(st.from, st.to)
				end
			end
			assert.same({ "50-80" }, none)
		end
	)

	it("costToCap lists world stretches apart: no gold, no gap", function()
		local inp = input(nil)
		local prof = { recipes = inp.recipes }
		local opts = {
			price = inp.price,
			items = inp.items,
			cap = 80,
			learned = inp.learned,
			world = { { from = 50, to = 80, text = "Mine nodes", why = "from mining nodes" } },
		}
		local with = P.costToCap(prof, 1, 80, nil, opts)
		assert.same({}, with.gaps)
		assert.is_true(with.complete)
		assert.same({ { from = 50, to = 80, text = "Mine nodes", why = "from mining nodes" } }, with.world)
		opts.world = nil
		local without = P.costToCap(prof, 1, 80, nil, opts)
		assert.equal(1, #without.gaps)
		-- a world stretch costs nothing: the totals agree
		assert.equal(without.total, with.total)
	end)
end)

describe("Mining with the shipped data", function()
	local ns, data
	setup(function()
		ns = load({
			"Data/Recipes.lua",
			"Data/Spots.lua",
			"Logic.lua",
			"Guide.lua",
			"Planner.lua",
			"View.lua",
			"Where.lua",
		})
		data = ns.Data.recipes
	end)

	local function cost(world)
		return ns.Planner.costToCap(data.professions[186], 1, 300, function()
			return 100
		end, { vendor = data.vendor, items = data.items, ranks = RANKS, world = world })
	end

	local function stretches(faction)
		return ns.Where.worldStretches(
			{ data = ns.Data.spots, line = 186, skill = 1, level = 60, faction = faction },
			1,
			300
		)
	end

	it("smelting alone leaves holes (140-155, 185-300 today)", function()
		assert.is_true(#cost(nil).gaps > 0)
	end)

	for _, faction in ipairs({ "Alliance", "Horde" }) do
		it(("fills every smelting hole from mining nodes (%s)"):format(faction), function()
			local w = stretches(faction)
			assert.is_true(#w > 0)
			for _, s in ipairs(w) do
				assert.is_true(s.to > s.from)
				assert.matches("^Mine nodes", s.text)
				assert.equal("from mining nodes", s.why)
			end
			local r = cost(w)
			assert.same({}, r.gaps)
			assert.is_true(r.complete)
			assert.is_true(#r.world > 0)
			-- the path lines, the panel strip and the cost line say nodes, never a hole
			local lines = ns.Where.lines(r.steps, {})
			local worldLines = 0
			for _, l in ipairs(lines) do
				assert.is_not.equal("gap", l.kind, l.title)
				worldLines = worldLines + (l.kind == "world" and 1 or 0)
			end
			assert.is_true(worldLines > 0)
			local strip = ns.View.strip(lines, 1, { money = ns.Logic.money })
			assert.equal(0, strip.gaps)
			for _, seg in ipairs(strip.segments) do
				assert.is_nil(seg.gap)
			end
			local text = ns.View.costLine("Mining", 1, 300, r, { money = ns.Logic.money })
			assert.matches("complete", text, 1, true)
			assert.matches("from mining nodes", text, 1, true)
		end)
	end
end)
