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

describe("Alts.planAttach", function()
	local A = load().Alts
	local function s(n, slot)
		return { bag = 0, slot = slot, n = n }
	end
	local function takes(picks)
		local out = {}
		for k, p in ipairs(picks) do
			out[k] = p.take .. "/" .. p.n
		end
		return out
	end
	it("splits exactly the count from the smallest stack that holds more", function()
		local picks, got = A.planAttach({ s(20, 1), s(5, 2), s(3, 3) }, 4, 12)
		assert.same({ "4/5" }, takes(picks))
		assert.equal(4, got)
		assert.equal(2, A.splitOf(picks).slot)
	end)
	it("sends 3 from a lone stack of 20, not the 20", function()
		local picks, got = A.planAttach({ s(20, 1) }, 3, 12)
		assert.same({ "3/20" }, takes(picks))
		assert.equal(3, got)
	end)
	it("takes a stack of exactly the count whole, with no split", function()
		local picks, got = A.planAttach({ s(20, 1), s(4, 2) }, 4, 12)
		assert.same({ "4/4" }, takes(picks))
		assert.equal(4, got)
		assert.is_nil(A.splitOf(picks))
	end)
	it("takes the largest stacks whole, then splits the rest last", function()
		local picks, got = A.planAttach({ s(20, 1), s(20, 2), s(4, 3), s(1, 4) }, 43, 12)
		assert.same({ "20/20", "20/20", "3/4" }, takes(picks))
		assert.equal(43, got)
		assert.equal(picks[3], A.splitOf(picks))
	end)
	it("sends what the bags hold when that is less than the count, with no split", function()
		local picks, got = A.planAttach({ s(5, 1), s(2, 2) }, 10, 12)
		assert.same({ "5/5", "2/2" }, takes(picks))
		assert.equal(7, got)
		assert.is_nil(A.splitOf(picks))
	end)
	it("stops at the attachment slots", function()
		local stacks = {}
		for k = 1, 15 do
			stacks[k] = s(1, k)
		end
		local picks, got = A.planAttach(stacks, 20, 12)
		assert.equal(12, #picks)
		assert.equal(12, got)
	end)
	it("plans nothing for no stacks or a zero count", function()
		assert.same({}, (A.planAttach({}, 3, 12)))
		assert.same({}, (A.planAttach({ s(5, 1) }, 0, 12)))
	end)
	it("does not change the stacks it is given", function()
		local stacks = { s(20, 1) }
		A.planAttach(stacks, 3, 12)
		assert.equal(20, stacks[1].n)
		assert.is_nil(stacks[1].take)
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
	it("builds the mailbox panel: an exact split, bank, nowhere, and the fill states", function()
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
		-- step 1: the stack of 20 holds more than the 3 wanted, so the button splits 3 off first
		local d = V.mailPanel(groups, live, { free = 2 }, env, A.planAttach, 12)
		local g = d.groups[1]
		assert.equal("3 in bags, split from 20", g.rows[1].right)
		assert.equal("2 in bank: take them out", g.rows[2].right)
		assert.equal("none left here", g.rows[3].right)
		assert.equal("In the bank: take them out, then come back.", g.note.text)
		assert.equal("mailSplit", g.fill.id)
		assert.is_true(g.fill.enabled)
		assert.equal("Split 3 item1 from 20", g.fill.label)
		assert.same({ 1, 0, 1, 20, 3 }, { g.fill.item, g.fill.bag, g.fill.slot, g.fill.n, g.fill.take })
		-- no empty bag slot: the split waits
		g = V.mailPanel(groups, live, { free = 0 }, env, A.planAttach, 12).groups[1]
		assert.equal("mailSplit", g.fill.id)
		assert.is_false(g.fill.enabled)
		assert.equal("Free a bag slot to split 3 item1", g.fill.label)
		-- combat and a pending mail come before the split
		assert.equal(
			"In combat",
			V.mailPanel(groups, live, { combat = true, free = 2 }, env, A.planAttach, 12).groups[1].fill.label
		)
		-- step 2: after the split the bags hold 17 and 3; Fill attaches the 3 whole
		liveData[1] = { bags = 20, stacks = { { bag = 0, slot = 1, n = 17 }, { bag = 0, slot = 2, n = 3 } } }
		g = V.mailPanel(groups, live, { free = 1 }, env, A.planAttach, 12).groups[1]
		assert.equal("3 in bags", g.rows[1].right)
		assert.equal("mailFill", g.fill.id)
		assert.is_true(g.fill.enabled)
		assert.equal("Fill mail to Me: 1 attachment", g.fill.label)
		assert.same({ { bag = 0, slot = 2, n = 3, take = 3, item = 1 } }, g.fill.picks)
		d = V.mailPanel(groups, live, { pending = "Me" }, env, A.planAttach, 12)
		assert.equal("Now press Send", d.groups[1].fill.label)
		assert.is_false(d.groups[1].fill.enabled)
		d = V.mailPanel({}, live, {}, env, A.planAttach, 12)
		assert.equal("Nothing left to mail from this character.", d.empty)
	end)
end)
