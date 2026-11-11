-- Events, SavedVariables, selftest and the /skillup command. The panel follows the profession window.
local ADDON, ns = ...
SkillupHelper = ns
ns.Data = ns.Data or {}

-- Bumped with every change, so a /reload shows which code loaded (the TOC says @project-version@ until packaged).
ns.CODE_VERSION = "0.1.0"

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

local function attach()
	if ns.UI.frame or not ProfessionsFrame then
		return
	end
	ns.UI.create(ProfessionsFrame)
	ns.UI.frame:SetShown(db == nil or db.shown)
	ProfessionsFrame:HookScript("OnShow", ns.refresh)
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
for _, e in ipairs(REFRESH_EVENTS) do
	f:RegisterEvent(e)
end
f:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			SkillupHelperDB = ns.initDB(SkillupHelperDB)
			db = SkillupHelperDB
		elseif arg1 == "Blizzard_Professions" then
			attach()
		end
	elseif event == "PLAYER_LOGIN" then
		db.selftest = nil
		refreshSelftest()
		attach()
	elseif event == "PLAYER_LOGOUT" then
		refreshSelftest()
	elseif event == "TRADE_SKILL_SHOW" then
		attach()
		ns.refresh()
	else
		ns.refresh()
	end
end)

SLASH_SKILLUPHELPER1 = "/skillup"
SlashCmdList.SKILLUPHELPER = function()
	if not ns.UI.frame then
		print("SkillupHelper: open a profession window first.")
		return
	end
	ns.setShown(not ns.UI.frame:IsShown())
end
