-- Rank unlocks (Data/Routes.lua routeRanks): how the guide says Expert and Artisan are got (a trainer, a book, a
-- quest), laid over the data's ranks by the planner, worded by View and Where, and followed by the guide chip.
local function load()
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Guide.lua", "Planner.lua", "Scan.lua", "TSM.lua", "View.lua", "Where.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local EGG, CLAM, SWISS, COOKBOOK, M1 = 12207, 7974, 8932, 16072, 11

-- routeRanks rows in the generated shape (tools/gen_routes.py)
local ROUTE_RANKS = {
	[185] = {
		{ name = "Journeyman", skill = 50, kind = "trainer" },
		{
			name = "Expert",
			skill = 125,
			kind = "book",
			item = COOKBOOK,
			names = { [COOKBOOK] = "Expert Cookbook" },
			npcs = {
				{ id = 12033, name = "Wulan", faction = "H", map = 1443, x = 26.1, y = 69.7 },
				{ name = "Shandrina", faction = "A", map = 1440, x = 49.5, y = 67.1 },
			},
		},
		{
			name = "Artisan",
			skill = 225,
			level = 35,
			kind = "quest",
			quest = 6610,
			questName = "Clamlette Surprise",
			items = { EGG, 12, CLAM, 10, SWISS, 20 },
			names = { [SWISS] = "Alterac Swiss" },
			npcs = { { name = "Dirge Quikcleave", map = 1446, x = 52.6, y = 28.1 } },
		},
	},
	[165] = {
		{
			name = "Expert",
			skill = 125,
			level = 20,
			kind = "trainer",
			npcs = {
				{ id = 3007, name = "Una", faction = "H", map = 1456, x = 41.7, y = 42.6 },
				{ id = 4212, name = "Telonis", faction = "A", map = 1457, x = 64.4, y = 21.5 },
			},
		},
		{
			name = "Artisan",
			skill = 200,
			level = 35,
			kind = "trainer",
			npcs = {
				{ id = 11098, name = "Hahrana Ironhide", faction = "H", map = 1444, x = 74.4, y = 43.1 },
				{ id = 11097, name = "Drakk Stonehand", faction = "A", map = 1425, x = 13.4, y = 43.3 },
			},
		},
	},
}

-- the data's ranks (Data/Recipes.lua's shape) before the overlay
local COOK_RANKS = {
	{ name = "Apprentice", cap = 75, cost = 100, where = "trainer" },
	{ name = "Journeyman", cap = 150, skill = 50, cost = 500, where = "trainer" },
	{ name = "Expert", cap = 225, skill = 125, cost = 5000, where = "unknown" },
	{ name = "Artisan", cap = 300, skill = 200, where = "quest" },
}
local LW_RANKS = {
	{ name = "Apprentice", cap = 75, cost = 10, where = "trainer" },
	{ name = "Journeyman", cap = 150, skill = 50, cost = 500, where = "trainer" },
	{ name = "Expert", cap = 225, skill = 125, cost = 5000, where = "trainer" },
	{ name = "Artisan", cap = 300, skill = 200, cost = 50000, where = "trainer" },
}

-- Data/Trainers.lua rows shaped like the regenerated ones: Una and Telonis are Expert, Hahrana and Drakk Artisan
local TRAINER_ROWS = {
	{ id = 3007, name = "Una", map = 1456, x = 41.7, y = 42.6, place = "Thunder Bluff", role = "trainer" },
	{ id = 4212, name = "Telonis", map = 1457, x = 64.4, y = 21.5, place = "Darnassus", role = "trainer" },
	{ id = 11098, name = "Hahrana Ironhide", map = 1444, x = 74.4, y = 43.1, place = "Camp Mojache", role = "trainer" },
	{
		id = 11097,
		name = "Drakk Stonehand",
		map = 1425,
		x = 13.4,
		y = 43.3,
		place = "The Hinterlands",
		role = "trainer",
	},
	{ id = 8126, name = "Nixx Sprocketspring", map = 1446, x = 52.5, y = 27.3, place = "Gadgetzan", role = "trainer" },
}
for _, r in ipairs(TRAINER_ROWS) do
	r.trains = r.id == 8126 and "Engineering" or "Leatherworking"
	r.rank = (r.id == 3007 or r.id == 4212) and "expert" or "artisan"
	r.faction = (r.id == 3007 or r.id == 11098) and "H" or (r.id == 8126 and "B" or "A")
