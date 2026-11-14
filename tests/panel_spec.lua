-- View.lua, Phase 2 of the panel redesign: the sticky action bar, the Why row, the mats expander, collapsible
-- sections, the step preview with its pager and the step menu. Frame-free; the frames are checked in game.
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
		dock = "blizzard",
		craftable = function()
			return 3
		end,
	}
end

local function cooking(ns, opts)
	local have = { [I.LION] = 7, [I.BEAR] = 1 }
	local input = F.cooking()
	input.have = have
	local p = ns.Planner.run(input)
	p.prices, p.ageHours = { live = 10, export = 0, none = 0 }, 2
	local m = { profession = "Cooking", skill = 173, maxSkill = 225, planner = p }
	return ns.View.describe(m, envOf(ns, have), opts), p
end

local function ids(row)
	local out = {}
	for _, a in ipairs(row) do
		out[#out + 1] = a.id
	end
	return table.concat(out, ",")
end

describe("Sticky action bar", function()
	local V
	before_each(function()
		V = load().View
	end)

	it("puts mail and Buy on rows of their own above Craft and Show recipe", function()
		local card = {
			actions = {
				{ id = "mailQueue", label = "Queue mail" },
				{ id = "buy", label = "Buy" },
				{ id = "craft", label = "Craft 3" },
				{ id = "open", label = "Show recipe" },
			},
		}
		local rows = V.actionBar(card)
		assert.same({ "mailQueue", "buy", "craft,open" }, { ids(rows[1]), ids(rows[2]), ids(rows[3]) })
	end)

	it("leaves out empty rows and has no bar without actions", function()
		local rows = V.actionBar({ actions = { { id = "craft" } } })
		assert.equal(1, #rows)
		assert.equal("craft", ids(rows[1]))
		assert.is_nil(V.actionBar({}))
		assert.is_nil(V.actionBar({ actions = {} }))
	end)

	it("builds the bar for the Next card in describe", function()
		local d = cooking(load())
		local bar = d.next.bar
		assert.is_table(bar)
		local last = bar[#bar]
		assert.equal("craft", last[1].id)
		assert.equal("open", last[2].id)
	end)
end)

describe("Why row", function()
	local V
	before_each(function()
		V = load().View
	end)

	it("shows the first note and +N folded, every line open", function()
		local card = { key = "k", notes = { "a", "b" }, alt = "Or use stock", tags = "Last use" }
		local folded = V.whyRow(card, false)
		assert.same({ "a" }, { folded.lines[1].text, folded.lines[2] })
		assert.equal(3, folded.more)
		assert.same({ "why", "k", "+3" }, { folded.toggle.id, folded.toggle.key, folded.toggle.label })
		local open = V.whyRow(card, true)
		assert.equal(4, #open.lines)
		assert.equal("less", open.toggle.label)
		assert.is_true(open.open)
	end)

	it("has no toggle for one line and no row for none", function()
		local one = V.whyRow({ key = "k", notes = { "only" } }, false)
		assert.equal(1, #one.lines)
		assert.is_nil(one.toggle)
		assert.is_nil(V.whyRow({ key = "k", notes = {} }, false))
	end)

	it("leaves the other ways to the Way menu when the card has one", function()
		local card = { key = "k", notes = {}, others = { "Other way" }, way = { items = {} } }
		assert.is_nil(V.whyRow(card, true))
		card.way = nil
		assert.equal("Other way", V.whyRow(card, true).lines[1].text)
	end)

	it("opens only for the card it was opened on", function()
		local d = cooking(load(), { whyOpen = "not this card" })
		if d.next.why and d.next.why.toggle then
			assert.is_false(d.next.why.open)
		end
	end)
end)

describe("Mats expander", function()
	local V
	before_each(function()
		V = load().View
	end)

	local function card(n)
		local c = { key = "k", mats = {} }
		for i = 1, n do
			c.mats[i] = { name = "m" .. i }
		end
		return c
	end

	it("cuts to five rows with N more reagents", function()
		local c = V.foldMats(card(8), false)
		assert.equal(5, #c.mats)
		assert.equal(8, c.allMats)
		assert.same({ "mats", "k", "3 more reagents" }, { c.matsToggle.id, c.matsToggle.key, c.matsToggle.label })
		assert.equal("1 more reagent", V.foldMats(card(6), false).matsToggle.label)
	end)

	it("keeps every row open, and needs no expander for five or fewer", function()
		local c = V.foldMats(card(8), true)
		assert.equal(8, #c.mats)
		assert.equal("Fewer reagents", c.matsToggle.label)
		assert.is_nil(V.foldMats(card(5), false).matsToggle)
	end)
end)

describe("Step preview", function()
	local ns
	before_each(function()
		ns = load()
	end)

	it("gives every later step a preview action and selects the previewed one", function()
		local d = cooking(ns, { preview = 3 })
		for _, r in ipairs(d.later) do
			assert.same({ "preview", r.n }, { r.preview.id, r.preview.step })
			assert.equal(r.n == 3 or nil, r.selected)
		end
	end)

	it("shows the step on the card with a pager and no craft", function()
		local now, p = cooking(ns)
		local d = cooking(ns, { preview = 2 })
		assert.is_true(d.next.previewing)
		assert.equal(now.next.key, d.now.key)
		assert.not_equal(now.next.key, d.next.key)
		assert.same({ 2, #p.steps, "Step 2 of " .. #p.steps }, { d.pager.index, d.pager.total, d.pager.text })
		for _, a in ipairs(d.next.actions) do
			assert.not_equal("craft", a.id)
			assert.not_equal("buy", a.id)
		end
		assert.equal("now", d.next.actions[1].id)
		assert.is_false(d.next.actions[1].enabled)
		assert.equal("Step 1 comes first", d.next.actions[1].label)
		-- the runway still runs for step 1
		assert.equal(now.runway.target, d.runway.target)
		local text = table.concat(ns.View.text(d), "\n")
		assert.matches("< Step 2 of", text, 1, true)
	end)

	it("ignores a step the plan does not have, and step 1", function()
		local _, p = cooking(ns)
		assert.is_nil(cooking(ns, { preview = #p.steps + 1 }).pager)
		assert.is_nil(cooking(ns, { preview = 1 }).pager)
	end)

	it("pages back to now from step 2 and stops at the last step", function()
		local pg = ns.View.pager(2, 9)
		assert.same({ 1, true }, { pg.prev.step, pg.prev.enabled })
		assert.same({ 3, true }, { pg.next.step, pg.next.enabled })
		assert.equal(1, pg.back.step)
		assert.is_false(ns.View.pager(9, 9).next.enabled)
	end)

	it("offers Show recipe on a previewed craft step that is learned beside Blizzard's window", function()
		local acts = ns.View.previewActions({ kind = "craft", spell = 7 }, envOf(ns, {}))
		assert.same({ "now", "open" }, { acts[1].id, acts[2].id })
		assert.equal("Show recipe", acts[2].label)
		assert.equal(1, #ns.View.previewActions({ kind = "train" }, envOf(ns, {})))
	end)
end)

describe("Step menu", function()
	local V
	before_each(function()
		V = load().View
	end)

	it("lists preview, Show recipe and, while previewing, Back to now", function()
		local row = {
			n = 4,
			text = "3x Thing",
			preview = { id = "preview", step = 4, enabled = true, label = "Preview this step" },
			open = { id = "open", spell = 9, enabled = true, label = "Show" },
		}
		local m = V.stepMenu(row, true)
		assert.equal("Step 4", m.title)
		assert.same(
			{ "Preview this step", "Show recipe", "Back to now" },
			{ m.items[1].label, m.items[2].label, m.items[3].label }
		)
		assert.equal(9, m.items[2].spell)
		assert.equal(2, #V.stepMenu(row, false).items)
	end)
end)

describe("Collapsible sections", function()
	local V
	before_each(function()
		V = load().View
	end)

	local shop = {
		title = "Total 1g, 2 stops",
		blocks = {
			{
				place = "vendor",
				city = "Ironforge",
				title = "Vendor, Ironforge: 40c",
				rows = { { name = "a", right = "1" } },
			},
			{ place = "ah", title = "Auction House: 1g", rows = { { name = "b", right = "2" } } },
		},
		stock = { "Keep 3 x" },
	}

	local function kinds(items)
		local out = {}
		for _, it in ipairs(items) do
			out[#out + 1] = it.kind
		end
		return table.concat(out, ",")
	end

	it("opens the place sections and folds Stock until the user opens it", function()
		local items = V.shoppingItems(shop, {})
		assert.equal("line,gap,head,row,gap,head,row,gap,head", kinds(items))
		assert.same({ "shop:vendor:Ironforge", false }, { items[3].key, items[3].collapsed })
		assert.same({ "stock", true, true }, { items[9].key, items[9].collapsed, items[9].action.collapsed })
		local open = V.shoppingItems(shop, { stock = false })
		assert.equal("line", open[#open].kind)
	end)

	it("hides a folded section's rows and keeps its head", function()
		local items = V.shoppingItems(shop, { ["shop:vendor:Ironforge"] = true })
		assert.equal("line,gap,head,gap,head,row,gap,head", kinds(items))
		assert.equal("section", items[3].action.id)
	end)

	it("keeps Queue all under a folded character", function()
		local a = {
			title = "Counted",
			groups = {
				{
					who = "Alt",
					rows = { { name = "Bar", right = "3", tone = "gold", action = { id = "mailQueue" } } },
					all = { id = "mailQueue" },
				},
			},
			incoming = { "From Alt: 3 Bar" },
		}
		assert.equal("line,gap,head,row,button,gap,head,line", kinds(V.altsItems(a, {})))
		assert.equal("line,gap,head,button,gap,head", kinds(V.altsItems(a, { ["alt:Alt"] = true, incoming = true })))
		assert.equal("Alt (1)", V.altsItems(a, {})[3].text)
	end)
end)
