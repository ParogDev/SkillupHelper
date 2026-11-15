-- The minimap button (FieldUI.lua draws it, Journal.lua says what it does) and the pixel snapping of the small
-- frames (the tracker and the field card), against the whole addon loaded in TOC order into a sandbox. The frame
-- mock keeps each frame's anchors and works out its rectangle on a 2560 x 1440 screen at a UI scale that puts
-- 1.2 pixels in a unit, so a fractional saved point is visibly off the pixel grid until it is snapped.

local SECRET = {}
local SCREEN_W, SCREEN_H, SCALE = 2560, 1440, 0.64
local K = SCALE * SCREEN_H / 768 -- pixels per UI unit: 1.2

local OPTIONAL = { ["Data/Plan.lua"] = true }

local function tocFiles()
	local out = {}
	for line in io.lines("SkillupHelper.toc") do
		line = line:gsub("\r$", "")
		if line ~= "" and not line:match("^#") then
			out[#out + 1] = (line:gsub("\\", "/"))
		end
	end
	return out
end

------------------------------------------------------------------------------------------------------------- mock

local function noop() end

local function frac(point)
	local fx = point:find("LEFT") and 0 or (point:find("RIGHT") and 1 or 0.5)
	local fy = point:find("TOP") and 1 or (point:find("BOTTOM") and 0 or 0.5)
	return fx, fy
end

-- left, bottom, width, height of a frame from its first anchor (nil when it has none).
local function rect(f)
	if f.screen then
		return 0, 0, f.w, f.h
	end
	local p = f.points[1]
	if not p then
		return nil
	end
	local rl, rb, rw, rh = rect(p[2])
	if not rl then
		return nil
	end
	local w, h = f.w or 0, f.h or 0
	local rfx, rfy = frac(p[3])
	local fx, fy = frac(p[1])
	return rl + rfx * rw + p[4] - fx * w, rb + rfy * rh + p[5] - fy * h, w, h
end

local METHODS = {}
local MT = {
	__index = function(_, k)
		local m = METHODS[k]
		if m then
			return m
		end
		-- any other widget method is accepted and ignored; lower-case keys are plain fields
		if type(k) == "string" and k:match("^%u") then
			return noop
		end
		return nil
	end,
}

local function newFrame(world, kind, name, parent)
	local f = { kind = kind, name = name, parent = parent, world = world, shown = true }
	f.scripts, f.events, f.points, f.lines = {}, {}, {}, {}
	world.frames[#world.frames + 1] = f
	return setmetatable(f, MT)
end

function METHODS:SetShown(on)
	on = on and true or false
	local changed = self.shown ~= on
	self.shown = on
	local fn = changed and self.scripts[on and "OnShow" or "OnHide"]
	if fn then
		fn(self)
	end
end
function METHODS:Show()
	self:SetShown(true)
end
function METHODS:Hide()
	self:SetShown(false)
end
function METHODS:IsShown()
	return self.shown
end
function METHODS:IsVisible()
	return self.shown
end
function METHODS:SetScript(name, fn)
	self.scripts[name] = fn
end
function METHODS:GetScript(name)
	return self.scripts[name]
end
function METHODS:HookScript(name, fn)
	local old = self.scripts[name]
	self.scripts[name] = function(...)
		if old then
			old(...)
		end
		fn(...)
	end
end
function METHODS:RegisterEvent(e)
	self.events[e] = true
end
function METHODS:RegisterUnitEvent(e)
	self.events[e] = true
end
function METHODS:SetSize(w, h)
	self.w, self.h = w, h
end
function METHODS:SetWidth(w)
	self.w = w
end
function METHODS:SetHeight(h)
	self.h = h
end
function METHODS:GetWidth()
	return self.w or 0
end
function METHODS:GetHeight()
	return self.h or 0
end
-- SetPoint(point), (point, x, y), (point, rel, relPoint, x, y) and (point, rel, x, y), as the client takes them.
function METHODS:SetPoint(point, a, b, c, d)
	local rel, relPoint, x, y
	if type(a) == "number" then
		x, y = a, b
	elseif type(b) == "number" then
		rel, x, y = a, b, c
	else
		rel, relPoint, x, y = a, b, c, d
	end
	self.points[#self.points + 1] =
		{ point, rel or self.parent or self.world.UIParent, relPoint or point, x or 0, y or 0 }
end
function METHODS:ClearAllPoints()
	self.points = {}
end
function METHODS:GetNumPoints()
	return #self.points
end
function METHODS:GetPoint(i)
	local p = self.points[i or 1]
	if p then
		return p[1], p[2], p[3], p[4], p[5]
	end
end
function METHODS:GetLeft()
	return (rect(self))
end
function METHODS:GetBottom()
	local _, b = rect(self)
	return b
end
function METHODS:GetTop()
	local l, b, _, h = rect(self)
	return l and b + h or nil
end
function METHODS:GetCenter()
	local l, b, w, h = rect(self)
	if l then
		return l + w / 2, b + h / 2
	end
end
function METHODS:GetEffectiveScale()
	return self.world.scale or SCALE
end
function METHODS:GetScale()
	return 1
end
function METHODS:SetScale(s)
	self.ownScale = s
end
function METHODS:GetFrameLevel()
	return 1
end
function METHODS:IsOwned()
	return false
end
function METHODS:SetText(s)
	self.text = s
end
function METHODS:GetText()
	return self.text
end
function METHODS:SetFontHeight(h)
	self.fontHeight = h
end
function METHODS:GetStringWidth()
	return 40
end
function METHODS:GetStringHeight()
	return self.fontHeight or 10
end
function METHODS:SetTexture(id)
	self.texture = id
end
function METHODS:GetTexture()
	return self.texture
end
function METHODS:CreateTexture()
	return newFrame(self.world, "Texture", nil, self)
end
function METHODS:CreateFontString()
	return newFrame(self.world, "FontString", nil, self)
end
function METHODS:CreateLine()
	return newFrame(self.world, "Line", nil, self)
end
function METHODS:CreateMaskTexture()
	return newFrame(self.world, "MaskTexture", nil, self)
end
-- the tooltip's part
function METHODS:SetOwner(owner, anchor)
	self.owner, self.anchor, self.lines = owner, anchor, {}
	self.points = {}
end
function METHODS:AddLine(s)
	self.lines[#self.lines + 1] = s
end

-- The client of a scenario: { professions = { { line, rank, cap } }, db = SkillupHelperDB before the load,
-- ldb = true (another addon brought LibStub with LibDataBroker and LibDBIcon), shape = "SQUARE" }.
local function client(sc, world)
	local G = {}
	G.CreateFrame = function(kind, name, parent)
		return newFrame(world, kind, name, parent)
	end
	world.UIParent = newFrame(world, "Frame", "UIParent")
	-- sc.scale: another UI scale than the file's 0.64 (the journal's specs run at 0.7: 1.3125 pixels in a unit)
	local k = (world.scale or SCALE) * SCREEN_H / 768
	world.UIParent.screen, world.UIParent.w, world.UIParent.h = true, SCREEN_W / k, SCREEN_H / k
	G.UIParent = world.UIParent
	G.GameTooltip = newFrame(world, "GameTooltip", "GameTooltip", world.UIParent)
	world.tooltip = G.GameTooltip
	-- a 140-unit minimap in the top right corner
	G.Minimap = newFrame(world, "Minimap", "Minimap", world.UIParent)
	G.Minimap:SetSize(140, 140)
	G.Minimap:SetPoint("TOPRIGHT", world.UIParent, "TOPRIGHT", -20, -20)
	world.Minimap = G.Minimap
	G.GetPhysicalScreenSize = function()
		return SCREEN_W, SCREEN_H
	end
	G.GetCursorPosition = function()
		return world.cursor[1], world.cursor[2]
	end
	if sc.shape then
		G.GetMinimapShape = function()
			return sc.shape
		end
	end
	if sc.ldb then
		world.ldb = { objects = {}, iconRegistered = 0 }
		local broker = {
			NewDataObject = function(_, name, obj)
				world.ldb.objects[name] = obj
				return obj
			end,
		}
		local icon = {
			Register = function()
				world.ldb.iconRegistered = world.ldb.iconRegistered + 1
			end,
		}
		G.LibStub = {
			GetLibrary = function(_, name)
				return name == "LibDataBroker-1.1" and broker or (name == "LibDBIcon-1.0" and icon or nil)
			end,
		}
	end
	G.MenuUtil = {
		CreateContextMenu = function(owner, generator)
			local root = { items = {}, owner = owner }
			local function add(kind)
				return function(_, label, a, b)
					local item = { kind = kind, label = label, run = b or a, enabled = true }
					item.SetEnabled = function(self, on)
						self.enabled = on
					end
					root.items[#root.items + 1] = item
					return item
				end
			end
			root.CreateTitle = function(_, title)
				root.title = title
			end
			root.CreateRadio, root.CreateCheckbox, root.CreateButton = add("radio"), add("check"), add("button")
			generator(owner, root)
			world.menu = root
		end,
	}
	G.hooksecurefunc = function(t, name, fn)
		local old = t[name]
		t[name] = function(...)
			local a, b, c = old(...)
			fn(...)
			return a, b, c
		end
	end
	G.SlashCmdList = {}
	G.print = function(s)
		world.printed[#world.printed + 1] = tostring(s)
	end
	G.GetBuildInfo = function()
		return "1.60.1", "70888", "Nov 1 2026", 16001
	end
	G.WOW_PROJECT_ID = 99
	G.GetLocale = function()
		return "enUS"
	end
	G.GetTime = os.clock
	G.time = os.time
	G.date = os.date
	G.debugprofilestop = function()
		return os.clock() * 1000
	end
	G.issecretvalue = function(v)
		return v == SECRET
	end
	G.InCombatLockdown = function()
		return false
	end
	G.IsInInstance = function()
		return false
	end
	G.C_Timer = {
		After = noop,
		NewTicker = function()
			return { Cancel = noop }
		end,
	}
	G.C_AddOns = {
		GetAddOnMetadata = function()
			return nil
		end,
	}
	G.UnitLevel = function()
		return 60
	end
	G.UnitClassBase = function()
		return "WARRIOR"
	end
	G.UnitFactionGroup = function()
		return "Horde"
	end
	G.UnitGUID = function()
		return "Player-0-00000001"
	end
	G.UnitName = function()
		return "Tester"
	end
	G.GetRealmName = function()
		return "Realm"
	end
	G.GetProfessions = function()
		local idx = {}
		for i = 1, #(sc.professions or {}) do
			idx[i] = i
		end
		return unpack(idx)
	end
	G.GetProfessionInfo = function(i)
		local p = sc.professions[i]
		return "Profession", 0, p[2], p[3], 0, 0, p[1]
	end
	G.C_SkillInfo = {
		GetSkillLineInfoByID = function()
			return nil
		end,
	}
	G.GetBindingKey = function()
		return nil
	end
	G.C_Map, G.C_Texture, G.C_SuperTrack, G.GetPlayerFacing = false, false, false, false
	return G
end

-- Loads every TOC file in order into a sandbox and logs in. Returns { env, ns, P, F, W, world, fire }.
local function login(sc)
	sc = sc or {}
	local world = { frames = {}, printed = {}, cursor = { 0, 0 }, scale = sc.scale }
	local G = client(sc, world)
	local env = setmetatable({}, {
		__index = function(_, k)
			local v = G[k]
			if v == false then
				return nil -- named above so another spec's global of that name does not leak in
			end
			if v ~= nil then
				return v
			end
			return rawget(_G, k)
		end,
	})
	rawset(env, "_G", env)
	if sc.db then
		rawset(env, "SkillupHelperDB", sc.db)
	end
	local ns = {}
	for _, file in ipairs(tocFiles()) do
		local chunk, err = loadfile(file)
		if chunk then
			setfenv(chunk, env)
			chunk("SkillupHelper", ns)
		elseif not OPTIONAL[file] then
			error(file .. ": " .. tostring(err))
		end
	end
	local function fire(event, ...)
		for _, f in ipairs(world.frames) do
			if f.events[event] and f.scripts.OnEvent then
				f.scripts.OnEvent(f, event, ...)
			end
		end
	end
	fire("ADDON_LOADED", "SkillupHelper")
	fire("PLAYER_LOGIN")
	local a = { env = env, ns = ns, world = world, fire = fire }
	a.P, a.F, a.W = ns.Provider, ns.FieldUI, ns.Widgets
	a.P.sync = true
	a.db = env.SkillupHelperDB
	a.button = a.F.minimapButton()
	return a
end

local function script(f, name, ...)
	local fn = f.scripts[name]
	assert(fn, "no script " .. name)
	return fn(f, ...)
end

local function whole(v)
	local px = v * K
	return math.abs(px - math.floor(px + 0.5)) < 1e-6
end

local function near(want, got)
	assert.is_true(math.abs(want - got) < 1e-6, ("%s expected, got %s"):format(tostring(want), tostring(got)))
end

-- The menu a right click opens: by label { enabled, run }, and the labels in order.
local function menuOf(a)
	a.world.menu = nil
	script(a.button, "OnClick", "RightButton")
	local m = assert(a.world.menu, "no menu opened")
	local by, labels = {}, {}
	for i, item in ipairs(m.items) do
		by[item.label] = item
		labels[i] = item.label
	end
	return by, labels, m
end

-- A gatherer who tracks the best Herbalism spot. The tracker frame itself is not drawn: its view-model is kept.
local function gatherer(sc)
	sc = sc or {}
	sc.professions = { { 182, 100, 150 } }
	local a = login(sc)
	a.F.setTracker = function(vm)
		a.F.trackerVM = vm
	end
	a.F.update, a.F.hide = noop, noop
	a.W.state.journal = { profession = 182 }
	a.P.snapshot()
	a.spot = assert(a.P.whereOf(182, nil), "no Herbalism spot in the shipped data").key
	return a
end

------------------------------------------------------------------------------------------------------- pure maths

describe("Minimap button: the pure maths", function()
	local F
	setup(function()
		F = login().F
	end)

	it("a round minimap: the button sits on a circle of half the width plus 5", function()
		local x, y = F.minimapOffset(0, 70, 70, "ROUND")
		near(75, x)
		near(0, y)
		x, y = F.minimapOffset(90, 70, 70, "ROUND")
		near(0, x)
		near(75, y)
		x, y = F.minimapOffset(180, 70, 70)
		near(-75, x)
		near(0, y)
		x, y = F.minimapOffset(215, 70, 70, "ROUND")
		near(75 * math.cos(math.rad(215)), x)
		near(75 * math.sin(math.rad(215)), y)
		-- an oval minimap keeps its two radii; an unknown shape is round
		x, y = F.minimapOffset(45, 100, 50, "NO-SUCH-SHAPE")
		near(105 * math.cos(math.rad(45)), x)
		near(55 * math.sin(math.rad(45)), y)
	end)

	it("a square minimap: the button follows the edge and is held at the corners", function()
		local diag = math.sqrt(2 * 75 * 75) - 10
		local x, y = F.minimapOffset(0, 70, 70, "SQUARE")
		near(75, x)
		near(0, y)
		x, y = F.minimapOffset(10, 70, 70, "SQUARE")
		near(75, x) -- clamped to the right edge
		near(diag * math.sin(math.rad(10)), y)
		x, y = F.minimapOffset(45, 70, 70, "SQUARE")
		near(diag * math.cos(math.rad(45)), x)
		near(diag * math.sin(math.rad(45)), y)
		x, y = F.minimapOffset(270, 70, 70, "SQUARE")
		near(0, x)
		near(-75, y)
	end)

	it("a mixed shape is round in its round quadrants only", function()
		local diag = math.sqrt(2 * 75 * 75) - 10
		-- CORNER-TOPRIGHT: the top right quadrant is round, the others square
		local x, y = F.minimapOffset(45, 70, 70, "CORNER-TOPRIGHT")
		near(75 * math.cos(math.rad(45)), x)
		near(75 * math.sin(math.rad(45)), y)
		x, y = F.minimapOffset(225, 70, 70, "CORNER-TOPRIGHT")
		near(diag * math.cos(math.rad(225)), x)
		near(diag * math.sin(math.rad(225)), y)
	end)

	it("the cursor gives the angle from the minimap's centre, in the minimap's own scale", function()
		near(0, F.minimapAngle(200, 100, 100, 100, 1))
		near(90, F.minimapAngle(100, 200, 100, 100, 1))
		near(180, F.minimapAngle(0, 100, 100, 100, 1))
		near(270, F.minimapAngle(100, 0, 100, 100, 1))
		-- cursor pixels are divided by the effective scale first
		near(45, F.minimapAngle(400, 400, 100, 100, 2))
		near(225, F.minimapAngle(64, 64, 200, 200, 0.64))
	end)

	it("no angle, and the broken link, when the cursor cannot say", function()
		local a, why = F.minimapAngle(100, 100, 100, 100, 1)
		assert.is_nil(a)
		assert.truthy(why:find("centre", 1, true))
		a, why = F.minimapAngle(nil, 100, 100, 100, 1)
		assert.is_nil(a)
		assert.is_string(why)
		assert.is_nil((F.minimapAngle(SECRET, 100, 100, 100, 1)))
	end)

	it("the tooltip opens towards the middle of the screen", function()
		assert.same({ "TOPRIGHT", "BOTTOMRIGHT" }, { F.minimapTipAnchor(1900, 1000, 2000, 1100) })
		assert.same({ "BOTTOMLEFT", "TOPLEFT" }, { F.minimapTipAnchor(100, 100, 2000, 1100) })
		assert.same({ "TOP", "BOTTOM" }, { F.minimapTipAnchor(1000, 1000, 2000, 1100) })
		assert.same({ "TOPRIGHT", "BOTTOMLEFT" }, { F.minimapTipAnchor(nil, nil, 2000, 1100) })
	end)
end)

------------------------------------------------------------------------------------------------------- the button

describe("Minimap button: the frame", function()
	it("is made once at login, a child of Minimap, at the default angle", function()
		local a = login()
		local b = assert(a.button)
		assert.equal(a.world.Minimap, b.parent)
		assert.is_true(b:IsShown())
		assert.same({ angle = 215, hide = false }, a.db.ui.minimap)
		assert.equal(1, b:GetNumPoints())
		local point, rel, relPoint, x, y = b:GetPoint(1)
		assert.equal("CENTER", point)
		assert.equal(a.world.Minimap, rel)
		assert.equal("CENTER", relPoint)
		-- the offsets are the round ones for 215 degrees, on whole pixels
		local wx, wy = a.F.minimapOffset(215, 70, 70, "ROUND")
		assert.is_true(math.abs(wx - x) <= 0.5 / K and math.abs(wy - y) <= 0.5 / K)
		assert.is_true(whole(x) and whole(y))
		assert.equal(b, a.F.minimapCreate())
		assert.is_nil(a.P.diag.firstError)
	end)

	it("restores the saved angle, and follows a square minimap", function()
		local a = login({ db = { ui = { minimap = { angle = 90, hide = false } } } })
		local _, _, _, x, y = a.button:GetPoint(1)
		near(0, x)
		near(75, y)
		local sq = login({ db = { ui = { minimap = { angle = 45 } } }, shape = "SQUARE" })
		_, _, _, x, y = sq.button:GetPoint(1)
		local diag = (math.sqrt(2 * 75 * 75) - 10) * math.cos(math.rad(45))
		assert.is_true(math.abs(diag - x) <= 0.5 / K and math.abs(diag - y) <= 0.5 / K)
		assert.equal("SQUARE", sq.F.minimapDiag().shape)
	end)

	it("a drag moves it around the edge and saves the angle", function()
		local a = login()
		local cx, cy = a.world.Minimap:GetCenter()
		script(a.button, "OnDragStart")
		assert.is_function(a.button.scripts.OnUpdate)
		-- straight above the centre, in screen pixels
		a.world.cursor = { cx * SCALE, (cy + 50) * SCALE }
		script(a.button, "OnUpdate", 0.01)
		assert.equal(90, a.db.ui.minimap.angle)
		-- then to the left of it, and let go there
		a.world.cursor = { (cx - 80) * SCALE, cy * SCALE }
		script(a.button, "OnDragStop")
		assert.is_nil(a.button.scripts.OnUpdate)
		assert.equal(180, a.db.ui.minimap.angle)
		local _, _, _, x, y = a.button:GetPoint(1)
		near(-75, x)
		near(0, y)
	end)

	it("left click toggles the journal", function()
		local a = login()
		local toggled = 0
		a.ns.JournalUI.Toggle = function()
			toggled = toggled + 1
		end
		script(a.button, "OnClick", "LeftButton")
		script(a.button, "OnClick", "LeftButton")
		assert.equal(2, toggled)
		assert.equal(2, a.F.minimapDiag().clicks)
		assert.is_nil(a.world.menu)
	end)

	it("hides and shows through the setting, the slash command and the menu; never destroyed", function()
		local a = login()
		local b = a.button
		local function row()
			for _, e in ipairs(a.P.settingsPage().planner) do
				if e.key == "minimap" then
					return e
				end
			end
		end
		assert.equal("check", row().kind)
		assert.is_true(row().value)
		assert.is_true(a.P.provider.setting("minimap", false))
		assert.is_false(b:IsShown())
		assert.is_true(a.db.ui.minimap.hide)
		assert.is_false(row().value)
		assert.is_true(a.P.provider.setting("minimap", true))
		assert.is_true(b:IsShown())
		assert.is_false(a.db.ui.minimap.hide)
		-- /skillup minimap toggles and says which
		a.world.printed = {}
		a.env.SlashCmdList.SKILLUPHELPER("minimap")
		assert.is_false(b:IsShown())
		assert.truthy(a.world.printed[1]:find("/skillup minimap", 1, true))
		a.env.SlashCmdList.SKILLUPHELPER("minimap")
		assert.is_true(b:IsShown())
		a.env.SlashCmdList.SKILLUPHELPER("minimap off")
		a.env.SlashCmdList.SKILLUPHELPER("minimap off")
		assert.is_false(b:IsShown())
		a.env.SlashCmdList.SKILLUPHELPER("minimap on")
		assert.is_true(b:IsShown())
		-- the menu's own entry: one chat line on how to get it back
		a.world.printed = {}
		menuOf(a)["Hide this button"].run()
		assert.is_false(b:IsShown())
		assert.equal(1, #a.world.printed)
		assert.truthy(a.world.printed[1]:find("/skillup minimap", 1, true))
		assert.equal(b, a.F.minimapButton())
		assert.is_true(a.F.minimapDiag().created)
		assert.is_false(a.F.minimapDiag().shown)
	end)

	it("a button hidden before the /reload is made hidden", function()
		local a = login({ db = { ui = { minimap = { angle = 10, hide = true } } } })
		assert.is_table(a.button)
		assert.is_false(a.button:IsShown())
		assert.is_false(a.F.minimapDiag().shown)
		assert.equal(10, a.F.minimapDiag().angle)
	end)

	it("without a Minimap frame nothing is made and the selftest names the link", function()
		local a = login()
		-- a fresh FieldUI in a client that has no Minimap
		local env = setmetatable({}, {
			__index = function(_, k)
				if k == "Minimap" then
					return nil
				end
				return a.env[k]
			end,
		})
		local ns = { Widgets = a.W, MapCanvas = a.ns.MapCanvas }
		local chunk = assert(loadfile("FieldUI.lua"))
		setfenv(chunk, env)
		chunk("SkillupHelper", ns)
		local b, why = ns.FieldUI.minimapCreate()
		assert.is_nil(b)
		assert.equal("the Minimap frame is absent", why)
		assert.is_false(ns.FieldUI.minimapSetShown(true))
		local d = ns.FieldUI.minimapDiag()
		assert.is_false(d.created)
		assert.equal("the Minimap frame is absent", d.why)
	end)
end)

--------------------------------------------------------------------------------------------------------- the menu

describe("Minimap button: the menu", function()
	it("nothing open, nothing to track: the entries say why", function()
		local a = login()
		local by, labels, m = menuOf(a)
		assert.equal("SkillupHelper", m.title)
		assert.equal(a.button, m.owner)
		assert.same({
			"Open the journal",
			"Show the panel (open a profession window first)",
			"Track this spot (pick a gathering skill or Lockpicking in the journal)",
			"Settings",
			"Hide this button",
		}, labels)
		assert.is_true(by["Open the journal"].enabled)
		assert.is_false(by["Show the panel (open a profession window first)"].enabled)
		assert.is_false(by["Track this spot (pick a gathering skill or Lockpicking in the journal)"].enabled)
		assert.is_true(by["Settings"].enabled)
		assert.is_true(by["Hide this button"].enabled)
		-- the journal and its settings page
		local opened = {}
		a.ns.JournalUI.open = function(page)
			opened[#opened + 1] = page or "default"
		end
		by["Open the journal"].run()
		by["Settings"].run()
		assert.same({ "default", "settings" }, opened)
		assert.is_nil(a.P.diag.firstError)
	end)

	it("a profession window open: the panel entry toggles the docked panel", function()
		local a = login()
		local calls = {}
		a.ns.setShown = function(shown, byUser)
			calls[#calls + 1] = { shown, byUser }
		end
		a.ns.tradeSkillOpen = true
		a.ns.UI.frame = newFrame(a.world, "Frame")
		local by = menuOf(a)
		assert.is_true(by["Hide the panel"].enabled)
		by["Hide the panel"].run()
		a.ns.UI.frame:Hide()
		by = menuOf(a)
		assert.is_nil(by["Hide the panel"])
		by["Show the panel"].run()
		assert.same({ { false, true }, { true, true } }, calls)
	end)

	it("a gatherer: Track this spot, then Stop tracking", function()
		local a = gatherer()
		local by = menuOf(a)
		assert.is_true(by["Track this spot"].enabled)
		by["Track this spot"].run()
		assert.same({ line = 182, spot = a.spot }, a.P.tracked())
		by = menuOf(a)
		assert.is_nil(by["Track this spot"])
		assert.is_true(by["Stop tracking"].enabled)
		by["Stop tracking"].run()
		assert.is_nil(a.P.tracked())
		assert.is_nil(a.P.diag.firstError)
	end)

	it("the spot selected in the journal is the one tracked", function()
		local a = gatherer()
		a.ns.JournalUI.ctx.spot = "a-chosen-spot"
		local tracked
		a.P.provider.trackSpot = function(key)
			tracked = key
		end
		menuOf(a)["Track this spot"].run()
		assert.equal("a-chosen-spot", tracked)
	end)

	it("no MenuUtil: the click is counted and the link named", function()
		local a = login()
		rawset(a.env, "MenuUtil", false)
		script(a.button, "OnClick", "RightButton")
		assert.equal("MenuUtil absent", a.F.minimapDiag().why)
	end)
end)

------------------------------------------------------------------------------------------------------ the tooltip

describe("Minimap button: the tooltip", function()
	local HINT = "Left-click: journal. Right-click: menu. Drag: move."

	local function texts(lines)
		local out = {}
		for i, l in ipairs(lines) do
			out[i] = type(l) == "table" and l[1] or l
		end
		return out
	end

	it("nothing tracked", function()
		local a = login()
		assert.same(
			{ "SkillupHelper", "Nothing tracked. Left-click opens the journal.", HINT },
			texts(a.P.minimapTip())
		)
	end)

	it("the docked plan's next step when a plan was read", function()
		local a = login()
		a.ns.UI.model = { profession = "Blacksmithing" }
		a.ns.UI.last = { now = { title = "Copper Chain Belt", sub = "Craft 12" } }
		assert.same({ "SkillupHelper", "Copper Chain Belt", "Craft 12", HINT }, texts(a.P.minimapTip()))
		-- a second line that is not a sentence (a table of terms) is left out
		a.ns.UI.last.now.sub = { "x" }
		assert.same({ "SkillupHelper", "Copper Chain Belt", HINT }, texts(a.P.minimapTip()))
	end)

	it("the tracked spot's tracker lines win over the docked plan", function()
		local a = gatherer()
		a.ns.UI.model = {}
		a.ns.UI.last = { now = { title = "Copper Chain Belt", sub = "Craft 12" } }
		a.P.provider.trackSpot(a.spot)
		assert.is_table(a.F.trackerVM)
		a.F.trackerVM = { title = "Hillsbrad Foothills", sub = "Briarthorn" }
		assert.same({ "SkillupHelper", "Hillsbrad Foothills", "Briarthorn", HINT }, texts(a.P.minimapTip()))
	end)

	it("a secret title degrades to one plain line", function()
		local a = gatherer()
		a.P.provider.trackSpot(a.spot)
		a.F.trackerVM = { title = SECRET, sub = SECRET }
		local lines = texts(a.P.minimapTip())
		assert.same({ "SkillupHelper", "The current step's text is hidden here (protected by the game).", HINT }, lines)
		a.F.trackerVM = { title = SECRET, sub = "Briarthorn" }
		lines = texts(a.P.minimapTip())
		assert.equal(4, #lines)
		for _, l in ipairs(lines) do
			assert.is_string(l)
		end
		assert.is_nil(a.P.diag.firstError)
	end)

	it("hovering fills GameTooltip, anchored away from the screen's corner", function()
		local a = login()
		script(a.button, "OnEnter")
		local tt = a.world.tooltip
		assert.equal(a.button, tt.owner)
		assert.equal("ANCHOR_NONE", tt.anchor)
		assert.same({ "SkillupHelper", "Nothing tracked. Left-click opens the journal.", HINT }, tt.lines)
		-- the minimap is in the top right corner: the tooltip hangs below the button, to its left
		local point, rel, relPoint = tt:GetPoint(1)
		assert.same({ "TOPRIGHT", a.button, "BOTTOMRIGHT" }, { point, rel, relPoint })
		assert.is_true(tt:IsShown())
		script(a.button, "OnLeave")
		assert.is_false(tt:IsShown())
		-- no tooltip while dragging
		script(a.button, "OnDragStart")
		tt.lines = {}
		script(a.button, "OnEnter")
		assert.same({}, tt.lines)
	end)
end)

-------------------------------------------------------------------------------------------------------------- LDB

describe("Minimap button: LibDataBroker", function()
	it("publishes nothing when no addon brought LibDataBroker", function()
		local a = login()
		assert.is_nil(a.F.minimapLDB)
		assert.equal("LibDataBroker not loaded", a.F.minimapDiag().ldb)
		assert.is_true(a.F.minimapDiag().created)
	end)

	it("publishes a launcher with the button's click and tooltip, and leaves LibDBIcon alone", function()
		local a = login({ ldb = true })
		local obj = assert(a.world.ldb.objects.SkillupHelper)
		assert.equal(obj, a.F.minimapLDB)
		assert.equal("published", a.F.minimapDiag().ldb)
		assert.equal("launcher", obj.type)
		assert.equal("Interface\\Icons\\Trade_LeatherWorking", obj.icon)
		assert.equal(0, a.world.ldb.iconRegistered)
		local toggled = 0
		a.ns.JournalUI.Toggle = function()
			toggled = toggled + 1
		end
		local bar = newFrame(a.world, "Button")
		obj.OnClick(bar, "LeftButton")
		assert.equal(1, toggled)
		obj.OnClick(bar, "RightButton")
		assert.equal(bar, a.world.menu.owner)
		local tt = newFrame(a.world, "GameTooltip")
		obj.OnTooltipShow(tt)
		assert.equal("SkillupHelper", tt.lines[1])
		assert.equal(3, #tt.lines)
		-- once only
		assert.is_true(a.F.minimapPublish())
		assert.equal(obj, a.F.minimapLDB)
	end)

	it("the selftest carries the button's state", function()
		local a = login({ ldb = true, db = { ui = { minimap = { angle = 300 } } } })
		a.fire("PLAYER_LOGOUT")
		local st = a.db.selftest.minimap
		assert.is_true(st.created)
		assert.is_true(st.shown)
		assert.equal(300, st.angle)
		assert.equal("ROUND", st.shape)
		assert.equal("published", st.ldb)
		assert.equal(0, st.clicks)
		assert.is_nil(st.why)
	end)
end)

------------------------------------------------------------------------------------------------------- whole pixels

describe("Pixel snapping of the small frames", function()
	it("the mock is off the grid at a fractional point (the bug)", function()
		local a = login()
		local f = newFrame(a.world, "Frame", nil, a.world.UIParent)
		f:SetSize(236, 60)
		f:SetPoint("TOPLEFT", a.world.UIParent, "TOPLEFT", 100.3, -200.7)
		assert.is_false(whole(f:GetLeft()))
		assert.is_false(whole(f:GetTop()))
		assert.is_true(a.W.snap(f))
		assert.is_true(whole(f:GetLeft()))
		assert.is_true(whole(f:GetTop()))
		assert.is_true(whole(f:GetWidth()))
	end)

	it("a tracker restored at a fractional saved point ends on whole pixels", function()
		local a = login({ db = { ui = { tracker = { point = { "TOPLEFT", 100.3, -200.7 } } } } })
		local t = assert(a.F.setTracker({ key = "k", title = "A place", color = "bone" }))
		assert.equal(1, t:GetNumPoints())
		assert.is_true(whole(t:GetLeft()))
		assert.is_true(whole(t:GetTop()))
		assert.is_true(whole(t:GetWidth()) and whole(t:GetHeight()))
		-- it stayed within half a pixel of where it was saved
		assert.is_true(math.abs(t:GetLeft() - 100.3) <= 0.5 / K + 1e-9)
	end)

	it("a tracker restored at a centred fractional point ends on whole pixels too", function()
		local a = login({ db = { ui = { tracker = { point = { "CENTER", 33.37, -41.19 } } } } })
		local t = assert(a.F.setTracker({ key = "k", title = "A place", color = "bone" }))
		assert.is_true(whole(t:GetLeft()))
		assert.is_true(whole(t:GetTop()))
	end)

	it("the tracker's drag stop saves the snapped point", function()
		local a = login()
		local t = assert(a.F.setTracker({ key = "k", title = "A place", color = "bone" }))
		-- where the client leaves a dragged frame: any fraction of a unit
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", a.world.UIParent, "TOPLEFT", 512.4321, -300.777)
		script(t, "OnDragStop")
		local p = a.db.ui.tracker.point
		assert.equal("TOPLEFT", p[1])
		assert.is_true(whole(p[2]) and whole(p[3]))
		local _, _, _, x, y = t:GetPoint(1)
		assert.same({ x, y }, { p[2], p[3] })
		assert.is_true(whole(t:GetLeft()) and whole(t:GetTop()))
	end)

	it("a field card restored at a fractional saved point ends on whole pixels", function()
		local a = login({ db = { ui = { field = { point = { "TOPLEFT", 640.55, -210.15 } } } } })
		local f = assert(a.F.show({ title = "Herbalism", skill = "100 / 150" }))
		assert.is_true(f:IsShown())
		assert.equal(1, f:GetNumPoints())
		assert.is_true(whole(f:GetLeft()))
		assert.is_true(whole(f:GetTop()))
		assert.is_true(whole(f:GetWidth()) and whole(f:GetHeight()))
	end)

	it("the field card's drag stop saves the snapped point", function()
		local a = login()
		local f = assert(a.F.show({ title = "Herbalism" }))
		f:ClearAllPoints()
		f:SetPoint("BOTTOMLEFT", a.world.UIParent, "BOTTOMLEFT", 77.777, 123.456)
		script(f, "OnDragStop")
		local p = a.db.ui.field.point
		assert.equal("BOTTOMLEFT", p[1])
		assert.is_true(whole(p[2]))
		assert.is_true(whole(f:GetLeft()) and whole(f:GetTop()))
		local _, _, _, x, y = f:GetPoint(1)
		assert.same({ x, y }, { p[2], p[3] })
	end)

	it("a field card docked under the tracker is on whole pixels as well", function()
		local a = login({ db = { ui = { tracker = { point = { "TOPLEFT", 300.3, -150.9 } } } } })
		local t = assert(a.F.setTracker({ key = "k", title = "A place", color = "bone" }))
		local f = assert(a.F.show({ title = "Herbalism" }))
		local _, rel = f:GetPoint(1)
		assert.equal(t, rel)
		assert.is_true(whole(f:GetLeft()) and whole(f:GetTop()))
	end)
end)

-- The journal at UI scale 0.7 on a 2560 x 1440 screen: 1.3125 pixels in a unit, so nothing lands on a pixel by luck.
describe("Pixel snapping of the journal", function()
	local K7 = 0.7 * SCREEN_H / 768
	local function whole7(v)
		local px = v * K7
		return math.abs(px - math.floor(px + 0.5)) < 1e-6
	end
	-- the point the game saved after a drag before the window was snapped
	local SAVED = { "CENTER", -90.99983, -24.99996 }

	local function open(page, sc)
		sc = sc or {}
		sc.scale = 0.7
		sc.professions = sc.professions or { { 164, 28, 75 }, { 186, 60, 150 } }
		sc.db = sc.db or { ui = { journal = { point = { SAVED[1], SAVED[2], SAVED[3] }, profession = 164 } } }
		local a = login(sc)
		a.J = a.ns.JournalUI
		a.frame = a.J.open(page)
		return a
	end

	it("has 1.3125 pixels in a unit, and the saved point is off the grid before it is snapped", function()
		local a = login({ scale = 0.7 })
		near(1.3125, K7)
		local f = newFrame(a.world, "Frame", nil, a.world.UIParent)
		near(K7, a.W.pxPerUnit(f))
		f:SetSize(960, 640)
		f:SetPoint(SAVED[1], a.world.UIParent, SAVED[1], SAVED[2], SAVED[3])
		assert.is_false(whole7(f:GetLeft()))
		assert.is_false(whole7(f:GetTop()))
	end)

	it("a journal restored at the saved fractional point ends with its left and top on whole pixels", function()
		local a = open("overview")
		local f = a.frame
		assert.equal("SkillupHelperJournal", f.name)
		assert.equal(1, f:GetNumPoints())
		assert.is_true(whole7(f:GetLeft()), "left " .. tostring(f:GetLeft() * K7))
		assert.is_true(whole7(f:GetTop()), "top " .. tostring(f:GetTop() * K7))
		assert.is_true(whole7(f:GetWidth()) and whole7(f:GetHeight()))
		-- it moved by less than a pixel from where it was saved
		local _, _, _, x, y = f:GetPoint(1)
		assert.is_true(math.abs(x - SAVED[2]) <= 1 / K7 and math.abs(y - SAVED[3]) <= 1 / K7)
		-- no scale of its own: a fractional scale breaks the fonts' hinting
		assert.is_nil(f.ownScale)
		assert.is_true(a.W.pixel.snaps >= 1)
		-- shown again after it was put off the grid by hand: on the grid again
		a.J.close()
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", a.world.UIParent, "TOPLEFT", 301.37, -99.11)
		a.J.open("overview")
		assert.is_true(whole7(f:GetLeft()) and whole7(f:GetTop()))
	end)

	it("a drag stop saves { point, x, y } with the offsets on whole pixels", function()
		local a = open("overview")
		local f = a.frame
		local band
		for _, c in ipairs(a.world.frames) do
			if c.parent == f and c.scripts.OnDragStop then
				band = c
			end
		end
		assert(band, "the title band has no OnDragStop")
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", a.world.UIParent, "TOPLEFT", 412.3456, -77.7777)
		script(band, "OnDragStop")
		local p = a.db.ui.journal.point
		assert.same({ "TOPLEFT", 3 }, { p[1], #p })
		assert.is_true(whole7(p[2]) and whole7(p[3]))
		assert.is_true(whole7(f:GetLeft()) and whole7(f:GetTop()))
	end)

	it("every edge of the timeline is a whole pixel, and segments that meet share their edge", function()
		local a = open("path")
		local page = assert(a.J.page("path"))
		local vm = assert(page.vm, "the provider's path did not draw: " .. tostring(a.J.diag().emptyTitle))
		local t = page.timeline
		assert.is_true(#t.edges > 40)
		for i, x in ipairs(t.edges) do
			local px = x * K7
			assert.is_true(math.abs(px - math.floor(px + 0.5)) < 1e-6, ("edge %d at %s px"):format(i, tostring(px)))
		end
		-- the segments of the plan: each right edge is the next one's left edge, to the bit
		local snap = function(skill)
			return a.W.px(t, 18 + skill * 3)
		end
		local met = 0
		for i = 2, #vm.segments do
			local prev, cur = vm.segments[i - 1], vm.segments[i]
			if prev.to == cur.from then
				met = met + 1
				assert.equal(snap(prev.to), snap(cur.from))
			end
		end
		assert.is_true(met >= 1)
		-- a 1-px rule is exactly one pixel at this scale
		near(1, a.W.px(t, 1, 1) * K7)
		assert.equal(0, a.W.overflow.count, tostring(a.W.overflow.last))
	end)

	it("draws the provider's Overview, Path and Where through the pages with nothing over its box", function()
		local a = open("overview")
		local d = a.J.diag()
		assert.is_nil(d.lastWhy)
		assert.is_true(d.pages.overview.rows >= 10)
		assert.equal(d.pages.overview.rows, d.pages.overview.shown) -- every profession the data ships, on one page
		a.J.open("path")
		d = a.J.diag()
		assert.is_true(d.pages.path.steps >= 1 and d.pages.path.stretches >= 1)
		assert.is_true(d.pages.path.shown <= a.ns.Where.PATH_MAX)
		assert.is_true(d.pages.path.detailFits)
		a.J.open("where", { profession = 186 })
		d = a.J.diag()
		assert.is_true(d.pages.where.spots >= 1)
		assert.is_string(d.crumb)
		a.J.open("path") -- Mining: the world path on the same page
		d = a.J.diag()
		assert.is_true(d.pages.path.steps >= 1 and d.pages.path.stretches >= 1)
		assert.is_nil(d.lastWhy)
		assert.is_nil(a.P.diag.firstError)
		assert.equal(0, d.overflow.count, tostring(d.overflow.last))
	end)
end)
