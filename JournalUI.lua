-- The journal: one 960 x 640 window with six pages (Overview, Path, Where, Shopping, Alts and mail, Settings and
-- data). It draws view-models and reports clicks; it computes no plan and composes no sentence. Everything it needs
-- comes through J.provider (docs/ui.md, "Provider contract"); every page also takes its view-model directly
-- (J.setPage(name, vm)), which is how the tests drive it. Nothing is created until the first open.
local _, ns = ...
local W = ns.Widgets
local J = {}
ns.JournalUI = J
ns.Journal = J

local WIDTH, HEIGHT = 960, 640
local BODY_X, BODY_Y, BODY_W, BODY_H = 12, 76, 936, 512
local PAGES = {
	{ id = "overview", label = "Overview" },
	{ id = "path", label = "Path" },
	{ id = "where", label = "Where" },
	{ id = "shopping", label = "Shopping" },
	{ id = "alts", label = "Alts and mail" },
	{ id = "settings", label = "Settings and data" },
}
local PAGE = {}
for _, p in ipairs(PAGES) do
	PAGE[p.id] = p
end
local BINDING = "SKILLUPHELPER_JOURNAL"
local GATHERING = { herbalism = true, mining = true, skinning = true, fishing = true, lockpicking = true }

-- The integrator fills this table. Every entry is optional; a missing one is named in J.diag().missing.
--   journal(ctx)            -> { tabs = { { id, count, pip, tone } }, professions = { { key, name, learned } },
--                                profession, status, crumb }
--   page(name, ctx)         -> the page's view-model (overview, path, whereList, shopping, alts, settings)
--   context()               -> { profession, step }: what the docked panel shows now (for the open-journal button)
--   live(where, live)       -> strings for the tick ({ dist, line2, line3, ... }); may set live.nextIndex / floor / visited
--   trackerLive(trackerVM)  -> { title, right, rightTone, angle, ticks }
--   selectProfession(key), selectStep(step, action), selectSpot(key), trackSpot(key)
--   chooseWay(action, owner), shortcut(action), setting(key, value, action)
--   waypoint(where, pin) -> ok, why      (default: J.setWaypoint)
--   openMap(map, where) -> ok, why       (default: OpenWorldMap)
--   resetLearned(id), bindKey(key) -> ok, why (default: SetBinding + SaveBindings)
--   act(action, ...)                     any other action id (falls back to ns.UI.act)
J.provider = {}
J.stats = { opened = 0, pages = {}, acts = {}, missing = {}, lastWhy = nil }

local frame, pages, built = nil, {}, {}
local shell = {}

local function jstate()
	local s = W.state or {}
	W.state = s
	s.journal = s.journal or {}
	return s.journal
end

-- The state table the integrator backs with SavedVariables (SkillupHelperDB.ui). Plain fields are written:
-- journal = { point = { point, x, y }, page, profession, closeInCombat, filter, sort }, where = { mode },
-- field = { open, point }, tracker = { point, locked }.
function J.setState(t)
	W.state = type(t) == "table" and t or {}
	J.state = W.state
end

local function call(name, ...)
	local f = J.provider[name]
	if type(f) ~= "function" then
		J.stats.missing[name] = true
		return nil
	end
	local res = { pcall(f, ...) }
	if not res[1] then
		J.stats.lastWhy = ("provider.%s failed: %s"):format(name, tostring(res[2]))
		return nil
	end
	return res[2], res[3]
end
J.call = call

W.live = function(where, live)
	return call("live", where, live)
end
W.trackerLive = function(vm)
	return call("trackerLive", vm)
end

------------------------------------------------------------------------------------------------------ client actions

-- A user waypoint at a map position, super-tracked (as GuideUI.togglePin does). -> true, or false and the link.
function J.setWaypoint(map, x, y)
	if W.secret(map) or type(map) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
		return false, "no map position to pin"
	end
	if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint) then
		return false, "C_Map.SetUserWaypoint is absent"
	end
	local okCan, can = pcall(C_Map.CanSetUserWaypointOnMap, map)
	if not okCan or not can then
		return false, ("C_Map.CanSetUserWaypointOnMap(%d) refused: this map takes no pin"):format(map)
	end
	local ok, err = pcall(function()
		C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(map, x, y))
	end)
	if not ok then
		return false, "C_Map.SetUserWaypoint failed: " .. tostring(err)
	end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
	return true
end

function J.openMap(map)
	if type(OpenWorldMap) ~= "function" then
		return false, "OpenWorldMap is absent"
	end
	local ok, err = pcall(OpenWorldMap, type(map) == "number" and map or nil)
	return ok, not ok and ("OpenWorldMap failed: " .. tostring(err)) or nil
end

function J.bind(key)
	if InCombatLockdown and InCombatLockdown() then
		return false, "keys cannot be bound in a fight"
	end
	if not (SetBinding and SaveBindings and GetCurrentBindingSet) then
		return false, "SetBinding is absent"
	end
	local ok, done = pcall(SetBinding, key, BINDING)
	if not ok or not done then
		return false, "SetBinding refused " .. tostring(key)
	end
	pcall(function()
		SaveBindings(GetCurrentBindingSet())
	end)
	return true
end

-- Where a pin action points: the pin clicked, else the map's current target, else the place's centre.
local function pinTarget(a)
	local where = a.where or (pages.where and pages.where.where)
	local pin = a.pin
	local p = pin and (pin.p or pin)
	if p and type(p.x) == "number" then
		return where, p.x, p.y
	end
	local map = pages.where and pages.where.map
	if map and map.where == where and map.target then
		return where, map.target[1], map.target[2]
	end
	local area = where and where.area
	if area and type(area.x) == "number" then
		return where, area.x, area.y
	end
	local v = where and where.views and (where.views.spot or where.views.travel)
	if v then
		return where, v.cx or v[1], v.cy or v[2]
	end
	return where
end

-- The one door for clicks. Known ids go to their provider callback; the page is redrawn afterwards.
function J.act(a, owner)
	if type(a) ~= "table" or a.enabled == false then
		return
	end
	local id = a.id
	J.stats.acts[id or "?"] = (J.stats.acts[id or "?"] or 0) + 1
	local ok, why = true, nil
	if id == "journal" or id == "page" then
		J.open(a.page, a)
		return
	elseif id == "close" then
		J.close()
		return
	elseif id == "selectProfession" then
		jstate().profession = a.key
		J.ctx.profession, J.ctx.step, J.ctx.spot = a.key, nil, nil
		call("selectProfession", a.key)
		if a.page then
			jstate().page = a.page
		end
	elseif id == "selectStep" then
		J.ctx.step = a.step
		call("selectStep", a.step, a)
	elseif id == "selectSpot" then
		J.ctx.spot = a.key
		call("selectSpot", a.key)
	elseif id == "trackSpot" then
		call("trackSpot", a.key)
	elseif id == "wayMenu" or id == "useWay" or id == "way" or id == "swap" then
		call("chooseWay", a, owner)
	elseif id == "shortcut" or id == "allow" or id == "hide" then
		call("shortcut", a)
	elseif id == "setting" then
		if a.key == "closeInCombat" then
			jstate().closeInCombat = a.value and true or false
		end
		call("setting", a.key, a.value, a)
	elseif id == "pin" then
		local where, x, y = pinTarget(a)
		if J.provider.waypoint then
			ok, why = call("waypoint", where, a.pin)
		else
			ok, why = J.setWaypoint(where and where.map, x, y)
		end
	elseif id == "openMap" then
		local where = a.where or (pages.where and pages.where.where)
		local map = a.map or (where and where.map)
		if J.provider.openMap then
			ok, why = call("openMap", map, where)
		else
			ok, why = J.openMap(map)
		end
	elseif id == "resetLearned" then
		call("resetLearned", a.list or a.key)
	elseif id == "bindKey" then
		J.captureKey()
		return
	elseif id == "mapMode" then
		if pages.where then
			pages.where.map:SetMode(a.mode)
		end
		return
	elseif J.provider.act then
		call("act", a, owner)
	elseif ns.UI and ns.UI.act then
		ns.UI.act(a)
	else
		ok, why = false, "no handler for action " .. tostring(id)
	end
	if ok == false then
		J.stats.lastWhy = why
		J.flash(why)
	end
	J.refresh()
end
W.onAction = J.act

-------------------------------------------------------------------------------------------------------------- shell

local function tab(parent, def)
	local b = W.frame("Button", nil, parent)
	b:SetSize(128, 26)
	b.id = def.id
	b.hover = W.tex(b, "BACKGROUND")
	b.hover:SetAllPoints()
	W.fill(b.hover, "line", 0.4)
	b.hover:Hide()
	b.label = W.text(b, "GameFontHighlight", 12)
	b.label:SetPoint("CENTER", 0, 1)
	b.label:SetJustifyH("CENTER")
	b.under = W.tex(b, "ARTWORK")
	b.under:SetHeight(2)
	b.under:SetPoint("BOTTOMLEFT")
	b.under:SetPoint("BOTTOMRIGHT")
	b.pip = W.disc(b, 6, "OVERLAY")
	b.pip:SetPoint("TOPRIGHT", -6, -5)
	b.pip:SetVertexColor(W.rgb("warn"))
	b:SetScript("OnEnter", function(self)
		self.hover:Show()
		W.showTip(self, self.tip)
	end)
	b:SetScript("OnLeave", function(self)
		self.hover:Hide()
		W.hideTip(self)
	end)
	b:SetScript("OnClick", function(self)
		J.open(self.id)
	end)
	return b
end

local function paintTabs(vm)
	local by = {}
	for _, t in ipairs(vm and vm.tabs or {}) do
		by[t.id] = t
	end
	local page = jstate().page
	for _, b in ipairs(shell.tabs) do
		local t = by[b.id] or {}
		local on = b.id == page
		local label = t.label or PAGE[b.id].label
		if t.count and t.count ~= 0 then
			label = label .. " " .. tostring(t.count)
		end
		W.set(b.label, label, on and "bone" or (t.tone or "ash"))
		-- the selected tab: bone text and a 2-px gold underline; the others keep a 1-px line
		b.under:SetHeight(on and 2 or 1)
		W.fill(b.under, on and "gold" or "line")
		b.pip:SetShown(t.pip == true)
		b.tip = t.tip
	end
end

local function professionMenu()
	local vm = shell.vm or {}
	local items = {}
	for pass = 1, 2 do
		for _, p in ipairs(vm.professions or {}) do
			if (p.learned and pass == 1) or (not p.learned and pass == 2) then
				items[#items + 1] = {
					label = p.learned and p.name or (p.label or (p.name .. " (not learned)")),
					kind = "radio",
					checked = p.key == (vm.profession or jstate().profession),
					action = { id = "selectProfession", key = p.key, enabled = true },
				}
			end
		end
	end
	local ok, why = W.menu(shell.prof, { title = "Profession", items = items })
	if not ok then
		J.stats.lastWhy = why
	end
