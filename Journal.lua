-- The journal's provider and the wiring of the new surfaces (journal, field card, tracker, compartment, key binding,
-- the docked panel's open-journal button and where-card) to the planner, Skills and Where. Loaded after Core.lua.
-- Every entry runs under pcall (P.run) and records its first error for the selftest, so a failure here never
-- reaches the docked panel. No frame is built at login: the journal, the card and the tracker are made on first use.
local _, ns = ...
local P = {}
ns.Provider = P

local WORLD = { [633] = true, [186] = true, [182] = true, [393] = true, [356] = true }
local GATHERING = { 186, 182, 393, 356 }
local LOCKPICKING = 633
-- items whose TSM price says whether TradeSkillMaster has any auction data yet (Linen Cloth, Copper Ore, Peacebloom)
local PRICE_PROBES = { 2589, 2770, 2447 }

P.TEXT = {
	noPrices = "TradeSkillMaster has no auction prices yet: costs count vendor items only and list the rest as "
		.. "missing prices. Let the TSM desktop app sync, or scan the auction house once in TSM, then reopen this window.",
	noTSM = "TradeSkillMaster is not loaded: costs count vendor items only and list the rest as missing prices.",
	costing = "working out the cost (a moment)",
	firstRun = "SkillupHelper %s: the journal shows every profession, what levelling it costs and where to go. "
		.. "Open it with the button on the profession panel, the addon menu by the minimap, or /skillup journal.",
	notNowShopping = "Open your %s window once: the shopping list is made from your bags, bank and the plan.",
	noShoppingWorld = "%s needs no shopping: it is levelled in the world. The Where page shows where.",
	noAlts = "Open a profession window: the plan then says which reagents your other characters hold.",
	craftWhere = "%s is levelled at a crafting window, not out in the world. Pick a gathering skill or "
		.. "Lockpicking in the list at the top to see where to go.",
	noProfession = "This character has no profession yet. Any trainer in a capital teaches one; the Overview "
		.. "shows what each costs to level to 300.",
	minimapHidden = "SkillupHelper: minimap button hidden. /skillup minimap brings it back, and so does "
		.. "the journal's Settings page (Show the minimap button).",
	minimapNothing = "Nothing tracked. Left-click opens the journal.",
	minimapHint = "Left-click: journal. Right-click: menu. Drag: move.",
	minimapSecret = "The current step's text is hidden here (protected by the game).",
}

P.diag = { errors = {}, firstError = nil, costRuns = 0, costMs = 0, costMaxMs = 0, costQueued = 0 }

local function record(where, err)
	local line = tostring(err):match("^[^\n]*")
	P.diag.errors[where] = line
	P.diag.firstError = P.diag.firstError or (where .. ": " .. line)
end

-- Runs fn under pcall: a failure is recorded (selftest.journalWiring) and nil returned, never raised.
function P.run(where, fn, ...)
	local ok, a, b = pcall(fn, ...)
	if not ok then
		record(where, a)
		return nil
	end
	return a, b
end

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v) == true
end

local function clean(v)
	if v == nil or secret(v) then
		return nil
	end
	return v
end

------------------------------------------------------------------------------------------------------------- state

local function db()
	return type(SkillupHelperDB) == "table" and SkillupHelperDB or nil
end

-- SkillupHelperDB.ui: the journal's, the field card's and the tracker's saved state (JournalUI.setState).
local fallbackUI = {}
function P.ui()
	local d = db()
	if not d then
		return fallbackUI
	end
	d.ui = type(d.ui) == "table" and d.ui or {}
	return d.ui
end

-- The character's key for per-character choices (the tracked spot): its GUID, never a name.
local function charKey()
	local g = UnitGUID and clean(UnitGUID("player")) or nil
	return type(g) == "string" and g or "player"
end

-- { line, spot } tracked by this character, or nil.
function P.tracked()
	local ui = P.ui()
	local t = type(ui.track) == "table" and ui.track[charKey()] or nil
	return type(t) == "table" and t.spot and t or nil
end

local function setTracked(line, spot)
	local ui = P.ui()
	ui.track = type(ui.track) == "table" and ui.track or {}
	ui.track[charKey()] = spot and { line = line, spot = spot } or nil
end

---------------------------------------------------------------------------------------------------------- the client

local function playerFacts()
	local level = UnitLevel and clean(UnitLevel("player")) or nil
	local class = UnitClassBase and clean(UnitClassBase("player")) or nil
	local faction = ns.Scan and ns.Scan.faction and ns.Scan.faction() or nil
	return type(level) == "number" and level or nil, type(class) == "string" and class or nil, faction
end

-- The player's position on their best map, normalised, or nil and why.
local function hereNow()
	if not (C_Map and C_Map.GetBestMapForUnit) then
		return nil, "C_Map.GetBestMapForUnit is absent"
	end
	local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
	map = ok and clean(map) or nil
	if type(map) ~= "number" then
		return nil, "map unknown here"
	end
	if not (ns.MapCanvas and ns.MapCanvas.position) then
		return nil, "MapCanvas.lua did not load"
	end
	local pos, why = ns.MapCanvas.position(map)
	if type(pos) ~= "table" or not pos.x then
		return nil, why or "position unknown"
	end
	return { map = map, x = pos.x, y = pos.y, facing = pos.facing }
end

-- Whether TradeSkillMaster has any auction price: { ok, text } (text is the plain-words status when it has none).
function P.prices()
	if type(TSM_API) ~= "table" then
		return { ok = false, text = P.TEXT.noTSM, why = "TSM_API missing" }
	end
	local why
	for _, item in ipairs(PRICE_PROBES) do
		local v, w = ns.TSM.value("dbmarket", item)
		v = v or ns.TSM.value("dbminbuyout", item)
		if v then
			return { ok = true, text = "TSM prices: live" }
		end
		why = why or w
	end
	return { ok = false, text = P.TEXT.noPrices, why = why }
end

------------------------------------------------------------------------------------------------------- the snapshot

-- What every page of one refresh reads: skills of every line, the character, the data. Built once per refresh.
function P.snapshot()
	local level, class, faction = playerFacts()
	local s = { level = level, class = class, faction = faction }
	s.plan = ns.plan and ns.plan() or nil
	s.spots = ns.Data and ns.Data.spots or nil
	s.skills = {}
	if ns.Skills then
		local lines = ns.Skills.lines()
		s.skills = ns.Skills.all(lines, ns.Skills.env())
	end
	s.here, s.hereWhy = hereNow()
	s.prices = P.prices()
	P.snap = s
	return s
end

-- The profession the journal shows when none is chosen: the docked panel's, else Lockpicking for a rogue, else a
-- gathering skill the character has, else any learned profession, else nil.
function P.defaultProfession(s)
	s = s or P.snap or {}
	local sk = s.skills or {}
	if ns.tradeSkillOpen and ns.UI and type(ns.UI.model) == "table" then
		local line = clean(ns.UI.model.professionID)
		if type(line) == "number" then
			return line
		end
	end
	local t = P.tracked()
	if t and t.line then
		return t.line
	end
	if s.class == "ROGUE" and sk[LOCKPICKING] and sk[LOCKPICKING].available ~= false then
		return LOCKPICKING
	end
	for _, line in ipairs(GATHERING) do
		if sk[line] and sk[line].rank then
			return line
		end
	end
	local best
	for line, r in pairs(sk) do
		if r.rank and not WORLD[line] and (not best or line < best) then
			best = line
		end
	end
	return best
