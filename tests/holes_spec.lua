-- A missing price or a gated recipe is never a hole (the owner's rule): the shipped data planned with live-shaped
-- prices (TSM.prices over a price function that returns nil for some items), and the step order the panel relies on.
-- In game, Blacksmithing at skill 28 showed "No recipe gives skill 185 to 215": the trainer window had listed only the
-- recipes learnable at 28, and every trainer recipe it did not list was gated.
local function load()
	local ns = {}
	for _, f in ipairs({ "Data/Recipes.lua", "Logic.lua", "Planner.lua", "TSM.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local BLACKSMITHING = 164
-- Steel Bar, Solid Stone, Mithril Bar, Citrine, Gold Bar
local MID = { [3859] = true, [7912] = true, [3860] = true, [3864] = true, [3577] = true }
local MARKET = { dbmarket = true, dbminbuyout = true, dbregionmarketavg = true }
local REASONS = { norecipe = true, recipesOff = true, excluded = true, level = true }

describe("no false hole", function()
	local ns, data, P
	setup(function()
		ns = load()
		data, P = ns.Data.recipes, ns.Planner
	end)

	-- TradeSkillMaster's answer per item: a market price, or nil for the items `none(item)` names (what TSM.value
	-- returns when AuctionDB has nothing). Vendor prices come from the data's own vendor table.
	local function getter(none)
		return function(source, item)
			if not MARKET[source] or (none and none(item)) then
				return nil
			end
			return 100 + item % 37
		end
	end

	local function recipeItems(prof)
		local set = {}
		for _, r in pairs(prof.recipes) do
			if r.item then
				set[r.item] = true
			end
		end
		return set
	end

	-- The price functions the hole was hunted with: every price, none for anything a vendor does not sell, none for
	-- a handful of mid-level reagents, none for the recipe items.
	local function modes(prof)
		local patterns = recipeItems(prof)
		return {
			{ name = "every price" },
			{
				name = "no auction price at all",
				none = function()
					return true
				end,
			},
			{
				name = "no price for mid-level reagents",
				none = function(item)
					return MID[item] == true
				end,
			},
			{
				name = "no price for recipe items",
				none = function(item)
					return patterns[item] == true
				end,
			},
		}
	end

	-- Scan.runPlanner's input for a profession entry of the shipped data: the recipes learned with the profession,
	-- prices through TSM.prices for the recipes not grey yet, the data's default ranks.
	local function plan(prof, skill, none, extra)
		local learned = {}
		for spell, r in pairs(prof.recipes) do
			if r.src == "auto" then
				learned[spell] = true
			end
		end
		local priced = { name = prof.name, recipes = {} }
		for spell, r in pairs(prof.recipes) do
			if learned[spell] or (not r.gone and (type(r.g) ~= "number" or r.g > skill)) then
				priced.recipes[spell] = r
			end
		end
		-- an item TradeSkillMaster has no price for comes back as { buy = false } (and is counted as "live")
		local price, product = ns.TSM.prices(data, priced, getter(none), 0.5)
		local cap = 300
		for _, rk in ipairs(prof.ranks or {}) do
			if rk.cap > skill and rk.cap < cap then
				cap = rk.cap
			end
		end
		local input = {
			skill = skill,
			cap = cap,
			target = 300,
			level = 60,
			ranks = prof.ranks,
			recipes = prof.recipes,
			items = data.items,
			learned = learned,
			price = price,
			product = product,
			faction = "Alliance",
			have = {},
		}
		for k, v in pairs(extra or {}) do
			input[k] = v
		end
		return P.run(input)
	end

	local function gapsOf(p)
		local out = {}
		for _, st in ipairs(p.steps) do
			if st.kind == "gap" then
				out[#out + 1] = st
			end
		end
		return out
	end

	local function gapText(p)
		local out = {}
		for _, g in ipairs(gapsOf(p)) do
			out[#out + 1] = ("%d-%d (%s)"):format(g.from, g.to, tostring(g.reason))
		end
		return table.concat(out, ", ")
	end

	-- What the trainer window lists when it hides the recipes the character cannot learn yet.
	local function listedAt(prof, skill)
		local seen = {}
		for spell, r in pairs(prof.recipes) do
			if r.src == "trainer" and (r.learn or r.y) <= skill then
				seen[spell] = true
			end
		end
		return seen
	end

	it("Blacksmithing from 28 and from 1 has no hole to 300, whatever TradeSkillMaster cannot price", function()
		local prof = data.professions[BLACKSMITHING]
		for _, skill in ipairs({ 28, 1 }) do
			for _, mode in ipairs(modes(prof)) do
				local p = plan(prof, skill, mode.none)
				local at = ("from %d, %s"):format(skill, mode.name)
				assert.equal(300, p.cap, at)
				assert.equal("", gapText(p), at)
				local last
				for _, st in ipairs(p.steps) do
					last = st.to or last
				end
				assert.near(300, last, 1e-6, at)
			end
		end
	end)

	it(
		"the trainer list read at 28 (learnable recipes only) gates nothing above it: no hole, no bought detour",
		function()
			local prof = data.professions[BLACKSMITHING]
			local free = plan(prof, 28)
			local p = plan(prof, 28, nil, { trainerSeen = listedAt(prof, 28) })
			assert.equal("", gapText(p))
			local function crafts(q)
				local out = {}
				for _, st in ipairs(q.steps) do
					if st.kind == "craft" then
						out[#out + 1] = ("%s %d-%d x%d"):format(st.name, st.from, st.to, st.crafts)
					end
				end
				return out
			end
			-- the same plan as with no trainer read at all
			assert.same(crafts(free), crafts(p))
			for _, st in ipairs(p.steps) do
				assert.is_nil(st.gated, st.name)
				assert.is_nil(st.unchecked, st.name)
			end
		end
	)

	it("a step that buys an unpriced reagent lists it, and the plan totals them", function()
		local prof = data.professions[BLACKSMITHING]
		local p = plan(prof, 28, function()
			return true
		end)
		local byItem, steps = {}, 0
		for _, st in ipairs(p.steps) do
			if st.kind == "craft" then
				local rows = {}
				for _, b in ipairs(st.buy) do
					if b.each == nil then
						assert.is_true(b.unpriced)
						rows[#rows + 1] = b.item
					else
						assert.is_nil(b.unpriced)
					end
				end
				local listed = {}
				for _, u in ipairs(st.unpriced or {}) do
					listed[#listed + 1] = u.item
					-- named from the data's items; a reagent the generated items table lacks (211422, found with
					-- resale off) has no name here and the panel asks the client for it
					assert.is_true(type(u.name) == "string" or data.items[u.item] == nil, tostring(u.item))
					assert.is_true(u.count > 0)
					byItem[u.item] = (byItem[u.item] or 0) + u.count
				end
				assert.same(rows, listed, st.name)
				steps = steps + (#listed > 0 and 1 or 0)
			end
		end
		assert.is_true(steps > 0)
		local n = 0
		for _ in pairs(byItem) do
			n = n + 1
		end
		assert.equal(n, p.unpriced.count)
		assert.equal(n, #p.unpriced.items)
		for _, e in ipairs(p.unpriced.items) do
			assert.is_nil(e.recipe)
			assert.equal(byItem[e.item], e.count)
			assert.is_true(type(e.name) == "string" or data.items[e.item] == nil, tostring(e.item))
		end
		-- every price known: nothing unpriced, on the plan or on a step
		local full = plan(prof, 28)
		assert.same({ count = 0, items = {} }, full.unpriced)
		for _, st in ipairs(full.steps) do
			assert.is_nil(st.unpriced)
		end
		-- the cost to the cap carries the same table
		local r = P.costToCap(prof, 28, 300, function() end, { vendor = data.vendor, items = data.items, cap = 75 })
		assert.same({}, r.gaps)
		assert.is_true(r.unpriced.count > 0)
	end)

	it("no crafting profession gets a hole from a missing price: only the holes it has with every price", function()
		local ids = {}
		for id, prof in pairs(data.professions) do
			if not prof.side then
				ids[#ids + 1] = id
			end
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local prof = data.professions[id]
			local real = {}
			for _, mode in ipairs(modes(prof)) do
				local p = plan(prof, 1, mode.none)
				local at = ("%s, %s"):format(prof.name, mode.name)
				for _, g in ipairs(gapsOf(p)) do
					assert.is_true(REASONS[g.reason] == true, at .. ": reason " .. tostring(g.reason))
					assert.is_string(g.why)
					for s = g.from, g.to - 1 do
						if not mode.none then
							real[s] = true
						end
						-- a level that is a hole without some price is a hole with every price too
						assert.is_true(real[s] == true, ("%s: %d is a hole only without prices"):format(at, s))
					end
				end
				if not mode.none and #gapsOf(p) > 0 then
					print(("REAL HOLES %s: %s"):format(prof.name, gapText(p)))
				end
				if not mode.none and p.cap < 300 and not prof.world then
					print(("STOPS %s at %d"):format(prof.name, p.cap))
				end
			end
		end
	end)

	describe("the step order", function()
		local function check(p, skill, at)
			local steps = p.steps
			local crafted = {}
			for i, st in ipairs(steps) do
				if st.kind == "train" or st.kind == "buyRecipe" then
					-- the step that gets recipe X sits immediately before the first craft of X
					local nx = steps[i + 1]
					assert.is_true(nx ~= nil and nx.kind == "craft" and nx.spell == st.spell, at .. ": " .. st.name)
					assert.is_nil(crafted[st.spell], at .. ": " .. st.name .. " crafted before it is learned")
				elseif st.kind == "craft" then
					crafted[st.spell] = true
				elseif st.kind == "trainRank" then
					if skill >= st.by then
						-- the cap is reached already: nothing but rank training before it
						for j = 1, i - 1 do
							assert.equal("trainRank", steps[j].kind, at)
						end
					else
						-- where its cap is reached: the next craft is the first step that ends past the old cap
						local j = i + 1
						while steps[j] and (steps[j].kind == "train" or steps[j].kind == "buyRecipe") do
							j = j + 1
						end
						local nx = steps[j]
						assert.is_true(nx ~= nil and (nx.kind == "craft" or nx.kind == "gap"), at .. ": " .. st.name)
						assert.is_true(nx.to > st.by and nx.from <= st.by, at .. ": " .. st.name)
						assert.is_true(nx.from >= (st.at or st.by), at .. ": " .. st.name)
						assert.equal(nx.from, st.skill, at)
						for k = 1, i - 1 do
							assert.is_true(
								(steps[k].to or 0) <= st.by,
								at .. ": a step crosses the cap before " .. st.name
							)
						end
					end
				end
			end
		end

		it("on the shipped Blacksmithing plan: recipe then its craft, a rank where its cap is reached", function()
			local prof = data.professions[BLACKSMITHING]
			for _, skill in ipairs({ 28, 1 }) do
				for _, mode in ipairs(modes(prof)) do
					local p = plan(prof, skill, mode.none)
					local at = ("from %d, %s"):format(skill, mode.name)
					check(p, skill, at)
					-- each rank once: its own step, or carried by the one step that runs across its whole window
					local ranks = {}
					for _, st in ipairs(p.steps) do
						if st.kind == "trainRank" then
							ranks[#ranks + 1] = st.name
						elseif st.rankUp then
							ranks[#ranks + 1] = st.rankUp.name
						end
					end
					assert.same({ "Journeyman", "Expert", "Artisan" }, ranks, at)
				end
			end
			check(plan(prof, 28, nil, { trainerSeen = listedAt(prof, 28) }), 28, "trainer read at 28")
		end)
	end)
end)

describe("holes and fallbacks, constructed", function()
	local P
	before_each(function()
		P = load().Planner
	end)
	local M1, M2, NONE, PAT = 11, 12, 999, 15
	local function recipe(name, mat, extra)
		local r = { name = name, y = 100, g = 140, k = 1, mats = { mat, 1 }, src = "trainer" }
		for k, v in pairs(extra or {}) do
			r[k] = v
		end
		return r
	end
	local function input(recipes, learned, extra)
		local inp = {
			skill = 100,
			cap = 110,
			recipes = recipes,
			learned = learned or {},
			items = { [NONE] = { name = "Rare Thing" } },
			price = {
				[M1] = { buy = 50, where = "ah", salvage = 1 },
				[M2] = { buy = 60, where = "ah", salvage = 1 },
				-- TSM.prices' entry for an item with no price
				[NONE] = { salvage = 0 },
				[PAT] = { buy = 100, where = "ah", salvage = 1 },
			},
			effort = 20,
		}
		for k, v in pairs(extra or {}) do
			inp[k] = v
		end
		return inp
	end
	local function kinds(p)
		local out = {}
		for _, st in ipairs(p.steps) do
			out[#out + 1] = st.kind .. (st.spell and (" " .. st.spell) or "")
		end
		return out
	end

	it("a stretch no recipe covers is the true hole: reason norecipe", function()
		local p = P.run(input({ [1] = recipe("R1", M1, { g = 105 }) }, { [1] = true }))
		assert.same({ "craft 1", "gap" }, kinds(p))
		local gap = p.steps[2]
		assert.same({ 105, 110, "norecipe" }, { gap.from, gap.to, gap.reason })
		assert.equal("no recipe gives skill here", gap.why)
		-- a recipe that needs an item missing from the game data is no recipe
		p = P.run(input({ [1] = recipe("R1", M1, { gone = true }) }))
		assert.same({ "gap" }, kinds(p))
		assert.equal("norecipe", p.steps[1].reason)
	end)

	it("a recipe whose reagent has no price is planned, never a hole, and names the reagent", function()
		local p = P.run(input({ [1] = recipe("R1", NONE) }, { [1] = true }))
		assert.same({ "craft 1" }, kinds(p))
		local st = p.steps[1]
		assert.same({ { item = NONE, name = "Rare Thing", count = st.crafts } }, st.unpriced)
		assert.is_true(st.buy[1].unpriced)
		assert.is_nil(st.gated)
		-- its cost counts what has a price: the effort only, never an invented price
		assert.equal(0, st.cash.out)
		assert.is_true(st.costPt >= 20 and st.costPt < 30)
		assert.same({ count = 1, items = { { item = NONE, name = "Rare Thing", count = st.crafts } } }, p.unpriced)
		assert.same({}, p.skipped)
		-- an item with no price entry at all is the same case, and stays on the auction list
		local inp = input({ [1] = recipe("R1", NONE) }, { [1] = true })
		inp.price[NONE] = nil
		p = P.run(inp)
		assert.same({ "craft 1" }, kinds(p))
		assert.equal(1, p.unpriced.count)
		assert.same({ NONE, true }, { p.shopping.ah[1].item, p.shopping.ah[1].unpriced })
		assert.is_true(p.trip.rows[1].unpriced)
	end)

	it("an unpriced recipe ranks after a priced one of similar yield, and before a nearly grey one", function()
		-- same thresholds: the priced recipe wins, the unpriced one is only named as skipped
		local p =
			P.run(input({ [1] = recipe("Priced", M1), [2] = recipe("Unpriced", NONE) }, { [1] = true, [2] = true }))
		assert.same({ "craft 1" }, kinds(p))
		assert.equal("no price for Rare Thing", p.skipped[1].why)
		-- the priced one nearly grey (a point every 11 crafts): the unpriced one is cheaper even with its reagent
		-- counted as the dearest priced reagent (50 here)
		p = P.run(
			input(
				{ [1] = recipe("Priced", M1, { y = 60, g = 104 }), [2] = recipe("Unpriced", NONE) },
				{ [1] = true, [2] = true }
			)
		)
		assert.same({ "craft 2" }, kinds(p))
		assert.equal(NONE, p.steps[1].unpriced[1].item)
	end)

	it("a recipe item with no auction price fills a stretch nothing else covers, at a price said unknown", function()
		local recipes = {
			[1] = recipe("R1", M1, { g = 105 }),
			[4] = recipe("Pattern", M2, { src = "item", item = NONE, learn = 100 }),
		}
		local p = P.run(input(recipes, { [1] = true }))
		assert.same({ "craft 1", "buyRecipe 4", "craft 4" }, kinds(p))
		assert.same({ "source", true }, { p.steps[2].where, p.steps[2].priceUnknown })
		assert.equal("noPrice", p.steps[3].gated)
		assert.same({ { item = NONE, name = "Rare Thing", count = 1, recipe = true } }, p.unpriced.items)
		-- with a price it is bought as before, and nothing is unpriced
		recipes[4].item = PAT
		p = P.run(input(recipes, { [1] = true }))
		assert.same({ "ah", 100 }, { p.steps[#p.steps - 1].where, p.steps[#p.steps - 1].price })
		assert.equal(0, p.unpriced.count)
	end)

	it("a hole left by the user's own settings, or by the character level, says so", function()
		local recipes = {
			[1] = recipe("R1", M1, { g = 105 }),
			[4] = recipe("Pattern", M2, { src = "item", item = PAT, learn = 100 }),
		}
		local function gapOf(extra)
			local p = P.run(input(recipes, { [1] = true }, extra))
			local st = p.steps[#p.steps]
			return { st.kind, st.reason }
		end
		assert.same({ "gap", "excluded" }, gapOf({ exclude = { ahPatterns = true } }))
		assert.same({ "gap", "excluded" }, gapOf({ exclude = { notNow = { [4] = true } } }))
		assert.same({ "gap", "recipesOff" }, gapOf({ noRecipeBuys = true }))
		recipes[4] = recipe("By level", M2, { level = 40 })
		assert.same({ "gap", "level" }, gapOf({ level = 20 }))
	end)

	it("more than MAX_RECIPE_BUYS recipes are bought when each fills a stretch nothing else covers", function()
		local recipes, price = {}, { [M1] = { buy = 50, where = "ah", salvage = 1 } }
		for k = 1, 5 do
			local pattern = 200 + k
			price[pattern] = { buy = 100, where = "ah", salvage = 1 }
			-- each covers two levels of its own: learned at 98 + 2k, grey two points later
			local at = 98 + 2 * k
			recipes[k] = recipe("P" .. k, M1, { src = "item", item = pattern, learn = at, y = at, g = at + 2 })
		end
		local p = P.run(input(recipes, {}, { price = price }))
		assert.is_true(P.MAX_RECIPE_BUYS < 5)
		for _, st in ipairs(p.steps) do
			assert.is_not.equal("gap", st.kind)
		end
		assert.equal(5, #p.buys)
	end)
end)