end

local function drawShell(vm)
	shell.vm = vm or shell.vm or {}
	vm = shell.vm
	local page = jstate().page
	paintTabs(vm)
	local name
	for _, p in ipairs(vm.professions or {}) do
		if p.key == (vm.profession or jstate().profession) then
			name = p.name
		end
	end
	-- the breadcrumb: profession (a dropdown) > step. Hidden on the pages that are not about one profession.
	local scoped = page ~= "overview" and page ~= "settings"
	shell.prof:SetShown(scoped)
	shell.crumb:SetShown(scoped)
	if scoped then
		W.set(shell.prof.label, name or vm.profession or "Pick a profession")
		shell.prof:SetWidth(math.max(120, math.min(220, (shell.prof.label:GetStringWidth() or 0) + 40)))
		W.paintButton(shell.prof)
		W.set(shell.crumb, vm.crumb and ("> " .. vm.crumb) or "", "ash")
	end
	W.set(shell.status, shell.flash or vm.status or "", shell.flash and "warn" or "ash")
	local key
	if GetBindingKey then
		local ok, k = pcall(GetBindingKey, BINDING)
		key = ok and k or nil
	end
	W.set(shell.hint, key and ("Key: " .. tostring(key)) or "No key set. Settings and data has one.", "ash")
end

-- One line in the status bar for a refused action (which link broke); cleared by the next page change.
function J.flash(text)
	shell.flash = text
	if frame and shell.status then
		W.set(shell.status, text or (shell.vm and shell.vm.status) or "", text and "warn" or "ash")
	end
end

