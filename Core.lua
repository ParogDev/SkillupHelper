-- Events, SavedVariables, selftest and the /skillup command. The panel follows the profession window.
local ADDON, ns = ...
SkillupHelper = ns
ns.Data = ns.Data or {}

-- Bumped with every change, so a /reload shows which code loaded (the TOC says @project-version@ until packaged).
ns.CODE_VERSION = "0.1.1"

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
	st.tsm = ns.TSM.status()
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
		ns.lastScan = {
			at = date("%Y-%m-%d %H:%M:%S"),
			profession = model.profession,
			skill = model.skill,
			fromStock = model.fromStock and #model.fromStock or nil,
			planState = model.planState,
			why = model.why or model.planWhy,
			counts = model.counts,
			diag = model.diag,
			idSource = model.idSource,
			dock = ns.dockKind,
			tsm = ns.TSM.status(),
		}
	end)
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
f:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			SkillupHelperDB = ns.initDB(SkillupHelperDB)
			db = SkillupHelperDB
		end
	elseif event == "PLAYER_LOGIN" then
		db.selftest = nil
		ns.TSM.register()
		ns.onTSMChanged = function()
			if ns.tradeSkillOpen then
				redock()
			end
		end
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
SlashCmdList.SKILLUPHELPER = function()
	if not ns.tradeSkillOpen then
		print("SkillupHelper: open a profession first.")
		return
	end
	ns.setShown(not ns.UI.frame:IsShown())
end
