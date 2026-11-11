-- Planner fixtures from the design note (research/2026-11-11-skillup-planner.md in the scaffolding): prices in copper.
-- Buy: Lion Meat 123, Big Bear Meat 90, Medium Leather 99, Light Leather 31, Light Hide 125, Raw Rockscale Cod 15,
-- Goldthorn 1249, Heavy Leather 296, Elixir of Lesser Agility 831. Vendor: Hot Spices 40, Fine Thread 100, Gray Dye
-- 350, Salt 50, water 25. Vendor sell: Lion Meat 55, Big Bear Meat 45, Medium Leather 50.
local F = {}

F.ITEM = {
	LION = 3731,
	BEAR = 3730,
	SPICES = 2692,
	TAIL = 5470,
	CLAM = 5503,
	COD = 6362,
	GOLDTHORN = 3821,
	WATER = 159,
	CODRECIPE = 6369,
	MEDIUM = 2319,
	LIGHT = 2318,
	HIDE = 783,
	CURED = 4231,
	SALT = 4289,
	THREAD = 2321,
	DYE = 4340,
	ELIXIR = 3390,
	HEAVY = 4234,
	PATTERN = 4296,
}
local I = F.ITEM

-- name, buy (nil = none), where, vendor sell, market (for salvage)
local ITEMS = {
	[I.LION] = { "Lion Meat", 123, "ah", 55 },
	[I.BEAR] = { "Big Bear Meat", 90, "ah", 45 },
	[I.SPICES] = { "Hot Spices", 40, "vendor", 10 },
	[I.TAIL] = { "Thunder Lizard Tail", 50, "ah", 10 },
	[I.CLAM] = { "Clam Meat", 60, "ah", 5 },
	[I.COD] = { "Raw Rockscale Cod", 15, "ah", 1 },
	[I.GOLDTHORN] = { "Goldthorn", 1249, "ah", 100 },
	[I.WATER] = { "Refreshing Spring Water", 25, "vendor", 1 },
	[I.CODRECIPE] = { "Recipe: Rockscale Cod", 2811, "ah", 500 },
	[I.MEDIUM] = { "Medium Leather", 99, "ah", 50 },
	[I.LIGHT] = { "Light Leather", 31, "ah", 10 },
	[I.HIDE] = { "Light Hide", 125, "ah", 20 },
	[I.CURED] = { "Cured Light Hide", 219, "ah", 30 },
	[I.SALT] = { "Salt", 50, "vendor", 10 },
	[I.THREAD] = { "Fine Thread", 100, "vendor", 25 },
	[I.DYE] = { "Gray Dye", 350, "vendor", 50 },
	[I.ELIXIR] = { "Elixir of Lesser Agility", 831, "ah", 100 },
	[I.HEAVY] = { "Heavy Leather", 296, "ah", 60 },
	[I.PATTERN] = { "Pattern: Dark Leather Shoulders", 2036, "ah", 500 },
}

-- price[item] = { buy, where, salvage }: salvage = max(vendor sell, 0.5 * market)
function F.prices(only)
	local price, items = {}, {}
	for id, it in pairs(ITEMS) do
		if not only or only[id] then
			local mv = it[3] == "ah" and it[2] or 0
			price[id] = { buy = it[2], where = it[3], salvage = math.max(it[4], 0.5 * mv) }
		end
		items[id] = { name = it[1], sell = it[4], mv = it[3] == "ah" and it[2] or nil }
	end
	for id, it in pairs(F.PRODUCTS or {}) do
		items[id] = it
	end
	return price, items
end

-- product[spell] = { vendor = per craft, sell, takes }
local function rec(name, y, g, mats, vendor, extra)
	local r = { name = name, y = y, g = g, k = 1, mats = mats, src = "trainer", vend = vendor }
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	return r
end

F.COOKING = {
	[6418] = rec("Crispy Lizard Tail", 140, 180, { I.TAIL, 1, I.SPICES, 1 }, 100),
	[6501] = rec("Goblin Deviled Clams", 165, 205, { I.CLAM, 1 }, 27),
	[3397] = rec("Big Bear Steak", 150, 190, { I.BEAR, 1, I.SPICES, 1 }, 125),
	[3398] = rec("Hot Lion Chops", 175, 215, { I.LION, 1, I.SPICES, 1 }, 125),
	[7828] = rec("Rockscale Cod", 190, 230, { I.COD, 1 }, 6, { src = "item", item = I.CODRECIPE, learn = 175 }),
	[13028] = rec("Goldthorn Tea", 215, 255, { I.GOLDTHORN, 1, I.WATER, 1 }, 340, { sell = 2722, takes = 12 }),
}
F.COOKING_LEARNED = { [6418] = true, [6501] = true, [3397] = true, [3398] = true }

