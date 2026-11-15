-- What the panel shows, as plain tables: the model (Scan.build) in, a view description out. No frames and no client
-- calls except through `env`, so busted tests it whole; UI.lua only draws what this returns.
--
-- The panel wears the colour of the step to do now: the card's stripe and its pulse take the recipe's difficulty
-- colour, everything else stays ink and bone. The docked panel draws `now`, `next`, `strip` and `journal`; the
-- lists (shopping, alts, settings) are the journal's pages.
local _, ns = ...
local V = {}
ns.View = V

-- The docked panel is the glance: one card for the step to do now, the next few lines, the whole path as a strip
-- and a button into the journal. Nothing in it scrolls, so every list it shows has a fixed cap.
V.BUY_LINES = 2 -- "buy" lines on the card; the rest fold into the second line
V.MAX_LINKS = 2 -- link lines on the card: Shopping, Alts
V.MAX_NEXT = 3 -- lines under "Next"
V.MIN_HEIGHT = 96
V.RANK_CAPS = { 75, 150, 225 } -- ticks on the path strip (Skills.RANK_CAPS without the top)

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
	local a, b = prev and prev.now, cur and cur.now
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
local BUY_AT = { vendor = " at a vendor", AH = " on the AH" }

local function upper1(s)
	return (tostring(s):gsub("^%l", string.upper))
end

local function plural(n, word)
	return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- Names joined inside a budget of characters, the rest as "and N more" (Where.fitList): never an ellipsis.
local function fitList(parts, budget)
	if ns.Where and ns.Where.fitList then
		return ns.Where.fitList(parts, budget)
	end
	return table.concat(parts, ", ")
end

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

