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
		local d, p = cooking(have)
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
		-- with a shopping list the row points to it; without one it names the place and price
		local listed = false
		for _, r in ipairs(p.shopping and p.shopping.vendor or {}) do
			listed = listed or r.item == nx.mats[2].item
		end
		local want = listed and "0/1, on the list" or "buy 1, vendor 40c"
		assert.same({ want, false }, { nx.mats[2].right, nx.mats[2].covered })
		-- the runway runs to the next colour change of the step's own recipe (150/190)
		assert.same({ "green", 190, "17 to grey" }, { d.runway.color, d.runway.target, d.runway.label })
		-- prices are live and recent: no stale line
		assert.is_nil(d.header.stale)
	end)

	it("lists every later step as a numbered row, with no cap", function()
		local d, p = cooking({ [I.LION] = 7, [I.BEAR] = 1 })
		assert.same(
			{ 2, "orange", "7x Hot Lion Chops, from stock" },
			{ d.later[1].n, d.later[1].color, d.later[1].text }
		)
		assert.equal("173 to 180", d.later[1].right)
		assert.equal(#p.steps - 1, #d.later)
		for i, r in ipairs(d.later) do
			assert.equal(i + 1, r.n)
		end
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

	it("shows a buy step's stock alternative, and the hold list and verdicts under Shopping's Stock", function()
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
		local text = table.concat(d.shopping.stock, "\n")
		for _, h in ipairs(p.hold) do
			assert.matches(("Keep %d "):format(h.count), text, 1, true)
		end
		for _, e in ipairs(p.fromStock) do
			if e.verdict == "wasteful" then
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
		-- two reagents, both refused for the same reason: the reason is on the button
		local both = V.buyAction({ want[1], { item = 9, name = "Gray Dye", count = 7 } }, env)
		assert.same({ false, "Buy 2 reagents: bags full, room for 5" }, { both.enabled, both.label })
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

describe("AH trip on the Next card", function()
	local function model(skill, plan)
		return { skill = skill, maxSkill = 150, profession = "Leatherworking", planner = plan }
	end

	it("shows one list for the stretch with spares, and the Add to AH list button", function()
		local ns = load()
		local plan = ns.Planner.run(F.input(F.LEATHER, F.LEATHER_LEARNED, 109, 150, {}))
		plan.profKey = "Leatherworking"
		local env = envOf(ns, {})
		local d = ns.View.describe(model(109, plan), env)
		local trip = d.next.trip
		assert.is_truthy(trip.title:find("^One AH trip: "))
		assert.equal("Leatherworking", trip.prof)
		local light
		for _, r in ipairs(trip.rows) do
			if r.item == I.LIGHT then
				light = r
			end
		end
		-- the buy step already covers the p90, so the row has no separate spare count
		assert.is_nil(light.right:find("spare"))
		assert.equal(10 * plan.steps[1].crafts, light.count)
		-- the button sits on the Shopping tab, over the list it keeps
		assert.equal("trip", d.shopping.trip.id)
		assert.is_truthy(d.shopping.trip.label:find("^Add to AH list"))

		env.savedTrip = function(prof)
			return prof == "Leatherworking" and {} or nil
		end
		assert.equal("untrip", ns.View.describe(model(109, plan), env).shopping.trip.id)
	end)

	local function noteWith(card, prefix)
		for _, n in ipairs(card.notes) do
			if n:find(prefix, 1, true) == 1 then
				return n
			end
		end
	end

	it("a buy step says it is bought for a bad-luck run and offers no alt on earmarked leather", function()
		local ns = load()
		local plan = ns.Planner.run(F.input(F.LEATHER, F.LEATHER_LEARNED, 112, 150, { [I.MEDIUM] = 96 }))
		local d = ns.View.describe(model(112, plan), envOf(ns, { [I.MEDIUM] = 96 }))
		local st = plan.steps[1]
		assert.equal("Light Leather Pants", st.name)
		assert.is_nil(d.next.alt)
		assert.equal(
			("Bought for a bad-luck run: usually %d crafts, up to %d"):format(math.ceil(st.expected - 1e-6), st.crafts),
			noteWith(d.next, "Bought for a bad-luck run")
		)
		assert.is_nil(noteWith(d.next, "On your AH list"))
	end)

	it("a committed step says the recipe holds until its target", function()
		local ns = load()
		local first = ns.Planner.run(F.input(F.LEATHER, F.LEATHER_LEARNED, 109, 150, {}))
		local commit = first.trip.commit
		local plan = ns.Planner.run(F.input(F.LEATHER, F.LEATHER_LEARNED, 111, 150, {}, { commit = commit }))
		local d = ns.View.describe(model(111, plan), envOf(ns, {}))
		assert.equal(
			("On your AH list: this recipe holds until %d"):format(math.floor(plan.steps[1].to)),
			noteWith(d.next, "On your AH list")
		)
		assert.is_nil(d.next.alt)
	end)
end)

describe("Cap model on the panel", function()
	local ns
	before_each(function()
		ns = load()
	end)

	local function craft(spell, extra)
		local st = {
			kind = "craft",
			spell = spell,
			name = "Recipe " .. spell,
			crafts = 3,
			from = 100,
			to = 103,
			points = 3,
			color = "orange",
			used = {},
			buy = { { item = 2318, count = 6, each = 20, where = "ah" } },
		}
		for k, v in pairs(extra or {}) do
			st[k] = v
		end
		return st
	end

	local function plan(steps, extra)
		local p = { steps = steps, hold = {}, leftovers = {}, fromStock = {}, ageHours = 1, prices = {} }
		for k, v in pairs(extra or {}) do
			p[k] = v
		end
		return p
	end

	local function show(p, env)
		local m = { profession = "Leatherworking", skill = 100, maxSkill = 150, planner = p }
		local d = ns.View.describe(m, env or envOf(ns, {}))
		return d, table.concat(ns.View.text(d), "\n")
	end

	it("shows a rank step with unknown for what the trainer has not shown", function()
		local env = envOf(ns, {})
		local st = { kind = "trainRank", name = "Expert", cap = 225, level = 20, cost = 50000, skill = 125 }
		assert.equal("Train Expert (225) — level 20, 5g 0s 0c", ns.View.rankLine(st, env))
		assert.equal(
			"Train Artisan (300) — level unknown, cost unknown",
			ns.View.rankLine({ name = "Artisan", cap = 300 }, env)
		)
		local d = show(plan({ craft(1), st, { kind = "trainRank", name = "Artisan", cap = 300 } }))
		assert.same({ "Train Expert (225)", "level 20, 5g 0s 0c" }, { d.later[1].text, d.later[1].right })
		assert.same({ "Train Artisan (300)", "level unknown, cost unknown" }, { d.later[2].text, d.later[2].right })
		local card = show(plan({ st }))
		assert.same(
			{ "gold", "Train Expert (225)", "needs skill 125" },
			{ card.next.color, card.next.name, card.next.gain }
		)
	end)

	it("notes the rank to train inside a craft step, the hard stop and the plan's coverage", function()
		local up = { name = "Expert", at = 125, by = 150 }
		local d, all = show(plan({ craft(1, { rankUp = up }) }, {
			capBlock = { name = "Artisan", level = 35, have = 30, cap = 300 },
			coverage = { to = 140 },
		}))
		assert.matches("Train Expert between 125 and 150", all, 1, true)
		assert.equal("Artisan needs level 35, you are 30", d.capBlock)
		assert.matches("^Artisan needs level 35, you are 30", d.notice)
		assert.equal("Data/Plan.lua covers to 140", d.more.data[1])
		-- coverage up to the cap says nothing: no data lines, but the tab holds the settings and is never dimmed
		local full = show(plan({ craft(1) }, { coverage = { to = 150 } }))
		assert.same({}, full.more.data)
		assert.is_string(full.more.empty)
		assert.is_false(full.tabs[4].empty)
		assert.equal("Artisan needs level unknown, you are unknown", ns.View.capBlockLine({ name = "Artisan" }))
	end)

	it("says why an empty plan is empty at the cap: Poisons rises with the character level", function()
		local V = ns.View
		assert.equal(
			"At your cap (175). Poisons rises 5 per character level.",
			V.atCapLine({ skill = 175, maxSkill = 175, profession = "Poisons", professionID = 40 })
		)
		assert.equal(
			"At your cap (175). Poisons rises 5 per character level.",
			V.atCapLine({ skill = 175, maxSkill = 175, profession = "Poisons" })
		)
		assert.equal(
			"At your cap (150): the next rank at the trainer raises it.",
			V.atCapLine({ skill = 150, maxSkill = 150, profession = "Cooking", professionID = 185 })
		)
		assert.equal("At the top skill (300).", V.atCapLine({ skill = 300, maxSkill = 300, profession = "Cooking" }))
		assert.is_nil(V.atCapLine({ skill = 140, maxSkill = 150, profession = "Poisons" }))
		assert.is_nil(V.atCapLine({}))
	end)

	it("lists other ways cheapest first, special teachers named", function()
		local others = {
			{ spell = 2, name = "Tea", extra = 900, src = "special", teacher = "a dungeon NPC" },
			{ spell = 3, name = "Bread", extra = 120, src = "trainer" },
			{ spell = 4, name = "Pie", extra = 50, src = "special" },
		}
		local d, all = show(plan({ craft(1, { others = others }) }))
		assert.same({
			"Other way: Pie, +50c (special NPC / dungeon)",
			"Other way: Bread, +1s 20c (trainer)",
			"Other way: Tea, +9s 0c (special NPC / dungeon: a dungeon NPC)",
		}, d.next.others)
		assert.matches("Other way: Pie", all, 1, true)
	end)

	it("gives each other way a Use this button, except a gated one and the and-more line", function()
		local others = {
			{ spell = 2, name = "Bread", extra = 120, src = "trainer" },
			{ spell = 3, name = "Pie", extra = 50, src = "special", gated = true },
			{ spell = 4, name = "Tea", extra = 300, src = "known" },
			{ spell = 5, name = "Soup", extra = 400, src = "known" },
		}
		local d = show(plan({ craft(1, { others = others }) }))
		local rows = d.next.otherRows
		assert.equal(4, #rows)
		assert.equal("Other way: Pie, +50c (special NPC / dungeon)", rows[1].text)
		assert.is_nil(rows[1].use)
		assert.same({ "swap", 2, 1, true, "Use this" }, {
			rows[2].use.id,
			rows[2].use.spell,
			rows[2].use.from,
			rows[2].use.enabled,
			rows[2].use.label,
		})
		assert.same({ "swap", 4 }, { rows[3].use.id, rows[3].use.spell })
		assert.equal("and 1 more ways", rows[4].text)
		assert.is_nil(rows[4].use)
		assert.is_nil(d.next.swapBack)
	end)

	it("a swapped step offers Back to the recipe it replaced, and its Use this replaces that one", function()
		local others = { { spell = 3, name = "Tea", extra = 10, src = "known" } }
		local d = show(plan({ craft(2, { others = others, swapFrom = 1, swapFromName = "Bread" }) }))
		local back = d.next.swapBack
		assert.equal("Your choice, instead of Bread", back.text)
		assert.same({ "unswap", 1, "Back to Bread" }, { back.use.id, back.use.spell, back.use.label })
		local use = d.next.otherRows[1].use
		assert.same({ "swap", 3, 1 }, { use.id, use.spell, use.from })
	end)

	it("a committed step's other ways have no Use this", function()
		local others = { { spell = 3, name = "Tea", extra = 10, src = "known" } }
		local d = show(plan({ craft(2, { others = others, committed = true }) }))
		assert.is_nil(d.next.otherRows[1].use)
	end)

	it("shows a step's shortcuts with Use it and Hide, marks the later row, and says why under More", function()
		local cuts =
			{ { spell = 6, name = "Pie", saves = 150, src = "trainer", needs = "no trainer you opened teaches it" } }
		local d = show(plan({ craft(1, { shortcuts = cuts }), craft(2, { shortcuts = cuts }) }, { shortcuts = 1 }))
		local row = d.next.shortcuts[1]
		assert.equal("Shortcut: Pie saves 1s 50c (needs: no trainer you opened teaches it)", row.text)
		assert.same({ "useShortcut", 6, true }, { row.use.id, row.use.spell, row.use.enabled })
		assert.same({ "hideShortcut", 6 }, { row.hide.id, row.hide.spell })
		assert.matches("· shortcut$", d.later[1].text)
		local data = d.more.data
		assert.matches("1 shortcut %(quest, dungeon or unchecked trainer%) marked on its step", data[#data])
		local gap =
			show(plan({ { kind = "gap", from = 10, to = 20, why = "x", shortcuts = { { spell = 7, name = "Tea" } } } }))
		assert.equal("Fills this gap: Tea", gap.next.shortcuts[1].text)
		local fresh = show(plan({ craft(1) }, { unconfirmed = 3 }))
		data = fresh.more.data
		assert.equal("Visit your trainer once: 3 trainer recipes not confirmed yet", data[#data])
		-- something to act on: the More tab wears a pip
		assert.same({ "more", true }, { fresh.tabs[4].id, fresh.tabs[4].warn })
		assert.is_nil(d.tabs[4].warn)
	end)

	it("marks a trainer recipe not checked at a trainer", function()
		local st = { kind = "train", name = "Goldthorn Tea", at = 215, unchecked = true }
		local d = show(plan({ craft(1), st }))
		assert.equal("Train Goldthorn Tea, not checked at a trainer", d.later[1].text)
		local card = show(plan({ st }))
		assert.equal("not checked at a trainer", card.next.cost)
		local checked = show(plan({ { kind = "train", name = "Bread", at = 50 } }))
		assert.is_nil(checked.next.cost)
	end)

	it("shows plan.shopping once per place in travel order, and the AH block is the list it keeps", function()
		local shopping = {
			order = { "trainer", "vendor", "ah", "vendor" },
			trainer = { { kind = "trainRank", name = "Expert", skill = 125, step = 2 } },
			vendor = { { item = 2320, name = "Thread", count = 4, price = 10, merchant = "Supplies", step = 1 } },
			ah = {
				{ item = 2318, name = "Light Leather", count = 6, price = 20, kind = "reagent", step = 1 },
				{ item = 9000, name = "Pattern", count = 1, price = 5000, kind = "pattern", step = 3 },
			},
		}
		local d, all = show(plan({ craft(1) }, { shopping = shopping, profKey = "Leatherworking" }))
		local titles = {}
		local blocks = d.shopping.blocks
		for _, b in ipairs(blocks) do
			titles[#titles + 1] = b.title
		end
		assert.same({ "Trainer: 0c + 1 unknown", "Vendor: 40c", "Auction House: 51s 20c" }, titles)
		assert.equal("Thread (Supplies)", blocks[2].rows[1].name)
		assert.equal("at 125, cost unknown", blocks[1].rows[1].right)
		-- the blocks live on the Shopping tab only; the card links there
		assert.is_nil(d.next.blocks)
		assert.equal("Total 51s 60c, 3 stops, 1 price unknown", d.shopping.title)
		assert.same(
			{ "shopping", "Shopping: 51s 60c, 3 stops, 1 price unknown", "tab" },
			{ d.next.links[1].tab, d.next.links[1].text, d.next.links[1].action.id }
		)
		assert.same({ "shopping", 3 }, { d.tabs[2].id, d.tabs[2].count })
		-- the step's own buy row points to the list instead of naming a place and a price
		assert.equal("0/6, on the list", d.next.mats[1].right)
		assert.is_nil(all:find("buy 6, AH", 1, true))
		-- without plan.trip the AH block feeds "Add to AH list"
		assert.equal("trip", d.shopping.trip.id)
		local kept = d.next.trip
		assert.same({ 2, true, 5120 }, { #kept.rows, kept.rows[2].recipe, kept.total })
		assert.equal("Leatherworking", kept.prof)
		-- with a trip that starts now, the list it keeps is plan.trip, its commit included
		local trip = {
			fromStep = 1,
			to = 103,
			ends = "cap",
			total = 120,
			commit = { { spell = 1, to = 103 } },
			route = { 1 },
			rows = { { item = 2318, count = 6, buffer = 0, total = 6, each = 20, cost = 120 } },
		}
		local withTrip = show(plan({ craft(1) }, { shopping = shopping, trip = trip, profKey = "Leatherworking" }))
		assert.same(trip.commit, withTrip.next.trip.commit)
		assert.equal(3, #withTrip.shopping.blocks)
		-- without plan.shopping: today's rendering, an empty Shopping tab and no link row
		local old = show(plan({ craft(1) }))
		assert.is_nil(old.shopping.blocks)
		assert.is_string(old.shopping.empty)
		assert.same({}, old.next.links)
		assert.same({ "shopping", true }, { old.tabs[2].id, old.tabs[2].empty })
		assert.equal("buy 6, AH 1s 20c", old.next.mats[1].right)
	end)

	it("describes four tabs in strip order, and Plan when the saved one is unknown", function()
		local d = show(plan({ craft(1), craft(2) }))
		local ids = {}
		for _, t in ipairs(d.tabs) do
			ids[#ids + 1] = t.id .. ":" .. t.label
		end
		assert.same({ "plan:Plan", "shopping:Shopping", "alts:Alts", "more:More" }, ids)
		assert.is_false(d.tabs[1].empty)
		assert.same({ "plan", "alts", "plan" }, { ns.View.tabOf(nil), ns.View.tabOf("alts"), ns.View.tabOf("x") })
		-- a message (no profession) has no tabs
		local msg = ns.View.describe({ why = "Open a profession" }, envOf(ns, {}))
		assert.is_nil(msg.tabs)
	end)

	it("lists the alts' reagents per character with Queue, Queue all and the queued state", function()
		local mail = {
			{ who = "Alta", item = 2318, count = 14 },
			{ who = "Alta", item = 2320, count = 3 },
			{ who = "Bert", item = 2318, count = 2 },
		}
		local env = envOf(ns, {})
		env.queued = function(who, item)
			return who == "Alta" and item == 2320
		end
		env.mailQueue = function()
			return { { alt = "Alta", item = 2320, count = 3 } }
		end
		local used =
			{ { item = 2318, count = 16, mail = { { who = "Alta", count = 14 }, { who = "Bert", count = 2 } } } }
		local d, all = show(plan({ craft(1, { used = used, buy = {} }) }, { mail = mail }), env)
		local a = d.alts
		assert.equal("Counted in the plan: 19 reagents on 2 characters", a.title)
		assert.same({ "Alta", "Bert" }, { a.groups[1].who, a.groups[2].who })
		local r1, r2 = a.groups[1].rows[1], a.groups[1].rows[2]
		assert.same(
			{ "14, not queued", "gold", "mailQueue", "Queue" },
			{ r1.right, r1.tone, r1.action.id, r1.action.label }
		)
		assert.same({ { alt = "Alta", item = 2318, count = 14 } }, r1.action.rows)
		assert.same({ "3, queued", "green", "mailUnqueue" }, { r2.right, r2.tone, r2.action.id })
		-- Queue all takes only the rows not queued yet
		assert.same(
			{ "mailQueue", "Queue all from Alta", 1 },
			{ a.groups[1].all.id, a.groups[1].all.label, #a.groups[1].all.rows }
		)
		assert.equal(2, a.open)
		assert.same({ "Mail queue: Alta sends 3 item 2320" }, a.incoming)
		assert.same({ "alts", 3, true }, { d.tabs[3].id, d.tabs[3].count, d.tabs[3].warn })
		-- the card links to the Alts tab, after Shopping (none here)
		assert.same(
			{ "alts", "Alts: 19 reagents on 2 characters, not queued" },
			{ d.next.links[1].tab, d.next.links[1].text }
		)
		assert.matches("Queue all from Alta", all, 1, true)
		-- nothing from alts: an empty tab that says why
		local none = show(plan({ craft(1) }))
		assert.same({ 0, true }, { #none.alts.groups, none.tabs[3].empty })
		assert.is_string(none.alts.empty)
	end)

	it("offers Show recipe on learned craft rows beside Blizzard's window only", function()
		local learned = { [1] = true, [2] = true }
		local env = envOf(ns, {})
		env.dock = "blizzard"
		env.craftable = function(spell)
			if learned[spell] then
				return 0
			end
			return nil, "recipe not learned"
		end
		local V = ns.View
		local a = V.rowOpen(craft(2), env)
		assert.same({ "open", 2, true }, { a.id, a.spell, a.enabled })
		assert.is_nil(V.rowOpen(craft(3), env)) -- not learned
		assert.is_nil(V.rowOpen({ kind = "train", name = "x", at = 1 }, env))
		assert.is_nil(V.rowOpen({ kind = "trainRank", name = "Expert", cap = 225 }, env))
		assert.is_nil(V.rowOpen({ kind = "buyRecipe", item = 9, name = "x", price = 1 }, env))
		local d = show(plan({ craft(1), craft(2), craft(3), { kind = "train", name = "x", at = 1 } }), env)
		assert.same({ 2, false, false }, { d.later[1].open.spell, d.later[2].open ~= nil, d.later[3].open ~= nil })
		env.dock = "tsm"
		assert.is_nil(V.rowOpen(craft(2), env))
		env.dock = "blizzard"
		env.craftable = nil
		assert.is_nil(V.rowOpen(craft(2), env))
	end)
end)

describe("AH buy rows", function()
	local ns, env
	before_each(function()
		ns = load()
		env = envOf(ns, {})
		env.gold = function()
			return 1000000
		end
	end)

	local reagent = { item = 2318, name = "Light Leather", count = 6, each = 20, committed = true }
	local pattern = { item = 9000, name = "Pattern", count = 1, each = 5000, pattern = true, committed = false }

	it("starts a commodity buy, then asks to confirm the quoted total", function()
		local live = { state = "listed", kind = "commodity", results = { { unitPrice = 22, quantity = 50 } } }
		local r = ns.View.ahRow(reagent, live, env)
		assert.same(
			{ "ahStart", true, 6, "Buy 6 for 1s 32c" },
			{ r.action.id, r.action.enabled, r.action.qty, r.action.label }
		)
		assert.equal("22c each, 1s 32c", r.right)
		live.state = "quoting"
		local q = ns.View.ahRow(reagent, live, env).action
		assert.same({ false, "Getting the price" }, { q.enabled, q.label })
		live.state, live.quote, live.qty = "quoted", { unit = 22, total = 132 }, 6
		local c = ns.View.ahRow(reagent, live, env).action
		assert.same({ "ahConfirm", true, "Confirm 6 for 1s 32c" }, { c.id, c.enabled, c.label })
		live.state = "buying"
		assert.is_false(ns.View.ahRow(reagent, live, env).action.enabled)
		live.state = "bought"
		assert.equal("Bought 6", ns.View.ahRow(reagent, live, env).action.label)
	end)

	it("never drops a committed step's buy when it is sold out or overpriced, and says so", function()
		local none = ns.View.ahRow(reagent, { state = "listed", kind = "commodity", results = {} }, env)
		assert.is_nil(none.skip)
		assert.matches("^Sold out%. For a step you committed to", none.note)
		assert.equal("ahSearch", none.action.id)
		local dear = ns.View.ahRow(reagent, {
			state = "listed",
			kind = "commodity",
			results = { { unitPrice = 40, quantity = 50 } },
		}, env)
		assert.is_nil(dear.skip)
		assert.equal("2.0x the plan's 20c each", dear.warn)
		assert.same({ true, "Buy anyway: 6 for 2s 40c" }, { dear.action.enabled, dear.action.label })
	end)

	it("buys a pattern at its cheapest buyout and marks it for a replan when overpriced or gone", function()
		local live = {
			state = "listed",
			kind = "item",
			results = { { auctionID = 7, buyoutAmount = 4000, quantity = 1 }, { auctionID = 8, buyoutAmount = 6000 } },
		}
		local r = ns.View.ahRow(pattern, live, env)
		assert.same(
			{ "ahBid", 7, 4000, "Buy for 40s 0c" },
			{ r.action.id, r.action.auctionID, r.action.buyout, r.action.label }
		)
		assert.is_nil(r.skip)
		live.results = { { auctionID = 8, buyoutAmount = 9000, quantity = 1 } }
		local over = ns.View.ahRow(pattern, live, env)
		assert.equal("overpriced", over.skip)
		assert.matches("The next plan goes without it", over.note, 1, true)
		live.results = {}
		assert.equal("sold out", ns.View.ahRow(pattern, live, env).skip)
	end)

	it("lets one purchase run at a time and checks the gold", function()
		local live = { state = "listed", kind = "commodity", results = { { unitPrice = 22, quantity = 50 } } }
		env.busy = 9000
		local r = ns.View.ahRow(reagent, live, env)
		assert.same({ false, "Wait: another buy is in progress" }, { r.action.enabled, r.action.label })
		env.busy = nil
		env.gold = function()
			return 100
		end
		local poor = ns.View.ahRow(reagent, live, env)
		assert.same({ false, "Not enough gold: 1s 32c needed" }, { poor.action.enabled, poor.action.label })
	end)

	it("titles the panel with the plan's total, or says the list is empty", function()
		local d = ns.View.ahPanel({ reagent, pattern }, {}, env)
		assert.equal("SkillupHelper AH list: 2 items, plan 51s 20c", d.title)
		assert.equal("Searching the AH", d.rows[1].action.label)
		assert.truthy(ns.View.ahPanel({}, {}, env).empty)
	end)
end)

describe("Shopping by city", function()
	local function blocks(where)
		local ns = load()
		local env = envOf(ns, {})
		env.where = where
		local shopping = {
			order = { "trainer", "vendor", "ah" },
			trainer = { { kind = "trainRank", name = "Expert", skill = 125, cost = 100, step = 2 } },
			vendor = {
				{ item = 2320, name = "Thread", count = 4, price = 10, merchant = "Tamar", step = 1 },
				{ item = 2678, name = "Spice", count = 2, price = 5, merchant = "Innkeeper", step = 1 },
			},
			ah = { { item = 2318, name = "Light Leather", count = 6, price = 20, kind = "reagent", step = 1 } },
		}
		local out = {}
		for _, b in ipairs(ns.View.shoppingBlocks(shopping, env)) do
			out[#out + 1] = b.title
		end
		return out
	end

	it("keeps one block per place in travel order when no city is known", function()
		assert.same({ "Trainer: 1s 0c", "Vendor: 50c", "Auction House: 1s 20c" }, blocks(nil))
	end)

	it("splits the vendor block by city and puts the nearest city first, travel order inside it", function()
		local where = function(place, r)
			if place == "vendor" and r.item == 2678 then
				return "Crossroads", 300
			end
			return "Orgrimmar", 2000
		end
		assert.same({
			"Vendor, Crossroads: 10c",
			"Trainer, Orgrimmar: 1s 0c",
			"Vendor, Orgrimmar: 40c",
			"Auction House, Orgrimmar: 1s 20c",
		}, blocks(where))
	end)

	it("puts blocks of no known city last", function()
		local where = function(place)
			if place == "ah" then
				return "Orgrimmar", nil
			end
			return nil
		end
		assert.same({ "Auction House, Orgrimmar: 1s 20c", "Trainer: 1s 0c", "Vendor: 50c" }, blocks(where))
	end)
end)