end

local function nameOf(line, s)
	s = s or P.snap or {}
	local def = s.spots and s.spots.skills and s.spots.skills[line]
	local prof = s.plan and s.plan.professions and s.plan.professions[line]
	return (def and def.name) or (prof and prof.name) or ("Skill " .. tostring(line))
end

local function itemName(item)
	if ns.Scan and ns.Scan.itemName then
		local ok, n = pcall(ns.Scan.itemName, item)
		if ok and type(n) == "string" then
			return n
		end
	end
	return "item " .. tostring(item)
end

---------------------------------------------------------------------------------------------------------- the costs

-- Planner.costToCap runs, one profession per frame, cached until a setting or a skill changes.
local costCache, costQueue, costBusy = {}, {}, false
P.sync = false -- the tests cost in place

function P.invalidate()
	costCache = {}
	P.whereCache = {}
end

local function costKey(line, from)
	return tostring(line) .. ":" .. tostring(from)
end

local function costNow(line, prof, from)
	local plan = P.snap and P.snap.plan or (ns.plan and ns.plan())
	if not plan or not prof then
		return nil, "no recipe data for this profession"
	end
	local own = { skill = from, cap = nil }
	local sk = P.snap and P.snap.skills and P.snap.skills[line]
	own.cap = sk and sk.cap or nil
	local t0 = debugprofilestop and debugprofilestop() or nil
	local settings = ns.settings and ns.settings() or {}
	local r, _, _, why = ns.Scan.costOf(plan, line, prof, from > 1 and own or nil, settings)
	if t0 then
		local ms = debugprofilestop() - t0
		P.diag.costMs = P.diag.costMs + ms
		P.diag.costMaxMs = math.max(P.diag.costMaxMs, ms)
	end
	P.diag.costRuns = P.diag.costRuns + 1
	costCache[costKey(line, from)] = { r = r, why = why }
	return r, why
end

local function drain()
	local job = table.remove(costQueue, 1)
	if not job then
		costBusy = false
		if ns.JournalUI then
			P.run("refresh", ns.JournalUI.refresh)
		end
		return
	end
	if not costCache[costKey(job.line, job.from)] then
		P.run("cost", costNow, job.line, job.prof, job.from)
	end
	C_Timer.After(0, drain)
end

