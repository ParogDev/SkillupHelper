-- Shape of Data/Plan.lua, the file a price tool on your PC writes (gitignored; listed in the TOC, so a /reload
-- picks up a new one). Without it the panel still lists what you can craft from stock, colours from the client.
-- This example is not loaded.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.plan = {
	generatedAt = "2026-11-11 12:00:00",
	build = "1.60.1.70888",
	-- vendor-sold reagents (copper each): counted as always available
	vendor = { [2692] = 40 },
	professions = {
		-- keyed by skill line id (185 Cooking, 165 Leatherworking)
		[185] = {
			name = "Cooking",
			from = 173,
			to = 225,
			total = -14902,
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
			-- every recipe: { yellow, grey, skill-ups per craft }
			recipes = { [6418] = { 140, 180, 1 } },
		},
	},
}
