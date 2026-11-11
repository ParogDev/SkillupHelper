-- View.lua: the panel's description of a plan, frame-free. The frames themselves are checked in game.
local F = dofile("tests/fixtures.lua")
local I = F.ITEM

local function load()
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "TSM.lua", "View.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local function envOf(ns, have)
	return {
		nameOf = function(item, fallback)
			return fallback or ("item " .. item)
		end,
		money = ns.Logic.money,
		have = function(item)
			return have[item] or 0
		end,
	}
end

describe("Colour-change target", function()
	local V
	before_each(function()
		V = load().View
	end)

	it("runs to yellow, then green, then grey, and stops at grey", function()
		-- 150/190: green from 170
		local o = V.colourTarget(140, 150, 190)
		assert.same({ "orange", 150, "yellow", 10 }, { o.color, o.target, o.next, o.left })
		assert.equal(130, o.from)
		assert.near(0.5, o.frac, 1e-9)
		local y = V.colourTarget(160, 150, 190)
		assert.same({ "yellow", 150, 170, "green" }, { y.color, y.from, y.target, y.next })
		assert.equal("10 to green", y.label)
		local g = V.colourTarget(173, 150, 190)
		assert.same({ "green", 170, 190, "grey", "17 to grey" }, { g.color, g.from, g.target, g.next, g.label })
		assert.near(3 / 20, g.frac, 1e-9)
		assert.is_nil(V.colourTarget(190, 150, 190))
		assert.is_nil(V.colourTarget(150, 150, 150))
		assert.is_nil(V.colourTarget(nil, 150, 190))
	end)

	it("starts the orange band at the skill when the skill sits far below yellow", function()
		local o = V.colourTarget(100, 150, 190)
		assert.equal(100, o.from)
		assert.equal(0, o.frac)
	end)
end)

describe("Consumed materials", function()
	local V
	before_each(function()
		V = load().View
	end)

	it("reports the units gone for the same step only", function()
		local prev = { key = "craft:1:stock", mats = { { item = 1, have = 7 }, { item = 2, have = 3 } } }
		local cur = { key = "craft:1:stock", mats = { { item = 1, have = 6 }, { item = 2, have = 3 } } }
		assert.same({ [1] = 1 }, V.consumed(prev, cur))
		assert.same({}, V.consumed(prev, { key = "craft:2:stock", mats = cur.mats }))
		assert.same({}, V.consumed(nil, cur))
		-- more in the bags (looted, bank opened) is not a consumption
		assert.same({}, V.consumed(cur, prev))
	end)

	it("names the transition: first, same, advance, replace", function()
		local a = { profession = "Cooking", skill = 173, next = { key = "a" } }
		assert.equal("first", V.transition(nil, a))
		assert.equal("same", V.transition(a, { profession = "Cooking", skill = 173, next = { key = "a" } }))
		assert.equal("advance", V.transition(a, { profession = "Cooking", skill = 174, next = { key = "b" } }))
		assert.equal("replace", V.transition(a, { profession = "Cooking", skill = 173, next = { key = "b" } }))
		assert.equal("first", V.transition(a, { profession = "Leatherworking", skill = 174, next = { key = "b" } }))
	end)
end)

