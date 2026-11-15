-- Events, SavedVariables, selftest and the /skillup command. The panel follows the profession window.
local ADDON, ns = ...
SkillupHelper = ns
ns.Data = ns.Data or {}

-- Bumped with every change, so a /reload shows which code loaded (the TOC says @project-version@ until packaged).
ns.CODE_VERSION = "0.3.0"

-- The data the planner reads, built once from the three layers (Logic.effectivePlan): the shipped Data/Recipes.lua,
-- an optional local Data/Plan.lua on top, an optional Data/Custom.lua on top of both. ns.Data.layers says what
-- loaded (selftest.data). A Data/Custom.lua that breaks the merge is left out and named, never a Lua error.
function ns.plan()
	if ns.Data.effective == nil then
		local ok, eff, report = pcall(ns.Logic.effectivePlan, ns.Data.recipes, ns.Data.plan, ns.Data.custom)
		if not ok then
			local err = tostring(eff)
			ok, eff, report = pcall(ns.Logic.effectivePlan, ns.Data.recipes, ns.Data.plan, nil)
			if not ok then
				eff, report = nil, { error = "data layers failed: " .. tostring(eff) }
			end
			report.custom = { applied = 0, errors = { "Data/Custom.lua could not be applied: " .. err } }
		end
		ns.Data.effective = eff or false
		ns.Data.layers = report
	end
	return ns.Data.effective or nil
end

-- One chat line when Data/Custom.lua has entries that were left out (all of them are in selftest.data.custom).
function ns.customNotice()
	local c = ns.Data.layers and ns.Data.layers.custom
	local errors = type(c) == "table" and c.errors or {}
	if #errors == 0 then
		return nil
	end
	return ("SkillupHelper: Data/Custom.lua: %d entr%s left out. First: %s"):format(
		#errors,
		#errors == 1 and "y" or "ies",
		errors[1]
	)
end

function ns.version()
	local v = C_AddOns.GetAddOnMetadata(ADDON, "Version")
	if not v or v:sub(1, 1) == "@" then
		return ns.CODE_VERSION .. "-dev"
	end
	return v
end

local DEFAULTS = { shown = true }
local db
ns.selftest = {}
ns.scans = {}

function ns.initDB(saved)
	saved = type(saved) == "table" and saved or {}
	for k, v in pairs(DEFAULTS) do
		if saved[k] == nil then
			saved[k] = v
		end
	end
	return saved
end

-- The cap model's SavedVariables, made on first use (ns.capTables): ranks[skillLineID][cap] learned at the trainer;
-- exclude = { dungeon, ahPatterns, special, notNow[spellID], allow[spellID] (gated recipes to use), swap[spellID] = spellID };
-- trainerSeen[skillLineID][spellID or lowercased name] = true for the recipes an ordinary trainer lists.
-- What the game taught (trainer ranks and learn ranks, recipe colours, vendors, NPC positions, skill-up counts) lives
-- in saved.learned (Learned.lua), the one table that is safe to share: ns.capTables moves the pre-0.3.0 fields
-- (ranks, colorSeen, trainerReq, guide.npcs) into it.
local learned
function ns.capTables(saved)
	local locale = GetLocale and GetLocale() or nil
	learned = ns.Learned.attach(saved, ns.Learned.build(), locale)
	saved.exclude = type(saved.exclude) == "table" and saved.exclude or {}
	saved.exclude.notNow = type(saved.exclude.notNow) == "table" and saved.exclude.notNow or {}
	saved.exclude.allow = type(saved.exclude.allow) == "table" and saved.exclude.allow or {}
	-- swap[Y] = X: "use X instead of Y" (the Other way rows of a step)
	saved.exclude.swap = type(saved.exclude.swap) == "table" and saved.exclude.swap or {}
	saved.trainerSeen = type(saved.trainerSeen) == "table" and saved.trainerSeen or {}
	-- learned.colors[spellID] = { o = highest skill seen orange, y = lowest seen yellow or green, ... }: for learned
	-- recipes the export does not list it narrows their estimated yellow threshold (Scan.yellowOf).
	-- learned.trainers[skillLineID][spellID or lowercased name] = { skill, cost }: what a trainer asks for each recipe
	-- it lists, read in game (Scan.readTrainer). It wins over the data's learn ranks (Logic.withTrainerReq).
	return saved
end

function ns.savedColorSeen()
	return learned and learned.colors or nil
end

-- SkillupHelperDB.learned, or nil before the SavedVariables load.
function ns.learned()
	return learned
end

-- What Data/Plan.lua holds, for the selftest; nil when the file is absent.
function ns.selftest.planSummary(plan)
	if type(plan) ~= "table" then
		return nil
	end
	local profs = {}
	for id, p in pairs(plan.professions or {}) do
		profs[#profs + 1] = ("%s(%s) %s-%s, %d steps"):format(
			tostring(p.name),
			tostring(id),
			tostring(p.from),
			tostring(p.to),
			#(p.rows or {})
		)
	end
	table.sort(profs)
	return { generatedAt = plan.generatedAt, build = plan.build, professions = profs }
end

