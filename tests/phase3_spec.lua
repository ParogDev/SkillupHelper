-- Phase 3 of the panel redesign: the More tab's settings (Logic.applySetting, Logic.effortStep, View.moreItems), the
-- Way menu (View.wayMenu, the step menu's "Ways..."), covered Shopping blocks folding themselves. Frame-free.

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
			return (have or {})[item] or 0
		end,
		spellName = function(id)
			return ({ [7] = "Tea", [8] = "Bread" })[id] or ("spell " .. id)
		end,
	}
end

local function find(items, pred)
	for _, it in ipairs(items) do
		if pred(it) then
			return it
		end
	end
end

describe("Logic.applySetting", function()
	local L = load().Logic

	it("writes the keys the slash commands write", function()
		local db = { exclude = { allow = {}, notNow = {} } }
		assert.is_true(L.applySetting(db, { key = "luck", value = 95 }))
		assert.equal(95, db.luck)
		assert.is_true(L.applySetting(db, { key = "effort", value = 50 }))
		assert.equal(50, db.effort)
		assert.is_true(L.applySetting(db, { key = "noRecipeBuys", value = true }))
		assert.is_true(db.noRecipeBuys)
		assert.is_true(L.applySetting(db, { key = "noRecipeBuys", value = false }))
		assert.is_nil(db.noRecipeBuys)
		assert.is_true(L.applySetting(db, { key = "noAlts", value = true }))
		assert.is_true(db.noAlts)
		assert.is_true(L.applySetting(db, { key = "luck" }))
		assert.is_nil(db.luck)
	end)

	it("refuses a luck the planner has no z for, and a negative effort, naming the value", function()
		local db = {}
		local ok, why = L.applySetting(db, { key = "luck", value = 85 })
		assert.is_false(ok)
		assert.matches("luck 85", why)
		ok, why = L.applySetting(db, { key = "effort", value = -1 })
		assert.is_false(ok)
		assert.matches("effort %-1", why)
		assert.is_nil(db.luck)
	end)

	it("toggles the exclusions as /skillup exclude does", function()
		local db = {}
		assert.is_true(L.applySetting(db, { key = "dungeon", value = true }))
		assert.is_true(db.exclude.dungeon)
		L.applySetting(db, { key = "dungeon", value = false })
		assert.is_nil(db.exclude.dungeon)
		-- special: false plans special teachers, nil leaves them out
		L.applySetting(db, { key = "special", value = false })
		assert.is_false(db.exclude.special)
		L.applySetting(db, { key = "special", value = nil })
		assert.is_nil(db.exclude.special)
	end)

	it("keeps allow and notNow apart, as /skillup allow and exclude <id> do", function()
		local db = { exclude = { allow = { [7] = true }, notNow = {} } }
		L.applySetting(db, { key = "notNow", spell = 7, value = true })
		assert.is_true(db.exclude.notNow[7])
		assert.is_nil(db.exclude.allow[7])
		L.applySetting(db, { key = "allow", spell = 7, value = true })
		assert.is_true(db.exclude.allow[7])
		assert.is_nil(db.exclude.notNow[7])
		L.applySetting(db, { key = "allow", spell = 7, value = nil })
		assert.is_nil(db.exclude.allow[7])
		local ok, why = L.applySetting(db, { key = "allow" })
		assert.is_false(ok)
		assert.matches("spell id", why)
	end)

	it("names the broken link without SavedVariables or with an unknown key", function()
		local ok, why = L.applySetting(nil, { key = "luck", value = 90 })
		assert.is_false(ok)
		assert.matches("not loaded", why)
		ok, why = L.applySetting({}, { key = "colour" })
		assert.is_false(ok)
		assert.matches("unknown setting colour", why)
	end)
end)

describe("Logic.effortStep", function()
	local L = load().Logic

	it("walks 0, 5c, 10c, 20c, 50c, 1s, 2s, 5s and stops at the ends", function()
		assert.equal(50, L.effortStep(20, 1))
		assert.equal(10, L.effortStep(20, -1))
		assert.is_nil(L.effortStep(0, -1))
		assert.is_nil(L.effortStep(500, 1))
		-- a value typed with /skillup effort snaps to the next step that way
		assert.equal(50, L.effortStep(30, 1))
		assert.equal(20, L.effortStep(30, -1))
	end)
end)

