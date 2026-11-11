-- Logic, the panel text and the scan against a fake C_TradeSkillUI. Frames are checked in game.
local function load(ns)
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "Scan.lua", "TSM.lua", "UI.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
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
		local text = table.concat(ns.UI.lines(ns.Scan.build(plan)), "\n")
		assert.matches("Cooking 175/225", text)
		assert.matches("Crispy Lizard Tail", text)
		assert.matches("buy 10 item 2678", text)
		assert.matches("Recipes worth buying", text)
		assert.matches("Recipe: Rockscale Cod 27s 92c", text)
		assert.matches("then 180%-215 Rockscale Cod", text)
		assert.is_true(#ns.UI.lines({ why = "x", state = "not now" }) == 1)
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
		local text = table.concat(ns.UI.lines(m), "\n")
		assert.matches("NOW |r Craft 1x", text, 1, true)
		assert.matches("Big Bear Steak", text)
		assert.matches("NEXT|r Craft 7x", text, 1, true)
		assert.matches("Buy Recipe: Rockscale Cod %(AH 28s 11c%)", text)
		assert.matches("TSM data is 30 h old", text)
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

	it("names a version 1 plan", function()
		local m = ns.Scan.build(plan)
		assert.matches("version 1", m.plannerWhy)
		assert.matches("version 1", table.concat(ns.UI.lines(m), "\n"))
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
			SetPoint = function(_, p, rel)
				points[#points + 1] = { p, rel }
			end,
			SetHeight = function() end,
		}
		_G.UIParent = {}
		ns.UI.dock(nil)
		assert.same({ { "CENTER", _G.UIParent } }, points)
		local target = {
			GetHeight = function()
				return 0
			end,
		}
		ns.UI.dock(target)
		ns.UI.dock(target)
		assert.same({ { "TOPLEFT", target } }, points)
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
		assert.equal(ns.CODE_VERSION, "0.2.0")
	end)
end)
