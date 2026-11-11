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

-- The materials of a craft step: what it takes from the bags (have/need) and what it buys (where, price).
local function craftMats(st, env)
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
		if r.buy then
			r.right = ("buy %d, %s %s"):format(r.buy.count, r.buy.where, env.money(r.buy.cost))
		else
			r.right = ("%d/%d"):format(math.min(r.have, r.need), r.need)
		end
	end
	return order
end

-- The Next card of a planner step.
local function nextCard(st, env)
	local money = env.money
	local card = { key = stepKey(st), kind = st.kind, spell = st.spell, mats = {}, notes = {} }
	if st.kind == "gap" then
		card.color = "warn"
		card.name = ("Nothing gives skill from %d to %d"):format(st.from, st.to)
		card.verb = st.why
		return card
	elseif st.kind == "train" then
		card.color = "gold"
		card.name = st.name
		card.verb = ("Train it at the trainer, from %d"):format(st.at)
		return card
	elseif st.kind == "buyRecipe" then
		card.color = "gold"
		card.item = st.item
		card.name = env.nameOf(st.item, "Recipe: " .. tostring(st.name))
		card.verb = ("Buy it on the AH for %s"):format(money(st.price))
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
	card.mats = craftMats(st, env)
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
		return { n = n, color = "warn", text = "No recipe gives skill", right = ("%d to %d"):format(st.from, st.to) }
	elseif st.kind == "train" then
		return { n = n, color = "gold", text = "Train " .. st.name, right = ("at %d"):format(st.at) }
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
		text = ("%dx %s%s"):format(st.crafts, st.name, st.source == "stock" and ", from stock" or ""),
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
		a.label = #want == 1 and ("Buy %s: %s"):format(first.name, (problems[1]:gsub("^[^:]*: ", "")))
			or "This vendor sells none of them"
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
		d.next = p.steps[1] and nextCard(p.steps[1], env)
		for i = 2, #p.steps do
			if #d.later >= V.MAX_LATER then
				d.later[#d.later + 1] =
					{ n = nil, color = "ash", text = ("and %d more steps"):format(#p.steps - i + 1) }
				break
			end
			d.later[#d.later + 1] = laterRow(i, p.steps[i], env)
		end
		d.footer = footerLines(p, env)
		if not d.next then
			d.empty = "Nothing gives skill in range: every known recipe is grey."
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
		for _, n in ipairs(nx.notes) do
			add(n)
		end
		add(nx.alt)
		add(nx.tags)
		for _, a in ipairs(nx.actions or {}) do
			add(("[%s]%s"):format(a.label, a.enabled and "" or " (not yet)"))
		end
	end
	add(d.empty)
	for _, r in ipairs(d.later) do
		add(((r.n and (r.n .. " ") or "") .. r.text .. (r.right and (" " .. r.right) or "")))
	end
	for _, f in ipairs(d.footer) do
		add(f)
	end
	return out
end