describe("View.moreItems", function()
	local ns = load()
	local env = envOf(ns)

	local function settings(over)
		local s = { luck = 90, defaultEffort = 20, allow = {}, notNow = {} }
		for k, v in pairs(over or {}) do
			s[k] = v
		end
		return s
	end

	it("draws the Planner controls with the values in use", function()
		local items = ns.View.moreItems({ data = {} }, settings({ luck = 95, effort = 50 }), env, {})
		local luck = find(items, function(i)
			return i.kind == "choice"
		end)
		assert.equal("95%", luck.value)
		assert.equal(#ns.Logic.LUCKS, #luck.menu.items)
		local checked = find(luck.menu.items, function(i)
			return i.checked
		end)
		assert.equal(95, checked.action.value)
		local step = find(items, function(i)
			return i.kind == "stepper"
		end)
		assert.equal("50c", step.value)
		assert.equal(20, step.dec.value)
		assert.equal(100, step.inc.value)
		assert.is_true(step.inc.enabled)
	end)

	it("says the effort is the default and disables - at none", function()
		local items = ns.View.moreItems({ data = {} }, settings({ effort = 0 }), env, {})
		local step = find(items, function(i)
			return i.kind == "stepper"
		end)
		assert.equal("none", step.value)
		assert.is_false(step.dec.enabled)
		items = ns.View.moreItems({ data = {} }, settings(), env, {})
		step = find(items, function(i)
			return i.kind == "stepper"
		end)
		assert.matches("%(default%)", step.value)
	end)

	it("checkboxes show the state and flip it on a click", function()
		local items = ns.View.moreItems({ data = {} }, settings({ noRecipeBuys = true, special = false }), env, {})
		local function box(text)
			return find(items, function(i)
				return i.kind == "check" and i.text:find(text, 1, true) == 1
			end)
		end
		local recipes = box("Suggest recipes")
		assert.is_false(recipes.on)
		assert.equal("noRecipeBuys", recipes.action.key)
		assert.is_false(recipes.action.value) -- turning it on clears noRecipeBuys
		local alts = box("Count reagents")
		assert.is_true(alts.on)
		assert.is_true(alts.action.value) -- turning it off sets noAlts
		local special = box("Special teachers")
		assert.is_true(special.on)
		assert.is_nil(special.action.value) -- off: back to the default (left out)
		special = find(ns.View.moreItems({ data = {} }, settings(), env, {}), function(i)
			return i.kind == "check" and i.text:find("Special", 1, true) == 1
		end)
		assert.is_false(special.on)
		assert.is_false(special.action.value)
	end)

	it("lists shortcuts in use and hidden recipes by name, each with its undo", function()
		local s = settings({ allow = { [8] = true, [7] = true }, notNow = { [9] = true } })
		local items = ns.View.moreItems({ data = {} }, s, env, {})
		local head = find(items, function(i)
			return i.kind == "head" and i.text:find("Shortcuts in use", 1, true)
		end)
		assert.equal("Shortcuts in use (2)", head.text)
		local rows = {}
		for _, i in ipairs(items) do
			if i.kind == "row" then
				rows[#rows + 1] = i
			end
		end
		assert.equal(3, #rows)
		assert.equal("Bread", rows[1].name)
		assert.equal("Tea", rows[2].name)
		assert.equal("Stop using", rows[1].action.label)
		assert.same({ "allow", 8 }, { rows[1].action.key, rows[1].action.spell })
		assert.is_nil(rows[1].action.value)
		assert.equal("spell 9", rows[3].name)
		assert.equal("Offer again", rows[3].action.label)
		assert.equal("notNow", rows[3].action.key)
	end)

	it("folds a section the user folded, and marks the trainer line as something to do", function()
		local more = { data = { "Visit your trainer once: 2 trainer recipes not confirmed yet" } }
		local items = ns.View.moreItems(more, settings(), env, { ["more:planner"] = true })
		assert.is_nil(find(items, function(i)
			return i.kind == "choice"
		end))
		local line = find(items, function(i)
			return i.kind == "line" and i.text:find("Visit your trainer", 1, true)
		end)
		assert.equal("warn", line.color)
	end)
end)

describe("View.wayMenu", function()
	local ns = load()
	local env = envOf(ns)
	local function craft(over)
		local st = { kind = "craft", spell = 1, name = "Bracers", from = 120, to = 130, crafts = 12 }
		for k, v in pairs(over or {}) do
			st[k] = v
		end
		return st
	end

	it("is nil for a step without an alternative, and for train steps", function()
		assert.is_nil(ns.View.wayMenu(craft(), env))
		assert.is_nil(ns.View.wayMenu({ kind = "train", name = "x" }, env))
	end)

	it("lists the plan's pick first, then the others cheapest first, each a swap", function()
		local m = ns.View.wayMenu(
			craft({
				others = {
					{ spell = 3, name = "Belt", extra = 205, src = "known" },
					{ spell = 2, name = "Chain", extra = 120, src = "trainer" },
				},
			}),
			env
		)
		assert.equal("Ways from 120 to 130", m.title)
		assert.equal("Way: Bracers", m.label)
		assert.equal("plan's pick", m.right)
		assert.equal("Bracers (plan's pick)", m.items[1].label)
		assert.is_true(m.items[1].checked)
		assert.equal("Chain +1s 20c (trainer)", m.items[2].label)
		assert.same({ "swap", 2, 1 }, { m.items[2].action.id, m.items[2].action.spell, m.items[2].action.from })
		assert.equal(3, m.items[3].action.spell)
		assert.is_nil(m.back)
	end)

	it("after a swap: your pick, the plan's pick as a radio that swaps back, and Back to", function()
		local m = ns.View.wayMenu(
			craft({ spell = 2, name = "Chain", swapFrom = 1, swapFromName = "Bracers", others = {} }),
			env
		)
		assert.equal("your pick", m.right)
		assert.equal("gold", m.rightColor)
		assert.equal("Bracers (plan's pick)", m.items[2].label)
		assert.equal("unswap", m.items[2].action.id)
		assert.equal("unswap", m.back.id)
		assert.equal("Back to Bracers", m.back.label)
	end)

	it("a gated or committed alternative is shown without an action, with why", function()
		local m = ns.View.wayMenu(
			craft({ committed = true, others = { { spell = 2, name = "Chain", extra = 10, src = "trainer" } } }),
			env
		)
		assert.is_nil(m.items[2].action)
		assert.matches("AH list", m.items[2].tip)
		m = ns.View.wayMenu(craft({ others = { { spell = 2, name = "Chain", extra = 10, gated = true } } }), env)
		assert.is_nil(m.items[2].action)
		assert.matches("shortcut", m.items[2].tip)
	end)

	it("the stock option is a note, and moves out of the Why row", function()
		local st = craft({
			others = { { spell = 2, name = "Chain", extra = 10, src = "trainer" } },
			alt = { crafts = 12, name = "Copper Mace", extra = 300 },
		})
		local m = ns.View.wayMenu(st, env)
		assert.is_true(m.stock)
		assert.equal("note", m.items[3].kind)
		assert.matches("Or use stock: 12x Copper Mace", m.items[3].label)
		local why = ns.View.whyRow({ key = "k", notes = { "n" }, alt = "Or use stock", way = m }, false)
		assert.equal(0, why.more)
	end)

	it("shortcuts become submenus with Use it and Hide after a divider; a gap reads Fill this gap", function()
		local cuts = { { spell = 7, name = "Tea", saves = 100, needs = "quest" } }
		local m =
			ns.View.wayMenu(craft({ others = { { spell = 2, name = "Chain", extra = 1 } }, shortcuts = cuts }), env)
		assert.equal("divider", m.items[3].kind)
		assert.equal("submenu", m.items[4].kind)
		assert.matches("Shortcut: Tea saves 1s", m.items[4].label)
		assert.same({ "useShortcut", "hideShortcut" }, { m.items[4].items[1].id, m.items[4].items[2].id })
		local gap =
			ns.View.wayMenu({ kind = "gap", from = 10, to = 20, shortcuts = { { spell = 7, name = "Tea" } } }, env)
		assert.equal("Fill this gap", gap.label)
		assert.equal("warn", gap.rightColor)
		assert.equal("submenu", gap.items[1].kind)
	end)

	it("the step menu carries the row's ways", function()
		local way = { title = "t", items = {} }
		local m = ns.View.stepMenu({ n = 3, way = way }, false)
		assert.equal(way, m.ways)
		assert.is_nil(ns.View.stepMenu({ n = 3 }, false).ways)
	end)
end)

describe("covered Shopping blocks", function()
	local ns = load()

	it("marks rows the bags now cover, and folds a block whose rows are all covered", function()
		local shopping = {
			order = { "vendor" },
			vendor = {
				{ item = 10, name = "Salt", count = 4, price = 5 },
				{ item = 11, name = "Oil", count = 2, price = 5 },
			},
		}
		local env = envOf(ns, { [10] = 5, [11] = 1 })
		local blocks = ns.View.shoppingBlocks(shopping, env, { [10] = 1 })
		assert.is_true(blocks[1].rows[1].covered)
		assert.is_nil(blocks[1].rows[2].covered)
		assert.is_nil(blocks[1].covered)
		env = envOf(ns, { [10] = 5, [11] = 2 })
		blocks = ns.View.shoppingBlocks(shopping, env, { [10] = 1 })
		assert.is_true(blocks[1].covered)
		local items = ns.View.shoppingItems({ blocks = blocks }, {})
		local head = find(items, function(i)
			return i.kind == "head"
		end)
		assert.is_true(head.collapsed)
		assert.matches("covered$", head.text)
		-- the user's own choice wins
		items = ns.View.shoppingItems({ blocks = blocks }, { [head.key] = false })
		head = find(items, function(i)
			return i.kind == "head"
		end)
		assert.is_false(head.collapsed)
	end)

	it("without the plan's counts nothing is covered", function()
		local shopping = { order = { "vendor" }, vendor = { { item = 10, name = "Salt", count = 4, price = 5 } } }
		local blocks = ns.View.shoppingBlocks(shopping, envOf(ns, { [10] = 50 }))
		assert.is_nil(blocks[1].covered)
	end)
end)
