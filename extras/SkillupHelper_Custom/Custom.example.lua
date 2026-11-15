-- Your own changes to the recipe data, kept apart from the files the addon ships (an update never overwrites them).
--
-- To use it: copy the folder extras/SkillupHelper_Custom out of SkillupHelper, next to it, so the game has
-- Interface/AddOns/SkillupHelper_Custom/SkillupHelper_Custom.toc. Copy the entries you need from this example into
-- that folder's Custom.lua. Restart the game the first time (a new addon folder is only seen at start) and /reload
-- after every later edit. This example file is not loaded; only Custom.lua is.
--
-- The addon reads three layers, each on top of the one before:
--   1. Data/Recipes.lua   shipped: every recipe of every profession (generated, do not edit);
--   2. Data/Plan.lua      optional: fallback prices written by a price tool on your PC;
--   3. Custom.lua         optional: your SkillupHelper_Custom table. What you write here wins over both.
-- One thing wins over this file: what a profession trainer shows in game. Once you open a trainer, the skill it asks
-- for each recipe is saved and used.
--
-- Every entry is checked when the addon loads. A bad entry is left out and named: one chat line at login, and all of
-- them in SkillupHelperDB.selftest.data.custom.errors after a /reload. The rest of the file still applies.
-- A Lua syntax error in this file (a missing comma or brace) is reported by the game itself and nothing in it loads;
-- the addon then runs on the shipped data.
--
-- Ids: a skill line id names a profession (164 Blacksmithing, 165 Leatherworking, 171 Alchemy, 185 Cooking,
-- 186 Mining, 197 Tailoring, 202 Engineering, 333 Enchanting, 129 First Aid, 40 Poisons). Spell and item ids are the
-- numbers in Data/Recipes.lua, or in a database site's address (.../spell=2660, .../item=2840).
--
-- The values below only show the shape: the learn ranks, the teacher and the coordinates are made up.
SkillupHelper_Custom = {
	recipes = {
		-- [skill line id] = { [spell id] = fields to change, or false }
		[164] = {
			-- Change fields of a recipe the data has. Any of:
			--   learn   the skill needed to learn it (a trainer recipe is planned from here, through its orange range)
			--   src     how it is learned: "trainer", "item" (a recipe item), "auto" (comes with the profession) or
			--           "special" (a quest or special NPC: shown as a shortcut, never planned on its own)
			--   teacher who teaches a special recipe or sells a recipe item (text, shown with the shortcut)
			--   cost    what the trainer asks, in copper
			--   y, g    the skill where it turns yellow and where it turns grey
			--   k       skill points a successful craft gives (1 for nearly every recipe)
			--   mats    reagents as { item, count, item, count, ... }
			--   makes, n  the item made and how many per craft
			--   item    the recipe item's id; bop = true when that item binds when picked up (never an auction buy)
			--   name    the recipe's name
			[2660] = { learn = 1 },
			[3320] = { learn = 25, cost = 100 },
			[9813] = { src = "special", teacher = "a quest in the Barrens" },

			-- false leaves a recipe out of every plan, also when you have learned it.
			[2663] = false,

			-- A recipe the data lacks: it needs at least y, g and mats.
			[999001] = {
				name = "Example Buckle",
				y = 60,
				g = 100,
				mats = { 2840, 4, 2880, 1 },
				makes = 999002,
				n = 1,
				src = "trainer",
				learn = 35,
			},
		},
	},

	-- Reagents a vendor sells, with the price of one in copper. They count as always available and are never looked
	-- up on the auction house. false takes one off the shipped list.
	vendor = {
		[2880] = 100, -- Weak Flux, 1s
		[3466] = 2000, -- Strong Flux, 20s
		-- [4289] = false,
	},

	-- Names and vendor sell prices for items your own recipes use (the client usually knows them already).
	items = {
		[999002] = { name = "Example Buckle", sell = 150, stack = 20 },
	},

	-- People the guide can send you to, in the shape of Data/Npcs.lua: the NPC's id, its name, the uiMap id, x and y
	-- in percent of that map, and a role: "trade" or "cook" (a vendor; list what it sells), "trainer" (name the
	-- profession in `trains`), "auction". An entry with a shipped NPC's id replaces it.
	npcs = {
		{
			id = 3355,
			name = "Saru Steelfury",
			map = 1454,
			x = 76.6,
			y = 34.6,
			role = "trainer",
			trains = "Blacksmithing",
			place = "Orgrimmar",
		},
		{
			id = 3356,
			name = "Sumi",
			map = 1454,
			x = 75,
			y = 34.2,
			role = "trade",
			place = "Orgrimmar",
			sells = { 2880, 3466 },
		},
	},

	-- Places to level a world skill: [skill line] = { [spot id] = spot, or false }. 633 Lockpicking, 186 Mining,
	-- 182 Herbalism, 393 Skinning (Fishing has zones and is not customisable yet). A new id adds a spot, a shipped id
	-- (see Data/Spots.lua) replaces it, false leaves a shipped one out. A spot needs map (uiMap id), x and y (map
	-- percent) and gets: what is there, by the target keys of Data/Spots.lua's skills[line].targets. pts (route
	-- points, x, y pairs in map percent), zone, area and note are optional.
	spots = {
		-- [633] = {
		-- 	["lock:custom:my-loop"] = {
		-- 		map = 1418, zone = "Badlands", x = 41.5, y = 28.7,
		-- 		gets = { { t = "<a target key>", n = 4 } },
		-- 		pts = { 41.0, 28.0, 42.0, 29.5 },
		-- 		note = "Up the west ramp",
		-- 	},
		-- 	["<a shipped spot id>"] = false,
		-- },
	},

	-- Trainers and recipe vendors in the shape of Data/Trainers.lua: id, name, map, x, y, role ("trainer" with
	-- trains = the profession's name, or "recipes"), faction ("A", "H" or "B"). A row with a shipped id replaces it.
	trainers = {
		-- { id = 999001, name = "My Trainer", map = 1454, x = 40, y = 60, role = "trainer", trains = "Mining", faction = "H" },
	},
}