end
local NPC_ROWS = {
	{ id = 12033, name = "Wulan", map = 1443, x = 26.2, y = 69.8, role = "cook", place = "Shadowprey Village" },
	{ id = 8661, name = "Auctioneer Beardo", map = 1446, x = 52, y = 29.6, role = "auction", place = "Gadgetzan" },
}
local MAPS = {
	[1425] = { name = "The Hinterlands" },
	[1440] = { name = "Ashenvale" },
	[1443] = { name = "Desolace" },
	[1444] = { name = "Feralas" },
	[1446] = { name = "Tanaris" },
	[1456] = { name = "Thunder Bluff" },
	[1457] = { name = "Darnassus" },
}

-- every map on one continent, 10 yards a percent, maps 1000 yards apart: Thunder Bluff (1456) is nearest to `here`
local function world(map, x, y)
	if type(map) ~= "number" then
		return nil
	end
	return 1, (map - 1456) * 1000 - y * 10, -x * 10
end
local HERE = { continent = 1, x = -426, y = -417 }

local NAMES = { [EGG] = "Giant Egg", [CLAM] = "Zesty Clam Meat" }
local function envOf(ns, have)
	return {
		nameOf = function(item, fallback)
			return NAMES[item] or fallback or ("item " .. item)
		end,
		money = ns.Logic.money,
		have = function(item)
			return have[item] or 0
		end,
	}
end

local PRICE = {
	[M1] = { buy = 10, where = "ah", salvage = 1 },
	[EGG] = { buy = 300, where = "ah", salvage = 1 },
	[CLAM] = { buy = 150, where = "ah", salvage = 1 },
	[SWISS] = { buy = 40, where = "vendor", salvage = 1 },
}

local function recipe(y, g, learn)
	return { y = y, g = g, k = 1, name = "Recipe " .. y, mats = { M1, 1 }, src = "trainer", learn = learn, cost = 0 }
end

local function cooking(P, skill, cap, faction, unlocks)
	return P.run({
		skill = skill,
		cap = cap,
		target = 300,
		level = 40,
		ranks = COOK_RANKS,
		unlocks = unlocks,
		faction = faction,
		recipes = { [1] = recipe(150, 230, 100), [2] = recipe(250, 300, 225) },
		learned = { [1] = true, [2] = true },
		price = PRICE,
		have = {},
	})
end

local function rankStep(plan, name)
	for _, st in ipairs(plan.steps) do
		if st.kind == "trainRank" and st.name == name then
			return st
		end
	end
	return nil
end

local function panelPlan(steps)
	return { steps = steps, hold = {}, leftovers = {}, fromStock = {}, ageHours = 1, prices = {} }
end

local function cardOf(ns, st, env, profession)
	local m =
		{ profession = profession or "Cooking", skill = st.skill or 1, maxSkill = st.by, planner = panelPlan({ st }) }
	return ns.View.describe(m, env).now
end