-- selftest.data: a copy of the data layers' report (ns.Data.layers, cached for the session and read by the guide and
-- the journal) with the data's age on top: where and when the overlay was read, and whether the game is a newer build.
-- The shared report itself is never written to.
function ns.selftest.dataReport(layers, recipes, build, buildNumber)
	if type(layers) ~= "table" then
		return layers
	end
	local out = {}
	for k, v in pairs(layers) do
		out[k] = v
	end
	out.overlayRetrieved = type(recipes) == "table" and recipes.source or nil
	out.status, out.gameIsNewer = ns.Logic.dataStatus(recipes, build, buildNumber)
	return out
end

local function refreshSelftest()
	if not db then
		return
	end
	local build, buildNumber, _, interface = GetBuildInfo()
	local st = db.selftest or {}
	st.version = ns.version()
	st.build, st.interface, st.project = build .. "." .. tostring(buildNumber), interface, WOW_PROJECT_ID
	st.loadedAt = st.loadedAt or date("%Y-%m-%d %H:%M:%S")
	st.savedAt = date("%Y-%m-%d %H:%M:%S")
	-- the data layers: the shipped build and recipe counts per profession, the local plan, the custom file
	ns.plan()
	st.data = ns.selftest.dataReport(ns.Data.layers, ns.Data.recipes, build, buildNumber)
	st.plan = ns.selftest.planSummary(ns.Data.plan) or "Data/Plan.lua absent (optional: the shipped data plans alone)"
	st.lastScan = ns.lastScan
	-- the last scan of every profession opened this session, so Cooking and Leatherworking both show after one reload
	st.scans = ns.scans
	st.settings = ns.settings()
	st.stockRuns = ns.Scan.stockRuns or 0
	st.trips = db.trips
	-- cap model: rank entries saved at trainers, and the last trainer read's broken link (nil when it read fine)
	st.ranksSeen = ns.ranksSeen()
	-- what the game taught, as counts (the table itself is SkillupHelperDB.learned), and the last craft counted
	st.learned = ns.Learned.status(learned)
	st.skillups = ns.skillupStatus
	st.lastTrainerRead = ns.lastTrainerRead
	st.tsm = ns.TSM.status()
	st.craftedEvent = ns.craftedEvent
	-- known only with a local Data/Plan.lua (its pricesAt); unknown is not stale
	local age = ns.TSM.ageHours(ns.Data.plan)
	st.tsmAgeHours = age and math.floor(age * 10 + 0.5) / 10
	st.tsmStale = age ~= nil and age > ns.TSM.STALE_HOURS
	st.lastError = ns.lastError
	st.panelErrors = ns.panelErrors
	st.guide = ns.GuideUI and ns.GuideUI.status()
	local ui = ns.UI.stats
	st.ui = {
		layout = ui.layout,
		-- what the docked panel shows (the card, the next lines, why some are not shown)
		views = ui.views,
		animations = ui.animations,
		played = ui.played,
		lastDock = ui.lastDock,
		docks = ui.docks,
		dockGap = ui.dockGap,
		fit = ui.fit,
		handle = ui.handle,
		clicks = ui.clicks,
		actionsWhy = ui.actionsWhy,
		lastCraft = ui.lastCraft,
		lastCraftError = ui.lastCraftError,
		lastOpenError = ui.lastOpenError,
		-- "Show recipe": path "list" (selected in the open window) or "OpenRecipe" (server trip), and why
		lastOpen = ui.lastOpen,
		merchant = ui.merchant,
		lastBuy = ui.lastBuy,
		lastBuyError = ui.lastBuyError,
		buysByUi = ui.buysByUi,
		-- the AH list (UI.ahEvent / UI.ahAct)
		ah = ui.ah,
		lastAhBuy = ui.lastAhBuy,
		lastAhError = ui.lastAhError,
	}
	st.ahSkip = db.ahSkip
	-- the alts' reagents (counts and the broken link only: no character names in the selftest) and the mail queue
	st.alts = ns.Scan.altCache and ns.Scan.altCache.status or "not read yet (open a profession window)"
	st.mail = ns.MailUI and ns.MailUI.status()
	db.selftest = st
end

-- Runs a panel step and keeps its error: chat once per step, selftest.lastError and panelErrors always. Without
-- BugGrabber a frame error is otherwise invisible and the panel just does not appear.
ns.panelErrors = {}
function ns.guard(where, fn, ...)
	local ok, err = xpcall(fn, function(e)
		local stack = debugstack and debugstack(2, 6, 0) or ""
		return tostring(e) .. "\n" .. stack
	end, ...)
	if not ok then
		ns.lastError = where .. ": " .. tostring(err)
		if not ns.panelErrors[where] then
			print("|cffff6060SkillupHelper " .. where .. " failed:|r " .. tostring(err):match("^[^\n]*"))
		end
		ns.panelErrors[where] = ns.lastError
	end
	return ok
end

-- Skill-ups per craft, for learned.skillups: a craft cast of a recipe of the open profession is kept until a scan
-- at least SETTLE seconds later shows the skill, and the points gained since are its skill-ups (Learned.settle).
-- Counted, never planned from: the numbers are for whoever checks the skill-up chance formula against the game.
local SETTLE = 1.5
local crafting = nil -- { line, skill, cap, recipes } of the last scan
local crafts, craftsAt = {}, 0
ns.skillupStatus = { casts = 0, counted = 0 }

