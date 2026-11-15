-- Pure logic: skill-up colours and chances, crafts possible from stock, the plan's next step. No frames, no client
-- calls except through the functions passed in, so busted tests it whole.
local _, ns = ...
local L = {}
ns.Logic = L

-- Enum.TradeskillRelativeDifficulty: Optimal = 0, Medium = 1, Easy = 2, Trivial = 3.
local DIFFICULTY_COLOR = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "grey" }
L.COLOR_RANK = { orange = 1, yellow = 2, green = 3, grey = 4 }
-- Chance by colour when no thresholds are known (mid-band guesses; marked "~" in the panel).
local COLOR_CHANCE = { orange = 1, yellow = 0.75, green = 0.25, grey = 0 }

function L.colorOf(skill, yellow, grey)
	if skill < yellow then
		return "orange"
	elseif skill >= grey then
		return "grey"
	elseif skill < math.floor((yellow + grey) / 2) then
		return "yellow"
	end
	return "green"
end

function L.colorOfDifficulty(difficulty)
	return DIFFICULTY_COLOR[difficulty]
end

-- Skill-up chance per craft (the vanilla-client formula; an assumption for Forever, as in tools/tsm/skillup.py).
function L.chance(skill, yellow, grey)
	if skill < yellow then
		return 1
	elseif skill >= grey or grey <= yellow then
		return 0
	end
	return (grey - skill) / (grey - yellow)
end

-- Expected skill points from `crafts` crafts starting at `skill`, the chance falling as the skill rises.
-- thresholds = { yellow, grey, skillups } or nil (then the colour guess, constant).
function L.expectedPoints(skill, crafts, thresholds, color)
	if crafts == math.huge then
		return nil
	end
	local s = skill
	for _ = 1, crafts do
		local p
		if thresholds then
			p = L.chance(math.floor(s), thresholds[1], thresholds[2]) * (thresholds[3] or 1)
		else
			p = COLOR_CHANCE[color] or 0
		end
		if p <= 0 then
			break
		end
		s = s + p
	end
	return s - skill
end

-- How many times a recipe can be crafted from stock. reagents = { { item = id, count = n }, ... };
-- have(item) -> count in bags+bank; vendor[item] -> copper when a vendor sells it (counted as unlimited).
-- Returns crafts (math.huge when every reagent is vendor-sold), the limiting item, and for those crafts
-- the vendor reagents still to buy: { { item, need } }.
function L.craftsPossible(reagents, have, vendor)
	local n, limiting = math.huge, nil
	for _, r in ipairs(reagents) do
		if r.count > 0 and not vendor[r.item] then
			local k = math.floor(have(r.item) / r.count)
			if k < n then
				n, limiting = k, r.item
			end
		end
	end
	local toBuy = {}
	if n > 0 and n ~= math.huge then
		for _, r in ipairs(reagents) do
			if vendor[r.item] then
				local need = r.count * n - have(r.item)
				if need > 0 then
					toBuy[#toBuy + 1] = { item = r.item, need = need }
				end
			end
		end
	end
	return n, limiting, toBuy
end

-- The from-stock list: recipes that give skill now and can be crafted at least once without buying from
-- the auction house. recipes = { { id, name, learned, difficulty, thresholds, reagents }, ... }.
function L.fromStock(recipes, skill, have, vendor)
	local out = {}
	for _, r in ipairs(recipes) do
		if r.learned and r.reagents and #r.reagents > 0 then
			local color = r.thresholds and L.colorOf(skill, r.thresholds[1], r.thresholds[2])
				or L.colorOfDifficulty(r.difficulty)
			-- the client's own colour wins when it gives one: it knows the real thresholds
			local clientColor = L.colorOfDifficulty(r.difficulty)
			if clientColor then
				color = clientColor
			end
			if color and color ~= "grey" then
				local crafts, limiting, toBuy = L.craftsPossible(r.reagents, have, vendor)
				if crafts > 0 then
					out[#out + 1] = {
						id = r.id,
						name = r.name,
						color = color,
						crafts = crafts,
						limiting = limiting,
						toBuy = toBuy,
						points = L.expectedPoints(skill, crafts, r.thresholds, color),
						guessed = r.thresholds == nil,
					}
				end
			end
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = L.COLOR_RANK[a.color], L.COLOR_RANK[b.color]
		if ra ~= rb then
			return ra < rb
		end
		local pa, pb = a.points or math.huge, b.points or math.huge
		if pa ~= pb then
			return pa > pb
		end
		return a.name < b.name
	end)
	return out