describe("Rank unlocks", function()
	local ns, P, G
	before_each(function()
		_G.issecretvalue = function()
			return false
		end
		ns = load()
		ns.Data = { npcs = NPC_ROWS, trainers = TRAINER_ROWS, spots = { maps = MAPS } }
		P, G = ns.Planner, ns.Guide
	end)

	it("Cooking 225/225: the Artisan rank is the Clamlette Surprise quest from Dirge, with its hand-in", function()
		local plan = cooking(P, 225, 225, "Horde", ROUTE_RANKS[185])
		local st = plan.steps[1]
		assert.same({ "trainRank", "Artisan", 225, 35 }, { st.kind, st.name, st.at, st.level })
		assert.equal("quest", st.where)
		assert.same({ "quest", 6610, "Clamlette Surprise" }, { st.unlock.kind, st.unlock.quest, st.unlock.questName })
		assert.same({ "Dirge Quikcleave" }, { st.unlock.npcs[1].name })
		local mats = {}
		for _, m in ipairs(st.unlock.mats) do
			mats[#mats + 1] = { m.item, m.count, m.where, m.each }
		end
		assert.same({ { EGG, 12, "ah", 300 }, { CLAM, 10, "ah", 150 }, { SWISS, 20, "vendor", 40 } }, mats)

		-- the card names the quest and lists the hand-in like a craft's materials
		local card = cardOf(ns, st, envOf(ns, { [EGG] = 2 }))
		assert.equal("Quest: Clamlette Surprise from Dirge Quikcleave, Gadgetzan (Tanaris)", card.title)
		assert.equal("Artisan (to 300): at 225", card.sub)
		local rows = {}
		for _, r in ipairs(card.mats) do
			rows[#rows + 1] = { r.name, r.have, r.need, r.right }
		end
		assert.same({
			{ "Giant Egg", 2, 12, "buy 10, AH 30s 0c" },
			{ "Zesty Clam Meat", 0, 10, "buy 10, AH 15s 0c" },
			{ "Alterac Swiss", 0, 20, "buy 20, vendor 8s 0c" },
		}, rows)
		assert.equal("You have 2 of 12 Giant Egg; buy 10 on the AH: 30s 0c", card.lines[1].text)
		assert.equal("53s 0c for the hand-in", card.lines[4].text)

		-- the chip: Alterac Swiss at a vendor, the rest at the auction house, then the quest giver (no npc id)
		local needs = G.needsOf(st, "Cooking")
		assert.same({ "vendor", "auction", "quest" }, { needs[1].kind, needs[2].kind, needs[3].kind })
		assert.same({ SWISS, 20 }, { needs[1].items[1].item, needs[1].items[1].count })
		assert.same({ EGG, CLAM }, { needs[2].items[1].item, needs[2].items[2].item })
		local pick = G.nearest(G.shippedRecords(TRAINER_ROWS, "Horde"), needs[3], HERE, world)
		assert.same({ "Dirge Quikcleave", "Gadgetzan", 1446 }, { pick.name, pick.zone, pick.npc.map })
		-- bought hand-in items leave only the quest giver
		local have = { [EGG] = 12, [CLAM] = 10, [SWISS] = 20 }
		local open = G.pending(needs, function(i)
			return have[i] or 0
		end)
		assert.same({ "quest" }, { open[1].kind, open[2] })
	end)

	it(
		"Cooking 125: the Expert rank is the Expert Cookbook, from Wulan for the Horde and Shandrina for the Alliance",
		function()
			local horde = rankStep(cooking(P, 125, 150, "Horde", ROUTE_RANKS[185]), "Expert")
			assert.same({ "book", COOKBOOK, 125 }, { horde.unlock.kind, horde.unlock.item, horde.at })
			assert.same({ "Wulan" }, { horde.unlock.npcs[1].name, horde.unlock.npcs[2] })
			-- a book has no trainer fee: the data's 50s is not its price
			assert.is_nil(horde.cost)
			local card = cardOf(ns, horde, envOf(ns, {}))
			assert.equal("Buy the Expert Cookbook from Wulan, Shadowprey Village (Desolace)", card.title)
			assert.equal("Expert (to 225): at 125, book price not known yet", card.sub)
			local need = G.needsOf(horde, "Cooking")[1]
			assert.same({ "vendor", COOKBOOK }, { need.kind, need.items[1].item })
			-- Wulan's seed does not list the book: the unlock says she sells it
			local pick = G.nearest(G.known(NPC_ROWS, {}, {}, {}), need, HERE, world)
			assert.same({ "Wulan", "Shadowprey Village" }, { pick.name, pick.zone })

			local alliance = rankStep(cooking(P, 125, 150, "Alliance", ROUTE_RANKS[185]), "Expert")
			assert.same({ "Shandrina" }, { alliance.unlock.npcs[1].name, alliance.unlock.npcs[2] })
			assert.equal("Buy the Expert Cookbook from Shandrina, Ashenvale", cardOf(ns, alliance, envOf(ns, {})).title)
			local apick = G.nearest({}, G.needsOf(alliance, "Cooking")[1], HERE, world)
			assert.same({ "Shandrina", "unlock:Shandrina" }, { apick.name, apick.npc.id })
		end
	)

	describe("Leatherworking 162", function()
		local function lw(faction, unlocks)
			return P.run({
				skill = 162,
				cap = 225,
				target = 300,
				level = 40,
				ranks = LW_RANKS,
				unlocks = unlocks,
				faction = faction,
				recipes = {
					[1] = recipe(170, 210, 140),
					-- Nightscape Pants: a trainer recipe learned at 205
					[10548] = {
						y = 225,
						g = 245,
						k = 1,
						name = "Nightscape Pants",
						mats = { M1, 1 },
						src = "trainer",
						learn = 205,
						cost = 4000,
					},
					[3] = recipe(260, 300, 240),
				},
				learned = { [1] = true },
				price = PRICE,
				have = {},
			})
		end
		local function train(plan, spell)
			for _, st in ipairs(plan.steps) do
				if st.kind == "train" and st.spell == spell then
					return st
				end
			end
			return nil
		end

		it("the Artisan rank and its recipes send the Horde to Hahrana and the Alliance to Drakk", function()
			for faction, want in pairs({ Horde = "Hahrana Ironhide", Alliance = "Drakk Stonehand" }) do
				local plan = lw(faction, ROUTE_RANKS[165])
				local known = G.shippedRecords(TRAINER_ROWS, faction)
				local art = rankStep(plan, "Artisan")
				assert.same({ "trainer", 200, 35 }, { art.unlock.kind, art.at, art.level })
				local need = G.needsOf(art, "Leatherworking")[1]
				assert.equal("trainer", need.kind)
				local pick = G.nearest(known, need, HERE, world)
				assert.equal(want, pick.name, faction)
				assert.is_true(pick.certain)
				local text = ("Train Artisan at %s"):format(want)
				assert.equal(text, cardOf(ns, art, envOf(ns, {}), "Leatherworking").title:sub(1, #text))
				-- Nightscape Pants, learned at 205: the Artisan trainer, not Una in Thunder Bluff (nearer)
				local pants = train(plan, 10548)
				assert.equal("Artisan", pants.trainerRank)
				local pneed = G.needsOf(pants, "Leatherworking")[1]
				assert.equal(want, G.nearest(known, pneed, HERE, world).name, faction)
			end
			assert.equal(
				"Train Artisan at Hahrana Ironhide, Camp Mojache (Feralas)",
				cardOf(ns, rankStep(lw("Horde", ROUTE_RANKS[165]), "Artisan"), envOf(ns, {}), "Leatherworking").title
			)
		end)

		it("without unlocks the trainers' ranks still pick an Artisan for a recipe learned at 205", function()
			local plan = lw("Horde", nil)
			local pants = train(plan, 10548)
			assert.is_nil(pants.trainers)
			local need = G.needsOf(pants, "Leatherworking")[1]
			assert.is_nil(need.npcs)
			local pick, _, _, stats = G.nearest(G.shippedRecords(TRAINER_ROWS, "Horde"), need, HERE, world)
			assert.equal("Hahrana Ironhide", pick.name)
			assert.equal(1, stats.belowRank)
			-- Una (expert) reaches a recipe learned at 150, not one at 205
			local una = G.shippedRecords(TRAINER_ROWS, "Horde")[1]
			assert.equal("Una", una.name)
			assert.is_true(G.rankReaches(una, { kind = "trainer", at = 150 }))
			assert.is_false(G.rankReaches(una, { kind = "trainer", at = 205 }))
			assert.is_false(G.rankReaches(una, { kind = "trainer", cap = 300 }))
		end)
	end)

	it("no routeRanks table: the data's ranks and the old trainer need", function()
		assert.is_nil(ns.Scan.unlocksFor(185))
		local plan = cooking(P, 225, 225, "Horde", ns.Scan.unlocksFor(185))
		-- Artisan at the data's 200, so the rank step comes first at the cap; no unlock
		local st = rankStep(plan, "Artisan")
		assert.same({ 200, "quest" }, { st.at, st.where })
		assert.is_nil(st.unlock)
		assert.is_nil(st.level)
		local need = G.needsOf(st, "Cooking")
		assert.same({ "trainer", 300 }, { need[1].kind, need[1].cap })
		assert.is_nil(need[1].npcs)
		local card = cardOf(ns, st, envOf(ns, {}))
		assert.equal("Train Artisan (to 300)", card.title)
		assert.same(COOK_RANKS, P.rankUnlocks(COOK_RANKS, nil, "Horde"))
	end)

	it("a rank read at a trainer keeps its own skill and takes only a trainer unlock", function()
		local seen = { { name = "Artisan", cap = 300, skill = 210, level = 30, where = "trainer", seen = true } }
		local out = P.rankUnlocks(seen, ROUTE_RANKS[185], "Horde")
		assert.equal(seen[1], out[1])
		local lw = P.rankUnlocks(seen, ROUTE_RANKS[165], "Alliance")
		assert.same({ 210, 30, "trainer" }, { lw[1].skill, lw[1].level, lw[1].where })
		assert.same({ "Drakk Stonehand" }, { lw[1].unlock.npcs[1].name, lw[1].unlock.npcs[2] })
	end)

	it("the shipped Data/Routes.lua routeRanks, when present, has the shape the planner reads", function()
		local data = {}
		assert(loadfile("Data/Routes.lua"))("SkillupHelper", { Data = data })
		if data.routeRanks == nil then
			return
		end
		ns.Data.routeRanks = data.routeRanks
		for line, list in pairs(data.routeRanks) do
			assert.equal(list, ns.Scan.unlocksFor(line))
			for _, u in ipairs(list) do
				assert.is_string(u.name)
				assert.is_true(u.kind == "trainer" or u.kind == "book" or u.kind == "quest", u.name)
				for _, n in ipairs(u.npcs or {}) do
					assert.is_string(n.name)
					assert.is_true(n.faction == nil or n.faction == "A" or n.faction == "H")
				end
			end
		end
	end)
end)