local function noteCraftCast(spellID)
	if not learned or not ns.tradeSkillOpen or not crafting or type(spellID) ~= "number" then
		return
	end
	if (issecretvalue and issecretvalue(spellID)) or type(crafting.recipes) ~= "table" then
		return
	end
	if not crafting.recipes[spellID] or type(crafting.skill) ~= "number" then
		return
	end
	local c = crafts[spellID] or { n = 0, skill = crafting.skill }
	c.n = c.n + 1
	crafts[spellID] = c
	craftsAt = GetTime()
	ns.skillupStatus.casts = ns.skillupStatus.casts + 1
end

-- model: a scan's model, or liveSkill()'s { professionID, skill, maxSkill } while the panel is hidden. A model with no
-- profession (a failed scan, a secret id) settles nothing and drops nothing.
local function settleCrafts(model)
	local line = model and model.professionID
	if line == nil or (issecretvalue and issecretvalue(line)) then
		return
	end
	if next(crafts) and crafting and line == crafting.line and GetTime() - craftsAt >= SETTLE then
		local n = ns.Learned.settle(learned, line, crafts, model.skill, crafting.cap)
		ns.skillupStatus.counted = ns.skillupStatus.counted + n
		ns.skillupStatus.last = { line = line, skill = model.skill, crafts = n }
		crafts = {}
	elseif next(crafts) and crafting and line ~= crafting.line then
		crafts = {} -- another profession's window: the pending crafts cannot be settled against it
	end
	if not next(crafts) and type(model.skill) == "number" then
		-- every learned recipe of the window counts (the client-only ones too: Scan.build's model.learned); the
		-- data's recipes when a model has no such set; the last set when a hidden-panel read carries none
		local recipes = model.learned or (model.plan and model.plan.recipes)
		if recipes == nil and crafting and crafting.line == line then
			recipes = crafting.recipes
		end
		crafting = { line = line, skill = model.skill, cap = model.maxSkill, recipes = recipes }
	end
end

-- The open profession's skill straight from the client, for settling crafts without a scan (the panel hidden, the
-- window closing): { professionID, skill, maxSkill }, or nil when there is none or it is a secret (not now).
local function liveSkill()
	local ok, info = pcall(ns.Scan.professionInfo)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local id, skill, cap = info.professionID, info.skillLevel, info.maxSkillLevel
	if issecretvalue and (issecretvalue(id) or issecretvalue(skill) or issecretvalue(cap)) then
		return nil
	end
	if id == nil or type(skill) ~= "number" then
		return nil
	end
	return { professionID = id, skill = skill, maxSkill = cap }
end

-- With the panel hidden ns.refresh scans nothing, so pending crafts settle here: SETTLE seconds after the last
-- refresh event, again while some stay pending (at most a few times: a skill that never reads stops trying).
local settleArmed, settleTries = false, 0
local function settleSoon()
	if settleArmed then
		return
	end
	settleArmed = true
	C_Timer.After(SETTLE, function()
		settleArmed = false
		if not ns.tradeSkillOpen then
			return
		end
		ns.guard("skillups", function()
			settleCrafts(liveSkill())
		end)
		if next(crafts) and settleTries < 5 then
			settleTries = settleTries + 1
			settleSoon()
		else
			settleTries = 0
		end
	end)
end

-- For the tests: the craft counter's steps (a cast, a settle with a model, a hidden-panel settle).
ns.craftCounter = {
	cast = function(spellID)
		return noteCraftCast(spellID)
	end,
	settle = function(model)
		return settleCrafts(model)
	end,
	pending = function()
		return crafts
	end,
}

local pending = false
function ns.refresh()
	if not ns.UI.frame or not ns.UI.frame:IsShown() then
		-- the panel hidden: no scan, but crafts made meanwhile still settle against the client's skill
		if ns.tradeSkillOpen and next(crafts) then
			settleSoon()
		end
		return
	end
	if pending then
		return
	end
	pending = true
	C_Timer.After(0.3, function()
		pending = false
		local ok, model = pcall(ns.Scan.build, ns.plan())
		if not ok then
			ns.lastError = tostring(model)
			model = { why = "scan failed: " .. tostring(model) }
		end
		ns.guard("draw", ns.UI.show, model)
		ns.guard("skillups", settleCrafts, model)
		ns.lastScan = ns.scanSummary(model)
		ns.lastScan.dock = ns.dockKind
		ns.lastScan.tsm = ns.TSM.status()
		if model.profession then
			ns.scans[model.profession] = ns.lastScan
		end
	end)
end

