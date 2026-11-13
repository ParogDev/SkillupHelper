-- Alts.lua (the alts' stock from TSM and the mail queue), Planner.mailFrom and View's mail models.
local function load()
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "TSM.lua", "Alts.lua", "View.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

describe("Alts.roster", function()
	local A = load().Alts
	it("lists the characters of one faction and realm without the current one", function()
		local db =
			{ _scopeKeys = { sync = { "Bob - Horde - R", "Al - Horde - R", "Me - Horde - R", "Cy - Alliance - R" } } }
		assert.same({ "Al", "Bob" }, A.roster(db, "Horde - R", "Me"))
	end)
	it("names the broken link when TSM's settings are missing or changed", function()
		local names, why = A.roster(nil, "Horde - R", "Me")
		assert.is_nil(names)
		assert.matches("TradeSkillMasterDB missing", why)
		names, why = A.roster({}, "Horde - R", "Me")
		assert.is_nil(names)
		assert.matches("_scopeKeys.sync missing", why)
	end)
end)

describe("Alts.stock", function()
	local A = load().Alts
	it("sums bags, bank and mail per alt, most units first, and skips items no alt holds", function()
		local data = { Al = { [1] = { 2, 1, 0 } }, Bob = { [1] = { 0, 0, 5 }, [2] = { 0, 0, 0 } } }
		local q = function(item, name)
			local t = data[name][item] or { 0, 0, 0 }
			return t[1], t[2], t[3]
		end
		local stock, counts = A.stock({ [1] = true, [2] = true, [3] = true }, { "Al", "Bob" }, q, function(item)
			return item == 3 and 0 or nil
		end)
		-- bag units first: Al's 2 in bags beat Bob's 5 in the mailbox
		assert.same({ "Al", "Bob" }, { stock[1][1].who, stock[1][2].who })
		assert.equal(3, stock[1][1].n)
		assert.equal(5, stock[1][2].n)
		assert.is_nil(stock[2])
		assert.is_nil(stock[3])
		assert.same({ alts = 2, items = 1, units = 8, errors = 0 }, counts)
	end)
	it("counts a failed read and keeps its reason", function()
		local _, counts = A.stock({ [1] = true }, { "Al" }, function()
			return nil, "boom"
		end)
		assert.equal(1, counts.errors)
		assert.equal("boom", counts.lastError)
	end)
end)

describe("Alts mail queue", function()
	local A = load().Alts
	it("queues by setting the count, never adding, and never to the sender itself", function()
		local q = {}
		assert.is_true(A.enqueue(q, "Al", "Me", 10, 3))
		assert.is_true(A.enqueue(q, "Al", "Me", 10, 5))
		assert.is_false(A.enqueue(q, "Me", "Me", 10, 5))
		assert.same({ Al = { { item = 10, count = 5, to = "Me" } } }, q)
	end)
	it("groups an alt's queue by recipient and lists what is queued to one character", function()
		local q = {}
		A.enqueue(q, "Al", "Me", 20, 1)
		A.enqueue(q, "Al", "Me", 10, 2)
		A.enqueue(q, "Al", "Zed", 10, 4)
		A.enqueue(q, "Bob", "Me", 10, 3)
		local g = A.forAlt(q, "Al")
		assert.same({ "Me", "Zed" }, { g[1].to, g[2].to })
		assert.same({ { item = 10, count = 2 }, { item = 20, count = 1 } }, g[1].rows)
		assert.same({
			{ alt = "Al", item = 10, count = 2 },
			{ alt = "Al", item = 20, count = 1 },
			{ alt = "Bob", item = 10, count = 3 },
		}, A.toMe(q, "Me"))
	end)
	it("drops what a sent mail carried, and the alt once its list is empty", function()
		local q = {}
		A.enqueue(q, "Al", "Me", 10, 5)
		A.enqueue(q, "Al", "Me", 20, 2)
		A.sent(q, "Al", "Me", { [10] = 3, [20] = 20 })
		assert.same({ Al = { { item = 10, count = 2, to = "Me" } } }, q)
		A.sent(q, "Al", "Me", { [10] = 2 })
		assert.is_nil(q.Al)
	end)
	it("removes one row, and the alt with its last row", function()
		local q = {}
		A.enqueue(q, "Al", "Me", 10, 5)
		A.enqueue(q, "Al", "Zed", 10, 5)
		assert.is_true(A.remove(q, "Al", "Me", 10))
		assert.is_false(A.remove(q, "Al", "Me", 10))
		assert.is_true(A.remove(q, "Al", "Zed", 10))
		assert.same({}, q)
	end)
end)

describe("Alts.pickStacks", function()
	local A = load().Alts
	local function s(n, slot)
		return { bag = 0, slot = slot, n = n }
	end
	it("takes the smallest stack that covers the count", function()
		local picks, got = A.pickStacks({ s(20, 1), s(5, 2), s(3, 3) }, 4, 12)
		assert.equal(1, #picks)
		assert.equal(5, got)
	end)
	it("takes the largest stacks, then the smallest that covers the rest", function()
		local picks, got = A.pickStacks({ s(20, 1), s(20, 2), s(4, 3), s(1, 4) }, 43, 12)
		assert.same({ 20, 20, 4 }, { picks[1].n, picks[2].n, picks[3].n })
		assert.equal(44, got)
	end)
	it("stops at the attachment slots and at what the bags hold", function()
		local stacks = {}
		for k = 1, 15 do
			stacks[k] = s(1, k)
		end
		local picks, got = A.pickStacks(stacks, 20, 12)
		assert.equal(12, #picks)
		assert.equal(12, got)
	end)
end)

describe("Planner.mailFrom", function()
	local P = load().Planner
	it("uses own units first, then alts largest first, and totals per alt and item", function()
		local steps = {
			{ kind = "craft", used = { { item = 10, count = 4 } } },
			{ kind = "craft", used = { { item = 10, count = 6 } } },
		}
		local alts = { [10] = { { who = "Bob", n = 5 }, { who = "Al", n = 5 } } }
		local mail = P.mailFrom(steps, { [10] = 3 }, alts)
		assert.same({ { who = "Bob", count = 1 } }, steps[1].used[1].mail)
		assert.same({ { who = "Bob", count = 4 }, { who = "Al", count = 2 } }, steps[2].used[1].mail)
		assert.same({ { who = "Al", item = 10, count = 2 }, { who = "Bob", item = 10, count = 5 } }, mail)
	end)
	it("marks nothing when own units cover the steps", function()
		local steps = { { kind = "craft", used = { { item = 10, count = 4 } } } }
		assert.same({}, P.mailFrom(steps, { [10] = 4 }, { [10] = { { who = "Al", n = 9 } } }))
		assert.is_nil(steps[1].used[1].mail)
	end)
end)

describe("View mail models", function()
	local V = load().View
	local env = {
		nameOf = function(i)
			return "item" .. i
		end,
	}
	it("offers Queue mail while a part is not queued, and the drop state once all is", function()
		local card = { mats = { { item = 10, mail = { { who = "Al", count = 3 } } } } }
		local a = V.mailAction(card)
		assert.equal("mailQueue", a.id)
		assert.equal("Queue mail: 3 reagents from Al", a.label)
		card.mats[1].queued = true
		assert.equal("mailUnqueue", V.mailAction(card).id)
		assert.is_nil(V.mailAction({ mats = { { item = 10 } } }))
	end)
	it("words a material row by alt and queue state", function()
		local r = { item = 10, mail = { { who = "Al", count = 2 }, { who = "Bob", count = 1 } } }
		assert.equal("3 on 2 alts", V.mailWords(r, env))
		r = { item = 10, mail = { { who = "Al", count = 2 } } }
		local q = {
			queued = function(who, item)
				return who == "Al" and item == 10
			end,
		}
		assert.equal("2 queued on Al", V.mailWords(r, q))
		assert.is_true(r.queued)
	end)
	it("builds the mailbox panel: whole-stack overshoot, bank, nowhere, and the fill states", function()
		local groups =
			{ { to = "Me", rows = { { item = 1, count = 3 }, { item = 2, count = 2 }, { item = 3, count = 1 } } } }
		local liveData = {
			[1] = { bags = 20, stacks = { { bag = 0, slot = 1, n = 20 } } },
			[2] = { bags = 0, bank = 5 },
			[3] = {},
		}
		local live = function(i)
			return liveData[i]
		end
		local A = load().Alts
		local d = V.mailPanel(groups, live, {}, env, A.pickStacks, 12)
		local g = d.groups[1]
		assert.equal("sends 20, wants 3", g.rows[1].right)
		assert.equal("2 in bank: take them out", g.rows[2].right)
		assert.equal("none left here", g.rows[3].right)
		assert.is_true(g.fill.enabled)
		assert.equal("Fill mail to Me: 1 stack", g.fill.label)
		assert.matches("Stacks go whole", g.note.text)
		d = V.mailPanel(groups, live, { pending = "Me" }, env, A.pickStacks, 12)
		assert.equal("Now press Send", d.groups[1].fill.label)
		assert.is_false(d.groups[1].fill.enabled)
		d = V.mailPanel({}, live, {}, env, A.pickStacks, 12)
		assert.equal("Nothing left to mail from this character.", d.empty)
	end)
end)
