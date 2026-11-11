-- Shape of Data/Plan.lua (version 2), the file a price tool on your PC writes (tools/tsm/skillup_lua.py in the
-- scaffolding; gitignored here, listed in the TOC, so a /reload picks up a new one). The planner prices from TSM live
-- and uses this file for what the client cannot tell it: thresholds, reagents of unlearned recipes, how a recipe is
-- learned, and fallback prices when TSM_API returns none. Without the file the panel still lists what you can craft
-- from stock, colours from the client. This example is not loaded.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.plan = {
	version = 2,
	generatedAt = "2026-11-11 12:00:00",
	build = "1.60.1.70888",
	-- AuctionDB download time (epoch seconds) of the prices the export saw: the panel warns past 24 hours
	pricesAt = 1762862400,
	-- defaults; /skillup effort <copper> overrides the effort charge per craft
	effort = 20,
	sellShare = 0.5,
	-- vendor-sold reagents (copper each): counted as always available
	vendor = { [2692] = 40 },
	-- name, vendor sell, fallback market value, stack, the exported recipe that makes it
	items = {
		[3731] = { name = "Lion Meat", sell = 55, mv = 123, stack = 10 },
		[6369] = { name = "Recipe: Rockscale Cod", sell = 550, mv = 2811 },
	},
	professions = {
		-- keyed by skill line id (185 Cooking, 165 Leatherworking)
		[185] = {
			name = "Cooking",
			from = 173,
			-- the skill the recipes below cover (the generator's --to, by default the top rank cap): the plan's target
			-- until a trainer visit saves the ranks (SkillupHelperDB.ranks, /skillup ranks)
			to = 300,
			total = -14902,
			-- the offline plan (tools/tsm/skillup.py), kept for comparison
			rows = {
				{
					from = 173,
					to = 180,
					spell = 6418,
					recipe = "Crispy Lizard Tail",
					yellow = 140,
					green = 160,
					grey = 180,
					crafts = 104,
					cost = -1971,
					source = "known",
					mats = { { item = 5470, count = 104, name = "Thunder Lizard Tail" } },
				},
			},
			buyRecipes = {
				{ item = 6369, itemName = "Recipe: Rockscale Cod", price = 2792, learnRank = 175, spell = 7828, from = 180, to = 215 },
			},
			-- every recipe that can give skill in range: y/g thresholds, k skill-ups, mats { item, count, ... },
			-- product and count, src (auto | trainer | item), recipe item and learn rank, AH value per craft and
			-- how many crafts' worth the market takes
			recipes = {
				[3398] = { y = 175, g = 215, k = 1, name = "Hot Lion Chops", mats = { 2692, 1, 3731, 1 }, makes = 3727, n = 1, src = "trainer" },
				[7828] = { y = 190, g = 230, k = 1, name = "Rockscale Cod", mats = { 6362, 1 }, makes = 4594, n = 1, src = "item", item = 6369, learn = 175 },
			},
		},
	},
}
