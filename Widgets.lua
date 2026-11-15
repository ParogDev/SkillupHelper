-- Shared building blocks of the journal, the field card and the tracker: palette, text, buttons, pools, chips,
-- band bars, the yields block, travel legs, errand stops, paged lists and areas (nothing scrolls), pixel snapping
-- and the settings controls. Frames only draw view-models (plain tables); nothing here composes a sentence or computes a plan.
-- UI.lua has older copies of text / fill / edges / newButton / newControl: see docs/ui.md ("To de-duplicate").
local _, ns = ...
local W = {}
ns.Widgets = W

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local ARROW = "Interface\\ChatFrame\\ChatFrameExpandArrow" -- points right at rotation 0
W.WHITE, W.CIRCLE, W.ARROW = WHITE, CIRCLE, ARROW

-- The panel's palette (View.RGB) with the journal's four additions. View.RGB wins when it has the key.
local RGB = {
	orange = { 1, 0.502, 0.251 },
	yellow = { 1, 1, 0 },
	green = { 0.251, 0.753, 0.251 },
	grey = { 0.5, 0.5, 0.5 },
	gold = { 1, 0.82, 0 },
	warn = { 1, 0.376, 0.376 },
	bone = { 0.918, 0.894, 0.839 },
	ash = { 0.549, 0.561, 0.588 },
	ink = { 0.063, 0.075, 0.094 },
	surface = { 0.102, 0.122, 0.153 },
	line = { 0.204, 0.224, 0.267 },
	parch = { 0.78, 0.69, 0.502 },
	field = { 0.047, 0.059, 0.075 },
	horde = { 0.639, 0.188, 0.122 },
	alliance = { 0.2, 0.34, 0.64 },
}
W.RGB = RGB
-- The letter that goes with a band colour, so colour is never the only signal.
W.BAND_LETTER = { orange = "O", yellow = "Y", green = "G", grey = "-", locked = "x" }

-- Counts of what was created, for the selftest (JournalUI.diag).
W.stats = { frames = 0, regions = 0, tips = 0 }

function W.secret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

function W.rgb(name)
	local view = ns.View and ns.View.RGB
	local c = (view and view[name]) or RGB[name] or RGB.bone
	return c[1], c[2], c[3]
end
local rgb = W.rgb

function W.setColor(fs, name, alpha)
	local r, g, b = rgb(name)
	fs:SetTextColor(r, g, b, alpha or 1)
end
local setColor = W.setColor

function W.fill(tex, name, alpha)
	local r, g, b = rgb(name)
	tex:SetColorTexture(r, g, b, alpha or 1)
end
local fill = W.fill

-- Every frame and region made here rounds its own layout to whole screen pixels (see "pixels" below).
local function roundLayout(obj)
	if obj.SetRoundLayoutToNearestPixel then
		obj:SetRoundLayoutToNearestPixel(true)
	end
	return obj
end

function W.frame(kind, name, parent, template)
	W.stats.frames = W.stats.frames + 1
	return roundLayout(CreateFrame(kind, name, parent, template))
end
local frame = W.frame

function W.tex(parent, layer, sub)
	W.stats.regions = W.stats.regions + 1
	return roundLayout(parent:CreateTexture(nil, layer or "ARTWORK", nil, sub))
end
local tex = W.tex

-- A one-line FontString. Fonts go through SetFontObject + SetFontHeight (never SetFont on a FontFamily).
function W.text(parent, font, height, layer)
	W.stats.regions = W.stats.regions + 1
	local fs = roundLayout(parent:CreateFontString(nil, layer or "OVERLAY"))
	fs:SetFontObject(font or "GameFontHighlightSmall")
	if height then
		fs:SetFontHeight(height)
	end
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("MIDDLE")
	fs:SetWordWrap(false)
	return fs
end
local text = W.text

-- A wrapping paragraph of a fixed width.
function W.para(parent, font, height, width)
	local fs = text(parent, font, height)
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(true)
	fs:SetWidth(width)
	return fs
end

-- Sets a text that may be nil or secret: a secret is shown raw (the client may draw it), nil is "".
function W.set(fs, s, tone, alpha)
	if s == nil then
		s = ""
	elseif not W.secret(s) and type(s) ~= "string" then
		s = tostring(s)
	end
	fs:SetText(s)
	if tone then
		setColor(fs, tone, alpha)
	end
end
local set = W.set

function W.edges(owner, layer, parent)
	local out = {}
	for k, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local t = tex(parent or owner, layer or "BORDER")
		if k <= 2 then
			t:SetHeight(1)
			t:SetPoint(side .. "LEFT", owner, side .. "LEFT")
			t:SetPoint(side .. "RIGHT", owner, side .. "RIGHT")
		else
			t:SetWidth(1)
			t:SetPoint("TOP" .. side, owner, "TOP" .. side)
			t:SetPoint("BOTTOM" .. side, owner, "BOTTOM" .. side)
		end
		out[k] = t
	end
	return out
end
local edges = W.edges

function W.paintEdges(list, name, alpha)
	local r, g, b = rgb(name)
	for _, t in ipairs(list) do
		t:SetColorTexture(r, g, b, alpha or 1)
	end
end
local paintEdges = W.paintEdges

-- A filled disc: a white texture under the portrait circle mask (as GuideUI.circle does).
function W.disc(parent, size, layer, sub)
	local t = tex(parent, layer, sub)
	t:SetSize(size, size)
	t:SetTexture(WHITE)
	W.stats.regions = W.stats.regions + 1
	local m = parent:CreateMaskTexture()
	m:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	m:SetAllPoints(t)
	t:AddMaskTexture(m)
	t.mask = m
	return t
end

