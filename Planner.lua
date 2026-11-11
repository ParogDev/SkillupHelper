-- The skill-up planner (design: scaffolding research/2026-11-11-skillup-planner.md). Pure: no client calls, every
-- input passed in, so busted tests it whole.
--
--   costPt(o, s) = (max(net, 0) + effort * (1 + precrafts)) / (p(s) * skillups)
--
-- Pass 1 picks the cheapest option per level at buy prices (and buys recipe items that save more than they cost).
-- Pass 2 gives owned stock the plan does not need to the levels where it saves most (greedy fill, best saving per
-- unit first). Pass 3 turns levels into ordered steps; pass 4 gives verdicts (hold, leftovers, the from-stock list).
local _, ns = ...
local P = {}
ns.Planner = P

P.EFFORT = 20 -- copper per craft (a setting: SkillupHelperDB.effort)
P.SELL_SHARE = 0.5 -- a leftover is worth max(vendor sell, this share of the market value)
P.BIAS = 10 -- copper per point: owned stock wins a near tie
P.CRAFT_SAVING = 0.2 -- craft an intermediate only when that saves this share of its buy price
P.MAX_RECIPE_BUYS = 3
P.WASTEFUL = 1.1 -- a from-stock recipe more than 10% over the plan's cost per point is "wasteful"
P.CANDS_PER_LEVEL = 6 -- stock candidates kept per level for the greedy fill
local HUGE = 1e7 -- cost per point of a level nothing covers
local EPS = 1e-6

-- Skill-up chance per craft: the vanilla-client formula (an assumption for Forever, as in tools/tsm/skillup.py).
function P.chance(s, y, g)
	if s < y then
		return 1
	elseif s >= g or g <= y then
		return 0
	end
	return (g - s) / (g - y)
end

-- The colour-band guess (Logic.lua's constants): the second run that tags steps depending on the formula.
function P.flatChance(s, y, g)
	if s < y then
		return 1
	elseif s >= g then
		return 0
	end
	return s < math.floor((y + g) / 2) and 0.75 or 0.25
end

local function colorOf(s, y, g)
	if s < y then
		return "orange"
	elseif s >= g then
		return "grey"
	end
	return s < math.floor((y + g) / 2) and "yellow" or "green"
end
P.colorOf = colorOf

local CLIENT_COLOR = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "grey" }

local function pairsOf(flat)
	local out = {}
	for i = 1, #(flat or {}) - 1, 2 do
		out[flat[i]] = (out[flat[i]] or 0) + flat[i + 1]
	end
	return out
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

local function merge(into, from)
	for k, v in pairs(from) do
		into[k] = (into[k] or 0) + v
	end
end

local function buyOf(ctx, item)
	local pr = ctx.price[item]
	return pr and pr.buy
end

local function salvageOf(ctx, item)
	local pr = ctx.price[item]
	return pr and pr.salvage or 0
end

local function isVendor(ctx, item)
	local pr = ctx.price[item]
	return pr ~= nil and pr.where == "vendor"
end

-- (cost, materials, intermediates) for qty of item: bought, or crafted through a learned recipe when that saves
-- CRAFT_SAVING or the item has no price (tools/tsm/skillup.py _expand). nil when neither works.
local function expand(ctx, item, qty, depth, skipSpell)
	local buy = buyOf(ctx, item)
	local best
	if buy then
		best = { buy * qty, { [item] = qty }, {} }
	end
	local maker = ctx.makers[item]
	if maker and depth > 0 and maker.spell ~= skipSpell then
		local total, mats, pre = 0, {}, { [item] = qty }
		for _, sub in ipairs(sortedKeys(maker.mats)) do
			local got = expand(ctx, sub, qty * maker.mats[sub] / maker.n, depth - 1, skipSpell)
			if not got then
				total = nil
				break
			end
			total = total + got[1]
			merge(mats, got[2])
			merge(pre, got[3])
		end
		if total and (not best or total < best[1] * (1 - P.CRAFT_SAVING)) then
			best = { total, mats, pre }
		end
	end
	return best
end

