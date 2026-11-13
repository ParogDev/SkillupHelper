-- Logic, the panel text and the scan against a fake C_TradeSkillUI. Frames are checked in game.
local function load(ns)
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "Scan.lua", "TSM.lua", "View.lua", "UI.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

-- The panel's view description of a model, as text lines.
local function panelText(ns, m)
	local env = {
		nameOf = function(item, fallback)
			return fallback or ("item " .. item)
		end,
		money = ns.Logic.money,
		have = ns.Scan.have,
	}
	return ns.View.text(ns.View.describe(m, env))
end

local LIZARD, SPICES, TAIL, COD = 101, 2678, 5, 6

local plan = {
	generatedAt = "2026-11-11 12:00:00",
	vendor = { [SPICES] = 10 },
	professions = {
		[185] = {
			name = "Cooking",
			from = 173,
			to = 225,
			recipes = { [LIZARD] = { 140, 180, 1 } },
			rows = {
				{
					from = 173,
					to = 180,
					spell = LIZARD,
					recipe = "Crispy Lizard Tail",
					yellow = 140,
					green = 160,
					grey = 180,
					crafts = 104,
					cost = -1971,
					source = "known",
					mats = {
						{ item = TAIL, count = 104, name = "Thunder Lizard Tail" },
						{ item = SPICES, count = 104 },
					},
				},
				{ from = 180, to = 215, spell = 300, recipe = "Rockscale Cod", yellow = 190, green = 210, grey = 230 },
			},
			buyRecipes = {
				{
					item = 900,
					itemName = "Recipe: Rockscale Cod",
					price = 2792,
					learnRank = 175,
					spell = 300,
					from = 180,
					to = 215,
				},
			},
		},
	},
}