-- Atlas with a fallback: true when the atlas exists on this client and was set. The broken link is counted.
local atlasKnown = {}
W.atlasMissing = {}
function W.hasAtlas(name)
	if not name then
		return false
	end
	local k = atlasKnown[name]
	if k == nil then
		local ok, info = pcall(function()
			return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name)
		end)
		k = ok and info ~= nil and info ~= false
		atlasKnown[name] = k
		if not k then
			W.atlasMissing[#W.atlasMissing + 1] = name
		end
	end
	return k
end

function W.atlas(t, name, fallbackFile)
	if W.hasAtlas(name) then
		t:SetAtlas(name)
		return true
	end
	if fallbackFile then
		t:SetTexture(fallbackFile)
	end
	return false
end

-- An icon that is a file id, a path or an atlas name ("atlas:Name"); nil hides it.
function W.icon(t, icon)
	if icon == nil or W.secret(icon) then
		t:Hide()
		return
	end
	local name = type(icon) == "string" and icon:match("^atlas:(.+)$")
	if name then
		if not W.atlas(t, name) then
			t:Hide()
			return
		end
	else
		t:SetTexture(icon)
	end
	t:Show()
end

----------------------------------------------------------------------------------------------------------- tooltips

-- Tooltips sit at the right of their owner everywhere. tip: a string, or { title, line, line, ... } where a line is
-- a string or { text, tone }.
function W.showTip(owner, tip)
	if not tip or not GameTooltip then
		return
	end
	W.stats.tips = W.stats.tips + 1
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	if type(tip) == "table" then
		GameTooltip:SetText(tip[1] or "", 1, 1, 1, 1, true)
		for i = 2, #tip do
			local l = tip[i]
			local r, g, b = rgb(type(l) == "table" and l[2] or "ash")
			GameTooltip:AddLine(type(l) == "table" and l[1] or l, r, g, b, true)
		end
	else
		GameTooltip:SetText(tip, 1, 1, 1, 1, true)
	end
	GameTooltip:Show()
end

function W.hideTip(owner)
	if GameTooltip and GameTooltip:IsOwned(owner) then
		GameTooltip:Hide()
	end
end

-- The tip of a row: its own, else the full text of whichever of its labels was cut short.
function W.tipOf(owner, ...)
	if owner.tip then
		return owner.tip
	end
	local out
	for i = 1, select("#", ...) do
		local fs = select(i, ...)
		if fs and fs:IsShown() and fs:IsTruncated() then
			out = out or {}
			out[#out + 1] = fs:GetText()
		end
	end
	return out
end

-------------------------------------------------------------------------------------------------------------- pixels

-- A window that sits on a fraction of a screen pixel draws its text and 1-px rules differently at every position:
-- the client rounds each region on its own. So every window of the addon is kept on whole physical pixels: its
-- size and its top-left corner are snapped after a drag, when it is shown and when the UI scale or the display
-- changes, and its children round their own layout (SetRoundLayoutToNearestPixel, what PixelUtil.SetPoint and
-- SetSize did by hand). With the origin on a pixel a child lands on the same sub-pixel wherever the window is.
W.pixel = { snaps = 0, moved = 0, lastWhy = nil }
local snapped = setmetatable({}, { __mode = "k" }) -- windows to snap again on a scale change

-- Physical pixels per UI unit of this frame (1 when the client cannot say).
function W.pxPerUnit(f)
	local scale = f and f.GetEffectiveScale and f:GetEffectiveScale() or 1
	local _, ph
	if GetPhysicalScreenSize then
		_, ph = GetPhysicalScreenSize()
	end
	if type(scale) ~= "number" or scale <= 0 then
		scale = 1
	end
	if type(ph) ~= "number" or ph <= 0 then
		ph = 768
	end
	return scale * ph / 768
end

-- v UI units as the nearest whole number of pixels at k pixels per unit, back in UI units; at least `min` pixels.
function W.snapValue(v, k, min)
	local px = math.floor(v * k + 0.5)
	if min and v >= 0 and px < min then
		px = min
	end
	return px / k
end

-- v units of frame f on whole pixels.
function W.px(f, v, min)
	return W.snapValue(v, W.pxPerUnit(f), min)
end

-- Turns on pixel rounding for a frame made elsewhere (UI.lua, GuideUI.lua) and everything under it.
function W.roundAll(f)
	if not (f and f.SetRoundLayoutToNearestPixel) then
		return
	end
	f:SetRoundLayoutToNearestPixel(true)
	if f.GetRegions then
		for _, r in ipairs({ f:GetRegions() }) do
			roundLayout(r)
		end
	end
	if f.GetChildren then
		for _, c in ipairs({ f:GetChildren() }) do
			W.roundAll(c)
		end
	end
end

local watch
local function watchScale()
	if watch or not CreateFrame then
		return
	end
	watch = CreateFrame("Frame")
	for _, e in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do
		pcall(watch.RegisterEvent, watch, e)
	end
	watch:SetScript("OnEvent", function()
		for f in pairs(snapped) do
			if f.IsShown and f:IsShown() then
				W.snap(f)
			end
		end
	end)
end

-- Puts a window on whole pixels: its size, then its top-left corner, by shifting the offsets of its one anchor
-- (so a frame docked to another keeps following it). Returns true, or false and the broken link. A frame with
-- several anchors is sized by them and is left alone.
function W.snap(f)
	if not (f and f.GetLeft and f.GetPoint) then
		return false, "no frame"
	end
	watchScale()
	snapped[f] = true
	local k = W.pxPerUnit(f)
	local w, h = f:GetWidth(), f:GetHeight()
	if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
		f:SetSize(W.snapValue(w, k, 1), W.snapValue(h, k, 1))
	end
	if f.GetNumPoints and f:GetNumPoints() ~= 1 then
		W.pixel.lastWhy = "not one anchor"
		return false, W.pixel.lastWhy
	end
	local left, top = f:GetLeft(), f:GetTop()
	local point, rel, relPoint, x, y = f:GetPoint(1)
	if type(left) ~= "number" or type(top) ~= "number" or not point then
		W.pixel.lastWhy = "the frame has no position yet"
		return false, W.pixel.lastWhy
	end
	local dx, dy = W.snapValue(left, k) - left, W.snapValue(top, k) - top
	W.pixel.snaps = W.pixel.snaps + 1
	if math.abs(dx) > 0.0001 or math.abs(dy) > 0.0001 then
		W.pixel.moved = W.pixel.moved + 1
		f:ClearAllPoints()
		f:SetPoint(point, rel, relPoint, (x or 0) + dx, (y or 0) + dy)
	end
	return true
end

-- After a drag: stop, snap, and return the anchor to save as { point, x, y } (offsets already on whole pixels).
function W.dragStop(f)
	f:StopMovingOrSizing()
	W.snap(f)
	local point, _, _, x, y = f:GetPoint(1)
	if point then
		return { point, x, y }
	end
	return nil
end

-------------------------------------------------------------------------------------------------------------- pools

-- A pool is an array that only grows: take() by index, finish() hides the tail. Regions are never destroyed.
function W.pool(make)
	return { items = {}, n = 0, make = make }
end

function W.start(p)
	p.n = 0
end

function W.take(p)
	p.n = p.n + 1
	local x = p.items[p.n]
	if not x then
		x = p.make(p.n)
		p.items[p.n] = x
	end
	return x
end

function W.finish(p)
	for i = p.n + 1, #p.items do
		p.items[i]:Hide()
	end
end

------------------------------------------------------------------------------------------------------------ actions

-- Every click goes through one door. JournalUI sets W.onAction; until then a click is counted and dropped.
W.dropped = 0
function W.act(action, ...)
	if not action or action.enabled == false then
		return
	end
	if W.onAction then
		if ns.guard then
			ns.guard("click", W.onAction, action, ...)
		else
			W.onAction(action, ...)
		end
	else
		W.dropped = W.dropped + 1
	end
end

------------------------------------------------------------------------------------------------------------ buttons

-- Flat buttons. Styles: "primary" (the accent colour), "quiet" (outline), "inert" (cannot act; its label says what
-- to do first), "link" (text only). States: hover, pressed (label drops 1 px), selected (bone edge).
function W.paintButton(b)
	local over = b.over and b.style ~= "inert"
	local r, g, bl = rgb("line")
	if b.style == "primary" then
		r, g, bl = rgb(b.accent or "bone")
		b.bg:SetColorTexture(r, g, bl, (b.down and 0.46) or (over and 0.34) or 0.18)
		for _, t in ipairs(b.edge) do
			t:SetColorTexture(r, g, bl, over and 1 or 0.8)
		end
		setColor(b.label, "bone")
	elseif b.style == "quiet" then
		b.bg:SetColorTexture(r, g, bl, (b.down and 0.8) or (over and 0.5) or 0)
		paintEdges(b.edge, b.selected and "bone" or "line", 1)
		setColor(b.label, (over or b.selected) and "bone" or "ash")
	elseif b.style == "link" then
		b.bg:SetColorTexture(r, g, bl, over and 0.35 or 0)
		paintEdges(b.edge, "line", 0)
		setColor(b.label, over and "bone" or (b.accent or "gold"))
	else
		b.bg:SetColorTexture(r, g, bl, 0.25)
		paintEdges(b.edge, "line", 0.6)
		setColor(b.label, "ash", 0.8)
	end
	-- labelY lifts the label of a button that carries a second line under it (the Path page's stretch buttons)
	local dy = (b.labelY or 0) + (b.down and -1 or 0)
	b.label:SetPoint("LEFT", 8, dy)
	b.label:SetPoint("RIGHT", -8, dy)
end
local paintButton = W.paintButton

function W.button(parent, w, h)
	local b = frame("Button", nil, parent)
	b:SetSize(w or 96, h or 24)
	b.bg = tex(b, "BACKGROUND")
	b.bg:SetAllPoints()
	b.edge = edges(b)
	b.label = text(b, "GameFontHighlightSmall", 12)
	b.label:SetJustifyH("CENTER")
	b.style, b.accent = "quiet", "bone"
	b:SetScript("OnEnter", function(self)
		self.over = true
		paintButton(self)
		W.showTip(self, W.tipOf(self, self.label))
	end)
	b:SetScript("OnLeave", function(self)
		self.over, self.down = false, false
		paintButton(self)
		W.hideTip(self)
	end)
	b:SetScript("OnMouseDown", function(self)
		self.down = self.style ~= "inert"
		paintButton(self)
	end)
	b:SetScript("OnMouseUp", function(self)
		self.down = false
		paintButton(self)
	end)
	b:SetScript("OnClick", function(self, mouse)
		if self.style == "inert" then
			return
		end
		if self.onClick then
			self.onClick(self, mouse)
		else
			W.act(self.action, mouse)
		end
	end)
	paintButton(b)
	return b
end

-- Shows a View action ({ id, label, enabled, tip }) on a button. style: nil picks primary / inert from `enabled`.
function W.setButton(b, a, style, accent)
	if not a then
		b:Hide()
		return
	end
	b.action, b.tip = a, a.tip
	b.style = (a.enabled == false and "inert") or style or "primary"
	b.accent = accent or b.accent or "bone"
	set(b.label, a.label)
	paintButton(b)
	b:Show()
end

-- A row of buttons from actions, laid left to right with a 6-px gap, the first one primary.
function W.buttonRow(pool, parent, actions, x, y, w, accent, point)
	W.start(pool)
	local n = math.min(#(actions or {}), 3)
	local bw = n > 0 and math.floor((w - (n - 1) * 6) / n) or 0
	for i = 1, n do
		local b = W.take(pool)
		b:SetParent(parent)
		b:ClearAllPoints()
		b:SetPoint(point or "TOPLEFT", x + (i - 1) * (bw + 6), y)
		b:SetSize(bw, 24)
		W.setButton(b, actions[i], (actions[i].quiet or i > 1) and "quiet" or nil, accent)
	end
	W.finish(pool)
	return n
end

-- A row that is a button: hover fill, optional selected state (surface fill and a gold rule at its left).
function W.rowButton(parent, h)
	local r = frame("Button", nil, parent)
	r:SetHeight(h or 22)
	r.bg = tex(r, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:Hide()
	r.hover = tex(r, "BACKGROUND", 1)
	r.hover:SetAllPoints()
	fill(r.hover, "line", 0.45)
	r.hover:Hide()
	r.rule = tex(r, "BORDER")
	r.rule:SetWidth(3)
	r.rule:SetPoint("TOPLEFT")
	r.rule:SetPoint("BOTTOMLEFT")
	r.rule:Hide()
	r.labels = {}
	r:SetScript("OnEnter", function(self)
		if self.action or self.onClick then
			self.hover:Show()
		end
		W.showTip(self, W.tipOf(self, unpack(self.labels)))
	end)
	r:SetScript("OnLeave", function(self)
		self.hover:Hide()
		W.hideTip(self)
	end)
	r:SetScript("OnClick", function(self, mouse)
		if self.onClick then
			self.onClick(self, mouse)
		else
			W.act(self.action, mouse)
		end
	end)
	return r
end

function W.selectRow(r, on, tone)
	r.bg:SetShown(on and true or false)
	r.rule:SetShown(on and true or false)
	if on then
		fill(r.bg, "surface")
		fill(r.rule, tone or "gold")
	end
end

-- A context menu from { title, items = { { label, checked, action | func, enabled, kind = "radio"|"check"|nil } } }.
-- Returns false and the broken link when the client has no MenuUtil.
function W.menu(owner, m)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		return false, "MenuUtil absent"
	end
	if not m or not m.items then
		return false, "no menu items"
	end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		if m.title then
			root:CreateTitle(m.title)
		end
		for _, e in ipairs(m.items) do
			local run = function()
				if e.func then
					e.func(e)
				else
					W.act(e.action)
				end
			end
			local checked = function()
				return e.checked and true or false
			end
			local d
			if e.kind == "radio" or (e.kind == nil and e.checked ~= nil) then
				d = root:CreateRadio(e.label, checked, run)
			elseif e.kind == "check" then
				d = root:CreateCheckbox(e.label, checked, run)
			else
				d = root:CreateButton(e.label, run)
			end
			if e.enabled == false and d and d.SetEnabled then
				d:SetEnabled(false)
			end
		end
	end)
	return true
end

-------------------------------------------------------------------------------------------------------------- chips

-- An 18-px chip: 1-px edge and text in the tone, fill tone .18. Without a tone: bone on ink .78, line edge.
function W.chip(parent)
	local c = frame("Frame", nil, parent)
	c:SetSize(60, 18)
	c.bg = tex(c, "BACKGROUND")
	c.bg:SetAllPoints()
	c.edge = edges(c)
	c.icon = tex(c, "ARTWORK")
	c.icon:SetSize(12, 12)
	c.icon:SetPoint("LEFT", 4, 0)
	c.icon:Hide()
	c.label = text(c, "GameFontHighlightSmall", 11)
	c.label:SetPoint("LEFT", 6, 0)
	c:EnableMouse(true)
	c:SetScript("OnEnter", function(self)
		W.showTip(self, self.tip)
	end)
	c:SetScript("OnLeave", W.hideTip)
	return c
end

function W.setChip(c, label, tone, tip, icon)
	if label == nil or label == "" then
		c:Hide()
		return 0
	end
	c.tip = tip
	set(c.label, label)
	local lead = 6
	if icon and W.atlas(c.icon, icon) then
		c.icon:Show()
		lead = 20
	else
		c.icon:Hide()
	end
	c.label:SetPoint("LEFT", lead, 0)
	if tone then
		fill(c.bg, tone, 0.18)
		paintEdges(c.edge, tone, 1)
		setColor(c.label, tone)
	else
		fill(c.bg, "ink", 0.78)
		paintEdges(c.edge, "line", 1)
		setColor(c.label, "bone")
	end
	local w = math.ceil((c.label:GetStringWidth() or 0) + lead + 6)
	c:SetWidth(w)
	c:Show()
	return w
end

-- The mob chip of a where model ({ label, tone, phrase, names, elite }); the tooltip carries the names.
function W.setMobChip(c, mobs)
	if not mobs then
		c:Hide()
		return 0
	end
	local tip = { mobs.label or "Mobs" }
	if mobs.phrase then
		tip[#tip + 1] = { mobs.phrase, mobs.tone or "bone" }
	end
	for _, n in ipairs(mobs.names or {}) do
		tip[#tip + 1] = n
	end
	return W.setChip(c, mobs.label, mobs.tone, tip, mobs.elite and "DungeonSkull" or nil)
end

---------------------------------------------------------------------------------------------------------- band bars

-- A band bar: a track and coloured segments on one axis { lo, hi }. Segments left of `skill` are spent (.38); the
-- one the skill crosses is split in two. A segment with `hatch` is a gap: warn .18 with 1-px warn stripes every 4 px
-- (the pattern is the signal, the colour only repeats it). opts: ticks (1-px ash marks), locked (all spent),
-- req (1-px warn tick), spent (alpha of spent parts), raise (hatch stands 1 px proud on each side).
function W.band(parent, w, h)
	local b = { w = w, h = h or 6, parent = parent }
	b.track = tex(parent, "ARTWORK", -2)
	b.track:SetSize(w, b.h)
	b.segs = W.pool(function()
		return tex(parent, "ARTWORK", 0)
	end)
	b.stripes = W.pool(function()
		return tex(parent, "ARTWORK", 1)
	end)
	b.ticks = W.pool(function()
		return tex(parent, "ARTWORK", 2)
	end)
	function b:Place(point, rel, relPoint, x, y)
		self.track:ClearAllPoints()
		self.track:SetPoint(point, rel, relPoint, x, y)
	end
	function b:X(v, axis)
		local lo, hi = axis.lo or 0, axis.hi or 300
		if hi <= lo then
			return 0
		end
		return math.max(0, math.min(self.w, (v - lo) / (hi - lo) * self.w))
	end
	function b:Hide()
		self.track:Hide()
		for _, p in ipairs({ self.segs, self.stripes, self.ticks }) do
			W.start(p)
			W.finish(p)
		end
	end
	function b:Part(x1, x2, color, alpha, hatch, raise)
		if x2 - x1 < 0.5 then
			return
		end
		local t = W.take(self.segs)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", self.track, "TOPLEFT", x1, raise or 0)
		t:SetSize(x2 - x1, self.h + 2 * (raise or 0))
		fill(t, color, hatch and 0.18 or alpha)
		t:Show()
		if hatch then
			for x = x1 + 1, x2 - 1, 4 do
				local s = W.take(self.stripes)
				s:ClearAllPoints()
				s:SetPoint("TOPLEFT", self.track, "TOPLEFT", x, raise or 0)
				s:SetSize(1, self.h + 2 * (raise or 0))
				fill(s, color, 0.9)
				s:Show()
			end
		end
	end
	function b:Set(segs, axis, skill, opts)
		opts = opts or {}
		axis = axis or { lo = 0, hi = 300 }
		if W.secret(skill) or type(skill) ~= "number" then
			skill = nil -- secret or unknown skill: full bars, no dimming
		end
		W.start(self.segs)
		W.start(self.stripes)
		W.start(self.ticks)
		fill(self.track, "line", opts.track or 0.9)
		self.track:Show()
		local spent = opts.spent or 0.38
		local cut = skill and self:X(skill, axis)
		for _, s in ipairs(segs or {}) do
			local x1, x2 = self:X(s.from or 0, axis), self:X(s.to or 0, axis)
			local a = s.alpha or 1
			if s.hatch then
				self:Part(x1, x2, s.color or "warn", a, true, opts.raise)
			elseif opts.locked then
				self:Part(x1, x2, s.color, spent)
			elseif cut and cut > x1 then
				self:Part(x1, math.min(cut, x2), s.color, spent * a)
				self:Part(math.max(cut, x1), x2, s.color, a)
			else
				self:Part(x1, x2, s.color, a)
			end
		end
		local function tick(v, tone, alpha)
			local t = W.take(self.ticks)
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", self.track, "TOPLEFT", math.min(self.w - 1, self:X(v, axis)), 1)
			t:SetSize(1, self.h + 2)
			fill(t, tone, alpha)
			t:Show()
		end
		for _, v in ipairs(opts.ticks or {}) do
			tick(v, "ash", 0.9)
		end
		if opts.req then
			tick(opts.req, "warn", 1)
		end
		W.finish(self.segs)
		W.finish(self.stripes)
		W.finish(self.ticks)
		return cut
	end
	return b
end

-------------------------------------------------------------------------------------------------------- yields block

local YIELD_H, YIELD_HEAD, NAME_W, BAR_W = 20, 15, 104, 84

-- "Here you get": rows share one axis and one now-line. Returns a frame with :Set(yields) -> height.
function W.yields(parent, w)
	local f = frame("Frame", nil, parent)
	f:SetSize(w, YIELD_HEAD)
	f.w = w
	f.head = text(f, "GameFontHighlightSmall", 10)
	f.head:SetPoint("TOPLEFT", 0, -2)
	f.skill = text(f, "GameFontHighlightSmall", 10)
	f.nowLine = tex(f, "OVERLAY", 2)
	f.nowLine:SetWidth(1)
	f.nowTop = tex(f, "OVERLAY", 3)
	f.nowTop:SetSize(5, 5)
	f.nowTop:SetTexture(WHITE)
	f.nowTop:SetRotation(math.pi / 4)
	f.more = text(f, "GameFontHighlightSmall", 10)
	f.rows = W.pool(function()
		local r = frame("Frame", nil, f)
		r:SetSize(w, YIELD_H)
		r.icon = tex(r, "ARTWORK")
		r.icon:SetSize(16, 16)
		r.icon:SetPoint("LEFT", 0, 0)
		r.name = text(r, "GameFontHighlight", 12)
		r.name:SetPoint("LEFT", 22, 0)
		r.name:SetWidth(NAME_W)
		r.band = W.band(r, BAR_W, 6)
		r.band:Place("LEFT", r, "LEFT", 22 + NAME_W + 6, 0)
		r.right = text(r, "GameFontHighlightSmall", 11)
		r.right:SetPoint("RIGHT", 0, 0)
		r.right:SetPoint("LEFT", r, "LEFT", 22 + NAME_W + 6 + BAR_W + 6, 0)
		r.right:SetJustifyH("RIGHT")
		r:EnableMouse(true)
		r:SetScript("OnEnter", function(self)
			W.showTip(self, W.tipOf(self, self.name, self.right))
		end)
		r:SetScript("OnLeave", W.hideTip)
		return r
	end)
	function f:Set(y, max)
		W.start(self.rows)
		if not y or not y.rows or #y.rows == 0 then
			W.finish(self.rows)
			self:Hide()
			return 0
		end
		local skill = y.skill
		if W.secret(skill) or type(skill) ~= "number" then
			skill = nil
		end
		set(self.head, y.title or "Here you get", "ash")
		local cut
		local n = math.min(#y.rows, max or #y.rows)
		for i = 1, n do
			local row = y.rows[i]
			local r = W.take(self.rows)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", 0, -(YIELD_HEAD + (i - 1) * YIELD_H))
			r.tip = row.tip
			W.icon(r.icon, row.icon)
			local dim = row.state == "grey" or row.state == "locked"
			set(r.name, row.name, dim and "ash" or "bone")
			local c = r.band:Set(
				row.segs,
				y.axis,
				skill,
				{ locked = row.state == "locked", req = row.state == "locked" and row.req }
			)
			cut = cut or c
			-- the letter repeats the colour ("O to 135" reads without colour vision)
			local letter = W.BAND_LETTER[row.state]
			local right = row.right
			if right and letter and row.state ~= "grey" and row.state ~= "locked" and y.letters ~= false then
				right = letter .. " " .. right
			end
			set(r.right, right, row.tone or (row.state == "locked" and "warn") or row.state or "bone")
			r:Show()
		end
		W.finish(self.rows)
		local h = YIELD_HEAD + n * YIELD_H
		local more = y.more or (#y.rows - n)
		if more and more > 0 then
			self.more:ClearAllPoints()
			self.more:SetPoint("TOPLEFT", 22, -h - 2)
			set(self.more, ("%d more"):format(more), "ash")
			self.more:Show()
			h = h + 14
		else
			self.more:Hide()
		end
		if skill and cut then
			local x = 22 + NAME_W + 6 + cut
			self.nowLine:ClearAllPoints()
			self.nowLine:SetPoint("TOPLEFT", x, -YIELD_HEAD + 2)
			self.nowLine:SetHeight(n * YIELD_H)
			fill(self.nowLine, "bone")
			self.nowLine:Show()
			self.nowTop:ClearAllPoints()
			self.nowTop:SetPoint("CENTER", self, "TOPLEFT", x, -YIELD_HEAD + 2)
			self.nowTop:SetVertexColor(rgb("bone"))
			self.nowTop:Show()
			self.skill:ClearAllPoints()
			self.skill:SetPoint("BOTTOM", self, "TOPLEFT", x, -YIELD_HEAD + 5)
			set(self.skill, skill, "bone")
			self.skill:Show()
		else
			self.nowLine:Hide()
			self.nowTop:Hide()
			self.skill:Hide()
		end
		self:SetHeight(h)
		self:Show()
		return h
	end
	return f
end

--------------------------------------------------------------------------------------------------------- travel legs

local LEG_ATLAS = {
	flight = "TaxiNode_Neutral",
	entrance = "poi-door-arrow-up",
	cave = "CaveUnderground-Down",
	trainer = "Profession",
	vendor = "Repair",
	auction = "Auctioneer",
	mailbox = "Mailbox",
	inn = "Innkeeper",
}
W.LEG_ATLAS = LEG_ATLAS

-- Up to 3 legs of 16 px. :Set(travel, done, nowRight) -> height; done = { boolean } from the live state.
function W.legs(parent, w)
	local f = frame("Frame", nil, parent)
	f:SetSize(w, 16)
	f.rows = W.pool(function()
		local r = {}
		r.icon = tex(f, "ARTWORK")
		r.icon:SetSize(12, 12)
		r.dot = W.disc(f, 6, "ARTWORK", 1)
		r.text = text(f, "GameFontHighlightSmall", 11)
		r.right = text(f, "GameFontHighlightSmall", 10)
		r.right:SetJustifyH("RIGHT")
		function r:Hide()
			self.icon:Hide()
			self.dot:Hide()
			self.text:Hide()
			self.right:Hide()
		end
		return r
	end)
	function f:Set(travel, done, nowRight)
		W.start(self.rows)
		local n = math.min(#(travel or {}), 3)
		local now
		for i = 1, n do
			local leg = travel[i]
			local r = W.take(self.rows)
			local y = -(i - 1) * 16 - 8
			local isDone = done and done[i]
			if not isDone and not now then
				now = i
			end
			r.icon:ClearAllPoints()
			r.icon:SetPoint("CENTER", self, "TOPLEFT", 6, y)
			r.dot:ClearAllPoints()
			r.dot:SetPoint("CENTER", self, "TOPLEFT", 6, y)
			if isDone then
				r.icon:Hide()
				r.dot:SetVertexColor(rgb("green"))
				r.dot:Show()
			elseif W.atlas(r.icon, LEG_ATLAS[leg.icon] or leg.icon) then
				r.icon:Show()
				r.dot:Hide()
			else
				r.icon:Hide()
				r.dot:SetVertexColor(rgb("ash"))
				r.dot:Show()
			end
			r.right:ClearAllPoints()
			r.right:SetPoint("RIGHT", self, "TOPRIGHT", 0, y)
			set(r.right, (now == i and nowRight) or leg.right or "", now == i and "bone" or "ash")
			r.right:Show()
			r.text:ClearAllPoints()
			r.text:SetPoint("LEFT", self, "TOPLEFT", 18, y)
			r.text:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
			local unsure = leg.confidence and leg.confidence ~= "confirmed"
			set(r.text, leg.text, unsure and "parch" or (now == i and "bone" or "ash"))
			r.text:Show()
		end
		W.finish(self.rows)
		self:SetHeight(math.max(1, n * 16))
		self:SetShown(n > 0)
		return n * 16
	end
	return f
end

-------------------------------------------------------------------------------------------------------- errand stops

-- The numbered disc of a stop, in the states of the pins: now = filled step colour, todo = bone outline,
-- done = green with a tick mark ("v"), unconfirmed = parch outline.
function W.stopDisc(parent, size)
	local d = {}
	d.outer = W.disc(parent, size, "ARTWORK", 1)
	d.inner = W.disc(parent, size - 2, "ARTWORK", 2)
	d.inner:SetPoint("CENTER", d.outer, "CENTER")
	d.num = text(parent, "GameFontHighlightSmall", size >= 16 and 11 or 10)
	d.num:SetPoint("CENTER", d.outer, "CENTER")
	d.num:SetJustifyH("CENTER")
	function d:Set(n, state, color, confidence)
		local unsure = confidence and confidence ~= "confirmed"
		if state == "done" then
			self.outer:SetVertexColor(rgb("green"))
			self.inner:Hide()
			set(self.num, "v", "ink")
		elseif state == "now" and not unsure then
			self.outer:SetVertexColor(rgb(color or "bone"))
			self.inner:Hide()
			set(self.num, n, "ink")
		else
			self.outer:SetVertexColor(rgb(unsure and "parch" or "bone"))
			self.inner:SetVertexColor(rgb("ink"))
			self.inner:Show()
			set(self.num, n, unsure and "parch" or "bone")
		end
		self.outer:Show()
		self.num:Show()
	end
	function d:Hide()
		self.outer:Hide()
		self.inner:Hide()
		self.num:Hide()
	end
	return d
end

-- Stop rows of 36 px. :Set(stops, color, max, nowRight) -> height.
function W.stops(parent, w)
	local f = frame("Frame", nil, parent)
	f:SetSize(w, 36)
	f.rows = W.pool(function()
		local r = frame("Frame", nil, f)
		r:SetSize(w, 36)
		r.disc = W.stopDisc(r, 18)
		r.disc.outer:SetPoint("LEFT", 0, 0)
		r.right = text(r, "GameFontHighlightSmall", 11)
		r.right:SetPoint("TOPRIGHT", 0, -4)
		r.right:SetJustifyH("RIGHT")
		r.name = text(r, "GameFontHighlight", 12)
		r.name:SetPoint("TOPLEFT", 26, -4)
		r.name:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
		r.sub = text(r, "GameFontHighlightSmall", 10)
		r.sub:SetPoint("TOPLEFT", 26, -20)
		r.sub:SetPoint("RIGHT", 0, 0)
		r:EnableMouse(true)
		r:SetScript("OnEnter", function(self)
			W.showTip(self, W.tipOf(self, self.name, self.sub))
		end)
		r:SetScript("OnLeave", W.hideTip)
		return r
	end)
	function f:Set(stops, color, max, nowRight)
		W.start(self.rows)
		local n = math.min(#(stops or {}), max or 4)
		for i = 1, n do
			local s = stops[i]
			local r = W.take(self.rows)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", 0, -(i - 1) * 36)
			r.tip = s.tip
			r.disc:Set(s.n or i, s.state, color, s.confidence)
			local unsure = s.confidence and s.confidence ~= "confirmed"
			set(r.name, s.name, s.state == "done" and "ash" or "bone")
			local sub = s.sub or s.what
			if not s.sub and s.what then
				sub = s.what .. (s.cost and (", " .. s.cost) or "") .. (s.place and (". " .. s.place) or "")
			end
			set(r.sub, sub, unsure and "parch" or "ash")
			set(r.right, (s.state == "now" and nowRight) or s.leg or "", s.state == "now" and "bone" or "ash")
			r:Show()
		end
		W.finish(self.rows)
		self:SetHeight(math.max(1, n * 36))
		self:SetShown(n > 0)
		return n * 36
	end
	return f
end

-------------------------------------------------------------------------------------------------------------- scroll

-- No surface scrolls: nothing here makes a scroll bar, a slider that moves content, or a mouse-wheel handler, and
-- nothing clips rows it cannot otherwise show. Content that is longer than its box is split into pages at item
-- boundaries with a pager (Previous / Next and "1 to 8 of 21"); a page layout that has no pager and still does not
-- fit is counted in W.overflow, which the tests hold at zero.
W.overflow = { count = 0, last = nil }
local PAGER_H = 26

function W.noteOverflow(where, need, have)
	W.overflow.count = W.overflow.count + 1
	W.overflow.last = ("%s needs %d px, has %d"):format(tostring(where), math.ceil(need or 0), math.floor(have or 0))
end

-- "Previous  1 to 8 of 21  Next" at the bottom of `owner`. owner gives :Turn(delta).
local function pager(owner, w)
	local p = frame("Frame", nil, owner)
	p:SetSize(w, PAGER_H - 2)
	p:SetPoint("BOTTOMLEFT", 0, 0)
	p.rule = tex(p, "BORDER")
	p.rule:SetHeight(1)
	p.rule:SetPoint("TOPLEFT")
	p.rule:SetPoint("TOPRIGHT")
	fill(p.rule, "line")
	p.prev = W.button(p, 76, 20)
	p.prev:SetPoint("BOTTOMLEFT", 0, 0)
	p.next = W.button(p, 76, 20)
	p.next:SetPoint("BOTTOMRIGHT", 0, 0)
	p.label = text(p, "GameFontHighlightSmall", 11)
	p.label:SetPoint("LEFT", p.prev, "RIGHT", 6, 0)
	p.label:SetPoint("RIGHT", p.next, "LEFT", -6, 0)
	p.label:SetJustifyH("CENTER")
	p.prev.onClick = function()
		owner:Turn(-1)
	end
	p.next.onClick = function()
		owner:Turn(1)
	end
	function p:Set(page, pages, first, last, total, noun)
		-- what the page shown holds, kept for the selftest and the tests (every item is on exactly one page)
		self.first, self.last, self.total = first, last, total
		self:SetShown(pages > 1)
		if pages <= 1 then
			return
		end
		set(self.label, ("%d to %d of %d%s"):format(first, last, total, noun and (" " .. noun) or ""), "ash")
		W.setButton(self.prev, { id = "pagePrev", label = "Previous", enabled = page > 1 }, "quiet")
		W.setButton(self.next, { id = "pageNext", label = "Next", enabled = page < pages }, "quiet")
	end
	p:Hide()
	return p
end

-- An area of a fixed size for laid-out content. W.items pages into it; a page that draws its own layout calls
-- :SetContentHeight(total), and a total over the box is an overflow (counted, never scrolled).
function W.pages(parent, w, h, name)
	local s = frame("Frame", nil, parent)
	s:SetSize(w, h)
	s.w, s.h, s.page, s.pageCount, s.total, s.name = w, h, 1, 1, 0, name or "area"
	s.content = frame("Frame", nil, s)
	s.content:SetSize(w, h)
	s.content:SetPoint("TOPLEFT", 0, 0)
	s.pager = pager(s, w)
	function s:Turn(delta)
		local to = math.max(1, math.min(self.pageCount, self.page + delta))
		if to ~= self.page then
			self.page = to
			if self.redraw then
				self.redraw()
			end
		end
	end
	function s:SetContentHeight(total)
		self.total = total or 0
		if self.total > self.h + 0.5 then
			W.noteOverflow(self.name, self.total, self.h)
		end
	end
	return s
end

-- A list of rows that always fits: rows are laid top down and, when they are more than the box holds, split into
-- pages. spec = { make(list) -> row frame, draw(row, item, index), height(item) -> px (default spec.rowHeight),
-- noun = "spots" }. :Reveal(i) turns to the page that holds item i.
function W.list(parent, w, h, spec)
	local l = frame("Frame", nil, parent)
	l:SetSize(w, h)
	l.w, l.h, l.page, l.pageCount, l.items, l.pageOf, l.firstOf = w, h, 1, 1, {}, {}, { 1 }
	l.rows = W.pool(function()
		local r = spec.make(l)
		r:SetWidth(w)
		return r
	end)
	l.pager = pager(l, w)
	local function heightOf(it)
		return (spec.height and spec.height(it)) or spec.rowHeight or 22
	end
	-- pages for a box of `room` px; returns the page count. spec.keep(item) -> true keeps an item (a header) on
	-- the page of the item after it.
	local function paginate(self, room)
		local page, y = 1, 0
		self.pageOf, self.firstOf = {}, { 1 }
		for i, it in ipairs(self.items) do
			local ih = heightOf(it)
			local nxt = self.items[i + 1]
			local with = (spec.keep and nxt and spec.keep(it)) and heightOf(nxt) or 0
			if y > 0 and y + ih + with > room then
				page, y = page + 1, 0
				self.firstOf[page] = i
			end
			self.pageOf[i] = page
			y = y + ih
			if ih > room then
				W.noteOverflow("list row", ih, room)
			end
		end
		return page
	end
	function l:Refresh()
		W.start(self.rows)
		local y, first, last = 0, nil, 0
		for i, it in ipairs(self.items) do
			if self.pageOf[i] == self.page then
				local r = W.take(self.rows)
				local ih = heightOf(it)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", 0, -y)
				r:SetHeight(ih)
				spec.draw(r, it, i)
				r:Show()
				y = y + ih
				first, last = first or i, i
			end
		end
		W.finish(self.rows)
		self.pager:Set(self.page, self.pageCount, first or 0, last, #self.items, spec.noun)
	end
	function l:Turn(delta)
		local to = math.max(1, math.min(self.pageCount, self.page + delta))
		if to ~= self.page then
			self.page = to
			self:Refresh()
		end
	end
	function l:SetItems(items, keepPage)
		self.items = items or {}
		self.pageCount = paginate(self, self.h)
		if self.pageCount > 1 then
			self.pageCount = paginate(self, self.h - PAGER_H)
		end
		self.page = keepPage and math.max(1, math.min(self.page, self.pageCount)) or 1
		self:Refresh()
	end
	function l:Reveal(i)
		local page = self.pageOf[i]
		if page and page ~= self.page then
			self.page = page
			self:Refresh()
		end
	end
	-- A new box height (the room left under a card of varying height); call before SetItems.
	function l:SetBox(box)
		self.h = math.max(1, box)
		self:SetHeight(self.h)
	end
	-- every item is on exactly one page (the no-scroll spec reads this)
	function l:Unplaced()
		local n = 0
		for i = 1, #self.items do
			if not self.pageOf[i] then
				n = n + 1
			end
		end
		return n
	end
	return l
end

-- Hand-laid content that still pages: a page adds its pieces top down (frames, font strings, anything with
-- SetPoint and SetShown) and :Finish() splits them at piece boundaries over the pages of a W.pages area, with its
-- pager. :Add(obj, h, dx, keep) -> entry (keep: stay with the piece after it, for a header); :Gap(h) is space that
-- is dropped at the top of a page; :With(entry, obj) shows obj only with that entry (a button laid over a row).
function W.flow(area)
	local fl = { area = area, list = {}, gap = 0 }
	function fl:Add(obj, h, dx, keep)
		local e = { obj = obj, h = h, dx = dx or 0, keep = keep, gap = self.gap }
		self.gap = 0
		self.list[#self.list + 1] = e
		return e
	end
	function fl:Gap(h)
		self.gap = self.gap + (h or 8)
	end
	function fl:With(e, obj)
		e.with = e.with or {}
		e.with[#e.with + 1] = obj
	end
	local function pass(self, room)
		local page, y = 1, 0
		for i, e in ipairs(self.list) do
			local nxt = self.list[i + 1]
			local need = e.h + ((e.keep and nxt) and (nxt.gap + nxt.h) or 0)
			if y > 0 and y + e.gap + need > room then
				page, y = page + 1, 0
			end
			if y > 0 then
				y = y + e.gap
			end
			if e.h > room then
				W.noteOverflow(area.name, e.h, room)
			end
			e.page, e.y = page, y
			y = y + e.h
		end
		return page
	end
	function fl:Finish(noun)
		local count = pass(self, area.h)
		if count > 1 then
			count = pass(self, area.h - PAGER_H)
		end
		area.pageCount = count
		area.page = math.max(1, math.min(area.page or 1, count))
		local first, last = nil, 0
		for i, e in ipairs(self.list) do
			local on = e.page == area.page
			e.obj:ClearAllPoints()
			e.obj:SetPoint("TOPLEFT", area.content, "TOPLEFT", e.dx, -e.y)
			e.obj:SetShown(on)
			for _, o in ipairs(e.with or {}) do
				o:SetShown(on)
			end
			if on then
				first, last = first or i, i
			end
		end
		area.pager:Set(area.page, count, first or 0, last, #self.list, noun or "lines")
		return count
	end
	return fl
end

-- The window's close button: a quiet 22-px button with an X drawn from two 2-px lines turned 45 degrees (never a
-- glyph, which the font may lack).
function W.closeButton(parent)
	local b = W.button(parent, 22, 22)
	b.label:Hide()
	b.cross = {}
	for i = 1, 2 do
		local t = tex(b, "OVERLAY")
		t:SetSize(12, 2)
		t:SetPoint("CENTER", 0, 0)
		t:SetTexture(WHITE)
		t:SetRotation(i == 1 and math.pi / 4 or -math.pi / 4)
		t:SetVertexColor(rgb("ash"))
		b.cross[i] = t
	end
	b.tip = "Close (Escape)"
	return b
end

---------------------------------------------------------------------------------------------------------- item lists

-- Draws View list items ({ kind = "head"|"line"|"row"|"button"|"gap"|"check", ... }: V.shoppingItems,
-- V.altsItems, V.moreItems) on a W.pages area at the given width, paged at item boundaries. Returns the area's
-- height. Numbers sit right-aligned in one column; a row with an action carries its button at the far right.
function W.items(scroll, items, width)
	local c = scroll.content
	if not scroll.pools then
		scroll.pools = {
			fs = W.pool(function()
				return W.para(c, "GameFontHighlightSmall", 11, width)
			end),
			heads = W.pool(function()
				local b = W.rowButton(c, 24)
				b.arrow = tex(b, "ARTWORK")
				b.arrow:SetSize(10, 10)
				b.arrow:SetPoint("LEFT", 2, 0)
				b.arrow:SetTexture(ARROW)
				b.label = text(b, "GameFontNormalSmall", 11)
				b.label:SetPoint("LEFT", 16, 0)
				b.label:SetPoint("RIGHT", -4, 0)
				b.line = tex(b, "BORDER")
				b.line:SetHeight(1)
				b.line:SetPoint("BOTTOMLEFT")
				b.line:SetPoint("BOTTOMRIGHT")
				fill(b.line, "line")
				b.labels = { b.label }
				return b
			end),
			rows = W.pool(function()
				local r = frame("Frame", nil, c)
				r:SetHeight(22)
				r.mark = tex(r, "ARTWORK")
				r.mark:SetSize(3, 12)
				r.mark:SetPoint("LEFT", 4, 0)
				r.use = W.button(r, 64, 18)
				r.use:SetPoint("RIGHT", 0, 0)
				r.right = text(r, "GameFontHighlightSmall", 11)
				r.right:SetJustifyH("RIGHT")
				r.name = text(r, "GameFontHighlight", 12)
				r.name:SetPoint("LEFT", 14, 0)
				r.name:SetPoint("RIGHT", r.right, "LEFT", -8, 0)
				r.strike = tex(r, "OVERLAY")
				r.strike:SetHeight(1)
				r.strike:SetPoint("LEFT", r.name, "LEFT", 0, 0)
				r.strike:SetPoint("RIGHT", r.right, "RIGHT", 0, 0)
				r:EnableMouse(true)
				r:SetScript("OnEnter", function(self)
					W.showTip(self, W.tipOf(self, self.name, self.right))
				end)
				r:SetScript("OnLeave", W.hideTip)
				return r
			end),
			buttons = W.pool(function()
				return W.button(c, width, 22)
			end),
			checks = W.pool(function()
				return W.check(c, width)
			end),
		}
	end
	local p = scroll.pools
	scroll.redraw = function()
		W.items(scroll, items, width)
	end
	-- One pass lays every item out and hides those that are not on the page shown. `room` is the box, less the
	-- pager when a first pass found more than one page.
	local function pass(room)
		for _, pool in pairs(p) do
			W.start(pool)
		end
		local y, page, shown, first, last, n = 0, 1, scroll.page, nil, 0, 0
		-- puts obj (ih px high, x px in) at the cursor, on the next page when it does not fit; a head keeps the row
		-- that follows it
		local function put(obj, ih, x, isHead)
			n = n + 1
			if y > 0 and y + ih + (isHead and 24 or 0) > room then
				page, y = page + 1, 0
			end
			if ih > room then
				W.noteOverflow(scroll.name or "items", ih, room)
			end
			obj:ClearAllPoints()
			obj:SetPoint("TOPLEFT", x or 0, -y)
			obj:SetShown(page == shown)
			if page == shown then
				first, last = first or n, n
			end
			y = y + ih
		end
		for _, it in ipairs(items or {}) do
			if it.kind == "gap" then
				-- space between blocks, never at the top of a page
				if y > 0 then
					y = y + (it.h or 8)
				end
			elseif it.kind == "head" and it.action then
				local b = W.take(p.heads)
				b:SetWidth(width)
				b.action = it.action
				set(b.label, it.text, it.color or "gold")
				b.arrow:SetRotation(it.collapsed and 0 or -math.pi / 2)
				b.arrow:SetVertexColor(rgb(it.color or "gold"))
				put(b, 26, 0, true)
			elseif it.kind == "head" or it.kind == "line" then
				local fs = W.take(p.fs)
				fs:SetFontObject(it.kind == "head" and "GameFontNormalSmall" or "GameFontHighlightSmall")
				fs:SetFontHeight(it.size or 11)
				fs:SetWidth(width - (it.indent or 0))
				set(fs, it.text, it.color or (it.kind == "head" and "gold" or "ash"))
				put(fs, math.max(it.size or 11, fs:GetStringHeight() or 0) + 5, it.indent or 0, it.kind == "head")
			elseif it.kind == "row" then
				local r = W.take(p.rows)
				r:SetWidth(width)
				r.tip = it.tip
				fill(r.mark, it.mark or it.tone or "ash")
				r.right:ClearAllPoints()
				if it.action then
					W.setButton(
						r.use,
						it.action,
						it.action.id == "mailQueue" and "primary" or "quiet",
						it.tone or "gold"
					)
					r.use:SetWidth(math.max(64, (r.use.label:GetStringWidth() or 0) + 18))
					r.right:SetPoint("RIGHT", r.use, "LEFT", -8, 0)
				else
					r.use:Hide()
					r.right:SetPoint("RIGHT", -4, 0)
				end
				set(r.name, it.name, it.color or (it.tone == "green" and "ash") or "bone")
				set(r.right, it.right, it.tone or "bone")
				-- a covered row is green and struck through: the line is the second signal
				r.strike:SetShown(it.tone == "green" or it.covered == true)
				fill(r.strike, "green", 0.7)
				put(r, 22, 0)
			elseif it.kind == "check" then
				local ck = W.take(p.checks)
				ck:Set(it.text, it.on, it.action, it.tip)
				put(ck, 24, 0)
			elseif it.kind == "button" and it.action then
				local b = W.take(p.buttons)
				b:SetSize(math.min(width, 280), 22)
				W.setButton(b, it.action, it.quiet and "quiet" or nil, it.accent or "gold")
				if y > 0 then
					y = y + 4
				end
				put(b, 28, 0)
			end
		end
		for _, pool in pairs(p) do
			W.finish(pool)
		end
		return page, first or 0, last, n
	end
	local count, first, last, n = pass(scroll.h)
	if count > 1 then
		count = pass(scroll.h - PAGER_H)
		scroll.page = math.max(1, math.min(scroll.page, count))
		count, first, last, n = pass(scroll.h - PAGER_H)
	else
		scroll.page = 1
	end
	scroll.pageCount = count
	scroll.pager:Set(scroll.page, count, first, last, n, "lines")
	return scroll.h
end

----------------------------------------------------------------------------------------------------------- controls

-- A 14-px flat checkbox with its label; the whole row is the click target. The box is filled and holds a mark when
-- on, so the state does not rest on colour.
function W.check(parent, w)
	local c = W.rowButton(parent, 22)
	c:SetWidth(w)
	c.box = tex(c, "ARTWORK")
	c.box:SetSize(14, 14)
	c.box:SetPoint("LEFT", 2, 0)
	c.boxIn = tex(c, "ARTWORK", 1)
	c.boxIn:SetSize(12, 12)
	c.boxIn:SetPoint("CENTER", c.box, "CENTER")
	c.mark = tex(c, "ARTWORK", 2)
	c.mark:SetSize(6, 6)
	c.mark:SetPoint("CENTER", c.box, "CENTER")
	c.label = text(c, "GameFontHighlight", 12)
	c.label:SetPoint("LEFT", 24, 0)
	c.label:SetPoint("RIGHT", -4, 0)
	c.labels = { c.label }
	function c:Set(label, on, action, tip)
		self.action, self.tip = action, tip
		set(self.label, label, on and "bone" or "ash")
		fill(self.box, on and "gold" or "line")
		fill(self.boxIn, "ink")
		fill(self.mark, "gold", on and 1 or 0)
		self:Show()
	end
	return c
end

-- "Label ........ [value v]": a dropdown that opens a radio menu of options ({ label, value, checked, action }).
function W.dropdown(parent, w, bw)
	local c = frame("Frame", nil, parent)
	c:SetSize(w, 22)
	c.label = text(c, "GameFontHighlight", 12)
	c.label:SetPoint("LEFT", 2, 0)
	c.btn = W.button(c, bw or 104, 20)
	c.btn:SetPoint("RIGHT", 0, 0)
	c.label:SetPoint("RIGHT", c.btn, "LEFT", -8, 0)
	c.arrow = tex(c.btn, "OVERLAY")
	c.arrow:SetSize(10, 10)
	c.arrow:SetPoint("RIGHT", -5, 0)
	c.arrow:SetTexture(ARROW)
	c.arrow:SetRotation(-math.pi / 2)
	c.btn.onClick = function(self)
		local ok, why = W.menu(self, c.menu)
		if not ok then
			W.menuWhy = why
		end
	end
	function c:Set(label, value, menu, tip)
		self.menu = menu
		self.btn.tip = tip
		set(self.label, label, "bone")
		set(self.btn.label, value)
		self.btn.style = menu and "quiet" or "inert"
		paintButton(self.btn)
		self:Show()
	end
	return c
end

-- "Label ........ [-] value [+]". dec / inc are actions; a disabled one is inert.
function W.stepper(parent, w)
	local c = frame("Frame", nil, parent)
	c:SetSize(w, 22)
	c.inc = W.button(c, 22, 20)
	c.inc:SetPoint("RIGHT", 0, 0)
	c.value = text(c, "GameFontHighlightSmall", 11)
	c.value:SetWidth(64)
	c.value:SetPoint("RIGHT", c.inc, "LEFT", -4, 0)
	c.value:SetJustifyH("CENTER")
	c.dec = W.button(c, 22, 20)
	c.dec:SetPoint("RIGHT", c.value, "LEFT", -4, 0)
	c.label = text(c, "GameFontHighlight", 12)
	c.label:SetPoint("LEFT", 2, 0)
	c.label:SetPoint("RIGHT", c.dec, "LEFT", -8, 0)
	function c:Set(label, value, dec, inc, tip)
		set(self.label, label, "bone")
		set(self.value, value, "bone")
		W.setButton(self.dec, dec or { enabled = false }, "quiet")
		W.setButton(self.inc, inc or { enabled = false }, "quiet")
		set(self.dec.label, "-")
		set(self.inc.label, "+")
		self.dec.tip, self.inc.tip = tip, tip
		self:Show()
	end
	return c
end

-- A flat slider: a 2-px track with a 10 x 14 thumb. Dragging previews the value text; the action fires once, on
-- release, with the snapped value (fire(value)). The OnUpdate runs only while the button is down.
function W.slider(parent, w)
	local c = frame("Frame", nil, parent)
	c:SetSize(w, 38)
	c.label = text(c, "GameFontHighlight", 12)
	c.label:SetPoint("TOPLEFT", 2, -2)
	c.value = text(c, "GameFontHighlightSmall", 11)
	c.value:SetPoint("TOPRIGHT", 0, -2)
	c.value:SetJustifyH("RIGHT")
	c.hit = frame("Button", nil, c)
	c.hit:SetPoint("BOTTOMLEFT", 2, 2)
	c.hit:SetPoint("BOTTOMRIGHT", -2, 2)
	c.hit:SetHeight(16)
	c.track = tex(c.hit, "BACKGROUND")
	c.track:SetHeight(2)
	c.track:SetPoint("LEFT")
	c.track:SetPoint("RIGHT")
	fill(c.track, "line")
	c.fillTex = tex(c.hit, "BORDER")
	c.fillTex:SetHeight(2)
	c.fillTex:SetPoint("LEFT")
	fill(c.fillTex, "gold", 0.8)
	c.thumb = tex(c.hit, "ARTWORK")
	c.thumb:SetSize(10, 14)
	fill(c.thumb, "bone")
	c.min, c.max, c.step, c.cur = 0, 1, 1, 0
	function c:Snap(v)
		local step = self.step > 0 and self.step or 1
		v = self.min + math.floor((v - self.min) / step + 0.5) * step
		return math.max(self.min, math.min(self.max, v))
	end
	function c:Paint(v)
		local span = self.max - self.min
		local tw = (w - 4) - 10
		local x = span > 0 and (v - self.min) / span * tw or 0
		self.thumb:ClearAllPoints()
		self.thumb:SetPoint("LEFT", x, 0)
		self.fillTex:SetWidth(math.max(1, x))
		set(self.value, self.format and self.format(v) or v, "bone")
	end
	function c:FromCursor()
		local left, scale = self.hit:GetLeft(), self.hit:GetEffectiveScale()
		local cx = GetCursorPosition()
		if W.secret(cx) or not (left and cx and scale and scale > 0) then
			return self.cur
		end
		local frac = math.max(0, math.min(1, (cx / scale - left - 5) / math.max(1, (w - 4) - 10)))
		return self:Snap(self.min + frac * (self.max - self.min))
	end
	c.hit:SetScript("OnMouseDown", function(self)
		self:SetScript("OnUpdate", function()
			c.drag = c:FromCursor()
			c:Paint(c.drag)
		end)
	end)
	c.hit:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
		local v = c.drag or c:FromCursor()
		c.drag = nil
		if v ~= c.cur and c.fire then
			c.cur = v
			c.fire(v)
		end
	end)
	c.hit:SetScript("OnHide", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	c.hit:SetScript("OnEnter", function(self)
		W.showTip(self, c.tip)
	end)
	c.hit:SetScript("OnLeave", W.hideTip)
	function c:Set(label, value, min, max, step, format, fire, tip)
		self.min, self.max, self.step = min or 0, max or 100, step or 1
		self.format, self.fire, self.tip = format, fire, tip
		self.cur = self:Snap(tonumber(value) or self.min)
		set(self.label, label, "bone")
		self:Paint(self.cur)
		self:Show()
	end
	return c
end

-- A segmented control: buttons side by side, the chosen one selected. :Set({ { id, label, tip } }, chosen, fire).
function W.segments(parent, h)
	local s = frame("Frame", nil, parent)
	s:SetSize(10, h or 22)
	s.pool = W.pool(function()
		return W.button(s, 60, h or 22)
	end)
	function s:Set(options, chosen, fire)
		W.start(self.pool)
		local x = 0
		for _, o in ipairs(options or {}) do
			local b = W.take(self.pool)
			set(b.label, o.label)
			local bw = math.ceil((b.label:GetStringWidth() or 40) + 20)
			b:ClearAllPoints()
			b:SetPoint("LEFT", x, 0)
			b:SetSize(bw, h or 22)
			b.style, b.selected, b.tip = "quiet", o.id == chosen, o.tip
			b.onClick = function()
				fire(o.id, o)
			end
			-- the chosen segment keeps a filled ground as well as the bone edge
			paintButton(b)
			if b.selected then
				fill(b.bg, "line", 0.8)
			end
			b:Show()
			x = x + bw - 1
		end
		W.finish(self.pool)
		self:SetWidth(math.max(1, x + 1))
		self:Show()
		return x + 1
	end
	return s
end

-- An empty state: a title, a paragraph that names the broken link and what still works, and one optional action.
function W.empty(parent, w)
	local e = frame("Frame", nil, parent)
	e:SetSize(w, 80)
	e.title = text(e, "GameFontHighlight", 13)
	e.title:SetPoint("TOPLEFT", 0, 0)
	e.title:SetWidth(w)
	e.body = W.para(e, "GameFontHighlightSmall", 11, w)
	e.body:SetPoint("TOPLEFT", 0, -22)
	e.btn = W.button(e, 200, 24)
	e.labels = { e.title }
	function e:Set(empty)
		if not empty then
			self:Hide()
			return 0
		end
		if type(empty) == "string" then
			empty = { text = empty }
		end
		set(self.title, empty.title or "", "bone")
		set(self.body, empty.text or "", "ash")
		local top = empty.title and 22 or 0
		self.body:ClearAllPoints()
		self.body:SetPoint("TOPLEFT", 0, -top)
		local h = top + math.max(12, self.body:GetStringHeight() or 12)
		if empty.action then
			self.btn:ClearAllPoints()
			self.btn:SetPoint("TOPLEFT", 0, -h - 10)
			W.setButton(self.btn, empty.action, "quiet")
			self.btn:SetWidth(math.min(w, math.max(120, (self.btn.label:GetStringWidth() or 0) + 24)))
			h = h + 34
		else
			self.btn:Hide()
		end
		self:SetHeight(h)
		self:Show()
		return h
	end
	return e
end

-- A surface card: ink-on-surface ground with a 1-px line edge and an optional 3-px left rule.
function W.card(parent, w, h)
	local c = frame("Frame", nil, parent)
	c:SetSize(w, h)
	c.bg = tex(c, "BACKGROUND")
	c.bg:SetAllPoints()
	fill(c.bg, "surface")
	c.rule = tex(c, "BORDER")
	c.rule:SetWidth(3)
	c.rule:SetPoint("TOPLEFT")
	c.rule:SetPoint("BOTTOMLEFT")
	c.rule:Hide()
	function c:Rule(tone)
		self.rule:SetShown(tone ~= nil)
		if tone then
			fill(self.rule, tone)
		end
	end
	return c
end

-- A section header: gold 11 with a 1-px rule under it. Returns the FontString; h = 20.
function W.header(parent, w)
	local fs = text(parent, "GameFontNormalSmall", 11)
	fs:SetWidth(w)
	fs.line = tex(parent, "BORDER")
	fs.line:SetHeight(1)
	fs.line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
	fs.line:SetWidth(w)
	fill(fs.line, "line")
	local hide, show, setShown = fs.Hide, fs.Show, fs.SetShown
	function fs:SetShown(on)
		setShown(self, on)
		self.line:SetShown(on and true or false)
	end
	function fs:Hide()
		hide(self)
		self.line:Hide()
	end
	function fs:Show()
		show(self)
		self.line:Show()
	end
	return fs
end

function W.money(c)
	if c == nil or W.secret(c) then
		return "-"
	end
	return ns.Logic and ns.Logic.money and ns.Logic.money(c) or tostring(c)
end