-- A rank's terms: the skill it asks for and its price, "at 50, 5s" (from a trainer visit, else the data's default
-- ranks). The skill is `at`; a rank whose skill nobody knows is trained "by <the cap before it>". The character level
-- is said only when it matters: too low ("needs level 10, you are 8"), or not known while the rank asks for more than
-- level 1 ("needs level 10, character level not known yet"). The player's level: st.have (the planner's), else
-- env.level.
function V.rankTerms(st, env)
	local parts = {}
	if type(st.at) == "number" then
		parts[#parts + 1] = ("at %d"):format(st.at)
	elseif type(st.by) == "number" then
		parts[#parts + 1] = ("by %d"):format(st.by)
	end
	parts[#parts + 1] = type(st.cost) == "number" and env.money(st.cost) or "price not known yet"
	local need = type(st.level) == "number" and st.level or nil
	local have = (type(st.have) == "number" and st.have) or (type(env.level) == "number" and env.level) or nil
	if need and have and have < need then
		parts[#parts + 1] = ("needs level %d, you are %d"):format(need, have)
	elseif need and need > 1 and not have then
		parts[#parts + 1] = ("needs level %d, character level not known yet"):format(need)
	end
	return table.concat(parts, ", ")
end

-- "Train Journeyman (to 150) at 50, 5s".
function V.rankLine(st, env)
	local cap = type(st.cap) == "number" and (" (to %d)"):format(st.cap) or ""
	return ("Train %s%s %s"):format(st.name or "the next rank", cap, V.rankTerms(st, env))
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
		local text = c.needs and ("%s (needs: %s)"):format(what, tostring(c.needs))
			or (c.why and ("%s (%s)"):format(what, tostring(c.why)))
			or what
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

-- The Way selector of a craft or gap step (the Plan card's "Way: X v" row and a step row's "Ways..." menu), or nil
-- when the step has no alternative. { label, right, rightColor, title, items, back, stock }. items in menu order:
-- radios { kind = "radio", label, checked, action, tip } (the way in use first, then the plan's pick when the user
-- swapped, then the others cheapest first; a radio without an action is shown disabled), a stock note { kind = "note" },
-- a divider, then each shortcut { kind = "submenu", label, items = { use, hide } }. back: the "Back to Y" action.
function V.wayMenu(st, env)
	if type(st) ~= "table" or (st.kind ~= "craft" and st.kind ~= "gap") then
		return nil
	end
	local others = {}
	for _, o in ipairs(st.kind == "craft" and st.others or {}) do
		others[#others + 1] = o
	end
	table.sort(others, V.byExtra)
	local cuts = V.shortcutRows(st.shortcuts, env)
	local swapBack = st.kind == "craft" and V.swapBackRow(st) or nil
	if #others == 0 and #cuts == 0 and not swapBack then
		return nil
	end
	local m = { items = {} }
	local items = m.items
	if st.kind == "gap" then
		m.title = ("Ways from %s to %s"):format(known(st.from), known(st.to))
		m.label, m.right, m.rightColor = "Fill this gap", "no recipe here", "warn"
	else
		m.title = ("Ways from %d to %d"):format(math.floor(st.from or 0), math.floor(st.to or 0))
		m.label = "Way: " .. tostring(st.name or st.spell)
		local mine = swapBack ~= nil
		m.right, m.rightColor = mine and "your pick" or "plan's pick", mine and "gold" or "ash"
		items[#items + 1] = {
			kind = "radio",
			label = ("%s (%s)"):format(tostring(st.name or st.spell), m.right),
			checked = true,
		}
		if swapBack then
			m.back = swapBack.use
			items[#items + 1] = {
				kind = "radio",
				label = tostring(st.swapFromName or ("spell " .. st.swapFrom)) .. " (plan's pick)",
				checked = false,
				action = swapBack.use,
			}
		end
		local from = st.swapFrom or st.spell
		for _, o in ipairs(others) do
			local src = SRC_TEXT[o.src] or (o.src and tostring(o.src)) or "source unknown"
			local r = {
				kind = "radio",
				label = ("%s +%s (%s)"):format(tostring(o.name or o.spell), env.money(math.max(0, o.extra or 0)), src),
				checked = false,
			}
			if o.gated then
				r.tip = "Not sure you can get it: a shortcut's Use it lets the plan pick it"
			elseif st.committed then
				r.tip = "On your AH list: this recipe holds until its target (drop the list to switch)"
			elseif type(from) == "number" then
				r.action = {
					id = "swap",
					spell = o.spell,
					from = from,
					enabled = true,
					label = "Use this",
					tip = ("Plan %s here instead"):format(tostring(o.name or o.spell)),
				}
			end
			items[#items + 1] = r
		end
		if st.alt then
			m.stock = true
			items[#items + 1] = {
				kind = "note",
				label = ("Or use stock: %dx %s, +%s over the path"):format(
					st.alt.crafts or 0,
					tostring(st.alt.name),
					env.money(st.alt.extra or 0)
				),
			}
		end
	end
	if #cuts > 0 then
		if #items > 0 then
			items[#items + 1] = { kind = "divider" }
		end
		for _, c in ipairs(cuts) do
			items[#items + 1] = { kind = "submenu", label = c.text, items = { c.use, c.hide } }
		end
	end
	return m
end

-- What the plan is sure of, as the More tab's data lines: the shortcuts it left out, and trainer recipes not confirmed yet.
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
			r = { item = item, name = env.nameOf(item) or ("item " .. tostring(item)), need = 0, have = env.have(item) }
			byItem[item] = r
			order[#order + 1] = r
		end
		return r
	end
	for _, u in ipairs(st.used or {}) do
		local r = row(u.item)
		r.need = r.need + u.count
		for _, m in ipairs(u.mail or {}) do
			r.mail = r.mail or {}
			r.mail[#r.mail + 1] = { who = m.who, count = m.count }
		end
	end
	for _, b in ipairs(st.buy or {}) do
		local r = row(b.item)
		r.need = r.need + b.count
		r.buy = {
			count = b.count,
			where = WHERE[b.where] or "?",
			cost = (b.each or 0) * b.count,
			unpriced = b.unpriced == true or nil,
		}
	end
	for _, r in ipairs(order) do
		r.covered = r.buy == nil
		if r.buy then
			-- the card's sentence: "You have 13 of 24 Rough Stone; buy 11 at a vendor: 88c"
			local place = BUY_AT[r.buy.where] or ""
			r.text = ("You have %d of %d %s; buy %d%s%s"):format(
				math.min(r.have, r.need),
				r.need,
				r.name,
				r.buy.count,
				place,
				r.buy.unpriced and ", price unknown" or (": " .. env.money(r.buy.cost))
			)
		end
		if r.buy and listed and listed[r.item] then
			r.right = ("%d/%d, on the list"):format(math.min(r.have, r.need), r.need)
		elseif r.buy then
			r.right = ("buy %d, %s %s"):format(r.buy.count, r.buy.where, env.money(r.buy.cost))
		else
			r.right = ("%d/%d"):format(math.min(r.have, r.need), r.need)
		end
		if r.mail then
			r.right = r.right .. ", " .. V.mailWords(r, env)
		end
	end
	return order
end

-- "3 on Altname", "3 queued on Altname" or "3 on 2 alts" for a material row whose units the plan takes from alts;
-- sets r.mailCount, r.queued (every alt's part queued) and r.mailTip (one line per alt).
function V.mailWords(r, env)
	local n, queued, tip = 0, true, {}
	for _, m in ipairs(r.mail) do
		n = n + m.count
		if not (env.queued and env.queued(m.who, r.item, m.count)) then
			queued = false
		end
		tip[#tip + 1] = ("%s %d"):format(m.who, m.count)
	end
	r.mailCount, r.queued, r.mailTip = n, queued, table.concat(tip, ", ")
	local where = #r.mail == 1 and r.mail[1].who or ("%d alts"):format(#r.mail)
	return ("%d %son %s"):format(n, queued and "queued " or "", where)
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
		card.way = V.wayMenu(st, env)
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
		if st.owned then
			card.verb = "In your bags: learn it"
		elseif st.where == "source" then
			-- a recipe the user chose to use that the plan cannot buy: where it comes from, price not known
			card.verb = "Get the recipe: " .. tostring(st.source or "source not known")
			card.cost = "recipe price unknown"
		elseif st.where == "vendor" then
			local who = st.vendor and st.vendor.name
			local place = who and type(st.vendor.place) == "string" and (" in " .. st.vendor.place) or ""
			card.verb = ("Buy it from %s%s for %s"):format(
				who and tostring(who) or "its vendor",
				place,
				money(st.price)
			)
		else
			card.verb = ("Buy it on the AH for %s"):format(money(st.price))
		end
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
	if st.resale and (st.resale.back or 0) > 0 then
		-- "Count selling what I craft" is off: what selling would bring is information, the plan never ranks on it
		card.resale = ("about %s back if you sell %d (not counted)"):format(
			money(st.resale.back),
			st.resale.crafts or 0
		)
	end
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
	card.way = V.wayMenu(st, env)
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
	if card.resale then
		-- last, so a tight fit drops it before anything the plan needs
		card.notes[#card.notes + 1] = upper1(card.resale)
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

-- "price unknown for 2 items", and the names for the tooltip. nil with nothing unpriced.
function V.unpricedText(names)
	if type(names) ~= "table" or #names == 0 then
		return nil
	end
	return ("price unknown for %s"):format(plural(#names, "item")), "Price unknown: " .. table.concat(names, ", ")
end

-- The card's face, what the panel draws of a step: card.title ("Craft 12 Rough Grinding Stone"), card.sub ("28 to
-- 40, orange") and card.lines = { { text, color, tip, note } }: what to buy, what it costs and at most two notes.
-- Every line is a whole sentence that wraps; a list that would run long is cut here with "and N more", never by the
-- frame.
local function cardFace(card, st, env)
	local money = env.money
	local lines = {}
	local function add(text, color, tip, note)
		if text and text ~= "" then
			lines[#lines + 1] = { text = text, color = color or "ash", tip = tip, note = note }
		end
	end
	card.lines = lines
	if st.kind == "trainRank" then
		local cap = type(st.cap) == "number" and (" (to %d)"):format(st.cap) or ""
		card.title = ("Train %s%s"):format(st.name or "the next rank", cap)
		card.sub = upper1(V.rankTerms(st, env))
			.. (st.where and (", " .. (WHERE_RANK[st.where] or tostring(st.where))) or "")
		add(card.notes[1], "ash", nil, true)
		return card
	elseif st.kind == "gap" then
		card.title = ("No recipe from %d to %d"):format(math.floor(st.from), math.floor(st.to))
		card.sub = upper1(st.why or "no recipe in the data gives skill here")
		return card
	elseif st.kind == "train" then
		card.title = "Train " .. tostring(st.name)
		card.sub = ("At the trainer from skill %d%s"):format(
			st.at or 0,
			(type(st.cost) == "number" and st.cost > 0) and (", " .. money(st.cost)) or ""
		)
		if st.unchecked then
			add(upper1(V.UNCHECKED), "ash", nil, true)
		end
		return card
	elseif st.kind == "buyRecipe" then
		local learn = (", learn at %d"):format(st.learn or 0)
		if st.owned then
			card.title, card.sub = "Learn " .. card.name, "It is in your bags" .. learn
		elseif st.where == "source" then
			card.title = "Get " .. card.name
			card.sub = ("From: %s%s"):format(tostring(st.source or "source not known"), learn)
			add("Price unknown for the recipe", "warn")
		elseif st.where == "vendor" then
			local who = st.vendor and st.vendor.name
			local place = who and type(st.vendor.place) == "string" and (" in " .. st.vendor.place) or ""
			card.title = "Buy " .. card.name
			card.sub = ("From %s%s for %s%s"):format(
				who and tostring(who) or "its vendor",
				place,
				money(st.price),
				learn
			)
		else
			card.title = "Buy " .. card.name
			card.sub = ("On the AH for %s%s"):format(money(st.price), learn)
		end
		if st.saves then
			add(("Saves %s over the plan without it"):format(money(st.saves)), "ash", nil, true)
		end
		return card
	end
	card.title = ("Craft %d %s"):format(st.crafts or 0, tostring(st.name))
	local sub = ("%d to %d, %s"):format(math.floor(st.from or 0), math.floor((st.to or 0) + 0.5), card.color)
	if st.chance and card.color ~= "orange" then
		local a, b = math.floor(st.chance[1] * 100 + 0.5), math.floor(st.chance[2] * 100 + 0.5)
		sub = sub .. (a == b and (", %d%% a craft"):format(a) or (", %d%% falling to %d%% a craft"):format(a, b))
	end
	card.sub = sub
	-- what to buy: a sentence per reagent, the rest folded into the last line with their sentences in its tooltip
	local buys, total = {}, 0
	for _, r in ipairs(card.mats) do
		if r.buy then
			buys[#buys + 1] = r
			total = total + (r.buy.unpriced and 0 or r.buy.cost)
		end
	end
	for k, r in ipairs(buys) do
		if k < V.BUY_LINES or #buys == V.BUY_LINES then
			add(r.text, "bone")
		elseif k == V.BUY_LINES then
			local names, tip = {}, {}
			for j = k, #buys do
				names[#names + 1] = ("%d %s"):format(buys[j].buy.count, buys[j].name)
				tip[#tip + 1] = buys[j].text
			end
			add(("Also buy %s"):format(fitList(names, 64)), "bone", table.concat(tip, "\n"))
		end
	end
	if #buys == 0 and #card.mats > 0 then
		add("You have every reagent", "green")
	end
	local names = {}
	for _, u in ipairs(st.unpriced or {}) do
		names[#names + 1] = tostring(u.name or env.nameOf(u.item))
	end
	local unpriced, unpricedTip = V.unpricedText(names)
	if total > 0 then
		local cost = ("%s for this step"):format(money(total))
		if st.costPt then
			cost = cost .. (", %s a point"):format(money(st.costPt))
		end
		add(unpriced and (cost .. ", " .. unpriced) or cost, "ash", unpricedTip)
	elseif unpriced then
		add(upper1(unpriced), "warn", unpricedTip)
	end
	-- notes: what must be crafted first, then the first of the plan's own notes
	local pre = {}
	for _, p in ipairs(card.pre or {}) do
		pre[#pre + 1] = ("%d %s"):format(p.count, p.name)
	end
	if #pre > 0 then
		-- not a note the fit may drop: it is what to do before this step
		add(("First craft %s"):format(fitList(pre, 64)), "bone")
	end
	for _, n in ipairs(card.notes) do
		if not n:find("^Craft %d+ .* first$") then
			add(n, "ash", nil, true)
			break
		end
	end
	return card
end

local VERDICT_TEXT = {
	ok = "fine to craft",
	alternative = "the stock option",
}

-- The Shopping tab's Stock lines: what to keep, what is left over, what stock crafts would cost.
local function stockLines(p, env)
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
	return out
end

-- The quiet line about price freshness, or nil when the prices are live and recent.
local function staleLine(p)
	local parts = {}
	-- the age comes from a local Data/Plan.lua (pricesAt); without one it is not known, and nothing is claimed
	local age = p.ageHours
	if age ~= nil and age > ns.TSM.STALE_HOURS then
		parts[#parts + 1] = ("TSM prices are %.0f h old: sync the TSM app"):format(age)
	end
	local export = p.prices and p.prices.export or 0
	if export > 0 then
		parts[#parts + 1] = ("%d prices not from TSM (bundled or exported)"):format(export)
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
	card.title = ("Craft about %d %s"):format(m.craftsLeft or 0, tostring(st.recipe))
	card.sub = ("%s, %s"):format(card.gain, color)
	card.lines = {}
	local short = {}
	for _, r in ipairs(card.mats) do
		if not r.covered then
			short[#short + 1] = ("%d %s"):format(r.need - (r.have or 0), r.name)
		end
	end
	if #short > 0 then
		card.lines[1] = { text = ("Buy %s"):format(fitList(short, 64)), color = "bone" }
	end
	card.lines[#card.lines + 1] = { text = card.cost, color = "ash" }
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

-- The mail-queue button of a Next card whose rows take units from alts: "Queue mail" while any part is not queued,
-- else the queued state (a click drops it). rows: { { alt, item, count } } for the click.
function V.mailAction(card)
	local rows, alts, n, all = {}, {}, 0, true
	for _, r in ipairs(card and card.mats or {}) do
		for _, m in ipairs(r.mail or {}) do
			rows[#rows + 1] = { alt = m.who, item = r.item, count = m.count }
			if not alts[m.who] then
				alts[m.who] = true
				alts[#alts + 1] = m.who
			end
			n = n + m.count
		end
		if r.mail and not r.queued then
			all = false
		end
	end
	if #rows == 0 then
		return nil
	end
	local from = #alts == 1 and alts[1] or ("%d alts"):format(#alts)
	if all then
		return {
			id = "mailUnqueue",
			rows = rows,
			enabled = true,
			label = ("Mail queued on %s (click to drop it)"):format(from),
		}
	end
	return {
		id = "mailQueue",
		rows = rows,
		enabled = true,
		label = ("Queue mail: %d reagent%s from %s"):format(n, n == 1 and "" or "s", from),
		tip = ("Keeps this list: on %s, at a mailbox, it becomes a filled mail to you."):format(from),
	}
end

-- Footer lines of the mail queued to this character: one per alt. rows: Alts.toMe's list.
function V.mailQueueLines(rows, env)
	local out, by, order = {}, {}, {}
	for _, e in ipairs(rows or {}) do
		if not by[e.alt] then
			by[e.alt] = {}
			order[#order + 1] = e.alt
		end
		local list = by[e.alt]
		list[#list + 1] = ("%d %s"):format(e.count, env.nameOf(e.item))
	end
	for _, alt in ipairs(order) do
		out[#out + 1] = ("Mail queue: %s sends %s"):format(alt, table.concat(by[alt], ", "))
	end
	return out
end

-- The panel beside the mailbox on an alt. groups: Alts.forAlt's list; live(item) -> { bags, bank, mail, stacks,
-- locked } (stacks: { { bag, slot, n } } in the bags, unlocked; locked: a stack of it is locked); state:
-- { pending = recipient, note = { text, tone }, combat, busy, free = empty bag slots }. Returns { title, groups =
-- { { to, title, rows, note, fill, drop } }, empty } with fill an action { id, to, enabled, label, picks }; picks:
-- what a click attaches, at most max: { bag, slot, n, take, item } with take < n on the one split of a row (pick:
-- Alts.planAttach). While a pick is a split, fill is the first step instead:
-- { id = "mailSplit", to, item, bag, slot, n, take }, a click that splits take into an empty bag slot.
function V.mailPanel(groups, live, state, env, pick, max)
	state = state or {}
	local out = { groups = {} }
	local items, total = 0, 0
	for _, g in ipairs(groups or {}) do
		local og = { to = g.to, rows = {} }
		local stacks, wantMore = {}, false
		local away, locked = nil, false
		for _, e in ipairs(g.rows) do
			local l = live(e.item) or {}
			locked = locked or l.locked == true
			local bags, bank, mail = l.bags or 0, l.bank or 0, l.mail or 0
			local row = { item = e.item, name = env.nameOf(e.item), count = e.count, color = "bone" }
			local picks = pick(l.stacks or {}, e.count, max)
			if bags >= e.count then
				row.right, row.tone = ("%d in bags"):format(e.count), "green"
				for _, s in ipairs(picks) do
					if s.take < s.n then
						row.right = ("%d in bags, split from %d"):format(e.count, s.n)
					end
				end
			elseif bags > 0 then
				local rest = bank > 0 and ("%d in bank"):format(math.min(bank, e.count - bags))
					or (mail > 0 and ("%d in mail"):format(math.min(mail, e.count - bags)))
				row.right = rest and ("%d in bags, %s"):format(bags, rest) or ("%d of %d in bags"):format(bags, e.count)
				row.tone = "bone"
			elseif bank > 0 then
				row.right, row.tone, row.color =
					("%d in bank: take them out"):format(math.min(bank, e.count)), "warn", "ash"
				away = away or "In the bank: take them out, then come back."
			elseif mail > 0 then
				row.right, row.tone, row.color =
					("%d in mail: open it first"):format(math.min(mail, e.count)), "warn", "ash"
				away = away or "In your mailbox: open that mail first."
			else
				row.right, row.tone, row.color = "none left here", "warn", "ash"
				away = away or ("Not on this character any more. Drop the list, or queue it again on %s."):format(g.to)
			end
			for _, s in ipairs(picks) do
				stacks[#stacks + 1] = { bag = s.bag, slot = s.slot, n = s.n, take = s.take, item = e.item }
			end
			items = items + 1
			og.rows[#og.rows + 1] = row
		end
		if #stacks > max then
			wantMore = true
		end
		local mailN = math.ceil(#stacks / max)
		local send = {}
		for k = 1, math.min(#stacks, max) do
			send[k] = stacks[k]
		end
		og.title = ("To %s: %d item%s"):format(g.to, #g.rows, #g.rows == 1 and "" or "s")
		local split
		for _, s in ipairs(send) do
			if s.take < s.n then
				split = split or s
			end
		end
		local fill = { id = "mailFill", to = g.to, picks = send, enabled = false }
		if state.combat then
			fill.label = "In combat"
		elseif state.pending == g.to then
			fill.label = "Now press Send"
		elseif state.pending then
			fill.label = "Wait: another mail is being filled"
		elseif locked then
			-- a split or move the server has not confirmed: the stacks read now are not the ones a click would use
			fill.label = "Wait: the bags are updating"
		elseif split then
			-- step 1 of 2: the split goes to an empty bag slot; the next draw picks it whole
			fill = {
				id = "mailSplit",
				to = g.to,
				item = split.item,
				bag = split.bag,
				slot = split.slot,
				n = split.n,
				take = split.take,
				enabled = (state.free or 0) > 0,
			}
			local name = env.nameOf(split.item)
			fill.label = fill.enabled and ("Split %d %s from %d"):format(split.take, name, split.n)
				or ("Free a bag slot to split %d %s"):format(split.take, name)
			fill.tip = "Step 1 of 2: puts exactly that many in an empty bag slot. Then Fill attaches them."
		elseif state.busy then
			fill.label = "Send Mail form is in use: clear it first"
		elseif #send == 0 then
			fill.label = ("Nothing in bags for %s"):format(g.to)
		else
			fill.enabled = true
			fill.label = wantMore and ("Fill mail 1 of %d to %s: %d attachments"):format(mailN, g.to, #send)
				or ("Fill mail to %s: %d attachment%s"):format(g.to, #send, #send == 1 and "" or "s")
		end
		og.fill = fill
		og.drop = {
			id = "mailDrop",
			to = g.to,
			enabled = true,
			label = "Drop",
			tip = ("Drops %s's list from this character's queue."):format(g.to),
		}
		if state.note and state.note.to == g.to then
			og.note = { text = state.note.text, tone = state.note.tone }
		elseif wantMore then
			og.note =
				{ text = "12 stacks fit in one mail. Send this one, then click again for the rest.", tone = "ash" }
		elseif away then
			og.note = { text = away, tone = "warn" }
		end
		total = total + 1
		out.groups[#out.groups + 1] = og
	end
	if #out.groups == 0 then
		out.title = "SkillupHelper: mail queue done"
		out.empty = "Nothing left to mail from this character."
	else
		out.title = ("SkillupHelper mail queue: %d item%s to %d character%s"):format(
			items,
			items == 1 and "" or "s",
			total,
			total == 1 and "" or "s"
		)
	end
	return out
end

-- The mailbox panel's groups split into pages that fit `room` px (nothing scrolls): a page break falls between
-- rows, a group carried over repeats its title (cont = true), and its note and buttons (h.tail) stay with its last
-- row. h = { title, row, tail = function(g) -> px }. Returns pages = { { { g, from, to, cont, tail } } }, every row
-- on exactly one page; a group's first chunk always holds at least one row (or its tail when it has none).
function V.mailPages(groups, room, h)
	local pages, page, y = {}, {}, 0
	local function turn()
		pages[#pages + 1] = page
		page, y = {}, 0
	end
	for _, g in ipairs(groups or {}) do
		local n, i, first = #(g.rows or {}), 1, true
		local tail = h.tail(g)
		while true do
			if y > 0 and y + h.title + (i <= n and h.row or tail) > room then
				turn()
			end
			y = y + h.title
			local from = i
			while i <= n and y + h.row + (i == n and tail or 0) <= room do
				y, i = y + h.row, i + 1
			end
			if i == from and i <= n then
				-- a page too short for one row and its buttons: the row goes anyway (never lost)
				y, i = y + h.row, i + 1
			end
			local done = i > n
			if done then
				y = y + tail
			end
			page[#page + 1] = { g = g, from = from, to = i - 1, cont = not first, tail = done }
			first = false
			if done then
				break
			end
			turn()
		end
	end
	if #page > 0 or #pages == 0 then
		pages[#pages + 1] = page
	end
	return pages
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
-- own: this character's counts the plan was built on (plan.have). A vendor or AH row is covered once the bags hold
-- its count more than that (bought, the replan not in yet); a block whose rows are all covered is `covered`.
function V.shoppingBlocks(shopping, env, own)
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
						if own and r.item and (r.count or 0) > 0 then
							local got = (env.have(r.item) or 0) - (own[r.item] or 0)
							row.covered = got >= r.count or nil
						end
					end
					b.rows[#b.rows + 1] = row
				end
				local covered = #b.rows > 0
				for _, row in ipairs(b.rows) do
					covered = covered and row.covered == true
				end
				b.covered = covered or nil
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

-- One line of "/skillup cost": what Planner.costToCap found for a profession. r = its result, or nil and why.
function V.costLine(name, from, to, r, env, why)
	local head = ("%s %d to %d"):format(tostring(name), from, to)
	if type(r) ~= "table" then
		return ("%s: no estimate (%s)"):format(head, tostring(why or "the planner failed"))
	end
	local parts = {}
	if r.trainingCost and r.trainingCost > 0 then
		parts[#parts + 1] = "training " .. env.money(r.trainingCost)
	end
	local n = #(r.recipesToBuy or {})
	if n > 0 then
		parts[#parts + 1] = ("%d recipe%s to buy"):format(n, n == 1 and "" or "s")
	end
	local unknown = r.unknownRecipePrices or 0
	if unknown > 0 then
		parts[#parts + 1] = ("%d recipe price%s unknown"):format(unknown, unknown == 1 and "" or "s")
	end
	local state = "complete"
	if #(r.gaps or {}) > 0 then
		local gaps = {}
		for _, g in ipairs(r.gaps) do
			gaps[#gaps + 1] = ("%d-%d"):format(math.floor(g.from), math.floor(g.to))
		end
		state = "nothing gives skill at " .. table.concat(gaps, ", ")
	end
	local missing = r.unknownPrices or 0
	return ("%s: %s%s; %s; %s"):format(
		head,
		env.money(r.total),
		#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "",
		state,
		missing == 0 and "every price from TSM"
			or ("%d price%s missing from TSM"):format(missing, missing == 1 and "" or "s")
	)
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

V.AH_ROWS = 5 -- rows the AH list shows at once: it pages, it never scrolls

-- The AH panel: { title, rows, all, empty, pager }. list: Logic.ahList; live[item]: V.ahRow's live. `all` is every
-- row (the frame keeps SkillupHelperDB.ahSkip in step with them); `rows` is the page shown, V.AH_ROWS at most, and
-- pager = { text = "1 to 5 of 21", prev, next } (actions `ahPage`) only when the list has more than one page.
function V.ahPanel(list, live, env, page)
	local d = { rows = {}, all = {} }
	local est = 0
	for _, r in ipairs(list or {}) do
		est = est + (r.each or 0) * r.count
		d.all[#d.all + 1] = V.ahRow(r, live and live[r.item], env)
	end
	if #d.all == 0 then
		d.title = "SkillupHelper: your AH list is empty"
		d.empty = "Add a list from the journal's Shopping page (Add to AH list)."
	else
		d.title = ("SkillupHelper AH list: %s, plan %s"):format(plural(#d.all, "item"), env.money(est))
	end
	local pg = V.page(#d.all, V.AH_ROWS, page)
	for k = pg.from, pg.to do
		d.rows[#d.rows + 1] = d.all[k]
	end
	d.page = pg.page
	if pg.text then
		d.pager = {
			text = pg.text,
			prev = { id = "ahPage", page = pg.page - 1, enabled = pg.page > 1, label = "Previous" },
			next = { id = "ahPage", page = pg.page + 1, enabled = pg.page < pg.pages, label = "Next" },
		}
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

-- The panel's height: `fixed` (what always shows) plus the optional pieces that fit under `limit` (the docked
-- window's height). Nothing scrolls and nothing is clipped: a piece that does not fit is left out whole, the last
-- one in `optional` first (its order is the order of importance), and the journal holds it. optional =
-- { { key, h } }. Returns { height, limit, content (everything, had it fitted), shown = { key = true }, dropped =
-- { keys }, overflow }: overflow is true only when even the fixed part is taller than the limit, which the layout
-- must never reach.
function V.fit(fixed, optional, limit)
	local content = fixed
	for _, o in ipairs(optional or {}) do
		content = content + o.h
	end
	local out = { limit = limit, content = content, shown = {}, dropped = {} }
	local total, last = content, #(optional or {})
	while total > limit and last >= 1 do
		total = total - optional[last].h
		table.insert(out.dropped, 1, optional[last].key)
		last = last - 1
	end
	for k = 1, last do
		out.shown[optional[k].key] = true
	end
	out.overflow = total > limit
	out.height = math.max(math.min(V.MIN_HEIGHT, limit), total)
	return out
end

-- One page of a list that may be longer than its box: { from, to, total, page, pages, text = "1 to 8 of 21" } and
-- nil for a list that fits on one page (no pager is drawn then).
function V.page(total, per, page)
	per = math.max(1, per)
	local pages = math.max(1, math.ceil(total / per))
	page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
	local from = (page - 1) * per + 1
	local to = math.min(total, page * per)
	local out = { from = from, to = to, total = total, page = page, pages = pages }
	if pages > 1 then
		out.text = ("%d to %d of %d"):format(from, to, total)
	end
	return out
end

------------------------------------------------------------------------------------------------- shopping and alts

-- The Alts tab: the reagents the plan takes from other characters (plan.mail { { who, item, count } }), one group
-- per character, each row with its queue state and a Queue / Queued button, and "Queue all" while any row is not
-- queued. incoming: the lines of mail already queued to this character (V.mailQueueLines).
-- Returns { title, groups = { { who, rows = { { item, name, count, right, tone, action } }, all } }, incoming, empty,
-- open } (open: rows not queued yet).
function V.altsView(mail, env)
	local out = { groups = {}, incoming = {}, open = 0 }
	local index, items, units = {}, 0, 0
	for _, e in ipairs(mail or {}) do
		local g = index[e.who]
		if not g then
			g = { who = e.who, rows = {}, rest = {} }
			index[e.who] = g
			out.groups[#out.groups + 1] = g
		end
		local queued = env.queued and env.queued(e.who, e.item, e.count) or false
		local part = { alt = e.who, item = e.item, count = e.count }
		local row = { item = e.item, name = env.nameOf(e.item), count = e.count }
		if queued then
			row.right, row.tone = ("%d, queued"):format(e.count), "green"
			row.action = {
				id = "mailUnqueue",
				rows = { part },
				enabled = true,
				label = "Queued",
				tip = "Click to drop it from the mail queue",
			}
		else
			row.right, row.tone = ("%d, not queued"):format(e.count), "gold"
			row.action = {
				id = "mailQueue",
				rows = { part },
				enabled = true,
				label = "Queue",
				tip = ("On %s, at a mailbox, this becomes a filled mail to you."):format(e.who),
			}
			g.rest[#g.rest + 1] = part
			out.open = out.open + 1
		end
		g.rows[#g.rows + 1] = row
		items, units = items + 1, units + e.count
	end
	for _, g in ipairs(out.groups) do
		if #g.rest > 0 then
			g.all = {
				id = "mailQueue",
				rows = g.rest,
				enabled = true,
				label = ("Queue all from %s"):format(g.who),
			}
		end
		g.rest = nil
	end
	out.incoming = V.mailQueueLines(env.mailQueue and env.mailQueue() or nil, env)
	if #out.groups == 0 then
		out.empty = "The plan takes nothing from your other characters."
	else
		out.title = ("Counted in the plan: %d reagent%s on %d character%s"):format(
			units,
			units == 1 and "" or "s",
			#out.groups,
			#out.groups == 1 and "" or "s"
		)
	end
	return out
end

-- What the plan pays trainers, as the Shopping tab's own line under the total (the same sum as "/skillup cost"):
-- "Training 5s 60c: 2 recipes, 1 rank (1 price unknown)". nil when the plan trains nothing.
function V.trainingLine(p, env)
	local t = ns.Planner and ns.Planner.trainingOf and ns.Planner.trainingOf(p)
	if not t or t.recipes + t.ranks == 0 then
		return nil
	end
	local parts = {}
	if t.recipes > 0 then
		parts[#parts + 1] = ("%d recipe%s"):format(t.recipes, t.recipes == 1 and "" or "s")
	end
	if t.ranks > 0 then
		parts[#parts + 1] = ("%d rank%s"):format(t.ranks, t.ranks == 1 and "" or "s")
	end
	return ("Training %s: %s%s"):format(
		env.money(t.total),
		table.concat(parts, ", "),
		t.unknown > 0 and (" (%d price%s unknown)"):format(t.unknown, t.unknown == 1 and "" or "s") or ""
	)
end

-- The Shopping tab's head line: "Total 3g 12s, 2 stops" (+ "N unknown").
local function shoppingTitle(blocks, env)
	local total, unknown = 0, 0
	for _, b in ipairs(blocks) do
		total = total + (b.total or 0)
		unknown = unknown + (b.unknown or 0)
	end
	return ("Total %s, %d stop%s%s"):format(
		env.money(total),
		#blocks,
		#blocks == 1 and "" or "s",
		unknown > 0 and (", %d price%s unknown"):format(unknown, unknown == 1 and "" or "s") or ""
	)
end

-- The card's link lines, one per journal page that holds more for this plan: { page, text, tone, tip, action }.
-- "Shopping: 1s 88c, 2 stops" opens the journal's Shopping page, "3 reagents on your other characters, not queued"
-- its Alts and mail page. A click never changes the panel.
local function cardLinks(d, profession)
	local out = {}
	local shop = d.shopping
	if shop.blocks and #shop.blocks > 0 then
		out[#out + 1] = {
			page = "shopping",
			tone = "gold",
			text = ("Shopping: %s"):format((shop.title:gsub("^Total ", ""))),
			tip = "Open the shopping list in the journal",
		}
	end
	local alts = d.alts
	if #alts.groups > 0 then
		local units = 0
		for _, g in ipairs(alts.groups) do
			for _, r in ipairs(g.rows) do
				units = units + r.count
			end
		end
		out[#out + 1] = {
			page = "alts",
			tone = alts.open > 0 and "gold" or "green",
			text = ("%s on your other characters, %s"):format(
				plural(units, "reagent"),
				alts.open > 0 and "not queued" or "queued"
			),
			tip = "Open Alts and mail in the journal",
		}
	end
	for k = #out, V.MAX_LINKS + 1, -1 do
		out[k] = nil
	end
	for _, l in ipairs(out) do
		l.action =
			{ id = "journal", page = l.page, profession = profession, enabled = true, label = l.text, tip = l.tip }
	end
	return out
end

--------------------------------------------------------------------------------------------- next lines and strip

-- The plan's lines (Where.lines) as the panel's short list: at most V.MAX_NEXT entries after the step on the card.
-- An entry is { kind = "line" | "rank" | "gap", n, title, meta, color, tone (of meta), tip, action }: the title
-- wraps to a second row and is never cut; meta is the range, the cost and "price unknown for 2 items" (names in the
-- tip). A rank training is its own entry before the line it unlocks. The line whose recipe the card is learning now
-- stays, as "Craft 43 Copper Dagger". Returns { entries, more (lines not shown), total (lines) }.
function V.nextLines(lines, p, env, profession)
	local out = { entries = {}, more = 0, total = #lines }
	local steps = p.steps or {}
	for _, line in ipairs(lines) do
		local rank = line.rank
		if rank and rank.step ~= 1 and steps[rank.step] and #out.entries < V.MAX_NEXT then
			out.entries[#out.entries + 1] = {
				kind = "rank",
				title = V.rankLine(steps[rank.step], env),
				color = "gold",
				action = { id = "journal", page = "path", profession = profession, step = line.step, enabled = true },
			}
		end
		if line.step ~= 1 then
			if #out.entries >= V.MAX_NEXT then
				out.more = out.more + 1
			else
				local e = { kind = line.kind == "gap" and "gap" or "line", n = line.n, color = line.color }
				e.title = line.title
				if line.learn and line.learn.step == 1 then
					-- the card is that unlock: what is left of the line is the crafting
					e.title = ("Craft %d %s"):format(line.crafts or 0, tostring(steps[line.step].name))
				end
				local meta = {}
				if line.kind == "gap" then
					meta[1] = upper1(line.why or "no recipe in the data gives skill here")
					e.tone = "warn"
				else
					if line.kind == "unlock" then
						meta[1] = ("at %d"):format(line.from or 0)
					else
						meta[1] = ("%d to %d"):format(line.from or 0, line.to or 0)
					end
					local learning = line.learn and line.learn.step == 1 and line.learn.cost or 0
					local cost = line.cost and (line.cost - learning) or nil
					if cost and cost > 0 then
						meta[#meta + 1] = env.money(cost)
					end
					local unpriced, tip = V.unpricedText(line.unpriced)
					meta[#meta + 1] = unpriced
					e.tip = tip
				end
				e.meta = table.concat(meta, ", ")
				e.action = { id = "journal", page = "path", profession = profession, step = line.step, enabled = true }
				out.entries[#out.entries + 1] = e
			end
		end
	end
	return out
end

-- The whole path as one strip: skill 1 to V.TOP_SKILL on the panel's width, every x a 0..1 fraction of it. A segment
-- per plan line in its colour, what is behind the skill as one dimmed segment, a hole as a `gap` segment (hatched in
-- the frame), anything the plan does not reach as `none`. The segments cover the whole strip in order, edge to edge.
-- Returns { lo, hi, segments = { { from, to, x0, x1, color, done, gap, none, tip, step } }, caps = { { at, x } },
-- now = { skill, x }, gaps, caption }.
function V.strip(lines, skill, env)
	local lo, hi = 1, V.TOP_SKILL
	local function x(v)
		return math.max(0, math.min(1, (v - lo) / (hi - lo)))
	end
	skill = math.max(lo, math.min(hi, math.floor(tonumber(skill) or lo)))
	local s = { lo = lo, hi = hi, segments = {}, caps = {}, now = { skill = skill, x = x(skill) }, gaps = 0 }
	local at = lo
	local function push(seg)
		seg.from, seg.to = math.max(seg.from, at), math.min(seg.to, hi)
		if seg.to <= seg.from then
			return
		end
		if seg.from > at then
			push({
				from = at,
				to = seg.from,
				color = "line",
				none = true,
				tip = ("No plan from %d to %d"):format(at, seg.from),
			})
		end
		seg.x0, seg.x1 = x(seg.from), x(seg.to)
		s.segments[#s.segments + 1] = seg
		at = seg.to
	end
	if skill > lo then
		push({ from = lo, to = skill, color = "ash", done = true, tip = ("Done: %d to %d"):format(lo, skill) })
	end
	local count = 0
	for _, line in ipairs(lines or {}) do
		if line.kind ~= "unlock" then
			count = count + 1
			local tip = ("%d. %s"):format(line.n, line.short or line.title)
			if line.kind == "gap" then
				s.gaps = s.gaps + 1
				tip = tip .. "\n" .. upper1(line.why or "no recipe in the data gives skill here")
			else
				local parts = {}
				if line.cost and line.cost > 0 then
					parts[1] = env.money(line.cost)
				end
				parts[#parts + 1] = V.unpricedText(line.unpriced)
				if #parts > 0 then
					tip = tip .. "\n" .. upper1(table.concat(parts, ", "))
				end
			end
			push({
				from = line.from,
				to = line.to,
				color = line.color,
				gap = line.kind == "gap" or nil,
				done = line.to <= skill or nil,
				tip = tip,
				step = line.step,
			})
		end
	end
	if at < hi then
		local from = at
		push({ from = from, to = hi, color = "line", none = true, tip = ("No plan from %d to %d"):format(from, hi) })
	end
	for _, cap in ipairs(V.RANK_CAPS) do
		s.caps[#s.caps + 1] = { at = cap, x = x(cap) }
	end
	s.caption = ("%s to %d"):format(plural(count, "step"), hi)
	if s.gaps > 0 then
		s.caption = ("%s, %s"):format(s.caption, plural(s.gaps, "gap"))
	end
	return s
end

-- The segment of a strip under x (0..1), or nil outside it.
function V.stripAt(strip, x)
	if type(strip) ~= "table" or type(x) ~= "number" or x < 0 or x > 1 then
		return nil
	end
	for _, seg in ipairs(strip.segments) do
		if x >= seg.x0 and x < seg.x1 then
			return seg
		end
	end
	return strip.segments[#strip.segments]
end

-- env: nameOf(item, fallback) -> string, money(copper) -> string, have(item) -> count; optional craftable(spell) ->
-- crafts the client allows now (nil and why when the recipe is not learned) and dock ("blizzard", "tsm", "free").
-- Returns { state, profession, skill, cap, header, runway, now, next, strip, journal, notice, message, empty,
-- shopping, alts, more }. The docked panel draws four things: `now` (the card of the step to do: title, sub, lines,
-- links, bar), `next` = { entries, more, total, why } (V.nextLines), `strip` (V.strip) and `journal` (the button's
-- action). shopping = { title, blocks, trip, stock, empty }, alts = V.altsView and more = { data, warn, empty } are
-- the journal's pages (Journal.lua reads them from the last description); the panel only links to them.
function V.describe(m, env)
	m = m or {}
	local listed -- the items on the shopping list: their mat rows say "on the list"
	if m.why and not m.skill then
		return {
			state = "message",
			message = m.why,
			tone = m.state == "not now" and "ash" or "warn",
			next = { entries = {}, more = 0, total = 0 },
			journal = { id = "journal", page = "overview", enabled = true, label = "Open the journal" },
		}
	end
	local profession = m.professionID
	local d = {
		state = "plan",
		profession = m.profession,
		skill = m.skill,
		cap = m.maxSkill,
		header = { title = m.profession or "?", skill = ("%d / %d"):format(m.skill or 0, m.maxSkill or 0) },
		next = { entries = {}, more = 0, total = 0 },
		notice = m.why,
		shopping = { stock = {} },
		more = { data = {} },
		journal = {
			id = "journal",
			page = "path",
			profession = profession,
			step = 1,
			enabled = true,
			label = "Open the journal",
			tip = "The whole path, the shopping list, alts and mail, and the settings",
		},
	}
	local p = m.planner
	if p then
		d.header.stale = staleLine(p)
		local shop = V.shoppingBlocks(p.shopping, env, p.have)
		if shop then
			listed = {}
			for _, place in ipairs({ "vendor", "ah" }) do
				for _, r in ipairs(p.shopping[place] or {}) do
					listed[r.item or false] = true
				end
			end
		end
		d.now = p.steps[1] and cardFace(nextCard(p.steps[1], env, listed), p.steps[1], env)
		local saved = env.savedTrip and env.savedTrip(p.profKey)
		local cb = V.capBlockLine(p.capBlock)
		if cb then
			d.capBlock = cb
			d.notice = d.notice and (cb .. "\n" .. d.notice) or cb
		end
		local sh = d.shopping
		if d.now and shop then
			-- one block per place in travel order, on the Shopping page; the AH block is also what "Add to AH list" keeps
			sh.blocks = shop
			-- the list "Add to AH list" keeps: plan.trip when the trip starts now (as before), else the AH block
			if p.trip and p.trip.fromStep == 1 then
				d.now.trip = V.tripBlock(p.trip, env, saved)
			elseif not p.trip then
				d.now.trip = V.shoppingTrip(p, env, saved)
			end
			if d.now.trip then
				d.now.trip.prof = p.profKey
			end
		elseif d.now and p.trip and p.trip.fromStep == 1 then
			d.now.trip = V.tripBlock(p.trip, env, saved)
			if d.now.trip then
				d.now.trip.prof = p.profKey
				sh.blocks = { d.now.trip }
			end
		elseif p.trip and not shop then
			sh.tripLine = ("AH trip at step %d: %s, covers to %d"):format(
				p.trip.fromStep,
				env.money(p.trip.total),
				math.floor(p.trip.to or 0)
			)
		end
		-- the plan as lines (Where.lines): the next few under the card, all of them on the strip
		if ns.Where and ns.Where.lines then
			local lines = ns.Where.lines(p.steps, { nameOf = env.nameOf })
			d.next = V.nextLines(lines, p, env, profession)
			d.strip = V.strip(lines, m.skill, env)
		else
			d.next.why = "Where.lua is not loaded: the next lines and the path strip are not drawn"
		end
		sh.stock = stockLines(p, env)
		sh.training = V.trainingLine(p, env)
		local data = d.more.data
		local cov = p.coverage and p.coverage.to
		if type(cov) == "number" and (not m.maxSkill or cov < m.maxSkill) then
			data[#data + 1] = ("The recipe data covers to %d"):format(cov)
		end
		for _, line in ipairs(V.routeLines(p)) do
			data[#data + 1] = line
		end
		-- "Visit your trainer once": something to act on
		d.more.warn = p.unconfirmed ~= nil and p.unconfirmed > 0 or nil
		d.alts = V.altsView(p.mail, env)
		if not d.now then
			d.empty = V.atCapLine(m) or "Nothing gives skill in range: every known recipe is grey."
		end
	else
		d.state = "legacy"
		d.notice = d.notice or m.plannerWhy or m.planWhy
		d.now = legacyCard(m, env)
		for _, e in ipairs(m.fromStock or {}) do
			local crafts = e.crafts == math.huge and "vendor mats" or ("x%d"):format(e.crafts)
			if #d.next.entries < V.MAX_NEXT then
				d.next.entries[#d.next.entries + 1] =
					{ kind = "line", color = e.color, title = ("%s %s, from stock"):format(e.name, crafts) }
			else
				d.next.more = d.next.more + 1
			end
		end
		d.next.total = #d.next.entries + d.next.more
		for _, b in ipairs(m.buyRecipes or {}) do
			d.shopping.stock[#d.shopping.stock + 1] = ("Worth buying: %s, %s, for %d to %d"):format(
				b.itemName or env.nameOf(b.item, b.recipe),
				env.money(b.price),
				b.from,
				b.to
			)
		end
		if not d.now then
			d.empty = "No plan step for this skill."
		end
	end
	d.alts = d.alts or V.altsView(nil, env)
	local sh = d.shopping
	if sh.blocks then
		sh.title = shoppingTitle(sh.blocks, env)
	elseif #sh.stock == 0 and not sh.tripLine then
		sh.empty = "Nothing to buy: the bags and bank cover the plan."
	end
	if #d.more.data == 0 then
		d.more.empty = "Nothing to report about the plan's data."
	end
	local nx = d.now
	if nx and nx.kind == "craft" and nx.thresholds then
		d.runway = V.colourTarget(m.skill, nx.thresholds[1], nx.thresholds[2])
	end
	if nx then
		-- actions read every reagent, whatever the card's lines show of them
		nx.actions, nx.actionsWhy = V.actions(nx, env)
		-- "Add to AH list" sits on the journal's Shopping page, over the blocks it keeps
		sh.trip = V.tripAction(nx.trip)
		local ma = V.mailAction(nx)
		if ma then
			nx.actions = nx.actions or {}
			table.insert(nx.actions, 1, ma)
		end
		nx.links = cardLinks(d, profession)
		nx.bar = V.actionBar(nx)
		-- Journal.lua's minimap tip still reads the card as `next.name` and `next.verb` (the description's old
		-- shape): these two fields keep it speaking until it reads `now.title` and `now.sub`
		d.next.name, d.next.verb = nx.name, nx.verb
	end
	if d.next.more > 0 then
		d.journal.label = ("Open the journal: %s"):format(plural(d.next.more, "more step"))
	end
	return d
end

-- The action bar under the card: rows of the card's actions, { { mail }, { buy }, { craft, open } } with the empty
-- rows left out. nil when the card has no action.
function V.actionBar(card)
	local by = {}
	for _, a in ipairs(card.actions or {}) do
		by[a.id] = by[a.id] or a
	end
	local rows = {}
	local mail = by.mailQueue or by.mailUnqueue
	if mail then
		rows[#rows + 1] = { mail }
	end
	if by.buy then
		rows[#rows + 1] = { by.buy }
	end
	local last = {}
	last[#last + 1] = by.craft
	last[#last + 1] = by.open
	if #last > 0 then
		rows[#rows + 1] = last
	end
	return #rows > 0 and rows or nil
end

-- A collapsible section head: { kind = "head", key, text, collapsed, action }. The state is saved per account
-- (SkillupHelperDB.ui.collapsed[key]); `fallback` is the state of a section the user never touched.
local function section(out, key, text, collapsed, color, fallback)
	local c = collapsed and collapsed[key]
	if c == nil then
		c = fallback or false
	end
	out[#out + 1] = {
		kind = "head",
		key = key,
		text = text,
		color = color,
		collapsed = c,
		action = { id = "section", key = key, collapsed = c, enabled = true, label = text },
	}
	return c
end

-- The Shopping tab as list items: the total and the trip button, a section per place and city, then Stock (folded
-- until opened). collapsed: SkillupHelperDB.ui.collapsed.
function V.shoppingItems(s, collapsed)
	local out = {}
	if s.title then
		out[#out + 1] = { kind = "line", text = s.title, color = "bone", size = 12 }
	end
	if s.training then
		out[#out + 1] = { kind = "line", text = s.training }
	end
	if s.tripLine then
		out[#out + 1] = { kind = "line", text = s.tripLine }
	end
	if s.trip then
		out[#out + 1] = { kind = "button", action = s.trip, accent = s.trip.id == "trip" and "gold" or "ash" }
	end
	for _, b in ipairs(s.blocks or {}) do
		out[#out + 1] = { kind = "gap", h = 6 }
		local key = ("shop:%s:%s"):format(tostring(b.place or "trip"), tostring(b.city or ""))
		-- a block the bags already cover folds itself (until the user opens it)
		if not section(out, key, b.covered and (b.title .. ", covered") or b.title, collapsed, nil, b.covered) then
			for _, r in ipairs(b.rows) do
				local tone = r.covered and "green" or nil
				out[#out + 1] = { kind = "row", name = r.name, right = r.right, mark = tone or "gold", tone = tone }
			end
		end
	end
	if #(s.stock or {}) > 0 then
		out[#out + 1] = { kind = "gap", h = 10 }
		if not section(out, "stock", ("Stock (%d)"):format(#s.stock), collapsed, "ash", true) then
			for _, line in ipairs(s.stock) do
				out[#out + 1] = { kind = "line", text = line, size = 10 }
			end
		end
	end
	if s.empty then
		out[#out + 1] = { kind = "line", text = s.empty }
	end
	return out
end

-- The Alts tab: a section per character, a row per reagent with Queue / Queued, Queue all; then the mail queued to
-- you. Queue all stays visible under a folded character.
function V.altsItems(a, collapsed)
	local out = {}
	if a.title then
		out[#out + 1] = { kind = "line", text = a.title, color = "bone", size = 12 }
	end
	for _, g in ipairs(a.groups) do
		out[#out + 1] = { kind = "gap", h = 6 }
		local text = ("%s (%d)"):format(g.who, #g.rows)
		if not section(out, "alt:" .. tostring(g.who), text, collapsed) then
			for _, r in ipairs(g.rows) do
				out[#out + 1] = { kind = "row", name = r.name, right = r.right, tone = r.tone, action = r.action }
			end
		end
		if g.all then
			out[#out + 1] = { kind = "button", action = g.all, accent = "gold" }
		end
	end
	if #a.incoming > 0 then
		out[#out + 1] = { kind = "gap", h = 10 }
		local text = ("In the mail queue (%d)"):format(#a.incoming)
		if not section(out, "incoming", text, collapsed, "ash") then
			for _, line in ipairs(a.incoming) do
				out[#out + 1] = { kind = "line", text = line, size = 10 }
			end
		end
	end
	if a.empty then
		out[#out + 1] = { kind = "line", text = a.empty }
	end
	return out
end

local function setting(key, value, label, extra)
	local a = { id = "setting", key = key, value = value, enabled = true, label = label }
	for k, v in pairs(extra or {}) do
		a[k] = v
	end
	return a
end

local function check(out, text, on, key, value, tip)
	out[#out + 1] =
		{ kind = "check", text = text, on = on and true or false, action = setting(key, value, text), tip = tip }
end

-- A spell id's list as rows sorted by name, each with one button.
local function spellRows(out, set, env, label, key, tip)
	local list = {}
	for id, on in pairs(set or {}) do
		if on and type(id) == "number" then
			list[#list + 1] = { id = id, name = env.spellName and env.spellName(id) or ("spell " .. id) }
		end
	end
	table.sort(list, function(a, b)
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.id < b.id
	end)
	for _, e in ipairs(list) do
		out[#out + 1] = {
			kind = "row",
			name = e.name,
			mark = "gold",
			action = setting(key, nil, label, { spell = e.id, tip = tip }),
		}
	end
	return #list
end

local function countSet(set)
	local n = 0
	for id, on in pairs(set or {}) do
		if on and type(id) == "number" then
			n = n + 1
		end
	end
	return n
end

-- The More tab as list items: Planner (luck dropdown, effort stepper, two checkboxes), Recipe sources, Shortcuts in
-- use (Stop using), Hidden recipes (Offer again), then the Data lines. s: ns.settingsView(); env: money, spellName.
-- Every control is an action { id = "setting", key, value, spell } for Logic.applySetting.
function V.moreItems(more, s, env, collapsed)
	local out = {}
	s = s or {}
	if not section(out, "more:planner", "Planner", collapsed) then
		-- the planner's own defaults (Planner.LUCK, Planner.EFFORT), so the controls never drift from them
		local P = ns.Planner or {}
		local defaultLuck = P.LUCK or 90
		local luck = s.luck or defaultLuck
		local radios = {}
		for _, l in ipairs(ns.Logic.LUCKS) do
			radios[#radios + 1] = {
				label = ("%d%%%s"):format(l, l == defaultLuck and " (default)" or ""),
				checked = l == luck,
				action = setting("luck", l, ("Buy for bad luck: %d%%"):format(l)),
			}
		end
		out[#out + 1] = {
			kind = "choice",
			text = "Buy for bad luck",
			value = ("%d%%"):format(luck),
			menu = { title = "Buys cover this share of runs", items = radios },
			tip = "How unlucky a run of crafts the buys cover. 90%: nine runs in ten need no second trip.",
		}
		local effort = s.effort or s.defaultEffort or P.EFFORT or 20
		local down, up = ns.Logic.effortStep(effort, -1), ns.Logic.effortStep(effort, 1)
		local function word(c)
			return c == 0 and "none" or env.money(c)
		end
		out[#out + 1] = {
			kind = "stepper",
			text = "Effort per craft",
			value = word(effort) .. (s.effort == nil and " (default)" or ""),
			dec = setting("effort", down, "Less effort", { enabled = down ~= nil }),
			inc = setting("effort", up, "More effort", { enabled = up ~= nil }),
			tip = "What one craft's time is worth to you: the plan adds it to every craft, so it favours fewer crafts.",
		}
		check(
			out,
			"Suggest recipes to buy",
			not s.noRecipeBuys,
			"noRecipeBuys",
			not s.noRecipeBuys,
			"Off: the plan uses only the recipes you know and the trainer's."
		)
		check(
			out,
			"Count reagents on my other characters",
			not s.noAlts,
			"noAlts",
			not s.noAlts,
			"From TSM's inventory of your alts. Off: the plan counts this character's bags and bank only."
		)
		check(
			out,
			"Count selling what I craft",
			s.resale == true,
			"resale",
			not s.resale,
			"On: what the products sell for lowers a recipe's cost. Off: recipes are ranked by what you pay."
		)
	end
	out[#out + 1] = { kind = "gap", h = 8 }
	if not section(out, "more:sources", "Recipe sources", collapsed) then
		check(out, "Dungeon patterns", not s.dungeon, "dungeon", not s.dungeon, "Recipes that drop in dungeons.")
		check(
			out,
			"AH patterns",
			not s.ahPatterns,
			"ahPatterns",
			not s.ahPatterns,
			"Recipes bought on the auction house."
		)
		-- on: exclude.special = false plans them; off: nil leaves them out (the default)
		local specialOn = s.special == false
		local special = nil
		if not specialOn then
			special = false
		end
		check(
			out,
			"Special teachers (dungeon or special NPC)",
			specialOn,
			"special",
			special,
			"Off by default: these teachers are hard to reach."
		)
	end
	out[#out + 1] = { kind = "gap", h = 8 }
	local nAllow = countSet(s.allow)
	if not section(out, "more:allow", ("Shortcuts in use (%d)"):format(nAllow), collapsed) then
		if nAllow == 0 then
			out[#out + 1] =
				{ kind = "line", text = "None. A shortcut's Use it in the Way menu adds it here.", size = 10 }
		else
			spellRows(
				out,
				s.allow,
				env,
				"Stop using",
				"allow",
				"The plan stops using this recipe (offered as a shortcut again)"
			)
		end
	end
	local nHidden = countSet(s.notNow)
	out[#out + 1] = { kind = "gap", h = 8 }
	if not section(out, "more:hidden", ("Hidden recipes (%d)"):format(nHidden), collapsed) then
		if nHidden == 0 then
			out[#out + 1] = { kind = "line", text = "None. A shortcut's Hide puts it here.", size = 10 }
		else
			spellRows(out, s.notNow, env, "Offer again", "notNow", "The plan may offer this recipe again")
		end
	end
	more = more or { data = {} }
	if #more.data > 0 then
		out[#out + 1] = { kind = "gap", h = 8 }
		if not section(out, "more:data", "Data", collapsed, "ash") then
			for _, line in ipairs(more.data) do
				local act = line:find("^Visit your trainer once") ~= nil
				out[#out + 1] = { kind = "line", text = line, color = act and "warn" or nil }
			end
		end
	end
	return out
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
	if d.strip then
		add(d.strip.caption)
	end
	if d.runway then
		add(d.runway.label)
	end
	add(d.header.stale)
	add(d.notice)
	local nx = d.now
	if nx then
		add(nx.title)
		add(nx.sub)
		for _, l in ipairs(nx.lines or {}) do
			add(l.text)
		end
		for _, l in ipairs(nx.links or {}) do
			add(("[%s]"):format(l.text))
		end
		for _, a in ipairs(nx.actions or {}) do
			add(("[%s]%s"):format(a.label, a.enabled and "" or " (not yet)"))
		end
	end
	add(d.empty)
	if #d.next.entries > 0 then
		add("-- Next")
	end
	for _, e in ipairs(d.next.entries) do
		add((e.n and (e.n .. ". ") or "") .. e.title .. ((e.meta and e.meta ~= "") and (" (" .. e.meta .. ")") or ""))
	end
	add(d.next.why)
	add(("[%s]"):format(d.journal.label))
	local sh = d.shopping or {}
	add("-- Shopping")
	add(sh.title)
	add(sh.tripLine)
	if sh.trip then
		add(("[%s]"):format(sh.trip.label))
	end
	for _, b in ipairs(sh.blocks or {}) do
		add(b.title)
		for _, r in ipairs(b.rows) do
			add(("  %s %s"):format(r.name, r.right))
		end
	end
	for _, s in ipairs(sh.stock or {}) do
		add(s)
	end
	add(sh.empty)
	local alts = d.alts or { groups = {}, incoming = {} }
	add("-- Alts")
	add(alts.title)
	for _, g in ipairs(alts.groups) do
		add(g.who)
		for _, r in ipairs(g.rows) do
			add(("  %s %s [%s]"):format(r.name, r.right, r.action.label))
		end
		if g.all then
			add(("[%s]"):format(g.all.label))
		end
	end
	for _, s in ipairs(alts.incoming) do
		add(s)
	end
	add(alts.empty)
	add("-- More")
	for _, s in ipairs(d.more and d.more.data or {}) do
		add(s)
	end
	add(d.more and d.more.empty)
	return out
end
