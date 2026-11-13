-- What the panel shows, as plain tables: the model (Scan.build) in, a view description out. No frames and no client
-- calls except through `env`, so busted tests it whole; UI.lua only draws what this returns.
--
-- The panel wears the colour of the step to do now: the Next card's stripe, its pulse and the runway bar take the
-- recipe's difficulty colour, everything else stays ink and bone.
local _, ns = ...
local V = {}
ns.View = V

V.MAX_LATER = 6
V.MAX_FOOTER = 6
V.MAX_MATS = 8
V.MIN_HEIGHT = 96

-- Colours as r, g, b. The four difficulty colours are the game's own; the rest is the panel's palette.
V.RGB = {
	orange = { 1, 0.502, 0.251 },
	yellow = { 1, 1, 0 },
	green = { 0.251, 0.753, 0.251 },
	grey = { 0.5, 0.5, 0.5 },
	gold = { 1, 0.82, 0 }, -- buy a recipe, train: steps that unlock rather than craft
	warn = { 1, 0.376, 0.376 },
	bone = { 0.918, 0.894, 0.839 },
	ash = { 0.549, 0.561, 0.588 },
	ink = { 0.063, 0.075, 0.094 },
	surface = { 0.102, 0.122, 0.153 },
	line = { 0.204, 0.224, 0.267 },
}

local NEXT_COLOR = { orange = "yellow", yellow = "green", green = "grey" }

-- The next colour change of a recipe at `skill`: { from, target, color, next } where the bar runs from `from` (the
-- start of the current band) to `target` (the skill at which the colour changes). nil when the recipe is grey or the
-- thresholds are missing. The orange band has no start in the data, so it is drawn as wide as the yellow one.
function V.colourTarget(skill, y, g)
	if type(skill) ~= "number" or type(y) ~= "number" or type(g) ~= "number" or g <= y then
		return nil
	end
	local mid = math.floor((y + g) / 2)
	local band
	if skill < y then
		local width = math.max(1, mid - y)
		band = { from = math.min(skill, y - width), target = y, color = "orange" }
	elseif skill < mid then
		band = { from = y, target = mid, color = "yellow" }
	elseif skill < g then
		band = { from = math.max(y, mid), target = g, color = "green" }
	else
		return nil
	end
	band.next = NEXT_COLOR[band.color]
	local span = band.target - band.from
	band.frac = span > 0 and math.max(0, math.min(1, (skill - band.from) / span)) or 1
	band.left = band.target - skill
	band.label = ("%d to %s"):format(band.left, band.next)
	return band
end

-- Units of each material that went since the last refresh of the SAME step (the bags dropped while it stayed first).
-- prev, cur: Next cards ({ key, mats = { { item, have } } }). Returns consumed[item] = units gone.
function V.consumed(prev, cur)
	local out = {}
	if not prev or not cur or prev.key == nil or prev.key ~= cur.key then
		return out
	end
	local before = {}
	for _, m in ipairs(prev.mats or {}) do
		before[m.item] = m.have
	end
	for _, m in ipairs(cur.mats or {}) do
		local b = before[m.item]
		if b and m.have < b then
			out[m.item] = b - m.have
		end
	end
	return out
end

-- How the Next card changes between two descriptions: "first" (nothing shown before or another profession), "same"
-- (same step, numbers update in place), "advance" (the skill passed the step: slide the next one in), "replace"
-- (the plan changed its mind at the same skill: crossfade).
function V.transition(prev, cur)
	local a, b = prev and prev.next, cur and cur.next
	if not a or not b or prev.profession ~= cur.profession then
		return "first"
	end
	if a.key == b.key then
		return "same"
	end
	if (cur.skill or 0) > (prev.skill or 0) then
		return "advance"
	end
	return "replace"
end

local function stepKey(st)
	return table.concat({ st.kind, tostring(st.spell or st.item or st.from), tostring(st.source or "") }, ":")
end

local TAG_TEXT = {
	["last use"] = "last use before it turns grey",
	["needs AH sale"] = "counts on selling the results on the AH",
	["chance model"] = "the chance formula decides this one",
	["prices from export"] = "some prices from the export",
}

local WHERE = { vendor = "vendor", ah = "AH" }

-- A field the planner may leave nil (unknown, never guessed), as text.
local function known(v, f)
	if v == nil then
		return "unknown"
	end
	if f then
		return f(v)
	end
	return type(v) == "number" and tostring(math.floor(v)) or tostring(v)
end

-- A rank's terms: "level 20, 5g" ("unknown" for what the trainer has not shown yet).
function V.rankTerms(st, env)
	return ("level %s, %s"):format(known(st.level), st.cost and env.money(st.cost) or "cost unknown")
end

-- "Train Expert (225) — level 20, 5g".
function V.rankLine(st, env)
	return ("Train %s (%s) — %s"):format(st.name or "the next rank", known(st.cap), V.rankTerms(st, env))
end

local SRC_TEXT = {
	known = "known",
	trainer = "trainer",
	item = "pattern",
	auto = "learned with the rank",
	vendor = "vendor pattern",
	ah = "AH pattern",
	drop = "drop",
	dungeon = "dungeon drop",
	special = "special NPC / dungeon",
}

V.UNCHECKED = "not checked at a trainer"

-- Alternatives cheapest first; a tie by spell, so the order is total.
function V.byExtra(a, b)
	if (a.extra or 0) ~= (b.extra or 0) then
		return (a.extra or 0) < (b.extra or 0)
	end
	return (tonumber(a.spell) or 0) < (tonumber(b.spell) or 0)
end

