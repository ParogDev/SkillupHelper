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
-- Planner rules (README "Planner rules"):
-- 1. Buy for bad luck: every step that buys sizes its crafts and buys at a percentile of the crafts it takes to reach
--    its target (default p90, a setting: SkillupHelperDB.luck), never at the mean.
-- 2. Earmarks are hard: a material a later step uses is never spent by a stock alternative, a from-stock verdict or
--    a replan. Only true spares are offered.
-- 3. A bought step is committed: its recipe and target hold until the target is reached or the recipe greys.
P.LUCK = 90 -- percentile of crafts every buy covers
P.TRIP_Z = 1.2816 -- z of the default percentile (normal approximation)
local Z_OF = { [50] = 0, [75] = 0.6745, [80] = 0.8416, [90] = 1.2816, [95] = 1.6449, [99] = 2.3263 }

-- z for a luck percentile (50, 75, 80, 90, 95, 99); nil for any other value.
function P.zOf(pct)
	return Z_OF[tonumber(pct) or -1]
end
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

-- Whether input.exclude drops recipe r (spell) from the plan: a "not now" spell, an AH pattern, a dungeon pattern.
-- A recipe already learned is never dropped as a pattern: the pattern is no longer needed.
local function excluded(exclude, spell, r, learned)
	if not exclude then
		return false
	elseif exclude.notNow and exclude.notNow[spell] then
		return true
	elseif learned then
		return false
	elseif exclude.ahPatterns and r.src == "item" then
		return true
	end
	return exclude.dungeon == true and r.patternSrc == "dungeon"
end

