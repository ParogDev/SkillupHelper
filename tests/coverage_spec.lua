-- Completeness of the shipped Data/Recipes.lua: every crafting profession can be costed from skill 1 to 300 with
-- the real planner (Planner.costToCap, what "/skillup cost" runs). A stretch nothing covers is a hole in the data,
-- and the failure names the skill brackets and the recipes nearest to them.
local function load()
	local ns = {}
	for _, f in ipairs({ "Data/Recipes.lua", "Logic.lua", "Planner.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

-- Professions the data cannot level by crafting today: { brackets = { { from, to } }, reason }. The test asserts
-- these exact brackets, so a data change that closes (or moves) a hole fails here until the entry is updated.
-- The aim is an empty table.
local KNOWN_HOLES = {
	[186] = {
		brackets = { { 140, 155 }, { 185, 300 } },
		reason = "Mining is levelled by mining ore. Its craft recipes are the smelting spells, which turn grey at "
			.. "140 (Iron) and 185 (Gold); the later ones (Steel, Mithril, Truesilver, Dark Iron, Thorium) give no "
			.. "skill at all in the data (yellow = grey). No data is missing: crafting alone cannot do it.",
	},
}

-- With trainer and auto recipes only (no recipe item bought): the brackets that need a bought recipe.
local NEEDS_A_RECIPE_ITEM = {
	[129] = { { 210, 240 } }, -- First Aid: Heavy Silk and Mageweave Bandage are manuals
	[164] = { { 285, 300 } }, -- Blacksmithing
	[165] = { { 270, 280 }, { 295, 300 } }, -- Leatherworking
	[185] = { { 280, 300 } }, -- Cooking
	[197] = { { 260, 285 }, { 295, 300 } }, -- Tailoring
}

-- Ranks that never limit: every cap trainable well before it is reached.
local RANKS = {
	{ name = "Apprentice", cap = 75, cost = 10, where = "trainer" },
	{ name = "Journeyman", cap = 150, skill = 50, cost = 500, where = "trainer" },
	{ name = "Expert", cap = 225, skill = 125, cost = 5000, where = "trainer" },
	{ name = "Artisan", cap = 300, skill = 200, cost = 50000, where = "trainer" },
}
local REAGENT, RECIPE_ITEM = 100, 10000

local function usable(r)
	return not r.gone and r.src ~= "unlisted" and r.src ~= "special" and not (r.src == "item" and r.bop)
end

local function startOf(r)
	if r.src == "auto" then
		return 1
	elseif r.src == "item" then
		return r.learn or 1
	end
	return r.learn or r.y
end

-- "125-130: nearest Smelt Gold 115-130 (trainer), ..." for each gap
local function describeGaps(prof, gaps)
	local out = {}
	for _, g in ipairs(gaps) do
		local near = {}
		for spell, r in pairs(prof.recipes) do
			if usable(r) then
				local a, z = startOf(r), r.g
				local dist = math.max(0, a - g.to, g.from - z)
				near[#near + 1] = { dist = dist, spell = spell, text = ("%s %d-%d (%s)"):format(r.name, a, z, r.src) }
			end
		end
		table.sort(near, function(x, y)
			if x.dist ~= y.dist then
				return x.dist < y.dist
			end
			return x.spell < y.spell
		end)
		local names = {}
		for i = 1, math.min(4, #near) do
			names[i] = near[i].text
		end
		out[#out + 1] = ("%d-%d (%s): nearest %s"):format(g.from, g.to, tostring(g.why), table.concat(names, ", "))
	end
	return table.concat(out, "\n  ")
end

local function bracketsOf(gaps)
	local out = {}
	for _, g in ipairs(gaps) do
		out[#out + 1] = { math.floor(g.from), math.floor(g.to) }
	end
	return out
end

describe("the shipped recipe data", function()
	local ns, data, ids
	setup(function()
		ns = load()
		data = ns.Data.recipes
		ids = {}
		for id, prof in pairs(data.professions) do
			if not prof.side then
				ids[#ids + 1] = id
			end
		end
		table.sort(ids)
	end)

	local function cost(prof, recipeItems)
		local recipeItem = {}
		for _, r in pairs(prof.recipes) do
			if r.item then
				recipeItem[r.item] = true
			end
		end
		return ns.Planner.costToCap(prof, 1, 300, function(item)
			return recipeItem[item] and RECIPE_ITEM or REAGENT
		end, {
			vendor = data.vendor,
			items = data.items,
			-- Poisons has no ranks (a class skill): its cap is the target
			ranks = prof.ranks and RANKS or nil,
			cap = not prof.ranks and 300 or nil,
			recipeItems = recipeItems,
		})
	end

	it("loads with every crafting profession and the fields the planner reads", function()
		assert.equal(2, data.version)
		assert.is_string(data.build)
		local names = {}
		for _, id in ipairs(ids) do
			local prof = data.professions[id]
			names[#names + 1] = prof.name
			assert.equal(300, prof.to)
			for spell, r in pairs(prof.recipes) do
				local at = prof.name .. " " .. spell
				assert.is_number(r.y, at)
				assert.is_number(r.g, at)
				assert.is_true(type(r.mats) == "table" and #r.mats >= 2 and #r.mats % 2 == 0, at)
				assert.is_true(ns.Logic.isPlanV2(data, prof))
				assert.is_true(({ auto = 1, trainer = 1, item = 1, special = 1, unlisted = 1 })[r.src] == 1, at)
				assert.is_true(r.src ~= "item" or r.item ~= nil, at .. ": an item recipe names its item")
			end
		end
		assert.same({
			"Poisons",
			"First Aid",
			"Blacksmithing",
			"Leatherworking",
			"Alchemy",
			"Cooking",
			"Mining",
			"Tailoring",
			"Engineering",
			"Enchanting",
		}, names)
		-- Enchanting recipes make no item and stay in the data
		local enchants = 0
		for _, r in pairs(data.professions[333].recipes) do
			enchants = enchants + (r.makes == nil and 1 or 0)
		end
		assert.is_true(enchants > 100)
	end)

	it("can cost every crafting profession from 1 to 300 with no gap", function()
		local failures, seenHoles = {}, {}
		for _, id in ipairs(ids) do
			local prof = data.professions[id]
			local t0 = os.clock()
			local r = cost(prof, true)
			print(
				("%s: %s, %d steps, %d recipes to buy, training %s, %.2f s"):format(
					prof.name,
					r.complete and ns.Logic.money(r.total) or "INCOMPLETE",
					#r.steps,
					#r.recipesToBuy,
					ns.Logic.money(r.trainingCost),
					os.clock() - t0
				)
			)
			assert.is_true(r.total == r.total and math.abs(r.total) < math.huge, prof.name .. ": a finite total")
			assert.equal(0, r.unknownPrices, prof.name)
			-- every step's recipe is in the data; a trainer recipe is trained, and a recipe item bought, before its
			-- first craft
			local got = {}
			for i, st in ipairs(r.steps) do
				if st.kind == "train" or st.kind == "buyRecipe" then
					got[st.spell] = st.kind
				elseif st.kind == "craft" then
					local row = prof.recipes[st.spell]
					local at = ("%s step %d %s"):format(prof.name, i, tostring(st.name))
					assert.is_not_nil(row, at .. ": not in the data")
					if row.src == "trainer" then
						assert.equal("train", got[st.spell], at .. ": crafted before it is trained")
					elseif row.src == "item" then
						assert.equal("buyRecipe", got[st.spell], at .. ": crafted before its recipe is bought")
					else
						assert.equal("auto", row.src, at)
					end
				end
			end
			local known = KNOWN_HOLES[id]
			if known then
				seenHoles[id] = true
				assert.same(known.brackets, bracketsOf(r.gaps), prof.name .. ": KNOWN_HOLES is out of date")
			elseif not r.complete then
				failures[#failures + 1] = ("%s (%d) is not covered:\n  %s"):format(
					prof.name,
					id,
					describeGaps(prof, r.gaps)
				)
			end
		end
		assert.equal("", table.concat(failures, "\n"))
		for id in pairs(KNOWN_HOLES) do
			assert.is_true(seenHoles[id], "KNOWN_HOLES names a profession the data does not have: " .. id)
		end
	end)

	it("says which brackets need a bought recipe when only trainer recipes are used", function()
		local got = {}
		for _, id in ipairs(ids) do
			local prof = data.professions[id]
			local r = cost(prof, false)
			assert.same({}, r.recipesToBuy, prof.name)
			if not r.complete and not KNOWN_HOLES[id] then
				got[id] = bracketsOf(r.gaps)
				print(("%s needs a bought recipe at:\n  %s"):format(prof.name, describeGaps(prof, r.gaps)))
			end
		end
		assert.same(NEEDS_A_RECIPE_ITEM, got)
	end)
end)