-- What one scan and its plan looked like, for the selftest (no item or character names beyond recipe names).
function ns.scanSummary(model)
	local s = {
		at = date("%Y-%m-%d %H:%M:%S"),
		profession = model.profession,
		skill = model.skill,
		maxSkill = model.maxSkill,
		fromStock = model.fromStock and #model.fromStock or nil,
		planState = model.planState,
		why = model.why or model.planWhy or model.plannerWhy,
		counts = model.counts,
		diag = model.diag,
		idSource = model.idSource,
		greyCheck = model.greyCheck,
	}
	local p = model.planner
	if p then
		local ageHours = p.ageHours
		s.planner = {
			ms = p.ms and math.floor(p.ms * 100 + 0.5) / 100,
			steps = #p.steps,
			hold = #p.hold,
			leftovers = #p.leftovers,
			skipped = #p.skipped,
			-- learned recipes planned from the client (not in the export); clientOnly: no export for the profession
			liveRecipes = p.liveRecipes,
			-- learned recipes the scan dropped (no schematic, no grey...), by reason: they are not in the plan
			liveSkipped = model.counts and model.counts.liveSkipped,
			clientOnly = p.clientOnly,
			colourMismatch = #p.colourMismatch,
			mismatches = p.colourMismatch,
			priceSources = p.prices,
			tsmAgeHours = ageHours and math.floor(ageHours * 10 + 0.5) / 10,
			tsmStale = ageHours ~= nil and ageHours > ns.TSM.STALE_HOURS,
			-- the plan ran on the data's default ranks: no trainer of this profession was read yet
			ranksAssumed = model.ranksAssumed,
		}
		local list = {}
		for i, st in ipairs(p.steps) do
			if i > 6 then
				break
			end
			list[#list + 1] = ("%s %s%s %s"):format(
				st.kind,
				st.crafts and (st.crafts .. "x ") or "",
				tostring(st.name or st.why),
				st.from and ("%.1f-%.1f"):format(st.from, st.to or st.from) or tostring(st.at or "")
			)
		end
		s.planner.first = list
	end
	return s
end