F.LEATHER = {
	[2167] = rec("Gray Leather Boots", 100, 125, { I.MEDIUM, 4, I.THREAD, 2, I.DYE, 1 }, 307),
	[2169] = rec("Dark Leather Tunic", 100, 125, { I.MEDIUM, 6, I.THREAD, 1 }, 339),
	[2168] = rec("Dark Leather Cloak", 110, 135, { I.MEDIUM, 8, I.DYE, 1 }, 308),
	[7135] = rec("Dark Leather Pants", 115, 140, { I.MEDIUM, 12, I.DYE, 1, I.THREAD, 1 }, 1089),
	[9195] = rec("Light Leather Pants", 100, 130, { I.LIGHT, 10, I.CURED, 1, I.THREAD, 1 }, 599),
	[3816] = rec("Cured Light Hide", 35, 55, { I.HIDE, 1, I.SALT, 1 }, 0, { makes = I.CURED, n = 1 }),
	[3769] = rec(
		"Dark Leather Shoulders",
		140,
		165,
		{ I.MEDIUM, 12, I.ELIXIR, 1, I.DYE, 1, I.THREAD, 2 },
		1457,
		{ src = "item", item = I.PATTERN, learn = 115, sell = 2743, takes = 64 }
	),
	[9194] = rec("Heavy Leather Ammo Pouch", 145, 165, { I.HEAVY, 8, I.THREAD, 2 }, 500, { sell = 2791, takes = 46 }),
}
F.LEATHER_LEARNED = { [2167] = true, [2169] = true, [2168] = true, [7135] = true, [9195] = true, [3816] = true }

-- Each recipe's product as an item of its own (id 100000 + spell) that vendors for the recipe's `vend`, so the
-- price layer (TSM.prices) values products the way the planner fixtures do.
F.PRODUCTS = {}
for _, list in ipairs({ F.COOKING, F.LEATHER }) do
	for spell, r in pairs(list) do
		if not r.makes then
			r.makes, r.n = 100000 + spell, 1
			F.PRODUCTS[r.makes] = { name = r.name, sell = r.vend }
		end
	end
end

local function products(recipes)
	local out = {}
	for spell, r in pairs(recipes) do
		out[spell] = { vendor = r.vend or 0, sell = r.sell, takes = r.takes or 0 }
	end
	return out
end

function F.input(recipes, learned, skill, cap, have, extra)
	local price, items = F.prices()
	local input = {
		skill = skill,
		cap = cap,
		recipes = recipes,
		learned = learned,
		price = price,
		items = items,
		product = products(recipes),
		have = have or {},
		effort = 20,
	}
	for k, v in pairs(extra or {}) do
		input[k] = v
	end
	return input
end

function F.cooking(have)
	return F.input(F.COOKING, F.COOKING_LEARNED, 173, 225, have or { [I.LION] = 7, [I.BEAR] = 1 })
end

function F.leather(have)
	return F.input(F.LEATHER, F.LEATHER_LEARNED, 109, 150, have or { [I.MEDIUM] = 92 })
end

-- One plan as text lines (the busted spec prints them; tools read them in the test log).
function F.describe(plan, names)
	local lines = {}
	local function nm(i)
		return names and names[i] and names[i].name or tostring(i)
	end
	for i, st in ipairs(plan.steps) do
		local s
		if st.kind == "craft" then
			local buy = {}
			for _, b in ipairs(st.buy) do
				buy[#buy + 1] = ("%d %s (%s %d)"):format(
					b.count,
					nm(b.item),
					tostring(b.where),
					(b.each or 0) * b.count
				)
			end
			local used = {}
			for _, u in ipairs(st.used) do
				used[#used + 1] = ("%d %s"):format(u.count, nm(u.item))
			end
			local pre = {}
			for _, p in ipairs(st.pre) do
				pre[#pre + 1] = ("%d %s"):format(p.count, nm(p.item))
			end
			s = ("%d. craft %dx %s [%s] %.2f-%.2f (+%.2f) %s %d%%-%d%%, %.0fc/pt"):format(
				i,
				st.crafts,
				st.name,
				st.source,
				st.from,
				st.to,
				st.points,
				st.color,
				st.chance[1] * 100 + 0.5,
				st.chance[2] * 100 + 0.5,
				st.costPt or -1
			)
			if #used > 0 then
				s = s .. "; stock " .. table.concat(used, ", ")
			end
			if #pre > 0 then
				s = s .. "; craft first " .. table.concat(pre, ", ")
			end
			if #buy > 0 then
				s = s .. "; buy " .. table.concat(buy, ", ")
			end
			if #st.tags > 0 then
				s = s .. "; tags: " .. table.concat(st.tags, ", ")
			end
			if st.alt then
				s = s .. ("; alt: %dx %s from stock, +%dc"):format(st.alt.crafts, st.alt.name, st.alt.extra)
			end
		elseif st.kind == "buyRecipe" then
			s = ("%d. buy recipe %s (%s %d), learn %d, saves %s"):format(
				i,
				st.name,
				st.where,
				st.price,
				st.learn,
				tostring(st.saves and math.floor(st.saves))
			)
			if st.alt then
				s = s .. ("; skip: %s, +%d"):format(st.alt.name, st.alt.extra)
			end
		elseif st.kind == "train" then
			s = ("%d. train %s at %d"):format(i, st.name, st.at)
		else
			s = ("%d. gap %d-%d: %s"):format(i, st.from, st.to, st.why)
		end
		lines[#lines + 1] = s
	end
	for _, h in ipairs(plan.hold) do
		lines[#lines + 1] = ("hold %d %s for %s at %d"):format(h.count, nm(h.item), h.name, h.at)
	end
	for _, l in ipairs(plan.leftovers) do
		lines[#lines + 1] = ("leftover %d %s worth %d (%s)"):format(l.count, nm(l.item), l.value, l.how)
	end
	for _, e in ipairs(plan.fromStock) do
		lines[#lines + 1] = ("from stock: %s x%d %s%s"):format(
			e.name,
			e.crafts,
			e.verdict,
			e.extra and (" +" .. math.floor(e.extra + 0.5) .. "c/pt") or ""
		)
	end
	return lines
end

return F