-- The cap model: the skill the plan reaches and the ranks it trains on the way. Walks input.ranks above the live
-- cap: a rank whose character level is known and above the player's stops there (ctx.capBlock), any other raises
-- the effective cap and is trained between its unlock skill (at; nil = unknown, placed as by) and the cap before it
-- (by). The plan never goes past input.target, nor past the top skill its recipes cover (ctx.coverage).
local function capModel(ctx, input)
	local live = input.cap
	ctx.liveCap = live
	ctx.rankUps = {}
	local ranks = input.ranks or {}
	local target = input.target or live
	if #ranks == 0 or not live then
		ctx.cap = live and math.min(live, target) or live
		return
	end
	local list = {}
	for _, rk in ipairs(ranks) do
		list[#list + 1] = rk
	end
	table.sort(list, function(a, b)
		return a.cap < b.cap
	end)
	local eff = live
	for _, rk in ipairs(list) do
		if eff >= target then
			break
		end
		if rk.cap > eff then
			local reason
			if rk.level and input.level and rk.level > input.level then
				reason = "level"
			elseif rk.where == "special" and not (input.exclude and input.exclude.special == false) then
				-- taught by a special teacher (dungeon NPC, ...): not an ordinary trainer visit
				reason = "special"
			end
			if reason then
				ctx.capBlock =
					{ name = rk.name, level = rk.level, have = input.level, cap = rk.cap, reason = reason, by = eff }
				break
			end
			ctx.rankUps[#ctx.rankUps + 1] = {
				name = rk.name,
				cap = rk.cap,
				by = eff,
				at = rk.skill,
				level = rk.level,
				cost = rk.cost,
				where = rk.where,
			}
			eff = rk.cap
		end
	end
	ctx.cap = math.min(eff, target)
	-- coverage: the top skill any recipe gives (its grey); the plan stops there, never below the live cap
	local top
	for _, r in pairs(input.recipes or {}) do
		if r.g and (not top or r.g > top) then
			top = r.g
		end
	end
	if top and top < target then
		ctx.coverage = { to = top }
	end
	if top and top < ctx.cap then
		ctx.cap = math.max(live, top)
	end
	-- ranks the plan no longer reaches: not trained, and a blocked rank past the recipes' end is no stop
	local kept = {}
	for _, up in ipairs(ctx.rankUps) do
		if up.by < ctx.cap then
			kept[#kept + 1] = up
		end
	end
	ctx.rankUps = kept
	if ctx.capBlock and eff ~= ctx.cap then
		ctx.capBlock = nil
	end
end

-- Options (recipe variants) the planner can use: learned recipes, trainer recipes from their learn rank, recipe items
-- with a price as candidates to buy. The client's colour at the current skill wins over the exported thresholds.
-- input.exclude (dungeon, ahPatterns, notNow[spell]) drops recipes; input.ranks, level and target set the cap model.
function P.prepare(input)
	local ctx = {
		skill = input.skill,
		cap = input.cap,
		level = input.level,
		exclude = input.exclude,
		price = input.price or {},
		product = input.product or {},
		items = input.items or {},
		learned = input.learned or {},
		effort = input.effort or P.EFFORT,
		-- true: plan only with recipes already known or trainable (the "/skillup recipes off" setting)
		noRecipeBuys = input.noRecipeBuys == true,
		z = P.zOf(input.luck) or P.TRIP_Z,
		options = {},
		hidden = {}, -- gated options the plan never picks, offered in step.shortcuts and step.others
		unconfirmed = 0, -- trainer recipes planned while no trainer of this profession was read yet
		mismatch = {},
		makers = {},
	}
	capModel(ctx, input)
	local recipes = input.recipes or {}
	local spells = sortedKeys(recipes)
	for _, spell in ipairs(spells) do
		local r = recipes[spell]
		if
			r.makes
			and ctx.learned[spell]
			and not ctx.makers[r.makes]
			and not excluded(input.exclude, spell, r, true)
		then
			ctx.makers[r.makes] = { spell = spell, mats = pairsOf(r.mats), n = r.n or 1 }
		end
	end
	local skill = ctx.skill
	for _, spell in ipairs(spells) do
		local r = recipes[spell]
		local y, g = r.y, r.g
		local learned = ctx.learned[spell] == true
		local out = excluded(input.exclude, spell, r, learned)
		local diff = input.difficulty and input.difficulty[spell]
		if not out and learned and diff ~= nil and y and g then
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
			local src = "known"
			if not learned then
				src = (r.src == "item" or r.src == "auto" or r.src == "special") and r.src or "trainer"
			end
			-- a trainer recipe no ordinary trainer was seen to teach is "not checked": gated, like a special teacher's
			local unchecked = src == "trainer"
				and input.trainerSeen ~= nil
				and not input.trainerSeen[spell]
				and not (r.name and input.trainerSeen[string.lower(r.name)])
			if src == "trainer" and input.trainerSeen == nil then
				ctx.unconfirmed = ctx.unconfirmed + 1
			end
			-- gated: not sure to be obtainable (special teacher, quest, unchecked trainer recipe). The plan never picks
			-- it unless the user said "use it" (exclude.allow[spell]) or enabled special teachers; it is offered as a
			-- shortcut on the steps it would make cheaper, or on a gap it fills.
			local allowed = input.exclude and input.exclude.allow and input.exclude.allow[spell] == true
			local gated = not allowed
				and (unchecked or (src == "special" and not (input.exclude and input.exclude.special == false)))
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
				train = src == "trainer",
				unchecked = unchecked or nil,
				gated = gated or nil,
				allowed = allowed or nil,
				teacher = src == "special" and r.teacher or nil,
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
			-- a gated recipe is only shown, as a shortcut or an alternative (ctx.hidden)
			local into = gated and ctx.hidden or ctx.options
			for _, o in ipairs(list) do
				into[#into + 1] = o
			end
		end
	end
	return ctx
end

-- Whether o's product goes to the AH: only when the sale beats the vendor and the market takes any.
-- costPt, stockPass and finish all count proceeds by this one rule.
local function sells(o)
	return o.sell ~= nil and o.sell > o.vendor and o.takes > 0
end
P.sells = sells

-- What one craft of o brings back when cum crafts of it were already sold.
local function backOf(o, cum)
	if sells(o) and (cum or 0) < o.takes then
		return o.sell
	end
	return o.vendor
end
P.backOf = backOf

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
	local net = mat - backOf(o, cum)
	local c = ((net > 0 and net or 0) + ctx.effort * (1 + o.precrafts)) / p
	return c, p, net
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

-- No one-craft interleaving: a run of recipe B of at most P.ISLAND points between two runs of recipe A becomes A,
-- unless B saves at least P.INTERLEAVE_SAVING of the cost left from there, or A gives no skill there.
P.ISLAND = 1
P.INTERLEAVE_SAVING = 0.1

local function smooth(ctx, levels, chance)
	local changed = true
	while changed do
		changed = false
		local runs = {}
		for s = ctx.skill, ctx.cap - 1 do
			local o = levels[s] and levels[s].o or false
			local last = runs[#runs]
			if last and last.o == o then
				last.to = s
			else
				runs[#runs + 1] = { o = o, from = s, to = s }
			end
		end
		for r = 2, #runs - 1 do
			local a, b = runs[r - 1].o, runs[r]
			if a and b.o and runs[r + 1].o == a and b.to - b.from + 1 <= P.ISLAND then
				-- A's crafts so far count for its AH sales
				local cum = 0
				for s = ctx.skill, b.from - 1 do
					if levels[s] and levels[s].o == a then
						cum = cum + 1 / levels[s].p
					end
				end
				local save, repl = 0, {}
				for s = b.from, b.to do
					local c, p = costPt(ctx, a, s, cum, nil, chance)
					-- a level the user's swap picked is never smoothed away
					if not c or levels[s].picked then
						repl = nil
						break
					end
					cum = cum + 1 / p
					repl[s] = { o = a, c = c, p = p, costs = levels[s].costs }
					save = save + c - levels[s].c
				end
				if repl then
					local remaining = 0
					for s = b.from, ctx.cap - 1 do
						remaining = remaining + (levels[s] and levels[s].c or 0)
					end
					if save < P.INTERLEAVE_SAVING * remaining then
						for s, lv in pairs(repl) do
							levels[s] = lv
						end
						changed = true
						break
					end
				end
			end
		end
	end
	return levels
end

-- The user's swaps (input.exclude.swap[Y] = X, "use X instead of Y"): the option that replaces best at level s, the
-- cheapest variant of X with a cost there, following a chain Y -> X -> Z to its last link that has one. Returns
-- o, c, p, net, or nil when no swap applies at s.
local function swapAt(ctx, opts, best, s, cum, chance)
	local swap = ctx.exclude and ctx.exclude.swap
	if not swap then
		return nil
	end
	local spell, seen = best.spell, {}
	local po, pc, pp, pnet
	while swap[spell] and not seen[spell] do
		seen[spell] = true
		spell = swap[spell]
		local bo, bc, bp, bnet
		for _, o in ipairs(opts) do
			if o.spell == spell then
				local c, p, net = costPt(ctx, o, s, cum[o], nil, chance)
				if c and better(c, p, net, bc, bp, bnet) then
					bo, bc, bp, bnet = o, c, p, net
				end
			end
		end
		if bo then
			po, pc, pp, pnet = bo, bc, bp, bnet
		end
	end
	return po, pc, pp, pnet
end

-- Cheapest option per level. Each level also keeps every spell's cost there (costs[spell], its cheapest variant):
-- the alternatives (step.others) come from it. A level the user's swap decided is `picked` (swapFrom: the spell it
-- replaced): smoothing and the stock pass leave it alone.
local function forward(ctx, opts, chance)
	local levels, cum = {}, {}
	for s = ctx.skill, ctx.cap - 1 do
		local best, bc, bp, bnet
		local costs = {}
		for _, o in ipairs(opts) do
			local c, p, net = costPt(ctx, o, s, cum[o], nil, chance)
			if c then
				if not costs[o.spell] or c < costs[o.spell] then
					costs[o.spell] = c
				end
				if better(c, p, net, bc, bp, bnet) then
					best, bc, bp, bnet = o, c, p, net
				end
			end
		end
		for _, o in ipairs(ctx.hidden or {}) do
			local c = costPt(ctx, o, s, 0, nil, chance)
			if c and (not costs[o.spell] or c < costs[o.spell]) then
				costs[o.spell] = c
			end
		end
		local so, sc, sp = nil, nil, nil
		if best then
			so, sc, sp = swapAt(ctx, opts, best, s, cum, chance)
		end
		if so and so.spell ~= best.spell then
			cum[so] = (cum[so] or 0) + 1 / sp
			levels[s] = { o = so, c = sc, p = sp, costs = costs, picked = true, swapFrom = best.spell }
		elseif best then
			cum[best] = (cum[best] or 0) + 1 / bp
			levels[s] = { o = best, c = bc, p = bp, costs = costs }
		else
			levels[s] = false
		end
	end
	return smooth(ctx, levels, chance)
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
	-- a recipe item the user swapped to ("Use this") is bought whatever it saves
	local buys, bought = {}, {}
	local swapTo = {}
	for _, to in pairs(ctx.exclude and ctx.exclude.swap or {}) do
		swapTo[to] = true
	end
	for _, c in ipairs(cands) do
		if swapTo[c.spell] then
			opts[#opts + 1] = c
			if not bought[c.spell] then
				bought[c.spell] = true
				buys[#buys + 1] =
					{ spell = c.spell, item = c.recipeItem, price = c.recipePrice, learn = c.at, swap = true }
			end
		end
	end
	local levels = forward(ctx, opts, chance)
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
-- route: spells of committed steps (rule 3); their levels, and every level forced by a commit, keep the bought recipe.
local function stockPass(ctx, base, have, route)
	local chance = base.chance
	local demand, var, users = {}, {}, {}
	for s = ctx.skill, ctx.cap - 1 do
		local lv = base.levels[s]
		if lv then
			for i, n in pairs(lv.o.mats) do
				demand[i] = (demand[i] or 0) + n / lv.p
			end
			local p = math.min(lv.p, 1)
			if not var[lv.o] then
				users[#users + 1] = lv.o
			end
			var[lv.o] = (var[lv.o] or 0) + (1 - p) / (p * p)
		end
	end
	-- rule 1: buys cover the luck percentile of crafts, so those spares are not surplus while their recipe still runs,
	-- or a replan after a bad-luck run would spend them elsewhere (rule 2)
	for _, o in ipairs(users) do
		local spare = ctx.z * math.sqrt(var[o])
		for i, n in pairs(o.mats) do
			demand[i] = demand[i] + n * spare
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
			local net = mat - backOf(o, 0)
			local numer = (net > 0 and net or 0) + ctx.effort * (1 + o.precrafts)
			for s = math.max(ctx.skill, o.at == -math.huge and ctx.skill or math.ceil(o.at)), ctx.cap - 1 do
				local lv = base.levels[s]
				if
					(not lv or o ~= lv.o) and not (lv and (lv.committed or lv.picked or (route and route[lv.o.spell])))
				then
					local p = chance(s, o.y, o.g) * o.k
					if p <= 0 then
						break
					end
					local c = numer / p
					local gain = (lv and lv.c or HUGE) - c + P.BIAS
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

-- Whole crafts of o the pool still holds its owned reagents for (math.huge when it owns none of them).
local function stockLimit(ctx, o, have, pool)
	local limit = math.huge
	for _, i in ipairs(ownedKinds(ctx, o, have)) do
		limit = math.min(limit, math.floor((pool[i] or 0) / o.mats[i] + EPS))
	end
	return limit
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
		-- one recipe over one contiguous range is one step: stock against buy is a materials line, not a boundary
		if last and ((part.gap and last.gap) or (not part.gap and last.o == part.o)) then
			if part.source == "buy" or last.source == "buy" then
				last.source = "buy"
			elseif part.source ~= last.source then
				last.source = "mixed"
			end
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

-- Crafts it takes to go from skill `from` to `to` with o: mean and variance. Each point at level s takes a geometric
-- number of crafts with success p(s) (mean 1/p, variance (1-p)/p^2); a part of a level counts by its share.
function P.craftSpread(from, to, o, chance)
	chance = chance or P.chance
	local mean, var = 0, 0
	local s = math.floor(from)
	while s < to - EPS do
		local f = math.min(to, s + 1) - math.max(from, s)
		local p = chance(s, o.y, o.g) * (o.k or 1)
		if p <= 0 then
			break
		end
		p = math.min(p, 1)
		mean = mean + f / p
		var = var + f * (1 - p) / (p * p)
		s = s + 1
	end
	return mean, var
end

-- The option each step crafts and the option of its stock alternative (internal; plans stay plain data).
local optOf = setmetatable({}, { __mode = "k" })
local altOf = setmetatable({}, { __mode = "k" })

-- Rule 3: the levels of committed steps ({ spell, to }: a saved AH trip) keep their recipe until `to` is reached or
-- the recipe greys, whatever the baseline picks now. Returns a copy of base (the cached baseline is never changed),
-- the set of committed spells, and the set of forced levels.
local function commitLevels(ctx, base, commits, chance)
	local committed = {}
	if not commits or #commits == 0 then
		return base, committed
	end
	local levels = {}
	for s, lv in pairs(base.levels) do
		levels[s] = lv
	end
	local opts = {}
	for _, o in ipairs(base.opts) do
		opts[#opts + 1] = o
	end
	for _, cm in ipairs(commits) do
		-- the option the baseline used for this spell, else its plain variant
		local pick
		for s = ctx.skill, ctx.cap - 1 do
			local lv = base.levels[s]
			if lv and lv.o.spell == cm.spell then
				pick = lv.o
				break
			end
		end
		if not pick then
			for _, o in ipairs(ctx.options) do
				if o.spell == cm.spell and o.variant == 1 and (o.learned or o.src ~= "item") then
					pick = o
				end
			end
		end
		local to = math.min(math.ceil((cm.to or ctx.skill) - EPS), ctx.cap)
		if pick and ctx.skill < to then
			local any = false
			for s = ctx.skill, to - 1 do
				local c, p = costPt(ctx, pick, s, 0, nil, chance)
				if c then
					local lv0 = base.levels[s]
					levels[s] = { o = pick, c = c, p = p, committed = true, costs = lv0 and lv0.costs or nil }
					any = true
				end
			end
			if any then
				committed[pick.spell] = true
				local seen = false
				for _, o in ipairs(opts) do
					seen = seen or o == pick
				end
				if not seen then
					opts[#opts + 1] = pick
				end
			end
		end
	end
	return setmetatable({ levels = levels, opts = opts }, { __index = base }), committed
end

P.OTHERS = 3 -- alternatives kept per step
P.SHORTCUTS = 2 -- shortcuts (gated recipes that save money or fill a gap) kept per step
P.SHORTCUT_MIN = 100 -- copper: a gated recipe saving less than this over a step is not worth a detour

-- A shortcut entry: the gated option o, what it saves over the step (nil on a gap), and what it takes to get it.
local function shortcutOf(o, saves)
	local needs
	if o.src == "special" then
		needs = o.teacher or "a special teacher"
	elseif o.unchecked then
		needs = "no trainer you opened teaches it"
	end
	return { spell = o.spell, name = o.name, saves = saves, src = o.src, needs = needs }
end

-- Other ways to cover a craft step: every spell the baseline priced at each of the step's levels, its extra cost over
-- the step's points (each level weighted by the share of it the step covers), cheapest first, at most P.OTHERS.
local function othersOf(ctx, base, step, info)
	if step.to <= step.from + EPS then
		return nil
	end
	local lo = math.floor(step.from)
	local hi = math.min(math.max(lo, math.ceil(step.to - EPS) - 1), ctx.cap - 1)
	local extra
	for s = lo, hi do
		local lv = base.levels[s]
		if not lv or not lv.costs then
			return nil
		end
		local f = math.max(0, math.min(step.to, s + 1) - math.max(step.from, s))
		local now = {}
		for spell, c in pairs(lv.costs) do
			-- an alternative covers the whole step: a spell missing at any level drops out. The spell a swap replaced
			-- is not an alternative: the step offers "Back to" it (step.swapFrom).
			if spell ~= step.spell and spell ~= step.swapFrom and (not extra or extra[spell]) then
				now[spell] = (extra and extra[spell] or 0) + f * (c - lv.c)
			end
		end
		extra = now
	end
	local out, cuts = {}, {}
	for spell, x in pairs(extra or {}) do
		local o = info[spell]
		if o and o.gated and x < -P.SHORTCUT_MIN then
			-- a gated recipe that would make this step cheaper: a shortcut, with what it saves
			cuts[#cuts + 1] = shortcutOf(o, -x)
		else
			out[#out + 1] = {
				spell = spell,
				name = o and o.name,
				extra = math.max(0, x),
				src = o and o.src,
				teacher = o and o.teacher,
				unchecked = o and o.unchecked,
				-- gated: shown, never switched to ("Use it" on a shortcut is the way in)
				gated = o and o.gated,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.extra ~= b.extra then
			return a.extra < b.extra
		end
		return a.spell < b.spell
	end)
	for k = #out, P.OTHERS + 1, -1 do
		out[k] = nil
	end
	table.sort(cuts, function(a, b)
		if a.saves ~= b.saves then
			return a.saves > b.saves
		end
		return a.spell < b.spell
	end)
	for k = #cuts, P.SHORTCUTS + 1, -1 do
		cuts[k] = nil
	end
	return #out > 0 and out or nil, #cuts > 0 and cuts or nil
end

-- Gated recipes that give skill at every level of a gap step: shortcuts that fill it (saves = nil), cheapest first.
local function gapFills(ctx, step, chance)
	local lo, hi = math.floor(step.from), math.min(math.ceil(step.to - EPS) - 1, ctx.cap - 1)
	local cuts = {}
	for _, o in ipairs(ctx.hidden or {}) do
		if o.variant == 1 then
			local total = 0
			for s = lo, hi do
				local c = costPt(ctx, o, s, 0, nil, chance)
				if not c then
					total = nil
					break
				end
				total = total + c
			end
			if total then
				local cut = shortcutOf(o, nil)
				cut.cost = total
				cuts[#cuts + 1] = cut
			end
		end
	end
	table.sort(cuts, function(a, b)
		if a.cost ~= b.cost then
			return a.cost < b.cost
		end
		return a.spell < b.spell
	end)
	for k = #cuts, P.SHORTCUTS + 1, -1 do
		cuts[k] = nil
	end
	return #cuts > 0 and cuts or nil
end

-- The skill at the boundary before steps[i]: where the next step with a range starts (the plan's end after the last).
local function startOf(ctx, steps, i)
	for j = i, #steps do
		if steps[j].from then
			return steps[j].from
		end
	end
	for j = #steps, 1, -1 do
		if steps[j].to then
			return steps[j].to
		end
	end
	return ctx.skill
end

-- Rank training in the step list. Per rank-up (window [at, by]; at unknown = by): at or past by, train first. Else
-- batch it before a trainer visit already in the window, else the earliest step boundary in the window. When one run
-- straddles the whole window it is never split: the step carries step.rankUp ("train between at and by").
local function placeRanks(ctx, steps)
	for _, up in ipairs(ctx.rankUps or {}) do
		local lo, hi = up.at or up.by, up.by
		local function rankStep(skill)
			return {
				kind = "trainRank",
				name = up.name,
				cap = up.cap,
				by = up.by,
				at = up.at,
				level = up.level,
				cost = up.cost,
				where = up.where,
				skill = skill,
			}
		end
		local function inWindow(s)
			return s >= lo - EPS and s <= hi + EPS
		end
		local placed = false
		if ctx.skill >= hi - EPS then
			local i = 1
			while steps[i] and steps[i].kind == "trainRank" do
				i = i + 1
			end
			table.insert(steps, i, rankStep(ctx.skill))
			placed = true
		end
		if not placed then
			for i, st in ipairs(steps) do
				if st.kind == "train" and inWindow(startOf(ctx, steps, i)) then
					table.insert(steps, i, rankStep(startOf(ctx, steps, i)))
					placed = true
					break
				end
			end
		end
		if not placed then
			for i = 1, #steps + 1 do
				local s = startOf(ctx, steps, i)
				if inWindow(s) then
					table.insert(steps, i, rankStep(s))
					placed = true
					break
				end
			end
		end
		if not placed then
			for _, st in ipairs(steps) do
				if st.from and st.to and st.to > hi + EPS then
					st.rankUp = up
					placed = true
					break
				end
			end
		end
		if not placed then
			steps[#steps + 1] = rankStep(startOf(ctx, steps, #steps + 1))
		end
	end
end

-- Pass 2 to 4 for the formula run, compared with the flat run. Cheap: rerun on every bag update.
-- commits: the steps the user bought for (rule 3), { { spell, to } }.
local function finishCore(ctx, baseline, have, commits)
	have = have or {}
	local chance = baseline.formula.chance
	local base, committed = commitLevels(ctx, baseline.formula, commits, chance)
	local route = next(committed) and committed or nil
	local st = stockPass(ctx, base, have, route)
	local flatSt = stockPass(ctx, baseline.flat, have, route)
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
		elseif seg.source == "buy" and math.max(cur, seg.from) >= math.min(seg.to, ctx.cap) - EPS then
			-- an earlier stock step's expected points already passed this stretch: nothing left to buy for
			cur = math.max(cur, seg.from)
		elseif
			seg.source ~= "buy"
			and stockLimit(ctx, seg.o, have, pool) < 1
			and segs[idx + 1]
			and segs[idx + 1].o == seg.o
			and segs[idx + 1].source == "buy"
		then
			-- the stock this segment counted on is gone and the same recipe is bought next: one buy step, not two
			local nx = segs[idx + 1]
			nx.from, nx.alloc = seg.from, nx.alloc + seg.alloc
			nx.pts, nx.cost = nx.pts + seg.pts, nx.cost + seg.cost
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
					owned = (have[b.item] or 0) > 0 or nil, -- in the bags already: learn it, no AH
					saves = b.saves,
					fillsGap = b.fillsGap,
					alt = b.instead and { spell = b.instead, name = b.insteadName, extra = b.saves } or nil,
				}
			elseif o.train and not announced[o.spell] then
				announced[o.spell] = true
				steps[#steps + 1] =
					{ kind = "train", spell = o.spell, name = o.name, at = o.at, unchecked = o.unchecked }
			end
			local crafts
			local source = seg.source
			if source ~= "buy" then
				local limit = stockLimit(ctx, o, have, pool)
				if limit < 1 then
					-- an earlier step used up the stock this one counted on: buy for it, never claim stock the bags lack
					source = "buy"
				else
					crafts = math.max(1, math.min(math.ceil(seg.alloc - EPS), limit))
				end
			end
			local from = math.max(cur, seg.from)
			local pts, expected
			if source == "buy" then
				-- rule 1: buy for the luck percentile of the crafts to the step's target, not for the mean; the
				-- target holds (a lucky run ends the step early and leaves spares as stock)
				local target = math.min(seg.to, ctx.cap)
				local mean, var = P.craftSpread(from, target, o, chance)
				expected = mean
				crafts = math.max(1, math.ceil(mean + ctx.z * math.sqrt(var) - EPS))
				pts = math.max(0, target - from)
			else
				pts = P.expectedPoints(from, crafts, o, chance, ctx.cap)
			end
			local step = {
				kind = "craft",
				spell = o.spell,
				name = o.name,
				crafts = crafts,
				expected = expected, -- buy steps: the mean crafts (crafts is the luck percentile)
				source = source,
				from = from,
				to = from + pts,
				points = pts,
				committed = committed[o.spell] or nil,
				unchecked = o.unchecked, -- taught by a trainer nobody has seen teach it yet
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
			if sells(o) then
				soldHere = math.max(0, math.min(crafts, o.takes - (sold[o.spell] or 0)))
				sold[o.spell] = (sold[o.spell] or 0) + soldHere
			end
			step.cash = { out = out, back = soldHere * (o.sell or 0) + (crafts - soldHere) * o.vendor }
			if source ~= "buy" and step.color ~= "orange" then
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
			if source == "buy" then
				step.poolBefore = poolBefore
			end
			optOf[step] = o
			steps[#steps + 1] = step
			cur = step.to
		end
	end

	-- the stock alternative of each buy step: what is in the bags then, less everything a later step uses (rule 2:
	-- an earmark is hard, whether or not the plan buys more of that item later)
	for idx, step in ipairs(steps) do
		local before = step.poolBefore
		step.poolBefore = nil
		if before and not step.committed then
			local avail = {}
			for i, q in pairs(before) do
				avail[i] = q
			end
			for j = idx + 1, #steps do
				for _, u in ipairs(steps[j].used or {}) do
					avail[u.item] = (avail[u.item] or 0) - u.count
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
				altOf[step] = alt
			end
		end
	end

	-- pass 4: what is held for later steps, what is left over, the from-stock list
	local holdKey = {}
	-- an earmark names a different, later step: materials kept for the current recipe's own next crafts are not one
	local current
	for _, step in ipairs(steps) do
		if step.kind == "craft" then
			current = current or step.spell
		end
	end
	for _, step in ipairs(steps) do
		if step.kind == "craft" and math.floor(step.from) > ctx.skill and step.spell ~= current then
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
	local patterns = {} -- a recipe item the plan learns later is not a leftover
	for _, step in ipairs(steps) do
		if step.kind == "buyRecipe" and step.item then
			patterns[step.item] = true
		end
	end
	for _, i in ipairs(sortedKeys(pool)) do
		local q = math.floor(pool[i] + EPS)
		if
			q >= 1
			and (have[i] or 0) > 0
			and not isVendor(ctx, i)
			and not patterns[i]
			and (st.rem[i] or 0) >= 1 - EPS
		then
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
	-- rule 2: the earmark of each item, the first step that uses it (later steps through plan.hold, first steps too)
	local held = {}
	for _, step in ipairs(steps) do
		for _, u in ipairs(step.kind == "craft" and step.used or {}) do
			if not held[u.item] and u.count > 0 then
				held[u.item] = { spell = step.spell, at = math.floor(step.from) }
			end
		end
	end
	local alts = {}
	for _, step in ipairs(steps) do
		if step.alt then
			alts[step.alt.spell] = step.alt
		end
	end
	for _, o in ipairs(ctx.options) do
		if o.learned and o.variant == 1 then
			-- crafts the bags hold reagents for (have), and crafts from true spares only (pool: what no step uses)
			local crafts, spare, any = math.huge, math.huge, false
			for i, n in pairs(o.mats) do
				if not isVendor(ctx, i) then
					any = true
					crafts = math.min(crafts, math.floor((have[i] or 0) / n + EPS))
					spare = math.min(spare, math.floor(math.max(0, pool[i] or 0) / n + EPS))
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
				for _, i in ipairs(sortedKeys(o.mats)) do
					if spare < 1 and held[i] and (not h or (h.spell == o.spell and held[i].spell ~= o.spell)) then
						h = held[i]
					end
				end
				if first[o.spell] == true then
					e.verdict = "now"
				elseif first[o.spell] == "alternative" then
					e.verdict, e.crafts = "alternative", alts[o.spell].crafts
				elseif h then
					-- its reagents belong to another step: never offered as a way to spend them now
					e.verdict, e.instead, e.at = "later", h.spell, h.at
				elseif vNow and c > vNow * P.WASTEFUL then
					e.verdict, e.extra, e.crafts = "wasteful", c - vNow, spare
					e.instead = lv.o.spell
				else
					e.verdict, e.crafts = "ok", spare
				end
				e.points = P.expectedPoints(ctx.skill, e.crafts, o, chance, ctx.cap)
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
	-- alternatives, then the rank training (after every list above: neither changes what a craft step uses)
	local info = {}
	for _, list in ipairs({ ctx.options, ctx.hidden or {} }) do
		for _, o in ipairs(list) do
			info[o.spell] = info[o.spell] or o
		end
	end
	local cutSpells = {}
	for _, step in ipairs(steps) do
		if step.kind == "craft" then
			-- a step on a level the user's swap picked: the spell it replaced, for "Back to"
			local at = base.levels[math.floor(step.from)]
			if at and at.picked and at.o.spell == step.spell then
				step.swapFrom = at.swapFrom
				step.swapFromName = info[at.swapFrom] and info[at.swapFrom].name or nil
			end
			step.others, step.shortcuts = othersOf(ctx, base, step, info)
		elseif step.kind == "gap" then
			step.shortcuts = gapFills(ctx, step, chance)
		end
		for _, cut in ipairs(step.shortcuts or {}) do
			cutSpells[cut.spell] = true
		end
	end
	-- the plan uses only recipes it is sure of; this many gated ones would save money or fill a gap
	local nCuts = 0
	for _ in pairs(cutSpells) do
		nCuts = nCuts + 1
	end
	plan.shortcuts = nCuts
	plan.unconfirmed = ctx.unconfirmed > 0 and ctx.unconfirmed or nil
	placeRanks(ctx, steps)
	plan.liveCap = ctx.liveCap
	plan.rankUps = ctx.rankUps
	plan.capBlock = ctx.capBlock
	plan.coverage = ctx.coverage
	return plan
end

local function isAh(ctx, item)
	local pr = ctx.price[item]
	return pr ~= nil and pr.where ~= "vendor"
end

-- Whether a step sends the user to the AH: a recipe to buy there, or a reagent it buys there.
local function needsAh(ctx, st)
	if st.kind == "buyRecipe" then
		return not st.owned
	end
	for _, b in ipairs(st.kind == "craft" and st.buy or {}) do
		if isAh(ctx, b.item) then
			return true
		end
	end
	return false
end
P.needsAh = needsAh

-- One AH trip for the stretch ahead: every AH buy from the first step that needs the AH up to the next trainer visit,
-- gap or the cap (patterns are bought on the same trip), stopping early when gold on hand runs out. Each recipe
-- bought in the stretch buys for the 90th percentile of its crafts: the leftovers are stock for later steps.
local function tripOf(ctx, steps, chance, gold)
	local first
	for i, st in ipairs(steps) do
		if st.kind == "train" or st.kind == "trainRank" or st.kind == "gap" then
			return nil
		elseif needsAh(ctx, st) then
			first = i
			break
		end
	end
	if not first then
		return nil
	end
	local rows, byItem, spread = {}, {}, {}
	local total, last, ends = 0, first, "cap"
	local function add(item, count, each, field)
		local r = byItem[item]
		if not r then
			r = { item = item, count = 0, buffer = 0, each = each or 0 }
			byItem[item] = r
			rows[#rows + 1] = r
		end
		r[field] = r[field] + count
		total = total + count * (each or 0)
	end
	for i = first, #steps do
		local st = steps[i]
		if st.kind == "train" or st.kind == "trainRank" or st.kind == "gap" then
			ends = st.kind
			break
		end
		local cost = 0
		if st.kind == "buyRecipe" then
			cost = st.owned and 0 or (st.price or 0)
		else
			for _, b in ipairs(st.buy) do
				if isAh(ctx, b.item) then
					cost = cost + b.count * (b.each or 0)
				end
			end
		end
		if gold and i > first and total + cost > gold then
			ends = "gold"
			break
		end
		if st.kind == "buyRecipe" then
			if not st.owned then
				add(st.item, 1, st.price, "count")
				byItem[st.item].recipe = true
			end
		else
			local o = optOf[st]
			local bought = {}
			for _, b in ipairs(st.buy) do
				if isAh(ctx, b.item) then
					add(b.item, b.count, b.each, "count")
					bought[b.item] = true
				end
			end
			if o and next(bought) then
				local sp = spread[o]
				if not sp then
					sp = { mean = 0, var = 0, crafts = 0, items = {} }
					spread[o] = sp
					spread[#spread + 1] = o
				end
				local m, v = P.craftSpread(st.from, st.to, o, chance)
				sp.mean, sp.var, sp.crafts = sp.mean + m, sp.var + v, sp.crafts + st.crafts
				for item in pairs(bought) do
					sp.items[item] = true
				end
			end
		end
		last = i
	end
	-- the luck buffer over the whole trip: each buy step already covers its own percentile (rule 1); a recipe that runs
	-- over several steps only tops up where its joint percentile needs more than the steps' sum
	local spare = 0
	for _, o in ipairs(spread) do
		local sp = spread[o]
		local extra = math.ceil(sp.mean + ctx.z * math.sqrt(sp.var) - sp.crafts - EPS)
		if extra > 0 then
			spare = spare + extra
			for _, item in ipairs(sortedKeys(sp.items)) do
				add(item, math.ceil(o.mats[item] * extra - EPS), byItem[item].each, "buffer")
			end
		end
	end
	for _, r in ipairs(rows) do
		r.total = r.count + r.buffer
		r.cost = r.total * r.each
	end
	table.sort(rows, function(a, b)
		if a.cost ~= b.cost then
			return a.cost > b.cost
		end
		return a.item < b.item
	end)
	local lastStep = steps[last]
	-- the steps the trip buys for: saved with the list, they are committed (rule 3) until their target is reached
	local route, commit = {}, {}
	for i = first, last do
		local st = steps[i]
		if st.kind == "craft" then
			route[#route + 1] = st.spell
			commit[#commit + 1] = { spell = st.spell, from = st.from, to = st.to, crafts = st.crafts }
		end
	end
	return {
		fromStep = first,
		toStep = last,
		to = lastStep.to or lastStep.learn or ctx.skill,
		ends = ends,
		rows = rows,
		total = total,
		spareCrafts = spare,
		route = route,
		commit = commit,
	}
end
P.tripOf = tripOf

-- The shopping list grouped by place, for the stretch ahead: the trainer visits due now (leading train and trainRank
-- steps), then every step up to the next trainer visit or gap, or the trip's last step (gold). One trainer block, one
-- vendor block (merged per item, by merchant), one AH block (reagents and patterns merged per item, plus the trip's
-- luck buffer). order = travel order: trainer and vendor before the AH, never vendor, AH, vendor.
function P.shoppingOf(ctx, steps, trip)
	local shop = { vendor = {}, ah = {}, trainer = {}, order = {} }
	local function trainerRow(st, i)
		shop.trainer[#shop.trainer + 1] = {
			kind = st.kind,
			name = st.name,
			skill = st.kind == "trainRank" and st.skill or st.at,
			cost = st.cost,
			step = i,
		}
	end
	local i = 1
	while steps[i] and (steps[i].kind == "train" or steps[i].kind == "trainRank") do
		trainerRow(steps[i], i)
		i = i + 1
	end
	local vendorBy, ahBy = {}, {}
	local function add(block, by, item, count, each, extra, idx)
		local r = by[item]
		if not r then
			local info = ctx.items[item] or {}
			r = { item = item, name = info.name, count = 0, price = each, step = idx }
			for k, v in pairs(extra) do
				r[k] = v
			end
			by[item] = r
			block[#block + 1] = r
		end
		r.count = r.count + count
	end
	local stop = trip and trip.toStep or #steps
	for j = i, stop do
		local st = steps[j]
		if st.kind == "train" or st.kind == "trainRank" or st.kind == "gap" then
			break
		elseif st.kind == "buyRecipe" then
			if not st.owned then
				add(shop.ah, ahBy, st.item, 1, st.price, { kind = "pattern" }, j)
			end
		elseif st.kind == "craft" then
			for _, b in ipairs(st.buy) do
				if isVendor(ctx, b.item) then
					local pr = ctx.price[b.item] or {}
					local info = ctx.items[b.item] or {}
					add(shop.vendor, vendorBy, b.item, b.count, b.each, { merchant = pr.merchant or info.merchant }, j)
				elseif isAh(ctx, b.item) then
					add(shop.ah, ahBy, b.item, b.count, b.each, { kind = "reagent" }, j)
				end
			end
		end
	end
	for _, r in ipairs(trip and trip.rows or {}) do
		if ahBy[r.item] and (r.buffer or 0) > 0 then
			ahBy[r.item].count = ahBy[r.item].count + r.buffer
		end
	end
	table.sort(shop.vendor, function(a, b)
		local ma, mb = a.merchant and tostring(a.merchant), b.merchant and tostring(b.merchant)
		if ma ~= mb then
			if not ma or not mb then
				return ma ~= nil
			end
			return ma < mb
		elseif a.step ~= b.step then
			return a.step < b.step
		end
		return a.item < b.item
	end)
	table.sort(shop.ah, function(a, b)
		if a.step ~= b.step then
			return a.step < b.step
		end
		return a.item < b.item
	end)
	for _, k in ipairs({ "trainer", "vendor", "ah" }) do
		if #shop[k] > 0 then
			shop.order[#shop.order + 1] = k
		end
	end
	return shop
end

-- Pass 2 to 4, then the AH trip and the shopping list. opts: commit (the steps of the saved trip, { { spell, to } }:
-- rule 3), gold (copper on hand: the trip stops where it runs out).
function P.finish(ctx, baseline, have, opts)
	opts = opts or {}
	local plan = finishCore(ctx, baseline, have or {}, opts.commit)
	plan.luck = ctx.z
	plan.trip = tripOf(ctx, plan.steps, baseline.formula.chance, opts.gold)
	plan.shopping = P.shoppingOf(ctx, plan.steps, plan.trip)
	return plan
end

-- The whole planner in one call (tests, and the panel when nothing is cached).
function P.run(input)
	local ctx = P.prepare(input)
	return P.finish(ctx, P.baseline(ctx, input.chance), input.have, { commit = input.commit, gold = input.gold })
end
