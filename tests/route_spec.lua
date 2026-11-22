-- Planner rule 4: the guide is the route (input.route, Data/Routes.lua). Synthetic recipes first, then the shipped
-- Leatherworking and Cooking data planned along the shipped routes.
local function load(files)
	local ns = {}
	for _, f in ipairs(files or { "Logic.lua", "Planner.lua", "TSM.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local M1, M2, M3, M4, PAT = 11, 12, 13, 14, 15

-- orange from 100 to 200: one point a craft everywhere in these tests, so only the price decides
local function recipe(name, mat, extra)
	local r = { name = name, y = 200, g = 250, k = 1, mats = { mat, 1 }, src = "trainer" }
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	return r
end

local function input(recipes, learned, extra)
	local inp = {
		skill = 100,
		cap = 120,
		recipes = recipes,
		learned = learned,
		price = {
			[M1] = { buy = 10, where = "ah", salvage = 1 },
			[M2] = { buy = 30, where = "ah", salvage = 1 },
			[M3] = { buy = 40, where = "ah", salvage = 1 },
			[M4] = { buy = 5, where = "ah", salvage = 1 },
			[PAT] = { buy = 100000, where = "ah", salvage = 1 },
		},
		effort = 20,
	}
	for k, v in pairs(extra or {}) do
		inp[k] = v
	end
	return inp
end

local function crafts(plan)
	local out = {}
	for _, st in ipairs(plan.steps) do
		if st.kind == "craft" then
			out[#out + 1] = st.spell
		end
	end
	return out
end

local function kinds(plan)
	local out = {}
	for _, st in ipairs(plan.steps) do
		out[#out + 1] = st.kind
	end
	return out
end

-- A (1) is the cheapest and off the guide; B (2) the guide's pick; C (3) its alternative.
local ABC = { [1] = recipe("A", M1), [2] = recipe("B", M2), [3] = recipe("C", M3) }
local LEARNED = { [1] = true, [2] = true, [3] = true }
local function route(...)
	return { ... }
end

describe("Planner rule 4: the guide is the route", function()
	local P
	before_each(function()
		P = load().Planner
	end)

	it("plans without a route exactly as before: the cheapest recipe, no guide marks", function()
		local plan = P.run(input(ABC, LEARNED))
		assert.same({ 1 }, crafts(plan))
		assert.is_nil(plan.steps[1].guide)
		assert.is_nil(plan.steps[1].offGuide)
		assert.is_nil(plan.guide)
	end)

	it("restricts the pick to the guide's recipe even when an off-guide one is cheaper", function()
		local plan = P.run(input(ABC, LEARNED, { route = route({ from = 100, to = 120, spell = 2 }) }))
		assert.same({ 2 }, crafts(plan))
		assert.is_true(plan.steps[1].guide)
		assert.is_nil(plan.steps[1].guideAlt)
		assert.same({ steps = 1, onGuide = 1, offGuide = 0 }, plan.guide)
		-- the cheaper recipe is still offered as another way (the user may swap to it)
		assert.equal(1, plan.steps[1].others[1].spell)
		assert.is_nil(plan.steps[1].others[1].guide)
	end)

	it("chooses the guide's alternative when it is cheaper, and marks the step guide alt", function()
		local recipes = { [1] = recipe("A", M4), [2] = recipe("B", M3), [3] = recipe("C", M2) }
		local plan = P.run(input(recipes, LEARNED, {
			route = route({ from = 100, to = 120, spell = 2 }, { from = 100, to = 120, spell = 3, alt = true }),
		}))
		assert.same({ 3 }, crafts(plan))
		assert.is_true(plan.steps[1].guide)
		assert.is_true(plan.steps[1].guideAlt)
	end)

	it("lets owned stock pick the guide's alternative, never an off-guide recipe", function()
		local r = route({ from = 100, to = 120, spell = 2 }, { from = 100, to = 120, spell = 3, alt = true })
		-- 100 M3 owned: the dearer alternative from stock beats buying the guide's main pick
		local stocked = P.run(input(ABC, LEARNED, { route = r, have = { [M3] = 100 } }))
		assert.same({ 3 }, crafts(stocked))
		assert.equal("stock", stocked.steps[1].source)
		assert.is_true(stocked.steps[1].guideAlt)
		-- 100 M1 owned: A would be free, but it is not the guide's; the plan stays on B and offers no A as "use stock"
		local off = P.run(input(ABC, LEARNED, { route = r, have = { [M1] = 100 } }))
		assert.same({ 2 }, crafts(off))
		assert.is_true(off.steps[1].guide)
		assert.is_true(off.steps[1].alt == nil or off.steps[1].alt.spell ~= 1)
		-- without the route the same bags craft A from stock
		assert.same({ 1 }, crafts(P.run(input(ABC, LEARNED, { have = { [M1] = 100 } }))))
	end)

	it("filters the guide's rows by faction", function()
		local recipes = { [1] = recipe("A", M1), [2] = recipe("B", M2), [4] = recipe("D", M4) }
		local learned = { [1] = true, [2] = true, [4] = true }
		local r = route({ from = 100, to = 120, spell = 2 }, { from = 100, to = 120, spell = 4, faction = "horde" })
		assert.same({ 4 }, crafts(P.run(input(recipes, learned, { route = r, faction = "Horde" }))))
		assert.same({ 2 }, crafts(P.run(input(recipes, learned, { route = r, faction = "Alliance" }))))
		-- only the other faction's row covers the skill: off the guide (the cheapest recipe), and it says so
		local only = P.run(input(recipes, learned, {
			route = route({ from = 100, to = 120, spell = 4, faction = "horde" }),
			faction = "Alliance",
		}))
		assert.same({ 4 }, crafts(only))
		assert.is_nil(only.steps[1].guide)
		assert.equal("the guide's recipes here are the other faction's", only.steps[1].offGuide)
	end)

	it("falls back off the guide with a reason where the guide's recipe is grey", function()
		local recipes = { [1] = recipe("A", M1), [5] = recipe("E", M2, { y = 100, g = 110 }) }
		local plan = P.run(input(recipes, { [1] = true, [5] = true }, {
			route = route({ from = 100, to = 120, spell = 5 }),
		}))
		local steps = {}
		for _, st in ipairs(plan.steps) do
			if st.kind == "craft" then
				steps[#steps + 1] = st
			end
		end
		assert.equal(5, steps[1].spell)
		assert.is_true(steps[1].guide)
		local last = steps[#steps]
		assert.equal(1, last.spell)
		assert.is_nil(last.guide)
		assert.equal("the guide's recipes are grey here", last.offGuide)
		assert.equal(1, plan.guide.offGuide)
		assert.matches("the guide's recipes are grey here$", plan.guide.lastOffGuide)
	end)

	it("says the guide has nothing for a level it does not cover", function()
		local plan = P.run(input(ABC, LEARNED, { route = route({ from = 100, to = 110, spell = 2 }) }))
		assert.same({ 2, 1 }, crafts(plan))
		assert.is_true(plan.steps[1].guide)
		assert.equal("the guide has nothing for this level", plan.steps[2].offGuide)
	end)

	it("lets the user's swap win over the guide and marks the step off the guide", function()
		local plan = P.run(input(ABC, LEARNED, {
			route = route({ from = 100, to = 120, spell = 2 }),
			exclude = { swap = { [2] = 1 } },
		}))
		assert.same({ 1 }, crafts(plan))
		assert.equal(2, plan.steps[1].swapFrom)
		assert.equal("you chose this recipe instead", plan.steps[1].offGuide)
	end)

	it("lets the user's 'not now' win over the guide, with the reason", function()
		local plan = P.run(input(ABC, LEARNED, {
			route = route({ from = 100, to = 120, spell = 2 }),
			exclude = { notNow = { [2] = true } },
		}))
		assert.same({ 1 }, crafts(plan))
		assert.equal("you left the guide's recipe out", plan.steps[1].offGuide)
	end)

	it("plans a gated recipe the guide names (a special teacher) at the guide's skills only", function()
		local recipes = {
			[1] = recipe("A", M1),
			[2] = recipe("B", M2),
			[6] = recipe("Special", M4, { src = "special", teacher = "a quest", learn = 100 }),
		}
		local learned = { [1] = true, [2] = true }
		-- without the guide it is a shortcut only
		assert.same({ 1 }, crafts(P.run(input(recipes, learned))))
		-- learnable later than the guide uses it: off the guide, and the step says why
		recipes[6].learn = 150
		local late = P.run(input(recipes, learned, { route = route({ from = 100, to = 110, spell = 6 }) }))
		assert.same({ 1 }, crafts(late))
		assert.equal("the guide's recipe is learned at 150", late.steps[1].offGuide)
		recipes[6].learn = 100
		local plan = P.run(input(recipes, learned, { route = route({ from = 100, to = 110, spell = 6 }) }))
		assert.same({ "buyRecipe", "craft", "craft" }, kinds(plan))
		assert.same({ 6, 1 }, crafts(plan))
		assert.equal("source", plan.steps[1].where)
		assert.equal("a quest", plan.steps[1].source)
		assert.is_true(plan.steps[2].guide)
		-- past the guide's stretch the special recipe is not planned, cheapest as it is
		assert.equal("the guide has nothing for this level", plan.steps[3].offGuide)
	end)

	it("buys a recipe item the guide names whatever it saves", function()
		local recipes = {
			[1] = recipe("A", M2),
			[7] = recipe("Pattern", M1, { src = "item", item = PAT, learn = 100 }),
		}
		local learned = { [1] = true }
		-- 20 crafts saving 20c each never pay for a 10g pattern: without the guide it is not bought
		assert.same({ 1 }, crafts(P.run(input(recipes, learned))))
		local plan = P.run(input(recipes, learned, { route = route({ from = 100, to = 120, spell = 7 }) }))
		assert.same({ "buyRecipe", "craft" }, kinds(plan))
		assert.equal(PAT, plan.steps[1].item)
		assert.equal(100000, plan.steps[1].price)
		assert.is_nil(plan.steps[1].saves)
		assert.same({ 7 }, crafts(plan))
		assert.is_true(plan.steps[2].guide)
	end)

	it("keeps the guide when recipe buys are off only for recipes it need not buy", function()
		local recipes = {
			[1] = recipe("A", M2),
			[7] = recipe("Pattern", M1, { src = "item", item = PAT, learn = 100 }),
		}
		local plan = P.run(input(recipes, { [1] = true }, {
			route = route({ from = 100, to = 120, spell = 7 }),
			noRecipeBuys = true,
		}))
		assert.same({ 1 }, crafts(plan))
		assert.equal("recipe buys are off (/skillup recipes on)", plan.steps[1].offGuide)
	end)

	it("costToCap passes the route through", function()
		local prof = { recipes = ABC, ranks = {} }
		local function price(i)
			return ({ [M1] = 10, [M2] = 30, [M3] = 40 })[i]
		end
		local learned = { learned = LEARNED, cap = 120 }
		local free = P.costToCap(prof, 100, 120, price, learned)
		assert.equal(1, free.steps[1].spell)
		learned.route = route({ from = 100, to = 120, spell = 3 })
		local guided = P.costToCap(prof, 100, 120, price, learned)
		assert.equal(3, guided.steps[1].spell)
		assert.is_true(guided.steps[1].guide)
	end)
end)

describe("The card shows the guide", function()
	local ns
	before_each(function()
		ns = load({ "Logic.lua", "Planner.lua", "TSM.lua", "View.lua", "Where.lua" })
	end)

	local env = {
		nameOf = function(item, fallback)
			return fallback or ("item " .. item)
		end,
		money = function(c)
			return tostring(c) .. "c"
		end,
		have = function()
			return 0
		end,
	}

	local function card(r)
		local p = ns.Planner.run(input(ABC, LEARNED, { route = r }))
		p.prices, p.ageHours = { live = 3, export = 0, none = 0 }, 1
		return ns.View.describe({ profession = "Test", skill = 100, maxSkill = 120, planner = p }, env).now
	end

	it("tags a guide step, a guide alternative, and says why a step is off the guide", function()
		assert.matches(", Guide$", card(route({ from = 100, to = 120, spell = 2 })).sub)
		assert.matches(", Guide alt$", card(route({ from = 100, to = 120, spell = 3, alt = true })).sub)
		local off = card(route({ from = 110, to = 120, spell = 2 }))
		assert.is_nil(off.sub:find("Guide", 1, true))
		local said = false
		for _, l in ipairs(off.lines) do
			said = said or l.text == "Off guide: the guide has nothing for this level"
		end
		assert.is_true(said)
	end)
end)

-- The shipped data along the shipped routes, every reagent and recipe item at one flat price: every craft step is on
-- the guide. The steps are printed so the route can be read in the test output.
describe("Shipped routes (Data/Routes.lua) over the shipped recipes", function()
	local P, data
	before_each(function()
		local ns = load()
		P = ns.Planner
		data = {}
		assert(loadfile("Data/Recipes.lua"))("SkillupHelper", data)
		assert(loadfile("Data/Routes.lua"))("SkillupHelper", data)
	end)

	local function flat()
		return 100
	end

	local function plan(line, from, to, faction)
		local rs = data.Data.recipes
		local prof = rs.professions[line]
		local r = P.costToCap(prof, from, to, flat, {
			cap = to,
			items = rs.items,
			faction = faction,
			route = data.Data.routes[line],
		})
		local lines = { ("%s %d-%d (%s):"):format(prof.name, from, to, faction) }
		local off = {}
		for _, st in ipairs(r.steps) do
			if st.kind == "craft" then
				local tag = st.guide and (st.guideAlt and "guide alt" or "guide") or ("OFF: " .. tostring(st.offGuide))
				lines[#lines + 1] = ("  %3d-%3d  %3dx %s [%s]"):format(
					math.floor(st.from),
					math.floor(st.to + 0.5),
					st.crafts,
					st.name,
					tag
				)
				if not st.guide then
					off[#off + 1] = lines[#lines]
				end
			elseif st.kind == "buyRecipe" then
				lines[#lines + 1] = ("  get recipe %s (learn %s)"):format(tostring(st.name), tostring(st.learn))
			elseif st.kind == "train" then
				lines[#lines + 1] = ("  train %s at %s"):format(tostring(st.name), tostring(st.at))
			elseif st.kind == "gap" then
				lines[#lines + 1] = ("  GAP %d-%d: %s"):format(st.from, st.to, tostring(st.why))
				off[#off + 1] = lines[#lines]
			end
		end
		print("\n" .. table.concat(lines, "\n"))
		return r, off
	end

	it("has a route for Leatherworking and Cooking, every spell a recipe of its line", function()
		assert.matches("^wow%-professions%.com, Forever section, %d+%-%d+%-%d+$", data.Data.routes.source)
		for _, line in ipairs({ 165, 185 }) do
			local recipes = data.Data.recipes.professions[line].recipes
			assert.is_true(#data.Data.routes[line] > 0)
			for _, e in ipairs(data.Data.routes[line]) do
				assert.is_truthy(recipes[e.spell], "spell " .. e.spell .. " of line " .. line)
				assert.is_true(e.to > e.from)
			end
		end
	end)

	it("Leatherworking 162-225 (Horde) stays on the guide", function()
		local _, off = plan(165, 162, 225, "Horde")
		assert.same({}, off)
	end)

	it("Leatherworking 225-300 (Horde) stays on the guide", function()
		local _, off = plan(165, 225, 300, "Horde")
		assert.same({}, off)
	end)

	it("Cooking 225-300 (Horde) stays on the guide", function()
		local _, off = plan(185, 225, 300, "Horde")
		assert.same({}, off)
	end)
end)
