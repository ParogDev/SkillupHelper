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
--   selectProfession(key), selectStep(step, action), selectStretch(index), selectSpot(key), trackSpot(key)
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
	elseif id == "selectStretch" then
		call("selectStretch", a.index, a)
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
		-- a count shows only when the tab's tooltip names what is counted, and never on Overview
		if t.count and t.count ~= 0 and t.tip and b.id ~= "overview" then
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
	-- the breadcrumb: the profession (a dropdown), then only what the dropdown does not already say: the selected
	-- line on Path, the spot on Where. Hidden on the pages that are not about one profession.
	local scoped = page ~= "overview" and page ~= "settings"
	shell.prof:SetShown(scoped)
	shell.crumb:SetShown(scoped)
	if scoped then
		local shown = name or vm.profession or "Pick a profession"
		W.set(shell.prof.label, shown)
		shell.prof:SetWidth(math.max(120, math.min(220, (shell.prof.label:GetStringWidth() or 0) + 40)))
		W.paintButton(shell.prof)
		local crumb = pages[page] and pages[page].crumb or vm.crumb
		if W.secret(crumb) or type(crumb) ~= "string" or crumb == "" or crumb == shown then
			crumb = nil
		end
		shell.crumbText = crumb
		W.set(shell.crumb, crumb or "", "ash")
	end
	W.set(shell.status, shell.flash or vm.status or "", shell.flash and "warn" or "ash")
	local key
	if GetBindingKey then
		local ok, k = pcall(GetBindingKey, BINDING)
		key = ok and k or nil
	end
	if key and not W.secret(key) then
		W.set(shell.hint.label, "Journal key: " .. tostring(key), "ash")
		shell.hint.tip = "Change it under Settings and data."
	else
		W.set(shell.hint.label, "No key opens the journal yet. Set one under Settings and data.", "ash")
		shell.hint.tip = "Click to open Settings and data."
	end
	shell.hint:SetWidth(math.ceil((shell.hint.label:GetStringWidth() or 0) + 4))
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
	-- No scale of its own: a fractional scale breaks the fonts' hinting. The window stays at scale 1 and on whole
	-- pixels (W.snap: after the saved point is restored, on every show and after a drag).
	local s = jstate()
	if type(s.point) == "table" and s.point[1] then
		frame:SetPoint(s.point[1], UIParent, s.point[1], s.point[2] or 0, s.point[3] or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	W.snap(frame)
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
		local point = W.dragStop(frame)
		if point then
			jstate().point = point
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
	-- a long line title can be cut here: the band's tooltip has it whole
	band:SetScript("OnEnter", function(self)
		W.showTip(self, W.tipOf(self, shell.crumb))
	end)
	band:SetScript("OnLeave", W.hideTip)
	-- the client's own close button (UIPanelCloseButton, SharedUIPanelTemplates.xml); where the template is
	-- refused, an X drawn from two lines. Never a letter: the font may lack the glyph.
	local okClose, closeButton = pcall(W.frame, "Button", nil, band, "UIPanelCloseButton")
	if okClose and closeButton then
		shell.close, shell.closeKind = closeButton, "template"
		closeButton:SetSize(24, 24)
		closeButton:SetPoint("TOPRIGHT", -8, -8)
		closeButton:SetScript("OnClick", function()
			J.close()
		end)
	else
		shell.close, shell.closeKind = W.closeButton(band), "drawn"
		shell.close:SetPoint("TOPRIGHT", -9, -9)
		shell.close.onClick = function()
			J.close()
		end
	end

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
	-- the key hint is a click target: it opens the page that sets the key
	shell.hint = W.frame("Button", nil, frame)
	shell.hint:SetSize(120, 18)
	shell.hint:SetPoint("BOTTOMRIGHT", -14, 5)
	shell.hint.label = W.text(shell.hint, "GameFontHighlightSmall", 10)
	shell.hint.label:SetPoint("RIGHT", 0, 0)
	shell.hint.label:SetJustifyH("RIGHT")
	shell.hint:SetScript("OnEnter", function(self)
		W.setColor(self.label, "bone")
		W.showTip(self, self.tip)
	end)
	shell.hint:SetScript("OnLeave", function(self)
		W.setColor(self.label, "ash")
		W.hideTip(self)
	end)
	shell.hint:SetScript("OnClick", function()
		J.open("settings")
	end)
	-- the status is secondary text: when it is cut short its full text is in the tooltip
	shell.statusBox = W.frame("Frame", nil, frame)
	shell.statusBox:SetHeight(18)
	shell.statusBox:SetPoint("BOTTOMLEFT", 14, 5)
	shell.statusBox:SetPoint("RIGHT", shell.hint, "LEFT", -12, 0)
	shell.statusBox:EnableMouse(true)
	shell.status = W.text(shell.statusBox, "GameFontHighlightSmall", 10)
	shell.status:SetAllPoints(shell.statusBox)
	shell.statusBox:SetScript("OnEnter", function(self)
		W.showTip(self, W.tipOf(self, shell.status))
	end)
	shell.statusBox:SetScript("OnLeave", W.hideTip)
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
	frame:SetScript("OnShow", function(self)
		J.stats.opened = J.stats.opened + 1
		W.snap(self)
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
	if r.unpriced and #r.unpriced > 0 then
		tip[#tip + 1] = { ("Price unknown, not in the cost: %s"):format(table.concat(r.unpriced, ", ")), "warn" }
	elseif r.tsmMissing and r.tsmMissing > 0 then
		tip[#tip + 1] = ("Prices missing: %d"):format(r.tsmMissing)
	end
	-- the cost breakdown lives here, not on the card
	local c = r.cost or {}
	for _, part in ipairs({ { "Materials", c.mats }, { "Recipes", c.recipes }, { "Training", c.training } }) do
		if part[2] and part[2] ~= "" then
			tip[#tip + 1] = ("%s: %s"):format(part[1], tostring(part[2]))
		end
	end
	if r.why then
		tip[#tip + 1] = r.why
	end
	if r.usable ~= false then
		tip[#tip + 1] = "Click to open its path."
	end
	return tip
end

-- The Overview is a grid of cards, never a list: 3 columns by 6 rows hold the 18 professions the data can ship
-- inside the body, under the 22-px filter row. 30 + 6 * 75 + 5 * 6 = 510 of 512 px.
local OV_COLS, OV_ROWS, OV_W, OV_H, OV_GAP_X, OV_GAP_Y, OV_TOP = 3, 6, 306, 75, 9, 6, 30
assert(OV_COLS * OV_W + (OV_COLS - 1) * OV_GAP_X <= BODY_W, "overview: the columns are wider than the body")
assert(OV_TOP + OV_ROWS * OV_H + (OV_ROWS - 1) * OV_GAP_Y <= BODY_H, "overview: the rows are taller than the body")

-- One profession: icon, name and skill on line 1, the rank bar with cap ticks, the cost to the top, the state of
-- the path. Every text has the card's full width to itself or shares it with a short right-aligned one.
local function overviewCard(parent)
	local r = W.rowButton(parent, OV_H)
	r:SetWidth(OV_W)
	r.ground = W.tex(r, "BACKGROUND", -1)
	r.ground:SetAllPoints()
	W.fill(r.ground, "surface")
	r.icon = W.tex(r, "ARTWORK")
	r.icon:SetSize(24, 24)
	r.icon:SetPoint("TOPLEFT", 12, -8)
	r.skill = W.text(r, "GameFontHighlightSmall", 11)
	r.skill:SetPoint("TOPRIGHT", -10, -9)
	r.skill:SetJustifyH("RIGHT")
	r.name = W.text(r, "GameFontHighlight", 13)
	r.name:SetPoint("TOPLEFT", 44, -8)
	r.name:SetPoint("RIGHT", r.skill, "LEFT", -8, 0)
	r.rank = W.band(r, OV_W - 44 - 10, 6)
	r.rank:Place("TOPLEFT", r, "TOPLEFT", 44, -28)
	r.cost = W.text(r, "GameFontHighlightSmall", 11)
	r.cost:SetPoint("TOPLEFT", 12, -41)
	r.cost:SetPoint("RIGHT", -10, 0)
	r.cover = W.text(r, "GameFontHighlightSmall", 11)
	r.cover:SetPoint("TOPLEFT", 12, -57)
	r.cover:SetPoint("RIGHT", -10, 0)
	r.labels = { r.name, r.cost, r.cover }
	return r
end

local function drawOverviewCard(r, row)
	local dim = row.usable == false
	r:SetAlpha(dim and 0.55 or 1)
	r.action = { id = "selectProfession", key = row.key, page = "path", enabled = not dim }
	r.tip = coverageTip(row)
	W.icon(r.icon, row.icon)
	W.set(r.name, row.name, row.learned and "bone" or "ash")
	r.rank:Set(
		{ { from = 0, to = row.skill or 0, color = "gold" } },
		{ lo = 0, hi = 300 },
		nil,
		{ ticks = CAPS, track = 0.9 }
	)
	if row.skillText then
		W.set(r.skill, row.skillText, (row.learned and not dim) and "bone" or "ash")
	elseif dim then
		W.set(r.skill, row.why or "not available", "ash")
	elseif row.learned and row.skill then
		W.set(r.skill, ("%d / %d"):format(row.skill, row.cap or 300), "bone")
	else
		W.set(r.skill, "not learned", "ash")
	end
	local c = row.cost or {}
	local cost = row.costText or (c.total and ("To 300: " .. tostring(c.total))) or (dim and "" or "Price unknown")
	W.set(r.cost, cost, row.costTone or (c.total and "bone" or "warn"))
	local state = row.status == "complete" and "green" or (row.status == "gaps" and "warn" or "ash")
	W.set(r.cover, row.coverText or row.statusText or row.status or "", row.coverTone or state)
	-- the card's left rule says the state of the path a second time; the selected profession wears gold
	local selected = row.key == (shell.vm and shell.vm.profession or jstate().profession)
	r.rule:SetShown(true)
	W.fill(r.rule, selected and "gold" or (row.status == "gaps" and "warn" or "line"))
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
	-- the grid: a paged area, so more professions than 18 (no data ships that many) would turn pages, not scroll
	p.grid = W.pages(p, BODY_W, BODY_H - OV_TOP, "overview")
	p.grid:SetPoint("TOPLEFT", 0, -OV_TOP)
	p.cards = W.pool(function()
		return overviewCard(p.grid.content)
	end)
	p.grid.redraw = function()
		p:Draw(p.vm)
	end
	p.none = W.empty(p, 520)
	p.none:SetPoint("TOPLEFT", 34, -80)
	p.parts = { p.filters, p.sorts, p.sortLabel, p.grid }
	-- lays the cards of the page shown; with more than one page the last row gives way to the pager
	function p:Lay(rows)
		local g = self.grid
		local per = OV_COLS * OV_ROWS
		if #rows > per then
			per = OV_COLS * (OV_ROWS - 1)
		end
		g.pageCount = math.max(1, math.ceil(#rows / per))
		g.page = math.max(1, math.min(g.page, g.pageCount))
		local first = (g.page - 1) * per + 1
		local last = math.min(#rows, first + per - 1)
		W.start(self.cards)
		for i = first, last do
			local k = i - first
			local card = W.take(self.cards)
			card:ClearAllPoints()
			card:SetPoint("TOPLEFT", (k % OV_COLS) * (OV_W + OV_GAP_X), -math.floor(k / OV_COLS) * (OV_H + OV_GAP_Y))
			drawOverviewCard(card, rows[i])
			card:Show()
		end
		W.finish(self.cards)
		g.pager:Set(g.page, g.pageCount, first, last, #rows, "professions")
		local shown = last - first + 1
		local lines = math.ceil(shown / OV_COLS)
		g:SetContentHeight(lines * OV_H + math.max(0, lines - 1) * OV_GAP_Y + (g.pageCount > 1 and 26 or 0))
		self.rows, self.first, self.last = rows, first, last
		return shown
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
		local shown = self:Lay(rows)
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
		return { rows = #rows, gaps = gaps, shown = shown, pages = self.grid.pageCount }
	end
	return p
end

---------------------------------------------------------------------------------------------------------------- path

-- The Path page, top to bottom: the timeline card (128), the stretch bar (34), then the lines of one stretch (568
-- wide) beside the detail of the selected line (356 wide). Nothing scrolls: the timeline and the stretch bar are
-- the navigation, and a stretch never holds more lines than its box.
local TL_X, TL_PX, TL_H = 18, 3, 128
local BAR_Y, BAR_H = TL_H + 6, 34
local LIST_Y = BAR_Y + BAR_H + 6
local LIST_W, LIST_H, DETAIL_X, DETAIL_W = 568, BODY_H - LIST_Y, 580, 356
local ROW_H, HEAD_H, HEAD_LINE, HEAD_LINES = 46, 22, 16, 2
local PATH_MAX = ns.Where and ns.Where.PATH_MAX or 6
-- the longest stretch (its header with two rank lines, then PATH_MAX rows) fits the box: 54 + 6 * 46 = 330 of 338
assert(HEAD_H + HEAD_LINES * HEAD_LINE + PATH_MAX * ROW_H <= LIST_H, "path: a full stretch does not fit its list")
local LEGEND = {
	{ kind = "train", label = "Trainer" },
	{ kind = "ah", label = "Auction recipe" },
	{ kind = "vendor", label = "Vendor recipe" },
	{ kind = "bop", label = "Shortcut" },
	{ kind = "gap", label = "No recipe" },
}

local function timeline(parent)
	local t = W.card(parent, BODY_W, TL_H)
	t:EnableMouse(true)
	t.quads = W.pool(function()
		return W.tex(t, "ARTWORK")
	end)
	t.labels = W.pool(function()
		return W.text(t, "GameFontHighlightSmall", 10)
	end)
	-- Every edge is a whole physical pixel: both sides of a quad are snapped and its size is their difference, so
	-- two segments that meet at a skill value share that edge exactly. `edges` keeps every x for the tests.
	t.edges = {}
	local function px(v)
		return W.px(t, v)
	end
	local function quad(x, y, wd, ht, tone, alpha, sub, rot)
		local q = W.take(t.quads)
		q:ClearAllPoints()
		if rot then
			-- a turned square (the trainer's diamond): its centre sits on a pixel
			local cx, cy = px(x + wd / 2), px(y + ht / 2)
			q:SetPoint("CENTER", t, "TOPLEFT", cx, -cy)
			q:SetSize(px(wd), px(ht))
			t.edges[#t.edges + 1] = cx
		else
			local x1, x2, y1, y2 = px(x), px(x + wd), px(y), px(y + ht)
			-- a 1-px rule is one physical pixel at every scale, and nothing collapses to zero
			local one = W.px(t, 1, 1)
			if wd == 1 or x2 <= x1 then
				x2 = x1 + one
			end
			if ht == 1 or y2 <= y1 then
				y2 = y1 + one
			end
			q:SetPoint("TOPLEFT", t, "TOPLEFT", x1, -y1)
			q:SetSize(x2 - x1, y2 - y1)
			t.edges[#t.edges + 1] = x1
			t.edges[#t.edges + 1] = x2
		end
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
	-- a marker's shape at x (its centre), top y: the same drawing on the lane and in the legend
	local function mark(kind, x, y, alpha)
		if kind == "train" then
			quad(x - 4, y + 1.5, 8, 8, "gold", alpha or 1, 2, math.pi / 4)
		elseif kind == "ah" then
			box(x, y, 11, "gold", "gold", 0.25)
		elseif kind == "vendor" then
			box(x, y, 11, "bone")
		elseif kind == "gap" then
			quad(x - 6, y, 12, 11, "warn", 0.18, 1)
			for sx = x - 5, x + 5, 4 do
				quad(sx, y, 1, 11, "warn", 0.9, 2)
			end
		else
			box(x, y, 11, "parch", nil, nil, true)
		end
	end
	function t:Set(vm)
		W.start(self.quads)
		W.start(self.labels)
		self.vm = vm
		self.edges = {}
		t.edges = self.edges
		local skill = vm.skill
		if W.secret(skill) or type(skill) ~= "number" then
			skill = nil
		end
		-- the stretch the list shows: a quiet ground over its skill range, behind everything
		local shade = vm.shade
		if shade and type(shade.from) == "number" and type(shade.to) == "number" then
			quad(X(shade.from), 44, X(shade.to) - X(shade.from), 36, "bone", 0.1, -1)
			quad(X(shade.from), 80, X(shade.to) - X(shade.from), 2, "bone", 0.8, 0)
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
			marked[m.at] = true
			mark(m.kind, X(m.at), 28)
		end
		for _, at in ipairs(vm.gates or {}) do
			if not marked[at] then
				mark("train", X(at), 28, 0.6)
			end
		end
		for _, s in ipairs(vm.segments or {}) do
			-- left and right come from the skill values; the width is their difference, never rounded on its own
			local x1, x2 = X(s.from), X(s.to)
			local wd = x2 - x1
			if s.gap then
				quad(x1, 50, wd, 24, "warn", 0.18, 1)
				quad(x1, 50, wd, 1, "warn", 1, 2)
				quad(x1, 73, wd, 1, "warn", 1, 2)
				for sx = x1 + 2, x2 - 2, 4 do
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
				-- a 1-px ink joint on the shared edge tells two lines of one colour apart
				if not s.done and wd > 2 then
					quad(x1, 50, 1, 24, "ink", 1, 3)
				end
				if s.name and wd >= 24 then
					local fs = label(x1 + 4, 56, s.name, s.done and "bone" or "ink", 11, "TOPLEFT", s.done and 0.7 or 1)
					if (fs:GetStringWidth() or 0) > wd - 6 then
						fs:Hide() -- it does not fit: the name is in the tooltip and in the list
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
			label(X(skill), 98, vm.nowLabel or ("You, %d"):format(skill), "bone", 11, "TOP")
		end
		-- the legend: the real marker shapes with one-word labels, in one row at the right
		local lx = BODY_W - 12
		for i = #LEGEND, 1, -1 do
			local e = LEGEND[i]
			local fs = label(lx, 111, e.label, "ash", 10, "TOPRIGHT")
			lx = lx - math.ceil(fs:GetStringWidth() or 0) - 12
			mark(e.kind, lx, 110)
			lx = lx - 22
		end
		if lx < TL_X then
			W.noteOverflow("timeline legend", BODY_W - 12 - lx, BODY_W - 12 - TL_X)
		end
		W.finish(self.quads)
		W.finish(self.labels)
	end
	-- what is under the cursor: a marker (within 6 px, in its lane) or the segment at that skill
	function t:At()
		local vm = self.vm
		local left, top, scale = self:GetLeft(), self:GetTop(), self:GetEffectiveScale()
		local cx, cy = GetCursorPosition()
		if W.secret(cx) or W.secret(cy) or not (vm and left and top and cx and cy and scale and scale > 0) then
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
						hit.name or "No recipe",
						("Skill %d to %d"):format(math.floor(hit.from or 0), math.floor((hit.to or 0) + 0.5)),
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

-- One line of the path, 46 px. Line 1 is the title with the row's whole width, so it is never cut. Line 2: what
-- to buy at the left (worded to fit in Where.lua, whole in the tooltip), the skill range with its band letter and
-- the cost at the right. No button in a row: the other ways are in the detail.
local function pathRow(list)
	local r = W.rowButton(list, ROW_H)
	r.n = W.text(r, "GameFontHighlightSmall", 11)
	r.n:SetPoint("TOPLEFT", 6, -9)
	r.n:SetWidth(20)
	r.n:SetJustifyH("RIGHT")
	r.icon = W.tex(r, "ARTWORK")
	r.icon:SetSize(24, 24)
	r.icon:SetPoint("LEFT", 32, 0)
	r.title = W.text(r, "GameFontHighlight", 12)
	r.title:SetPoint("TOPLEFT", 64, -7)
	r.title:SetPoint("RIGHT", -8, 0)
	r.note = W.text(r, "GameFontHighlightSmall", 11)
	r.note:SetPoint("TOPRIGHT", -8, -26)
	r.note:SetJustifyH("RIGHT")
	r.cost = W.text(r, "GameFontHighlightSmall", 11)
	r.cost:SetPoint("RIGHT", r.note, "LEFT", -4, 0)
	r.cost:SetJustifyH("RIGHT")
	r.range = W.text(r, "GameFontHighlightSmall", 11)
	r.range:SetPoint("TOPRIGHT", r, "TOPLEFT", LIST_W - 140, -26)
	r.range:SetJustifyH("RIGHT")
	r.sub = W.text(r, "GameFontHighlightSmall", 10)
	r.sub:SetPoint("TOPLEFT", 64, -26)
	r.sub:SetPoint("RIGHT", r, "LEFT", LIST_W - 226, 0)
	r.rowLine = W.tex(r, "BORDER")
	r.rowLine:SetHeight(1)
	r.rowLine:SetPoint("BOTTOMLEFT")
	r.rowLine:SetPoint("BOTTOMRIGHT")
	W.fill(r.rowLine, "line", 0.6)
	r.labels = { r.title, r.sub }
	return r
end

local function drawPathRow(r, row)
	r.tip = row.tip
	r.action = row.action or (row.step and { id = "selectStep", step = row.step, enabled = true }) or nil
	local hasIcon = row.icon ~= nil
	W.icon(r.icon, row.icon)
	W.set(r.n, row.n or "", "ash")
	-- without an icon the text starts where the icon would
	local tx = hasIcon and 64 or 34
	r.title:SetPoint("TOPLEFT", tx, -7)
	r.sub:SetPoint("TOPLEFT", tx, -26)
	local tone = (row.kind == "gap" and "warn") or (row.kind == "unlock" and "gold") or "bone"
	W.set(r.title, row.title, tone, row.done and 0.6 or 1)
	W.set(r.sub, row.sub or "", row.kind == "gap" and "warn" or "ash")
	-- the range wears the band colour and its letter: colour is never the only signal
	local letter = W.BAND_LETTER[row.rangeTone]
	W.set(
		r.range,
		row.range and ((letter and letter ~= "-" and (letter .. " ") or "") .. row.range) or "",
		row.rangeTone or "ash"
	)
	W.set(r.note, row.costNote or "", "warn")
	r.note:SetWidth(row.costNote and math.ceil(r.note:GetStringWidth() or 0) or 1)
	W.set(r.cost, row.cost or "", "bone")
	W.selectRow(r, row.selected == true, row.rangeTone or "bone")
end

-- The header of the stretch shown: its name and range, then the rank trainings that fall in it (two lines; more
-- are counted on the second line and listed in the tooltip).
local function stretchHead(parent)
	local h = W.frame("Frame", nil, parent)
	h:SetSize(LIST_W, HEAD_H)
	h.title = W.text(h, "GameFontNormalSmall", 12)
	h.title:SetPoint("TOPLEFT", 6, -4)
	h.count = W.text(h, "GameFontHighlightSmall", 11)
	h.count:SetPoint("TOPRIGHT", -8, -5)
	h.count:SetJustifyH("RIGHT")
	h.title:SetPoint("RIGHT", h.count, "LEFT", -8, 0)
	h.lines = {}
	for i = 1, HEAD_LINES do
		local fs = W.text(h, "GameFontHighlightSmall", 11)
		fs:SetPoint("TOPLEFT", 6, -(HEAD_H + (i - 1) * HEAD_LINE))
		fs:SetPoint("RIGHT", -8, 0)
		h.lines[i] = fs
	end
	h.rule = W.tex(h, "BORDER")
	h.rule:SetPoint("BOTTOMLEFT")
	h.rule:SetPoint("BOTTOMRIGHT")
	W.fill(h.rule, "line")
	h:EnableMouse(true)
	h:SetScript("OnEnter", function(self)
		W.showTip(self, self.tip or W.tipOf(self, self.title, self.lines[1], self.lines[2]))
	end)
	h:SetScript("OnLeave", W.hideTip)
	function h:Set(s)
		h.rule:SetHeight(W.px(h, 1, 1))
		local head = s and s.head or {}
		local lines = head.lines or {}
		W.set(self.title, head.title or (s and s.label) or "", "gold")
		W.set(self.count, s and ("%d to %d of the path"):format(s.rows[1].n or 0, s.rows[#s.rows].n or 0) or "", "ash")
		local n = math.min(#lines, HEAD_LINES)
		for i = 1, HEAD_LINES do
			local text = lines[i]
			if i == HEAD_LINES and #lines > HEAD_LINES then
				text = ("%s, and %d more"):format(lines[i], #lines - HEAD_LINES)
			end
			W.set(self.lines[i], i <= n and text or "", "bone")
			self.lines[i]:SetShown(i <= n)
		end
		self.tip = #lines > HEAD_LINES and { head.title or "", unpack(lines) } or nil
		local height = HEAD_H + n * HEAD_LINE
		self:SetHeight(height)
		return height
	end
	return h
end

-- The stretch bar: Previous, one button per stretch (its skill range, with "you are here" or "done" under it), Next.
-- With more stretches than fit, the buttons shown are the ones around the selected stretch.
local STRETCH_NAV, STRETCH_MIN = 78, 78
local function stretchBar(parent)
	local bar = W.frame("Frame", nil, parent)
	bar:SetSize(BODY_W, BAR_H)
	bar.prev = W.button(bar, STRETCH_NAV, BAR_H)
	bar.prev:SetPoint("TOPLEFT", 0, 0)
	bar.next = W.button(bar, STRETCH_NAV, BAR_H)
	bar.next:SetPoint("TOPRIGHT", 0, 0)
	bar.pool = W.pool(function()
		local b = W.button(bar, STRETCH_MIN, BAR_H)
		b.state = W.text(b, "GameFontHighlightSmall", 9)
		b.state:SetPoint("BOTTOM", 0, 4)
		b.state:SetJustifyH("CENTER")
		return b
	end)
	function bar:Set(stretches, shown)
		stretches = stretches or {}
		local n = #stretches
		local room = BODY_W - 2 * (STRETCH_NAV + 6)
		local fit = math.max(1, math.floor((room + 4) / (STRETCH_MIN + 4)))
		local count = math.min(n, fit)
		-- the window of buttons: centred on the stretch shown, clamped to the ends
		local first = math.max(1, math.min(n - count + 1, (shown or 1) - math.floor(count / 2)))
		local bw = count > 0 and math.floor((room - (count - 1) * 4) / count) or 0
		W.start(self.pool)
		for k = 1, count do
			local s = stretches[first + k - 1]
			local b = W.take(self.pool)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", STRETCH_NAV + 6 + (k - 1) * (bw + 4), 0)
			b:SetSize(bw, BAR_H)
			b.onClick = nil
			b.selected = s.selected == true
			W.setButton(
				b,
				{ id = "selectStretch", index = s.index, label = s.label, enabled = true, tip = s.tip },
				"quiet"
			)
			-- the label sits high when a state line is under it; done stretches are dimmed
			local state = s.state
			b.labelY = state and 6 or 0
			W.paintButton(b)
			W.set(b.state, state or "", s.current and "gold" or "ash")
			b:SetAlpha((s.done and not b.selected) and 0.6 or 1)
			if b.selected then
				W.fill(b.bg, "line", 0.8)
			end
		end
		W.finish(self.pool)
		local at = shown or 1
		W.setButton(self.prev, {
			id = "selectStretch",
			index = at - 1,
			label = "Previous",
			enabled = at > 1,
			tip = at > 1 and stretches[at - 1].head and stretches[at - 1].head.title or nil,
		}, "quiet")
		W.setButton(self.next, {
			id = "selectStretch",
			index = at + 1,
			label = "Next",
			enabled = at < n,
			tip = at < n and stretches[at + 1].head and stretches[at + 1].head.title or nil,
		}, "quiet")
		self.first, self.count = first, count
		return count
	end
	return bar
end

-- The detail of the selected line, 356 wide and as tall as the list. Top down: the title; "Do this" and "Get the
-- recipe" as labelled paragraphs; then one paged list (W.list) that holds the Materials and the Other ways, each
-- under its header; the small map when the line needs a trip and there is room for it; the buttons. The list takes
-- whatever height is left, so the card never needs more than its box: more rows than fit turn pages.
local DETAIL_PAD, DETAIL_INNER, LABEL_W, MAP_H = 12, DETAIL_W - 3 - 24, 92, 72
local MAT_H, WAY_H, SECTION_H = 18, 22, 22

-- One row of the detail's list: a section header, a material (name, have / need, source and unit price) or a
-- way (a radio row; the plan's pick is filled).
local function detailRow(list)
	local r = W.rowButton(list, WAY_H)
	r.head = W.text(r, "GameFontNormalSmall", 11)
	r.head:SetPoint("BOTTOMLEFT", 0, 5)
	r.headLine = W.tex(r, "BORDER")
	r.headLine:SetHeight(1)
	r.headLine:SetPoint("BOTTOMLEFT")
	r.headLine:SetPoint("BOTTOMRIGHT")
	W.fill(r.headLine, "line")
	r.outer = W.disc(r, 12, "ARTWORK", 1)
	r.outer:SetPoint("LEFT", 2, 0)
	r.mid = W.disc(r, 10, "ARTWORK", 2)
	r.mid:SetPoint("CENTER", r.outer, "CENTER")
	r.dot = W.disc(r, 6, "ARTWORK", 3)
	r.dot:SetPoint("CENTER", r.outer, "CENTER")
	r.right = W.text(r, "GameFontHighlightSmall", 11)
	r.right:SetPoint("RIGHT", -2, 0)
	r.right:SetJustifyH("RIGHT")
	r.count = W.text(r, "GameFontHighlightSmall", 11)
	r.count:SetPoint("RIGHT", r, "LEFT", DETAIL_INNER - 126, 0)
	r.count:SetJustifyH("RIGHT")
	r.label = W.text(r, "GameFontHighlightSmall", 11)
	r.labels = { r.label, r.right }
	return r
end

local function drawDetailRow(r, it)
	local head, way = it.kind == "head", it.kind == "way"
	r.action, r.tip = way and it.action or nil, it.tip
	r.head:SetShown(head)
	r.headLine:SetShown(head)
	r.outer:SetShown(way)
	r.mid:SetShown(way)
	r.dot:SetShown(way and it.picked == true)
	r.label:SetShown(not head)
	r.right:SetShown(not head)
	r.count:SetShown(it.kind == "material")
	if head then
		W.set(r.head, it.text, "gold")
		return
	end
	r.label:ClearAllPoints()
	r.label:SetPoint("LEFT", way and 22 or 0, 0)
	if way then
		r.outer:SetVertexColor(W.rgb(it.picked and "gold" or "ash"))
		r.mid:SetVertexColor(W.rgb("surface"))
		r.dot:SetVertexColor(W.rgb("gold"))
		r.label:SetPoint("RIGHT", r.right, "LEFT", -8, 0)
		W.set(r.label, it.label, it.picked and "bone" or "ash")
		W.set(r.right, it.right or "", it.picked and "gold" or "ash")
	else
		-- "13 / 24": what the bags hold of what the line needs; green and a full count when there is enough
		local have, need = it.have or 0, it.need or 0
		r.label:SetPoint("RIGHT", r.count, "LEFT", -8, 0)
		W.set(r.label, it.name, "bone")
		W.set(
			r.count,
			it.need and ("%s / %s"):format(tostring(have), tostring(need)) or "",
			have >= need and "green" or "bone"
		)
		W.set(r.right, it.right or it.price or it.source or "", it.tone == "warn" and "warn" or "ash")
	end
end

local function detail(parent)
	local d = W.card(parent, DETAIL_W, LIST_H)
	local inner = DETAIL_INNER
	d.area = W.pages(d, inner, LIST_H - 2 * DETAIL_PAD, "path detail")
	d.area:SetPoint("TOPLEFT", 15, -DETAIL_PAD)
	local c = d.area.content
	d.title = W.para(c, "GameFontHighlightLarge", 15, inner)
	d.labels = W.pool(function()
		return W.text(c, "GameFontNormalSmall", 11)
	end)
	d.paras = W.pool(function()
		return W.para(c, "GameFontHighlightSmall", 11, inner - LABEL_W)
	end)
	d.list = W.list(c, inner, 100, {
		make = detailRow,
		draw = drawDetailRow,
		noun = "lines",
		height = function(it)
			return (it.kind == "head" and SECTION_H) or (it.kind == "way" and WAY_H) or MAT_H
		end,
		keep = function(it)
			return it.kind == "head"
		end,
	})
	d.map = ns.MapCanvas.new(d, 330, MAP_H, {
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
	-- the list's items of a detail model: Materials, then Other ways, each under its header
	local function listItems(v)
		local items = {}
		local mats = v.materials or {}
		if #mats > 0 then
			items[#items + 1] = { kind = "head", text = v.materialsTitle or "Materials" }
			for _, m in ipairs(mats) do
				items[#items + 1] = {
					kind = "material",
					name = m.name,
					have = m.have,
					need = m.need,
					right = m.right,
					price = m.price,
					source = m.source,
					tone = m.tone,
					tip = m.tip,
				}
			end
		end
		local ways = v.ways and v.ways.rows or {}
		if #ways > 0 then
			items[#items + 1] = { kind = "head", text = v.ways.title or "Other ways" }
			for _, wy in ipairs(ways) do
				items[#items + 1] = {
					kind = "way",
					label = wy.label,
					right = wy.right,
					picked = wy.picked,
					action = wy.action,
					tip = wy.tip,
				}
			end
		end
		return items
	end
	local function heightOf(items)
		local h = 0
		for _, it in ipairs(items) do
			h = h + ((it.kind == "head" and SECTION_H) or (it.kind == "way" and WAY_H) or MAT_H)
		end
		return h
	end
	function d:Set(v)
		W.start(self.labels)
		W.start(self.paras)
		local box = self.area.h
		if not v then
			self.title:Hide()
			self.map:Hide()
			self.list:Hide()
			W.buttonRow(self.buttons, self, {}, 0, 0, 10)
			local fs = W.take(self.paras)
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", 0, 0)
			fs:SetWidth(inner)
			W.set(fs, "Pick a line in the list or on the timeline to see what it needs and where it is done.", "ash")
			fs:Show()
			self:Rule(nil)
			W.finish(self.labels)
			W.finish(self.paras)
			self.area:SetContentHeight(40)
			return { fits = true }
		end
		self:Rule(v.color or "bone")
		local y = 0
		self.title:ClearAllPoints()
		self.title:SetPoint("TOPLEFT", 0, 0)
		W.set(self.title, v.title, "bone")
		self.title:Show()
		y = y + math.max(15, self.title:GetStringHeight() or 15) + 8
		-- a gold label at the left, its paragraphs at the right
		local function section(name, lines)
			if #lines == 0 then
				return
			end
			local lb = W.take(self.labels)
			lb:ClearAllPoints()
			lb:SetPoint("TOPLEFT", 0, -y)
			lb:SetWidth(LABEL_W - 6)
			W.set(lb, name, "gold")
			lb:Show()
			for _, l in ipairs(lines) do
				local fs = W.take(self.paras)
				fs:ClearAllPoints()
				fs:SetPoint("TOPLEFT", LABEL_W, -y)
				fs:SetWidth(inner - LABEL_W)
				W.set(fs, l.text, l.tone or "ash")
				fs:Show()
				y = y + math.max(11, fs:GetStringHeight() or 11) + 3
			end
			y = y + 5
		end
		local dothis = {}
		for _, l in ipairs(v.dothis or {}) do
			dothis[#dothis + 1] = l
		end
		if v.note then
			dothis[#dothis + 1] = { text = v.note, tone = "warn" }
		end
		section("Do this", dothis)
		local recipe = v.recipe
		section(
			"Get the recipe",
			recipe and recipe.text and { { text = recipe.text, tone = recipe.tone or "ash" } } or {}
		)
		W.finish(self.labels)
		W.finish(self.paras)
		-- what is left belongs to the list; the map is drawn only when the list still shows whole beside it
		local n = W.buttonRow(self.buttons, self, v.actions, 15, 10, inner, v.color, "BOTTOMLEFT")
		local bottom = n > 0 and (24 + 10) or 0
		local items = listItems(v)
		local need = heightOf(items)
		local room = box - y - bottom
		-- with the map the list keeps `withMap` px: enough when it shows whole, or in two pages of at least a
		-- header and two rows; a longer list takes the map's place ("Open in Where" still leads to it)
		local withMap = room - (MAP_H + 8)
		local hasMap = v.where ~= nil
			and (need <= withMap or (withMap >= SECTION_H + 2 * WAY_H + 26 and need <= 2 * (withMap - 26)))
		self.mapDropped = v.where ~= nil and not hasMap
		if hasMap then
			room = room - (MAP_H + 8)
		end
		self.map:SetShown(hasMap)
		if hasMap then
			self.map:SetPoint("BOTTOMLEFT", 15, DETAIL_PAD + bottom)
			self.map:Set(v.where, { mode = "travel" })
			W.setChip(self.mapChip, v.where.title, nil, v.where.sub)
		end
		self.list:ClearAllPoints()
		self.list:SetPoint("TOPLEFT", 0, -y)
		self.list:SetShown(#items > 0)
		self.list:SetBox(room)
		local same = self.shown == v.n and v.n ~= nil
		self.shown = v.n
		self.list:SetItems(items, same)
		local used = y + (#items > 0 and math.min(need, room) or 0) + (hasMap and (MAP_H + 8) or 0) + bottom
		if #items > 0 and room < SECTION_H + WAY_H then
			used = y + SECTION_H + WAY_H + bottom -- the texts above left no room for one header and one row
		end
		self.area:SetContentHeight(used)
		return { fits = used <= box + 0.5, lines = #items, pages = self.list.pageCount, map = hasMap }
	end
	return d
end

built.path = function()
	local p = pageFrame()
	p.timeline = timeline(p)
	p.timeline:SetPoint("TOPLEFT", 0, 0)
	p.bar = stretchBar(p)
	p.bar:SetPoint("TOPLEFT", 0, -BAR_Y)
	p.area = W.pages(p, LIST_W, LIST_H, "path lines")
	p.area:SetPoint("TOPLEFT", 0, -LIST_Y)
	p.head = stretchHead(p.area.content)
	p.head:SetPoint("TOPLEFT", 0, 0)
	p.rows = W.pool(function()
		local r = pathRow(p.area.content)
		r:SetWidth(LIST_W)
		return r
	end)
	p.detail = detail(p)
	p.detail:SetPoint("TOPLEFT", DETAIL_X, -LIST_Y)
	p.parts = { p.timeline, p.bar, p.area, p.detail }
	function p:Draw(vm)
		if
			pageEmpty(self, (not vm or vm.empty) and (vm and (type(vm.empty) == "table" and vm.empty or {
				title = "No plan yet",
				text = vm.empty,
			}) or {
				title = "No path to show",
				text = "Pick a profession at the top. The path is drawn from the plan for that "
					.. "profession; without a plan there is nothing to lay on the timeline.",
			}) or nil)
		then
			self.crumb = nil
			return { steps = 0 }
		end
		local stretch = vm.stretches and vm.stretches[vm.stretch or 0] or nil
		if
			pageEmpty(self, not stretch and {
				title = "No lines on this path",
				text = "The plan for this profession has no line to show: either everything is done, or the "
					.. "path came without its stretches (Where.pathSelect did not run).",
			} or nil)
		then
			self.crumb = nil
			return { steps = #(vm.rows or {}), stretches = 0 }
		end
		self.vm, self.crumb = vm, vm.crumb
		self.timeline:Set(vm)
		self.bar:Set(vm.stretches, vm.stretch)
		local y = self.head:Set(stretch)
		W.start(self.rows)
		for _, row in ipairs(stretch.rows) do
			local r = W.take(self.rows)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", 0, -y)
			drawPathRow(r, row)
			r:Show()
			y = y + ROW_H
		end
		W.finish(self.rows)
		-- a stretch always fits (W.stretches cuts at PATH_MAX rows); one that does not is counted, never scrolled
		self.area:SetContentHeight(y)
		local det = self.detail:Set(vm.detail)
		return {
			steps = #(vm.rows or {}),
			segments = #(vm.segments or {}),
			stretches = #vm.stretches,
			stretch = vm.stretch,
			shown = self.rows.n,
			detailFits = det.fits,
			mapDropped = self.detail.mapDropped or nil,
		}
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
	-- The left column, 296 x 512, top down: the head (34), the selected spot as a card with its yields, then one
	-- list in what is left: the other spots, best first, or (a two-segment control picks) the route to 300. The
	-- list pages ("1 to 4 of 14 spots"); nothing here scrolls and the route never adds height.
	p.side = W.pages(p, 296, BODY_H, "where side")
	p.side:SetPoint("TOPLEFT", 0, 0)
	local c = p.side.content
	p.headTitle = W.text(c, "GameFontHighlight", 12)
	p.headTitle:SetPoint("TOPLEFT", 2, -2)
	p.headTitle:SetWidth(280)
	p.headSub = W.text(c, "GameFontHighlightSmall", 10)
	p.headSub:SetPoint("TOPLEFT", 2, -17)
	p.headSub:SetWidth(280)
	p.list = W.list(c, 286, 100, {
		make = spotRow,
		draw = function(r, s)
			drawSpot(r, s)
			W.selectRow(r, s.selected, "bone")
		end,
		rowHeight = 62,
		noun = "spots",
	})
	p.listMode = W.segments(c, 22)
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
	p.route = W.list(c, 286, 100, {
		make = function(list)
			local r = W.rowButton(list, 34)
			r.range = W.text(r, "GameFontHighlightSmall", 11)
			r.range:SetPoint("TOPLEFT", 10, -5)
			r.range:SetWidth(72)
			r.title = W.text(r, "GameFontHighlightSmall", 11)
			r.title:SetPoint("TOPLEFT", 86, -5)
			r.title:SetPoint("RIGHT", -6, 0)
			r.sub = W.text(r, "GameFontHighlightSmall", 10)
			r.sub:SetPoint("TOPLEFT", 86, -19)
			r.sub:SetPoint("RIGHT", -6, 0)
			r.labels = { r.title, r.sub }
			return r
		end,
		draw = function(r, row)
			r.action = row.key and { id = "selectSpot", key = row.key, enabled = true } or nil
			r.tip = row.tip
			W.set(r.range, row.range, row.tone or "bone")
			W.set(r.title, row.title, row.done and "ash" or "bone")
			W.set(r.sub, row.sub or "", "ash")
		end,
		rowHeight = 34,
		noun = "legs",
	})
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
		self.crumb = where and not where.empty and where.title or nil
		local y = 34
		local spots = vm.spots or {}
		-- the selected spot is the card; the others are the list, in the order given (best first)
		local others, carded = {}, false
		self.card:Hide()
		for _, s in ipairs(spots) do
			if s.selected and where and not where.empty and not carded then
				carded = true
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
				-- at most six yield rows (the model gives four and counts the rest), so the list under the card
				-- always keeps room for two spots and its pager
				local yh = cd.yields:Set(where.yields, 6)
				local ch = 58 + yh + (yh > 0 and 8 or 0)
				cd:SetHeight(ch)
				cd:Show()
				y = y + ch + 6
			else
				others[#others + 1] = s
			end
		end
		if #spots == 0 or vm.empty then
			self.none:ClearAllPoints()
			self.none:SetPoint("TOPLEFT", 8, -y - 6)
			y = y
				+ 12
				+ self.none:Set(type(vm.empty) == "table" and vm.empty or {
					title = "Nothing to fetch right now",
					text = vm.empty or "No step of this profession needs a trip at this skill.",
				})
		else
			self.none:Hide()
		end
		-- the route to 300 takes the list's place when it is picked: it never adds height
		local it = vm.itinerary
		local hasRoute = it and it.rows and #it.rows > 0 or false
		local s = jstate()
		local mode = (hasRoute and (s.whereList == "route" or #others == 0)) and "route" or "spots"
		if hasRoute and #others > 0 then
			self.listMode:ClearAllPoints()
			self.listMode:SetPoint("TOPLEFT", 0, -y)
			self.listMode:Set(
				{
					{ id = "spots", label = "Other spots", tip = "The other spots that give points, best first." },
					{
						id = "route",
						label = it.title or "Route to 300",
						tip = "Where to go at each skill, to the top.",
					},
				},
				mode,
				function(id)
					s.whereList = id
					self:Draw(self.vm)
				end
			)
			y = y + 28
		else
			self.listMode:Hide()
			if hasRoute then
				y = y + 2
			end
		end
		local shown, hidden = self.list, self.route
		if mode == "route" then
			shown, hidden = self.route, self.list
		end
		hidden:Hide()
		local items = mode == "route" and it.rows or others
		local room = BODY_H - y
		shown:ClearAllPoints()
		shown:SetPoint("TOPLEFT", 0, -y)
		shown:SetShown(#items > 0)
		if #items > 0 then
			shown:SetBox(room)
			shown:SetItems(items, self.key == (where and where.key) and self.mode == mode)
		end
		self.mode = mode
		-- the column's own height: the list is cut to the room left, so only the head, the card and the empty
		-- state can overrun, and that is counted
		self.side:SetContentHeight(#items > 0 and math.max(y + 62, 0) or y)

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

local function sidePane(p, name)
	local side = W.pages(p, 324, BODY_H, name)
	side:SetPoint("TOPLEFT", 612, 0)
	return side
end

built.shopping = function()
	local p = pageFrame()
	p.main = W.pages(p, 600, BODY_H, "shopping list")
	p.main:SetPoint("TOPLEFT", 0, 0)
	p.side = sidePane(p, "shopping side")
	p.side.redraw = function()
		p:Draw(p.vm)
	end
	local c = p.side.content
	p.total = W.para(c, "GameFontHighlightLarge", 15, 310)
	-- the errand map sits in a holder, so the side's flow can place and page it like any other piece
	p.mapBox = W.frame("Frame", nil, c)
	p.mapBox:SetSize(314, 180)
	p.map = ns.MapCanvas.new(p.mapBox, 314, 180, {
		onClick = function(map)
			if map.where then
				W.act({ id = "journal", page = "where", spot = map.where.key, enabled = true })
			end
		end,
	})
	p.map:SetPoint("TOPLEFT", 0, 0)
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
		self.vm = vm
		W.items(self.main, items, 586)
		-- the side: total, errand map, its button, then the stock lines; laid by a flow, so a long stock list
		-- turns pages inside the pane
		local flow = W.flow(self.side)
		W.set(self.total, vm.total or "", "bone")
		flow:Add(self.total, math.max(15, self.total:GetStringHeight() or 15) + 8)
		self.map:SetShown(vm.errand ~= nil)
		if vm.errand then
			self.map:Set(vm.errand)
			flow:Add(self.mapBox, 188)
			W.setButton(
				self.open,
				{ id = "journal", page = "where", spot = vm.errand.key, label = "Open in Where", enabled = true },
				"primary",
				vm.errand.color
			)
			flow:Add(self.open, 34)
		else
			self.mapBox:Hide()
			self.open:Hide()
		end
		W.start(self.stock)
		local stock = vm.stock or {}
		if #stock > 0 then
			W.set(self.stockHead, vm.stockTitle or ("Stock (%d)"):format(#stock), "gold")
			flow:Add(self.stockHead, 22, 0, true)
			for _, line in ipairs(stock) do
				local fs = W.take(self.stock)
				W.set(fs, type(line) == "table" and line.text or line, "ash")
				flow:Add(fs, math.max(10, fs:GetStringHeight() or 10) + 4)
			end
		else
			self.stockHead:Hide()
		end
		W.finish(self.stock)
		local sidePages = flow:Finish("lines")
		return { rows = #items, sidePages = sidePages }
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
	p.main = W.pages(p, 600, BODY_H, "alts list")
	p.main:SetPoint("TOPLEFT", 0, 0)
	p.side = sidePane(p, "alts side")
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
		-- three columns that each page on their own: a long list turns pages inside its column
		local sc = W.pages(p, 304, BODY_H, "settings column " .. i)
		sc:SetPoint("TOPLEFT", (i - 1) * 316, 0)
		sc.redraw = function()
			p:Draw(p.vm)
		end
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
		-- pieces go to a flow: it lays them top down and splits them over the column's pages
		local flow = W.flow(sc)
		local col = { flow = flow }
		local function place(x, h, dx, keep)
			col.last = flow:Add(x, h, dx, keep)
			return col.last
		end
		function col.gap(h)
			flow:Gap(h)
		end
		function col.head(s)
			flow:Gap(12)
			local fs = W.take(pl.heads)
			W.set(fs, s, "gold")
			place(fs, 22, 0, true)
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
		-- a button laid over a piece already placed (at its right edge, or right of another button): it takes no
		-- height of its own and shows only with that piece
		function col.over(a, style, entry, wd, after)
			local b = W.take(pl.buttons)
			b.onClick = nil
			W.setButton(b, a, style or "quiet")
			local bw = wd or math.max(64, (b.label:GetStringWidth() or 0) + 20)
			b:SetSize(bw, 20)
			b:ClearAllPoints()
			if after then
				b:SetPoint("LEFT", after, "RIGHT", 6, 0)
			else
				b:SetPoint("RIGHT", entry.obj, "RIGHT", 0, 0)
				-- the row's label ends where the button begins
				if entry.obj.label then
					entry.obj.label:SetPoint("RIGHT", entry.obj, "RIGHT", -(bw + 6), 0)
				end
			end
			flow:With(entry, b)
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
			r.label:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
			if pipState then
				W.fill(r.pip, pipState == "ok" and "green" or (pipState == "broken" and "warn" or "ash"))
				W.fill(r.pipIn, "ink")
				r.pipIn:SetSize(pipState == "broken" and 2 or 6, 6)
			end
			return r, place(r, 20)
		end
		function col.finish()
			for _, pool in pairs(pl) do
				W.finish(pool)
			end
			col.pages = flow:Finish("lines")
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
				local _, listHead = col.row(e.label, e.rows and tostring(#e.rows) or "", nil, "bone", e.tip)
				listHead.keep = #(e.rows or {}) > 0
				for _, r in ipairs(e.rows or {}) do
					local _, entry = col.row(r.text or r.name, nil, nil, "ash", r.tip)
					if r.action then
						col.over(r.action, "quiet", entry)
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
			col.gap(4)
		end
		if #(vm.data or {}) == 0 then
			col.para("No data layer has reported yet.", "ash")
		end
		col.head(vm.explainTitle or "How the plan is made")
		for _, line in ipairs(vm.explain or EXPLAIN) do
			col.para(line, "ash")
			col.gap(2)
		end
		col.finish()

		-- column 3: what the addon learned in game, each list with a reset that asks once in place
		col = column(3)
		col.head(vm.learnedTitle or "Learned in game")
		for _, l in ipairs(vm.learned or {}) do
			local id = l.id or l.title
			local open = self.open[id] == true
			local _, head =
				col.row(("%s (%d)"):format(l.title or "", l.count or #(l.rows or {})), nil, nil, "bone", l.tip)
			local toggle = col.over(
				{ id = "fold", label = open and "Hide" or "Show", enabled = #(l.rows or {}) > 0 },
				"link",
				head
			)
			toggle.onClick = function()
				self.open[id] = not open
				self:Draw(self.vm)
			end
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
				local keep = col.over({ id = "keep", label = "Keep", enabled = true }, "quiet", col.last, 72, yes)
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
			-- an open list shows every row: what does not fit turns the column's pages
			if open then
				for _, r in ipairs(l.rows or {}) do
					col.row(r.text, r.sub, nil, "ash", r.tip)
				end
			end
			col.gap(6)
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

-- The shell's parts (tabs, close, hint, crumb), for the tests.
function J.shell()
	return shell
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
		-- nothing scrolls: `overflow.count` is how many laid-out areas needed more than their box (0 is right),
		-- with the last one named; `pixel` is the window snapping (snaps, how many moved it, the last refusal)
		overflow = W.overflow,
		pixel = W.pixel,
		close = shell.closeKind,
		crumb = shell.crumbText,
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
