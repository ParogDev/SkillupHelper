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
-- 4. The guide is the route: at a skill the guide covers (input.route, Data/Routes.lua), the plan chooses only among
--    the recipes the guide names there (main pick and alternatives, faction-filtered); prices, stock and rule 1 pick
--    between them. A level where none gives skill falls back to the cheapest recipe and says why (level.offGuide). The
--    user's swap, "not now" and the settings still win over the guide. Owned stock never moves a guide level off it.
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
-- CRAFT_SAVING or the item has no price (tools/tsm/skillup.py _expand). nil when neither works. force: craft this
-- item whenever a learned recipe can, whatever buying it costs (the stock-only variants of P.prepare).
local function expand(ctx, item, qty, depth, skipSpell, force)
	local buy = buyOf(ctx, item)
	local best
	if buy and not (force and ctx.makers[item] and depth > 0 and ctx.makers[item].spell ~= skipSpell) then
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
	-- a forced craft that cannot be priced (a sub-reagent without a price) falls back to buying: the caller sees no
	-- intermediate and builds no stock-only variant
	if not best and buy then
		best = { buy * qty, { [item] = qty }, {} }
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

-- Why the vendor of recipe r's item is not assumed reachable, or nil: the item asks for a reputation, or the vendor
-- is hostile to the character's faction (r.vendor.a / .h: the NPC's reaction to Alliance / Horde, nil = not known;
-- faction = "Alliance" | "Horde" | nil, and with no faction given a vendor hostile to either side is not assumed).
local function vendorBlock(r, faction)
	if r.faction or r.rep then
		return "its vendor asks for a reputation"
	end
	local v = r.vendor
	local side = (faction == "Horde" and "h") or (faction == "Alliance" and "a") or nil
	if (side and v[side] == -1) or (not side and (v.a == -1 or v.h == -1)) then
		return "its vendor is the other faction's"
	end
	return nil
end