describe("Logic", function()
	local L
	before_each(function()
		L = load({}).Logic
	end)

	it("colours and chances follow the thresholds", function()
		assert.equal("orange", L.colorOf(139, 140, 180))
		assert.equal("yellow", L.colorOf(150, 140, 180))
		assert.equal("green", L.colorOf(160, 140, 180))
		assert.equal("grey", L.colorOf(180, 140, 180))
		assert.equal(1, L.chance(100, 140, 180))
		assert.equal(0.25, L.chance(170, 140, 180))
		assert.equal(0, L.chance(180, 140, 180))
		assert.equal("orange", L.colorOfDifficulty(0))
		assert.equal("grey", L.colorOfDifficulty(3))
	end)

	it("counts crafts from stock with vendor reagents as unlimited", function()
		local have = { [TAIL] = 9, [SPICES] = 2 }
		local n, limiting, buy = L.craftsPossible(
			{ { item = TAIL, count = 2 }, { item = SPICES, count = 1 } },
			function(i)
				return have[i] or 0
			end,
			{ [SPICES] = 10 }
		)
		assert.equal(4, n)
		assert.equal(TAIL, limiting)
		assert.same({ { item = SPICES, need = 2 } }, buy)
		assert.equal(math.huge, (L.craftsPossible({ { item = SPICES, count = 1 } }, function()
			return 0
		end, { [SPICES] = 10 })))
	end)

	it("expected points fall as the skill climbs into green", function()
		assert.equal(3, L.expectedPoints(100, 3, { 140, 180, 1 }))
		local pts = L.expectedPoints(170, 40, { 140, 180, 1 })
		assert.is_true(pts > 2 and pts < 10)
	end)

	it("lists learned recipes that give skill, orange first, grey and uncraftable left out", function()
		local have = { [TAIL] = 3 }
		local function mk(id, name, learned, difficulty, item)
			return {
				id = id,
				name = name,
				learned = learned,
				difficulty = difficulty,
				reagents = { { item = item, count = 1 } },
			}
		end
		local recipes = {
			mk(1, "Grey", true, 3, TAIL),
			mk(2, "Yellow", true, 1, TAIL),
			mk(3, "Orange", true, 0, TAIL),
			mk(4, "Unlearned", false, 0, TAIL),
			mk(5, "NoMats", true, 0, COD),
		}
		local list = L.fromStock(recipes, 150, function(i)
			return have[i] or 0
		end, {})
		assert.equal(2, #list)
		assert.equal("Orange", list[1].name)
		assert.equal("Yellow", list[2].name)
		assert.is_true(list[2].guessed)
	end)

	it("finds the plan step, below and past the plan", function()
		local prof = plan.professions[185]
		local step, nxt, state = L.planStep(prof, 175)
		assert.equal("ok", state)
		assert.equal("Crispy Lizard Tail", step.recipe)
		assert.equal("Rockscale Cod", nxt.recipe)
		assert.equal("below", select(3, L.planStep(prof, 100)))
		assert.equal("done", select(3, L.planStep(prof, 225)))
		assert.equal("none", select(3, L.planStep(nil, 1)))
	end)

	it("shopping scales with the part of the step still ahead", function()
		local row = plan.professions[185].rows[1]
		local list, crafts = L.stepShopping(row, 176.5, function(i)
			return i == TAIL and 20 or 0
		end)
		assert.equal(52, crafts)
		assert.same({ item = TAIL, name = "Thunder Lizard Tail", need = 52, have = 20, short = 32 }, list[1])
	end)

	it("recipes to buy skip learned ones and say when they are learnable", function()
		local prof = plan.professions[185]
		local list = L.recipesToBuy(prof, 176, function()
			return false
		end)
		assert.equal(1, #list)
		assert.is_true(list[1].learnable)
		assert.equal(0, #L.recipesToBuy(prof, 176, function()
			return true
		end))
	end)

	it("finds the profession by id, parent id or name", function()
		assert.equal("Cooking", L.findProfession(plan, { professionID = 185 }).name)
		assert.equal("Cooking", L.findProfession(plan, { professionID = 2, parentProfessionID = 185 }).name)
		assert.equal("Cooking", L.findProfession(plan, { professionID = 2, professionName = "cooking" }).name)
		assert.is_nil(L.findProfession(plan, { professionID = 2, professionName = "Mining" }))
	end)

	it("formats money", function()
		assert.equal("27s 92c", L.money(2792))
		assert.equal("-1g 61s 59c", L.money(-16159))
		assert.equal("5c", L.money(5))
	end)
end)

describe("Scan and panel", function()
	local ns, have
	before_each(function()
		have = { [TAIL] = 10 }
		_G.issecretvalue = function()
			return false
		end
		_G.C_Item = {
			GetItemCount = function(i, bank)
				assert.is_true(bank)
				return have[i] or 0
			end,
			GetItemNameByID = function()
				return nil
			end,
		}
		_G.C_TradeSkillUI = {
			GetBaseProfessionInfo = function()
				return { professionID = 185, professionName = "Cooking", skillLevel = 175, maxSkillLevel = 225 }
			end,
			GetChildProfessionInfo = function()
				return { professionID = 0, maxSkillLevel = 0, skillLevel = 0 }
			end,
			IsTradeSkillLinked = function()
				return false
			end,
			GetAllRecipeIDs = function()
				return { LIZARD, 300 }
			end,
			GetRecipeInfo = function(id)
				if id == LIZARD then
					return { name = "Crispy Lizard Tail", learned = true, relativeDifficulty = 2, canSkillUp = true }
				end
				return { name = "Rockscale Cod", learned = false }
			end,
			GetRecipeSchematic = function(id)
				if id == LIZARD then
					return {
						reagentSlotSchematics = {
							{ reagents = { { itemID = TAIL } }, quantityRequired = 1, required = true },
							{ reagents = { { itemID = SPICES } }, quantityRequired = 1, required = true },
						},
					}
				end
			end,
		}
		ns = load({})
	end)

	it("builds the model from the client and the plan", function()
		local m = ns.Scan.build(plan)
		assert.equal(175, m.skill)
		assert.equal(1, #m.fromStock)
		assert.equal(10, m.fromStock[1].crafts)
		assert.equal("green", m.fromStock[1].color)
		assert.same({ { item = SPICES, need = 10 } }, m.fromStock[1].toBuy)
		assert.equal("ok", m.planState)
		assert.equal(1, #m.buyRecipes)
		assert.equal(1, m.counts.dataThresholds)
	end)

	it("names a missing plan file and a linked window", function()
		local m = ns.Scan.build(nil)
		assert.matches("Plan.lua absent", m.planWhy)
		_G.C_TradeSkillUI.IsTradeSkillLinked = function()
			return true
		end
		assert.matches("linked", ns.Scan.build(plan).why)
	end)

	it("renders every section without errors", function()
		local text = table.concat(panelText(ns, ns.Scan.build(plan)), "\n")
		assert.matches("Cooking 175 / 225", text)
		assert.matches("Crispy Lizard Tail", text)
		assert.matches("Thunder Lizard Tail buy 65", text)
		assert.matches("Crispy Lizard Tail x10, from stock", text)
		assert.matches("Worth buying: Recipe: Rockscale Cod, 27s 92c, for 180 to 215", text)
		assert.matches("version 1", text)
		assert.is_true(#panelText(ns, { why = "x", state = "not now" }) == 1)
	end)
end)

describe("Yellow threshold of a recipe the export does not list", function()
	local S
	before_each(function()
		S = load({}).Scan
	end)

	it("starts at grey minus the usual span and narrows with the colours seen", function()
		assert.equal(120, S.yellowOf(145, nil))
		local seen = {}
		assert.is_true(S.noteColor(seen, 1, 127, 0)) -- orange at 127: yellow is above
		assert.is_false(S.noteColor(seen, 1, 126, 0))
		assert.equal(128, S.yellowOf(145, seen[1]))
		assert.is_true(S.noteColor(seen, 1, 131, 1)) -- yellow at 131: yellow is at or below
		assert.equal(128, S.yellowOf(145, seen[1]))
		assert.equal(131, S.yellowOf(160, seen[1]))
		assert.is_false(S.noteColor(seen, 1, 131, 3)) -- grey says nothing about yellow
	end)

	it("builds an entry from the client, or names what is missing", function()
		local e = S.liveEntry({
			name = "Linen Bandage",
			grey = 50,
			skillUps = 1,
			reagents = { { item = 2589, count = 1 } },
			makes = 1251,
			n = 1,
		})
		assert.same({ 2589, 1 }, e.mats)
		assert.equal(1251, e.makes)
		assert.equal(25, e.y)
		local none, why = S.liveEntry({ name = "x", grey = 0, reagents = {} })
		assert.is_nil(none)
		assert.matches("grey", why)
		local _, why2 = S.liveEntry({ name = "x", grey = 50 })
		assert.matches("schematic", why2)
		-- only optional or finishing slots: not planned as a free craft
		local free, why3 = S.liveEntry({ name = "x", grey = 50, reagents = {} })
		assert.is_nil(free)
		assert.matches("no basic reagents", why3)
	end)
end)

describe("Planner in the scan and the panel", function()
	local F = dofile("tests/fixtures.lua")
	local I = F.ITEM
	local ns, have, live, plan2
	before_each(function()
		have = { [I.LION] = 7, [I.BEAR] = 1 }
		live = nil
		_G.time = os.time
		_G.issecretvalue = function()
			return false
		end
		_G.TSM_API = {
			GetCustomPriceValue = function(source, itemString)
				return live and live(source, tonumber(itemString:match("%d+")))
			end,
		}
		_G.C_Item = {
			GetItemCount = function(i)
				return have[i] or 0
			end,
			GetItemNameByID = function()
				return nil
			end,
		}
		local _, items = F.prices()
		plan2 = {
			version = 2,
			generatedAt = "2026-11-11 12:00:00",
			pricesAt = os.time() - 30 * 3600,
			effort = 20,
			sellShare = 0.5,
			vendor = { [I.SPICES] = 40, [I.WATER] = 25 },
			items = items,
			professions = { [185] = { name = "Cooking", from = 173, to = 225, rows = {}, recipes = F.COOKING } },
		}
		_G.C_TradeSkillUI = {
			GetBaseProfessionInfo = function()
				return { professionID = 185, professionName = "Cooking", skillLevel = 173, maxSkillLevel = 225 }
			end,
			GetAllRecipeIDs = function()
				return { 3397, 3398, 6418, 6501, 7828, 13028 }
			end,
			GetRecipeInfo = function(id)
				local r = F.COOKING[id]
				return { name = r.name, learned = F.COOKING_LEARNED[id] or false, maxTrivialLevel = r.g }
			end,
			GetRecipeSchematic = function()
				return { reagentSlotSchematics = {} }
			end,
		}
		ns = load({})
		ns.Scan.resetCaches()
	end)

	it("plans from export prices when TSM has none, and says so", function()
		local m = ns.Scan.build(plan2)
		assert.is_nil(m.why)
		assert.is_nil(m.plannerWhy)
		local p = m.planner
		assert.equal("Big Bear Steak", p.steps[1].name)
		assert.equal("Hot Lion Chops", p.steps[2].name)
		assert.is_true(p.prices.export > 0 and p.prices.live == 0)
		assert.is_true(p.ageHours > 24)
		assert.equal(4, #m.greyCheck)
		assert.same({ spell = 3397, client = 190, plan = 190 }, m.greyCheck[1])
		local text = table.concat(panelText(ns, m), "\n")
		assert.matches("Cooking 173 / 225", text, 1, true)
		assert.matches("17 to grey", text, 1, true)
		assert.matches("Big Bear Steak\nCraft 1, about +0.4, to 173", text, 1, true)
		assert.matches("2 7x Hot Lion Chops, from stock", text, 1, true)
		assert.matches("Rockscale Cod 28s 11c", text, 1, true)
		assert.matches("TSM prices are 30 h old", text)
		assert.matches("prices from the export", text)
		assert.matches("Train Goldthorn Tea", text)
	end)

	it("takes live TSM prices first and keeps pass 1 cached across bag updates", function()
		live = function(source, item)
			if source == "dbmarket" and item == I.LION then
				return 5000 -- lion meat is dear now: the plan keeps the stock but no longer counts it cheap
			end
		end
		local m = ns.Scan.build(plan2)
		assert.equal(1, m.planner.prices.live)
		have[I.LION] = 0
		local m2 = ns.Scan.build(plan2)
		assert.equal("Big Bear Steak", m2.planner.steps[1].name)
		assert.is_not.equal("Hot Lion Chops", m2.planner.steps[2].name)
	end)

	it("reruns the stock pass only when a reagent count changed", function()
		local finish, runs = ns.Planner.finish, 0
		ns.Planner.finish = function(...)
			runs = runs + 1
			return finish(...)
		end
		local ok, err = pcall(function()
			local m = ns.Scan.build(plan2)
			local m2 = ns.Scan.build(plan2) -- a bag update that moved nothing the plan uses
			assert.equal(1, runs)
			assert.equal(m.planner.steps, m2.planner.steps)
			m2.planner.ms = -1 -- a per-build field never reaches the cache
			assert.is_not.equal(-1, ns.Scan.build(plan2).planner.ms)
			have[I.LION] = 3
			local m3 = ns.Scan.build(plan2)
			assert.equal(2, runs)
			assert.is_not.equal(m.planner.steps, m3.planner.steps)
		end)
		ns.Planner.finish = finish
		assert(ok, err)
	end)

	it("plans without recipe buys when the setting says so", function()
		local cooking = plan2.professions[185]
		local p = ns.Scan.runPlanner(plan2, cooking, 173, 225, F.COOKING_LEARNED, {}, {})
		local p2 = ns.Scan.runPlanner(plan2, cooking, 173, 225, F.COOKING_LEARNED, {}, { noRecipeBuys = true })
		local function recipeBuys(result)
			local n = 0
			for _, s in ipairs(result.steps) do
				n = n + (s.kind == "buyRecipe" and 1 or 0)
			end
			return n
		end
		assert.is_true(recipeBuys(p) > 0)
		assert.equal(0, recipeBuys(p2))
	end)

	-- the client's schematic for a fixture recipe: its reagents and product
	local function clientSchematics()
		_G.C_TradeSkillUI.GetRecipeSchematic = function(id)
			local r = F.COOKING[id]
			local slots = {}
			for k = 1, #r.mats - 1, 2 do
				slots[#slots + 1] = { reagents = { { itemID = r.mats[k] } }, quantityRequired = r.mats[k + 1] }
			end
			return { reagentSlotSchematics = slots, outputItemID = r.makes, quantityMin = r.n }
		end
	end

	it("plans a learned recipe the export does not list, from the client", function()
		clientSchematics()
		plan2.professions[185].recipes = {}
		for spell, r in pairs(F.COOKING) do
			if spell ~= 3398 then
				plan2.professions[185].recipes[spell] = r
			end
		end
		local m = ns.Scan.build(plan2)
		assert.is_nil(m.plannerWhy)
		assert.equal(1, m.counts.live)
		assert.equal(1, m.planner.liveRecipes)
		local names = {}
		for _, s in ipairs(m.planner.steps) do
			names[#names + 1] = s.name
		end
		assert.matches("Hot Lion Chops", table.concat(names, ","), 1, true)
		-- the export itself is never changed
		assert.is_nil(plan2.professions[185].recipes[3398])
	end)

	it("plans a profession the export never covered, from the client and TSM alone", function()
		clientSchematics()
		plan2.professions = {}
		local m = ns.Scan.build(plan2)
		assert.is_nil(m.plannerWhy)
		assert.is_nil(m.planWhy)
		assert.equal(4, m.counts.live)
		assert.is_true(m.planner.clientOnly)
		assert.is_true(#m.planner.steps > 0)
		assert.equal("Cooking", m.planner.profKey)
	end)

	it("replans when a recipe is learned", function()
		clientSchematics()
		plan2.professions = {}
		local before = ns.Scan.build(plan2).planner
		F.COOKING_LEARNED[13028] = true
		local ok, err = pcall(function()
			local after = ns.Scan.build(plan2).planner
			assert.equal(5, after.liveRecipes)
			assert.is_not.equal(before.steps, after.steps)
		end)
		F.COOKING_LEARNED[13028] = nil
		assert(ok, err)
	end)

	it("names a version 1 plan", function()
		local m = ns.Scan.build(plan)
		assert.matches("version 1", m.plannerWhy)
		assert.matches("version 1", table.concat(panelText(ns, m), "\n"))
	end)
end)

describe("TSM docking", function()
	local function fakeFrame(visible, left, top)
		return {
			IsVisible = function()
				return visible
			end,
			GetLeft = function()
				return left
			end,
			GetTop = function()
				return top
			end,
		}
	end

	it("takes TSM's crafting frame from its callback and drops it when TSM hides", function()
		local cb, visible = nil, true
		_G.TSM_API = {
			RegisterUICallback = function(ui, tag, fn)
				assert.equal("CRAFTING", ui)
				assert.equal("SkillupHelper:dock", tag)
				cb = fn
			end,
			IsUIVisible = function()
				return visible
			end,
		}
		local ns = load({})
		assert.is_true(ns.TSM.register())
		local changed = 0
		ns.onTSMChanged = function()
			changed = changed + 1
		end
		local tsmFrame = fakeFrame(true, 10, 10)
		cb(true, tsmFrame)
		assert.equal(tsmFrame, ns.TSM.craftingFrame())
		visible = false
		assert.is_nil(ns.TSM.craftingFrame())
		cb(false)
		assert.equal(2, changed)
		assert.same("hidden", ns.TSM.status().lastCallback)
	end)

	it("anchors the panel free when there is no window, then docks and keeps one anchor", function()
		local ns = load({})
		local points = {}
		ns.UI.frame = {
			ClearAllPoints = function()
				points = {}
			end,
			SetPoint = function(_, p, rel, _, x)
				points[#points + 1] = { p, rel, x }
			end,
		}
		_G.UIParent = {}
		ns.UI.dock(nil)
		-- by its top: the panel's height follows its content
		assert.same({ { "TOP", _G.UIParent, 300 } }, points)
		local target = {
			GetHeight = function()
				return 0
			end,
		}
		ns.UI.dock(target, "tsm")
		ns.UI.dock(target, "tsm")
		assert.same({ { "TOPLEFT", target, 2 } }, points)
	end)

	it("stands clear of the profession tabs on the right edge of Blizzard's window", function()
		local ns = load({})
		local points = {}
		ns.UI.frame = {
			ClearAllPoints = function()
				points = {}
			end,
			SetPoint = function(_, p, rel, _, x)
				points[#points + 1] = { p, rel, x }
			end,
		}
		local function tab(shown, width)
			return {
				IsShown = function()
					return shown
				end,
				GetWidth = function()
					return width
				end,
			}
		end
		local target = {
			GetHeight = function()
				return 500
			end,
			ProfessionsOverviewTab = tab(true, 40),
			rightProfessionTabs = { tab(true, 44), tab(false, 90) },
		}
		ns.UI.dock(target, "blizzard")
		-- the widest shown tab, the gap to the window and a gap to the tabs
		assert.same({ { "TOPLEFT", target, 2 + 44 + 4 } }, points)
		assert.equal(50, ns.UI.stats.dockGap)
		-- the same frame without tabs to read (another client build) keeps the small gap
		target.ProfessionsOverviewTab, target.rightProfessionTabs = nil, nil
		ns.UI.dock(target, "blizzard")
		assert.same({ { "TOPLEFT", target, 2 } }, points)
	end)

	it("names a missing TSM_API", function()
		_G.TSM_API = nil
		local ns = load({})
		assert.is_false(ns.TSM.register())
		assert.matches("missing", ns.TSM.status().callback)
	end)

	it("counts Blizzard's window as showing only when TSM has not moved it off-screen", function()
		local ns = load({})
		assert.is_true(ns.TSM.onScreen(fakeFrame(true, 100, 700)))
		assert.is_false(ns.TSM.onScreen(fakeFrame(true, 100100, 100700)))
		assert.is_false(ns.TSM.onScreen(fakeFrame(false, 100, 700)))
	end)
end)

describe("Core", function()
	it("loads, fills defaults and summarises the plan", function()
		local frame = setmetatable({}, {
			__index = function()
				return function() end
			end,
		})
		_G.CreateFrame = function()
			return frame
		end
		_G.SlashCmdList = {}
		_G.C_AddOns = {
			GetAddOnMetadata = function()
				return "@project-version@"
			end,
		}
		local ns = load({})
		assert(loadfile("Core.lua"))("SkillupHelper", ns)
		assert.equal(ns.CODE_VERSION .. "-dev", ns.version())
		assert.same({ shown = false }, ns.initDB({ shown = false }))
		assert.is_true(ns.initDB(nil).shown)
		local s = ns.selftest.planSummary(plan)
		assert.same({ "Cooking(185) 173-225, 2 steps" }, s.professions)
		assert.is_nil(ns.selftest.planSummary(nil))
		local F = dofile("tests/fixtures.lua")
		_G.date = os.date
		local p = ns.Planner.run(F.cooking())
		p.ms, p.prices, p.ageHours = 0.5, { live = 3, export = 1, none = 0 }, 30
		local sum = ns.scanSummary({ profession = "Cooking", skill = 173, planner = p })
		assert.equal(6, sum.planner.steps)
		assert.is_true(sum.planner.tsmStale)
		assert.equal(3, sum.planner.priceSources.live)
		assert.matches("^craft 1x Big Bear Steak 173.0%-173.4", sum.planner.first[1])
		assert.is_false(ns.command("toggle"))
		assert.equal(ns.CODE_VERSION, "0.2.10")
	end)
end)

describe("Vendor buy math", function()
	local L
	before_each(function()
		L = load({}).Logic
	end)

	it("buys exactly the short count of a single-unit item, in one call", function()
		local b = L.vendorLots(7, { price = 40, lot = 1, maxStack = 20, available = -1 })
		assert.same({ lots = 7, qty = 7, cost = 280, calls = { 7 } }, b)
	end)

	it("rounds up to whole vendor lots and prices per lot", function()
		-- water sold in fives at 25c a lot: 12 short is 3 lots, 15 units
		local b = L.vendorLots(12, { price = 25, lot = 5, maxStack = 20, available = -1 })
		assert.same({ lots = 3, qty = 15, cost = 75, calls = { 15 } }, b)
		-- an exact multiple buys no extra lot
		assert.equal(10, L.vendorLots(10, { price = 25, lot = 5, maxStack = 20 }).qty)
	end)

	it("splits a buy past the per-call stack limit, each call whole lots", function()
		local b = L.vendorLots(45, { price = 10, lot = 1, maxStack = 20 })
		assert.same({ 20, 20, 5 }, b.calls)
		assert.equal(450, b.cost)
		-- lot 5, max 12 a call: calls of 10 (two lots), never a broken lot
		local c = L.vendorLots(23, { price = 1, lot = 5, maxStack = 12 })
		assert.same({ 25, { 10, 10, 5 } }, { c.qty, c.calls })
		-- a max below one lot still buys a lot a call
		assert.same({ 5, 5 }, L.vendorLots(6, { price = 1, lot = 5, maxStack = 1 }).calls)
		-- no max from the client: one lot a call, never more than the client might take
		assert.same({ 5, 5 }, L.vendorLots(10, { price = 1, lot = 5 }).calls)
	end)

	it("refuses nothing to buy, no offer, and more than a limited vendor has", function()
		assert.same({ nil, "nothing to buy" }, { L.vendorLots(0, { price = 1 }) })
		assert.same({ nil, "nothing to buy" }, { L.vendorLots(-3, { price = 1 }) })
		assert.same({ nil, "no offer" }, { L.vendorLots(2, nil) })
		assert.same({ nil, "the vendor has 3 left" }, { L.vendorLots(4, { price = 1, lot = 1, available = 3 }) })
		assert.equal(3, L.vendorLots(3, { price = 1, lot = 1, available = 3 }).qty)
	end)

	it("counts bag room as free slots times the stack, plus the top of a partial stack", function()
		assert.equal(40, L.bagRoom(2, 20, 0))
		assert.equal(47, L.bagRoom(2, 20, 13)) -- 7 more fit on the stack of 13
		assert.equal(40, L.bagRoom(2, 20, 40)) -- full stacks take nothing
		assert.equal(0, L.bagRoom(0, 20, 0))
		assert.equal(3, L.bagRoom(3, 1, 5)) -- unstackable
	end)
end)

describe("AH list math", function()
	local L
	before_each(function()
		L = load({}).Logic
	end)

	it("merges the saved lists into what is left to buy; reagents are committed, patterns are not", function()
		local trips = {
			Leatherworking = {
				rows = {
					{ item = 2318, name = "Light Leather", count = 10, bought = 4, each = 20 },
					{ item = 9000, name = "Pattern", count = 1, each = 5000, recipe = true },
					{ item = 2319, name = "Medium Leather", count = 3, bought = 3, each = 60 },
				},
			},
			Cooking = { rows = { { item = 2318, name = "Light Leather", count = 2, each = 20 } } },
		}
		local list = L.ahList(trips)
		assert.equal(2, #list)
		-- Cooking sorts first, then Leatherworking adds its 6 left
		assert.same({ 2318, 8, true, false }, { list[1].item, list[1].count, list[1].committed, list[1].pattern })
		assert.same({ 9000, 1, false, true }, { list[2].item, list[2].count, list[2].committed, list[2].pattern })
		assert.same({}, L.ahList(nil))
	end)

	it("prices a commodity buy cheapest first and says how many are listed", function()
		local q = L.commodityQuote({ { unitPrice = 30, quantity = 5 }, { unitPrice = 20, quantity = 3 } }, 6)
		assert.same({ 8, 6, 20 * 3 + 30 * 3, 20 }, { q.available, q.qty, q.total, q.unit })
		local short = L.commodityQuote({ { unitPrice = 20, quantity = 2 } }, 6)
		assert.same({ 2, 2, 40 }, { short.available, short.qty, short.total })
		local none = L.commodityQuote({}, 6)
		assert.same({ 0, 0 }, { none.available, none.qty })
		assert.is_nil(none.avg)
	end)

	it("picks the cheapest buyout, never the user's own or a bid-only auction", function()
		local best = L.cheapestBuyout({
			{ auctionID = 1, buyoutAmount = 900, quantity = 1 },
			{ auctionID = 2, buyoutAmount = 500, quantity = 1, containsOwnerItem = true },
			{ auctionID = 3, quantity = 1 },
			{ auctionID = 4, buyoutAmount = 700, quantity = 1 },
		})
		assert.same({ auctionID = 4, buyout = 700, quantity = 1 }, best)
		assert.is_nil(L.cheapestBuyout({ { auctionID = 3, quantity = 1 } }))
	end)

	it("calls a price over 1.5x the plan's estimate overpriced", function()
		assert.equal("ok", (L.ahVerdict(100, 150)))
		local v, r = L.ahVerdict(100, 151)
		assert.same({ "over", 1.51 }, { v, r })
		assert.equal("unknown", (L.ahVerdict(nil, 151)))
	end)
end)