-- The overview's cost function: the cached result, or nil and "working out the cost" while it is queued.
function P.costOf(line, prof, from)
	from = from or 1
	local c = costCache[costKey(line, from)]
	if c then
		return c.r, c.why
	end
	if P.sync or not (C_Timer and C_Timer.After) then
		return costNow(line, prof, from)
	end
	for _, j in ipairs(costQueue) do
		if j.line == line and j.from == from then
			return nil, P.TEXT.costing
		end
	end
	costQueue[#costQueue + 1] = { line = line, prof = prof, from = from }
	P.diag.costQueued = P.diag.costQueued + 1
	if not costBusy then
		costBusy = true
		C_Timer.After(0, drain)
	end
	return nil, P.TEXT.costing
end

------------------------------------------------------------------------------------------------------------- pages

local function money(c)
	return ns.Logic.money(c)
end

function P.overview(s)
	s = s or P.snap or P.snapshot()
	local ov = ns.Where.overview({
		professions = s.plan and s.plan.professions or {},
		data = s.spots,
		skills = s.skills,
		costFn = function(line, prof, from)
			return P.costOf(line, prof, from)
		end,
		level = s.level,
		faction = s.faction,
		class = s.class,
		money = money,
		nameOf = itemName,
		priceAge = s.prices.ok and "live" or "no live prices",
	})
	local any = false
	for _, row in ipairs(ov.rows) do
		row.group = row.group or (WORLD[row.key] and "gathering" or "crafting")
		any = any or row.learned
	end
	if not any then
		ov.notice = P.TEXT.noProfession
	end
	if not s.prices.ok then
		ov.notice = ov.notice and (ov.notice .. " " .. s.prices.text) or s.prices.text
	end
	return ov
end

local function query(line, s, selected)
	local sk = s.skills[line] or {}
	return ns.Where.query({
		data = s.spots,
		line = line,
		skill = sk.rank,
		cap = sk.cap,
		level = s.level,
		faction = s.faction,
		class = s.class,
		here = s.here,
		hereWhy = s.hereWhy,
		selected = selected,
		money = money,
	})
end

-- The Path page of a world skill as the path page's step rows and timeline segments.
local function worldPathPage(line, s)
	local wp = ns.Where.worldPath(query(line, s))
	local sk = s.skills[line] or {}
	local prof = s.plan and s.plan.professions and s.plan.professions[line]
	local p = {
		profession = wp.profession,
		skill = sk.rank or 1,
		caps = {},
		gates = {},
		segments = {},
		markers = {},
		rows = {},
	}
	for _, rk in ipairs(prof and prof.ranks or {}) do
		if type(rk.cap) == "number" then
			p.caps[#p.caps + 1] = { at = rk.cap, label = ("%s %d"):format(tostring(rk.name or "Rank"), rk.cap) }
		end
	end
	local spots = {}
	for i, r in ipairs(wp.rows) do
		local gap = r.state == "gap"
		p.segments[#p.segments + 1] = {
			step = i,
			from = r.from,
			to = r.to,
			name = r.title,
			done = r.state == "done",
			gap = gap and { reason = r.sub } or nil,
		}
		spots[i] = r.action and r.action.spot or nil
		local sub = r.sub or ""
		p.rows[#p.rows + 1] = {
			n = i,
			step = i,
			kind = gap and "gap" or "step",
			title = r.title,
			sub = sub,
			subFull = sub,
			from = r.from,
			to = r.to,
			range = ("%d to %d"):format(r.from, r.to),
			rangeTone = gap and "warn" or (r.state == "now" and "bone" or "ash"),
			done = r.state == "done",
			tip = { r.title, sub ~= "" and sub or nil },
			action = { id = "selectStep", step = i, enabled = true },
		}
	end
	if #p.rows == 0 then
		p.empty = { title = "No route", text = wp.text or ("No %s spot in the data."):format(wp.profession) }
		return p
	end
	ns.Where.pathSelect(p, { selected = P.selectedStep, stretch = P.selectedStretch })
	for _, row in ipairs(p.rows) do
		if row.selected then
			local spot = spots[row.n]
			local d = { title = row.title, n = row.n, color = row.rangeTone, dothis = {}, materials = {}, actions = {} }
			d.dothis[1] = { text = ("Skill %s."):format(row.range), tone = row.rangeTone }
			if row.sub ~= "" then
				d.dothis[2] = { text = row.sub, tone = row.kind == "gap" and "warn" or "ash" }
			end
			d.actions[1] = {
				id = "selectSpot",
				key = spot,
				page = "where",
				label = "Open in Where",
				enabled = spot ~= nil,
				tip = spot == nil and "No spot is mapped for this part." or nil,
			}
			p.detail = d
		end
	end
	return p
end

-- What the bags hold of an item, for the Path page's materials. The scan can fail (no item data yet): the count is
-- then nil and the first failure is kept for the selftest.
function P.have(item)
	if not (ns.Scan and ns.Scan.have) then
		return nil
	end
	local ok, n = pcall(ns.Scan.have, item)
	if not ok then
		P.diag.haveWhy = P.diag.haveWhy or tostring(n):match("^[^\n]*")
		return nil
	end
	return n
end

local function craftPathPage(line, s)
	local prof = s.plan and s.plan.professions and s.plan.professions[line]
	if not prof then
		return {
			empty = {
				title = "No recipe data",
				text = ("The shipped data has no recipes for %s."):format(nameOf(line, s)),
			},
		}
	end
	local sk = s.skills[line] or {}
	local from = sk.rank or 1
	local r, why = P.costOf(line, prof, from)
	if type(r) ~= "table" then
		return {
			empty = {
				title = why == P.TEXT.costing and "Working out the plan" or "No plan yet",
				text = why == P.TEXT.costing and "The planner is costing this profession. The page fills in a moment."
					or ("The planner gave no plan from %d: %s."):format(from, tostring(why or "no result")),
			},
		}
	end
	return ns.Where.path({
		profession = prof.name or nameOf(line, s),
		skill = from,
		plan = r,
		ranks = prof.ranks,
		money = money,
		nameOf = itemName,
		have = P.have,
		selected = P.selectedStep,
		stretch = P.selectedStretch,
		level = s.level,
	})
end

local function trackActions(line, key)
	local t = P.tracked()
	local on = t ~= nil and t.spot == key
	return {
		{
			id = "trackSpot",
			key = key,
			line = line,
			label = on and "Stop tracking" or "Track this spot",
			enabled = true,
		},
		{ id = "pin", label = "Pin on the map", enabled = true, spot = key },
		{ id = "openMap", label = "Open zone map", enabled = true, spot = key },
	}
end

local function wherePage(line, s, spot)
	if not WORLD[line] then
		return {
			head = { title = nameOf(line, s), sub = "" },
			spots = {},
			empty = { title = "Levelled at a crafting window", text = P.TEXT.craftWhere:format(nameOf(line, s)) },
		}
	end
	local q = query(line, s, spot or (P.tracked() and P.tracked().spot))
	local wl = ns.Where.whereList(q)
	local wp = ns.Where.worldPath(q)
	local rows = {}
	for _, r in ipairs(wp.rows) do
		if r.state ~= "done" then
			rows[#rows + 1] = {
				range = ("%d-%d"):format(r.from, r.to),
				title = r.title,
				sub = r.sub,
				key = r.action and r.action.spot or nil,
				tone = r.state == "gap" and "warn" or (r.state == "now" and "orange" or "ash"),
			}
		end
	end
	wl.itinerary = #rows > 0 and { title = ("Route to %d"):format(wp.to or 300), rows = rows } or nil
	local sel = wl.selected
	if type(sel) == "table" and sel.key and not sel.empty then
		sel.actions = trackActions(line, sel.key)
		sel.profession = sel.profession or line
	end
	if type(wl.empty) == "string" then
		wl.empty = { title = "Nothing to go to", text = wl.empty }
	end
	return wl
end

local function shoppingPage(line, s)
	if WORLD[line] and line ~= 186 then
		return { empty = P.TEXT.noShoppingWorld:format(nameOf(line, s)) }
	end
	local last = ns.UI and ns.UI.last
	local model = ns.UI and ns.UI.model
	if ns.tradeSkillOpen and type(last) == "table" and type(model) == "table" and model.professionID == line then
		return last.shopping
	end
	return { empty = P.TEXT.notNowShopping:format(nameOf(line, s)) }
end

local function altsPage()
	local last = ns.UI and ns.UI.last
	local d = db()
	local on = not (d and d.noAlts)
	local vm = type(last) == "table" and last.alts or { empty = P.TEXT.noAlts }
	vm.countAlts = {
		text = "Count reagents on my other characters",
		on = on,
		action = { id = "setting", key = "alts", value = not on, enabled = true },
	}
	vm.howto = vm.howto
		or "Open a mailbox on the character that holds the reagents: the Mail queue fills the send form, you press Send."
	return vm
end

-- The Settings page: every slash-command setting as a control on the same code path (ns.setSetting ->
-- Logic.applySetting), the data rows, what the game taught, the key binding.
function P.settingsPage(s)
	s = s or P.snap or {}
	local v = ns.settingsView and ns.settingsView() or {}
	local P_ = ns.Planner or {}
	local luckOptions = {}
	for _, l in ipairs(ns.Logic.LUCKS or {}) do
		luckOptions[#luckOptions + 1] = { value = l, label = ("%d%%"):format(l) }
	end
	local effort = v.effort or v.defaultEffort or P_.EFFORT or 20
	local down, up = ns.Logic.effortStep(effort, -1), ns.Logic.effortStep(effort, 1)
	local spellName = function(id)
		local n = ns.UI and ns.UI.spellName and ns.UI.spellName(id)
		return type(n) == "string" and n or ("spell " .. tostring(id))
	end
	local function spellRows(set, key, label)
		local rows = {}
		for id, on in pairs(set or {}) do
			if on and type(id) == "number" then
				rows[#rows + 1] = {
					text = spellName(id),
					action = { id = "setting", key = key, spell = id, value = nil, label = label, enabled = true },
				}
			end
		end
		table.sort(rows, function(a, b)
			return a.text < b.text
		end)
		return rows
	end
	local key = GetBindingKey and GetBindingKey("SKILLUPHELPER_JOURNAL") or nil
	local planner = {
		{
			kind = "dropdown",
			key = "luck",
			label = "Buy for bad luck",
			value = v.luck,
			text = ("%d%%"):format(v.luck or P_.LUCK or 90),
			options = luckOptions,
			tip = "How unlucky a run of crafts the buys cover. 90%: nine runs in ten need no second trip.",
		},
		{
			kind = "stepper",
			key = "effort",
			label = "Effort per craft",
			value = effort,
			text = (effort == 0 and "none" or money(effort)) .. (v.effort == nil and " (default)" or ""),
			dec = { id = "setting", key = "effort", value = down, enabled = down ~= nil },
			inc = { id = "setting", key = "effort", value = up, enabled = up ~= nil },
			tip = "What one craft's time is worth to you: the plan adds it to every craft.",
		},
		{ kind = "check", key = "recipes", label = "Suggest recipes to buy", value = not v.noRecipeBuys },
		{ kind = "check", key = "alts", label = "Count reagents on my other characters", value = not v.noAlts },
		{
			kind = "check",
			key = "resale",
			label = "Count selling what I craft",
			value = v.resale == true,
			tip = "On: what the products sell for lowers a recipe's cost. Off: recipes are ranked by what you pay.",
		},
		{ kind = "check", key = "dungeon", label = "Plan dungeon patterns", value = not v.dungeon },
		{ kind = "check", key = "ahPatterns", label = "Plan auction house patterns", value = not v.ahPatterns },
		{ kind = "check", key = "special", label = "Plan special teachers", value = v.special == false },
		{
			kind = "check",
			key = "closeInCombat",
			label = "Close the journal when a fight starts",
			value = (P.ui().journal or {}).closeInCombat ~= false,
		},
		{
			kind = "check",
			key = "minimap",
			label = "Show the minimap button",
			value = not P.minimapHidden(),
			tip = "The round button on the minimap's edge. /skillup minimap does the same.",
		},
		{ kind = "list", key = "allow", label = "Shortcuts in use", rows = spellRows(v.allow, "allow", "Stop using") },
		{
			kind = "list",
			key = "notNow",
			label = "Hidden recipes",
			rows = spellRows(v.notNow, "notNow", "Offer again"),
		},
		{ kind = "link", label = "Cost to 300 for every profession", page = "overview" },
		{ kind = "key", label = "Key to open the journal", value = clean(key) or "not set" },
	}
	local custom = ns.Data and ns.Data.layers and ns.Data.layers.custom
	local customErrors = {}
	for _, list in ipairs({ type(custom) == "table" and custom.errors or {}, P.custom and P.custom.errors or {} }) do
		for _, e in ipairs(list) do
			customErrors[#customErrors + 1] = e
		end
	end
	local data = ns.Where.dataRows({
		recipes = ns.Data and ns.Data.recipes,
		spots = ns.Data and ns.Data.spots,
		trainers = ns.Data and ns.Data.trainers,
		tsm = s.prices and s.prices.ok and { age = "live", missing = 0 } or nil,
		custom = ns.Data and ns.Data.custom and { loaded = true, errors = customErrors } or nil,
	})
	for _, row in ipairs(data) do
		if row.id == "tsm" and row.state == "broken" and s.prices then
			row.detail = s.prices.text
			row.state = "absent"
		end
	end
	local status = ns.Logic.dataStatus
			and ns.Data
			and ns.Data.recipes
			and (function()
				local version, buildNumber = GetBuildInfo()
				return ns.Logic.dataStatus(ns.Data.recipes, version, buildNumber)
			end)()
		or nil
	if status then
		data[#data + 1] = { id = "age", label = "Data age", state = "ok", detail = status }
	end
	return { planner = planner, data = data, learned = P.learnedLists() }
end

-- What the game taught (SkillupHelperDB.learned, Learned.lua), as lists with a Reset each.
function P.learnedLists()
	local l = ns.learned and ns.learned() or nil
	local out = {}
	local LISTS = {
		{ id = "ranks", title = "Trainer ranks" },
		{ id = "trainers", title = "Trainer recipe lists" },
		{ id = "colors", title = "Recipe colours seen" },
		{ id = "npcs", title = "Trainers and vendors visited" },
		{ id = "vendors", title = "Vendor prices seen" },
		{ id = "skillups", title = "Skill-ups counted" },
	}
	for _, e in ipairs(LISTS) do
		local t = type(l) == "table" and l[e.id] or nil
		local n = 0
		for _ in pairs(type(t) == "table" and t or {}) do
			n = n + 1
		end
		out[#out + 1] = {
			id = e.id,
			title = e.title,
			count = n,
			rows = {},
			empty = n == 0 and "Nothing yet: it fills in as you play." or nil,
			reset = n > 0 and { id = "resetLearned", list = e.id, label = "Reset", enabled = true } or nil,
		}
	end
	return out
end

------------------------------------------------------------------------------------------------- the where models

P.whereCache = {}

-- The `where` of a spot of a world line, or nil and why.
function P.whereOf(line, spot)
	local s = P.snap or P.snapshot()
	local key = tostring(line) .. ":" .. tostring(spot)
	if P.whereCache[key] then
		return P.whereCache[key]
	end
	local wl = ns.Where.whereList(query(line, s, spot))
	local w = wl.selected
	if type(w) ~= "table" then
		return nil, "no place for this skill"
	end
	w.profession = w.profession or line
	P.whereCache[key] = w
	return w
end

-- Live state per shown place (visits, mode, legs), and the tick that fills it.
local lives = {}
local VISIT_YD = 12

local function tick(where)
	if type(where) ~= "table" or where.empty then
		return nil, {}
	end
	local key = where.key or "?"
	local prev = lives[key]
	local now = GetTime and GetTime() or 0
	local here, why
	local pos, pwhy = ns.MapCanvas.position(where.map)
	if type(pos) == "table" and pos.x then
		here = { map = where.map, x = pos.x, y = pos.y, facing = pos.facing }
	elseif type(pos) == "table" and pos.onMap == false then
		here = { map = -1, x = 0, y = 0 } -- on another map: the travel lines
	else
		why = pwhy
	end
	local maps = P.snap and P.snap.spots and P.snap.spots.maps or (ns.Data.spots and ns.Data.spots.maps) or {}
	local live = ns.Where.live(where, here, prev, { now = now, why = why, maps = maps, last = prev and prev.last })
	if live.mode == "spot" and live.nextIndex and live.yards and live.yards <= VISIT_YD then
		live.visited = ns.Where.visit(live.visited or {}, live.nextIndex, now, where.respawnSec)
		live.last = live.nextIndex
	else
		live.last = prev and prev.last
	end
	lives[key] = live
	return live, ns.Where.whereLive(where, live, now)
end

------------------------------------------------------------------------------------------------- tracker and card

local trackedWhere

-- The field card's view-model for a place.
local function fieldVM(line, where)
	local s = P.snap or {}
	local sk = s.skills and s.skills[line]
	return {
		title = nameOf(line, s),
		skill = ns.Skills and ns.Skills.text(sk) or "",
		color = where.color,
		where = where,
		actions = {
			{ id = "pin", label = "Pin", enabled = true, where = where },
			{ id = "journal", page = "where", spot = where.key, profession = line, label = "Journal", enabled = true },
			{ id = "trackSpot", key = where.key, line = line, label = "Stop", enabled = true },
		},
	}
end

-- Shows the tracker for the character's tracked spot, or hides it. Rebuilt on login, a skill-up and a zone change.
function P.updateTracker()
	local t = P.tracked()
	if not (t and ns.FieldUI and ns.Data.spots) then
		trackedWhere = nil
		if ns.FieldUI then
			ns.FieldUI.setTracker(nil)
			ns.FieldUI.hide()
		end
		return false
	end
	P.snapshot()
	P.whereCache = {}
	local where = P.whereOf(t.line, t.spot)
	if not where then
		trackedWhere = nil
		ns.FieldUI.setTracker(nil)
		return false
	end
	trackedWhere = where
	local live = tick(where)
	ns.FieldUI.setTracker(ns.Where.tracker(where, live, GetTime and GetTime() or 0))
	ns.FieldUI.update(fieldVM(t.line, where))
	return true
end

-- GuideUI asks: is the tracker up? Then its chip stands aside (one floating widget at a time).
function P.chipYields()
	return trackedWhere ~= nil and P.tracked() ~= nil
end

------------------------------------------------------------------------------------------------------ the provider

local provider = {}
P.provider = provider

function provider.journal(c)
	local s = P.snapshot()
	local ov = P.overview(s)
	s.overview = ov
	local prof = c and c.profession or P.defaultProfession(s)
	-- no count on a tab: the Overview's cards say which paths have gaps, and the breadcrumb comes from the page
	-- (its selected line or spot), never the profession's name a second time
	return ns.Where.journal({
		page = c and c.page,
		profession = prof,
		overview = ov,
		status = ov.notice or (s.prices.ok and "Prices: TradeSkillMaster, live." or s.prices.text),
		pips = { settings = s.prices.ok ~= true },
	})
end

function provider.page(name, c)
	local s = P.snap or P.snapshot()
	local line = (c and c.profession) or P.defaultProfession(s)
	if name == "overview" then
		return s.overview or P.overview(s)
	elseif name == "settings" then
		return P.settingsPage(s)
	elseif name == "alts" then
		return altsPage()
	end
	if not line then
		return { empty = { title = "No profession yet", text = P.TEXT.noProfession } }
	end
	if name == "path" then
		return WORLD[line] and worldPathPage(line, s) or craftPathPage(line, s)
	elseif name == "where" then
		return wherePage(line, s, c and c.spot)
	elseif name == "shopping" then
		return shoppingPage(line, s)
	end
	return nil
end

function provider.context()
	local line = P.defaultProfession(P.snap or P.snapshot())
	local step = ns.UI and ns.UI.state and ns.UI.state.preview or nil
	return { profession = line, step = step }
end

function provider.live(where, live)
	local mine, strings = tick(where)
	if type(mine) == "table" and type(live) == "table" then
		live.nextIndex, live.floor, live.visited, live.legsDone =
			mine.nextIndex, mine.floor, mine.visited, mine.legsDone
	end
	if type(strings) == "table" then
		strings.line3 = strings.visitedLine
	end
	return strings
end

function provider.trackerLive()
	if not trackedWhere then
		return nil
	end
	local live, s = tick(trackedWhere)
	local out = { title = s.trackerTitle, right = s.trackerRight, ticks = s.ticks }
	if live and live.ok and live.onMap and type(live.bearing) == "number" and type(live.facing) == "number" then
		-- the arrow's rotation, counter-clockwise: the target's direction (clockwise bearing) less the facing
		out.angle = -math.rad(live.bearing) - live.facing
	end
	return out
end

function provider.selectProfession(key)
	P.selectedStep, P.selectedStretch = nil, nil
	return key
end

-- A line picked in the list or on the timeline: the page shows the stretch that holds it.
function provider.selectStep(step)
	P.selectedStep, P.selectedStretch = step, nil
end

-- A stretch button: the list shows that stretch; the selected line and its detail stay.
function provider.selectStretch(index)
	P.selectedStretch = index
end

function provider.selectSpot(key)
	local st = ns.Widgets and ns.Widgets.state
	if type(st) == "table" and type(st.journal) == "table" then
		st.journal.page = "where"
	end
	return key
end

function provider.trackSpot(key)
	local t = P.tracked()
	if t and t.spot == key then
		setTracked(nil, nil)
	else
		local st = ns.Widgets and ns.Widgets.state
		local line = (type(st) == "table" and type(st.journal) == "table" and st.journal.profession)
			or P.defaultProfession()
		if not WORLD[line] then
			return false, "only a gathering skill or Lockpicking spot can be tracked"
		end
		setTracked(line, key)
	end
	-- the guide chip reads P.chipYields() at its next evaluation (a bag change, a window, its own tick)
	P.run("tracker", P.updateTracker)
	return true
end

function provider.chooseWay(a, owner)
	if ns.UI and ns.UI.act then
		ns.UI.act(a, owner)
	end
end

function provider.shortcut(a)
	if a.id == "allow" or a.id == "shortcut" then
		ns.useShortcut(a.spell, true)
	elseif a.id == "hide" then
		ns.hideShortcut(a.spell)
	end
	P.invalidate()
end

-- Journal setting keys onto Logic.applySetting's (the slash commands' and the More tab's keys).
P.SETTING = {
	luck = function(v)
		return { key = "luck", value = v }
	end,
	effort = function(v)
		return { key = "effort", value = v }
	end,
	recipes = function(v)
		return { key = "noRecipeBuys", value = not v }
	end,
	alts = function(v)
		return { key = "noAlts", value = not v }
	end,
	resale = function(v)
		return { key = "resale", value = v and true or nil }
	end,
	dungeon = function(v)
		return { key = "dungeon", value = not v }
	end,
	ahPatterns = function(v)
		return { key = "ahPatterns", value = not v }
	end,
	special = function(v)
		if v then
			return { key = "special", value = false }
		end
		return { key = "special", value = nil }
	end,
	allow = function(v, a)
		return { key = "allow", value = v, spell = a and a.spell }
	end,
	notNow = function(v, a)
		return { key = "notNow", value = v, spell = a and a.spell }
	end,
}

function provider.setting(key, value, a)
	if key == "closeInCombat" then
		return true
	elseif key == "tracker" then
		setTracked(nil, nil)
		P.run("tracker", P.updateTracker)
		return true
	elseif key == "listMissing" then
		return true
	elseif key == "minimap" then
		return P.setMinimap(value and true or false)
	end
	local map = P.SETTING[key]
	if not map then
		return false, "no setting named " .. tostring(key)
	end
	local ok = ns.setSetting(map(value, a))
	P.invalidate()
	return ok, not ok and ns.lastSettingError or nil
end

local function spotWhere(where)
	if type(where) == "table" and where.map then
		return where
	end
	return trackedWhere
end

function provider.waypoint(where, pin)
	where = spotWhere(where)
	if not where then
		return false, "no place to pin"
	end
	local p = pin and (pin.p or pin)
	local x, y = p and p.x, p and p.y
	if type(x) ~= "number" and where.area then
		x, y = where.area.x, where.area.y
	end
	return ns.JournalUI.setWaypoint(where.map, x, y)
end

function provider.openMap(map, where)
	where = spotWhere(where)
	return ns.JournalUI.openMap(map or (where and where.map))
end

function provider.resetLearned(id)
	local l = ns.learned and ns.learned() or nil
	if type(l) ~= "table" or type(l[id]) ~= "table" then
		return false, "nothing learned under " .. tostring(id)
	end
	if ns.Learned and ns.Learned.reset then
		ns.Learned.reset(l, id)
	else
		l[id] = {}
	end
	P.invalidate()
	return true
end

function provider.act(a, owner)
	if ns.UI and ns.UI.act then
		return ns.UI.act(a, owner)
	end
end

------------------------------------------------------------------------------------------------- the docked panel

-- The open-journal button on the docked panel's header (UI.create calls this), with the first-run pulse.
function P.openButton(parent)
	return P.run("open button", function()
		local b = ns.JournalUI.newOpenButton(parent)
		b:SetPoint("TOPRIGHT", -29, -7)
		if P.pulse and C_Timer and C_Timer.NewTicker then
			local on = false
			local ticker
			ticker = C_Timer.NewTicker(0.6, function()
				on = not on
				for _, t in ipairs(b.lines or {}) do
					ns.Widgets.fill(t, on and "gold" or "ash")
				end
			end, 20)
			b:HookScript("OnClick", function()
				P.pulse = false
				if ticker then
					ticker:Cancel()
				end
			end)
		end
		P.diag.openButton = true
		return b
	end)
end

-- Under the docked panel, for a world skill's window (Mining's smelting): the where-card of the best spot now, so
-- smelting steps and node spots are shown side by side. A click on the card opens the journal's Where page.
function P.panelCard(model)
	local f = ns.UI and ns.UI.frame
	if not f then
		return
	end
	local line = type(model) == "table" and clean(model.professionID) or nil
	if not (WORLD[line] and ns.FieldUI and ns.Data.spots) then
		if f.whereCard then
			f.whereCard:Hide()
		end
		return
	end
	P.snapshot()
	local where = P.whereOf(line, P.tracked() and P.tracked().spot or nil)
	if not where then
		return
	end
	if not f.whereCard then
		f.whereCard = ns.FieldUI.newCard(f)
		f.whereCard:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -4)
	end
	f.whereCard:Set(where)
	f.whereCard:Show()
	P.diag.panelCard = line
end

------------------------------------------------------------------------------------------------- slash, selftest

-- "/skillup journal [page]" opens the journal; "/skillup" with no profession window open opens it too (the docked
-- panel needs one); every other command is Core's.
function P.command(msg)
	local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "journal" or cmd == "j" then
		P.run("journal", ns.JournalUI.open, arg ~= "" and arg:lower() or nil)
		return true
	end
	if cmd == "" and not ns.tradeSkillOpen then
		P.run("journal", ns.JournalUI.Toggle)
		return true
	end
	if cmd == "minimap" then
		-- "/skillup minimap" toggles the button; "on" and "off" say which
		local word = arg:lower()
		local show = P.minimapHidden()
		if word == "on" or word == "off" then
			show = word == "on"
		end
		local ok, why = P.setMinimap(show)
		if not ok then
			print("SkillupHelper: no minimap button: " .. tostring(why or "FieldUI did not load") .. ".")
		elseif show then
			print("SkillupHelper: minimap button shown.")
		else
			print("SkillupHelper: minimap button hidden. /skillup minimap shows it again.")
		end
		return true
	end
	return false
end

------------------------------------------------------------------------------------------------- minimap button

-- The view-models of FieldUI's minimap button: what its menu offers and what its tooltip says.

function P.minimapHidden()
	local m = P.ui().minimap
	return type(m) == "table" and m.hide == true
end

-- Shows or hides the button (the Settings checkbox, /skillup minimap, the button's own menu). `tell`: one chat line
-- on how to get it back.
function P.setMinimap(show, tell)
	if not (ns.FieldUI and ns.FieldUI.minimapSetShown) then
		return false, "FieldUI did not load"
	end
	local ok, why = ns.FieldUI.minimapSetShown(show)
	if tell and not show then
		print(P.TEXT.minimapHidden)
	end
	P.run("refresh", ns.JournalUI.refresh) -- an open Settings page shows the new state
	return ok, why
end

-- The spot the menu's "Track this spot" would track: the one selected in the journal, else the best spot of the
-- journal's world skill. nil and why when there is none.
local function trackable()
	local st = ns.Widgets and ns.Widgets.state
	local line = (type(st) == "table" and type(st.journal) == "table" and st.journal.profession)
		or P.defaultProfession()
	if not WORLD[line] then
		return nil, "pick a gathering skill or Lockpicking in the journal"
	end
	local key = ns.JournalUI.ctx and ns.JournalUI.ctx.spot
	if key == nil and ns.Data.spots then
		local where = P.whereOf(line, nil)
		key = where and where.key
	end
	if key == nil then
		return nil, "no place is known for this skill"
	end
	return key
end

-- The right-click menu, for Widgets.menu.
function P.minimapMenu()
	local items = {
		{
			label = "Open the journal",
			func = function()
				P.run("journal", function()
					ns.JournalUI.open()
				end)
			end,
		},
	}
	if not ns.tradeSkillOpen then
		items[#items + 1] = { label = "Show the panel (open a profession window first)", enabled = false }
	else
		local shown = ns.UI and ns.UI.frame and ns.UI.frame:IsShown() and true or false
		items[#items + 1] = {
			label = shown and "Hide the panel" or "Show the panel",
			func = function()
				P.run("panel", ns.setShown, not shown, true)
			end,
		}
	end
	local t = P.tracked()
	if t then
		items[#items + 1] = {
			label = "Stop tracking",
			func = function()
				provider.trackSpot(t.spot)
			end,
		}
	else
		local key, why = P.run("trackable", trackable)
		if key ~= nil then
			items[#items + 1] = {
				label = "Track this spot",
				func = function()
					provider.trackSpot(key)
				end,
			}
		else
			items[#items + 1] = {
				label = "Track this spot (" .. (why or "nothing to track") .. ")",
				enabled = false,
			}
		end
	end
	items[#items + 1] = {
		label = "Settings",
		func = function()
			P.run("journal", function()
				ns.JournalUI.open("settings")
			end)
		end,
	}
	items[#items + 1] = {
		label = "Hide this button",
		func = function()
			P.setMinimap(false, true)
		end,
	}
	return { title = "SkillupHelper", items = items }
end

-- The tooltip: the title, the current step in one or two lines (the tracked spot's tracker, else the docked plan's
-- next step, else that nothing is tracked), then the clicks. A secret text is never joined or shown: one plain line
-- says it is hidden.
function P.minimapTip()
	local lines = { "SkillupHelper" }
	local hidden = false
	local function add(v, tone)
		if secret(v) then
			if not hidden then
				hidden = true
				lines[#lines + 1] = { P.TEXT.minimapSecret, "ash" }
			end
		elseif type(v) == "string" and v ~= "" then
			lines[#lines + 1] = { v, tone }
		end
	end
	local vm = P.tracked() and ns.FieldUI and ns.FieldUI.trackerVM or nil
	local card = ns.UI and ns.UI.model and ns.UI.last and ns.UI.last.now or nil
	if type(vm) == "table" then
		add(vm.title, "bone")
		add(vm.sub, "ash")
	elseif type(card) == "table" then
		add(card.title, "bone")
		add(card.sub, "ash")
	end
	if #lines == 1 then
		lines[2] = { P.TEXT.minimapNothing, "ash" }
	end
	lines[#lines + 1] = { P.TEXT.minimapHint, "ash" }
	return lines
end

-- What the selftest records: the journal's own diag, the wiring's errors, skills and where counts, and the evidence
-- for each item of docs/first-launch-checklist.md.
function P.selftest(st)
	st.journal = ns.JournalUI and P.run("diag", ns.JournalUI.diag) or "JournalUI did not load"
	st.journalWiring = {
		firstError = P.diag.firstError,
		errors = P.diag.errors,
		costRuns = P.diag.costRuns,
		costMs = math.floor(P.diag.costMs),
		costMaxMs = math.floor(P.diag.costMaxMs),
		openButton = P.diag.openButton,
		panelCard = P.diag.panelCard,
		tracked = P.tracked() ~= nil,
		chipYields = P.chipYields(),
		customPlaces = P.custom,
		worldTries = P.diag.tries,
	}
	local sk = {}
	if ns.Skills then
		local r = P.run("skills", function()
			return ns.Skills.all(ns.Skills.lines(), ns.Skills.env())
		end)
		for line, v in pairs(r or {}) do
			if WORLD[line] then
				sk[tostring(line)] = { rank = v.rank, cap = v.cap, source = v.source, why = v.why }
			end
		end
		sk.last = ns.Skills.last
	end
	st.skills = sk
	local spots = ns.Data and ns.Data.spots
	local nSpots = 0
	for _, def in pairs(spots and spots.skills or {}) do
		nSpots = nSpots + #(def.spots or def.zones or {})
	end
	st.where = {
		spots = nSpots,
		trainers = ns.Data and type(ns.Data.trainers) == "table" and #ns.Data.trainers or 0,
		map = type(st.journal) == "table" and st.journal.where or nil,
		mapDiag = ns.MapCanvas and ns.MapCanvas.diag or nil,
	}
	local binding = GetBindingKey and clean(GetBindingKey("SKILLUPHELPER_JOURNAL")) or nil
	local skillApi = C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID and true or false
	st.firstLaunch = {
		compartment = type(rawget(_G, "SkillupHelper_OnCompartmentClick")) == "function",
		bindingName = rawget(_G, "BINDING_NAME_SKILLUPHELPER_JOURNAL") ~= nil,
		bindingKey = binding or "not set",
		skillApi = skillApi,
		lockpicking = sk["633"] and (sk["633"].source or sk["633"].why) or nil,
		mapArtMissing = ns.MapCanvas and ns.MapCanvas.diag and next(ns.MapCanvas.diag.artMissing or {}) ~= nil,
		tileFailures = ns.MapCanvas and ns.MapCanvas.diag and ns.MapCanvas.diag.tileFailures or nil,
		prices = P.snap and P.snap.prices and P.snap.prices.ok or false,
	}
	-- the minimap button: { created, shown, angle, hide, shape, ldb, clicks, why }
	st.minimap = ns.FieldUI and ns.FieldUI.minimapDiag and P.run("minimap diag", ns.FieldUI.minimapDiag)
		or "FieldUI did not load: no minimap button"
	st.pixels = ns.Widgets and ns.Widgets.pixel or nil
	return st
end

------------------------------------------------------------------------------------------------------------ wiring

local function wire()
	ns.JournalUI.provider = provider
	-- the slash command: /skillup journal, and /skillup with no profession window open
	local core = ns.command
	ns.command = function(msg)
		local handled = P.run("command", P.command, msg)
		if handled then
			return true
		end
		return core(msg)
	end
	-- the minimap button (FieldUI draws it): what a left click does, its menu and its tooltip
	ns.FieldUI.minimapProvider = {
		toggle = function()
			P.run("journal", function()
				ns.JournalUI.Toggle()
			end)
		end,
		menu = function()
			return P.run("minimap menu", P.minimapMenu)
		end,
		tip = function()
			return P.run("minimap tip", P.minimapTip)
		end,
	}
end
P.run("wire", wire)

------------------------------------------------------------------------------------------- Custom.lua: places, NPCs

local function pct(v)
	return type(v) == "number" and v >= 0 and v <= 100
end

-- One custom spot of a world line, checked and filled in to the shape of Data/Spots.lua. -> spot, or nil and why.
local function customSpot(def, id, e)
	if type(id) ~= "string" or id == "" then
		return nil, "a spot needs a text id"
	end
	if type(e) ~= "table" then
		return nil, "not a table"
	end
	if type(e.map) ~= "number" then
		return nil, "map must be a uiMap id (a number)"
	end
	if not (pct(e.x) and pct(e.y)) then
		return nil, "x and y must be map percent, 0 to 100"
	end
	if def.kind == "fish" then
		return nil, "Fishing has zones, not spots: not customisable yet"
	end
	if type(e.gets) ~= "table" or #e.gets == 0 then
		return nil, "gets must list what is there: { { t = target key, n = count } }"
	end
	local req, top = math.huge, 0
	for i, g in ipairs(e.gets) do
		local t = type(g) == "table" and def.targets and def.targets[g.t]
		if not t then
			return nil,
				("gets[%d]: no target %q in this skill's targets (Data/Spots.lua)"):format(i, tostring(g and g.t))
		end
		if type(t.req) == "number" then
			req, top = math.min(req, t.req), math.max(top, t.req)
		end
	end
	local pts = e.pts or { e.x, e.y }
	if type(pts) ~= "table" or #pts < 2 or #pts % 2 ~= 0 then
		return nil, "pts must be x, y pairs in map percent"
	end
	for i = 1, #pts do
		if not pct(pts[i]) then
			return nil, ("pts[%d] is not map percent"):format(i)
		end
	end
	local pk = {}
	for i = 1, #pts / 2 do
		pk[i] = type(e.pk) == "table" and e.pk[i] or 1
	end
	return {
		id = id,
		map = e.map,
		zone = type(e.zone) == "string" and e.zone or "",
		area = e.area,
		note = e.note,
		x = e.x,
		y = e.y,
		r = type(e.r) == "number" and e.r or 2,
		sites = #pk,
		pts = pts,
		pk = pk,
		gets = e.gets,
		req = req ~= math.huge and req or 1,
		top = top,
		startA = 1,
		startH = 1,
		custom = true,
	}
end

local function customTrainer(e)
	if type(e) ~= "table" or type(e.id) ~= "number" or type(e.name) ~= "string" then
		return nil, "needs id (a number) and name"
	end
	if type(e.map) ~= "number" or not (pct(e.x) and pct(e.y)) then
		return nil, "needs map (uiMap id) and x, y in map percent"
	end
	if e.role ~= "trainer" and e.role ~= "recipes" then
		return nil, 'role must be "trainer" or "recipes"'
	end
	if e.role == "trainer" and type(e.trains) ~= "string" then
		return nil, "a trainer needs trains = the profession's name"
	end
	if e.faction ~= nil and e.faction ~= "A" and e.faction ~= "H" and e.faction ~= "B" then
		return nil, 'faction must be "A", "H" or "B"'
	end
	local row = {}
	for k, v in pairs(e) do
		row[k] = v
	end
	row.place = row.place or "?"
	row.faction = row.faction or "B"
	row.custom = true
	return row
end

-- Data/Custom.lua's `spots` and `trainers` on top of the shipped Data/Spots.lua and Data/Trainers.lua.
--   spots = { [skill line] = { [spot id] = spot | false } }: a new id adds a spot, a shipped id replaces it, false
--           leaves it out. A spot: map, x, y, gets = { { t = target key, n } }, optional pts, pk, zone, area, note.
--   trainers = { row, ... }: a row with a shipped id replaces it. Rows as in Data/Trainers.lua.
-- Every bad entry is left out and named. Returns { applied, errors }.
function P.applyCustom(spots, trainers, custom)
	local report = { applied = 0, errors = {} }
	if type(custom) ~= "table" then
		return report
	end
	local function bad(what, why)
		report.errors[#report.errors + 1] = what .. ": " .. why
	end
	for line, list in pairs(type(custom.spots) == "table" and custom.spots or {}) do
		local def = type(spots) == "table" and type(spots.skills) == "table" and spots.skills[line]
		if not def then
			bad(("spots[%s]"):format(tostring(line)), "not a world skill line (633, 186, 182, 393)")
		elseif type(list) == "table" then
			for id, e in pairs(list) do
				local at
				for i, s in ipairs(def.spots or {}) do
					if s.id == id then
						at = i
					end
				end
				if e == false then
					if at then
						table.remove(def.spots, at)
						report.applied = report.applied + 1
					else
						bad(("spots[%d][%s]"):format(line, tostring(id)), "no shipped spot with this id to leave out")
					end
				else
					local spot, why = customSpot(def, id, e)
					if not spot then
						bad(("spots[%d][%s]"):format(line, tostring(id)), why)
					else
						def.spots = def.spots or {}
						if at then
							def.spots[at] = spot
						else
							def.spots[#def.spots + 1] = spot
						end
						report.applied = report.applied + 1
					end
				end
			end
		end
	end
	if type(custom.trainers) == "table" and type(trainers) == "table" then
		local byId = {}
		for i, r in ipairs(trainers) do
			byId[r.id] = i
		end
		for i, e in ipairs(custom.trainers) do
			local row, why = customTrainer(e)
			if not row then
				bad(("trainers[%d]"):format(i), why)
			elseif byId[row.id] then
				trainers[byId[row.id]] = row
				report.applied = report.applied + 1
			else
				trainers[#trainers + 1] = row
				byId[row.id] = #trainers
				report.applied = report.applied + 1
			end
		end
	end
	return report
end

--------------------------------------------------------------------------- world tries (learned.skillups, Learned.lua)

-- The gather and pick-lock spells, all ranks (Classic ids; unconfirmed for Forever until the first launch records a
-- try): a successful cast is one try at a skill-up on the target nearest the player.
P.TRY_SPELL = {
	[1804] = 633, -- Pick Lock
	[2575] = 186,
	[2576] = 186,
	[3564] = 186,
	[10248] = 186, -- Mining
	[2366] = 182,
	[2368] = 182,
	[3570] = 182,
	[11993] = 182, -- Herb Gathering
	[8613] = 393,
	[8617] = 393,
	[8618] = 393,
	[10768] = 393, -- Skinning
}
P.TRY_YD = 15 -- a data position this close to the player is the target that was used
P.TRY_SETTLE = 2 -- seconds for the skill-up message to arrive
P.diag.tries = { recorded = 0, unplaced = 0, last = nil }

-- The target key of the data position of `line` nearest `here` ({ map, x, y } normalised), within P.TRY_YD yards;
-- nil and why otherwise.
function P.nearestTarget(spots, line, here)
	local def = type(spots) == "table" and spots.skills and spots.skills[line]
	if not def or type(here) ~= "table" or type(here.x) ~= "number" then
		return nil, "no position or no data for this skill"
	end
	local size = spots.maps and spots.maps[here.map]
	if not size then
		return nil, "this map's size is not in the data"
	end
	local best, bestYd
	for _, s in ipairs(def.spots or {}) do
		if s.map == here.map and type(s.pts) == "table" then
			for i = 1, math.floor(#s.pts / 2) do
				local yd = ns.Where.yards(size, here.x, here.y, s.pts[2 * i - 1] / 100, s.pts[2 * i] / 100)
				local g = s.gets and s.gets[(s.pk and s.pk[i]) or 1]
				if yd and g and g.t and (not bestYd or yd < bestYd) then
					best, bestYd = g.t, yd
				end
			end
		end
	end
	if best and bestYd <= P.TRY_YD then
		return best
	end
	return nil, "no data position within " .. P.TRY_YD .. " yards"
end

local function rankOf(line)
	local r = ns.Skills.read(line, ns.Skills.env())
	return type(r) == "table" and type(r.rank) == "number" and r.rank or nil
end

-- One gather or pick-lock cast: noted as a try (and a skill-up when the rank rose within P.TRY_SETTLE seconds).
function P.worldTry(spell)
	local line = P.TRY_SPELL[clean(spell) or 0]
	local learned = line and ns.learned and ns.learned() or nil
	if not (line and type(learned) == "table" and ns.Learned and ns.Learned.noteTry) then
		return false
	end
	local here = hereNow()
	local key, why = P.nearestTarget(ns.Data.spots, line, here)
	local skill = rankOf(line)
	if not key or not skill then
		P.diag.tries.unplaced = P.diag.tries.unplaced + 1
		P.diag.tries.last = why or "skill unknown"
		return false
	end
	C_Timer.After(P.TRY_SETTLE, function()
		P.run("world try", function()
			local now = rankOf(line)
			ns.Learned.noteTry(learned, line, key, skill, type(now) == "number" and now > skill)
			P.diag.tries.recorded = P.diag.tries.recorded + 1
			P.diag.tries.last = key
		end)
	end)
	return true
end

P.custom = P.run("custom", function()
	return P.applyCustom(ns.Data.spots, ns.Data.trainers, ns.Data.custom)
end) or { applied = 0, errors = { "Data/Custom.lua spots and trainers could not be applied" } }

local ev = CreateFrame("Frame")
P.eventFrame = ev
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "ZONE_CHANGED_NEW_AREA" }) do
	ev:RegisterEvent(e)
end
P.diag.tries.event = pcall(ev.RegisterUnitEvent, ev, "UNIT_SPELLCAST_SUCCEEDED", "player") and "registered"
	or "UNIT_SPELLCAST_SUCCEEDED not registered: world tries are not counted"
ev:SetScript("OnEvent", function(_, event, unit, _, spell)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit == "player" and P.TRY_SPELL[clean(spell) or 0] then
			P.run("world try", P.worldTry, spell)
		end
	elseif event == "PLAYER_LOGIN" then
		P.run("state", function()
			ns.JournalUI.setState(P.ui())
		end)
		-- one button on the minimap, after the saved state is attached (its angle and hidden flag live there)
		P.run("minimap", ns.FieldUI.minimapInit)
		P.run("first run", function()
			local ui = P.ui()
			if ui.seen ~= ns.CODE_VERSION then
				ui.seen = ns.CODE_VERSION
				P.pulse = true
				print(P.TEXT.firstRun:format(ns.CODE_VERSION))
			end
			local errs = P.custom and P.custom.errors or {}
			if #errs > 0 then
				print(("SkillupHelper: Data/Custom.lua places and NPCs: %d left out. First: %s"):format(#errs, errs[1]))
			end
		end)
		P.run("tracker", P.updateTracker)
		local st = db() and db().selftest
		if type(st) == "table" then
			P.run("selftest", P.selftest, st)
		end
	elseif event == "PLAYER_LOGOUT" then
		local d = db()
		if d then
			d.selftest = type(d.selftest) == "table" and d.selftest or {}
			P.run("selftest", P.selftest, d.selftest)
		end
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		P.run("tracker", P.updateTracker)
	end
end)

-- Skill lines: Skills.lua reads them on its events (a skill-up message, a new line, a level); each change replans
-- the costs, moves the tracker and redraws an open journal.
P.run("skills", function()
	ns.Skills.register(ev)
	ns.Skills.listen(function()
		P.invalidate()
		P.run("tracker", P.updateTracker)
		P.run("refresh", ns.JournalUI.refresh)
	end)
end)

-- The docked panel: after each draw, the where-card of a world skill's window.
P.run("panel", function()
	hooksecurefunc(ns.UI, "show", function(model)
		P.run("panel card", P.panelCard, model)
	end)
end)

return P