local function create()
	frame = W.frame("Frame", "SkillupHelperJournal", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	-- HIGH with toplevel: over the world and the profession window when clicked, never above dialogs or tooltips
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:SetBackdrop({ bgFile = W.WHITE, edgeFile = W.WHITE, edgeSize = 1 })
	frame:SetBackdropColor(W.rgb("ink"))
	frame:SetBackdropBorderColor(W.rgb("line"))
	local uiH = UIParent and UIParent.GetHeight and UIParent:GetHeight()
	if type(uiH) == "number" and uiH > 0 and uiH < 680 then
		frame:SetScale(math.max(0.8, (uiH - 40) / HEIGHT))
	end
	local s = jstate()
	if type(s.point) == "table" and s.point[1] then
		frame:SetPoint(s.point[1], UIParent, s.point[1], s.point[2] or 0, s.point[3] or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	local special = _G.UISpecialFrames
	if type(special) == "table" then
		table.insert(special, "SkillupHelperJournal") -- Escape closes it
	end

	-- the 40-px title band moves the window
	local band = W.frame("Frame", nil, frame)
	band:SetPoint("TOPLEFT")
	band:SetPoint("TOPRIGHT")
	band:SetHeight(40)
	band:EnableMouse(true)
	band:RegisterForDrag("LeftButton")
	band:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	band:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, _, x, y = frame:GetPoint(1)
		if point then
			jstate().point = { point, x, y }
		end
	end)
	shell.title = W.text(band, "GameFontNormalLarge", 15)
	shell.title:SetPoint("TOPLEFT", 14, -12)
	W.set(shell.title, "SkillupHelper", "gold")
	shell.prof = W.button(band, 140, 22)
	shell.prof:SetPoint("TOPLEFT", 150, -9)
	shell.prof.label:SetJustifyH("LEFT")
	shell.prof.arrow = W.tex(shell.prof, "OVERLAY")
	shell.prof.arrow:SetSize(10, 10)
	shell.prof.arrow:SetPoint("RIGHT", -6, 0)
	shell.prof.arrow:SetTexture(W.ARROW)
	shell.prof.arrow:SetRotation(-math.pi / 2)
	shell.prof.tip = "Pick the profession these pages show."
	shell.prof.onClick = professionMenu
	shell.crumb = W.text(band, "GameFontHighlight", 12)
	shell.crumb:SetPoint("LEFT", shell.prof, "RIGHT", 10, 0)
	shell.crumb:SetPoint("RIGHT", band, "RIGHT", -44, 0)
	shell.close = W.button(band, 22, 22)
	shell.close:SetPoint("TOPRIGHT", -9, -9)
	W.set(shell.close.label, "x")
	shell.close.tip = "Close (Escape)"
	shell.close.onClick = function()
		J.close()
	end
	W.paintButton(shell.close)

	shell.tabs = {}
	for i, def in ipairs(PAGES) do
		local b = tab(frame, def)
		b:SetPoint("TOPLEFT", 12 + (i - 1) * 132, -42)
		shell.tabs[i] = b
	end
	shell.tabLine = W.tex(frame, "BORDER")
	shell.tabLine:SetHeight(1)
	shell.tabLine:SetPoint("TOPLEFT", 12, -68)
	shell.tabLine:SetPoint("TOPRIGHT", -12, -68)
	W.fill(shell.tabLine, "line")

	shell.body = W.frame("Frame", nil, frame)
	shell.body:SetSize(BODY_W, BODY_H)
	shell.body:SetPoint("TOPLEFT", BODY_X, -BODY_Y)
	shell.footLine = W.tex(frame, "BORDER")
	shell.footLine:SetHeight(1)
	shell.footLine:SetPoint("BOTTOMLEFT", 12, 28)
	shell.footLine:SetPoint("BOTTOMRIGHT", -12, 28)
	W.fill(shell.footLine, "line")
	shell.hint = W.text(frame, "GameFontHighlightSmall", 10)
	shell.hint:SetPoint("BOTTOMRIGHT", -14, 9)
	shell.hint:SetJustifyH("RIGHT")
	shell.status = W.text(frame, "GameFontHighlightSmall", 10)
	shell.status:SetPoint("BOTTOMLEFT", 14, 9)
	shell.status:SetPoint("RIGHT", shell.hint, "LEFT", -12, 0)
	shell.empty = W.empty(shell.body, 520)
	shell.empty:SetPoint("TOPLEFT", 24, -40)
	shell.empty:Hide()

	frame:RegisterEvent("PLAYER_REGEN_DISABLED")
	frame:SetScript("OnEvent", function(self, event)
		if event == "PLAYER_REGEN_DISABLED" then
			J.stopCapture()
			if jstate().closeInCombat ~= false then
				self:Hide()
			end
		end
	end)
	frame:SetScript("OnShow", function()
		J.stats.opened = J.stats.opened + 1
	end)
	frame:SetScript("OnHide", function()
		-- hidden: the map views' OnUpdate stops with their frames; only a pending key capture needs ending
		J.stopCapture()
	end)
	frame:Hide()
end

-- A page's empty state: its frames hide and one explanation takes the body.
local function pageEmpty(p, empty)
	if empty then
		for _, part in ipairs(p.parts or {}) do
			part:Hide()
		end
		shell.empty:Set(empty)
	else
		for _, part in ipairs(p.parts or {}) do
			part:Show()
		end
		shell.empty:Hide()
	end
	return empty ~= nil
end

local function pageFrame()
	local p = W.frame("Frame", nil, shell.body)
	p:SetAllPoints(shell.body)
	p:Hide()
	return p
end

------------------------------------------------------------------------------------------------------------ overview

local FILTERS = {
	{ id = "mine", label = "Mine", tip = "Professions this character has learned." },
	{ id = "all", label = "All" },
	{ id = "crafting", label = "Crafting" },
	{ id = "gathering", label = "Gathering" },
}
local SORTS = { { id = "name", label = "Name" }, { id = "skill", label = "Skill" }, { id = "cost", label = "Cost" } }
local CAPS = { 75, 150, 225, 300 }

local function overviewRows(vm)
	local s = jstate()
	local filter, sort = s.filter or "all", s.sort or "name"
	local out = {}
	for _, r in ipairs(vm.rows or {}) do
		local group = r.group or (GATHERING[tostring(r.key):lower()] and "gathering" or "crafting")
		if filter == "all" or (filter == "mine" and r.learned) or filter == group then
			out[#out + 1] = r
		end
	end
	if sort == "skill" then
		table.sort(out, function(a, b)
			local x, y = a.skill or -1, b.skill or -1
			if x ~= y then
				return x > y
			end
			return tostring(a.name) < tostring(b.name)
		end)
	elseif sort == "cost" then
		table.sort(out, function(a, b)
			local x, y = a.cost and a.cost.copper or math.huge, b.cost and b.cost.copper or math.huge
			if x ~= y then
				return x < y
			end
			return tostring(a.name) < tostring(b.name)
		end)
	elseif sort == "name" then
		table.sort(out, function(a, b)
			return tostring(a.name) < tostring(b.name)
		end)
	end
	return out
end

local function coverageTip(r)
	local tip = { r.name or "" }
	local cov = r.coverage or {}
	if r.statusText then
		tip[#tip + 1] = { r.statusText, r.status == "complete" and "green" or "warn" }
	end
	for _, g in ipairs(cov.gaps or {}) do
		tip[#tip + 1] = {
			("%s to %s: %s"):format(tostring(g.from), tostring(g.to), tostring(g.reason or "no reason given")),
			"warn",
		}
		for _, item in ipairs(g.lacks or {}) do
			tip[#tip + 1] = "   no price: " .. tostring(item)
		end
	end
	if r.tsmMissing and r.tsmMissing > 0 then
		tip[#tip + 1] = ("Prices missing: %d"):format(r.tsmMissing)
	end
	if r.why then
		tip[#tip + 1] = r.why
	end
	return tip
end

local function overviewRow(list)
	local r = W.rowButton(list, 37)
	r.icon = W.tex(r, "ARTWORK")
	r.icon:SetSize(18, 18)
	r.icon:SetPoint("TOPLEFT", 8, -5)
	r.name = W.text(r, "GameFontHighlight", 12)
	r.name:SetPoint("TOPLEFT", 34, -7)
	r.name:SetWidth(120)
	r.rank = W.band(r, 110, 6)
	r.rank:Place("TOPLEFT", r, "TOPLEFT", 160, -11)
	r.skill = W.text(r, "GameFontHighlightSmall", 11)
	r.skill:SetPoint("TOPLEFT", 278, -8)
	r.skill:SetWidth(64)
	local function right(x, font, size)
		local fs = W.text(r, font, size)
		fs:SetPoint("TOPRIGHT", r, "TOPLEFT", x, size == 13 and -6 or -8)
		fs:SetWidth(72)
		fs:SetJustifyH("RIGHT")
		return fs
	end
	r.total = right(420, "GameFontHighlight", 13)
	r.mats = right(496, "GameFontHighlightSmall", 11)
	r.recipes = right(566, "GameFontHighlightSmall", 11)
	r.training = right(636, "GameFontHighlightSmall", 11)
	r.cover = W.band(r, 150, 6)
	r.cover:Place("TOPLEFT", r, "TOPLEFT", 664, -11)
	r.state = W.text(r, "GameFontHighlightSmall", 11)
	r.state:SetPoint("TOPLEFT", 822, -8)
	r.state:SetWidth(100)
	r.line = W.text(r, "GameFontHighlightSmall", 10)
	r.line:SetPoint("TOPLEFT", 664, -22)
	r.line:SetWidth(258)
	r.rowLine = W.tex(r, "BORDER")
	r.rowLine:SetHeight(1)
	r.rowLine:SetPoint("BOTTOMLEFT")
	r.rowLine:SetPoint("BOTTOMRIGHT")
	W.fill(r.rowLine, "line", 0.6)
	r.labels = { r.name, r.line }
	return r
end

local function drawOverviewRow(r, row)
	local dim = row.usable == false
	r:SetAlpha(dim and 0.5 or 1)
	r.action = { id = "selectProfession", key = row.key, page = "path", enabled = not dim }
	r.tip = coverageTip(row)
	W.icon(r.icon, row.icon)
	W.set(r.name, row.name, row.learned and "bone" or "ash")
	local cap = row.cap or 300
	r.rank:Set(
		{ { from = 0, to = row.skill or 0, color = "gold" } },
		{ lo = 0, hi = 300 },
		nil,
		{ ticks = CAPS, track = 0.9 }
	)
	if dim then
		W.set(r.skill, row.why or "not available", "ash")
	elseif row.learned and row.skill then
		W.set(r.skill, ("%d / %d"):format(row.skill, cap), "bone")
	else
		W.set(r.skill, "not learned", "ash")
	end
	local c = row.cost or {}
	W.set(r.total, c.total or (dim and "" or "no price"), c.total and "bone" or "warn")
	W.set(r.mats, c.mats or "", "ash")
	W.set(r.recipes, c.recipes or "", "ash")
	W.set(r.training, c.training or "", "ash")
	local cov = row.coverage or {}
	local done = cov.done or row.skill or 0
	local segs = {
		{ from = 0, to = done, color = "ash", alpha = 0.45 },
		{ from = done, to = 300, color = "bone", alpha = 0.75 },
	}
	if row.status == "nodata" then
		segs = {}
	end
	for _, g in ipairs(cov.gaps or {}) do
		segs[#segs + 1] = { from = g.from, to = g.to, color = "warn", hatch = true }
	end
	r.cover:Set(segs, { lo = 0, hi = 300 }, nil, { raise = 1, track = 0.5 })
	W.set(
		r.state,
		row.statusText or row.status or "",
		row.status == "complete" and "green" or (row.status == "gaps" and "warn" or "ash")
	)
	W.set(r.line, row.line or "", row.lineTone or "ash")
	W.selectRow(r, row.key == (shell.vm and shell.vm.profession or jstate().profession), "gold")
end

built.overview = function()
	local p = pageFrame()
	p.filters = W.segments(p, 22)
	p.filters:SetPoint("TOPLEFT", 0, 0)
	p.sortLabel = W.text(p, "GameFontHighlightSmall", 11)
	W.set(p.sortLabel, "Sort by", "ash")
	p.sorts = W.segments(p, 22)
	p.sorts:SetPoint("TOPRIGHT", 0, 0)
	p.sortLabel:SetPoint("RIGHT", p.sorts, "LEFT", -8, 0)
	p.heads = {}
	local function head(label, x, rightEdge)
		local fs = W.text(p, "GameFontNormalSmall", 11)
		if rightEdge then
			fs:SetPoint("TOPRIGHT", p, "TOPLEFT", x, -34)
			fs:SetJustifyH("RIGHT")
		else
			fs:SetPoint("TOPLEFT", x, -34)
		end
		W.set(fs, label, "gold")
		p.heads[#p.heads + 1] = fs
	end
	head("Profession", 34)
	head("Skill", 160)
	head("Cost to 300", 420, true)
	head("Materials", 496, true)
	head("Recipes", 566, true)
	head("Training", 636, true)
	head("Path known, 1 to 300", 664)
	p.headLine = W.tex(p, "BORDER")
	p.headLine:SetHeight(1)
	p.headLine:SetPoint("TOPLEFT", 0, -51)
	p.headLine:SetPoint("TOPRIGHT", 0, -51)
	W.fill(p.headLine, "line")
	p.list = W.list(p, BODY_W, BODY_H - 54, { make = overviewRow, draw = drawOverviewRow, rowHeight = 37 })
	p.list:SetPoint("TOPLEFT", 0, -54)
	p.none = W.empty(p, 520)
	p.none:SetPoint("TOPLEFT", 34, -80)
	p.parts = { p.filters, p.sorts, p.sortLabel, p.list, p.headLine }
	for _, h in ipairs(p.heads) do
		p.parts[#p.parts + 1] = h
	end
	function p:Draw(vm)
		if
			pageEmpty(self, (not vm or not vm.rows) and (vm and vm.empty or {
				title = "No professions read yet",
				text = "The profession list comes from the plan data and this character's skills. "
					.. "Open a profession window once, or wait for the first scan.",
			}) or nil)
		then
			self.none:Hide()
			return { rows = 0, gaps = 0 }
		end
		self.vm = vm
		local s = jstate()
		local redraw = function()
			self:Draw(self.vm)
		end
		self.filters:Set(FILTERS, s.filter or "all", function(id)
			s.filter = id
			redraw()
		end)
		self.sorts:Set(SORTS, s.sort or "name", function(id)
			s.sort = id
			redraw()
		end)
		local rows = overviewRows(vm)
		self.list:SetItems(rows)
		if #rows == 0 then
			self.none:Set({
				title = "No profession matches this filter",
				text = "This character has learned none of them, or the filter leaves none.",
				action = { id = "showAll", label = "Show all professions", enabled = true },
			})
			self.none.btn.onClick = function()
				s.filter = "all"
				redraw()
			end
		else
			self.none:Hide()
		end
		local gaps = 0
		for _, r in ipairs(rows) do
			gaps = gaps + #(r.coverage and r.coverage.gaps or {})
		end
		return { rows = #rows, gaps = gaps, shown = self.list.rows.n }
	end
	return p
end

---------------------------------------------------------------------------------------------------------------- path

local TL_X, TL_PX = 18, 3
local LEGEND = "Diamond: trainer.  Gold square: recipe from the auction house.  Bone square: recipe from a vendor.  "
	.. "Broken square: Bind on Pickup shortcut.  Hatched: nothing priced."

local function timeline(parent)
	local t = W.card(parent, BODY_W, 128)
	t:EnableMouse(true)
	t.quads = W.pool(function()
		return W.tex(t, "ARTWORK")
	end)
	t.labels = W.pool(function()
		return W.text(t, "GameFontHighlightSmall", 10)
	end)
	local function quad(x, y, wd, ht, tone, alpha, sub, rot)
		local q = W.take(t.quads)
		q:ClearAllPoints()
		q:SetPoint("CENTER", t, "TOPLEFT", x + wd / 2, -(y + ht / 2))
		q:SetSize(wd, ht)
		q:SetDrawLayer("ARTWORK", sub or 0)
		local r, g, b = W.rgb(tone)
		q:SetColorTexture(r, g, b, alpha or 1)
		q:SetRotation(rot or 0)
		q:Show()
		return q
	end
	local function label(x, y, s, tone, size, point, alpha)
		local fs = W.take(t.labels)
		fs:SetFontHeight(size or 10)
		fs:ClearAllPoints()
		fs:SetPoint(point or "TOPLEFT", t, "TOPLEFT", x, -y)
		fs:SetWidth(0)
		W.set(fs, s, tone or "ash", alpha)
		fs:Show()
		return fs
	end
	local function X(skill)
		return TL_X + math.max(0, math.min(300, skill or 0)) * TL_PX
	end
	local function box(x, y, size, edge, inner, innerAlpha, broken)
		quad(x - size / 2, y, size, size, edge, 1, 2)
		quad(x - size / 2 + 1, y + 1, size - 2, size - 2, "surface", 1, 3)
		if inner then
			quad(x - size / 2 + 1, y + 1, size - 2, size - 2, inner, innerAlpha, 4)
		end
		if broken then
			-- a broken edge: a notch in the middle of each side, so "not on the path yet" does not rest on colour
			quad(x - 1.5, y, 3, size, "surface", 1, 5)
			quad(x - size / 2, y + size / 2 - 1.5, size, 3, "surface", 1, 5)
		end
	end
	function t:Set(vm)
		W.start(self.quads)
		W.start(self.labels)
		self.vm = vm
		local skill = vm.skill
		if W.secret(skill) or type(skill) ~= "number" then
			skill = nil
		end
		for _, c in ipairs(vm.caps or {}) do
			quad(X(c.at), 4, 1, 92, "ash", 0.7, 0)
			label(X(c.at) - 4, 4, c.label, "ash", 10, "TOPRIGHT")
		end
		for v = 0, 300, 25 do
			quad(X(v), 78, 1, 6, "ash", 0.8, 0)
			label(X(v), 86, v, "ash", 10, "TOP")
		end
		local marked = {}
		for _, m in ipairs(vm.markers or {}) do
			local x = X(m.at)
			marked[m.at] = true
			if m.kind == "train" then
				quad(x - 4, 29.5, 8, 8, "gold", 1, 2, math.pi / 4)
			elseif m.kind == "ah" then
				box(x, 28, 11, "gold", "gold", 0.25)
			elseif m.kind == "vendor" then
				box(x, 28, 11, "bone")
			else
				box(x, 28, 11, "parch", nil, nil, true)
			end
		end
		for _, at in ipairs(vm.gates or {}) do
			if not marked[at] then
				quad(X(at) - 4, 29.5, 8, 8, "gold", 0.6, 2, math.pi / 4)
			end
		end
		for _, s in ipairs(vm.segments or {}) do
			local x1, x2 = X(s.from), X(s.to) - 1
			local wd = math.max(1, x2 - x1)
			if s.gap then
				quad(x1, 50, wd, 24, "warn", 0.18, 1)
				quad(x1, 50, wd, 1, "warn", 1, 2)
				quad(x1, 73, wd, 1, "warn", 1, 2)
				for sx = x1 + 2, x2 - 1, 4 do
					quad(sx, 50, 1, 24, "warn", 0.9, 2)
				end
			else
				local bands = s.bands or { { from = s.from, to = s.to, color = "grey" } }
				for _, b in ipairs(bands) do
					local bx1, bx2 = math.max(x1, X(b.from)), math.min(x2, X(b.to))
					if bx2 > bx1 then
						quad(bx1, 50, bx2 - bx1, 24, b.color, s.done and 0.32 or 1, 1)
					end
				end
				if s.name and wd >= 24 then
					local fs = label(x1 + 4, 56, s.name, s.done and "bone" or "ink", 11, "TOPLEFT", s.done and 0.7 or 1)
					if (fs:GetStringWidth() or 0) > wd - 6 then
						fs:Hide() -- it does not fit: the name is in the tooltip
					end
				end
			end
			if s.step ~= nil and s.step == vm.selected then
				quad(x1 - 2, 48, wd + 4, 2, "bone", 1, 6)
				quad(x1 - 2, 74, wd + 4, 2, "bone", 1, 6)
				quad(x1 - 2, 48, 2, 28, "bone", 1, 6)
				quad(x2, 48, 2, 28, "bone", 1, 6)
			end
		end
		if skill then
			quad(X(skill), 18, 1, 64, "bone", 1, 7)
			label(X(skill), 98, vm.nowLabel or ("you, %d"):format(skill), "bone", 11, "TOP")
		end
		label(BODY_W - 12, 112, vm.legend or LEGEND, "ash", 10, "TOPRIGHT")
		W.finish(self.quads)
		W.finish(self.labels)
	end
	-- what is under the cursor: a marker (within 6 px, in its lane) or the segment at that skill
	function t:At()
		local vm = self.vm
		local left, top, scale = self:GetLeft(), self:GetTop(), self:GetEffectiveScale()
		local cx, cy = GetCursorPosition()
		if not (vm and left and top and cx and cy and scale and scale > 0) then
			return nil
		end
		local lx, ly = cx / scale - left, top - cy / scale
		if ly >= 24 and ly <= 43 then
			for _, m in ipairs(vm.markers or {}) do
				if math.abs(X(m.at) - lx) <= 6 then
					return m, "marker"
				end
			end
		end
		if ly >= 46 and ly <= 78 then
			local skill = (lx - TL_X) / TL_PX
			for _, s in ipairs(vm.segments or {}) do
				if skill >= s.from and skill < s.to then
					return s, "segment"
				end
			end
		end
		return nil
	end
	t:SetScript("OnMouseUp", function(self)
		local hit = self:At()
		if hit and hit.step then
			W.act({ id = "selectStep", step = hit.step, enabled = true })
		end
	end)
	-- the hover scan runs only while the mouse is over the timeline
	t:SetScript("OnEnter", function(self)
		local acc = 0
		self:SetScript("OnUpdate", function(_, elapsed)
			acc = acc + (elapsed or 0)
			if acc < 0.1 then
				return
			end
			acc = 0
			local hit, kind = self:At()
			if hit ~= self.tipHit then
				self.tipHit = hit
				if not hit then
					W.hideTip(self)
				elseif kind == "marker" then
					W.showTip(self, hit.tip or ("At " .. tostring(hit.at)))
				else
					W.showTip(self, {
						hit.name or "Gap",
						("%s to %s"):format(tostring(hit.from), tostring(hit.to)),
						hit.gap and { hit.gap.reason or "", "warn" } or nil,
					})
				end
			end
		end)
	end)
	t:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		self.tipHit = nil
		W.hideTip(self)
	end)
	return t
end

local function stepRow(list)
	local r = W.rowButton(list, 46)
	r.n = W.text(r, "GameFontHighlightSmall", 11)
	r.n:SetPoint("LEFT", 4, 0)
	r.n:SetWidth(22)
	r.n:SetJustifyH("RIGHT")
	r.icon = W.tex(r, "ARTWORK")
	r.icon:SetSize(24, 24)
	r.icon:SetPoint("LEFT", 32, 0)
	r.btn = W.button(r, 78, 22)
	r.btn:SetPoint("RIGHT", -4, 0)
	r.cost = W.text(r, "GameFontHighlight", 12)
	r.cost:SetPoint("RIGHT", r, "LEFT", 472, 0)
	r.cost:SetWidth(70)
	r.cost:SetJustifyH("RIGHT")
	r.range = W.text(r, "GameFontHighlightSmall", 11)
	r.range:SetPoint("RIGHT", r, "LEFT", 398, 0)
	r.range:SetWidth(84)
	r.range:SetJustifyH("RIGHT")
	r.title = W.text(r, "GameFontHighlight", 12)
	r.title:SetPoint("TOPLEFT", 64, -8)
	r.title:SetPoint("RIGHT", r.range, "LEFT", -8, 0)
	r.sub = W.text(r, "GameFontHighlightSmall", 10)
	r.sub:SetPoint("TOPLEFT", 64, -25)
	r.sub:SetPoint("RIGHT", r.range, "LEFT", -8, 0)
	r.rowLine = W.tex(r, "BORDER")
	r.rowLine:SetHeight(1)
	r.rowLine:SetPoint("BOTTOMLEFT")
	r.rowLine:SetPoint("BOTTOMRIGHT")
	W.fill(r.rowLine, "line", 0.6)
	r.labels = { r.title, r.sub }
	return r
end

local function drawStepRow(r, row)
	local fold = row.kind == "fold"
	r.tip = row.tip
	r.action = row.action or (not fold and row.n and { id = "selectStep", step = row.n, enabled = true }) or nil
	r.icon:SetShown(not fold)
	if not fold then
		W.icon(r.icon, row.icon)
	end
	W.set(r.n, fold and "" or row.n or "", "ash")
	r.title:ClearAllPoints()
	r.title:SetPoint(fold and "LEFT" or "TOPLEFT", fold and 32 or 64, fold and 0 or -8)
	r.title:SetPoint("RIGHT", r.range, "LEFT", -8, 0)
	W.set(
		r.title,
		row.title,
		(fold and "ash") or (row.kind == "gap" and "warn") or (row.kind == "unlock" and "gold") or "bone"
	)
	W.set(r.sub, fold and "" or row.sub or "", row.kind == "gap" and "warn" or "ash")
	-- the range wears the band colour and its letter
	local letter = W.BAND_LETTER[row.rangeTone]
	W.set(
		r.range,
		row.range and ((letter and letter ~= "-" and (letter .. " ") or "") .. row.range) or "",
		row.rangeTone or "ash"
	)
	W.set(r.cost, row.cost or "", "bone")
	local selected = row.selected or (J.pathSelected ~= nil and row.n == J.pathSelected and not fold)
	W.selectRow(r, selected, row.rangeTone or "bone")
	if row.kind == "gap" and row.action then
		W.setButton(r.btn, row.action, "quiet")
		r.action = nil
	elseif row.ways and row.ways > 1 then
		W.setButton(r.btn, {
			id = "wayMenu",
			step = row.n,
			row = row,
			label = row.waysLabel or ("%d ways"):format(row.ways),
			enabled = true,
		}, "quiet")
		r.btn.onClick = function(self)
			J.act(self.action, self)
		end
	else
		r.btn:Hide()
	end
end

local function detail(parent)
	local d = W.card(parent, 356, 376)
	local inner = 356 - 3 - 24
	d.scroll = W.scroll(d, 356 - 3 - 12, 200)
	d.scroll:SetPoint("TOPLEFT", 15, -12)
	local c = d.scroll.content
	d.title = W.para(c, "GameFontHighlightLarge", 15, inner)
	d.paras = W.pool(function()
		return W.para(c, "GameFontHighlightSmall", 11, inner)
	end)
	d.heads = W.pool(function()
		return W.header(c, inner)
	end)
	d.reagents = W.pool(function()
		local r = W.frame("Frame", nil, c)
		r:SetSize(inner, 18)
		r.price = W.text(r, "GameFontHighlightSmall", 11)
		r.price:SetPoint("RIGHT", 0, 0)
		r.price:SetWidth(96)
		r.price:SetJustifyH("RIGHT")
		r.count = W.text(r, "GameFontHighlightSmall", 11)
		r.count:SetPoint("RIGHT", r.price, "LEFT", -8, 0)
		r.count:SetWidth(56)
		r.count:SetJustifyH("RIGHT")
		r.name = W.text(r, "GameFontHighlightSmall", 11)
		r.name:SetPoint("LEFT", 0, 0)
		r.name:SetPoint("RIGHT", r.count, "LEFT", -8, 0)
		r:EnableMouse(true)
		r:SetScript("OnEnter", function(self)
			W.showTip(self, W.tipOf(self, self.name, self.price))
		end)
		r:SetScript("OnLeave", W.hideTip)
		return r
	end)
	d.ways = W.pool(function()
		local r = W.rowButton(c, 22)
		r:SetWidth(inner)
		r.outer = W.disc(r, 12, "ARTWORK", 1)
		r.outer:SetPoint("LEFT", 2, 0)
		r.mid = W.disc(r, 10, "ARTWORK", 2)
		r.mid:SetPoint("CENTER", r.outer, "CENTER")
		r.dot = W.disc(r, 6, "ARTWORK", 3)
		r.dot:SetPoint("CENTER", r.outer, "CENTER")
		r.right = W.text(r, "GameFontHighlightSmall", 11)
		r.right:SetPoint("RIGHT", -4, 0)
		r.right:SetJustifyH("RIGHT")
		r.label = W.text(r, "GameFontHighlightSmall", 11)
		r.label:SetPoint("LEFT", 22, 0)
		r.label:SetPoint("RIGHT", r.right, "LEFT", -8, 0)
		r.labels = { r.label, r.right }
		return r
	end)
	d.map = ns.MapCanvas.new(d, 330, 92, {
		header = "none",
		onClick = function(map)
			if map.where then
				W.act({ id = "journal", page = "where", spot = map.where.key, enabled = true })
			end
		end,
	})
	d.map:SetPoint("BOTTOMLEFT", 15, 44)
	d.mapChip = W.chip(d.map.top)
	d.mapChip:SetPoint("BOTTOMLEFT", 6, 6)
	d.buttons = W.pool(function()
		return W.button(d, 96, 24)
	end)
	function d:Set(v)
		for _, pool in ipairs({ self.paras, self.heads, self.reagents, self.ways }) do
			W.start(pool)
		end
		if not v then
			self.title:Hide()
			self.map:Hide()
			W.buttonRow(self.buttons, self, {}, 0, 0, 10)
			local fs = W.take(self.paras)
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", 0, 0)
			W.set(fs, "Pick a step in the list or on the timeline to see what it needs and where it is done.", "ash")
			fs:Show()
			self:Rule(nil)
			for _, pool in ipairs({ self.paras, self.heads, self.reagents, self.ways }) do
				W.finish(pool)
			end
			self.scroll:SetContentHeight(40)
			return
		end
		self:Rule(v.color or "bone")
		local y = 0
		self.title:ClearAllPoints()
		self.title:SetPoint("TOPLEFT", 0, 0)
		W.set(self.title, v.title, "bone")
		self.title:Show()
		y = y + math.max(15, self.title:GetStringHeight() or 15) + 8
		local function para(s, tone)
			local fs = W.take(self.paras)
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", 0, -y)
			W.set(fs, s, tone or "ash")
			fs:Show()
			y = y + math.max(11, fs:GetStringHeight() or 11) + 4
		end
		local function head(s)
			y = y + 6
			local fs = W.take(self.heads)
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", 0, -y)
			W.set(fs, s, "gold")
			fs:Show()
			y = y + 20
		end
		for _, l in ipairs(v.lines or {}) do
			para(l.text, l.tone)
		end
		if v.learn then
			-- recipe-source data not yet seen in Forever is written in parch; "Known" is a word, not only a colour
			local unsure = v.learn.confidence and v.learn.confidence ~= "confirmed"
			para(v.learn.text, unsure and "parch" or "ash")
			if v.learn.known then
				para(v.learn.knownText or "Known", "green")
			end
		end
		if v.reagents and #v.reagents > 0 then
			head(v.reagentsTitle or "Reagents")
			for _, rg in ipairs(v.reagents) do
				local r = W.take(self.reagents)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", 0, -y)
				r.tip = rg.tip or (rg.source and { rg.name or "", rg.source } or nil)
				W.set(r.name, rg.name, rg.tone or "bone")
				W.set(
					r.count,
					rg.need and ("%s / %s"):format(tostring(rg.have or 0), tostring(rg.need)) or "",
					(rg.have or 0) >= (rg.need or 0) and "green" or "bone"
				)
				W.set(r.price, rg.price or rg.source or "", rg.price and "ash" or "parch")
				r:Show()
				y = y + 18
			end
		end
		if v.ways and v.ways.rows and #v.ways.rows > 0 then
			head(v.ways.title or "Ways")
			for _, wy in ipairs(v.ways.rows) do
				local r = W.take(self.ways)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", 0, -y)
				r.action, r.tip = wy.action, wy.tip
				r.outer:SetVertexColor(W.rgb(wy.picked and "gold" or "ash"))
				r.mid:SetVertexColor(W.rgb("surface"))
				r.dot:SetVertexColor(W.rgb("gold"))
				r.dot:SetShown(wy.picked == true)
				W.set(r.label, wy.label, wy.picked and "bone" or "ash")
				W.set(r.right, wy.right or "", "ash")
				r:Show()
				y = y + 22
			end
		end
		for _, pool in ipairs({ self.paras, self.heads, self.reagents, self.ways }) do
			W.finish(pool)
		end
		local hasMap = v.where ~= nil
		self.map:SetShown(hasMap)
		if hasMap then
			self.map:Set(v.where, { mode = "travel" })
			W.setChip(self.mapChip, v.where.title, nil, v.where.sub)
		end
		local n = W.buttonRow(self.buttons, self, v.actions, 15, 10, 356 - 3 - 24, v.color, "BOTTOMLEFT")
		local bottom = (n > 0 and 44 or 12) + (hasMap and 100 or 0)
		self.scroll.h = 376 - 12 - bottom
		self.scroll:SetHeight(self.scroll.h)
		self.scroll:SetContentHeight(y + 4)
	end
	return d
end

built.path = function()
	local p = pageFrame()
	p.timeline = timeline(p)
	p.timeline:SetPoint("TOPLEFT", 0, 0)
	p.list = W.list(p, 568, 376, {
		make = stepRow,
		draw = drawStepRow,
		rowHeight = 46,
		height = function(row)
			return row.kind == "fold" and 26 or 46
		end,
	})
	p.list:SetPoint("TOPLEFT", 0, -136)
	p.detail = detail(p)
	p.detail:SetPoint("TOPLEFT", 580, -136)
	p.parts = { p.timeline, p.list, p.detail }
	function p:Draw(vm)
		if
			pageEmpty(self, (not vm or vm.empty) and (vm and vm.empty or {
				title = "No path to show",
				text = "Pick a profession at the top. The path is drawn from the plan for that "
					.. "profession; without a plan there is nothing to lay on the timeline.",
			}) or nil)
		then
			return { steps = 0 }
		end
		J.pathSelected = vm.selected
		self.timeline:Set(vm)
		local keep = self.profession == vm.profession
		self.profession = vm.profession
		self.list:SetItems(vm.rows or {}, keep)
		for i, row in ipairs(vm.rows or {}) do
			if row.n == vm.selected and row.kind ~= "fold" and not keep then
				self.list:Reveal(i)
			end
		end
		self.detail:Set(vm.detail)
		return { steps = #(vm.rows or {}), segments = #(vm.segments or {}), shown = self.list.rows.n }
	end
	return p
end

--------------------------------------------------------------------------------------------------------------- where

local function spotRow(parent)
	local r = W.rowButton(parent, 62)
	r:SetWidth(286)
	r.chip = W.chip(r)
	r.chip:SetPoint("TOPRIGHT", -6, -6)
	r.name = W.text(r, "GameFontHighlight", 12)
	r.name:SetPoint("TOPLEFT", 10, -7)
	r.name:SetPoint("RIGHT", r.chip, "LEFT", -6, 0)
	r.right = W.text(r, "GameFontHighlightSmall", 10)
	r.right:SetPoint("BOTTOMRIGHT", -6, 8)
	r.right:SetJustifyH("RIGHT")
	r.sub = W.text(r, "GameFontHighlightSmall", 10)
	r.sub:SetPoint("TOPLEFT", 10, -25)
	r.sub:SetPoint("RIGHT", -6, 0)
	r.third = W.text(r, "GameFontHighlightSmall", 10)
	r.third:SetPoint("TOPLEFT", 10, -40)
	r.third:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
	r.rowLine = W.tex(r, "BORDER")
	r.rowLine:SetHeight(1)
	r.rowLine:SetPoint("BOTTOMLEFT")
	r.rowLine:SetPoint("BOTTOMRIGHT")
	W.fill(r.rowLine, "line", 0.6)
	r.labels = { r.name, r.sub, r.third }
	return r
end

local function drawSpot(r, s)
	local unsure = s.confidence and s.confidence ~= "confirmed"
	r.action = { id = "selectSpot", key = s.key, enabled = true }
	r.tip = s.tip
	r:SetAlpha(s.locked and 0.6 or 1)
	W.set(r.name, s.title, "bone")
	local sub = s.sub or ""
	if s.flight and s.flight ~= "" then
		sub = sub ~= "" and (sub .. ". " .. s.flight) or s.flight
	end
	W.set(r.sub, sub, "ash")
	if s.locked then
		W.set(r.third, s.locked, "warn")
	elseif unsure and not s.yield then
		W.set(r.third, s.note or "positions from Classic, unconfirmed", "parch")
	else
		W.set(r.third, s.yield or "", unsure and "parch" or (s.yieldTone or "ash"))
	end
	W.set(r.right, s.right or "", "ash")
	if W.setMobChip(r.chip, s.mobs) == 0 then
		r.chip:SetWidth(1)
	end
end

built.where = function()
	local p = pageFrame()
	p.side = W.scroll(p, 296, BODY_H)
	p.side:SetPoint("TOPLEFT", 0, 0)
	local c = p.side.content
	p.headTitle = W.text(c, "GameFontHighlight", 12)
	p.headTitle:SetPoint("TOPLEFT", 2, -2)
	p.headTitle:SetWidth(280)
	p.headSub = W.text(c, "GameFontHighlightSmall", 10)
	p.headSub:SetPoint("TOPLEFT", 2, -17)
	p.headSub:SetWidth(280)
	p.rows = W.pool(function()
		return spotRow(c)
	end)
	-- the selected spot: a full card with its yields
	p.card = W.card(c, 286, 120)
	p.card.chip = W.chip(p.card)
	p.card.chip:SetPoint("TOPRIGHT", -6, -6)
	p.card.name = W.text(p.card, "GameFontHighlight", 13)
	p.card.name:SetPoint("TOPLEFT", 12, -8)
	p.card.name:SetPoint("RIGHT", p.card.chip, "LEFT", -6, 0)
	p.card.sub = W.text(p.card, "GameFontHighlightSmall", 10)
	p.card.sub:SetPoint("TOPLEFT", 12, -26)
	p.card.sub:SetPoint("RIGHT", -6, 0)
	p.card.third = W.text(p.card, "GameFontHighlightSmall", 10)
	p.card.third:SetPoint("TOPLEFT", 12, -40)
	p.card.third:SetPoint("RIGHT", -6, 0)
	p.card.yields = W.yields(p.card, 286 - 12 - 8)
	p.card.yields:SetPoint("TOPLEFT", 12, -58)
	p.itinHead = W.header(c, 280)
	p.itin = W.pool(function()
		local r = W.rowButton(c, 34)
		r:SetWidth(286)
		r.range = W.text(r, "GameFontHighlightSmall", 11)
		r.range:SetPoint("TOPLEFT", 10, -5)
		r.range:SetWidth(64)
		r.title = W.text(r, "GameFontHighlightSmall", 11)
		r.title:SetPoint("TOPLEFT", 78, -5)
		r.title:SetPoint("RIGHT", -6, 0)
		r.sub = W.text(r, "GameFontHighlightSmall", 10)
		r.sub:SetPoint("TOPLEFT", 78, -19)
		r.sub:SetPoint("RIGHT", -6, 0)
		r.labels = { r.title, r.sub }
		return r
	end)
	p.none = W.empty(c, 270)

	p.caption = W.card(p, 628, 74)
	p.caption:SetPoint("TOPLEFT", 308, -438)
	p.line1 = W.text(p.caption, "GameFontHighlight", 13)
	p.line1:SetPoint("TOPLEFT", 12, -9)
	p.line1:SetWidth(326)
	p.arrow = W.tex(p.caption, "ARTWORK")
	p.arrow:SetSize(12, 12)
	p.arrow:SetPoint("TOPLEFT", 12, -30)
	W.atlas(p.arrow, "MiniMap-QuestArrow", "Interface\\Minimap\\MinimapArrow")
	p.arrow:SetDesaturated(true)
	p.line2 = W.text(p.caption, "GameFontHighlight", 12)
	p.line2:SetPoint("TOPLEFT", 30, -29)
	p.line2:SetWidth(308)
	p.line3 = W.text(p.caption, "GameFontHighlightSmall", 10)
	p.line3:SetPoint("TOPLEFT", 12, -51)
	p.line3:SetWidth(326)
	p.caption:EnableMouse(true)
	p.caption:SetScript("OnEnter", function(self)
		W.showTip(self, W.tipOf(self, p.line1, p.line2, p.line3))
	end)
	p.caption:SetScript("OnLeave", W.hideTip)
	p.buttons = W.pool(function()
		return W.button(p.caption, 128, 24)
	end)
	p.map = ns.MapCanvas.new(p, 628, 430, {
		journal = true,
		emptyText = "No place selected.",
		onClick = function(map, button, pin)
			if button == "RightButton" then
				W.act({ id = "pin", where = map.where, pin = pin, enabled = true })
			elseif pin and pin.key then
				W.act({ id = "selectSpot", key = pin.key, enabled = true })
			end
		end,
		onMode = function(_, wanted)
			W.state = W.state or {}
			W.state.where = W.state.where or {}
			W.state.where.mode = wanted
		end,
		onLive = function(where, live)
			local s = call("live", where, live)
			p:Live(live, s)
			return s
		end,
	})
	p.map:SetPoint("TOPLEFT", 308, 0)
	p.parts = { p.side, p.caption, p.map.frame }

	-- the tick's part of the caption: line 2 and 3 and the bearing arrow, set only when they change
	function p:Live(live, s)
		local l2 = s and s.line2 or (self.where and self.where.caption and self.where.caption.line2) or ""
		local l3 = (s and (s.visitedLine or s.line3))
			or (self.where and self.where.caption and self.where.caption.line3)
			or ""
		if live and not live.ok and live.why == "in an instance" then
			l3 = s and s.hidden or "Position hidden here (in an instance). It comes back outside."
		end
		if l2 ~= self.l2 then
			self.l2 = l2
			W.set(self.line2, l2, "bone")
		end
		if l3 ~= self.l3 then
			self.l3 = l3
			W.set(self.line3, l3, "ash")
		end
		-- the arrow points where to walk, relative to where the player faces (bearing: degrees clockwise from north)
		local turn = live and live.bearing and live.facing and (-math.rad(live.bearing) - live.facing)
		self.arrow:SetShown(turn ~= nil and turn ~= false)
		if turn then
			self.arrow:SetRotation(turn)
		end
	end

	function p:Draw(vm)
		if
			pageEmpty(self, not vm and {
				title = "Nothing to show here yet",
				text = "Places come from the plan of the profession picked at the top. Pick one, or open its window once so the plan is read.",
			} or nil)
		then
			return { spots = 0 }
		end
		self.vm = vm
		local where = vm.selected
		self.where, self.l2, self.l3 = where, nil, nil
		W.set(self.headTitle, vm.head and vm.head.title or "", "bone")
		W.set(self.headSub, vm.head and vm.head.sub or "", "ash")
		W.start(self.rows)
		W.start(self.itin)
		local y = 34
		local spots = vm.spots or {}
		self.card:Hide()
		for _, s in ipairs(spots) do
			if s.selected and where and not where.empty then
				local cd = self.card
				cd:ClearAllPoints()
				cd:SetPoint("TOPLEFT", 0, -y)
				cd:Rule(where.color or "bone")
				W.set(cd.name, s.title or where.title, "bone")
				local sub = s.sub or where.sub or ""
				if s.flight and s.flight ~= "" then
					sub = sub ~= "" and (sub .. ". " .. s.flight) or s.flight
				end
				W.set(cd.sub, sub, "ash")
				local mobs = where.mobs or s.mobs
				W.set(cd.third, s.line or (mobs and mobs.phrase) or "", mobs and mobs.tone or "ash")
				if W.setMobChip(cd.chip, mobs) == 0 then
					cd.chip:SetWidth(1)
				end
				local yh = cd.yields:Set(where.yields)
				cd:SetHeight(58 + yh + (yh > 0 and 8 or 0))
				cd:Show()
				y = y + cd:GetHeight() + 4
			else
				local r = W.take(self.rows)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", 0, -y)
				drawSpot(r, s)
				W.selectRow(r, s.selected, "bone")
				r:Show()
				y = y + 62
			end
		end
		W.finish(self.rows)
		-- the itinerary to 300 for world skills (optional: whereList.itinerary = { title, rows })
		local it = vm.itinerary
		if it and it.rows and #it.rows > 0 then
			y = y + 12
			self.itinHead:ClearAllPoints()
			self.itinHead:SetPoint("TOPLEFT", 2, -y)
			W.set(self.itinHead, it.title or "Route to 300", "gold")
			self.itinHead:Show()
			y = y + 22
			for _, row in ipairs(it.rows) do
				local r = W.take(self.itin)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", 0, -y)
				r.action = row.key and { id = "selectSpot", key = row.key, enabled = true } or nil
				r.tip = row.tip
				W.set(r.range, row.range, row.tone or "bone")
				W.set(r.title, row.title, row.done and "ash" or "bone")
				W.set(r.sub, row.sub or "", "ash")
				r:Show()
				y = y + 34
			end
		else
			self.itinHead:Hide()
		end
		W.finish(self.itin)
		if #spots == 0 or vm.empty then
			self.none:ClearAllPoints()
			self.none:SetPoint("TOPLEFT", 8, -y - 6)
			y = y
				+ 6
				+ self.none:Set(type(vm.empty) == "table" and vm.empty or {
					title = "Nothing to fetch right now",
					text = vm.empty or "No step of this profession needs a trip at this skill.",
				})
		else
			self.none:Hide()
		end
		self.side:SetContentHeight(y + 8)

		local saved = W.state and W.state.where and W.state.where.mode
		self.map:Set(where, { mode = (where and where.key ~= self.key) and saved or nil })
		self.key = where and where.key
		local cap = where and where.caption or {}
		local empty = where and where.empty
		W.set(self.line1, (empty and empty.title) or cap.line1 or (where and where.title) or "", "bone")
		if empty or not where then
			W.set(self.line2, empty and empty.text or "", "ash")
			W.set(self.line3, "", "ash")
			self.arrow:Hide()
			self.l2, self.l3 = false, false
		else
			self:Live(self.map.live, nil)
		end
		local actions = where and where.actions
		if where and not empty and not actions then
			actions = {
				{ id = "pin", label = "Pin on the map", enabled = true, where = where },
				{ id = "openMap", label = "Open zone map", enabled = true, where = where },
			}
		end
		W.start(self.buttons)
		for i = 1, math.min(#(actions or {}), 3) do
			local b = W.take(self.buttons)
			b:ClearAllPoints()
			-- two buttons side by side at the right, the third (quiet) under them
			if i < 3 then
				b:SetPoint("TOPRIGHT", -12 - (2 - i) * 134, -10)
			else
				b:SetPoint("TOPRIGHT", -12, -40)
			end
			b:SetSize(128, 24)
			b.onClick = nil
			W.setButton(b, actions[i], (i > 1 or actions[i].quiet) and "quiet" or nil, where.color)
		end
		W.finish(self.buttons)
		return { spots = #spots, map = self.map:Stats() }
	end
	return p
end

------------------------------------------------------------------------------------------------- shopping and alts

local function collapsed()
	local s = W.state or {}
	return s.collapsed or {}
end

local function shoppingItems(vm)
	if vm.items then
		return vm.items
	end
	local b = vm.blocks
	if b and b[1] and b[1].kind then
		return b
	end
	if b and ns.View and ns.View.shoppingItems then
		return ns.View.shoppingItems({ blocks = b, trip = vm.trip, tripLine = vm.tripLine }, collapsed())
	end
	return {}
end

local function sidePane(p)
	local side = W.scroll(p, 324, BODY_H)
	side:SetPoint("TOPLEFT", 612, 0)
	return side
end

built.shopping = function()
	local p = pageFrame()
	p.main = W.scroll(p, 600, BODY_H)
	p.main:SetPoint("TOPLEFT", 0, 0)
	p.side = sidePane(p)
	local c = p.side.content
	p.total = W.text(c, "GameFontHighlightLarge", 15)
	p.total:SetPoint("TOPLEFT", 0, -2)
	p.total:SetWidth(310)
	p.map = ns.MapCanvas.new(c, 314, 180, {
		onClick = function(map)
			if map.where then
				W.act({ id = "journal", page = "where", spot = map.where.key, enabled = true })
			end
		end,
	})
	p.map:SetPoint("TOPLEFT", 0, -30)
	p.open = W.button(c, 160, 24)
	p.stockHead = W.header(c, 310)
	p.stock = W.pool(function()
		return W.para(c, "GameFontHighlightSmall", 10, 310)
	end)
	p.parts = { p.main, p.side }
	function p:Draw(vm)
		local items = vm and shoppingItems(vm) or {}
		if
			pageEmpty(
				self,
				(not vm or (#items == 0 and not vm.total))
						and (vm and vm.empty and { title = "Nothing to buy", text = vm.empty } or {
							title = "Nothing to buy",
							text = "The plan for this profession needs no purchase right now, or it has not been read yet.",
						})
					or nil
			)
		then
			return { rows = 0 }
		end
		W.items(self.main, items, 586)
		W.set(self.total, vm.total or "", "bone")
		local y = 30
		self.map:SetShown(vm.errand ~= nil)
		if vm.errand then
			self.map:Set(vm.errand)
			y = y + 188
			self.open:ClearAllPoints()
			self.open:SetPoint("TOPLEFT", 0, -y)
			W.setButton(
				self.open,
				{ id = "journal", page = "where", spot = vm.errand.key, label = "Open in Where", enabled = true },
				"primary",
				vm.errand.color
			)
			y = y + 34
		else
			self.open:Hide()
		end
		W.start(self.stock)
		local stock = vm.stock or {}
		if #stock > 0 then
			self.stockHead:ClearAllPoints()
			self.stockHead:SetPoint("TOPLEFT", 0, -y)
			W.set(self.stockHead, vm.stockTitle or ("Stock (%d)"):format(#stock), "gold")
			self.stockHead:Show()
			y = y + 22
			for _, line in ipairs(stock) do
				local fs = W.take(self.stock)
				fs:ClearAllPoints()
				fs:SetPoint("TOPLEFT", 0, -y)
				W.set(fs, type(line) == "table" and line.text or line, "ash")
				fs:Show()
				y = y + math.max(10, fs:GetStringHeight() or 10) + 4
			end
		else
			self.stockHead:Hide()
		end
		W.finish(self.stock)
		self.side:SetContentHeight(y + 8)
		return { rows = #items }
	end
	return p
end

local function altsItems(vm)
	if vm.items then
		return vm.items
	end
	if vm.groups and ns.View and ns.View.altsItems then
		return ns.View.altsItems(
			{ title = vm.title or vm.counted, groups = vm.groups, incoming = vm.incoming or {}, empty = vm.empty },
			collapsed()
		)
	end
	local out = {}
	if vm.counted then
		out[#out + 1] = { kind = "line", text = vm.counted, color = "bone", size = 12 }
	end
	for _, ch in ipairs(vm.characters or {}) do
		out[#out + 1] = { kind = "gap", h = 6 }
		out[#out + 1] = { kind = "head", text = ch.title or ch.name }
		for _, r in ipairs(ch.rows or {}) do
			local right = r.right or (r.want and r.held and ("%d of %d"):format(r.want, r.held)) or ""
			out[#out + 1] = {
				kind = "row",
				name = r.name or r.item,
				right = r.state and (right .. "   " .. r.state) or right,
				tone = r.tone,
				action = r.action,
			}
		end
		if ch.all then
			out[#out + 1] = { kind = "button", action = ch.all, accent = "gold" }
		end
	end
	return out
end

-- V.mailPanel's groups as list items: what is known of the shape is drawn, the rest is skipped.
local function queueItems(q)
	local out = {}
	if type(q) ~= "table" then
		return out
	end
	if q.title then
		out[#out + 1] = { kind = "line", text = q.title, color = "bone", size = 12 }
	end
	for _, g in ipairs(q.groups or {}) do
		out[#out + 1] = { kind = "gap", h = 6 }
		out[#out + 1] = { kind = "head", text = g.title or g.to or "" }
		for _, r in ipairs(g.rows or g.lines or {}) do
			if type(r) == "table" then
				out[#out + 1] = { kind = "row", name = r.name or r.text, right = r.right, tone = r.tone }
			else
				out[#out + 1] = { kind = "line", text = r, size = 10 }
			end
		end
		if g.note then
			out[#out + 1] = { kind = "line", text = g.note.text, color = g.note.tone, size = 10 }
		end
		if g.fill then
			out[#out + 1] = { kind = "button", action = g.fill, accent = "gold" }
		end
		if g.drop then
			out[#out + 1] = { kind = "button", action = g.drop, quiet = true }
		end
	end
	for _, line in ipairs(q.lines or {}) do
		out[#out + 1] = { kind = "line", text = line, size = 10 }
	end
	return out
end

built.alts = function()
	local p = pageFrame()
	p.main = W.scroll(p, 600, BODY_H)
	p.main:SetPoint("TOPLEFT", 0, 0)
	p.side = sidePane(p)
	p.parts = { p.main, p.side }
	function p:Draw(vm)
		local items = vm and altsItems(vm) or {}
		if
			pageEmpty(self, not vm and {
				title = "No other characters counted",
				text = "Reagents on your other characters show here once they have been logged in "
					.. "with the addon, and counting them is on in Settings and data.",
			} or nil)
		then
			return { rows = 0 }
		end
		if #items == 0 then
			items = {
				{ kind = "line", text = vm.empty or "No other character holds a reagent this plan needs.", size = 12 },
			}
		end
		W.items(self.main, items, 586)
		local side = { { kind = "head", text = vm.queueTitle or "Mail queue" } }
		for _, it in ipairs(queueItems(vm.queue)) do
			side[#side + 1] = it
		end
		if #side == 1 then
			side[#side + 1] = { kind = "line", text = vm.queueEmpty or "Nothing queued.", size = 11 }
		end
		if vm.howto then
			side[#side + 1] = { kind = "gap", h = 10 }
			side[#side + 1] = { kind = "line", text = vm.howto, size = 10 }
		end
		if vm.countAlts then
			side[#side + 1] = { kind = "gap", h = 10 }
			side[#side + 1] = {
				kind = "check",
				text = vm.countAlts.text or vm.countAlts.label,
				on = vm.countAlts.on,
				action = vm.countAlts.action,
				tip = vm.countAlts.tip,
			}
		end
		W.items(self.side, side, 310)
		return { rows = #items }
	end
	return p
end

------------------------------------------------------------------------------------------------------------ settings

local EXPLAIN = {
	"The plan takes the cheapest recipe for each stretch of skill, priced by TradeSkillMaster, and counts what "
		.. "the bags, the bank and (if on) your other characters already hold.",
	"It buys for a bad-luck run: at 90% it buys enough materials that nine runs in ten reach the target.",
	"Effort per craft is what one extra craft costs you in time, in copper. A higher value prefers fewer crafts.",
	"Recipes to buy and special teachers are offered only when they pay for themselves on the way to 300.",
}

local MODS = {
	LSHIFT = true,
	RSHIFT = true,
	LCTRL = true,
	RCTRL = true,
	LALT = true,
	RALT = true,
	LMETA = true,
	RMETA = true,
	UNKNOWN = true,
}

function J.stopCapture()
	if not (frame and J.capturing) then
		return
	end
	J.capturing = nil
	frame:SetScript("OnKeyDown", nil)
	if not (InCombatLockdown and InCombatLockdown()) then
		pcall(frame.EnableKeyboard, frame, false)
	end
end

-- "Set key": the next key press binds the journal; Escape cancels. Refused in a fight (SetBinding is).
function J.captureKey()
	if not frame then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		J.flash("Keys cannot be bound in a fight.")
		return
	end
	J.capturing = true
	J.flash("Press a key for the journal. Escape cancels.")
	pcall(frame.EnableKeyboard, frame, true)
	pcall(frame.SetPropagateKeyboardInput, frame, false)
	frame:SetScript("OnKeyDown", function(_, key)
		if MODS[key] then
			return
		end
		J.stopCapture()
		if key == "ESCAPE" then
			J.flash(nil)
			return
		end
		local combo = (IsAltKeyDown and IsAltKeyDown() and "ALT-" or "")
			.. (IsControlKeyDown and IsControlKeyDown() and "CTRL-" or "")
			.. (IsShiftKeyDown and IsShiftKeyDown() and "SHIFT-" or "")
			.. key
		local ok, why
		if J.provider.bindKey then
			ok, why = call("bindKey", combo)
		else
			ok, why = J.bind(combo)
		end
		J.flash(ok == false and why or nil)
		J.refresh()
	end)
end

built.settings = function()
	local p = pageFrame()
	p.cols = {}
	for i = 1, 3 do
		local sc = W.scroll(p, 304, BODY_H)
		sc:SetPoint("TOPLEFT", (i - 1) * 316, 0)
		p.cols[i] = sc
	end
	local cw = 290
	local function pools(c)
		return {
			heads = W.pool(function()
				return W.header(c, cw)
			end),
			paras = W.pool(function()
				return W.para(c, "GameFontHighlightSmall", 10, cw)
			end),
			checks = W.pool(function()
				return W.check(c, cw)
			end),
			drops = W.pool(function()
				return W.dropdown(c, cw, 104)
			end),
			steppers = W.pool(function()
				return W.stepper(c, cw)
			end),
			sliders = W.pool(function()
				return W.slider(c, cw)
			end),
			buttons = W.pool(function()
				return W.button(c, 96, 20)
			end),
			rows = W.pool(function()
				local r = W.frame("Frame", nil, c)
				r:SetSize(cw, 20)
				r.pip = W.tex(r, "ARTWORK")
				r.pip:SetSize(8, 8)
				r.pip:SetPoint("LEFT", 2, 0)
				r.pipIn = W.tex(r, "ARTWORK", 1)
				r.pipIn:SetSize(6, 6)
				r.pipIn:SetPoint("CENTER", r.pip, "CENTER")
				r.right = W.text(r, "GameFontHighlightSmall", 10)
				r.right:SetPoint("RIGHT", 0, 0)
				r.right:SetJustifyH("RIGHT")
				r.label = W.text(r, "GameFontHighlight", 12)
				r.label:SetPoint("LEFT", 16, 0)
				r.label:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
				r:EnableMouse(true)
				r:SetScript("OnEnter", function(self)
					W.showTip(self, W.tipOf(self, self.label, self.right))
				end)
				r:SetScript("OnLeave", W.hideTip)
				return r
			end),
		}
	end
	for i = 1, 3 do
		p.cols[i].pools = pools(p.cols[i].content)
	end
	p.open, p.confirm = {}, {}
	p.parts = { p.cols[1], p.cols[2], p.cols[3] }

	local function column(i)
		local sc = p.cols[i]
		local pl = sc.pools
		for _, pool in pairs(pl) do
			W.start(pool)
		end
		local col = { y = 0 }
		local function place(x, h, dx)
			x:ClearAllPoints()
			x:SetPoint("TOPLEFT", dx or 0, -col.y)
			x:Show()
			col.y = col.y + h
		end
		function col.head(s)
			col.y = col.y + (col.y > 0 and 12 or 0)
			local fs = W.take(pl.heads)
			W.set(fs, s, "gold")
			place(fs, 22)
		end
		function col.para(s, tone, dx)
			local fs = W.take(pl.paras)
			fs:SetWidth(cw - (dx or 0))
			W.set(fs, s, tone or "ash")
			place(fs, math.max(10, fs:GetStringHeight() or 10) + 4, dx)
		end
		function col.button(a, style, dx, wd)
			local b = W.take(pl.buttons)
			b.onClick = nil
			W.setButton(b, a, style or "quiet")
			b:SetSize(wd or math.max(64, (b.label:GetStringWidth() or 0) + 20), 20)
			place(b, 24, dx)
			return b
		end
		-- a row with a state pip: ok = filled square, absent = hollow square, broken = filled with a notch
		function col.row(label, right, pipState, tone, tip)
			local r = W.take(pl.rows)
			r.tip = tip
			W.set(r.label, label, tone or "bone")
			W.set(r.right, right or "", "ash")
			r.pip:SetShown(pipState ~= nil)
			r.pipIn:SetShown(pipState == "absent" or pipState == "broken")
			r.label:SetPoint("LEFT", pipState and 16 or 2, 0)
			if pipState then
				W.fill(r.pip, pipState == "ok" and "green" or (pipState == "broken" and "warn" or "ash"))
				W.fill(r.pipIn, "ink")
				r.pipIn:SetSize(pipState == "broken" and 2 or 6, 6)
			end
			place(r, 20)
			return r
		end
		function col.finish()
			for _, pool in pairs(pl) do
				W.finish(pool)
			end
			sc:SetContentHeight(col.y + 8)
		end
		col.pools = pl
		col.place = place
		return col
	end

	local function setting(e, value)
		return e.action and e.action.id and setmetatable({ value = value }, { __index = e.action })
			or { id = "setting", key = e.key, value = value, enabled = true }
	end

	function p:Draw(vm)
		if
			pageEmpty(self, not vm and {
				title = "Settings are not loaded yet",
				text = "They are read with the saved data when the addon starts. Close the journal and open it again in a moment.",
			} or nil)
		then
			return { controls = 0 }
		end
		self.vm = vm
		local n = 0
		-- column 1: the planner's settings, every former slash command as a control
		local col = column(1)
		col.head(vm.plannerTitle or "Planner")
		for _, e in ipairs(vm.planner or {}) do
			n = n + 1
			if e.kind == "check" then
				local c = W.take(col.pools.checks)
				local on = e.value == true or e.on == true
				c:Set(e.label, on, setting(e, not on), e.tip)
				col.place(c, 24)
			elseif e.kind == "dropdown" then
				local d = W.take(col.pools.drops)
				local items = {}
				for _, o in ipairs(e.options or {}) do
					local ov = type(o) == "table" and o.value or o
					items[#items + 1] = {
						label = type(o) == "table" and o.label or tostring(o),
						kind = "radio",
						checked = ov == e.value,
						action = type(o) == "table" and o.action or setting(e, ov),
					}
				end
				d:Set(
					e.label,
					e.text or tostring(e.value or ""),
					#items > 0 and { title = e.label, items = items } or nil,
					e.tip
				)
				col.place(d, 26)
			elseif e.kind == "slider" then
				local s = W.take(col.pools.sliders)
				s:Set(e.label, e.value, e.min, e.max, e.step, e.format, function(v)
					W.act(setting(e, v))
				end, e.tip)
				col.place(s, 42)
			elseif e.kind == "stepper" then
				local s = W.take(col.pools.steppers)
				local step = e.step or 1
				local v = tonumber(e.value)
				local dec = e.dec or (v and setting(e, v - step)) or nil
				local inc = e.inc or (v and setting(e, v + step)) or nil
				s:Set(e.label, e.text or tostring(e.value or ""), dec, inc, e.tip)
				col.place(s, 26)
				if e.reset then
					col.button(e.reset, "link")
				end
			elseif e.kind == "list" then
				col.row(e.label, e.rows and tostring(#e.rows) or "", nil, "bone", e.tip)
				for _, r in ipairs(e.rows or {}) do
					local row = col.row(r.text or r.name, nil, nil, "ash", r.tip)
					if r.action then
						local b = col.button(r.action, "quiet")
						b:ClearAllPoints()
						b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
						col.y = col.y - 24
					end
				end
				if e.empty and #(e.rows or {}) == 0 then
					col.para(e.empty, "ash", 16)
				end
			elseif e.kind == "link" then
				col.button(
					e.action or { id = "journal", page = e.page or "overview", label = e.label, enabled = true },
					"link"
				)
			elseif e.kind == "key" then
				local fight = InCombatLockdown and InCombatLockdown()
				col.row(e.label or "Key", e.value or "not set", nil, "bone", e.tip)
				col.button({
					id = "bindKey",
					label = J.capturing and "Press a key" or (fight and "Not in a fight" or "Set key"),
					enabled = not fight,
					tip = "Click, then press the key. Escape cancels.",
				}, "quiet")
			end
		end
		col.finish()

		-- column 2: which data layers loaded, with each validation error on its own line
		col = column(2)
		col.head(vm.dataTitle or "Data")
		local broken = 0
		for _, d in ipairs(vm.data or {}) do
			col.row(d.label, d.stateText, d.state or "absent", d.state == "broken" and "warn" or "bone", d.tip)
			if d.detail then
				col.para(d.detail, "ash", 16)
			end
			for _, err in ipairs(d.errors or {}) do
				broken = broken + 1
				col.para(err, "warn", 16)
			end
			if d.action then
				col.button(d.action, "quiet", 16)
			end
			col.y = col.y + 4
		end
		if #(vm.data or {}) == 0 then
			col.para("No data layer has reported yet.", "ash")
		end
		col.head(vm.explainTitle or "How the plan is made")
		for _, line in ipairs(vm.explain or EXPLAIN) do
			col.para(line, "ash")
			col.y = col.y + 2
		end
		col.finish()

		-- column 3: what the addon learned in game, each list with a reset that asks once in place
		col = column(3)
		col.head(vm.learnedTitle or "Learned in game")
		for _, l in ipairs(vm.learned or {}) do
			local id = l.id or l.title
			local open = self.open[id] == true
			local head = col.row(("%s (%d)"):format(l.title or "", l.count or #(l.rows or {})), nil, nil, "bone", l.tip)
			local toggle =
				col.button({ id = "fold", label = open and "Hide" or "Show", enabled = #(l.rows or {}) > 0 }, "link")
			toggle:ClearAllPoints()
			toggle:SetPoint("RIGHT", head, "RIGHT", 0, 0)
			toggle.onClick = function()
				self.open[id] = not open
				self:Draw(self.vm)
			end
			col.y = col.y - 24
			if self.confirm[id] then
				col.para(
					l.confirm or ("Reset %d %s? This cannot be undone."):format(l.count or 0, (l.title or ""):lower()),
					"warn",
					16
				)
				local yes = col.button({ id = "resetLearned", label = "Reset", enabled = true }, "primary", 16, 72)
				yes.accent = "warn"
				W.paintButton(yes)
				yes.onClick = function()
					self.confirm[id] = nil
					W.act(l.reset or { id = "resetLearned", list = id, enabled = true })
				end
				local keep = col.button({ id = "keep", label = "Keep", enabled = true }, "quiet", 94, 72)
				col.y = col.y - 24
				keep:ClearAllPoints()
				keep:SetPoint("TOPLEFT", 94, -col.y)
				col.y = col.y + 24
				keep.onClick = function()
					self.confirm[id] = nil
					self:Draw(self.vm)
				end
			elseif (l.count or #(l.rows or {})) > 0 then
				local b = col.button({
					id = "askReset",
					label = l.reset and l.reset.label or "Reset",
					enabled = true,
					tip = "Asks once before anything is removed.",
				}, "quiet", 16)
				b.onClick = function()
					self.confirm[id] = true
					self:Draw(self.vm)
				end
			end
			if open then
				for k, r in ipairs(l.rows or {}) do
					if k > 60 then
						col.para(("%d more"):format(#l.rows - 60), "ash", 16)
						break
					end
					col.row(r.text, r.sub, nil, "ash", r.tip)
				end
			end
			col.y = col.y + 6
		end
		if #(vm.learned or {}) == 0 then
			col.para("Nothing learned yet. Trainers, vendors and places are noted as this character meets them.", "ash")
		end
		col.finish()
		return { controls = n, errors = broken, learned = #(vm.learned or {}) }
	end
	return p
end

------------------------------------------------------------------------------------------------------------- entry

J.ctx = {}

local function ctx()
	return { profession = jstate().profession, step = J.ctx.step, spot = J.ctx.spot, page = jstate().page }
end

-- Draws a page from its view-model. Creates the window and the page on first use.
function J.setPage(name, vm)
	if not PAGE[name] then
		J.stats.lastWhy = "no page named " .. tostring(name)
		name = "overview"
	end
	if not frame then
		create()
	end
	jstate().page = name
	for id, p in pairs(pages) do
		p:SetShown(id == name)
	end
	local p = pages[name]
	if not p then
		p = built[name]()
		pages[name] = p
		p:Show()
	end
	local res = p:Draw(vm)
	local st = J.stats.pages[name] or { draws = 0 }
	st.draws = st.draws + 1
	for k, v in pairs(res or {}) do
		st[k] = v
	end
	st.empty = vm == nil
	J.stats.pages[name] = st
	J.stats.page = name
	paintTabs(shell.vm)
	return p
end

-- Pulls the shell and the current page from the provider and redraws. No work while the journal is hidden.
function J.refresh()
	if not (frame and frame:IsShown()) then
		return
	end
	local c = ctx()
	local vm = call("journal", c)
	if vm and vm.profession and not jstate().profession then
		jstate().profession = vm.profession
	end
	local page = jstate().page or "overview"
	J.setPage(page, call("page", page, c))
	drawShell(vm or {})
end

-- The one entry point: J.open(page, { profession, step, spot }).
function J.open(page, c)
	if not frame then
		create()
	end
	local s = jstate()
	if c and c.current then
		local now = call("context")
		if now then
			c = { profession = now.profession, step = now.step, spot = now.spot }
		end
	end
	if c then
		if c.profession then
			s.profession = c.profession
		end
		J.ctx.step, J.ctx.spot = c.step, c.spot
	end
	s.page = PAGE[page] and page or s.page or "overview"
	shell.flash = nil
	frame:Show()
	J.refresh()
	return frame
end

function J.close()
	if frame then
		frame:Hide()
	end
end

-- Toggles the journal. With a page: opens there, or closes when that page is already shown.
function J.Toggle(page)
	if frame and frame:IsShown() and (page == nil or page == jstate().page) then
		J.close()
		return false
	end
	J.open(page)
	return true
end
J.toggle = J.Toggle

function J.frame()
	return frame
end

-- A built page (nil until it was first shown), for the selftest and the tests.
function J.page(name)
	return pages[name]
end

-- The small "open the journal" button (22 x 22, three 1-px lines) for the docked panel's header.
function J.newOpenButton(parent)
	local b = W.frame("Button", nil, parent)
	b:SetSize(22, 22)
	b.lines = {}
	for i = 1, 3 do
		local t = W.tex(b, "ARTWORK")
		t:SetSize(10, 1)
		t:SetPoint("CENTER", 0, 4 - (i - 1) * 4)
		W.fill(t, "ash")
		b.lines[i] = t
	end
	local function paint(tone)
		for _, t in ipairs(b.lines) do
			W.fill(t, tone)
		end
	end
	b:SetScript("OnEnter", function(self)
		paint("bone")
		W.showTip(self, "Open the journal")
	end)
	b:SetScript("OnLeave", function(self)
		paint("ash")
		W.hideTip(self)
	end)
	b:SetScript("OnClick", function()
		J.act({ id = "journal", page = "path", current = true, enabled = true })
	end)
	return b
end

-- What the selftest reads: which page, how often opened, what each page drew, which provider callbacks are missing,
-- the last broken link, and the map's own diagnostics (mode, k, tiles, art missing and why).
function J.diag()
	local wp = pages.where
	return {
		created = frame ~= nil,
		shown = frame ~= nil and frame:IsShown() or false,
		opened = J.stats.opened,
		page = J.stats.page,
		pages = J.stats.pages,
		acts = J.stats.acts,
		missing = J.stats.missing,
		lastWhy = J.stats.lastWhy,
		emptyTitle = shell.empty and shell.empty:IsShown() and shell.empty.title:GetText() or nil,
		where = wp and wp.map:Stats() or nil,
		map = ns.MapCanvas.diag,
		widgets = W.stats,
		atlasMissing = W.atlasMissing,
		dropped = W.dropped,
		field = ns.FieldUI and ns.FieldUI.diag() or nil,
	}
end

------------------------------------------------------------------------------------------------------------ globals

-- The only globals: the binding's name and the three functions the TOC's compartment fields name. They are set
-- through _G so the reader (and luacheck) sees they are meant.

-- The key binding's name in the Key Bindings panel (Bindings.xml runs the compartment function).
_G.BINDING_NAME_SKILLUPHELPER_JOURNAL = "Open the SkillupHelper journal"

-- TOC: ## AddonCompartmentFunc: SkillupHelper_OnCompartmentClick
_G.SkillupHelper_OnCompartmentClick = function()
	if ns.guard then
		ns.guard("journal", J.Toggle)
	else
		J.Toggle()
	end
end

-- TOC: ## AddonCompartmentFuncOnEnter: SkillupHelper_OnCompartmentEnter
_G.SkillupHelper_OnCompartmentEnter = function(_, button)
	if button and GameTooltip then
		W.showTip(button, { "SkillupHelper", "Click: open or close the journal." })
		J.compartmentTip = button
	end
end

-- TOC: ## AddonCompartmentFuncOnLeave: SkillupHelper_OnCompartmentLeave
_G.SkillupHelper_OnCompartmentLeave = function()
	if J.compartmentTip then
		W.hideTip(J.compartmentTip)
		J.compartmentTip = nil
	end
end