end

-- The plan's step at `skill` and the one after it. Returns step, nextStep, state:
-- "ok", "below" (skill under the plan's start), "done" (at or over its end), "none" (no plan for this profession).
function L.planStep(prof, skill)
	if not prof or not prof.rows then
		return nil, nil, "none"
	end
	if skill < (prof.from or 0) then
		return nil, nil, "below"
	end
	if skill >= (prof.to or 0) then
		return nil, nil, "done"
	end
	for i, row in ipairs(prof.rows) do
		if skill >= row.from and skill < row.to then
			return row, prof.rows[i + 1], "ok"
		end
	end
	return nil, nil, "none"
end

-- What is still to buy for the rest of a step: the materials of the remaining crafts minus stock.
-- Crafts left scale with the share of the step's skill range still ahead.
function L.stepShopping(row, skill, have)
	if not row or not row.mats then
		return {}, 0
	end
	local span = row.to - row.from
	local left = span > 0 and (row.to - skill) / span or 1
	local crafts = math.ceil((row.crafts or 0) * left - 1e-9)
	local out = {}
	for _, m in ipairs(row.mats) do
		local need = math.ceil(m.count * left - 1e-9)
		local got = have(m.item)
		out[#out + 1] = { item = m.item, name = m.name, need = need, have = got, short = math.max(0, need - got) }
	end
	return out, crafts
end

-- Recipe items the plan buys that are not learned yet. isLearned(spell) -> bool or nil (unknown).
function L.recipesToBuy(prof, skill, isLearned)
	local out = {}
	for _, b in ipairs(prof and prof.buyRecipes or {}) do
		if isLearned(b.spell) ~= true and (b.to or math.huge) > skill then
			out[#out + 1] = {
				item = b.item,
				itemName = b.itemName,
				recipe = b.recipe,
				price = b.price,
				learnRank = b.learnRank,
				from = b.from,
				to = b.to,
				learnable = (b.learnRank or 0) <= skill,
			}
		end
	end
	return out
end

-- A recipe's { yellow, grey, skillups } from a Data/Plan.lua row: version 2 ({ y, g, k, mats, ... }) or the
-- version 1 three-element array. nil when the row has no thresholds.
function L.thresholds(row)
	if type(row) ~= "table" then
		return nil
	end
	if row.y and row.g then
		return { row.y, row.g, row.k or 1 }
	end
	if row[1] and row[2] then
		return row
	end
	return nil
end

-- Whether a profession entry carries the planner's input (Plan.lua version 2: reagents per recipe).
function L.isPlanV2(plan, prof)
	if not plan or (plan.version or 1) < 2 or not prof or type(prof.recipes) ~= "table" then
		return false
	end
	local _, row = next(prof.recipes)
	return row == nil or row.mats ~= nil
end

-- A vendor purchase of `short` units. offer = { price (copper a lot), lot (units a lot, the merchant's stackCount),
-- maxStack (units one BuyMerchantItem call may take), available (lots left, -1 or nil for unlimited) }.
-- Returns { lots, qty, cost, calls = { units per call } } (qty rounds up to whole lots; every call a whole number of
-- lots), or nil and why.
function L.vendorLots(short, offer)
	short = math.floor(short or 0)
	if short < 1 then
		return nil, "nothing to buy"
	end
	if type(offer) ~= "table" then
		return nil, "no offer"
	end
	local lot = math.max(1, math.floor(offer.lot or 1))
	local lots = math.ceil(short / lot)
	local available = offer.available
	if available and available >= 0 and lots > available then
		return nil, ("the vendor has %d left"):format(available * lot)
	end
	local qty = lots * lot
	local per = math.max(lot, math.floor((offer.maxStack or lot) / lot) * lot)
	local calls, rem = {}, qty
	while rem > 0 do
		local n = math.min(per, rem)
		calls[#calls + 1] = n
		rem = rem - n
	end
	return { lots = lots, qty = qty, cost = lots * (offer.price or 0), calls = calls }
end

-- Units of an item the bags take: free slots that accept it, times its stack size, plus the top of a partial stack
-- (counted as one stack, so a split pile makes this an overestimate by at most one stack).
function L.bagRoom(freeSlots, stackSize, inBags)
	stackSize = math.max(1, math.floor(stackSize or 1))
	local partial = (inBags or 0) % stackSize
	return (freeSlots or 0) * stackSize + (partial > 0 and (stackSize - partial) or 0)
end

-- Copper as "1g 2s 3c" (gold and silver only when present).
function L.money(c)
	if not c then
		return "-"
	end
	local neg = c < 0
	c = math.floor(math.abs(c) + 0.5)
	local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	local parts = {}
	if g > 0 then
		parts[#parts + 1] = g .. "g"
	end
	if s > 0 or g > 0 then
		parts[#parts + 1] = s .. "s"
	end
	parts[#parts + 1] = cc .. "c"
	return (neg and "-" or "") .. table.concat(parts, " ")
end

--------------------------------------------------------------------------------------------------- the AH list

-- A live AH price more than this many times the plan's estimate is overpriced: the row says so.
L.AH_OVER = 1.5

-- The AH list from the saved trip lists (SkillupHelperDB.trips, per profession): one row per item still to buy,
-- { item, name, count, each, pattern, committed, profs }. count is what is left after the buys made from it
-- (row.bought). A reagent row of a saved list buys for a committed step (planner rule 3); a pattern row does not.
function L.ahList(trips)
	local profs = {}
	for prof in pairs(trips or {}) do
		profs[#profs + 1] = prof
	end
	table.sort(profs, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local out, byItem = {}, {}
	for _, prof in ipairs(profs) do
		for _, r in ipairs(trips[prof].rows or {}) do
			local left = (r.count or 0) - (r.bought or 0)
			if type(r.item) == "number" and left > 0 then
				local row = byItem[r.item]
				if not row then
					row = {
						item = r.item,
						name = r.name,
						count = 0,
						each = r.each,
						pattern = r.recipe == true,
						profs = {},
					}
					row.committed = not row.pattern
					byItem[r.item] = row
					out[#out + 1] = row
				end
				row.count = row.count + left
				row.profs[#row.profs + 1] = prof
			end
		end
	end
	return out
end

-- What `need` units of a commodity cost from its search results ({ unitPrice, quantity }), cheapest first:
-- { available, qty (what can be bought, at most need), total, unit (the cheapest unit price), avg }.
function L.commodityQuote(results, need)
	local list = {}
	for _, r in ipairs(results or {}) do
		if type(r.unitPrice) == "number" and type(r.quantity) == "number" and r.quantity > 0 then
			list[#list + 1] = r
		end
	end
	table.sort(list, function(a, b)
		return a.unitPrice < b.unitPrice
	end)
	local q = { available = 0, qty = 0, total = 0, unit = list[1] and list[1].unitPrice or nil }
	for _, r in ipairs(list) do
		q.available = q.available + r.quantity
		local take = math.min(r.quantity, (need or 0) - q.qty)
		if take > 0 then
			q.qty = q.qty + take
			q.total = q.total + take * r.unitPrice
		end
	end
	q.avg = q.qty > 0 and q.total / q.qty or nil
	return q
end

-- The cheapest buyout among item search results ({ auctionID, buyoutAmount, quantity, containsOwnerItem }), the
-- user's own auctions left out: { auctionID, buyout, quantity }, or nil when nothing has a buyout.
function L.cheapestBuyout(results)
	local best
	for _, r in ipairs(results or {}) do
		local price = r.buyoutAmount
		if type(price) == "number" and price > 0 and r.auctionID and not r.containsOwnerItem then
			if not best or price < best.buyout then
				best = { auctionID = r.auctionID, buyout = price, quantity = r.quantity or 1 }
			end
		end
	end
	return best
end

-- Live AH price against the plan's estimate, per unit: "over" past L.AH_OVER times, else "ok"; "unknown" without an
-- estimate. Returns the verdict and the ratio.
function L.ahVerdict(each, live)
	if type(each) ~= "number" or each <= 0 or type(live) ~= "number" then
		return "unknown", nil
	end
	local ratio = live / each
	return ratio > L.AH_OVER and "over" or "ok", ratio
end

-- Settings (the More tab) ------------------------------------------------------------------------------------------
-- The values the More tab offers; the slash commands accept the same luck values (Planner.zOf) and any effort.
L.LUCKS = { 50, 75, 80, 90, 95, 99 }
L.EFFORTS = { 0, 5, 10, 20, 50, 100, 200, 500 } -- copper per craft: 0, 5c, 10c, 20c, 50c, 1s, 2s, 5s

-- The effort after `cur` one step up (dir > 0) or down: a value between two steps goes to the next one that way.
-- nil past either end.
function L.effortStep(cur, dir)
	cur = tonumber(cur) or 0
	if dir > 0 then
		for _, e in ipairs(L.EFFORTS) do
			if e > cur then
				return e
			end
		end
	else
		for k = #L.EFFORTS, 1, -1 do
			if L.EFFORTS[k] < cur then
				return L.EFFORTS[k]
			end
		end
	end
	return nil
end

local EXCLUDE_FLAG = { dungeon = true, ahPatterns = true }

-- Writes one More-tab control into SkillupHelperDB, under the keys the slash commands write:
--   luck (db.luck, one of L.LUCKS, nil resets), effort (db.effort, copper >= 0, nil resets), noRecipeBuys and
--   noAlts (true or nil), dungeon / ahPatterns (db.exclude[key]: true leaves them out), special (db.exclude.special:
--   false plans special teachers, nil leaves them out), allow / notNow (db.exclude[key][spell]: true or nil; one
--   clears the other, as /skillup allow and /skillup exclude <spellID> do).
-- a = { key, value, spell }. Returns true, or false and the broken link.
function L.applySetting(db, a)
	if type(db) ~= "table" then
		return false, "SkillupHelperDB not loaded"
	end
	if type(a) ~= "table" then
		return false, "no setting given"
	end
	local k, v = a.key, a.value
	if k == "luck" then
		if v ~= nil then
			local ok = false
			for _, l in ipairs(L.LUCKS) do
				ok = ok or l == v
			end
			if not ok then
				return false, "luck " .. tostring(v) .. " is not one of 50, 75, 80, 90, 95, 99"
			end
		end
		db.luck = v
		return true
	elseif k == "effort" then
		if v ~= nil and (type(v) ~= "number" or v < 0) then
			return false, "effort " .. tostring(v) .. " is not copper >= 0"
		end
		db.effort = v
		return true
	elseif k == "noRecipeBuys" or k == "noAlts" then
		db[k] = v and true or nil
		return true
	end
	db.exclude = type(db.exclude) == "table" and db.exclude or {}
	local ex = db.exclude
	if EXCLUDE_FLAG[k] then
		ex[k] = v and true or nil
		return true
	elseif k == "special" then
		if v == false then
			ex.special = false
		else
			ex.special = nil
		end
		return true
	elseif k == "allow" or k == "notNow" then
		if type(a.spell) ~= "number" then
			return false, k .. " without a spell id"
		end
		ex.allow = type(ex.allow) == "table" and ex.allow or {}
		ex.notNow = type(ex.notNow) == "table" and ex.notNow or {}
		ex[k][a.spell] = v and true or nil
		if v then
			ex[k == "allow" and "notNow" or "allow"][a.spell] = nil
		end
		return true
	end
	return false, "unknown setting " .. tostring(k)
end

-- The data layers -------------------------------------------------------------------------------------------------
-- The planner reads one table, built once at load from three files:
--   1. Data/Recipes.lua (ns.Data.recipes): shipped, every recipe of every profession, no auction prices;
--   2. Data/Plan.lua (ns.Data.plan): optional, written on a PC by a price tool, for some professions only. Its
--      fallback prices (items[].mv), sale values (recipes[].sell / takes), pricesAt and offline rows go on top;
--   3. Data/Custom.lua (ns.Data.custom): optional, the player's own changes (Data/Custom.example.lua).
-- No layer is ever written to: a changed row is a copy.

local SOURCES = { auto = true, trainer = true, item = true, special = true, unlisted = true }
local NPC_ROLES = { trade = true, cook = true, lwtrainer = true, cooktrainer = true, auction = true, trainer = true }

local function isCount(v)
	return type(v) == "number" and v >= 0 and v == v and v ~= math.huge
end

local function isId(v)
	return type(v) == "number" and v > 0 and v == math.floor(v)
end

local function isText(v)
	return type(v) == "string" and v ~= ""
end

local function isFlag(v)
	return type(v) == "boolean"
end

local function isMats(v)
	if type(v) ~= "table" or #v == 0 or #v % 2 ~= 0 then
		return false
	end
	for i = 1, #v, 2 do
		if not isId(v[i]) or not (type(v[i + 1]) == "number" and v[i + 1] > 0) then
			return false
		end
	end
	return true
end

-- field = { check, what it must be }
local RECIPE_FIELDS = {
	y = { isCount, "a number >= 0" },
	g = { isCount, "a number >= 0" },
	k = { isCount, "a number >= 0" },
	learn = { isCount, "a number >= 0" },
	cost = { isCount, "a number >= 0 (copper)" },
	name = { isText, "text" },
	teacher = { isText, "text" },
	src = {
		function(v)
			return SOURCES[v] == true
		end,
		"auto, trainer, item, special or unlisted",
	},
	from = { isText, "text (vendor, quest, drop, crafted)" },
	vendor = {
		function(v)
			return type(v) == "table" and (v.name == nil or isText(v.name))
		end,
		"a table { name, npc, zone, a, h }",
	},
	buy = { isCount, "a number >= 0 (copper)" },
	faction = { isCount, "a faction id" },
	rep = { isCount, "a reputation rank" },
	unc = { isFlag, "true or false" },
	mats = { isMats, "a list { item, count, item, count, ... }" },
	makes = { isId, "an item id" },
	n = { isCount, "a number >= 0" },
	item = { isId, "an item id" },
	bop = { isFlag, "true or false" },
	gone = { isFlag, "true or false" },
}
local ITEM_FIELDS = {
	name = { isText, "text" },
	sell = { isCount, "a number >= 0 (copper)" },
	mv = { isCount, "a number >= 0 (copper)" },
	stack = { isCount, "a number >= 0" },
}

local function checkFields(row, fields, where, errors)
	local ok = true
	for k, v in pairs(row) do
		local f = fields[k]
		if not f then
			errors[#errors + 1] = ("%s.%s: unknown field"):format(where, tostring(k))
			ok = false
		elseif not f[1](v) then
			errors[#errors + 1] = ("%s.%s: must be %s"):format(where, tostring(k), f[2])
			ok = false
		end
	end
	return ok
end

local function sortedKeysOf(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

-- Checks Data/Custom.lua's table. Returns the entries that are usable ({ recipes, vendor, items, npcs }, each maybe
-- empty) and a list of errors, one per bad entry, each naming its key ("recipes[164][2660].learn: must be ...").
-- A bad entry is left out; the rest of the file still applies. Never raises.
function L.validateCustom(custom)
	local clean, errors = { recipes = {}, vendor = {}, items = {}, npcs = {} }, {}
	if custom == nil then
		return clean, errors
	end
	if type(custom) ~= "table" then
		return clean, { "ns.Data.custom: must be a table" }
	end
	for _, k in ipairs(sortedKeysOf(custom)) do
		-- spots and trainers are checked and applied by Journal.lua (P.applyCustom)
		if clean[k] == nil and k ~= "version" and k ~= "spots" and k ~= "trainers" then
			errors[#errors + 1] = ("%s: unknown section (recipes, vendor, items, npcs, spots, trainers)"):format(
				tostring(k)
			)
		end
	end
	local function section(name)
		local t = custom[name]
		if t ~= nil and type(t) ~= "table" then
			errors[#errors + 1] = name .. ": must be a table"
			return {}
		end
		return t or {}
	end
	local recipes = section("recipes")
	for _, line in ipairs(sortedKeysOf(recipes)) do
		local rows = recipes[line]
		local at = ("recipes[%s]"):format(tostring(line))
		if not isId(line) then
			errors[#errors + 1] = at .. ": the key must be a skill line id (164 = Blacksmithing)"
		elseif type(rows) ~= "table" then
			errors[#errors + 1] = at .. ": must be a table of [spell id] = { ... } or false"
		else
			for _, spell in ipairs(sortedKeysOf(rows)) do
				local row = rows[spell]
				local where = ("%s[%s]"):format(at, tostring(spell))
				if not isId(spell) then
					errors[#errors + 1] = where .. ": the key must be a spell id"
				elseif row ~= false and type(row) ~= "table" then
					errors[#errors + 1] = where .. ": must be a table of fields, or false to leave the recipe out"
				elseif row == false or checkFields(row, RECIPE_FIELDS, where, errors) then
					clean.recipes[line] = clean.recipes[line] or {}
					clean.recipes[line][spell] = row
				end
			end
		end
	end
	local vendor = section("vendor")
	for _, item in ipairs(sortedKeysOf(vendor)) do
		local price = vendor[item]
		local where = ("vendor[%s]"):format(tostring(item))
		if not isId(item) then
			errors[#errors + 1] = where .. ": the key must be an item id"
		elseif price ~= false and not (type(price) == "number" and price > 0) then
			errors[#errors + 1] = where .. ": must be the vendor's price in copper, or false"
		else
			clean.vendor[item] = price
		end
	end
	local items = section("items")
	for _, item in ipairs(sortedKeysOf(items)) do
		local row = items[item]
		local where = ("items[%s]"):format(tostring(item))
		if not isId(item) then
			errors[#errors + 1] = where .. ": the key must be an item id"
		elseif type(row) ~= "table" then
			errors[#errors + 1] = where .. ": must be a table of fields"
		elseif checkFields(row, ITEM_FIELDS, where, errors) then
			clean.items[item] = row
		end
	end
	local npcs = section("npcs")
	for i = 1, #npcs do
		local r = npcs[i]
		local where = ("npcs[%d]"):format(i)
		local bad
		if type(r) ~= "table" then
			bad = "must be a table { id, name, map, x, y, role }"
		elseif not isId(r.id) then
			bad = "id must be the NPC id"
		elseif not isText(r.name) then
			bad = "name must be text"
		elseif not isId(r.map) then
			bad = "map must be a uiMap id"
		elseif not (isCount(r.x) and r.x <= 100 and isCount(r.y) and r.y <= 100) then
			bad = "x and y must be 0 to 100 (percent of the map)"
		elseif not NPC_ROLES[r.role] then
			bad = "role must be trade, cook, trainer, lwtrainer, cooktrainer or auction"
		elseif r.role == "trainer" and not isText(r.trains) then
			bad = 'a trainer needs trains = "the profession\'s name"'
		elseif r.place ~= nil and not isText(r.place) then
			bad = "place must be text"
		elseif r.sells ~= nil and type(r.sells) ~= "table" then
			bad = "sells must be a list of item ids"
		end
		if not bad and r.sells then
			for _, item in ipairs(r.sells) do
				if not isId(item) then
					bad = "sells must be a list of item ids"
				end
			end
		end
		if bad then
			errors[#errors + 1] = ("%s: %s"):format(where, bad)
		else
			clean.npcs[#clean.npcs + 1] = r
		end
	end
	return clean, errors
end

local function copyOf(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

-- row with over's fields on top; row itself when over changes nothing.
local function overlaid(row, over)
	local out
	for k, v in pairs(over) do
		if row[k] ~= v then
			out = out or copyOf(row)
			out[k] = v
		end
	end
	return out or row
end

-- The table the planner reads, from the three layers (any may be nil), and what loaded:
-- report = { shipped = { build, professions = { "Name(id) n recipes" } } or the broken link,
--            plan = "present, ..." or "absent (optional)", custom = "absent (optional)" or { applied, errors } }.
-- Returns nil (and the report) when no layer has a profession. `custom` is validated here (L.validateCustom).
function L.effectivePlan(shipped, plan, custom)
	local report = {}
	shipped = type(shipped) == "table" and shipped or nil
	plan = type(plan) == "table" and plan or nil
	local clean, errors = L.validateCustom(custom)
	local out = {
		version = 2,
		build = shipped and shipped.build or (plan and plan.build),
		vendor = copyOf(shipped and shipped.vendor),
		-- item rows a layer adds or changes sit in this table; every other item reads through to the shipped table
		-- (thousands of rows that are never copied or walked)
		items = setmetatable({}, { __index = shipped and shipped.items or nil }),
		professions = {},
	}
	-- per profession: the layers' parts, merged the first time its `recipes` are read (lazy below)
	local layers = {}
	if shipped then
		local profs = {}
		local counts = type(shipped.counts) == "table" and shipped.counts or {}
		for id, p in pairs(shipped.professions or {}) do
			out.professions[id] = p
			layers[id] = { base = p }
			-- the generator's own count: a profession's recipe table is not walked at load
			profs[#profs + 1] = ("%s(%s) %s recipes"):format(
				tostring(p.name),
				tostring(id),
				tostring(counts[id] or "?")
			)
		end
		table.sort(profs)
		report.shipped = {
			build = shipped.build,
			-- where and when the overlay's facts were read ("Wowhead, Forever section, 2026-11-14")
			source = shipped.source,
			professions = profs,
		}
	else
		report.shipped = "Data/Recipes.lua not loaded: the shipped recipe data is missing from this copy of the addon"
	end
	if plan then
		-- a version 1 export has thresholds only (no reagents): its recipe rows cannot go over the shipped ones
		local v2 = (plan.version or 1) >= 2
		for _, k in ipairs({ "generatedAt", "pricesAt", "effort", "sellShare" }) do
			out[k] = plan[k]
		end
		if not shipped then
			out.version = plan.version or 1
		end
		for item, price in pairs(plan.vendor or {}) do
			out.vendor[item] = price
		end
		for item, row in pairs(plan.items or {}) do
			local b = out.items[item]
			rawset(out.items, item, b and overlaid(b, row) or row)
		end
		local n = 0
		for id, p in pairs(plan.professions or {}) do
			n = n + 1
			if not layers[id] then
				out.professions[id] = p
				layers[id] = { base = p }
			else
				layers[id].plan = p
				layers[id].planRecipes = v2
			end
		end
		report.plan = ("present, %d profession%s%s%s"):format(
			n,
			n == 1 and "" or "s",
			plan.generatedAt and (", generated " .. tostring(plan.generatedAt)) or "",
			(shipped and not v2) and ", version 1: its recipe rows are not used" or ""
		)
	else
		report.plan = "absent (optional)"
	end
	if custom ~= nil then
		local applied = 0
		for line, rows in pairs(clean.recipes) do
			local layer = layers[line]
			if not layer then
				errors[#errors + 1] = ("recipes[%s]: no profession with this skill line id in the data"):format(
					tostring(line)
				)
			else
				-- checked now (one lookup per entry, so the errors are known at login), applied on first use
				local keep = {}
				local baseRecipes = layer.base.recipes or {}
				for _, spell in ipairs(sortedKeysOf(rows)) do
					local row = rows[spell]
					local known = baseRecipes[spell]
						or (layer.planRecipes and layer.plan.recipes and layer.plan.recipes[spell])
					if row == false or known or (row.y and row.g and row.mats) then
						keep[spell] = row
						applied = applied + 1
					else
						errors[#errors + 1] = ("recipes[%s][%s]: not in the data, and a new recipe needs y, g and mats"):format(
							tostring(line),
							tostring(spell)
						)
					end
				end
				layer.custom = next(keep) and keep or nil
			end
		end
		for item, price in pairs(clean.vendor) do
			out.vendor[item] = price or nil
			applied = applied + 1
		end
		for item, row in pairs(clean.items) do
			local b = out.items[item]
			rawset(out.items, item, b and overlaid(b, row) or row)
			applied = applied + 1
		end
		if #clean.npcs > 0 then
			out.npcs = clean.npcs
			applied = applied + #clean.npcs
		end
		table.sort(errors)
		report.custom = { applied = applied, errors = errors }
	else
		report.custom = "absent (optional)"
	end
	if not next(out.professions) then
		return nil, report
	end
	-- A profession a layer changes gets its own entry: the fields now (a handful), the recipes when first read.
	-- Nothing walks a recipe table at login; only the professions the player opens are ever merged.
	for id, layer in pairs(layers) do
		if layer.plan or layer.custom then
			local base, p = layer.base, layer.plan
			local entry = {}
			for _, src in ipairs({ base, p or {} }) do
				for k, v in pairs(src) do
					if k ~= "recipes" and k ~= "removed" then
						entry[k] = v
					end
				end
			end
			if p then
				-- the shipped data covers every rank; an export made for a lower target must not shorten the plan
				entry.to = math.max(tonumber(base.to) or 0, tonumber(p.to) or 0)
				entry.ranks = base.ranks
			end
			out.professions[id] = setmetatable(entry, {
				__index = function(t, k)
					if k ~= "recipes" and k ~= "removed" then
						return nil
					end
					local recipes, removed = copyOf(base.recipes), false
					if p and layer.planRecipes then
						for spell, row in pairs(p.recipes or {}) do
							local b = recipes[spell]
							recipes[spell] = b and overlaid(b, row) or row
						end
					end
					for spell, row in pairs(layer.custom or {}) do
						if row == false then
							-- out of the plan, also when the client lists it as learned (Scan.build reads `removed`)
							recipes[spell] = nil
							removed = removed or {}
							removed[spell] = true
						else
							recipes[spell] = recipes[spell] and overlaid(recipes[spell], row) or row
						end
					end
					rawset(t, "recipes", recipes)
					rawset(t, "removed", removed)
					return rawget(t, k) or nil
				end,
			})
		end
	end
	return out, report
end

-- How old the shipped data is, in plain words: "Recipe data: build 1.60.1.70938, learn ranks from Wowhead, Forever
-- section, 2026-11-14. Your game is build 1.60.1.71000: newer than the data, so a recipe changed since may be off
-- until the addon is updated." shipped = ns.Data.recipes (or nil); version, buildNumber = GetBuildInfo()'s first two.
-- Returns the line and whether the game is newer than the data (false when either build is unknown): a note, never
-- an error.
function L.dataStatus(shipped, version, buildNumber)
	if type(shipped) ~= "table" then
		return "Recipe data: not loaded (Data/Recipes.lua is missing from this copy of the addon).", false
	end
	local line = ("Recipe data: build %s"):format(tostring(shipped.build or "unknown"))
	if shipped.source then
		line = line .. ", learn ranks and sources from " .. tostring(shipped.source)
	end
	line = line .. "."
	local dataBuild = tonumber(tostring(shipped.build or ""):match("(%d+)$"))
	local gameBuild = tonumber(buildNumber)
	if not gameBuild then
		return line, false
	end
	local game = ("%s.%s"):format(tostring(version or "?"), tostring(buildNumber))
	if dataBuild and gameBuild > dataBuild then
		return ("%s Your game is build %s: newer than the data, so a recipe changed since may be off until the addon is updated."):format(
			line,
			game
		),
			true
	end
	return ("%s Your game is build %s."):format(line, game), false
end

-- Seed NPCs for the guide: Data/Npcs.lua's rows, then Data/Custom.lua's (a custom row with a shipped row's id
-- replaces it).
function L.npcRows(shipped, custom)
	local out, at = {}, {}
	for _, list in ipairs({ shipped or {}, custom or {} }) do
		for _, r in ipairs(list) do
			if at[r.id] then
				out[at[r.id]] = r
			else
				out[#out + 1] = r
				at[r.id] = #out
			end
		end
	end
	return out
end

-- What a profession trainer showed in game on top of a profession entry. req = SkillupHelperDB.trainerReq[line]:
-- { [spellID or lowercased name] = { skill, cost } }. A recipe the trainer lists is a trainer recipe (whatever the
-- data said), learned at the skill the trainer asks: the game's own word wins over Custom.lua and the shipped data.
-- Returns prof itself when nothing changes.
function L.withTrainerReq(prof, req)
	if type(prof) ~= "table" or type(req) ~= "table" or not next(req) then
		return prof
	end
	local recipes
	for spell, r in pairs(prof.recipes or {}) do
		local e = req[spell] or (type(r.name) == "string" and req[r.name:lower()]) or nil
		if type(e) == "table" then
			local over = { src = "trainer" }
			if type(e.skill) == "number" then
				over.learn = e.skill
			end
			if type(e.cost) == "number" then
				over.cost = e.cost
			end
			if r.gone then
				-- the trainer teaches it: it is in the game
				over.gone = false
			end
			local row = overlaid(r, over)
			if row ~= r then
				recipes = recipes or copyOf(prof.recipes)
				recipes[spell] = row
			end
		end
	end
	if not recipes then
		return prof
	end
	local out = copyOf(prof)
	out.recipes = recipes
	return out
end

-- The plan's profession entry for a profession the client names: by skill line id, then parent id, then name.
function L.findProfession(plan, info)
	if not plan or not plan.professions or not info then
		return nil
	end
	local p = plan.professions[info.professionID] or plan.professions[info.parentProfessionID or -1]
	if p then
		return p
	end
	local names = { info.professionName, info.parentProfessionName }
	for _, prof in pairs(plan.professions) do
		for _, n in pairs(names) do
			if type(n) == "string" and prof.name and n:lower() == prof.name:lower() then
				return prof
			end
		end
	end
	return nil
end
