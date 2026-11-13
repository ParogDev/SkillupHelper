-- Reagents on the player's other characters, from TradeSkillMaster's inventory tracking (TSM_API read calls and the
-- character list in TSM's saved settings; TSM's code and data are never changed), and the mail queue that brings them
-- over. Character names live only in SavedVariables and on screen, never in the selftest.
local _, ns = ...
local A = {}
ns.Alts = A

local SEP = " - " -- TSM's scope key separator: "Name - Faction - Realm", factionrealm "Faction - Realm"
A.MAX_ATTACH = 12 -- ATTACHMENTS_MAX_SEND in Blizzard_MailFrame

-- The characters TSM tracks on one faction and realm, without the current one. db: TradeSkillMasterDB. Returns the
-- names sorted, or nil and the link that broke.
function A.roster(db, factionrealm, me)
	if type(db) ~= "table" then
		return nil, "TradeSkillMasterDB missing (TSM not loaded?)"
	end
	local keys = type(db._scopeKeys) == "table" and db._scopeKeys.sync
	if type(keys) ~= "table" then
		return nil, "TradeSkillMasterDB._scopeKeys.sync missing (TSM changed its settings layout?)"
	end
	local out, seen = {}, {}
	for _, key in ipairs(keys) do
		if type(key) == "string" then
			local at = key:find(SEP, 1, true)
			local name, fr = at and key:sub(1, at - 1), at and key:sub(at + #SEP)
			if name and fr == factionrealm and name ~= me and not seen[name] then
				seen[name] = true
				out[#out + 1] = name
			end
		end
	end
	table.sort(out)
	return out
end

-- The alts' units of each item. items: a set of item IDs; names: A.roster's list; q(item, name) -> bags, bank, mail
-- (numbers, or nil and why); total(item) -> units on all alts or nil (a cheap first filter). Returns
-- stock[item] = { { who, n, bags, bank, mail } } (most units first), and the counts for the selftest.
function A.stock(items, names, q, total)
	local stock = {}
	local counts = { alts = #names, items = 0, units = 0, errors = 0 }
	for item in pairs(items) do
		local sum = total and total(item)
		if sum == nil or sum > 0 then
			local list
			for _, name in ipairs(names) do
				local bags, bank, mail = q(item, name)
				if bags == nil then
					counts.errors = counts.errors + 1
					counts.lastError = bank
				else
					local n = (bags or 0) + (bank or 0) + (mail or 0)
					if n > 0 then
						list = list or {}
						list[#list + 1] = { who = name, n = n, bags = bags or 0, bank = bank or 0, mail = mail or 0 }
					end
				end
			end
			if list then
				-- bag units first: they can be mailed as they are; bank and mail need the alt to take them out
				table.sort(list, function(a, b)
					if a.bags ~= b.bags then
						return a.bags > b.bags
					elseif a.n ~= b.n then
						return a.n > b.n
					end
					return a.who < b.who
				end)
				stock[item] = list
				counts.items = counts.items + 1
				for _, a in ipairs(list) do
					counts.units = counts.units + a.n
				end
			end
		end
	end
	return stock, counts
end

-- A stable key of the stock, so the planner reruns only when it changes.
function A.key(stock)
	local parts = {}
	for item, list in pairs(stock or {}) do
		for _, a in ipairs(list) do
			parts[#parts + 1] = item .. "@" .. a.who .. "=" .. a.n
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- The mail queue: queue[alt] = { { item, count, to } }, one row per alt, item and recipient. Saved account-wide, per
-- faction and realm (the caller hands in that slice).

local function find(list, item, to)
	for k, e in ipairs(list) do
		if e.item == item and e.to == to then
			return k, e
		end
	end
end

-- Queues count units of item from alt to the character to. The count replaces a queued one: queuing what the plan
-- needs twice does not mail it twice.
function A.enqueue(queue, alt, to, item, count)
	if alt == to or count < 1 then
		return false
	end
	queue[alt] = queue[alt] or {}
	local _, e = find(queue[alt], item, to)
	if e then
		e.count = count
	else
		local list = queue[alt]
		list[#list + 1] = { item = item, count = count, to = to }
	end
	return true
end

function A.remove(queue, alt, to, item)
	local list = queue[alt]
	local k = list and find(list, item, to)
	if k then
		table.remove(list, k)
		if #list == 0 then
			queue[alt] = nil
		end
		return true
	end
	return false
end

-- The rows queued to the character to, from every alt: { { alt, item, count } }, alt then item order.
function A.toMe(queue, to)
	local out = {}
	for alt, list in pairs(queue) do
		for _, e in ipairs(list) do
			if e.to == to then
				out[#out + 1] = { alt = alt, item = e.item, count = e.count }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.alt ~= b.alt then
			return a.alt < b.alt
		end
		return a.item < b.item
	end)
	return out
end

-- The alt's queue grouped by recipient: { { to, rows = { { item, count } } } }, recipients and items sorted.
function A.forAlt(queue, alt)
	local by, out = {}, {}
	for _, e in ipairs(queue[alt] or {}) do
		if not by[e.to] then
			by[e.to] = { to = e.to, rows = {} }
			out[#out + 1] = by[e.to]
		end
		local rows = by[e.to].rows
		rows[#rows + 1] = { item = e.item, count = e.count }
	end
	table.sort(out, function(a, b)
		return a.to < b.to
	end)
	for _, g in ipairs(out) do
		table.sort(g.rows, function(a, b)
			return a.item < b.item
		end)
	end
	return out
end

-- The attachments that send exactly count: a stack that holds exactly what is left goes whole, else the smallest
-- stack that holds more gives a split of what is left, else the largest goes whole and the loop goes on. So at most
-- one pick is a split, and it comes last. stacks: { { bag, slot, n } }; max: free attachment slots. Returns the
-- picks { bag, slot, n, take } (take < n marks the split) and the units they send; fewer than count when the bags
-- hold less or the slots run out.
function A.planAttach(stacks, count, max)
	local pool = {}
	for k, s in ipairs(stacks) do
		pool[k] = s
	end
	table.sort(pool, function(a, b)
		if a.n ~= b.n then
			return a.n < b.n
		end
		if a.bag ~= b.bag then
			return a.bag < b.bag
		end
		return a.slot < b.slot
	end)
	local picks, got = {}, 0
	while got < count and #picks < max and #pool > 0 do
		local want, at = count - got, nil
		for k, s in ipairs(pool) do
			if s.n >= want then
				at = k
				break
			end
		end
		local s = table.remove(pool, at or #pool)
		local take = math.min(s.n, want)
		picks[#picks + 1] = { bag = s.bag, slot = s.slot, n = s.n, take = take }
		got = got + take
	end
	return picks, got
end

-- The split among the picks, or nil.
function A.splitOf(picks)
	for _, p in ipairs(picks) do
		if p.take < p.n then
			return p
		end
	end
end

-- After a sent mail: the units attached ({ [item] = units }) leave the alt's queue to the recipient; a row whose
-- count is met goes.
function A.sent(queue, alt, to, attached)
	local list = queue[alt]
	if not list then
		return
	end
	for k = #list, 1, -1 do
		local e = list[k]
		local n = e.to == to and attached[e.item]
		if n then
			e.count = e.count - n
			if e.count < 1 then
				table.remove(list, k)
			end
		end
	end
	if #list == 0 then
		queue[alt] = nil
	end
end

-- The live read of the alts' stock through TSM. items: a set of item IDs. Returns stock and a status table for the
-- selftest (counts and the broken link, no names).
function A.read(items)
	local status = { source = "TSM" }
	if type(TSM_API) ~= "table" or type(TSM_API.GetBagQuantity) ~= "function" then
		status.why = "TSM_API.GetBagQuantity missing (TSM not loaded?)"
		return {}, status
	end
	local me = UnitName and UnitName("player")
	local faction = UnitFactionGroup and UnitFactionGroup("player")
	local realm = GetRealmName and GetRealmName()
	if type(me) ~= "string" or type(faction) ~= "string" or type(realm) ~= "string" then
		status.why = "player name, faction or realm unknown"
		return {}, status
	end
	if issecretvalue and (issecretvalue(me) or issecretvalue(faction) or issecretvalue(realm)) then
		status.why = "player name is a secret value now"
		return {}, status
	end
	local fr = faction .. SEP .. realm
	local names, why = A.roster(rawget(_G, "TradeSkillMasterDB"), fr, me)
	if not names then
		status.why = why
		return {}, status
	end
	local function q(item, name)
		local s = "i:" .. item
		local ok, bags = pcall(TSM_API.GetBagQuantity, s, name, fr)
		if not ok then
			return nil, tostring(bags)
		end
		local ok2, bank = pcall(TSM_API.GetBankQuantity, s, name, fr)
		if not ok2 then
			return nil, "GetBankQuantity: " .. tostring(bank)
		end
		local ok3, mail = pcall(TSM_API.GetMailQuantity, s, name, fr)
		if not ok3 then
			return nil, "GetMailQuantity: " .. tostring(mail)
		end
		return bags, bank, mail
	end
	local total
	if type(TSM_API.GetPlayerTotals) == "function" then
		total = function(item)
			local ok, _, alts = pcall(TSM_API.GetPlayerTotals, "i:" .. item)
			return ok and type(alts) == "number" and alts or nil
		end
	end
	local stock, counts = A.stock(items, names, q, total)
	for k, v in pairs(counts) do
		status[k] = v
	end
	return stock, status
end

-- This character's name and its faction-realm slice of the saved queue (created on first use).
function A.myQueue(db)
	local me = UnitName and UnitName("player")
	local faction = UnitFactionGroup and UnitFactionGroup("player")
	local realm = GetRealmName and GetRealmName()
	if type(me) ~= "string" or type(faction) ~= "string" or type(realm) ~= "string" then
		return nil
	end
	if issecretvalue and (issecretvalue(me) or issecretvalue(faction) or issecretvalue(realm)) then
		return nil
	end
	db.mailQueue = db.mailQueue or {}
	local fr = faction .. SEP .. realm
	db.mailQueue[fr] = db.mailQueue[fr] or {}
	return db.mailQueue[fr], me
end