local function matCost(ctx, mats)
	local total, missing = 0, nil
	for i, n in pairs(mats) do
		local b = buyOf(ctx, i)
		if b then
			total = total + n * b
		else
			missing = missing or {}
			missing[#missing + 1] = i
		end
	end
	if missing then
		table.sort(missing)
		return nil, missing
	end
	return total
end

local function newOption(ctx, base, mats, pre, variant)
	local o = {}
	for k, v in pairs(base) do
		o[k] = v
	end
	o.mats, o.pre, o.variant = mats, pre or {}, variant
	o.precrafts = 0
	for _, q in pairs(o.pre) do
		o.precrafts = o.precrafts + q
	end
	o.matBuy, o.missing = matCost(ctx, mats)
	o.export = false
	for i in pairs(mats) do
		local pr = ctx.price[i]
		if pr and pr.export then
			o.export = true
		end
	end
	return o
end

-- Options (recipe variants) the planner can use: learned recipes, trainer recipes from their learn rank, recipe items
-- with a price as candidates to buy. The client's colour at the current skill wins over the exported thresholds.
function P.prepare(input)
	local ctx = {
		skill = input.skill,
		cap = input.cap,
		price = input.price or {},
		product = input.product or {},
		items = input.items or {},
		learned = input.learned or {},
		effort = input.effort or P.EFFORT,
		bias = input.bias or P.BIAS,
		noRecipeBuys = input.noRecipeBuys,
		options = {},
		mismatch = {},
		makers = {},
	}
	local recipes = input.recipes or {}
	local spells = sortedKeys(recipes)
	for _, spell in ipairs(spells) do
		local r = recipes[spell]
		if r.makes and ctx.learned[spell] and not ctx.makers[r.makes] then
			ctx.makers[r.makes] = { spell = spell, mats = pairsOf(r.mats), n = r.n or 1 }
		end
	end
	local skill = ctx.skill
	for _, spell in ipairs(spells) do
		local r = recipes[spell]
		local y, g = r.y, r.g
		local learned = ctx.learned[spell] == true
		local out = false
		local diff = input.difficulty and input.difficulty[spell]
		if learned and diff ~= nil and y and g then
			local cc, tc = CLIENT_COLOR[diff], colorOf(skill, y, g)
			if cc and cc ~= tc then
				ctx.mismatch[#ctx.mismatch + 1] = { spell = spell, client = cc, data = tc }
				if cc == "grey" then
					out = true
				elseif cc == "orange" and y <= skill then
					y = skill + 1
				elseif cc ~= "orange" and skill < y then
					y = skill
				end
				if cc ~= "grey" and g <= skill then
					g = skill + 1
				end
				if g <= y then
					g = y + 1
				end
			end
		end
		if not out and y and g and g > skill then
			local src = learned and "known" or (r.src == "item" and "item" or (r.src == "auto" and "auto" or "trainer"))
			local at = -math.huge
			if not learned then
				at = r.learn or (src == "item" and 0 or y)
			end
			local prod = ctx.product[spell]
			if not prod then
				local info = r.makes and ctx.items[r.makes]
				prod = { vendor = (info and info.sell or 0) * (r.n or 1), sell = r.sell, takes = r.takes or 0 }
			end
			local base = {
				spell = spell,
				name = r.name or ("spell " .. spell),
				y = y,
				g = g,
				k = r.k or 1,
				src = src,
				learned = learned,
				at = at,
				train = not learned and src ~= "item",
				recipeItem = r.item,
				recipePrice = src == "item" and buyOf(ctx, r.item or -1) or nil,
				vendor = prod.vendor or 0,
				sell = prod.sell,
				takes = prod.takes or 0,
				prodExport = prod.export,
			}
			local plain = pairsOf(r.mats)
			local list = { newOption(ctx, base, plain, nil, 1) }
			-- intermediates through learned recipes: one variant with every reagent at its cheaper route
			local mats, pre, ok, differs = {}, {}, true, false
			for _, item in ipairs(sortedKeys(plain)) do
				local got = expand(ctx, item, plain[item], 2, spell)
				if not got then
					ok = false
					break
				end
				merge(mats, got[2])
				merge(pre, got[3])
				if next(got[3]) then
					differs = true
				end
			end
			if ok and differs then
				list[#list + 1] = newOption(ctx, base, mats, pre, 2)
			end
			for _, o in ipairs(list) do
				ctx.options[#ctx.options + 1] = o
			end
		end
	end
	return ctx
end

-- Cost per expected point of option o at skill s. cheap: items counted at salvage (owned surplus).
-- Returns cost, p (points per craft), net per craft; nil when o gives no skill or lacks a price.
local function costPt(ctx, o, s, cum, cheap, chance)
	if s < o.at then
		return nil
	end
	local p = chance(s, o.y, o.g) * o.k
	if p <= 0 then
		return nil
	end
	local mat = o.matBuy
	if cheap then
		mat = 0
		for i, n in pairs(o.mats) do
			local each = cheap[i] and salvageOf(ctx, i) or buyOf(ctx, i)
			if not each then
				return nil
			end
			mat = mat + n * each
		end
	elseif not mat then
		return nil
	end
	local back = (o.sell and (cum or 0) < o.takes) and o.sell or o.vendor
	local net = mat - back
	return ((net > 0 and net or 0) + ctx.effort * (1 + o.precrafts)) / p, p, net
end
P.costPt = costPt

-- Cheaper per point; ties (both free, effort 0): fewer crafts, then the larger profit (skillup.py's key).
local function better(c, p, net, bc, bp, bnet)
	if not bc then
		return true
	elseif c < bc - 1e-9 then
		return true
	elseif c > bc + 1e-9 then
		return false
	elseif p > bp + 1e-9 then
		return true
	elseif p < bp - 1e-9 then
		return false
	end
	return net < bnet
end

local function forward(ctx, opts, chance)
	local levels, cum = {}, {}
	for s = ctx.skill, ctx.cap - 1 do
		local best, bc, bp, bnet
		for _, o in ipairs(opts) do
			local c, p, net = costPt(ctx, o, s, cum[o], nil, chance)
			if c and better(c, p, net, bc, bp, bnet) then
				best, bc, bp, bnet = o, c, p, net
			end
		end
		if best then
			cum[best] = (cum[best] or 0) + 1 / bp
			levels[s] = { o = best, c = bc, p = bp }
		else
			levels[s] = false
		end
	end
	return levels
end

-- Pass 1 for one chance model: cheapest option per level, recipe items bought while one saves more than it costs.
local function baselineFor(ctx, chance)
	local opts, cands = {}, {}
	for _, o in ipairs(ctx.options) do
		if o.src ~= "item" then
			opts[#opts + 1] = o
		elseif o.recipePrice and not ctx.noRecipeBuys then
			cands[#cands + 1] = o
		end
	end
	local levels = forward(ctx, opts, chance)
	local buys, bought = {}, {}
	for _ = 1, P.MAX_RECIPE_BUYS do
		local best, bestSave
		for _, c in ipairs(cands) do
			if not bought[c.spell] and c.matBuy then
				local save, cum = -c.recipePrice, 0
				for s = ctx.skill, ctx.cap - 1 do
					local cost, p = costPt(ctx, c, s, cum, nil, chance)
					local v = levels[s] and levels[s].c or HUGE
					if cost and cost < v then
						save = save + (v - cost)
						cum = cum + 1 / p
					end
				end
				if save > 1 and (not bestSave or save > bestSave) then
					best, bestSave = c, save
				end
			end
		end
		if not best then
			break
		end
		bought[best.spell] = true
		for _, c in ipairs(cands) do
			if c.spell == best.spell then
				opts[#opts + 1] = c
			end
		end
		local before = levels
		levels = forward(ctx, opts, chance)
		local instead
		for s = ctx.skill, ctx.cap - 1 do
			if levels[s] and levels[s].o.spell == best.spell then
				instead = before[s] and before[s].o or nil
				break
			end
		end
		local fillsGap = bestSave >= HUGE / 2
		buys[#buys + 1] = {
			spell = best.spell,
			item = best.recipeItem,
			price = best.recipePrice,
			learn = best.at,
			saves = not fillsGap and bestSave or nil,
			fillsGap = fillsGap or nil,
			instead = (not fillsGap and instead) and instead.spell or nil,
			insteadName = (not fillsGap and instead) and instead.name or nil,
		}
	end
	return { levels = levels, opts = opts, buys = buys, chance = chance }
end

-- Pass 1, both chance models. Cached by the caller: it changes only with skill, cap, recipes or prices.
function P.baseline(ctx, chance)
	return {
		formula = baselineFor(ctx, chance or P.chance),
		flat = baselineFor(ctx, P.flatChance),
	}
end

-- Pass 2: owned units the baseline does not use, given to the levels where they save most per unit.
local function stockPass(ctx, base, have)
	local chance = base.chance
	local demand = {}
	for s = ctx.skill, ctx.cap - 1 do
		local lv = base.levels[s]
		if lv then
			for i, n in pairs(lv.o.mats) do
				demand[i] = (demand[i] or 0) + n / lv.p
			end
		end
	end
	local rem = {}
	for i, q in pairs(have) do
		local r = q - (demand[i] or 0)
		if r > 1e-9 then
			rem[i] = r
		end
	end
	-- options usable without buying a recipe: the baseline's, plus learned or trainer ones that lack a buy price
	local usable, seen = {}, {}
	for _, o in ipairs(base.opts) do
		usable[#usable + 1], seen[o] = o, true
	end
	for _, o in ipairs(ctx.options) do
		if not seen[o] and o.src ~= "item" then
			usable[#usable + 1] = o
		end
	end
	-- per option the cost of one craft with its surplus reagents at salvage does not depend on the level: only p does
	local perLevel = {}
	for _, o in ipairs(usable) do
		local mine, ok, mat, worst = nil, true, 0, 0
		for i, n in pairs(o.mats) do
			if rem[i] then
				mine = mine or {}
				mine[i] = true
				mat = mat + n * salvageOf(ctx, i)
				worst = math.max(worst, n)
			else
				local b = buyOf(ctx, i)
				if b then
					mat = mat + n * b
				else
					ok = false
				end
			end
		end
		if ok and mine then
			local net = mat - ((o.sell and o.takes > 0) and o.sell or o.vendor)
			local numer = (net > 0 and net or 0) + ctx.effort * (1 + o.precrafts)
			for s = math.max(ctx.skill, o.at == -math.huge and ctx.skill or math.ceil(o.at)), ctx.cap - 1 do
				local lv = base.levels[s]
				if not lv or o ~= lv.o then
					local p = chance(s, o.y, o.g) * o.k
					if p <= 0 then
						break
					end
					local c = numer / p
					local gain = (lv and lv.c or HUGE) - c + ctx.bias
					if gain > 0 then
						local list = perLevel[s] or {}
						perLevel[s] = list
						list[#list + 1] = { s = s, o = o, c = c, p = p, mine = mine, ratio = gain * p / worst }
					end
				end
			end
		end
	end
	-- a level is covered by one or two options at most: keep its best few candidates, so the sort stays small
	local cands = {}
	for s = ctx.skill, ctx.cap - 1 do
		local list = perLevel[s]
		if list then
			if #list > P.CANDS_PER_LEVEL then
				table.sort(list, function(a, b)
					return a.ratio > b.ratio
				end)
			end
			for k = 1, math.min(#list, P.CANDS_PER_LEVEL) do
				cands[#cands + 1] = list[k]
			end
		end
	end
	table.sort(cands, function(a, b)
		if a.ratio ~= b.ratio then
			return a.ratio > b.ratio
		elseif a.s ~= b.s then
			return a.s < b.s
		elseif a.o.spell ~= b.o.spell then
			return a.o.spell < b.o.spell
		end
		return a.o.variant < b.o.variant
	end)
	local cover, left = {}, {}
	for _, cd in ipairs(cands) do
		local lf = left[cd.s] or 1
		local f = lf
		for i in pairs(cd.mine) do
			f = math.min(f, rem[i] * cd.p / cd.o.mats[i])
		end
		if f > EPS then
			for i in pairs(cd.mine) do
				rem[i] = rem[i] - f * cd.o.mats[i] / cd.p
			end
			left[cd.s] = lf - f
			cover[cd.s] = cover[cd.s] or {}
			table.insert(cover[cd.s], { o = cd.o, f = f, c = cd.c, p = cd.p })
		end
	end
	return { cover = cover, left = left, rem = rem, demand = demand }
end

-- Levels as an ordered list of parts: inside one level the recipe with the lower grey goes first (an orange craft
-- loses nothing by waiting).
local function partsOf(ctx, base, st)
	local parts = {}
	for s = ctx.skill, ctx.cap - 1 do
		local list = {}
		for _, cv in ipairs(st.cover[s] or {}) do
			list[#list + 1] = { o = cv.o, f = cv.f, c = cv.c, p = cv.p, s = s }
		end
		table.sort(list, function(a, b)
			if a.o.g ~= b.o.g then
				return a.o.g < b.o.g
			end
			return a.o.spell < b.o.spell
		end)
		local lf = st.left[s] or 1
		if lf > EPS then
			local lv = base.levels[s]
			list[#list + 1] = lv and { o = lv.o, f = lf, c = lv.c, p = lv.p, s = s } or { gap = true, f = lf, s = s }
		end
		for _, part in ipairs(list) do
			parts[#parts + 1] = part
		end
	end
	return parts
end

-- Which spells each level uses (baseline or stock), for comparing two chance models.
local function usage(ctx, base, st)
	local used = {}
	for s = ctx.skill, ctx.cap - 1 do
		used[s] = {}
		for _, cv in ipairs(st.cover[s] or {}) do
			used[s][cv.o.spell] = true
		end
		if (st.left[s] or 1) > EPS and base.levels[s] then
			used[s][base.levels[s].o.spell] = true
		end
	end
	return used
end

-- Owned kinds: the non-vendor reagents of o the user has any of.
local function ownedKinds(ctx, o, have)
	local kinds = {}
	for i in pairs(o.mats) do
		if not isVendor(ctx, i) and (have[i] or 0) > 0 then
			kinds[#kinds + 1] = i
		end
	end
	return kinds
end

-- Split each part where stock runs out and label it: stock (every non-vendor reagent from stock), mixed (owned ones
-- from stock, others bought) or buy.
local function labelParts(ctx, parts, have)
	local pool = {}
	for i, q in pairs(have) do
		pool[i] = q
	end
	local out = {}
	local function consume(o, crafts)
		for i, n in pairs(o.mats) do
			if pool[i] then
				pool[i] = math.max(0, pool[i] - n * crafts)
			end
		end
	end
	for _, part in ipairs(parts) do
		if part.gap then
			out[#out + 1] = part
		else
			local o = part.o
			local crafts = part.f / part.p
			local kinds = ownedKinds(ctx, o, have)
			local sf = #kinds > 0 and 1 or 0
			for _, i in ipairs(kinds) do
				sf = math.min(sf, (pool[i] or 0) / (o.mats[i] * crafts))
			end
			local allOwned = true
			for i in pairs(o.mats) do
				if not isVendor(ctx, i) and (have[i] or 0) <= 0 then
					allOwned = false
				end
			end
			local stockLabel = allOwned and "stock" or "mixed"
			if sf >= 1 - EPS then
				part.source = stockLabel
				out[#out + 1] = part
				consume(o, crafts)
			elseif sf <= EPS then
				part.source = "buy"
				out[#out + 1] = part
				consume(o, crafts)
			else
				local a = { o = o, f = part.f * sf, c = part.c, p = part.p, s = part.s, source = stockLabel }
				local b = { o = o, f = part.f * (1 - sf), c = part.c, p = part.p, s = part.s, source = "buy" }
				out[#out + 1] = a
				consume(o, a.f / a.p)
				out[#out + 1] = b
				consume(o, b.f / b.p)
			end
		end
	end
	return out
end

local function segmentsOf(parts)
	local segs = {}
	for _, part in ipairs(parts) do
		local last = segs[#segs]
		if last and ((part.gap and last.gap) or (not part.gap and last.o == part.o and last.source == part.source)) then
			last.to = part.s + 1
			last.alloc = last.alloc + (part.gap and 0 or part.f / part.p)
			last.pts = last.pts + part.f
			last.cost = last.cost + (part.c or 0) * part.f
		else
			segs[#segs + 1] = {
				o = part.o,
				gap = part.gap,
				source = part.source,
				from = part.s,
				to = part.s + 1,
				alloc = part.gap and 0 or part.f / part.p,
				pts = part.f,
				cost = (part.c or 0) * part.f,
			}
		end
	end
	return segs
end

-- Expected skill points of `crafts` crafts of o from skill `s` (fractional), the chance falling as skill rises.
function P.expectedPoints(s, crafts, o, chance, cap)
	chance = chance or P.chance
	local cur = s
	for _ = 1, crafts do
		if cap and cur >= cap then
			break
		end
		local p = chance(math.floor(cur), o.y, o.g) * (o.k or 1)
		if p <= 0 then
			break
		end
		cur = cur + p
	end
	-- skill stops at the cap
	return (cap and math.min(cur, cap) or cur) - s
end

local function trueCostPt(ctx, o, s, have, st, chance)
	local cheap
	for i in pairs(o.mats) do
		-- owned and surplus to the plan: salvage; owned and the plan buys more anyway: its buy price
		if (have[i] or 0) > 0 and (st.demand[i] or 0) < (have[i] or 0) - EPS then
			cheap = cheap or {}
			cheap[i] = true
		end
	end
	return costPt(ctx, o, s, 0, cheap, chance)
end

-- The cheapest learned option craftable now from stock plus vendor reagents, other than `skip`.
local function stockAlternative(ctx, s, pool, skip, st, have, chance)
	local best, bc, bcrafts, bp
	for _, o in ipairs(ctx.options) do
		if o.learned and o.spell ~= skip and o.variant == 1 then
			local crafts, any = math.huge, false
			for i, n in pairs(o.mats) do
				if not isVendor(ctx, i) then
					any = true
					crafts = math.min(crafts, math.floor((pool[i] or 0) / n + EPS))
				end
			end
			if any and crafts >= 1 then
				local c, p = trueCostPt(ctx, o, s, have, st, chance)
				if c and (not bc or c < bc) then
					best, bc, bcrafts, bp = o, c, crafts, p
				end
			end
		end
	end
	return best, bc, bcrafts, bp
end

-- Pass 2 to 4 for the formula run, compared with the flat run. Cheap: rerun on every bag update.
function P.finish(ctx, baseline, have)
	have = have or {}
	local base, chance = baseline.formula, baseline.formula.chance
	local st = stockPass(ctx, base, have)
	local flatSt = stockPass(ctx, baseline.flat, have)
	local flatUse = usage(ctx, baseline.flat, flatSt)
	local parts = labelParts(ctx, partsOf(ctx, base, st), have)
	local segs = segmentsOf(parts)

	local plan = {
		skill = ctx.skill,
		cap = ctx.cap,
		model = "formula",
		steps = {},
		hold = {},
		leftovers = {},
		fromStock = {},
		skipped = {},
		colourMismatch = ctx.mismatch,
	}
	local buyBySpell = {}
	for _, b in ipairs(base.buys) do
		buyBySpell[b.spell] = b
	end
	local announced = {}
	local pool = {}
	for i, q in pairs(have) do
		pool[i] = q
	end
	local sold = {}
	local cur = ctx.skill
	local steps = plan.steps
	for idx, seg in ipairs(segs) do
		if cur >= ctx.cap then
			break
		end
		if seg.gap then
			steps[#steps + 1] = {
				kind = "gap",
				from = seg.from,
				to = seg.to,
				why = "no known or buyable recipe gives skill here",
			}
			cur = math.max(cur, seg.to)
		else
			local o = seg.o
			local b = buyBySpell[o.spell]
			if b and not announced[o.spell] then
				announced[o.spell] = true
				steps[#steps + 1] = {
					kind = "buyRecipe",
					spell = o.spell,
					name = o.name,
					item = b.item,
					price = b.price,
					where = "ah",
					learn = b.learn,
					saves = b.saves,
					fillsGap = b.fillsGap,
					alt = b.instead and { spell = b.instead, name = b.insteadName, extra = b.saves } or nil,
				}
			elseif o.train and not announced[o.spell] then
				announced[o.spell] = true
				steps[#steps + 1] = { kind = "train", spell = o.spell, name = o.name, at = o.at }
			end
			local crafts
			if seg.source == "buy" then
				crafts = math.max(1, math.ceil(seg.alloc - EPS))
			else
				local limit = math.huge
				for _, i in ipairs(ownedKinds(ctx, o, have)) do
					limit = math.min(limit, math.floor((pool[i] or 0) / o.mats[i] + EPS))
				end
				crafts = math.max(1, math.min(math.ceil(seg.alloc - EPS), limit))
			end
			local from = math.max(cur, seg.from)
			local pts = P.expectedPoints(from, crafts, o, chance, ctx.cap)
			local step = {
				kind = "craft",
				spell = o.spell,
				name = o.name,
				crafts = crafts,
				source = seg.source,
				from = from,
				to = from + pts,
				points = pts,
				color = colorOf(math.floor(from), o.y, o.g),
				-- the chance at the first craft and at the last one
				chance = {
					chance(math.floor(from), o.y, o.g),
					chance(math.floor(math.max(from, from + pts - 1)), o.y, o.g),
				},
				thresholds = { o.y, o.g, o.k },
				buy = {},
				used = {},
				pre = {},
				tags = {},
				costPt = seg.pts > 0 and seg.cost / seg.pts or nil,
			}
			local out, export = 0, o.prodExport == true
			local poolBefore = {}
			for i, q in pairs(pool) do
				poolBefore[i] = q
			end
			for _, i in ipairs(sortedKeys(o.mats)) do
				local need = o.mats[i] * crafts
				local use = math.min(pool[i] or 0, need)
				if use > 0 then
					pool[i] = (pool[i] or 0) - use
					step.used[#step.used + 1] = { item = i, count = math.floor(use + EPS) }
				end
				local count = math.ceil(need - use - EPS)
				if count > 0 then
					local pr = ctx.price[i] or {}
					step.buy[#step.buy + 1] = { item = i, count = count, where = pr.where, each = pr.buy }
					out = out + count * (pr.buy or 0)
					if pr.export then
						export = true
					end
				end
			end
			for _, i in ipairs(sortedKeys(o.pre)) do
				step.pre[#step.pre + 1] = {
					item = i,
					count = math.ceil(o.pre[i] * crafts - EPS),
					spell = ctx.makers[i] and ctx.makers[i].spell,
				}
			end
			local soldHere = 0
			if o.sell and o.sell > o.vendor then
				soldHere = math.max(0, math.min(crafts, o.takes - (sold[o.spell] or 0)))
				sold[o.spell] = (sold[o.spell] or 0) + soldHere
			end
			step.cash = { out = out, back = soldHere * (o.sell or 0) + (crafts - soldHere) * o.vendor }
			if seg.source ~= "buy" and step.color ~= "orange" then
				local later = false
				for j = idx + 1, #segs do
					if segs[j].o and segs[j].o.spell == o.spell then
						later = true
					end
				end
				if not later then
					step.tags[#step.tags + 1] = "last use"
				end
			end
			if soldHere > 0 then
				step.tags[#step.tags + 1] = "needs AH sale"
			end
			local lo = math.floor(from)
			local hi = math.max(lo, math.ceil(step.to) - 1)
			local inFlat = false
			for s = lo, math.min(hi, ctx.cap - 1) do
				if flatUse[s] and flatUse[s][o.spell] then
					inFlat = true
				end
			end
			if not inFlat then
				step.tags[#step.tags + 1] = "chance model"
				for spell in pairs(flatUse[lo] or {}) do
					step.flatInstead = math.min(step.flatInstead or spell, spell)
				end
			end
			if export or o.export then
				step.tags[#step.tags + 1] = "prices from export"
			end
			if seg.source == "buy" then
				step.poolBefore = poolBefore
			end
			steps[#steps + 1] = step
			cur = step.to
		end
	end

	-- the stock alternative of each buy step: what is in the bags then, less what a later step keeps for itself (an
	-- item the plan buys more of anyway stays available: using it now costs its buy price, which the extra shows)
	for idx, step in ipairs(steps) do
		local before = step.poolBefore
		step.poolBefore = nil
		if before then
			local avail = {}
			for i, q in pairs(before) do
				avail[i] = q
			end
			for j = idx + 1, #steps do
				for _, u in ipairs(steps[j].used or {}) do
					if (st.demand[u.item] or 0) < (have[u.item] or 0) - EPS then
						avail[u.item] = (avail[u.item] or 0) - u.count
					end
				end
			end
			local lo = math.floor(step.from)
			local alt, ac, acrafts = stockAlternative(ctx, lo, avail, step.spell, st, have, chance)
			local lv0 = base.levels[lo]
			local v = lv0 and lv0.c or step.costPt
			if alt and v then
				local apts = P.expectedPoints(step.from, acrafts, alt, chance, ctx.cap)
				step.alt = {
					spell = alt.spell,
					name = alt.name,
					crafts = acrafts,
					source = "stock",
					points = apts,
					extra = math.max(0, (ac - v) * math.min(apts, step.points)),
				}
			end
		end
	end

	-- pass 4: what is held for later steps, what is left over, the from-stock list
	local holdKey = {}
	for _, step in ipairs(steps) do
		if step.kind == "craft" and math.floor(step.from) > ctx.skill then
			for _, u in ipairs(step.used) do
				if not isVendor(ctx, u.item) and u.count > 0 then
					local key = u.item .. ":" .. step.spell
					local h = holdKey[key]
					if not h then
						h = {
							item = u.item,
							count = 0,
							spell = step.spell,
							name = step.name,
							at = math.floor(step.from),
						}
						holdKey[key] = h
						plan.hold[#plan.hold + 1] = h
					end
					h.count = h.count + u.count
				end
			end
		end
	end
	for _, i in ipairs(sortedKeys(pool)) do
		local q = math.floor(pool[i] + EPS)
		if q >= 1 and (have[i] or 0) > 0 and not isVendor(ctx, i) and (st.rem[i] or 0) >= 1 - EPS then
			local pr = ctx.price[i] or {}
			local info = ctx.items[i] or {}
			plan.leftovers[#plan.leftovers + 1] = {
				item = i,
				count = q,
				value = q * salvageOf(ctx, i),
				how = (pr.salvage or 0) > (info.sell or 0) and "ah" or "vendor",
			}
		end
	end
	local lv = base.levels[ctx.skill]
	local vNow = lv and lv.c
	local first = {}
	for _, step in ipairs(steps) do
		if step.kind == "craft" and math.floor(step.from) <= ctx.skill then
			first[step.spell] = true
			if step.alt then
				first[step.alt.spell] = "alternative"
			end
		end
	end
	local held = {}
	for _, h in ipairs(plan.hold) do
		held[h.item] = held[h.item] or h
	end
	for _, o in ipairs(ctx.options) do
		if o.learned and o.variant == 1 then
			local crafts, any = math.huge, false
			for i, n in pairs(o.mats) do
				if not isVendor(ctx, i) then
					any = true
					crafts = math.min(crafts, math.floor((have[i] or 0) / n + EPS))
				end
			end
			local c, p = trueCostPt(ctx, o, ctx.skill, have, st, chance)
			if any and crafts >= 1 and p then
				local e = {
					spell = o.spell,
					name = o.name,
					crafts = crafts,
					costPt = c,
					color = colorOf(ctx.skill, o.y, o.g),
				}
				local h
				for i in pairs(o.mats) do
					h = h or held[i]
				end
				if first[o.spell] then
					e.verdict = first[o.spell] == "alternative" and "alternative" or "now"
				elseif vNow and c > vNow * P.WASTEFUL then
					e.verdict, e.extra = "wasteful", c - vNow
					e.instead = lv.o.spell
				elseif h then
					e.verdict, e.instead, e.at = "later", h.spell, h.at
				else
					e.verdict = "ok"
				end
				e.points = P.expectedPoints(ctx.skill, crafts, o, chance, ctx.cap)
				plan.fromStock[#plan.fromStock + 1] = e
			end
		end
	end
	local rank = { now = 1, alternative = 2, ok = 3, later = 4, wasteful = 5 }
	table.sort(plan.fromStock, function(a, b)
		if rank[a.verdict] ~= rank[b.verdict] then
			return rank[a.verdict] < rank[b.verdict]
		end
		return a.costPt < b.costPt
	end)
	-- options that cannot be priced and are not owned (U5)
	local seenSpell = {}
	for _, o in ipairs(ctx.options) do
		if o.variant == 1 and o.missing and not seenSpell[o.spell] then
			local owned = false
			for _, i in ipairs(o.missing) do
				if (have[i] or 0) > 0 then
					owned = true
				end
			end
			local hasVariant = false
			for _, x in ipairs(ctx.options) do
				if x.spell == o.spell and x.matBuy then
					hasVariant = true
				end
			end
			if not owned and not hasVariant then
				seenSpell[o.spell] = true
				local names = {}
				for _, i in ipairs(o.missing) do
					local info = ctx.items[i]
					names[#names + 1] = info and info.name or ("item " .. i)
				end
				plan.skipped[#plan.skipped + 1] =
					{ spell = o.spell, name = o.name, why = "no price for " .. table.concat(names, ", ") }
			end
		end
	end
	plan.buys = base.buys
	return plan
end

-- The whole planner in one call (tests, and the panel when nothing is cached).
function P.run(input)
	local ctx = P.prepare(input)
	return P.finish(ctx, P.baseline(ctx, input.chance), input.have)
end