describe("View description", function()
	local ns
	before_each(function()
		ns = load()
	end)

	local function cooking(have)
		local input = F.cooking()
		input.have = have
		local p = ns.Planner.run(input)
		p.prices, p.ageHours = { live = 10, export = 0, none = 0 }, 2
		local m = { profession = "Cooking", skill = 173, maxSkill = 225, planner = p }
		return ns.View.describe(m, envOf(ns, have)), p
	end

	it("puts step 1 on the Next card with its colour, gain, cost and materials", function()
		local have = { [I.LION] = 7, [I.BEAR] = 1 }
		local d = cooking(have)
		assert.equal("plan", d.state)
		assert.same({ title = "Cooking", skill = "173 / 225" }, d.header)
		local nx = d.next
		assert.equal("Big Bear Steak", nx.name)
		assert.equal("green", nx.color)
		assert.equal("Craft 1", nx.verb)
		assert.matches("^about %+0%.4, to 173, 43%% a craft", nx.gain)
		assert.matches("a point$", nx.cost)
		-- tags read as one sentence, first word capitalised
		assert.matches("^Last use before it turns grey", nx.tags)
		-- one bear meat from the bags, the spices from the vendor
		assert.same({ "1/1", true }, { nx.mats[1].right, nx.mats[1].covered })
		assert.same({ I.BEAR, 1, 1 }, { nx.mats[1].item, nx.mats[1].have, nx.mats[1].need })
		assert.same({ "buy 1, vendor 40c", false }, { nx.mats[2].right, nx.mats[2].covered })
		-- the runway runs to the next colour change of the step's own recipe (150/190)
		assert.same({ "green", 190, "17 to grey" }, { d.runway.color, d.runway.target, d.runway.label })
		-- prices are live and recent: no stale line
		assert.is_nil(d.header.stale)
	end)

	it("lists later steps as numbered rows and keeps the card and rows to their limits", function()
		local d, p = cooking({ [I.LION] = 7, [I.BEAR] = 1 })
		assert.same(
			{ 2, "orange", "7x Hot Lion Chops, from stock" },
			{ d.later[1].n, d.later[1].color, d.later[1].text }
		)
		assert.equal("173 to 180", d.later[1].right)
		assert.is_true(#d.later <= ns.View.MAX_LATER + 1)
		assert.is_true(#p.steps - 1 == #d.later or d.later[#d.later].n == nil)
		local text = table.concat(ns.View.text(d), "\n")
		assert.matches("Buy Recipe: Rockscale Cod", text, 1, true)
		assert.matches("Train Goldthorn Tea", text, 1, true)
	end)

	it("says when prices are stale or came from the export", function()
		local input = F.cooking()
		local p = ns.Planner.run(input)
		p.prices, p.ageHours = { live = 0, export = 12 }, 30
		local d = ns.View.describe({ profession = "Cooking", skill = 173, maxSkill = 225, planner = p }, envOf(ns, {}))
		assert.equal("TSM prices are 30 h old: sync the TSM app; 12 prices from the export", d.header.stale)
		p.ageHours = nil
		d = ns.View.describe({ profession = "Cooking", skill = 173, maxSkill = 225, planner = p }, envOf(ns, {}))
		assert.matches("^TSM data age unknown", d.header.stale)
	end)

	it("shows a buy step's stock alternative and the hold list and verdicts in the footer", function()
		local input = F.leather()
		local p = ns.Planner.run(input)
		p.prices, p.ageHours = { live = 1 }, 1
		local d = ns.View.describe(
			{ profession = "Leatherworking", skill = input.skill, maxSkill = input.cap, planner = p },
			envOf(ns, input.have)
		)
		local alt
		for _, st in ipairs(p.steps) do
			alt = alt or (st.alt and st.kind == "craft" and st)
		end
		if p.steps[1].alt then
			assert.matches("^Or use stock: %d+x ", d.next.alt)
		end
		local text = table.concat(d.footer, "\n")
		for _, h in ipairs(p.hold) do
			assert.matches(("Keep %d "):format(h.count), text, 1, true)
		end
		for _, e in ipairs(p.fromStock) do
			if e.verdict == "wasteful" and #d.footer < ns.View.MAX_FOOTER then
				assert.matches(e.name .. " x" .. e.crafts .. " from stock:", text, 1, true)
			end
		end
	end)

	it("cards a gap, a training step and a recipe purchase without a runway", function()
		local env = envOf(ns, {})
		local function first(st)
			local p = { steps = { st }, hold = {}, leftovers = {}, fromStock = {}, ageHours = 1, prices = {} }
			return ns.View.describe({ profession = "X", skill = 140, maxSkill = 150, planner = p }, env)
		end
		local gap = first({ kind = "gap", from = 140, to = 150, why = "no known or buyable recipe gives skill here" })
		assert.same({ "warn", "Nothing gives skill from 140 to 150" }, { gap.next.color, gap.next.name })
		assert.is_nil(gap.runway)
		local train = first({ kind = "train", name = "Goldthorn Tea", at = 215 })
		assert.same({ "gold", "Train it at the trainer, from 215" }, { train.next.color, train.next.verb })
		local buy = first({ kind = "buyRecipe", name = "Rockscale Cod", item = 6369, price = 2811, learn = 175 })
		assert.same({ "Recipe: Rockscale Cod", "Buy it on the AH for 28s 11c", "learn at 175" }, {
			buy.next.name,
			buy.next.verb,
			buy.next.gain,
		})
		local none = ns.View.describe({
			profession = "X",
			skill = 1,
			maxSkill = 2,
			planner = { steps = {}, hold = {}, leftovers = {}, fromStock = {}, ageHours = 1, prices = {} },
		}, env)
		assert.is_nil(none.next)
		assert.matches("grey", none.empty)
	end)

	-- The cooking plan's first step (1x Big Bear Steak) with the client allowing `can` crafts, beside `dock`.
	local function withCraftable(can, dock, why)
		local have = { [I.LION] = 7, [I.BEAR] = 1 }
		local p = ns.Planner.run((function()
			local input = F.cooking()
			input.have = have
			return input
		end)())
		p.prices, p.ageHours = { live = 10, export = 0, none = 0 }, 2
		local env = envOf(ns, have)
		env.dock = dock
		env.asked = {}
		env.craftable = function(spell)
			env.asked[#env.asked + 1] = spell
			return can, why
		end
		local d = ns.View.describe({ profession = "Cooking", skill = 173, maxSkill = 225, planner = p }, env)
		return d.next, env, d
	end

	it("gives a learned craft step a Craft button for what the bags allow, capped at the step", function()
		local nx, env = withCraftable(5, "tsm")
		assert.same({ nx.spell }, env.asked)
		-- the step wants 1 craft; the bags would allow 5. Its Hot Spices come from a vendor: Buy sits first
		assert.same({ "buy", "craft" }, { nx.actions[1].id, nx.actions[2].id })
		local a = nx.actions[2]
		assert.same({ "craft", nx.spell, 1, true, "Craft 1" }, { a.id, a.spell, a.count, a.enabled, a.label })
		assert.is_nil(a.tip)
		-- fewer than the step wants: craft those, and say so
		local card = { kind = "craft", spell = 9, crafts = 7, mats = {} }
		local some = ns.View.actions(card, {
			craftable = function()
				return 3
			end,
		})
		assert.same({ 3, true, "Craft 3", "Materials for 3 of the 7 crafts" }, {
			some[1].count,
			some[1].enabled,
			some[1].label,
			some[1].tip,
		})
	end)

	it("offers Show recipe beside Blizzard's window only", function()
		local nx = withCraftable(1, "blizzard")
		assert.same({ "buy", "craft", "open" }, { nx.actions[1].id, nx.actions[2].id, nx.actions[3].id })
		assert.same(
			{ "Show recipe", true, nx.spell },
			{ nx.actions[3].label, nx.actions[3].enabled, nx.actions[3].spell }
		)
		assert.equal(2, #withCraftable(1, "tsm").actions)
		assert.equal(2, #withCraftable(1, "free").actions)
	end)

	it("says what to do first when nothing is craftable", function()
		local nx, _, d = withCraftable(0, "blizzard")
		local a = nx.actions[2]
		assert.same({ "craft", 0, false }, { a.id, a.count, a.enabled })
		-- the step buys its spices at the vendor
		assert.equal(("Buy 1 %s first"):format(nx.mats[2].name), a.label)
		assert.is_nil(a.tip)
		assert.equal("open", nx.actions[3].id)
		-- no vendor open: Buy is there, off, and says where to go
		local closed = nx.actions[1]
		assert.same({ "buy", false }, { closed.id, closed.enabled })
		assert.equal(("Buy 1 %s at a vendor"):format(nx.mats[2].name), closed.label)
		assert.matches("[" .. a.label .. "] (not yet)", table.concat(ns.View.text(d), "\n"), 1, true)
		local none = function()
			return 0
		end
		-- several blockers: the first on the button, all of them in the tip
		local card = {
			kind = "craft",
			spell = 9,
			crafts = 4,
			mats = {
				{ name = "Gray Dye", have = 0, need = 7, buy = { count = 7 } },
				{ name = "Bolt of Silk", have = 2, need = 8 },
			},
			pre = { { count = 2, name = "Fine Thread" } },
		}
		local b = ns.View.actions(card, { craftable = none })[1]
		assert.equal("Buy 7 Gray Dye first", b.label)
		assert.equal("Buy 7 Gray Dye first\nCraft 2 Fine Thread first", b.tip)
		-- nothing to buy or pre-craft: the short material
		card.mats[1].buy, card.pre = nil, nil
		assert.equal("Need 7 more Gray Dye", ns.View.actions(card, { craftable = none })[1].label)
		-- the plan counts it covered (bank stock) but the client cannot craft
		card.mats = { { name = "Bolt of Silk", have = 8, need = 8 } }
		assert.equal("Materials missing from your bags", ns.View.actions(card, { craftable = none })[1].label)
	end)

	it("buys a step's vendor reagents at an open merchant that sells them", function()
		local card = {
			kind = "craft",
			spell = 9,
			crafts = 7,
			mats = {
				{ item = 1, name = "Lion Meat", have = 7, need = 7 },
				{ item = 2, name = "Hot Spices", have = 0, need = 7, buy = { count = 7, where = "vendor" } },
				{ item = 3, name = "Lion Hide", have = 0, need = 2, buy = { count = 2, where = "AH" } },
			},
		}
		local offers = { [2] = { index = 4, price = 40, lot = 1, maxStack = 20, available = -1 } }
		local env = {
			money = ns.Logic.money,
			craftable = function()
				return 0
			end,
			merchant = function(item)
				return offers[item], "this vendor does not sell it"
			end,
			gold = function()
				return 10000
			end,
			bagRoom = function()
				return 100
			end,
		}
		local a = ns.View.actions(card, env)[1]
		-- only the vendor row, and only what it is short of; AH rows are not bought here
		assert.same({ "buy", true, "Buy 7 Hot Spices, 2s 80c", 280 }, { a.id, a.enabled, a.label, a.cost })
		assert.same({ { item = 2, name = "Hot Spices", index = 4, qty = 7, cost = 280, calls = { 7 } } }, a.items)
		assert.is_nil(a.tip)
		-- 3 already in the bags: buys the other 4
		card.mats[2].have = 3
		assert.equal(4, ns.View.actions(card, env)[1].items[1].qty)
		-- covered: no Buy button
		card.mats[2].have = 7
		assert.equal("craft", ns.View.actions(card, env)[1].id)
	end)

	it("keeps Buy off with the reason when the vendor lacks it, gold is short or the bags are full", function()
		local want = { { item = 2, name = "Hot Spices", count = 7 } }
		local offer = { index = 1, price = 40, lot = 1, maxStack = 20 }
		local env = {
			money = ns.Logic.money,
			merchant = function()
				return offer
			end,
		}
		local V = ns.View
		-- no merchant open
		local closed = V.buyAction(want, { money = ns.Logic.money })
		assert.same({ false, "Buy 7 Hot Spices at a vendor" }, { closed.enabled, closed.label })
		-- this vendor does not sell it
		local wrong = V.buyAction(want, {
			money = ns.Logic.money,
			merchant = function()
				return nil, "this vendor does not sell it"
			end,
		})
		assert.same({ false, "Buy Hot Spices: this vendor does not sell it" }, { wrong.enabled, wrong.label })
		-- gold short
		env.gold = function()
			return 100
		end
		local poor = V.buyAction(want, env)
		assert.same(
			{ false, "Not enough gold: 2s 80c needed", "You have 1s 0c." },
			{ poor.enabled, poor.label, poor.tip }
		)
		-- bags full
		env.gold = function()
			return 10000
		end
		env.bagRoom = function()
			return 5
		end
		local full = V.buyAction(want, env)
		assert.same({ false, "Buy Hot Spices: bags full, room for 5" }, { full.enabled, full.label })
		-- two reagents, one sold here: buys that one, the tip names the other
		env.bagRoom = nil
		local two = { want[1], { item = 9, name = "Gray Dye", count = 7 } }
		env.merchant = function(item)
			if item == 2 then
				return offer
			end
			return nil, "this vendor does not sell it"
		end
		local some = V.buyAction(two, env)
		assert.same({ true, "Buy 7 Hot Spices, 2s 80c" }, { some.enabled, some.label })
		assert.equal("7 Hot Spices, 2s 80c\nNot here: Gray Dye: this vendor does not sell it", some.tip)
		assert.is_nil(V.buyAction({}, env))
	end)

	it("gives no buttons to an unlearned recipe, a step that is not a craft, or an env without craftable", function()
		local nx = withCraftable(nil, "blizzard", "recipe not learned")
		assert.is_nil(nx.actions)
		assert.equal("recipe not learned", nx.actionsWhy)
		local have = { [I.LION] = 7, [I.BEAR] = 1 }
		assert.is_nil(ns.View.actions({ kind = "train", spell = 1 }, { craftable = error }))
		assert.is_nil(ns.View.actions({ kind = "craft" }, { craftable = error }))
		local acts, why = ns.View.actions({ kind = "craft", spell = 1 }, envOf(ns, have))
		assert.same({ nil, "env.craftable missing" }, { acts, why })
	end)

	it("sizes the panel to its content and scrolls only past the dock's height", function()
		local V = ns.View
		assert.same({ height = 260, scroll = false }, V.fit(200, 60, 500))
		assert.same({ height = 500, scroll = false }, V.fit(440, 60, 500))
		assert.same({ height = 500, scroll = true }, V.fit(441, 60, 500))
		-- a one-line message still leaves a panel to read and grab
		assert.same({ height = V.MIN_HEIGHT, scroll = false }, V.fit(10, 40, 500))
	end)

	it("describes a message without a skill as one line", function()
		local d = ns.View.describe({ why = "not your own profession window: NPC crafting", state = "not now" }, {})
		assert.is_nil(d.next)
		assert.same({ "message", "ash" }, { d.state, d.tone })
		assert.same({ "not your own profession window: NPC crafting" }, ns.View.text(d))
	end)
end)