-- The planner settings from SavedVariables (nil fields fall back to Data/Plan.lua's defaults).
function ns.settings()
	return {
		effort = db and db.effort,
		sellShare = db and db.sellShare,
		noRecipeBuys = db and db.noRecipeBuys,
		noAlts = db and db.noAlts,
		resale = db and db.resale,
		luck = db and db.luck,
		trips = db and db.trips,
		exclude = db and db.exclude,
	}
end

-- Ranks learned at the trainer -----------------------------------------------------------------------------------
-- The saved ranks of one skill line ({ [cap] = rank }), or nil.
function ns.savedTrainerSeen(skillLineID)
	return db and skillLineID and db.trainerSeen and db.trainerSeen[skillLineID] or nil
end

-- One section of SkillupHelperDB.learned for a skill line, or nil (no table yet, or a hand-edited file without it).
local function learnedFor(section, skillLineID)
	local t = learned and skillLineID and learned[section]
	return type(t) == "table" and t[skillLineID] or nil
end

function ns.savedTrainerReq(skillLineID)
	return learnedFor("trainers", skillLineID)
end

function ns.savedRanks(skillLineID)
	return learnedFor("ranks", skillLineID)
end

function ns.ranksSeen()
	local n = 0
	local ranks = learned and learned.ranks
	for _, byCap in pairs(type(ranks) == "table" and ranks or {}) do
		for _ in pairs(type(byCap) == "table" and byCap or {}) do
			n = n + 1
		end
	end
	return n
end

-- TRAINER_SHOW / TRAINER_UPDATE: save the rank services of a profession trainer. Not a profession trainer is "not
-- now" and leaves the last diagnostic alone.
function ns.onTrainer()
	if not db or not learned then
		return
	end
	local ok, parsed, why, state = pcall(ns.Scan.readTrainer)
	if not ok then
		ns.lastTrainerRead = "trainer read failed: " .. tostring(parsed)
		return
	end
	if state == "not now" then
		return
	end
	if parsed and parsed.skillLine and #parsed.ranks > 0 then
		-- the planner's cache key carries the ranks: the next scan replans on its own
		ns.Scan.saveRanks(learned.ranks, parsed.skillLine, parsed.ranks, time())
		ns.Learned.stampRanks(learned, parsed.skillLine, parsed.ranks, ns.Learned.build())
	end
	if parsed and parsed.skillLine and next(parsed.seen or {}) then
		local first = db.trainerSeen[parsed.skillLine] == nil
		local set = db.trainerSeen[parsed.skillLine] or {}
		for key in pairs(parsed.seen) do
			set[key] = true
		end
		db.trainerSeen[parsed.skillLine] = set
		if first then
			-- the planner's cache key carries trainerSeen: the next scan replans with only what a trainer teaches
			print(
				"SkillupHelper: trainer read. Recipes no trainer you've opened teaches are shortcuts now; another trainer can confirm them."
			)
		end
	end
	if parsed and parsed.skillLine and next(parsed.req or {}) then
		-- the planner's cache key carries each recipe's learn rank: the next scan replans
		ns.Learned.noteTrainer(learned, parsed.skillLine, parsed.req, ns.Learned.build())
	end
	ns.lastTrainerRead = why
end

-- The AH trip list kept per profession (View.tripBlock): what to buy at the AH, and the recipes it buys for, which
-- keep their levels in the plan until the trip's skill is reached.
function ns.saveTrip(block)
	if not db or not block or not block.prof then
		return false
	end
	local rows = {}
	for _, r in ipairs(block.rows) do
		rows[#rows + 1] = { item = r.item, name = r.name, count = r.count, each = r.each, recipe = r.recipe }
	end
	db.trips = db.trips or {}
	db.trips[block.prof] = {
		rows = rows,
		route = block.route,
		commit = block.commit,
		to = block.to,
		total = block.total,
		at = date("%Y-%m-%d %H:%M:%S"),
	}
	ns.refresh()
	return true
end

function ns.clearTrip(prof)
	if db and db.trips and prof then
		db.trips[prof] = nil
	end
	ns.refresh()
	return true
end

-- The trip list kept for `prof`, or nil.
function ns.savedTrip(prof)
	return db and db.trips and prof and db.trips[prof] or nil
end

------------------------------------------------------------------------------- AH list (UI worker's block)

-- Every saved trip list, per profession (Logic.ahList reads it at the auction house).
function ns.savedTrips()
	return db and db.trips or {}
end

-- A purchase from the AH list: `n` units of `item` count as bought on the saved rows (row.bought), oldest list
-- first, so the row shows what is left and the list empties as it is bought.
function ns.noteAhBought(item, n)
	local left = n or 0
	local profs = {}
	for prof in pairs(db and db.trips or {}) do
		profs[#profs + 1] = prof
	end
	table.sort(profs, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, prof in ipairs(profs) do
		for _, r in ipairs(db.trips[prof].rows or {}) do
			if left > 0 and r.item == item then
				local take = math.min(left, (r.count or 0) - (r.bought or 0))
				if take > 0 then
					r.bought = (r.bought or 0) + take
					left = left - take
				end
			end
		end
	end
	return n - left
end

-- SkillupHelperDB.ahSkip[item] = "sold out" | "overpriced": an AH buy the next plan may go without (never set for a
-- committed step's buy: View.ahRow says so on the row instead). why nil clears it (bought after all).
function ns.setAhSkip(item, why)
	if not db or type(item) ~= "number" then
		return
	end
	if why then
		db.ahSkip = db.ahSkip or {}
		db.ahSkip[item] = why
	elseif db.ahSkip then
		db.ahSkip[item] = nil
	end
end

-- Shows the panel or folds it to its handle (the choice is kept). byUser: a click, so the change fades in.
function ns.setShown(shown, byUser)
	if db then
		db.shown = shown
	end
	ns.UI.setShown(shown, ns.tradeSkillOpen == true, byUser)
	if shown then
		ns.refresh()
	end
end

-- The window to dock to: TSM's crafting frame when it is shown, else Blizzard's ProfessionsFrame when shown.
-- Returns the frame (or nil) and its kind, for the selftest.
function ns.dockTarget()
	local tsm = ns.TSM.craftingFrame()
	if tsm and tsm:IsVisible() then
		return tsm, "tsm"
	end
	if ProfessionsFrame and ns.TSM.onScreen(ProfessionsFrame) then
		return ProfessionsFrame, "blizzard"
	end
	return nil, "free"
end

local ticker
local function stopTicker()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

-- While a profession is open, follow the user flipping between TSM's UI and the WoW UI.
local function redock()
	local target, kind = ns.dockTarget()
	ns.UI.dock(target, kind)
	local changed = ns.dockKind ~= nil and ns.dockKind ~= kind
	-- set before the redraw, which reads it
	ns.dockKind = kind
	if changed then
		-- Show recipe is offered beside Blizzard's window only: redraw the card for the new window
		ns.refresh()
	end
	if ns.UI.frame and ns.UI.frame:IsShown() then
		ns.UI.noteDock(kind)
	end
end

local function open()
	ns.tradeSkillOpen = true
	if not ns.guard("create", ns.UI.create) then
		return
	end
	ns.UI.setShown(db == nil or db.shown, true)
	redock()
	stopTicker()
	ticker = C_Timer.NewTicker(0.5, redock)
	ns.refresh()
end

local function close()
	-- a last settle while the client still names the profession; crafts younger than SETTLE (their skill-up may not be
	-- in yet) are dropped: without the window the skill they ended at is not known
	ns.guard("skillups", function()
		settleCrafts(liveSkill())
	end)
	ns.tradeSkillOpen = false
	crafts, crafting = {}, nil
	stopTicker()
	ns.UI.setShown(false, false)
end

local f = CreateFrame("Frame")
ns.eventFrame = f
local REFRESH_EVENTS = {
	"TRADE_SKILL_SHOW",
	"TRADE_SKILL_LIST_UPDATE",
	"TRADE_SKILL_DATA_SOURCE_CHANGED",
	"BAG_UPDATE_DELAYED",
	"BANKFRAME_OPENED",
	"SKILL_LINES_CHANGED",
	-- a recipe learned with the window open (a pattern used, a trainer): it joins the plan at once
	"NEW_RECIPE_LEARNED",
}
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("TRADE_SKILL_CLOSE")
for _, e in ipairs(REFRESH_EVENTS) do
	f:RegisterEvent(e)
end
-- A craft result replans at once (it carries no recipe id and can fire for other sources: a trigger, not a counter).
-- Registered under pcall so a client without it names the event instead of breaking the load.
local okCrafted, errCrafted = pcall(f.RegisterEvent, f, "TRADE_SKILL_ITEM_CRAFTED_RESULT")
ns.craftedEvent = okCrafted and "registered"
	or ("TRADE_SKILL_ITEM_CRAFTED_RESULT not registered: " .. tostring(errCrafted))
-- The player's own casts: a craft of the open profession is a try at a skill-up (noteCraftCast).
ns.skillupStatus.event = pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player") and "registered"
	or "UNIT_SPELLCAST_SUCCEEDED not registered: crafts are not counted"
-- A vendor opening or closing turns the Next card's Buy button on or off (the same events under TSM's vendoring
-- window, which replaces MerchantFrame but not the merchant).
for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE" }) do
	f:RegisterEvent(e)
end
-- A profession trainer opening or updating: read its rank services (ns.onTrainer).
for _, e in ipairs({ "TRAINER_SHOW", "TRAINER_UPDATE" }) do
	f:RegisterEvent(e)
end
-- A craft the client refuses raises no Lua error (pcall sees nothing): it fires one of these, naming the addon.
for _, e in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
	pcall(f.RegisterEvent, f, e)
end
-- The auction house: the saved AH list becomes buy rows (UI.ahEvent). Under pcall so a client without one of them
-- names it in selftest.ahEvents instead of breaking the load.
local AH_EVENTS = {
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"COMMODITY_SEARCH_RESULTS_UPDATED",
	"ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PRICE_UPDATED",
	"COMMODITY_PRICE_UNAVAILABLE",
	"COMMODITY_PURCHASE_SUCCEEDED",
	"COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_PURCHASE_COMPLETED",
	"AUCTION_HOUSE_SHOW_ERROR",
}
local isAhEvent = {}
for _, e in ipairs(AH_EVENTS) do
	local ok, err = pcall(f.RegisterEvent, f, e)
	isAhEvent[e] = ok or nil
	if not ok then
		ns.UI.stats.ah.unregistered = ns.UI.stats.ah.unregistered or {}
		ns.UI.stats.ah.unregistered[e] = tostring(err)
	end
end
f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if arg1 == "player" then
			ns.guard("skillups", noteCraftCast, arg3)
		end
		return
	end
	if isAhEvent[event] then
		ns.guard("ah", ns.UI.ahEvent, event, arg1, arg2)
		return
	end
	if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if arg1 == ADDON and ns.UI.ah.open then
			ns.UI.stats.lastAhError = { at = date("%Y-%m-%d %H:%M:%S"), err = event .. ": " .. tostring(arg2) }
		end
		if arg1 == ADDON then
			ns.UI.stats.lastCraftError = ("%s: the client refused %s"):format(event, tostring(arg2))
		end
		return
	end
	if event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
		ns.onTrainer()
		return
	end
	if event == "BAG_UPDATE_DELAYED" then
		ns.UI.noteBags()
	end
	if event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED" then
		ns.merchantOpen = event == "MERCHANT_SHOW"
		local m = ns.UI.stats.merchant
		m.open = ns.merchantOpen
		if ns.merchantOpen then
			m.shows = m.shows + 1
			m.lastShow = date("%Y-%m-%d %H:%M:%S")
		end
	end
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			SkillupHelperDB = ns.initDB(SkillupHelperDB)
			db = SkillupHelperDB
			ns.capTables(db)
		end
	elseif event == "PLAYER_LOGIN" then
		db.selftest = nil
		ns.onTSMChanged = function()
			if ns.tradeSkillOpen then
				redock()
			end
		end
		ns.TSM.register()
		refreshSelftest()
		local notice = ns.customNotice()
		if notice then
			print(notice)
		end
		-- a game build newer than the shipped data: said once at login, in plain words, not as an error
		local okStatus, status, newer = pcall(function()
			local version, buildNumber = GetBuildInfo()
			return ns.Logic.dataStatus(ns.Data.recipes, version, buildNumber)
		end)
		if okStatus and newer then
			print("SkillupHelper: " .. status)
		end
	elseif event == "PLAYER_LOGOUT" then
		refreshSelftest()
	elseif event == "TRADE_SKILL_SHOW" then
		open()
	elseif event == "TRADE_SKILL_CLOSE" then
		close()
	elseif ns.tradeSkillOpen then
		ns.refresh()
		if event == "NEW_RECIPE_LEARNED" then
			-- the recipe list may not hold the new recipe yet: look again once the client has refreshed it
			C_Timer.After(1.5, ns.refresh)
		end
	end
end)

-- "/skillup ranks": the ranks saved at trainers, per profession ("unknown" for a field the trainer did not give).
-- "/skillup exclude dungeon|ahpatterns|special|<spellID>": toggles an exclusion from the plan (special teachers start
-- excluded); "/skillup exclude" lists them.
local function unknown(v)
	return v == nil and "unknown" or tostring(v)
end

function ns.capCommand(cmd, arg)
	if not db then
		print("SkillupHelper: SavedVariables not loaded yet.")
		return true
	end
	if cmd == "ranks" then
		local ids = {}
		local saved = learned and learned.ranks or {}
		for id in pairs(saved) do
			ids[#ids + 1] = id
		end
		table.sort(ids)
		if #ids == 0 then
			print("SkillupHelper: no ranks saved yet: open your profession trainer once.")
		end
		local plan = ns.plan()
		for _, id in ipairs(ids) do
			local p = plan and plan.professions and plan.professions[id]
			print(("SkillupHelper: %s (%s)"):format(p and p.name or "skill line", tostring(id)))
			for _, r in ipairs(ns.Scan.ranksArray(saved[id])) do
				print(
					("  %s to %s: skill %s, level %s, cost %s, at %s"):format(
						unknown(r.name),
						unknown(r.cap),
						unknown(r.skill),
						unknown(r.level),
						r.cost and ns.Logic.money(r.cost) or "unknown",
						unknown(r.where)
					)
				)
			end
		end
		if ns.lastTrainerRead then
			print("SkillupHelper: last trainer read: " .. ns.lastTrainerRead)
		end
		return true
	end
	local ex = db.exclude
	local word = arg:lower()
	local spell = tonumber(arg)
	if word == "dungeon" then
		ex.dungeon = not ex.dungeon or nil
	elseif word == "ahpatterns" then
		ex.ahPatterns = not ex.ahPatterns or nil
	elseif word == "special" then
		-- special teachers (dungeon or special NPC) are excluded by default: false enables them, nil excludes again
		if ex.special == false then
			ex.special = nil
		else
			ex.special = false
		end
	elseif spell then
		ex.notNow[spell] = not ex.notNow[spell] or nil
		ex.allow[spell] = nil
	elseif word ~= "" then
		print("SkillupHelper: /skillup exclude dungeon|ahpatterns|special|<spellID> (no argument lists them).")
		return true
	end
	local list = {}
	if ex.dungeon then
		list[#list + 1] = "dungeon patterns"
	end
	if ex.ahPatterns then
		list[#list + 1] = "AH patterns"
	end
	if ex.special ~= false then
		list[#list + 1] = "special teachers (dungeon or special NPC)"
	end
	local spells = {}
	for id in pairs(ex.notNow) do
		spells[#spells + 1] = id
	end
	table.sort(spells)
	for _, id in ipairs(spells) do
		list[#list + 1] = "spell " .. id
	end
	print("SkillupHelper: excluded from the plan: " .. (#list > 0 and table.concat(list, ", ") or "nothing") .. ".")
	local allowed = {}
	for id in pairs(ex.allow) do
		allowed[#allowed + 1] = id
	end
	table.sort(allowed)
	if #allowed > 0 then
		print("SkillupHelper: shortcuts in use: spell " .. table.concat(allowed, ", spell ") .. ".")
	end
	if word ~= "" then
		ns.refresh()
	end
	return true
end

-- A shortcut's buttons. "Use it": the plan may pick gated recipe `spell` (you can get it). "Hide": never offer it
-- again (exclude.notNow, as /skillup exclude <spellID>). Both replan; /skillup allow <spellID> toggles the first.
function ns.useShortcut(spell, on)
	if not (db and db.exclude and type(spell) == "number") then
		return false
	end
	db.exclude.allow[spell] = on and true or nil
	if on then
		db.exclude.notNow[spell] = nil
	end
	ns.refresh()
	return true
end

function ns.hideShortcut(spell)
	if not (db and db.exclude and type(spell) == "number") then
		return false
	end
	db.exclude.notNow[spell] = true
	db.exclude.allow[spell] = nil
	ns.refresh()
	return true
end

-- An Other way row's "Use this": plan recipe `to` where the plan would craft `from` (exclude.swap[from] = to); a
-- swap back the other way is dropped, so the two never loop. "Back to": the plan picks for `from` again. Both replan.
function ns.useSwap(from, to)
	if not (db and db.exclude and type(from) == "number" and type(to) == "number") or from == to then
		return false
	end
	db.exclude.swap = type(db.exclude.swap) == "table" and db.exclude.swap or {}
	db.exclude.swap[from] = to
	if db.exclude.swap[to] == from then
		db.exclude.swap[to] = nil
	end
	ns.refresh()
	return true
end

function ns.clearSwap(from)
	if not (db and db.exclude and type(from) == "number") then
		return false
	end
	if type(db.exclude.swap) == "table" then
		db.exclude.swap[from] = nil
	end
	ns.refresh()
	return true
end

-- A More-tab control: writes the same SavedVariables keys as the slash commands (Logic.applySetting), then replans.
function ns.setSetting(a)
	local ok, why = ns.Logic.applySetting(db, a)
	ns.lastSettingError = not ok and why or nil
	if ok then
		ns.refresh()
	end
	return ok
end

-- What the More tab shows: the settings as they stand, with the defaults they fall back to.
function ns.settingsView()
	local ex = db and db.exclude or {}
	return {
		luck = db and db.luck or ns.Planner.LUCK,
		effort = db and db.effort,
		defaultEffort = ns.plan() and ns.plan().effort or ns.Planner.EFFORT,
		noRecipeBuys = db and db.noRecipeBuys,
		noAlts = db and db.noAlts,
		resale = db and db.resale,
		dungeon = ex.dungeon,
		ahPatterns = ex.ahPatterns,
		special = ex.special,
		allow = ex.allow or {},
		notNow = ex.notNow or {},
	}
end

-- "/skillup cost [profession]": one line per crafting profession of the data (or the one named): what levelling it
-- to the top costs at TSM's prices now, the skill brackets no recipe covers, and how many prices TSM lacks. One
-- profession per frame: each is a whole planner run.
function ns.costCommand(arg)
	local plan = ns.plan()
	if not plan then
		print("SkillupHelper: no recipe data loaded (Data/Recipes.lua).")
		return true
	end
	local want = (arg or ""):lower()
	local ids = {}
	for id, prof in pairs(plan.professions) do
		local name = tostring(prof.name or id):lower()
		if (want == "" and not prof.side) or (want ~= "" and (name:find(want, 1, true) or tostring(id) == want)) then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	if #ids == 0 then
		print(("SkillupHelper: no profession named %q in the recipe data."):format(want))
		return true
	end
	local own = ns.Scan.playerSkills()
	local env = { money = ns.Logic.money }
	local i = 0
	local function nextOne()
		i = i + 1
		local id = ids[i]
		if not id then
			return
		end
		local prof = plan.professions[id]
		local r, from, to, why = ns.Scan.costOf(plan, id, prof, own[id], ns.settings())
		print("SkillupHelper: " .. ns.View.costLine(prof.name or id, from, to, r, env, why))
		C_Timer.After(0, nextOne)
	end
	nextOne()
	return true
end

SLASH_SKILLUPHELPER1 = "/skillup"
-- "/skillup effort 30": copper charged per craft by the planner ("/skillup effort" resets to the plan's default).
-- "/skillup recipes off": plan without buying recipe items ("on" plans with them again, the default).
function ns.command(msg)
	local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "ranks" or cmd == "exclude" then
		return ns.capCommand(cmd, arg)
	end
	if cmd == "cost" then
		return ns.costCommand(arg)
	end
	if cmd == "allow" then
		local spell = tonumber(arg)
		if not spell then
			print("SkillupHelper: /skillup allow <spellID> lets the plan use a shortcut recipe (again to stop).")
		elseif db and db.exclude and db.exclude.allow then
			local on = not db.exclude.allow[spell]
			ns.useShortcut(spell, on)
			print(("SkillupHelper: spell %d %s."):format(spell, on and "may be planned" or "is a shortcut again"))
		end
		return true
	end
	if cmd == "luck" then
		-- "/skillup luck 95": buys cover this percentile of crafts (50, 75, 80, 90, 95, 99; empty resets to 90)
		local n = tonumber(arg)
		if db then
			db.luck = ns.Planner.zOf(n) and n or nil
		end
		print(
			("SkillupHelper: buys cover a p%d run of crafts%s."):format(
				db and db.luck or ns.Planner.LUCK,
				(arg ~= "" and not ns.Planner.zOf(n)) and " (use 50, 75, 80, 90, 95 or 99)" or ""
			)
		)
		ns.refresh()
		return true
	end
	if cmd == "recipes" then
		local word = arg:lower()
		if word ~= "on" and word ~= "off" then
			print(("SkillupHelper: /skillup recipes on|off (now %s)."):format(db and db.noRecipeBuys and "off" or "on"))
			return true
		end
		if not db then
			print("SkillupHelper: SavedVariables not loaded yet, setting not changed.")
			return true
		end
		local off = word == "off"
		db.noRecipeBuys = off or nil
		print(
			off and "SkillupHelper: planning without buying recipes."
				or "SkillupHelper: planning with recipes to buy (/skillup recipes off to stop)."
		)
		ns.refresh()
		return true
	end
	if cmd == "resale" then
		-- "/skillup resale on": selling what you craft counts against a recipe's cost (off, the default: ranked by
		-- what you pay)
		local word = arg:lower()
		if word ~= "on" and word ~= "off" then
			print(("SkillupHelper: /skillup resale on|off (now %s)."):format(db and db.resale and "on" or "off"))
			return true
		end
		if not db then
			print("SkillupHelper: SavedVariables not loaded yet, setting not changed.")
			return true
		end
		db.resale = word == "on" or nil
		print(
			db.resale and "SkillupHelper: selling what you craft now counts against a recipe's cost."
				or "SkillupHelper: recipes ranked by what you pay; selling what you craft does not count."
		)
		ns.refresh()
		return true
	end
	if cmd ~= "effort" then
		return false
	end
	local n = tonumber(arg)
	if db then
		db.effort = (n and n >= 0) and n or nil
	end
	print(
		("SkillupHelper: effort %s copper a craft."):format(
			db and db.effort and tostring(db.effort)
				or "default (" .. tostring(ns.plan() and ns.plan().effort or ns.Planner.EFFORT) .. ")"
		)
	)
	ns.refresh()
	return true
end

SlashCmdList.SKILLUPHELPER = function(msg)
	if ns.command(msg) then
		return
	end
	if not ns.tradeSkillOpen then
		print("SkillupHelper: open a profession first.")
		return
	end
	ns.setShown(not ns.UI.frame:IsShown())
end
