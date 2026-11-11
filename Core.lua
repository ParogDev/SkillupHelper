-- Events, SavedVariables, selftest and the /skillup command. The panel follows the profession window.
local ADDON, ns = ...
SkillupHelper = ns
ns.Data = ns.Data or {}

-- Bumped with every change, so a /reload shows which code loaded (the TOC says @project-version@ until packaged).
ns.CODE_VERSION = "0.2.0"

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
	st.plan = ns.selftest.planSummary(ns.Data.plan) or "Data/Plan.lua absent"
	st.lastScan = ns.lastScan
	-- the last scan of every profession opened this session, so Cooking and Leatherworking both show after one reload
	st.scans = ns.scans
	st.settings = { effort = db.effort, sellShare = db.sellShare }
	st.tsm = ns.TSM.status()
	st.craftedEvent = ns.craftedEvent
	local age = ns.TSM.ageHours(ns.Data.plan)
	st.tsmAgeHours = age and math.floor(age * 10 + 0.5) / 10
	st.tsmStale = age == nil or age > ns.TSM.STALE_HOURS
	st.lastError = ns.lastError
	db.selftest = st
end

local pending = false
function ns.refresh()
	if pending or not ns.UI.frame or not ns.UI.frame:IsShown() then
		return
	end
	pending = true
	C_Timer.After(0.3, function()
		pending = false
		local ok, model = pcall(ns.Scan.build, ns.Data.plan)
		if not ok then
			ns.lastError = tostring(model)
			model = { why = "scan failed: " .. tostring(model) }
		end
		ns.UI.show(model)
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
			colourMismatch = #p.colourMismatch,
			mismatches = p.colourMismatch,
			priceSources = p.prices,
			tsmAgeHours = ageHours and math.floor(ageHours * 10 + 0.5) / 10,
			tsmStale = ageHours == nil or ageHours > ns.TSM.STALE_HOURS,
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
	return { effort = db and db.effort, sellShare = db and db.sellShare }
end

function ns.setShown(shown)
	if db then
		db.shown = shown
	end
	if ns.UI.frame then
		ns.UI.frame:SetShown(shown)
	end
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
	ns.UI.dock(target)
	ns.dockKind = kind
end

local function open()
	ns.UI.create()
	ns.tradeSkillOpen = true
	ns.UI.frame:SetShown(db == nil or db.shown)
	redock()
	stopTicker()
	ticker = C_Timer.NewTicker(0.5, redock)
	ns.refresh()
end

local function close()
	ns.tradeSkillOpen = false
	stopTicker()
	if ns.UI.frame then
		ns.UI.frame:Hide()
	end
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
f:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			SkillupHelperDB = ns.initDB(SkillupHelperDB)
			db = SkillupHelperDB
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
	elseif event == "PLAYER_LOGOUT" then
		refreshSelftest()
	elseif event == "TRADE_SKILL_SHOW" then
		open()
	elseif event == "TRADE_SKILL_CLOSE" then
		close()
	elseif ns.tradeSkillOpen then
		ns.refresh()
	end
end)

SLASH_SKILLUPHELPER1 = "/skillup"
-- "/skillup effort 30": copper charged per craft by the planner ("/skillup effort" resets to the plan's default).
function ns.command(msg)
	local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
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
				or "default (" .. tostring(ns.Data.plan and ns.Data.plan.effort or 20) .. ")"
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