-- Where a recipe item comes from, for a shortcut's text: the vendor's name, else the kind of source.
local FROM_TEXT = { vendor = "sold by a vendor", quest = "a quest reward", drop = "a drop", crafted = "crafted" }
local function fromText(o)
	if o.teacher then
		return o.teacher
	end
	local v = o.recipeVendor
	if type(v) == "table" and v.name then
		-- place: the zone the vendor stands in, by name (tools/gen_recipes.py, from the client's area and map tables)
		return "sold by " .. tostring(v.name) .. (type(v.place) == "string" and (" in " .. v.place) or "")
	end
	return o.from and (FROM_TEXT[o.from] or tostring(o.from)) or nil
end

-- Options (recipe variants) the planner can use: learned recipes, trainer recipes from their learn rank, recipe items
-- with a price as candidates to buy. The client's colour at the current skill wins over the exported thresholds.
-- input.exclude (dungeon, ahPatterns, notNow[spell]) drops recipes; input.ranks, level and target set the cap model.
-- input.route: the guide's entries for this skill line ({ { from, to, spell, alt, faction } }, Data/Routes.lua), rule 4.
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
		-- true: selling the products counts against a recipe's cost (the "Count selling what I craft" setting, off by
		-- default). Off: recipes are ranked by what the player pays, with no credit for any sale, AH or vendor.
		resale = input.resale == true,
		-- stretches levelled in the world (Mining's nodes): { { from, to, text, spot, why } }, sorted by from
		world = {},
		z = P.zOf(input.luck) or P.TRIP_Z,
		options = {},
		-- gated options: offered in step.shortcuts and step.others, and planned only where nothing else gives skill
		hidden = {},
		stockOnly = {}, -- variants that craft an intermediate from owned raw reagents: the stock pass only
		excludedOut = {}, -- { at, g } of the recipes input.exclude dropped (a gap's reason)
		unknownEach = 0, -- copper a unit of an unpriced reagent counts as, for ordering only (set below)
		unconfirmed = 0, -- trainer recipes planned while no trainer of this profession was read yet
		mismatch = {},
		makers = {},
	}
	for _, w in ipairs(type(input.world) == "table" and input.world or {}) do
		if type(w) == "table" and type(w.from) == "number" and type(w.to) == "number" and w.to > w.from then
			ctx.world[#ctx.world + 1] = w
		end
	end
	table.sort(ctx.world, function(a, b)
		return a.from < b.from
	end)
	capModel(ctx, input)
	local recipes = input.recipes or {}
	ctx.recipes = recipes
	-- the guide's route (rule 4): ctx.guide[s] = { [spell] = "main" | "alt" } for every skill an entry covers, the
	-- other faction's rows left out (ctx.guideOther[s]: a skill only such rows cover). nil without a route.
	ctx.guideSpell, ctx.guideWhy = {}, {}
	if type(input.route) == "table" and #input.route > 0 then
		ctx.guide, ctx.guideOther = {}, {}
		local side = type(input.faction) == "string" and string.lower(input.faction) or nil
		for _, e in ipairs(input.route) do
			if
				type(e) == "table"
				and type(e.spell) == "number"
				and type(e.from) == "number"
				and type(e.to) == "number"
			then
				local other = e.faction ~= nil and side ~= nil and e.faction ~= side
				for s = math.floor(e.from), math.ceil(e.to) - 1 do
					if other then
						ctx.guideOther[s] = true
					else
						local g = ctx.guide[s] or {}
						ctx.guide[s] = g
						if g[e.spell] ~= "main" then
							g[e.spell] = e.alt and "alt" or "main"
						end
					end
				end
				if not other then
					ctx.guideSpell[e.spell] = true
				end
			end
		end
	end
	local spells = sortedKeys(recipes)
	-- What the trainer lists read so far can say about a recipe: nothing above the highest learn skill they listed.
	-- A trainer window that hides what the character cannot learn yet (the client's default filter) lists only the
	-- recipes learnable at that skill, so a recipe learned later is "not listed yet", never "no trainer teaches it".
	-- (Read at skill 28, such a list once gated every trainer recipe above 28 and left Blacksmithing 185-215 a hole.)
	local seenTop
	if input.trainerSeen then
		for _, spell in ipairs(spells) do
			local r = recipes[spell]
			local at = r.learn or r.y
			if
				type(at) == "number"
				and (not seenTop or at > seenTop)
				and (input.trainerSeen[spell] or (r.name and input.trainerSeen[string.lower(r.name)]))
			then
				seenTop = at
			end
		end
	end
	-- the dearest reagent with a price: what a unit of an unpriced reagent counts as when recipes are compared
	-- (fallbackOpts). Recipe items are not reagents and stay out; with no price at all it is 0.
	for _, spell in ipairs(spells) do
		local mats = recipes[spell].mats or {}
		for k = 1, #mats - 1, 2 do
			local b = buyOf(ctx, mats[k])
			if b and b > ctx.unknownEach then
				ctx.unknownEach = b
			end
		end
	end
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
		-- gone: an item the recipe needs is not in the game data (Data/Recipes.lua); a learned one is real
		local out = excluded(input.exclude, spell, r, learned)
		if out and y and g and g > ctx.skill then
			-- a recipe the user's settings keep out: a stretch only such recipes cover is a hole with its own reason
			ctx.excludedOut[#ctx.excludedOut + 1] = { at = learned and -math.huge or (r.learn or 0), g = g }
		end
		if ctx.guideSpell[spell] then
			if out then
				ctx.guideWhy[spell] = "you left the guide's recipe out"
			elseif r.gone == true and not learned then
				ctx.guideWhy[spell] = "the guide's recipe needs an item missing from the game data"
			end
		end
		out = out or (r.gone == true and not learned)
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
				src = (r.src == "item" or r.src == "auto" or r.src == "special" or r.src == "unlisted") and r.src
					or "trainer"
			end
			-- a trainer recipe no ordinary trainer was seen to teach is "not checked": gated, like a special teacher's.
			-- Only up to the highest learn skill the lists reached (seenTop, above).
			local unchecked = src == "trainer"
				and input.trainerSeen ~= nil
				and seenTop ~= nil
				and (r.learn or y) <= seenTop
				and not input.trainerSeen[spell]
				and not (r.name and input.trainerSeen[string.lower(r.name)])
			if src == "trainer" and input.trainerSeen == nil then
				ctx.unconfirmed = ctx.unconfirmed + 1
			end
			-- gated: not sure to be obtainable (special teacher, quest, unchecked trainer recipe). The plan picks it only
			-- when the user said "use it" (exclude.allow[spell]) or enabled special teachers, or where nothing sure
			-- gives skill (the fallback of `forward`: never a hole while a recipe exists); it is offered as a shortcut
			-- on the steps it would make cheaper.
			local allowed = input.exclude and input.exclude.allow and input.exclude.allow[spell] == true
			-- a recipe item: one that binds when picked up is never an auction buy (ItemSparse.Bonding = 1; checked
			-- against auction data: none of those items is ever listed), and a tradeable one is an auction buy only
			-- while it has a price.
			local bop = src == "item" and r.bop == true
			local recipePrice = (src == "item" and not bop) and buyOf(ctx, r.item or -1) or nil
			local recipeWhere = "ah"
			-- a vendor known to sell the recipe item, at the item's vendor price: the cheaper of vendor and auction,
			-- and the one way to plan a recipe that binds when picked up. A vendor the character may not reach (the
			-- other faction's, a reputation) is not assumed: vendorWhy.
			local vendorWhy
			if src == "item" and type(r.vendor) == "table" and type(r.buy) == "number" then
				vendorWhy = vendorBlock(r, input.faction)
				if not vendorWhy and (not recipePrice or r.buy < recipePrice) then
					recipePrice, recipeWhere = r.buy, "vendor"
				end
			end
			-- with no way to buy it, a recipe item is gated: a shortcut that says why
			local noPrice = src == "item" and not bop and recipePrice == nil
			local bopOnly = bop and recipePrice == nil
			-- a recipe learned by character level (Poisons): not learnable yet below that level
			local tooLow = not learned
				and type(r.level) == "number"
				and type(input.level) == "number"
				and r.level > input.level
			local gated = not allowed
				and (
					unchecked
					or bopOnly
					or noPrice
					or tooLow
					-- not in the data's list of the profession's recipes: not confirmed obtainable
					or src == "unlisted"
					or (src == "special" and not (input.exclude and input.exclude.special == false))
				)
			-- rule 4: the guide confirms a recipe it names, so a gated one is planned, at the skills the guide uses it
			-- for only (guideOnly), unless it is not learnable yet (tooLow), its only vendor is out of reach, or the
			-- settings keep recipe buys out. A recipe item to buy is planned at the guide's skills only too.
			local guideOnly
			if ctx.guideSpell[spell] and not learned and src ~= "auto" then
				local why
				if tooLow then
					why = "the guide's recipe needs character level " .. tostring(r.level)
				elseif bopOnly and vendorWhy then
					why = "the guide's recipe can't be got: " .. vendorWhy
				elseif ctx.noRecipeBuys and src ~= "trainer" then
					why = "recipe buys are off (/skillup recipes on)"
				end
				if why then
					ctx.guideWhy[spell] = why
				elseif gated or src == "item" then
					gated, guideOnly = false, not allowed
				end
			end
			local at = -math.huge
			if not learned then
				-- no learn skill in the data: a recipe item or a level-gated recipe has none, a trainer recipe is
				-- assumed learnable from yellow
				at = r.learn or ((src == "item" or type(r.level) == "number") and 0 or y)
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
				-- planned only at the skills the guide names it for (rule 4)
				guideOnly = guideOnly or nil,
				teacher = (src == "special" or bop) and r.teacher or nil,
				recipeItem = r.item,
				recipePrice = recipePrice,
				recipeWhere = recipePrice and recipeWhere or nil,
				recipeVendor = src == "item" and r.vendor or nil,
				vendorWhy = vendorWhy,
				from = src == "item" and r.from or nil,
				bop = bop or nil,
				noPrice = noPrice or nil,
				level = r.level,
				tooLow = tooLow or nil,
				trainCost = src == "trainer" and r.cost or nil,
				vendor = prod.vendor or 0,
				sell = prod.sell,
				takes = prod.takes or 0,
				prodExport = prod.export,
				-- resale off: the product's sale is information only (step.resale), never a credit
				noResale = not ctx.resale or nil,
			}
			local plain = pairsOf(r.mats)
			-- base.plain: the recipe's own reagents, what a step built from any variant supplies (bags, crafts, buys)
			base.plain = plain
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
			-- stock-only variants: one per reagent a learned recipe makes but the cheaper route buys (curing a hide saves
			-- under CRAFT_SAVING at buy prices). Only the stock pass uses them, where an owned raw reagent (16 Medium
			-- Hide) costs its salvage: then the step crafts that reagent and buys the rest (Salt).
			if ok and not gated then
				local variant = #list
				for _, item in ipairs(sortedKeys(plain)) do
					if ctx.makers[item] and not pre[item] then
						local fm, fp, fok = {}, {}, true
						for _, other in ipairs(sortedKeys(plain)) do
							local got = expand(ctx, other, plain[other], 2, spell, other == item)
							if not got then
								fok = false
								break
							end
							merge(fm, got[2])
							merge(fp, got[3])
						end
						if fok and fp[item] then
							variant = variant + 1
							local o = newOption(ctx, base, fm, fp, variant)
							o.stockOnly = true
							-- the raw reagents the variant crafts from (Medium Hide, Salt): the stock pass offers it only
							-- when one of them is owned surplus, never for a reagent the plain recipe shares (the leather)
							o.raws = {}
							for i, n in pairs(fm) do
								-- more than the plain recipe takes: a raw the plain recipe also lists counts too
								if n > (plain[i] or 0) + EPS then
									o.raws[i] = true
								end
							end
							ctx.stockOnly[#ctx.stockOnly + 1] = o
						end
					end
				end
			end
		end
	end
	return ctx
end

-- Whether o's product goes to the AH: only when the sale beats the vendor and the market takes any.
-- costPt, stockPass and finish all count proceeds by this one rule. wouldSell ignores the resale setting (the card's
-- note); sells is the rule the plan ranks and counts by: never true with resale off (o.noResale).
local function wouldSell(o)
	return o.sell ~= nil and o.sell > o.vendor and o.takes > 0
end
local function sells(o)
	return not o.noResale and wouldSell(o)
end
P.sells = sells

-- What one craft of o would bring back when cum crafts of it were already sold, whatever the setting.
local function resaleOf(o, cum)
	if wouldSell(o) and (cum or 0) < o.takes then
		return o.sell
	end
	return o.vendor
end

-- What one craft of o brings back when cum crafts of it were already sold: 0 with resale off.
local function backOf(o, cum)
	if o.noResale then
		return 0
	end
	return resaleOf(o, cum)
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

-- Rule 4. The guide's kind of spell at level s: "main", "alt" or nil (also nil without a route).
local function guideKind(ctx, s, spell)
	local g = ctx.guide and ctx.guide[s]
	return g and g[spell] or nil
end

-- Whether o may take level s at all: a recipe the guide alone lets in (guideOnly) only where the guide names it.
local function usableAt(ctx, o, s)
	return not o.guideOnly or guideKind(ctx, s, o.spell) ~= nil
end

-- Whether owned stock may put o on level lv (at s): on a guide level only the guide's recipes (rule 4).
local function stockMay(ctx, lv, o, s)
	if lv and lv.guide then
		return guideKind(ctx, s, o.spell) ~= nil
	end
	return usableAt(ctx, o, s)
end

-- Why the guide gives nothing at level s (a level the plan takes off the guide): the reason of its main pick first.
local function offGuideWhy(ctx, s)
	local g = ctx.guide and ctx.guide[s]
	if not g then
		return ctx.guideOther and ctx.guideOther[s] and "the guide's recipes here are the other faction's"
			or "the guide has nothing for this level"
	end
	if not ctx.optionOf then
		ctx.optionOf = {}
		for _, list in ipairs({ ctx.options, ctx.hidden }) do
			for _, o in ipairs(list) do
				ctx.optionOf[o.spell] = ctx.optionOf[o.spell] or o
			end
		end
	end
	local spells = sortedKeys(g)
	table.sort(spells, function(a, b)
		if g[a] ~= g[b] then
			return g[a] == "main"
		end
		return a < b
	end)
	for _, spell in ipairs(spells) do
		local o, r = ctx.optionOf[spell], ctx.recipes and ctx.recipes[spell]
		if ctx.guideWhy[spell] then
			return ctx.guideWhy[spell]
		elseif not r then
			return "the guide's recipe is not in the recipe data"
		elseif not o then
			if r.g and r.g <= s then
				return "the guide's recipes are grey here"
			end
			return "the guide's recipe has no thresholds in the data"
		elseif s >= o.g then
			return "the guide's recipes are grey here"
		elseif s < o.at then
			return ("the guide's recipe is learned at %d"):format(o.at)
		elseif o.gated then
			return "the guide's recipe is not sure to be obtainable"
		elseif o.missing then
			return "no price for the guide's recipe's reagents"
		end
	end
	return "the guide's recipes give no skill here"
end

-- The fallback: recipes for a level no sure, fully priced recipe covers. The owner's rule: a stretch is never a hole
-- because a price is missing or a recipe is gated; it is planned with the best recipe by what is known, and the step
-- says what is not known (step.unpriced, step.gated). Only a stretch no obtainable recipe covers is a hole.
--
-- An unknown price is never counted as free. For ordering only, a unit of an unpriced reagent counts as the dearest
-- reagent this profession has a price for (ctx.unknownEach, pessimistic), so:
--   * a sure recipe with an unpriced reagent (rank 1) takes a level from a fully priced one only when it is cheaper
--     even at that estimate (the priced one is nearly grey, say); at a similar yield the priced recipe wins;
--   * a gated recipe is looked at only on a level no sure recipe covers, priced or not, the lower rank first:
--       2  gated but ordinary (a trainer recipe no trainer listed, a tradeable recipe item with no auction price today)
--       4  gated and uncertain (binds when picked up, not confirmed in Forever, a special teacher)
--       +1 when it also has an unpriced reagent
--   then the lower estimated cost per point, then fewer unpriced reagents.
-- The estimate never reaches the user: a step's cost counts its priced reagents only and says which are not.
-- Left out: recipes the user's settings drop, and a recipe the character level does not allow yet.
local function fallbackOpts(ctx)
	local list = {}
	local function add(o, rank)
		local known, units = 0, 0
		for i, n in pairs(o.mats) do
			local b = buyOf(ctx, i)
			if b then
				known = known + n * b
			else
				units = units + n
			end
		end
		list[#list + 1] = { o = o, rank = rank, unknown = o.missing and #o.missing or 0, known = known, units = units }
	end
	for _, o in ipairs(ctx.options) do
		-- with recipe buys off, a recipe item to buy stays out here as well
		if o.missing and not (ctx.noRecipeBuys and o.src == "item" and o.recipePrice) then
			add(o, 1)
		end
	end
	for _, o in ipairs(ctx.hidden) do
		-- recipe buys off means known and trainer recipes only: no recipe item, quest or special teacher either
		if not o.tooLow and not (ctx.noRecipeBuys and o.src ~= "trainer") then
			add(o, ((o.unchecked or o.noPrice) and 2 or 4) + (o.missing and 1 or 0))
		end
	end
	return list
end

-- The best fallback at skill s among those of rank <= maxRank (nil: any). Returns o, its estimated cost per point
-- (unpriced reagents at ctx.unknownEach), points per craft, the cost per point of its priced reagents alone, its rank;
-- nil when none gives skill. only: the guide's spells at s (rule 4): nothing else is looked at.
local function fallbackAt(ctx, list, s, chance, maxRank, only)
	local best, bc, bp, bk
	for _, f in ipairs(list) do
		local o = f.o
		local fits = s >= o.at and (not maxRank or f.rank <= maxRank) and usableAt(ctx, o, s)
		if only then
			fits = fits and only[o.spell] ~= nil
		end
		local p = fits and chance(s, o.y, o.g) * o.k or 0
		if p > 0 then
			local back, effort = backOf(o, 0), ctx.effort * (1 + o.precrafts)
			local net = f.known + f.units * ctx.unknownEach - back
			local c = ((net > 0 and net or 0) + effort) / p
			local wins
			if not best then
				wins = true
			elseif f.rank ~= best.rank then
				wins = f.rank < best.rank
			elseif math.abs(c - bc) > 1e-9 then
				wins = c < bc
			elseif f.unknown ~= best.unknown then
				wins = f.unknown < best.unknown
			elseif o.spell ~= best.o.spell then
				wins = o.spell < best.o.spell
			else
				wins = o.variant < best.o.variant
			end
			if wins then
				local knownNet = f.known - back
				best, bc, bp, bk = f, c, p, ((knownNet > 0 and knownNet or 0) + effort) / p
			end
		end
	end
	if not best then
		return nil
	end
	return best.o, bc, bp, bk, best.rank
end

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
					local kind = guideKind(ctx, s, a.spell)
					-- a level the user's swap picked is never smoothed away, nor a guide level off the guide (rule 4)
					if not c or levels[s].picked or not usableAt(ctx, a, s) or (levels[s].guide and not kind) then
						repl = nil
						break
					end
					cum = cum + 1 / p
					repl[s] = { o = a, c = c, p = p, costs = levels[s].costs }
					if kind then
						repl[s].guide, repl[s].guideAlt = true, kind == "alt" or nil
					else
						repl[s].offGuide = levels[s].offGuide
					end
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
	local fallbacks
	for s = ctx.skill, ctx.cap - 1 do
		-- rule 4: on a skill the guide covers, the best of the guide's options (gb) wins whenever one gives skill
		local g = ctx.guide and ctx.guide[s]
		local best, bc, bp, bnet
		local gb, gc, gp, gnet
		local costs = {}
		for _, o in ipairs(opts) do
			local c, p, net = costPt(ctx, o, s, cum[o], nil, chance)
			if c then
				if not costs[o.spell] or c < costs[o.spell] then
					costs[o.spell] = c
				end
				if usableAt(ctx, o, s) and better(c, p, net, bc, bp, bnet) then
					best, bc, bp, bnet = o, c, p, net
				end
				if g and g[o.spell] and better(c, p, net, gc, gp, gnet) then
					gb, gc, gp, gnet = o, c, p, net
				end
			end
		end
		for _, o in ipairs(ctx.hidden or {}) do
			local c = costPt(ctx, o, s, 0, nil, chance)
			if c and (not costs[o.spell] or c < costs[o.spell]) then
				costs[o.spell] = c
			end
		end
		fallbacks = fallbacks or fallbackOpts(ctx)
		-- a guide option without a price for a reagent keeps the level on the guide (the fallback, guide spells only)
		local gfo, gfc, gfp, gfk, gfrank
		if g then
			gfo, gfc, gfp, gfk, gfrank = fallbackAt(ctx, fallbacks, s, chance, gb and 1 or nil, g)
		end
		local onGuide = gb ~= nil or gfo ~= nil
		if gb then
			best, bc, bp = gb, gc, gp
		end
		local so, sc, sp = nil, nil, nil
		if best and (gb or not onGuide) then
			so, sc, sp = swapAt(ctx, opts, best, s, cum, chance)
		end
		-- the fallback (above): against a priced recipe only a sure one with an unpriced reagent, at its estimate;
		-- with nothing priced, any. level.fallback = "unpriced" (c is the estimate, known the priced part) or "gated".
		local fo, fc, fp, fk, frank
		if onGuide then
			fo, fc, fp, fk, frank = gfo, gfc, gfp, gfk, gfrank
		elseif not (so and so.spell ~= best.spell) then
			fo, fc, fp, fk, frank = fallbackAt(ctx, fallbacks, s, chance, best and 1 or nil)
		end
		if so and so.spell ~= best.spell then
			cum[so] = (cum[so] or 0) + 1 / sp
			levels[s] = { o = so, c = sc, p = sp, costs = costs, picked = true, swapFrom = best.spell }
		elseif best and (not onGuide or gb) and not (fo and fc < bc - 1e-9) then
			cum[best] = (cum[best] or 0) + 1 / bp
			levels[s] = { o = best, c = bc, p = bp, costs = costs }
		elseif fo then
			local kind = frank == 1 and "unpriced" or "gated"
			levels[s] = { o = fo, c = fc, p = fp, known = fk, costs = costs, fallback = kind }
		else
			levels[s] = false
		end
		local lv = levels[s]
		if lv and ctx.guide then
			local kind = guideKind(ctx, s, lv.o.spell)
			if kind then
				lv.guide, lv.guideAlt = true, kind == "alt" or nil
			elseif lv.picked then
				lv.offGuide = "you chose this recipe instead"
			else
				lv.offGuide = offGuideWhy(ctx, s)
			end
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
		elseif not o.recipePrice then
			-- here only because the user said "Use it" (exclude.allow): they can get the recipe, at a price nobody
			-- knows. The plan says where it comes from (a "get the recipe" step) and counts no price for it.
			opts[#opts + 1] = o
		elseif not ctx.noRecipeBuys then
			cands[#cands + 1] = o
		end
	end
	-- a recipe item the user swapped to ("Use this") is bought whatever it saves
	local buys, bought = {}, {}
	local swapTo = {}
	for _, to in pairs(ctx.exclude and ctx.exclude.swap or {}) do
		swapTo[to] = true
	end
	-- and so is one the guide names (rule 4): bought when a guide level uses it, whatever it saves
	for _, c in ipairs(cands) do
		local guided = ctx.guideSpell and ctx.guideSpell[c.spell]
		if swapTo[c.spell] or guided then
			opts[#opts + 1] = c
			if not bought[c.spell] then
				bought[c.spell] = true
				buys[#buys + 1] = {
					spell = c.spell,
					item = c.recipeItem,
					price = c.recipePrice,
					learn = c.at,
					swap = swapTo[c.spell] or nil,
					guide = (guided and not swapTo[c.spell]) or nil,
				}
				buys[#buys].where, buys[#buys].vendor = c.recipeWhere, c.recipeVendor
			end
		end
	end
	local levels = forward(ctx, opts, chance)
	-- at most MAX_RECIPE_BUYS recipes bought to save money; one that fills a level no sure recipe covers (a gap, or
	-- a gated fallback) is bought beyond that count: a priced recipe item goes before a gated recipe
	local nBuys = 0
	while true do
		local best, bestSave
		for _, c in ipairs(cands) do
			if not bought[c.spell] and c.matBuy then
				local save, cum = -c.recipePrice, 0
				for s = ctx.skill, ctx.cap - 1 do
					local cost, p = costPt(ctx, c, s, cum, nil, chance)
					local v = (levels[s] and levels[s].fallback ~= "gated") and levels[s].c or HUGE
					-- a guide level takes only the guide's recipes (rule 4): no saving there
					if levels[s] and levels[s].guide and not guideKind(ctx, s, c.spell) then
						cost = nil
					end
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
		if not best or (nBuys >= P.MAX_RECIPE_BUYS and bestSave < HUGE / 2) then
			break
		end
		nBuys = nBuys + 1
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
			where = best.recipeWhere,
			vendor = best.recipeVendor,
			learn = best.at,
			saves = not fillsGap and bestSave or nil,
			fillsGap = fillsGap or nil,
			instead = (not fillsGap and instead) and instead.spell or nil,
			insteadName = (not fillsGap and instead) and instead.name or nil,
		}
	end
	-- a swap's or the guide's recipe buy stands only when it took a level (a stale or costless swap buys nothing)
	local used = {}
	for s = ctx.skill, ctx.cap - 1 do
		local lv = levels[s]
		if lv then
			used[lv.o.spell] = true
			-- a fallback level on a recipe item that has a price (its reagents lack one): the recipe is bought
			if lv.fallback and lv.o.src == "item" and lv.o.recipePrice and not bought[lv.o.spell] then
				bought[lv.o.spell] = true
				buys[#buys + 1] = {
					spell = lv.o.spell,
					item = lv.o.recipeItem,
					price = lv.o.recipePrice,
					where = lv.o.recipeWhere,
					vendor = lv.o.recipeVendor,
					learn = lv.o.at,
					fillsGap = true,
				}
			end
		end
	end
	local kept = {}
	for _, b in ipairs(buys) do
		if not (b.swap or b.guide) or used[b.spell] then
			kept[#kept + 1] = b
		end
	end
	return { levels = levels, opts = opts, buys = kept, chance = chance }
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
	-- stock-only variants follow the plain rule above (no recipe to buy), except that the variant of a recipe sold as
	-- an item (src "item") counts when the baseline buys that recipe anyway
	local inBase = {}
	for _, o in ipairs(base.opts) do
		inBase[o.spell] = true
	end
	for _, list in ipairs({ ctx.options, ctx.stockOnly or {} }) do
		for _, o in ipairs(list) do
			if not seen[o] and (o.src ~= "item" or (o.stockOnly and inBase[o.spell])) then
				usable[#usable + 1] = o
			end
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
		-- a stock-only variant pays for its pre-craft only when the bags hold a non-vendor raw it crafts from: owned
		-- Medium Leather alone must not turn "use the 15 Cured Medium Hide in the bags" into "buy hides and cure them"
		if ok and mine and o.stockOnly then
			local own = false
			for i in pairs(o.raws or {}) do
				own = own or (mine[i] and not isVendor(ctx, i))
			end
			ok = own
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
					-- rule 4: stock may change which of the guide's recipes a guide level uses, never leave the guide
					local c = numer / p
					-- a gated fallback level counts as uncovered: owned stock of a sure recipe takes it. Rule 4: stock
					-- may change which of the guide's recipes a guide level uses, never take the level off the guide.
					local gain = ((lv and lv.fallback ~= "gated") and lv.c or HUGE) - c + P.BIAS
					if gain > 0 and stockMay(ctx, lv, o, s) then
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
			-- k: the cost per point the step shows (a fallback level's estimate stays inside the planner)
			list[#list + 1] = lv and { o = lv.o, f = lf, c = lv.c, k = lv.known, p = lv.p, s = s }
				or { gap = true, f = lf, s = s }
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
				local a =
					{ o = o, f = part.f * sf, c = part.c, k = part.k, p = part.p, s = part.s, source = stockLabel }
				local b =
					{ o = o, f = part.f * (1 - sf), c = part.c, k = part.k, p = part.p, s = part.s, source = "buy" }
				out[#out + 1] = a
				consume(o, a.f / a.p)
				out[#out + 1] = b
				consume(o, b.f / b.p)
			end
		end
	end
	return out
end

local function preKinds(o)
	local n = 0
	for _ in pairs(o.pre or {}) do
		n = n + 1
	end
	return n
end

local function segmentsOf(parts)
	local segs = {}
	for _, part in ipairs(parts) do
		local last = segs[#segs]
		-- one recipe over one contiguous range is one step: stock against buy is a materials line, not a boundary, and
		-- so is the variant (cure the owned hides, then buy cured ones): the step's supply pass decides per reagent
		if last and ((part.gap and last.gap) or (not part.gap and not last.gap and last.o.spell == part.o.spell)) then
			-- the variant that crafts the most intermediates speaks for the step: it crafts what the bags allow
			if part.o ~= last.o and preKinds(part.o) > preKinds(last.o) then
				last.o = part.o
			end
			if part.source == "buy" or last.source == "buy" then
				last.source = "buy"
			elseif part.source ~= last.source then
				last.source = "mixed"
			end
			last.to = part.s + 1
			last.alloc = last.alloc + (part.gap and 0 or part.f / part.p)
			last.pts = last.pts + part.f
			last.cost = last.cost + (part.k or part.c or 0) * part.f
		else
			segs[#segs + 1] = {
				o = part.o,
				gap = part.gap,
				source = part.source,
				from = part.s,
				to = part.s + 1,
				alloc = part.gap and 0 or part.f / part.p,
				pts = part.f,
				cost = (part.k or part.c or 0) * part.f,
			}
		end
	end
	return segs
end

-- What `crafts` crafts of o take, reagent by reagent: the bags first (pool, drawn down), then for an intermediate the
-- variant crafts (o.pre) the craft, then the auction house or vendor. A stock-only variant crafts only as many as its
-- owned non-vendor raws allow (15 Medium Hide: 15 cures, Salt bought) and buys the rest of the intermediate ready-
-- made, as at buy prices that is the cheaper route. A variant that buys the intermediate cures from spare raws too
-- (spare: the stock pass's rem, drawn down here). Returns uses, buys and made: item -> units.
local function supplyOf(ctx, o, crafts, pool, spare)
	local uses, buys, made = {}, {}, {}
	local function supply(i, need, depth)
		local use = math.min(math.max(pool[i] or 0, 0), need)
		if use > 0 then
			pool[i] = pool[i] - use
			uses[i] = (uses[i] or 0) + use
		end
		local short = need - use
		if short <= EPS then
			return
		end
		local mk = ctx.makers[i]
		-- a variant that buys the intermediate still cures from owned raws first (a committed step keeps the plain
		-- variant, and its "buy 7 Cured Medium Hide" must not stand while 10 Medium Hide sit in the bags)
		-- Only true spares (spare: what no step of the plan counts on, rule 2) feed this.
		local ownedRaw = false
		if mk and not o.pre[i] and depth == 0 and spare then
			for r in pairs(mk.mats) do
				local own = math.min(pool[r] or 0, spare[r] or 0)
				ownedRaw = ownedRaw or (not isVendor(ctx, r) and own >= mk.mats[r] - EPS)
			end
		end
		if mk and (o.pre[i] or ownedRaw) and depth < 3 then
			local c = short
			if o.stockOnly or not o.pre[i] then
				for _, r in ipairs(sortedKeys(mk.mats)) do
					if not isVendor(ctx, r) then
						local own = math.max(pool[r] or 0, 0)
						if not o.pre[i] then
							own = math.min(own, spare[r] or 0)
						end
						c = math.min(c, math.floor(own / mk.mats[r] + EPS) * mk.n)
					end
				end
			end
			if c > EPS and not o.pre[i] then
				local casts = math.ceil(c / mk.n - EPS)
				for r, q in pairs(mk.mats) do
					if spare[r] then
						spare[r] = math.max(0, spare[r] - casts * q)
					end
				end
			end
			if c > EPS then
				made[i] = (made[i] or 0) + c
				local casts = math.ceil(c / mk.n - EPS)
				for _, r in ipairs(sortedKeys(mk.mats)) do
					supply(r, casts * mk.mats[r], depth + 1)
				end
				short = math.max(0, short - c)
			end
		end
		if short > EPS then
			buys[i] = (buys[i] or 0) + short
		end
	end
	local plain = o.plain or o.mats
	for _, i in ipairs(sortedKeys(plain)) do
		supply(i, plain[i] * crafts, 0)
	end
	return uses, buys, made
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

-- The cheapest learned option craftable now from stock plus vendor reagents, other than `skip`. lv: the level at s;
-- on a guide level only the guide's recipes are an alternative (rule 4).
local function stockAlternative(ctx, s, pool, skip, st, have, chance, lv)
	local best, bc, bcrafts, bp
	for _, o in ipairs(ctx.options) do
		if o.learned and o.spell ~= skip and o.variant == 1 and stockMay(ctx, lv, o, s) then
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
					if ctx.guide then
						local kind = guideKind(ctx, s, pick.spell)
						levels[s].guide, levels[s].guideAlt = kind and true or nil, kind == "alt" or nil
						levels[s].offGuide = not kind and "a step on your AH list holds its recipe" or nil
					end
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
	local needs, why
	if o.src == "special" then
		needs = o.teacher or "a special teacher"
	elseif o.unchecked then
		needs = "no trainer you opened teaches it"
	elseif o.tooLow then
		why = ("needs character level %d"):format(o.level)
	elseif o.src == "unlisted" then
		why = "not confirmed obtainable in Forever"
	elseif o.bop then
		-- a recipe item that binds when picked up: never an auction buy; the data may say where it comes from
		local from = fromText(o)
		why = "its recipe binds when picked up" .. (from and (": " .. from) or "")
	elseif o.noPrice then
		why = "no auction price today" .. (o.vendorWhy and ("; " .. o.vendorWhy) or "")
	end
	return { spell = o.spell, name = o.name, saves = saves, src = o.src, needs = needs, why = why, bop = o.bop }
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
	-- a gated recipe need not cover the whole step: learnable part-way through, it is compared from its learn skill
	-- on (the step's own recipe stays before that). part[spell] = { x = what it changes, from = its first level }.
	local part = {}
	for s = lo, hi do
		local lv = base.levels[s]
		if not lv or not lv.costs then
			return nil
		end
		local f = math.max(0, math.min(step.to, s + 1) - math.max(step.from, s))
		local now = {}
		for spell, c in pairs(lv.costs) do
			local g = info[spell]
			if g and g.gated and spell ~= step.spell and c < lv.c then
				part[spell] = part[spell] or { x = 0, from = s }
				part[spell].x = part[spell].x + f * (c - lv.c)
			end
			-- an alternative covers the whole step: a spell missing at any level drops out. The spell a swap replaced
			-- is not an alternative: the step offers "Back to" it (step.swapFrom).
			if spell ~= step.spell and spell ~= step.swapFrom and (not extra or extra[spell]) then
				now[spell] = (extra and extra[spell] or 0) + f * (c - lv.c)
			end
		end
		extra = now
	end
	local out, cuts = {}, {}
	for spell, pt in pairs(part) do
		if pt.x < -P.SHORTCUT_MIN then
			-- a gated recipe that would make this step, or the rest of it, cheaper: a shortcut, with what it saves
			local cut = shortcutOf(info[spell], -pt.x)
			cut.from = pt.from > lo and pt.from or nil
			cuts[#cuts + 1] = cut
		end
	end
	for spell, x in pairs(extra or {}) do
		local o = info[spell]
		if o and o.gated and part[spell] and part[spell].x < -P.SHORTCUT_MIN then
			-- offered as a shortcut above
			x = nil
		end
		if x then
			out[#out + 1] = {
				spell = spell,
				name = o and o.name,
				extra = math.max(0, x),
				src = o and o.src,
				teacher = o and o.teacher,
				unchecked = o and o.unchecked,
				-- gated: shown, never switched to ("Use it" on a shortcut is the way in)
				gated = o and o.gated,
				-- one of the guide's recipes at the step's first skill (rule 4)
				guide = guideKind(ctx, lo, spell) and true or nil,
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

-- Why a stretch nothing covers is a hole: reason, why (text). A missing price or a gated recipe is never a reason (the
-- fallback of `forward` plans those):
--   "norecipe"    no obtainable recipe gives skill there (the true hole);
--   "recipesOff"  only recipes to buy or get elsewhere do, and that is off (input.noRecipeBuys);
--   "excluded"    only recipes the user's settings drop do (not now, AH patterns, dungeon patterns);
--   "level"       only recipes learned at a higher character level do.
local GAP_WHY = {
	norecipe = "no recipe gives skill here",
	recipesOff = "only a recipe to buy or get elsewhere gives skill here, and that is turned off",
	excluded = "only recipes you turned off give skill here",
	level = "the recipes here need a higher character level",
}
local function gapReason(ctx, from, to)
	local lo, hi = math.floor(from), math.max(math.floor(from), math.ceil(to - EPS) - 1)
	local function covers(at, g)
		return at <= hi and g > lo
	end
	local reason = "norecipe"
	for _, list in ipairs(ctx.noRecipeBuys and { ctx.options, ctx.hidden } or {}) do
		for _, o in ipairs(list) do
			if not o.learned and o.src ~= "trainer" and o.src ~= "auto" and not o.tooLow and covers(o.at, o.g) then
				reason = "recipesOff"
			end
		end
	end
	if reason == "norecipe" then
		for _, x in ipairs(ctx.excludedOut or {}) do
			if covers(x.at, x.g) then
				reason = "excluded"
			end
		end
	end
	if reason == "norecipe" then
		for _, o in ipairs(ctx.hidden or {}) do
			if o.tooLow and covers(o.at, o.g) then
				reason = "level"
			end
		end
	end
	return reason, GAP_WHY[reason]
end

-- [from, to) cut by ctx.world (input.world = { { from, to, text, spot, why } }: stretches a world skill levels on its
-- nodes, from Where's route): pieces { from, to, world = stretch | nil } in order, covering [from, to) edge to edge.
local function worldSplit(ctx, from, to)
	local out, at = {}, from
	for _, w in ipairs(ctx.world) do
		local a, b = math.max(at, w.from), math.min(to, w.to)
		if b > a then
			if a > at then
				out[#out + 1] = { from = at, to = a }
			end
			out[#out + 1] = { from = a, to = b, world = w }
			at = b
		end
	end
	if at < to then
		out[#out + 1] = { from = at, to = to }
	end
	return out
end

-- Why a gated option is gated, as one word (step.gated on a craft step the fallback planned).
local function gateOf(o)
	if not o.gated then
		return nil
	elseif o.unchecked then
		return "unchecked"
	elseif o.src == "special" then
		return "special"
	elseif o.src == "unlisted" then
		return "unlisted"
	elseif o.bop then
		return "bop"
	elseif o.noPrice then
		return "noPrice"
	end
	return o.tooLow and "level" or "gated"
end

-- Rank training in the step list. Per rank-up (window [at, by]; at unknown = by): at or past by, train first. Else
-- it goes where its cap is reached: immediately before the first step that ends past `by` (before that step's own
-- "train" or "buy recipe" step, which stays next to its craft). When that step starts before the rank can be trained
-- (it straddles the whole window) it is never split: the step carries step.rankUp ("train between at and by").
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
				-- the character's level when the plan was made (nil: not known)
				have = type(ctx.level) == "number" and ctx.level or nil,
				cost = up.cost,
				where = up.where,
				skill = skill,
			}
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
				if st.from and st.to and st.to > hi + EPS then
					if st.from < lo - EPS then
						st.rankUp = up
					else
						local j = i
						while
							j > 1
							and (steps[j - 1].kind == "train" or steps[j - 1].kind == "buyRecipe")
							and steps[j - 1].spell == st.spell
						do
							j = j - 1
						end
						table.insert(steps, j, rankStep(st.from))
					end
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
-- own: the units on this character (bags and bank); have also counts the alts' (P.finish), which steps may use but
-- which are no leftover to sell here and no craft to make now.
local function finishCore(ctx, baseline, have, commits, own)
	have = have or {}
	own = own or have
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
	-- raws no step counts on (the stock pass's rem): a step that buys an intermediate cures from these first
	local spareRaw = {}
	for i, q in pairs(st.rem) do
		spareRaw[i] = q
	end
	local cur = ctx.skill
	local steps = plan.steps
	for idx, seg in ipairs(segs) do
		if cur >= ctx.cap then
			break
		end
		if seg.gap then
			-- a stretch the world gives skill on (Mining's nodes, input.world) is a world step, never a hole
			for _, piece in ipairs(worldSplit(ctx, seg.from, seg.to)) do
				if piece.world then
					local w = piece.world
					steps[#steps + 1] = {
						kind = "world",
						from = piece.from,
						to = piece.to,
						name = w.text or "Gather in the world",
						spot = w.spot,
						why = w.why or "from gathering nodes",
					}
				else
					local reason, why = gapReason(ctx, piece.from, piece.to)
					steps[#steps + 1] = { kind = "gap", from = piece.from, to = piece.to, reason = reason, why = why }
				end
			end
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
					-- "vendor": the data names a vendor that sells it for less than the auction house
					where = b.where or "ah",
					vendor = b.vendor,
					learn = b.learn,
					owned = (own[b.item] or 0) > 0 or nil, -- in the bags already: learn it, no AH
					saves = b.saves,
					fillsGap = b.fillsGap,
					alt = b.instead and { spell = b.instead, name = b.insteadName, extra = b.saves } or nil,
				}
			elseif o.train and not announced[o.spell] then
				announced[o.spell] = true
				steps[#steps + 1] = {
					kind = "train",
					spell = o.spell,
					name = o.name,
					at = o.at,
					unchecked = o.unchecked,
					cost = o.trainCost,
				}
			end
			local crafts
			if not o.learned and o.src ~= "auto" and o.src ~= "known" and not announced[o.spell] then
				-- a recipe the user said they can get ("Use it") that the plan cannot buy: say where it comes from, and
				-- that its price is not known (never counted as free)
				announced[o.spell] = true
				local from
				if o.src == "special" then
					from = o.teacher or "a special teacher"
				elseif o.src == "unlisted" then
					from = "not confirmed obtainable in Forever"
				else
					from = fromText(o) or (o.bop and "binds when picked up, source not known") or nil
					if not o.bop then
						from = (from and (from .. "; ") or "") .. "auction house, no price today"
					end
				end
				steps[#steps + 1] = {
					kind = "buyRecipe",
					spell = o.spell,
					name = o.name,
					item = o.recipeItem,
					where = "source",
					source = from,
					priceUnknown = true,
					learn = o.at,
					owned = (o.recipeItem and (own[o.recipeItem] or 0) > 0) or nil,
				}
			end
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
				-- planned although gated, because nothing sure gives skill here: "unchecked" (trainer recipe no
				-- trainer listed), "noPrice" (recipe item with no auction price), "bop", "unlisted", "special"
				gated = gateOf(o),
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
			-- rule 4: on the guide when the guide names the recipe at every skill of the stretch (guideAlt: as one of
			-- its alternatives); else offGuide says why, from the first level off it
			if ctx.guide then
				local on, alt, why = true, false, nil
				local glo = math.max(math.floor(from), seg.from)
				for s = glo, math.min(math.max(glo, seg.to - 1), ctx.cap - 1) do
					local kind = guideKind(ctx, s, o.spell)
					if not kind then
						local lv = base.levels[s]
						on, why = false, why or (lv and lv.offGuide) or "the guide uses another recipe here"
					elseif kind == "alt" then
						alt = true
					end
				end
				step.guide, step.guideAlt, step.offGuide = on or nil, (on and alt) or nil, why
			end
			local out, export = 0, o.prodExport == true
			local poolBefore = {}
			for i, q in pairs(pool) do
				poolBefore[i] = q
			end
			local uses, buys, made = supplyOf(ctx, o, crafts, pool, spareRaw)
			for _, i in ipairs(sortedKeys(uses)) do
				step.used[#step.used + 1] = { item = i, count = math.floor(uses[i] + EPS) }
			end
			for _, i in ipairs(sortedKeys(buys)) do
				local count = math.ceil(buys[i] - EPS)
				if count > 0 then
					local pr = ctx.price[i] or {}
					-- TSM.prices leaves buy = false (not nil) for an item TradeSkillMaster has no price for
					step.buy[#step.buy + 1] = { item = i, count = count, where = pr.where, each = pr.buy or nil }
					if not pr.buy then
						-- no price: bought all the same, the step's cost is "at least" (cash.out leaves it out)
						step.buy[#step.buy].unpriced = true
						step.unpriced = step.unpriced or {}
						local info = ctx.items[i]
						step.unpriced[#step.unpriced + 1] =
							{ item = i, name = info and info.name or nil, count = count }
					end
					out = out + count * (pr.buy or 0)
					if pr.export then
						export = true
					end
				end
			end
			for _, i in ipairs(sortedKeys(made)) do
				local make = math.ceil(made[i] - EPS)
				if make > 0 then
					step.pre[#step.pre + 1] = {
						item = i,
						-- count: what the step takes of it from the bags, the units crafted now included (the card's
						-- button crafts count minus the bags); make: the units crafted, at plan time
						count = math.floor((uses[i] or 0) + EPS) + make,
						make = make,
						spell = ctx.makers[i] and ctx.makers[i].spell,
						n = ctx.makers[i] and ctx.makers[i].n,
					}
				end
			end
			local soldHere = 0
			if sells(o) then
				soldHere = math.max(0, math.min(crafts, o.takes - (sold[o.spell] or 0)))
				sold[o.spell] = (sold[o.spell] or 0) + soldHere
			end
			if o.noResale then
				-- resale off: nothing comes back; what selling would bring is a note on the card, never a credit
				step.cash = { out = out, back = 0 }
				local each = resaleOf(o, 0)
				if each > 0 and crafts > 0 then
					local n = wouldSell(o) and math.min(crafts, o.takes) or crafts
					step.resale = {
						back = n * each + (crafts - n) * o.vendor,
						crafts = crafts,
						ah = wouldSell(o) and n or 0,
					}
				end
			else
				step.cash = { out = out, back = soldHere * (o.sell or 0) + (crafts - soldHere) * o.vendor }
			end
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
			local lv0 = base.levels[lo]
			local alt, ac, acrafts = stockAlternative(ctx, lo, avail, step.spell, st, have, chance, lv0)
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
		-- steps take this character's units first, so what is left here is the pool less the alts' share
		local q = math.floor(math.min(pool[i], own[i] or 0) + EPS)
		if
			q >= 1
			and (own[i] or 0) > 0
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
					crafts = math.min(crafts, math.floor((own[i] or 0) / n + EPS))
					spare = math.min(spare, math.floor(math.max(0, math.min(pool[i] or 0, own[i] or 0)) / n + EPS))
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
	-- what the plan buys at a price nobody knows: reagents (step.unpriced) and recipes to get (a buyRecipe step with
	-- priceUnknown). plan.unpriced = { count = kinds, items = { { item, name, count, recipe = true | nil } } }, by item.
	local unpriced, unpricedBy, planned = { count = 0, items = {} }, {}, {}
	local function addUnpriced(key, item, name, count, recipe)
		local e = unpricedBy[key]
		if not e then
			e = { item = item, name = name, count = 0, recipe = recipe }
			unpricedBy[key] = e
			unpriced.items[#unpriced.items + 1] = e
		end
		e.count = e.count + count
	end
	for _, step in ipairs(steps) do
		if step.kind == "craft" then
			planned[step.spell] = true
			for _, u in ipairs(step.unpriced or {}) do
				addUnpriced(u.item, u.item, u.name, u.count)
			end
		elseif step.kind == "buyRecipe" and step.priceUnknown and not step.owned then
			local info = step.item and ctx.items[step.item]
			addUnpriced(
				"r" .. step.spell,
				step.item,
				info and info.name or ("Recipe: " .. tostring(step.name)),
				1,
				true
			)
		end
	end
	table.sort(unpriced.items, function(a, b)
		if (a.recipe == true) ~= (b.recipe == true) then
			return b.recipe == true
		end
		return (a.item or 0) < (b.item or 0)
	end)
	unpriced.count = #unpriced.items
	plan.unpriced = unpriced
	-- options that cannot be priced, are not owned and are not in the plan (U5)
	local seenSpell = {}
	for _, o in ipairs(ctx.options) do
		if o.variant == 1 and o.missing and not seenSpell[o.spell] and not planned[o.spell] then
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
	-- rule 4 in numbers: craft steps on the guide and off it, and the last reason off it (the selftest's route)
	if ctx.guide then
		local g = { steps = 0, onGuide = 0, offGuide = 0 }
		for _, step in ipairs(steps) do
			if step.kind == "craft" then
				g.steps = g.steps + 1
				if step.guide then
					g.onGuide = g.onGuide + 1
				else
					g.offGuide = g.offGuide + 1
					g.lastOffGuide = ("%d: %s"):format(math.floor(step.from), tostring(step.offGuide))
				end
			end
		end
		plan.guide = g
	end
	plan.liveCap = ctx.liveCap
	plan.rankUps = ctx.rankUps
	plan.capBlock = ctx.capBlock
	plan.coverage = ctx.coverage
	return plan
end

-- An item with no price at all is an auction buy too (price unknown): never dropped from the lists.
local function isAh(ctx, item)
	local pr = ctx.price[item]
	return pr == nil or pr.where ~= "vendor"
end

-- Whether a step sends the user to the AH: a recipe to buy there, or a reagent it buys there.
local function needsAh(ctx, st)
	if st.kind == "buyRecipe" then
		return not st.owned and st.where == "ah"
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
		if st.kind == "train" or st.kind == "trainRank" or st.kind == "gap" or st.kind == "world" then
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
			-- unpriced: no price for it (each = 0 keeps the sums; the total is then "at least")
			r = { item = item, count = 0, buffer = 0, each = each or 0, unpriced = each == nil or nil }
			byItem[item] = r
			rows[#rows + 1] = r
		end
		r[field] = r[field] + count
		total = total + count * (each or 0)
	end
	for i = first, #steps do
		local st = steps[i]
		if st.kind == "train" or st.kind == "trainRank" or st.kind == "gap" or st.kind == "world" then
			ends = st.kind
			break
		end
		local cost = 0
		if st.kind == "buyRecipe" then
			cost = (st.owned or st.where ~= "ah") and 0 or (st.price or 0)
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
			if not st.owned and st.where == "ah" then
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
		if st.kind == "train" or st.kind == "trainRank" or st.kind == "gap" or st.kind == "world" then
			break
		elseif st.kind == "buyRecipe" then
			if not st.owned and st.where == "vendor" then
				local merchant = st.vendor and st.vendor.name
				add(shop.vendor, vendorBy, st.item, 1, st.price, { merchant = merchant, kind = "pattern" }, j)
			elseif not st.owned and st.where == "ah" then
				add(shop.ah, ahBy, st.item, 1, st.price, { kind = "pattern" }, j)
			end
		elseif st.kind == "craft" then
			for _, b in ipairs(st.buy) do
				if isVendor(ctx, b.item) then
					local pr = ctx.price[b.item] or {}
					local info = ctx.items[b.item] or {}
					add(shop.vendor, vendorBy, b.item, b.count, b.each, { merchant = pr.merchant or info.merchant }, j)
				elseif isAh(ctx, b.item) then
					add(shop.ah, ahBy, b.item, b.count, b.each, { kind = "reagent", unpriced = b.unpriced }, j)
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

-- Which of the units each craft step uses must come from an alt: steps take this character's units first, in plan
-- order, then each alt's, the largest holder first. Sets u.mail = { { who, count } } on the step's used rows and
-- returns plan.mail = { { who, item, count } } (who, item order). alts: Alts.stock's shape.
function P.mailFrom(steps, own, alts)
	local left, from = {}, {}
	for i, q in pairs(own or {}) do
		left[i] = q
	end
	for i, list in pairs(alts or {}) do
		from[i] = {}
		for k, a in ipairs(list) do
			from[i][k] = { who = a.who, n = a.n }
		end
	end
	local total = {}
	for _, step in ipairs(steps) do
		for _, u in ipairs(step.kind == "craft" and step.used or {}) do
			local need = u.count - math.min(left[u.item] or 0, u.count)
			left[u.item] = math.max(0, (left[u.item] or 0) - u.count)
			for _, a in ipairs(need > 0 and from[u.item] or {}) do
				local take = math.min(a.n, need)
				if take > 0 then
					a.n, need = a.n - take, need - take
					u.mail = u.mail or {}
					u.mail[#u.mail + 1] = { who = a.who, count = take }
					local key = a.who .. "\0" .. u.item
					total[key] = total[key] or { who = a.who, item = u.item, count = 0 }
					total[key].count = total[key].count + take
				end
			end
		end
	end
	local out = {}
	for _, m in pairs(total) do
		out[#out + 1] = m
	end
	table.sort(out, function(a, b)
		if a.who ~= b.who then
			return a.who < b.who
		end
		return a.item < b.item
	end)
	return out
end

-- Pass 2 to 4, then the AH trip and the shopping list. opts: commit (the steps of the saved trip, { { spell, to } }:
-- rule 3), gold (copper on hand: the trip stops where it runs out), alts (the alts' units, Alts.stock's shape
-- { [item] = { { who, n } } }: the plan counts them as stock and names what to mail in plan.mail).
function P.finish(ctx, baseline, have, opts)
	opts = opts or {}
	have = have or {}
	local all = have
	if opts.alts and next(opts.alts) then
		all = {}
		for i, q in pairs(have) do
			all[i] = q
		end
		for i, list in pairs(opts.alts) do
			for _, a in ipairs(list) do
				all[i] = (all[i] or 0) + a.n
			end
		end
	end
	local plan = finishCore(ctx, baseline, all, opts.commit, have)
	plan.mail = P.mailFrom(plan.steps, have, opts.alts)
	plan.have = have -- this character's counts the plan was built on (the Shopping tab's covered rows)
	plan.luck = ctx.z
	plan.trip = tripOf(ctx, plan.steps, baseline.formula.chance, opts.gold)
	plan.shopping = P.shoppingOf(ctx, plan.steps, plan.trip)
	return plan
end

-- What a plan pays trainers: { total, recipes = n, ranks = n, unknown = n } (copper; unknown = trainer recipes and
-- ranks whose price the data does not have). Trainer recipes are the plan's train steps; ranks are plan.rankUps (a
-- rank trained inside one long step has no step of its own).
function P.trainingOf(plan)
	local t = { total = 0, recipes = 0, ranks = 0, unknown = 0 }
	for _, st in ipairs(plan and plan.steps or {}) do
		if st.kind == "train" then
			t.recipes = t.recipes + 1
			if type(st.cost) == "number" then
				t.total = t.total + st.cost
			else
				t.unknown = t.unknown + 1
			end
		end
	end
	for _, up in ipairs(plan and plan.rankUps or {}) do
		t.ranks = t.ranks + 1
		if type(up.cost) == "number" then
			t.total = t.total + up.cost
		else
			t.unknown = t.unknown + 1
		end
	end
	return t
end

-- What it costs to level a profession entry (Data/Recipes.lua's shape: { recipes, ranks }) from skill `from` to `to`,
-- for any profession, also one the character does not have: the real planner, run with nothing in the bags.
-- priceFn(item) -> copper to buy one, or nil (no price). opts (all optional):
--   vendor = { [item] = copper }, items = { [item] = { sell, ... } } (the data's tables);
--   price, product: ready tables in Planner.prepare's shape (TSM.prices' result) instead of priceFn;
--   learned = { [spell] = true } (default: every `auto` recipe, learned with the profession);
--   ranks (default prof.ranks), cap (the live cap; default: the first rank cap above `from`, and that rank's cost is
--   counted when from <= 1: a profession not learned yet), level, exclude, trainerSeen, effort, luck;
--   recipeItems = false: plan with trainer and auto recipes only; resale = true: selling products counts;
--   world = Planner.prepare's input.world (Mining's node stretches: a world step each, not a gap).
-- Returns { total, spent, back, trainingCost, steps, gaps = { { from, to, why, reason } }, recipesToBuy = { { spell,
-- name, item, price } }, unknownPrices (reagents that have no price), unknownItems, unknownRecipeItems (tradeable
-- recipe items with no price), unpriced (what the plan itself buys at an unknown price: plan.unpriced), reached,
-- complete }; opts.faction and opts.route as Planner.prepare's input.faction and input.route.
-- total = spent - back + recipe items + trainingCost, in copper, buying for the luck percentile (rule 1); with
-- unpriced.count > 0 it is "at least" that. A gap is a stretch no obtainable recipe covers (reason: gapReason's, or
-- "cap" for the stretch past the reachable cap), never a missing price: with complete data there is none.
function P.costToCap(prof, from, to, priceFn, opts)
	opts = opts or {}
	local recipes = type(prof) == "table" and prof.recipes or {}
	local vendor = opts.vendor or {}
	local price = opts.price
	local built = price == nil
	price = price or {}
	local unknown, unknownItems, unknownRecipes = {}, {}, 0
	-- quiet: priced when a price exists, never counted as unknown (a shortcut's reagents: the plan uses them only as a
	-- fallback, and then names them itself in `unpriced`)
	local function need(i, recipeItem, quiet)
		if built and price[i] == nil and not unknown[i] then
			local v = vendor[i]
			if v then
				price[i] = { buy = v, where = "vendor", salvage = 0 }
			else
				local p = priceFn and priceFn(i)
				if type(p) == "number" and p == p then
					price[i] = { buy = p, where = "ah", salvage = 0 }
				end
			end
		end
		if not quiet and not (price[i] and price[i].buy) and not unknown[i] then
			unknown[i] = true
			if recipeItem then
				-- a recipe item nobody sells today: its recipe is a shortcut, not a hole in the reagent prices
				unknownRecipes = unknownRecipes + 1
			else
				unknownItems[#unknownItems + 1] = i
			end
		end
	end
	local learned = opts.learned
	local auto = {}
	-- the guide's spells (opts.route, rule 4): planned like a recipe the user allowed, so priced the same way
	local guided = {}
	for _, e in ipairs(type(opts.route) == "table" and opts.route or {}) do
		if type(e) == "table" and e.spell then
			guided[e.spell] = true
		end
	end
	for spell, r in pairs(recipes) do
		-- only recipes the plan may use by itself: not the unlisted, special or bind-on-pickup shortcuts
		-- (one the user allowed, "Use it", is planned like any other, so its reagents are priced too)
		local allowed = guided[spell] or (opts.exclude and opts.exclude.allow and opts.exclude.allow[spell] == true)
		local shortcut = r.src == "unlisted" or r.src == "special" or (r.src == "item" and r.bop and not r.vendor)
		if not r.gone and (allowed or not shortcut) then
			for k = 1, #(r.mats or {}) - 1, 2 do
				need(r.mats[k])
			end
			if r.src == "item" and r.item and not r.bop then
				need(r.item, true)
			end
		elseif not r.gone then
			for k = 1, #(r.mats or {}) - 1, 2 do
				need(r.mats[k], false, true)
			end
		end
		if r.src == "auto" then
			auto[spell] = true
		end
	end
	table.sort(unknownItems)
	learned = learned or auto
	local ranks = opts.ranks or prof.ranks or {}
	local cap, first = opts.cap, nil
	if not cap then
		for _, rk in ipairs(ranks) do
			if rk.cap and rk.cap > from and (not cap or rk.cap < cap) then
				cap, first = rk.cap, rk
			end
		end
		cap = cap or to
	end
	local plan = P.run({
		skill = from,
		cap = cap,
		target = to,
		level = opts.level,
		ranks = ranks,
		exclude = opts.exclude,
		trainerSeen = opts.trainerSeen,
		faction = opts.faction,
		route = opts.route,
		recipes = recipes,
		items = opts.items or {},
		learned = learned,
		price = price,
		product = opts.product,
		effort = opts.effort,
		luck = opts.luck,
		noRecipeBuys = opts.recipeItems == false,
		resale = opts.resale == true,
		world = opts.world,
		have = {},
	})
	local out = {
		steps = plan.steps,
		gaps = {},
		world = {}, -- stretches levelled on nodes (opts.world): { { from, to, text, why, spot } }, no gold cost
		recipesToBuy = {},
		spent = 0,
		back = 0,
		trainingCost = 0,
		unknownPrices = #unknownItems,
		unknownItems = unknownItems,
		unknownRecipeItems = unknownRecipes,
		unknownRecipePrices = 0,
		-- what the plan itself buys at an unknown price (the plan's own table: count, items)
		unpriced = plan.unpriced,
		reached = plan.cap,
		capBlock = plan.capBlock,
	}
	if first and from <= 1 and type(first.cost) == "number" then
		out.trainingCost = first.cost
	end
	local recipeCost = 0
	for _, st in ipairs(plan.steps) do
		if st.kind == "gap" then
			out.gaps[#out.gaps + 1] = { from = st.from, to = st.to, why = st.why, reason = st.reason }
		elseif st.kind == "world" then
			-- levelled on nodes: no gold cost, no gap
			out.world[#out.world + 1] = { from = st.from, to = st.to, text = st.name, why = st.why, spot = st.spot }
		elseif st.kind == "craft" then
			out.spent = out.spent + (st.cash and st.cash.out or 0)
			out.back = out.back + (st.cash and st.cash.back or 0)
		elseif st.kind == "buyRecipe" then
			recipeCost = recipeCost + (st.price or 0)
			out.recipesToBuy[#out.recipesToBuy + 1] =
				{ spell = st.spell, name = st.name, item = st.item, price = st.price, source = st.source }
			if st.priceUnknown and not st.owned then
				-- a recipe to get at a price nobody knows: said, never counted as free
				out.unknownRecipePrices = out.unknownRecipePrices + 1
			end
		end
	end
	-- trainer recipes and the ranks trained on the way: the same sum the panel shows (P.trainingOf)
	out.trainingCost = out.trainingCost + P.trainingOf(plan).total
	if (plan.cap or from) < to then
		local why = "no rank raises the cap"
		if plan.capBlock then
			why = "the next rank is blocked (" .. tostring(plan.capBlock.reason) .. ")"
		elseif plan.coverage then
			why = "no recipe gives skill past " .. tostring(plan.coverage.to)
		end
		out.gaps[#out.gaps + 1] = { from = plan.cap or from, to = to, why = why, reason = "cap" }
	end
	out.total = out.spent - out.back + recipeCost + out.trainingCost
	out.complete = #out.gaps == 0
	return out
end

-- The whole planner in one call (tests, and the panel when nothing is cached).
function P.run(input)
	local ctx = P.prepare(input)
	return P.finish(
		ctx,
		P.baseline(ctx, input.chance),
		input.have,
		{ commit = input.commit, gold = input.gold, alts = input.alts }
	)
end