-- A step's alternatives as lines: "Other way: Name, +1s 20c (trainer)", cheapest first, at most `max`.
function V.otherLines(others, env, max)
	local list = {}
	for _, o in ipairs(others or {}) do
		list[#list + 1] = o
	end
	table.sort(list, V.byExtra)
	local out = {}
	for i, o in ipairs(list) do
		if max and i > max then
			out[#out + 1] = ("and %d more ways"):format(#list - max)
			break
		end
		local src = SRC_TEXT[o.src] or (o.src and tostring(o.src)) or "source unknown"
		if o.src == "special" and o.teacher then
			src = ("%s: %s"):format(src, tostring(o.teacher))
		end
		out[#out + 1] = ("Other way: %s, +%s (%s)"):format(
			tostring(o.name or o.spell),
			env.money(math.max(0, o.extra or 0)),
			src
		)
	end
	return out
end

-- A craft step's alternatives as rows { text, use = action or nil }: the text of V.otherLines, and a "Use this"
-- button that switches the plan to it ({ id = "swap", spell = X, from = Y }: SkillupHelperDB.exclude.swap[Y] = X).
-- Y is the spell the step was built on before any swap. A gated alternative, or a committed step (a saved AH trip),
-- gets no button: shortcuts and trips have their own controls. The "and N more" line has no button.
function V.otherRows(st, env, max)
	local lines = V.otherLines(st.others, env, max)
	local list = {}
	for _, o in ipairs(st.others or {}) do
		list[#list + 1] = o
	end
	-- the same total order as V.otherLines, so row i's button is row i's recipe
	table.sort(list, V.byExtra)
	local from = st.swapFrom or st.spell
	local out = {}
	for i, line in ipairs(lines) do
		local o = list[i]
		local row = { text = line }
		if o and (not max or i <= max) and not o.gated and not st.committed and type(from) == "number" then
			row.use = {
				id = "swap",
				spell = o.spell,
				from = from,
				enabled = true,
				label = "Use this",
				tip = ("Plan %s here instead (Back to undoes it)"):format(tostring(o.name or o.spell)),
			}
		end
		out[#out + 1] = row
	end
	return out
end

-- The row of a step the user's swap built: "Your choice, instead of Y" with a "Back to Y" button, or nil.
function V.swapBackRow(st)
	if type(st.swapFrom) ~= "number" then
		return nil
	end
	local name = tostring(st.swapFromName or ("spell " .. st.swapFrom))
	return {
		text = ("Your choice, instead of %s"):format(name),
		use = {
			id = "unswap",
			spell = st.swapFrom,
			enabled = true,
			label = "Back to " .. name,
			tip = "Let the plan pick the cheapest recipe here again",
		},
	}
end

-- A step's shortcuts (gated recipes: a special teacher, a quest, a trainer recipe no trainer was seen teaching) as
-- rows with their two buttons: { text, use = action, hide = action }. A shortcut on a craft step saves money; one on
-- a gap fills it.
function V.shortcutRows(cuts, env)
	local out = {}
	for _, c in ipairs(cuts or {}) do
		local what = c.saves and ("Shortcut: %s saves %s"):format(tostring(c.name or c.spell), env.money(c.saves))
			or ("Fills this gap: %s"):format(tostring(c.name or c.spell))
		local text = c.needs and ("%s (needs: %s)"):format(what, tostring(c.needs)) or what
		out[#out + 1] = {
			text = text,
			use = {
				id = "useShortcut",
				spell = c.spell,
				enabled = true,
				label = "Use it",
				tip = "You can get this recipe: let the plan use it",
			},
			hide = {
				id = "hideShortcut",
				spell = c.spell,
				enabled = true,
				label = "Hide",
				tip = "Never offer this recipe (/skillup exclude " .. tostring(c.spell) .. " brings it back)",
			},
		}
	end
	return out
end

-- What the plan is sure of, as footer lines: the shortcuts it left out, and trainer recipes not confirmed yet.
function V.routeLines(p)
	local out = {}
	if (p.shortcuts or 0) > 0 then
		-- before a trainer was read the plan also uses unconfirmed trainer recipes: no claim of certainty then
		out[#out + 1] = ("%s%d shortcut%s (quest, dungeon or unchecked trainer) marked on %s"):format(
			p.unconfirmed and "" or "Planned with recipes you can surely get. ",
			p.shortcuts,
			p.shortcuts == 1 and "" or "s",
			p.shortcuts == 1 and "its step" or "their steps"
		)
	end
	if p.unconfirmed then
		out[#out + 1] = ("Visit your trainer once: %d trainer recipe%s not confirmed yet"):format(
			p.unconfirmed,
			p.unconfirmed == 1 and "" or "s"
		)
	end
	return out
end

-- The materials of a craft step: what it takes from the bags (have/need) and what it buys (where, price). listed:
-- the items on the plan's shopping list (a set), whose buy rows point to it instead of naming a place and a price.
local function craftMats(st, env, listed)
	local byItem, order = {}, {}
	local function row(item)
		local r = byItem[item]
		if not r then
			r = { item = item, name = env.nameOf(item), need = 0, have = env.have(item) }
			byItem[item] = r
			order[#order + 1] = r
		end
		return r
	end
	for _, u in ipairs(st.used or {}) do
		local r = row(u.item)
		r.need = r.need + u.count
	end
	for _, b in ipairs(st.buy or {}) do
		local r = row(b.item)
		r.need = r.need + b.count
		r.buy = { count = b.count, where = WHERE[b.where] or "?", cost = (b.each or 0) * b.count }
	end
	for _, r in ipairs(order) do
		r.covered = r.buy == nil
		if r.buy and listed and listed[r.item] then
			r.right = ("%d/%d, on the list"):format(math.min(r.have, r.need), r.need)
		elseif r.buy then
			r.right = ("buy %d, %s %s"):format(r.buy.count, r.buy.where, env.money(r.buy.cost))
		else
			r.right = ("%d/%d"):format(math.min(r.have, r.need), r.need)
		end
	end
	return order
end

-- The Next card of a planner step.
local WHERE_RANK = { trainer = "at the trainer", book = "from a book", special = "special NPC / dungeon" }

local function nextCard(st, env, listed)
	local money = env.money
	local card = { key = stepKey(st), kind = st.kind, spell = st.spell, mats = {}, notes = {}, others = {} }
	if st.kind == "trainRank" then
		card.key = "trainRank:" .. tostring(st.cap)
		card.color = "gold"
		card.name = ("Train %s (%s)"):format(st.name or "the next rank", known(st.cap))
		card.verb = V.rankTerms(st, env)
		card.gain = st.skill and ("needs skill %d"):format(st.skill) or "skill needed unknown"
		card.cost = st.where and (WHERE_RANK[st.where] or tostring(st.where)) or "where unknown"
		if st.at and st.by then
			card.notes[#card.notes + 1] = ("Train it between %d and %d"):format(st.at, st.by)
		elseif st.by then
			card.notes[#card.notes + 1] = ("Train it before %d"):format(st.by)
		end
		return card
	elseif st.kind == "gap" then
		card.color = "warn"
		card.name = ("Nothing gives skill from %d to %d"):format(st.from, st.to)
		card.verb = st.why
		card.shortcuts = V.shortcutRows(st.shortcuts, env)
		return card
	elseif st.kind == "train" then
		card.color = "gold"
		card.name = st.name
		card.verb = ("Train it at the trainer, from %d"):format(st.at)
		if st.unchecked then
			card.cost = V.UNCHECKED
		end
		return card
	elseif st.kind == "buyRecipe" then
		card.color = "gold"
		card.item = st.item
		card.name = env.nameOf(st.item, "Recipe: " .. tostring(st.name))
		card.verb = st.owned and "In your bags: learn it" or ("Buy it on the AH for %s"):format(money(st.price))
		card.gain = ("learn at %d"):format(st.learn or 0)
		if st.saves then
			card.cost = ("saves %s over the plan without it"):format(money(st.saves))
		end
		if st.alt then
			card.alt = ("Or skip it: %s instead, %s more"):format(st.alt.name, money(st.alt.extra))
		end
		return card
	end
	card.color = st.color or "grey"
	card.name = st.name
	card.crafts = st.crafts
	card.verb = ("Craft %d"):format(st.crafts)
	card.gain = ("about +%.1f, to %d"):format(st.points or 0, math.floor(st.to or 0))
	if st.chance and card.color ~= "orange" then
		local a, b = math.floor(st.chance[1] * 100 + 0.5), math.floor(st.chance[2] * 100 + 0.5)
		card.gain = card.gain .. (a == b and (", %d%% a craft"):format(a) or (", %d%% falling to %d%%"):format(a, b))
	end
	if st.costPt then
		card.cost = ("%s a point"):format(money(st.costPt))
	end
	card.mats = craftMats(st, env, listed)
	if st.rankUp then
		local up = st.rankUp
		card.notes[#card.notes + 1] = ("Train %s between %s and %s"):format(
			up.name or "the next rank",
			known(up.at),
			known(up.by)
		)
	end
	card.others = V.otherLines(st.others, env, 3)
	card.otherRows = V.otherRows(st, env, 3)
	card.swapBack = V.swapBackRow(st)
	card.shortcuts = V.shortcutRows(st.shortcuts, env)
	card.pre = {}
	for _, p in ipairs(st.pre or {}) do
		local name = env.nameOf(p.item)
		card.pre[#card.pre + 1] = { count = p.count, name = name }
		card.notes[#card.notes + 1] = ("Craft %d %s first"):format(p.count, name)
	end
	if st.alt then
		card.alt = ("Or use stock: %dx %s, %s more over the path"):format(
			st.alt.crafts,
			st.alt.name,
			money(st.alt.extra)
		)
	end
	if st.expected then
		-- planner rule 1: the buys cover a bad-luck run; the mean is what it usually takes
		card.notes[#card.notes + 1] = ("Bought for a bad-luck run: usually %d crafts, up to %d"):format(
			math.ceil(st.expected - 1e-6),
			st.crafts
		)
	end
	if st.committed then
		card.notes[#card.notes + 1] = ("On your AH list: this recipe holds until %d"):format(math.floor(st.to or 0))
	end
	local tags = {}
	for _, t in ipairs(st.tags or {}) do
		tags[#tags + 1] = TAG_TEXT[t] or t
	end
	if #tags > 0 then
		local s = table.concat(tags, "; ")
		card.tags = s:sub(1, 1):upper() .. s:sub(2)
	end
	if st.thresholds then
		card.thresholds = { st.thresholds[1], st.thresholds[2] }
	end
	return card
end

-- One later step as a compact row: { n, color, text, right }.
local function laterRow(n, st, env)
	if st.kind == "gap" then
		return {
			n = n,
			color = "warn",
			text = "No recipe gives skill" .. (st.shortcuts and " (a shortcut fills it)" or ""),
			right = ("%d to %d"):format(st.from, st.to),
		}
	elseif st.kind == "trainRank" then
		return {
			n = n,
			color = "gold",
			text = ("Train %s (%s)"):format(st.name or "the next rank", known(st.cap)),
			right = V.rankTerms(st, env),
		}
	elseif st.kind == "train" then
		return {
			n = n,
			color = "gold",
			text = "Train " .. st.name .. (st.unchecked and (", " .. V.UNCHECKED) or ""),
			right = ("at %d"):format(st.at),
		}
	elseif st.kind == "buyRecipe" then
		return {
			n = n,
			color = "gold",
			text = "Buy " .. env.nameOf(st.item, "Recipe: " .. tostring(st.name)),
			right = env.money(st.price),
		}
	end
	return {
		n = n,
		color = st.color or "grey",
		text = ("%dx %s%s%s"):format(
			st.crafts,
			st.name,
			st.source == "stock" and ", from stock" or "",
			-- the shortcut itself (what it saves, what it needs) shows on the Next card
			st.shortcuts and " · shortcut" or ""
		),
		right = ("%d to %d"):format(math.floor(st.from), math.floor(st.to)),
	}
end

local VERDICT_TEXT = {
	ok = "fine to craft",
	alternative = "the stock option",
}

-- Quiet lines under the steps: what to keep, what is left over, what stock crafts would cost.
local function footerLines(p, env)
	local out = {}
	for _, h in ipairs(p.hold or {}) do
		out[#out + 1] = ("Keep %d %s for %s at %d"):format(h.count, env.nameOf(h.item), h.name, h.at)
	end
	for _, l in ipairs(p.leftovers or {}) do
		out[#out + 1] = ("Spare %d %s, worth %s at the %s"):format(
			l.count,
			env.nameOf(l.item),
			env.money(l.value),
			l.how == "ah" and "AH" or "vendor"
		)
	end
	for _, e in ipairs(p.fromStock or {}) do
		if e.verdict == "wasteful" then
			out[#out + 1] = ("%s x%d from stock: %s more a point"):format(e.name, e.crafts, env.money(e.extra))
		elseif e.verdict == "later" then
			out[#out + 1] = ("%s x%d from stock: keep it for %d"):format(e.name, e.crafts, e.at or 0)
		elseif VERDICT_TEXT[e.verdict] and e.verdict ~= "alternative" then
			out[#out + 1] = ("%s x%d from stock: %s"):format(e.name, e.crafts, VERDICT_TEXT[e.verdict])
		end
	end
	if #out > V.MAX_FOOTER then
		local more = #out - V.MAX_FOOTER
		for k = #out, V.MAX_FOOTER + 1, -1 do
			out[k] = nil
		end
		out[#out + 1] = ("and %d more"):format(more)
	end
	return out
end

-- The quiet line about price freshness, or nil when the prices are live and recent.
local function staleLine(p)
	local parts = {}
	local age = p.ageHours
	if age == nil then
		parts[#parts + 1] = "TSM data age unknown"
	elseif age > ns.TSM.STALE_HOURS then
		parts[#parts + 1] = ("TSM prices are %.0f h old: sync the TSM app"):format(age)
	end
	local export = p.prices and p.prices.export or 0
	if export > 0 then
		parts[#parts + 1] = ("%d prices from the export"):format(export)
	end
	return #parts > 0 and table.concat(parts, "; ") or nil
end

-- The Next card when only a version 1 plan (rows, no planner) is there.
local function legacyCard(m, env)
	local st = m.step
	if not st or not st.recipe then
		return nil
	end
	local color = ns.Logic.colorOf(m.skill, st.yellow, st.grey)
	local card = {
		key = "row:" .. tostring(st.spell or st.recipe),
		kind = "craft",
		spell = st.spell,
		color = color,
		name = st.recipe,
		crafts = m.craftsLeft,
		verb = ("Craft about %d"):format(m.craftsLeft or 0),
		gain = ("%d to %d"):format(st.from, st.to),
		cost = ("%s for the step"):format(env.money(st.cost)),
		thresholds = { st.yellow, st.grey },
		mats = {},
		notes = {},
	}
	for _, s in ipairs(m.shopping or {}) do
		card.mats[#card.mats + 1] = {
			item = s.item,
			name = s.name or env.nameOf(s.item),
			have = s.have,
			need = s.need,
			covered = s.short == 0,
			right = s.short > 0 and ("buy %d"):format(s.short) or ("%d/%d"):format(s.need, s.need),
		}
	end
	return card
end

-- What stands between the card and its first craft: the button's label and every blocker, one a line.
local function blockers(card)
	local list = {}
	for _, m in ipairs(card.mats or {}) do
		if m.buy then
			list[#list + 1] = ("Buy %d %s first"):format(m.buy.count, m.name)
		end
	end
	for _, p in ipairs(card.pre or {}) do
		list[#list + 1] = ("Craft %d %s first"):format(p.count, p.name)
	end
	if #list == 0 then
		for _, m in ipairs(card.mats or {}) do
			if (m.have or 0) < (m.need or 0) then
				list[#list + 1] = ("Need %d more %s"):format(m.need - (m.have or 0), m.name)
			end
		end
	end
	if #list == 0 then
		list[1] = "Materials missing from your bags"
	end
	return list[1], #list > 1 and table.concat(list, "\n") or nil
end

-- The vendor reagents a card is short of: { { item, name, count } }, the units its buy rows still lack (need minus
-- have, bags and bank, as the planner counts them).
function V.vendorShort(card)
	local want = {}
	for _, m in ipairs(card and card.mats or {}) do
		if m.buy and m.buy.where == "vendor" then
			local short = math.max(0, (m.need or 0) - (m.have or 0))
			if short > 0 then
				want[#want + 1] = { item = m.item, name = m.name, count = short }
			end
		end
	end
	return want
end

-- The "Buy" button for `want` (V.vendorShort) at the open merchant. env.merchant(item) -> offer (Logic.vendorLots)
-- with its merchant `index`, or nil and why; nil env.merchant means no merchant is open. env.gold() -> copper on
-- hand, env.bagRoom(item, offer) -> units the bags take (both optional). Returns
-- { id = "buy", want, items = { { item, name, index, qty, cost, calls } }, cost, enabled, label, tip }, or nil when
-- nothing is short. Disabled with the reason in its label and tip when no merchant sells it, gold is short or the bags
-- are full.
function V.buyAction(want, env)
	if not want or #want == 0 then
		return nil
	end
	local a = { id = "buy", want = want, items = {}, cost = 0, enabled = false }
	local first = want[1]
	local what = #want == 1 and ("%d %s"):format(first.count, first.name) or ("%d reagents"):format(#want)
	if type(env.merchant) ~= "function" then
		a.label = ("Buy %s at a vendor"):format(what)
		a.tip = "Open a vendor that sells " .. (#want == 1 and first.name or "them") .. ", then click here to buy."
		return a
	end
	local lines, problems = {}, {}
	for _, w in ipairs(want) do
		local offer, why = env.merchant(w.item)
		local lots
		if offer then
			lots, why = ns.Logic.vendorLots(w.count, offer)
		end
		if lots and env.bagRoom then
			local room = env.bagRoom(w.item, offer)
			if room and room < lots.qty then
				lots, why = nil, ("bags full, room for %d"):format(room)
			end
		end
		if lots then
			a.items[#a.items + 1] = {
				item = w.item,
				name = w.name,
				index = offer.index,
				qty = lots.qty,
				cost = lots.cost,
				calls = lots.calls,
			}
			a.cost = a.cost + lots.cost
			lines[#lines + 1] = ("%d %s, %s"):format(lots.qty, w.name, env.money(lots.cost))
		else
			problems[#problems + 1] = ("%s: %s"):format(w.name, why or "not sold here")
		end
	end
	if #a.items == 0 then
		-- one reason for all of them (bags full, no vendor stock) goes on the button; mixed reasons go to the tip
		local reasons, same = {}, true
		for k, w in ipairs(want) do
			reasons[k] = problems[k]:sub(#w.name + 3)
			same = same and reasons[k] == reasons[1]
		end
		if #want == 1 then
			a.label = ("Buy %s: %s"):format(first.name, reasons[1])
		elseif same then
			a.label = ("Buy %d reagents: %s"):format(#want, reasons[1])
		else
			a.label = "This vendor sells none of them"
		end
		a.tip = table.concat(problems, "\n")
		return a
	end
	local gold = env.gold and env.gold()
	if gold and gold < a.cost then
		a.label = ("Not enough gold: %s needed"):format(env.money(a.cost))
		a.tip = ("You have %s."):format(env.money(gold))
		return a
	end
	a.enabled = true
	if #a.items == 1 then
		a.label = ("Buy %d %s, %s"):format(a.items[1].qty, a.items[1].name, env.money(a.cost))
	else
		a.label = ("Buy %d reagents, %s"):format(#a.items, env.money(a.cost))
	end
	for _, p in ipairs(problems) do
		lines[#lines + 1] = "Not here: " .. p
	end
	if #lines > 1 or #problems > 0 then
		a.tip = table.concat(lines, "\n")
	end
	return a
end

-- The AH trip as a block for the card: { title, rows = { { item, name, right, recipe } }, total, to, route, key }.
-- `saved` is the trip list the user already keeps (env.savedTrip), shown as such.
function V.tripBlock(trip, env, saved)
	if not trip or #trip.rows == 0 then
		return nil
	end
	local b = {
		rows = {},
		total = trip.total,
		to = trip.to,
		route = trip.route,
		commit = trip.commit,
		saved = saved ~= nil,
	}
	local ENDS = { train = "the trainer", gap = "a gap", gold = "your gold", cap = "the cap" }
	b.title = ("One AH trip: %s, covers to %d (up to %s)"):format(
		env.money(trip.total),
		math.floor(trip.to or 0),
		ENDS[trip.ends] or tostring(trip.ends)
	)
	for _, r in ipairs(trip.rows) do
		local count = r.buffer > 0 and ("%d (+%d spare)"):format(r.count, r.buffer) or tostring(r.total)
		b.rows[#b.rows + 1] = {
			item = r.item,
			name = env.nameOf(r.item),
			count = r.total,
			each = r.each,
			recipe = r.recipe,
			right = ("%s, %s"):format(count, env.money(r.cost)),
		}
	end
	return b
end

-- The trip-list button: "Add to AH list" away from the AH, or the list already kept.
function V.tripAction(block)
	if not block then
		return nil
	end
	if block.saved then
		return { id = "untrip", block = block, enabled = true, label = "On your AH list (click to drop it)" }
	end
	return {
		id = "trip",
		block = block,
		enabled = true,
		label = ("Add to AH list, %d items"):format(#block.rows),
		tip = "Keeps this list: at the auction house it becomes buy rows.",
	}
end

local PLACE = { trainer = "Trainer", vendor = "Vendor", ah = "Auction House" }

-- A row's cost: its own total when the planner gives one, else unit price times count; nil when unknown.
local function rowCost(r)
	if r.kind == "trainRank" or r.kind == "train" or type(r.cost) == "number" then
		return r.cost
	end
	if type(r.price) == "number" then
		return r.price * (r.count or 1)
	end
	return nil
end

local KIND_RANK = { trainer = 1, vendor = 2, ah = 3 }

-- Blocks ordered by city: the city whose nearest stop is closest first, a city of unknown distance after those, and
-- blocks with no known city last; inside a city the travel order (trainer, vendor, auction house). Pure.
-- blocks: { { place, city, dist, rank } }, rank = the block's position in travel order. Returns a new list.
function V.orderByCity(blocks)
	local cityDist, cityFirst = {}, {}
	for _, b in ipairs(blocks) do
		if b.city then
			cityFirst[b.city] = math.min(cityFirst[b.city] or b.rank, b.rank)
			if b.dist and (not cityDist[b.city] or b.dist < cityDist[b.city]) then
				cityDist[b.city] = b.dist
			end
		end
	end
	local out = {}
	for i, b in ipairs(blocks) do
		out[i] = b
	end
	table.sort(out, function(a, b)
		if a.city ~= b.city then
			if not a.city or not b.city then
				return a.city ~= nil
			end
			local da, db = cityDist[a.city], cityDist[b.city]
			if (da ~= nil) ~= (db ~= nil) then
				return da ~= nil
			elseif da and da ~= db then
				return da < db
			elseif cityFirst[a.city] ~= cityFirst[b.city] then
				return cityFirst[a.city] < cityFirst[b.city]
			end
			return a.city < b.city
		end
		if (KIND_RANK[a.place] or 9) ~= (KIND_RANK[b.place] or 9) then
			return (KIND_RANK[a.place] or 9) < (KIND_RANK[b.place] or 9)
		end
		return a.rank < b.rank
	end)
	return out
end

-- Splits a place's rows by city. env.where(place, row) -> city, yards (Guide.lua `place` of the nearest NPC that
-- serves the row), or nil when no NPC with a place is known. Without env.where every row is one group, no city.
local function byCity(place, rows, env)
	local groups, index = {}, {}
	for _, r in ipairs(rows) do
		local city, dist
		if type(env.where) == "function" then
			city, dist = env.where(place, r)
		end
		local key = city or false
		local gr = index[key]
		if not gr then
			gr = { city = city, dist = dist, rows = {} }
			index[key] = gr
			groups[#groups + 1] = gr
		elseif dist and (not gr.dist or dist < gr.dist) then
			gr.dist = dist
		end
		gr.rows[#gr.rows + 1] = r
	end
	return groups
end

-- plan.shopping as blocks for the card, one per place and city, ordered by city (V.orderByCity), each city in travel
-- order: { { place, city, title, total, unknown, rows = { { item, name, right } } } }. nil when there is nothing to buy.
function V.shoppingBlocks(shopping, env)
	if type(shopping) ~= "table" then
		return nil
	end
	local out, seen = {}, {}
	local order = shopping.order or { "trainer", "vendor", "ah" }
	for _, place in ipairs(order) do
		local all = shopping[place]
		if not seen[place] and PLACE[place] and type(all) == "table" and #all > 0 then
			seen[place] = true
			for _, gr in ipairs(byCity(place, all, env)) do
				local rows = gr.rows
				local b = {
					place = place,
					city = gr.city,
					dist = gr.dist,
					rank = #out + 1,
					rows = {},
					total = 0,
					unknown = 0,
				}
				for _, r in ipairs(rows) do
					local cost = rowCost(r)
					if cost then
						b.total = b.total + cost
					else
						b.unknown = b.unknown + 1
					end
					local row = { item = r.item }
					if place == "trainer" then
						row.name = r.kind == "trainRank" and ("%s rank"):format(tostring(r.name)) or tostring(r.name)
						if r.unchecked then
							row.name = row.name .. ", " .. V.UNCHECKED
						end
						row.right = ("at %s, %s"):format(known(r.skill), cost and env.money(cost) or "cost unknown")
					else
						local name = env.nameOf(r.item, r.name)
						if place == "vendor" and type(r.merchant) == "string" then
							name = ("%s (%s)"):format(name, r.merchant)
						end
						row.name = name
						row.right = ("%d, %s"):format(r.count or 0, cost and env.money(cost) or "price unknown")
					end
					b.rows[#b.rows + 1] = row
				end
				b.title = ("%s%s: %s%s"):format(
					PLACE[place],
					b.city and (", " .. b.city) or "",
					env.money(b.total),
					b.unknown > 0 and (" + %d unknown"):format(b.unknown) or ""
				)
				out[#out + 1] = b
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return V.orderByCity(out)
end

-- The AH block of plan.shopping as the list the "Add to AH list" button keeps (ns.saveTrip): rows in the trip
-- list's shape ({ item, name, count, each, recipe = pattern }), commit and target from plan.trip.
function V.shoppingTrip(p, env, saved)
	local rows = p.shopping and p.shopping.ah
	if type(rows) ~= "table" or #rows == 0 then
		return nil
	end
	local b = { rows = {}, total = 0, saved = saved ~= nil, prof = p.profKey }
	for _, r in ipairs(rows) do
		local each = type(r.price) == "number" and r.price or nil
		b.rows[#b.rows + 1] = {
			item = r.item,
			name = env.nameOf(r.item, r.name),
			count = r.count or 0,
			each = each,
			recipe = r.kind == "pattern" or nil,
		}
		b.total = b.total + (rowCost(r) or 0)
	end
	local trip = p.trip
	if trip then
		b.to, b.route, b.commit = trip.to, trip.route, trip.commit
	end
	return b
end

-- The hard stop when the next rank needs a higher character level: "Artisan needs level 35, you are 30".
function V.capBlockLine(cb)
	if type(cb) ~= "table" then
		return nil
	end
	return ("%s needs level %s, you are %s"):format(
		tostring(cb.name or "The next rank"),
		known(cb.level),
		known(cb.have)
	)
end

-- Poisons (SkillLine 40) has no trainer ranks: its cap is 5 per character level, up to 300.
V.LEVEL_CAPPED = { [40] = 5, poisons = 5 }
-- The highest skill any profession reaches on this client.
V.TOP_SKILL = 300

-- Why the plan is empty when the skill sits at its live cap (nil when it does not): "At your cap (175). Poisons rises
-- 5 per character level." A level-capped skill says so; any other waits for the next rank at the trainer.
function V.atCapLine(m)
	local skill, cap = m and m.skill, m and m.maxSkill
	if type(skill) ~= "number" or type(cap) ~= "number" or skill < cap then
		return nil
	end
	local per = V.LEVEL_CAPPED[m.professionID or false]
		or (type(m.profession) == "string" and V.LEVEL_CAPPED[m.profession:lower()])
	if per and cap < V.TOP_SKILL then
		return ("At your cap (%d). %s rises %d per character level."):format(cap, m.profession or "This skill", per)
	end
	if cap >= V.TOP_SKILL then
		return ("At the top skill (%d)."):format(cap)
	end
	return ("At your cap (%d): the next rank at the trainer raises it."):format(cap)
end

------------------------------------------------------------------------------------------------- the AH buy rows

-- One AH list row (Logic.ahList) at the open AH. live: what the AH said about the item (UI.lua keeps it):
-- { state = "searching"|"listed"|"quoting"|"quoted"|"buying"|"bought"|"failed"|"unavailable", kind = "commodity"|
-- "item", results, quote = { unit, total }, qty, err }. env: money, nameOf, gold() (optional), busy (the item of the
-- purchase in flight, or nil).
-- Returns { item, name, right, note, warn, skip, action = { id, item, qty, auctionID, buyout, cost, enabled, label,
-- tip } }. skip: sold out or overpriced and not for a committed step, so the next plan may go without it.
function V.ahRow(row, live, env)
	local money = env.money
	local name = env.nameOf(row.item, row.name)
	local out = { item = row.item, name = ("%s x%d"):format(name, row.count), right = "", committed = row.committed }
	local act = { item = row.item, enabled = false }
	out.action = act
	local state = live and live.state or "waiting"
	local problem -- "sold out" or "overpriced": the row may go
	if state == "waiting" or state == "searching" then
		out.right = "searching"
		act.id, act.label = "ahWait", "Searching the AH"
		return out
	end
	if state == "bought" then
		out.right = "bought"
		act.id, act.label = "ahDone", ("Bought %d"):format(live.qty or row.count)
		return out
	end
	if state == "unavailable" then
		out.note = "The price changed or it sold out while you looked."
		act.id, act.enabled, act.label = "ahSearch", true, "Search again"
		return out
	end
	local estimate = row.each
	if live.kind == "item" then
		local best = ns.Logic.cheapestBuyout(live.results)
		if not best then
			problem = "sold out"
			out.right = "none with a buyout"
		else
			local verdict, ratio = ns.Logic.ahVerdict(estimate, best.buyout / math.max(1, best.quantity))
			out.right = money(best.buyout)
			if verdict == "over" then
				problem = "overpriced"
				out.warn = ("%.1fx the plan's %s"):format(ratio, money(estimate))
			end
			act.id, act.auctionID, act.buyout, act.cost = "ahBid", best.auctionID, best.buyout, best.buyout
			act.qty = best.quantity
			act.enabled = true
			act.label = (verdict == "over" and "Buy anyway for %s" or "Buy for %s"):format(money(best.buyout))
		end
	else
		local q = ns.Logic.commodityQuote(live.results, row.count)
		if q.qty == 0 then
			problem = "sold out"
			out.right = "none listed"
		else
			local verdict, ratio = ns.Logic.ahVerdict(estimate, q.avg)
			out.right = ("%s each, %s"):format(money(q.unit), money(q.total))
			if q.qty < row.count then
				out.note = ("Only %d on the AH."):format(q.available)
			end
			if verdict == "over" then
				problem = "overpriced"
				out.warn = ("%.1fx the plan's %s each"):format(ratio, money(estimate))
			end
			act.id, act.qty, act.cost, act.enabled = "ahStart", q.qty, q.total, true
			act.label = (verdict == "over" and "Buy anyway: %d for %s" or "Buy %d for %s"):format(q.qty, money(q.total))
		end
		if state == "quoting" then
			act.id, act.enabled, act.label = "ahWait", false, "Getting the price"
		elseif state == "quoted" and live.quote then
			local total = live.quote.total
			act.id, act.qty, act.cost, act.enabled = "ahConfirm", live.qty, total, true
			act.label = ("Confirm %d for %s"):format(live.qty or 0, money(total))
			local v, ratio = ns.Logic.ahVerdict(estimate, live.quote.unit)
			if v == "over" then
				problem = "overpriced"
				out.warn = ("%.1fx the plan's %s each"):format(ratio, money(estimate))
			end
		end
	end
	if state == "buying" then
		act.id, act.enabled, act.label = "ahWait", false, "Buying"
	elseif state == "failed" then
		out.note = live.err or "The purchase failed."
	end
	if problem then
		local msg = problem == "sold out" and "Sold out." or "Overpriced."
		if row.committed then
			-- planner rule 3: a committed step's buy never drops silently
			out.note = msg .. " For a step you committed to: it stays on the list (drop the AH list to replan)."
		else
			out.note = msg .. " The next plan goes without it."
			out.skip = problem
		end
		if problem == "sold out" then
			act.id, act.enabled, act.label = "ahSearch", true, "Search again"
		end
	end
	-- one purchase at a time, every step from a click: a row waits while another is in flight
	if act.enabled and env.busy and env.busy ~= row.item then
		act.enabled, act.label = false, "Wait: another buy is in progress"
	elseif act.enabled and act.id ~= "ahSearch" and env.gold and act.cost then
		local gold = env.gold()
		if type(gold) == "number" and gold < act.cost then
			act.enabled, act.label = false, ("Not enough gold: %s needed"):format(money(act.cost))
		end
	end
	return out
end

-- The AH panel: { title, rows, empty }. list: Logic.ahList; live[item]: V.ahRow's live.
function V.ahPanel(list, live, env)
	local d = { rows = {} }
	local est = 0
	for _, r in ipairs(list or {}) do
		est = est + (r.each or 0) * r.count
		d.rows[#d.rows + 1] = V.ahRow(r, live and live[r.item], env)
	end
	if #d.rows == 0 then
		d.title = "SkillupHelper: your AH list is empty"
		d.empty = "Add a list from the profession panel's Next card (Add to AH list)."
	else
		d.title = ("SkillupHelper AH list: %d items, plan %s"):format(#d.rows, env.money(est))
	end
	return d
end

-- The buttons of a Next card: { { id = "craft", spell, count, enabled, label, tip }, { id = "open", ... } }, or nil
-- and why when the card gets none (not a craft, the recipe is not learned, the client gave no count).
-- "Craft N" casts min(the step's crafts, what the bags allow now); with nothing craftable it stays, inert, and its
-- label says what to do first. "Show recipe" selects the recipe in Blizzard's window only: TSM's window does not
-- follow C_TradeSkillUI.OpenRecipe.
function V.actions(card, env)
	if not card or card.kind ~= "craft" or not card.spell then
		return nil
	end
	if type(env.craftable) ~= "function" then
		return nil, "env.craftable missing"
	end
	local can, why = env.craftable(card.spell)
	if type(can) ~= "number" then
		return nil, why
	end
	local want = math.max(1, math.floor(card.crafts or 1))
	local n = math.max(0, math.min(want, math.floor(can)))
	local craft = { id = "craft", spell = card.spell, count = n, enabled = n > 0 }
	if n > 0 then
		craft.label = ("Craft %d"):format(n)
		if n < want then
			craft.tip = ("Materials for %d of the %d crafts"):format(n, want)
		end
	else
		craft.label, craft.tip = blockers(card)
	end
	local out = {}
	-- vendor reagents the step lacks: a Buy button above Craft, live while a merchant that sells them is open
	local buy = V.buyAction(V.vendorShort(card), env)
	if buy then
		out[#out + 1] = buy
	end
	out[#out + 1] = craft
	if env.dock == "blizzard" then
		out[#out + 1] = { id = "open", spell = card.spell, enabled = true, label = "Show recipe" }
	end
	return out
end

-- The "Show recipe" control of a plan step row: { id = "open", spell, enabled, label, tip }, or nil when the row
-- gets none. Only craft steps whose recipe is learned (env.craftable answers a count) qualify, and only beside
-- Blizzard's window: TSM's window does not follow C_TradeSkillUI.OpenRecipe, so the control is hidden there.
function V.rowOpen(st, env)
	if type(st) ~= "table" or st.kind ~= "craft" or type(st.spell) ~= "number" then
		return nil
	end
	if env.dock ~= "blizzard" or type(env.craftable) ~= "function" then
		return nil
	end
	if type(env.craftable(st.spell)) ~= "number" then
		return nil
	end
	return { id = "open", spell = st.spell, enabled = true, label = "Show", tip = "Show this recipe in the window" }
end

-- The panel's height for `content` under `chrome` (header and margins), up to `limit` (the docked window's height):
-- as tall as what it shows, and scrolling only when that does not fit.
function V.fit(content, chrome, limit)
	local want = chrome + content
	if want <= limit then
		return { height = math.max(V.MIN_HEIGHT, want), scroll = false }
	end
	return { height = limit, scroll = true }
end

-- env: nameOf(item, fallback) -> string, money(copper) -> string, have(item) -> count; optional craftable(spell) ->
-- crafts the client allows now (nil and why when the recipe is not learned) and dock ("blizzard", "tsm", "free").
-- Returns { state, profession, skill, cap, header, runway, next, later, footer, notice, message }.
function V.describe(m, env)
	m = m or {}
	if m.why and not m.skill then
		return {
			state = "message",
			message = m.why,
			tone = m.state == "not now" and "ash" or "warn",
			later = {},
			footer = {},
		}
	end
	local d = {
		state = "plan",
		profession = m.profession,
		skill = m.skill,
		cap = m.maxSkill,
		header = { title = m.profession or "?", skill = ("%d / %d"):format(m.skill or 0, m.maxSkill or 0) },
		later = {},
		footer = {},
		notice = m.why,
	}
	local p = m.planner
	if p then
		d.header.stale = staleLine(p)
		local shop = V.shoppingBlocks(p.shopping, env)
		local listed
		if shop then
			listed = {}
			for _, place in ipairs({ "vendor", "ah" }) do
				for _, r in ipairs(p.shopping[place] or {}) do
					listed[r.item or false] = true
				end
			end
		end
		d.next = p.steps[1] and nextCard(p.steps[1], env, listed)
		local saved = env.savedTrip and env.savedTrip(p.profKey)
		local cb = V.capBlockLine(p.capBlock)
		if cb then
			d.capBlock = cb
			d.notice = d.notice and (cb .. "\n" .. d.notice) or cb
		end
		if d.next and shop then
			-- one block per place in travel order; the AH block is also what "Add to AH list" keeps
			d.next.blocks = shop
			-- the list "Add to AH list" keeps: plan.trip when the trip starts now (as before), else the AH block
			if p.trip and p.trip.fromStep == 1 then
				d.next.trip = V.tripBlock(p.trip, env, saved)
			elseif not p.trip then
				d.next.trip = V.shoppingTrip(p, env, saved)
			end
			if d.next.trip then
				d.next.trip.prof = p.profKey
			end
		elseif d.next and p.trip and p.trip.fromStep == 1 then
			d.next.trip = V.tripBlock(p.trip, env, saved)
			if d.next.trip then
				d.next.trip.prof = p.profKey
				d.next.blocks = { d.next.trip }
			end
		elseif p.trip and not shop then
			d.footer[#d.footer + 1] = ("AH trip at step %d: %s, covers to %d"):format(
				p.trip.fromStep,
				env.money(p.trip.total),
				math.floor(p.trip.to or 0)
			)
		end
		for i = 2, #p.steps do
			if #d.later >= V.MAX_LATER then
				d.later[#d.later + 1] =
					{ n = nil, color = "ash", text = ("and %d more steps"):format(#p.steps - i + 1) }
				break
			end
			local row = laterRow(i, p.steps[i], env)
			row.open = V.rowOpen(p.steps[i], env)
			d.later[#d.later + 1] = row
		end
		local tripLine = d.footer[1]
		d.footer = footerLines(p, env)
		if tripLine then
			table.insert(d.footer, 1, tripLine)
		end
		local cov = p.coverage and p.coverage.to
		if type(cov) == "number" and (not m.maxSkill or cov < m.maxSkill) then
			table.insert(d.footer, 1, ("Data/Plan.lua covers to %d"):format(cov))
		end
		for _, line in ipairs(V.routeLines(p)) do
			d.footer[#d.footer + 1] = line
		end
		if not d.next then
			d.empty = V.atCapLine(m) or "Nothing gives skill in range: every known recipe is grey."
		end
	else
		d.state = "legacy"
		d.notice = d.notice or m.plannerWhy or m.planWhy
		d.next = legacyCard(m, env)
		for _, e in ipairs(m.fromStock or {}) do
			if #d.later >= V.MAX_LATER then
				break
			end
			local crafts = e.crafts == math.huge and "vendor mats" or ("x%d"):format(e.crafts)
			d.later[#d.later + 1] = { color = e.color, text = ("%s %s, from stock"):format(e.name, crafts) }
		end
		for _, b in ipairs(m.buyRecipes or {}) do
			d.footer[#d.footer + 1] = ("Worth buying: %s, %s, for %d to %d"):format(
				b.itemName or env.nameOf(b.item, b.recipe),
				env.money(b.price),
				b.from,
				b.to
			)
		end
		if not d.next then
			d.empty = "No plan step for this skill."
		end
	end
	local nx = d.next
	if nx and nx.kind == "craft" and nx.thresholds then
		d.runway = V.colourTarget(m.skill, nx.thresholds[1], nx.thresholds[2])
	end
	if nx then
		-- actions read every reagent (a buy row past the cut still blocks Craft); only the display is cut
		nx.actions, nx.actionsWhy = V.actions(nx, env)
		local ta = V.tripAction(nx.trip)
		if ta then
			nx.actions = nx.actions or {}
			table.insert(nx.actions, 1, ta)
		end
	end
	if nx and #nx.mats > V.MAX_MATS then
		for k = #nx.mats, V.MAX_MATS + 1, -1 do
			nx.mats[k] = nil
		end
	end
	return d
end

-- The description as plain lines (tests, and a readable dump for bug reports).
function V.text(d)
	local out = {}
	local function add(s)
		if s and s ~= "" then
			out[#out + 1] = s
		end
	end
	if d.state == "message" then
		add(d.message)
		return out
	end
	add(("%s %s"):format(d.header.title, d.header.skill))
	if d.runway then
		add(d.runway.label)
	end
	add(d.header.stale)
	add(d.notice)
	local nx = d.next
	if nx then
		add(nx.name)
		add(table.concat({ nx.verb or "", nx.gain or "" }, ", "))
		add(nx.cost)
		for _, mt in ipairs(nx.mats) do
			add(("%s %s"):format(mt.name, mt.right))
		end
		for _, b in ipairs(nx.blocks or {}) do
			add(b.title)
			for _, r in ipairs(b.rows) do
				add(("  %s %s"):format(r.name, r.right))
			end
		end
		for _, n in ipairs(nx.notes) do
			add(n)
		end
		for _, o in ipairs(nx.others or {}) do
			add(o)
		end
		add(nx.alt)
		add(nx.tags)
		for _, a in ipairs(nx.actions or {}) do
			add(("[%s]%s"):format(a.label, a.enabled and "" or " (not yet)"))
		end
	end
	add(d.empty)
	for _, r in ipairs(d.later) do
		add(
			((r.n and (r.n .. " ") or "") .. r.text .. (r.right and (" " .. r.right) or ""))
				.. (r.open and (" [" .. r.open.label .. "]") or "")
		)
	end
	for _, f in ipairs(d.footer) do
		add(f)
	end
	return out
end
