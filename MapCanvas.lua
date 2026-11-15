-- The map view: a clipped crop of the real zone map with pins, a loop route and a live player arrow. It draws a
-- `where` view-model (docs/ui.md); it never decides what to show. Three frames per view whatever the point count
-- (clip, canvas, top); everything else is pooled regions that only grow to the largest spot seen.
--
-- Magnification k = screen px per layer px. k <= 2: zone tiles. 2 < k <= 4: tiles, desaturated ("soft"). k > 4: no
-- tiles, a plain field with a north mark and a yard scale ("plan"). No art from the client, or a tile the client
-- refuses: a coordinate grid ("grid") or the plain field, and M.diag says which link broke.
local _, ns = ...
local W = ns.Widgets
local M = {}
ns.MapCanvas = M

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ARROW_ATLAS, ARROW_FILE = "MiniMap-QuestArrow", "Interface\\Minimap\\MinimapArrow"
local TICK = 0.1
local VIRTUAL = { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 }
local PIN_ATLAS = {
	flight = "TaxiNode_Neutral",
	entrance = "poi-door-arrow-up",
	cave = "CaveUnderground-Down",
	mailbox = "Mailbox",
	trainer = "Profession",
	vendor = "Repair",
	auction = "Auctioneer",
	inn = "Innkeeper",
	user = "Waypoint-MapPin-Tracked",
}
local COMPASS = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }

-- What broke and what was drawn, for the selftest (JournalUI.diag reads it).
M.diag = { draws = 0, skipped = 0, ticks = 0, tileFailures = 0, artMissing = {}, last = nil, lastWhy = nil }

local artCache, sizeCache = {}, {}

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

local function num(v)
	return type(v) == "number" and not secret(v)
end

local function xy(p)
	if type(p) ~= "table" then
		return nil
	end
	local x, y = p.x or p[1], p.y or p[2]
	if num(x) and num(y) then
		return x, y
	end
	return nil
end

------------------------------------------------------------------------------------------------------- pure helpers

function M.modeFor(k)
	if not num(k) or k > 4 then
		return "plan"
	end
	return k <= 2 and "map" or "soft"
end

-- The 1 / 2 / 5 x 10^n yard value whose bar is 80 to 140 px long (else the nearest to 110). -> yards, px.
function M.scaleBar(pxPerYd)
	if not num(pxPerYd) or pxPerYd <= 0 then
		return nil
	end
	local best, bestPx
	for e = 0, 4 do
		for _, m in ipairs({ 1, 2, 5 }) do
			local yd = m * 10 ^ e
			local px = yd * pxPerYd
			if px >= 80 and px <= 140 then
				return yd, px
			end
			if not best or math.abs(px - 110) < math.abs(bestPx - 110) then
				best, bestPx = yd, px
			end
		end
	end
	return best, bestPx
end

-- Bearing in radians clockwise from north (map y grows south) as one of eight words.
function M.compass(bearing)
	if not num(bearing) then
		return nil
	end
	local i = math.floor((bearing % (2 * math.pi)) / (math.pi / 4) + 0.5) % 8
	return COMPASS[i + 1]
end

-- The art of a map: layer metrics and row-major tile fileIDs, as Blizzard_MapCanvasDetailLayer.lua:51-67 reads
-- them. nil and the broken link when the client gives none. Cached per map, failures too.
function M.art(map)
	if not num(map) then
		return nil, "no map id on this place"
	end
	local c = artCache[map]
	if c ~= nil then
		return c.L, c.textures, c.why
	end
	local why, L, textures
	if not (C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then
		why = "C_Map.GetMapArtLayers is absent on this client"
	else
		local ok, layers = pcall(C_Map.GetMapArtLayers, map)
		if not ok then
			why = ("C_Map.GetMapArtLayers failed for map %d: %s"):format(map, tostring(layers))
		elseif type(layers) ~= "table" or secret(layers) or type(layers[1]) ~= "table" then
			why = ("C_Map.GetMapArtLayers gave nothing for map %d"):format(map)
		else
			L = layers[1]
			if
				not (num(L.layerWidth) and num(L.layerHeight) and num(L.tileWidth) and num(L.tileHeight))
				or L.tileWidth <= 0
			then
				L, why = nil, ("C_Map.GetMapArtLayers gave no layer size for map %d"):format(map)
			else
				local okT, tx = pcall(C_Map.GetMapArtLayerTextures, map, 1)
				if not okT or type(tx) ~= "table" or secret(tx) or #tx == 0 then
					L, why = nil, ("C_Map.GetMapArtLayerTextures gave no tiles for map %d"):format(map)
				else
					textures = tx
				end
			end
		end
	end
	artCache[map] = { L = L, textures = textures, why = why }
	if why then
		M.diag.artMissing[map] = why
		M.diag.lastWhy = why
	end
	return L, textures, why
end

-- A tile the client refused: the map draws without art from now on.
function M.refuse(map, why)
	artCache[map] = { why = why }
	M.diag.artMissing[map] = why
	M.diag.lastWhy = why
	M.diag.tileFailures = M.diag.tileFailures + 1
end

function M.forget()
	artCache, sizeCache = {}, {}
end

-- Yards across and down a map (C_Map.GetMapWorldSize), or nil and why.
function M.worldSize(map)
	if not num(map) then
		return nil, nil, "no map id"
	end
	local c = sizeCache[map]
	if c == nil then
		local ok, w, h = pcall(function()
			return C_Map.GetMapWorldSize(map)
		end)
		if ok and num(w) and num(h) and w > 0 and h > 0 then
			c = { w, h }
		else
			c = { why = ("C_Map.GetMapWorldSize gave nothing for map %s"):format(tostring(map)) }
		end
		sizeCache[map] = c
	end
	return c[1], c[2], c.why
end

-- The crop of a where model for a mode: { cx, cy, span } (span = fraction of the layer width shown). The model's
-- own view wins; else the bounding box of what the mode shows, padded (15% loop, 12% travel).
function M.viewOf(where, mode, w, h, L)
	L = L or VIRTUAL
	local v = where.views and where.views[mode]
	if type(v) == "table" then
		local cx, cy, span = v.cx or v[1], v.cy or v[2], v.span or v[3]
		if num(cx) and num(cy) and num(span) and span > 0 then
			return { cx = cx, cy = cy, span = span }
		end
	end
	local x1, y1, x2, y2
	local function add(p)
		local x, y = xy(p)
		if x then
			x1, y1 = math.min(x1 or x, x), math.min(y1 or y, y)
			x2, y2 = math.max(x2 or x, x), math.max(y2 or y, y)
		end
	end
	if mode == "spot" and where.route and where.route.pts then
		for _, p in ipairs(where.route.pts) do
			add(p)
		end
	else
		for _, p in ipairs(where.pins or {}) do
			add(p)
		end
		for _, p in ipairs(where.stops or {}) do
			add(p)
		end
		for _, p in ipairs(where.leadIn and where.leadIn.points or {}) do
			add(p)
		end
	end
	local a = where.area
	if a and a.shape ~= "poly" and num(a.x) and num(a.y) then
		local r = num(a.r) and a.r or 0.01
		add({ a.x - r, a.y - r })
		add({ a.x + r, a.y + r })
	end
	for _, p in ipairs(a and a.points or {}) do
		add(p)
	end
	if not x1 then
		return { cx = 0.5, cy = 0.5, span = 1 }
	end
	local pad = mode == "spot" and 1.3 or 1.24
	local bw, bh = (x2 - x1) * pad, (y2 - y1) * pad
	local span = math.max(bw, bh * (L.layerHeight / L.layerWidth) * (w / h), 0.02)
	return { cx = (x1 + x2) / 2, cy = (y1 + y2) / 2, span = math.min(span, 1.2) }
end

-- Screen geometry of a crop: k and the layer's top-left on the clip (sx = ox + x * layerWidth * k).
function M.layout(L, view, w, h)
	local k = w / (view.span * L.layerWidth)
	return k, w / 2 - view.cx * L.layerWidth * k, h / 2 - view.cy * L.layerHeight * k
end

-- The tiles that intersect the clip: { { col, row, index, x, y, w, h } }, index row-major.
function M.tiles(L, k, ox, oy, w, h)
	local cols = math.ceil(L.layerWidth / L.tileWidth)
	local rows = math.ceil(L.layerHeight / L.tileHeight)
	local tw, th = L.tileWidth * k, L.tileHeight * k
	local out = {}
	for row = 1, rows do
		for col = 1, cols do
			local x, y = ox + (col - 1) * tw, oy + (row - 1) * th
			if x < w and x + tw > 0 and y < h and y + th > 0 then
				out[#out + 1] = { col = col, row = row, index = (row - 1) * cols + col, x = x, y = y, w = tw, h = th }
			end
		end
	end
	return out
end

-- The player on `map`: { x, y, facing, onMap }, or nil and why ("not now": instance, secret, no map).
function M.position(map)
	local okInst, inInstance = pcall(IsInInstance)
	if okInst and not secret(inInstance) and inInstance then
		return nil, "in an instance"
	end
	if not (C_Map and C_Map.GetPlayerMapPosition) then
		return nil, "C_Map.GetPlayerMapPosition is absent"
	end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
	if not ok then
		return nil, "C_Map.GetPlayerMapPosition failed: " .. tostring(pos)
	end
	if secret(pos) then
		return nil, "position is secret here"
	end
	if pos == nil then
		return { onMap = false }, "not on this map"
	end
	local x, y = pos:GetXY()
	if not (num(x) and num(y)) then
		return nil, "position is secret here"
	end
	local f = GetPlayerFacing and GetPlayerFacing()
	return { x = x, y = y, facing = num(f) and f or nil, onMap = x >= 0 and x <= 1 and y >= 0 and y <= 1 }
end

-- Yards and bearing (clockwise from north) between two map positions; nil and why without the map's size.
function M.between(map, x1, y1, x2, y2)
	local ww, wh, why = M.worldSize(map)
	if not ww then
		return nil, nil, why
	end
	local dx, dy = (x2 - x1) * ww, (y2 - y1) * wh
	return math.sqrt(dx * dx + dy * dy), math.atan2(dx, -dy) % (2 * math.pi)
end

-- The numbered stops of a loop at the current skill: grey and locked types are left out of the tour.
function M.tour(route)
	local stops, skipped = {}, {}
	local function add(i, p, out)
		local t = route.types and route.types[p.pk]
		local band = p.band or (t and t.band) or "green"
		if not xy(p) then
			M.diag.badPoints = (M.diag.badPoints or 0) + 1 -- a point without a position is left out, and counted
		elseif out or band == "grey" or band == "locked" then
			skipped[#skipped + 1] = { i = i, p = p, band = band == "locked" and "locked" or "grey", type = t }
		else
			stops[#stops + 1] = { i = i, n = #stops + 1, p = p, band = band, type = t }
		end
	end
	for i, p in ipairs(route and route.pts or {}) do
		add(i, p, false)
	end
	-- Where.route hands the points it took off the tour separately
	for i, p in ipairs(route and route.skipped or {}) do
		add(i, p, true)
	end
	return stops, skipped
end

-- At most 8 hull points of a point set: the extremes in eight directions, in order round the shape.
function M.hull(pts)
	local dirs = { { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 } }
	local out, seen = {}, {}
	for _, d in ipairs(dirs) do
		local best, bestV
		for i, p in ipairs(pts) do
			local x, y = xy(p)
			if x then
				local v = x * d[1] + y * d[2]
				if not bestV or v > bestV then
					best, bestV = i, v
				end
			end
		end
		if best and not seen[best] then
			seen[best] = true
			out[#out + 1] = pts[best]
		end
	end
	return out
end

------------------------------------------------------------------------------------------------------------ the view

local Map = {}
Map.__index = Map

-- opts: journal (numbered discs for every stop, north mark and scale in every mode, mode and floor controls),
-- header ("full" | "none"), onClick(map, button, pin), onLive(where, live) -> strings | nil,
-- skipClassic (ignored: confidence comes from the model).
function M.new(parent, w, h, opts)
	local self = setmetatable({}, Map)
	self.w, self.h, self.opts = w, h, opts or {}
	self.live, self.hits, self.wanted = {}, {}, "auto"
	local clip = W.frame("Frame", nil, parent)
	clip:SetSize(w, h)
	clip:SetClipsChildren(true)
	clip:EnableMouse(true)
	local canvas = W.frame("Frame", nil, clip)
	canvas:SetAllPoints(clip)
	local top = W.frame("Frame", nil, clip)
	top:SetAllPoints(clip)
	top:SetFrameLevel((canvas:GetFrameLevel() or 1) + 2)
	self.frame, self.clip, self.canvas, self.top = clip, clip, canvas, top

	self.ground = W.tex(canvas, "BACKGROUND", -8)
	self.ground:SetAllPoints(clip)
	self.dim = W.tex(canvas, "BACKGROUND", 7)
	self.dim:SetAllPoints(clip)
	self.pools = {
		tiles = W.pool(function()
			return W.tex(canvas, "BACKGROUND", -7)
		end),
		lines = W.pool(function()
			W.stats.regions = W.stats.regions + 1
			return canvas:CreateLine(nil, "ARTWORK", nil, 0)
		end),
		dashes = W.pool(function()
			W.stats.regions = W.stats.regions + 1
			return canvas:CreateLine(nil, "ARTWORK", nil, 0)
		end),
		chevs = W.pool(function()
			local t = W.tex(canvas, "ARTWORK", 1)
			t:SetTexture(W.ARROW)
			return t
		end),
		discs = W.pool(function()
			return W.disc(canvas, 10, "ARTWORK", 2)
		end),
		quads = W.pool(function()
			return W.tex(canvas, "ARTWORK", 2)
		end),
		icons = W.pool(function()
			return W.tex(canvas, "ARTWORK", 3)
		end),
		nums = W.pool(function()
			local fs = W.text(canvas, "GameFontHighlightSmall", 10, "OVERLAY")
			fs:SetJustifyH("CENTER")
			return fs
		end),
	}
	-- live marks: moved by the tick, never rebuilt
	self.bearing = canvas:CreateLine(nil, "ARTWORK", nil, 4)
	self.bearing:SetThickness(1)
	self.bearing:Hide()
	self.arrow = W.tex(canvas, "OVERLAY", 7)
	self.arrow:SetSize(16, 16)
	if not W.atlas(self.arrow, ARROW_ATLAS, ARROW_FILE) then
		M.diag.arrow = "atlas MiniMap-QuestArrow missing, file arrow used"
	end
	self.arrow:SetDesaturated(true)
	self.arrow:SetVertexColor(W.rgb("bone"))
	self.arrow:Hide()
	W.stats.regions = W.stats.regions + 1

	-- the header, on `top` so it does not move with the crop
	self.scrim = W.tex(top, "BACKGROUND")
	self.scrim:SetPoint("BOTTOMLEFT")
	self.scrim:SetPoint("BOTTOMRIGHT")
	self.scrim:SetHeight(44)
	self.scrim:SetTexture(WHITE)
	local r, g, b = W.rgb("ink")
	local okGrad = CreateColor
		and pcall(self.scrim.SetGradient, self.scrim, "VERTICAL", CreateColor(r, g, b, 0.92), CreateColor(r, g, b, 0))
	if not okGrad then
		self.scrim:SetColorTexture(r, g, b, 0.6)
		M.diag.scrim = "SetGradient refused: flat scrim"
	end
	self.title = W.text(top, "GameFontHighlight", 13)
	self.title:SetPoint("BOTTOMLEFT", 8, 20)
	self.sub = W.text(top, "GameFontHighlightSmall", 10)
	self.sub:SetPoint("BOTTOMLEFT", 8, 7)
	self.mobs = W.chip(top)
	self.mobs:SetPoint("BOTTOMRIGHT", -8, 8)
	self.title:SetPoint("RIGHT", self.mobs, "LEFT", -8, 0)
	self.sub:SetPoint("RIGHT", self.mobs, "LEFT", -8, 0)
	self.dist = W.chip(top)
	self.dist:SetPoint("TOPRIGHT", -8, -8)
	self.tag = W.chip(top)
	self.note = W.para(top, "GameFontHighlightSmall", 10, w - 24)
	self.note:SetJustifyH("CENTER")
	self.note:SetPoint("CENTER", 0, 0)
	self.north = W.tex(top, "ARTWORK")
	self.north:SetSize(10, 10)
	self.north:SetTexture(W.ARROW)
	self.north:SetRotation(math.pi / 2)
	self.northN = W.text(top, "GameFontHighlightSmall", 10)
	self.northN:SetJustifyH("CENTER")
	self.scale = { W.tex(top, "ARTWORK"), W.tex(top, "ARTWORK"), W.tex(top, "ARTWORK") }
	self.scaleText = W.text(top, "GameFontHighlightSmall", 10)
	self.scaleText:SetJustifyH("RIGHT")
	if self.opts.journal then
		self.modes = W.segments(top, 22)
		self.modes:SetPoint("TOPLEFT", 8, -8)
		self.floors = W.segments(top, 22)
	end

	clip:SetScript("OnEnter", function()
		self.over = true
	end)
	clip:SetScript("OnLeave", function()
		self.over = false
		W.hideTip(clip)
		self.tipOn = nil
	end)
	clip:SetScript("OnMouseUp", function(_, button)
		if self.opts.onClick then
			self.opts.onClick(self, button, self:Nearest())
		end
	end)
	-- No mouse wheel anywhere in the addon: the two-segment control on the journal's map switches the view.
	-- One throttled OnUpdate per view. It does not run while the view (or any parent) is hidden: no work then.
	self.acc = 0
	clip:SetScript("OnUpdate", function(_, elapsed)
		self.acc = self.acc + (elapsed or 0)
		if self.acc >= TICK then
			self.acc = 0
			self:Tick()
			if self.over then
				self:Hover()
			end
		end
	end)
	return self
end

function Map:SetPoint(...)
	self.frame:SetPoint(...)
end

function Map:Hide()
	self.frame:Hide()
end

function Map:Show()
	self.frame:Show()
end

function Map:SetShown(on)
	self.frame:SetShown(on and true or false)
end

-- "auto" follows the player (travel far, spot near); "travel" / "spot" is the user's choice until the spot changes.
function Map:SetMode(mode)
	self.wanted = mode or "auto"
	if mode == "travel" or mode == "spot" then
		self.mode = mode
	end
	self:Draw(true)
	if self.opts.onMode then
		self.opts.onMode(self, self.wanted, self.mode)
	end
end

function Map:SetFloor(id)
	self.floorWanted = id
	self:Draw(true)
end

-- Screen position on the clip of a map position.
function Map:XY(x, y)
	return self.ox + x * self.lw * self.k, self.oy + y * self.lh * self.k
end

function Map:Vis(x, y, m)
	m = m or 12
	return x > -m and x < self.w + m and y > -m and y < self.h + m
end

function Map:Quad(x, y, wd, ht, tone, alpha, sub, rot, layer)
	local t = W.take(self.pools.quads)
	t:ClearAllPoints()
	t:SetPoint("CENTER", self.canvas, "TOPLEFT", x, -y)
	t:SetSize(wd, ht)
	t:SetDrawLayer(layer or "ARTWORK", sub or 2)
	local r, g, b = W.rgb(tone)
	t:SetColorTexture(r, g, b, alpha or 1)
	t:SetRotation(rot or 0)
	t:Show()
	return t
end

function Map:Disc(x, y, size, tone, alpha, sub, layer)
	local t = W.take(self.pools.discs)
	t:ClearAllPoints()
	t:SetPoint("CENTER", self.canvas, "TOPLEFT", x, -y)
	t:SetSize(size, size)
	t:SetDrawLayer(layer or "ARTWORK", sub or 2)
	local r, g, b = W.rgb(tone)
	t:SetVertexColor(r, g, b, alpha or 1)
	t:Show()
	return t
end

function Map:Line(x1, y1, x2, y2, tone, alpha, thick, sub, pool)
	-- a segment wholly off one side of the crop is not drawn
	if (x1 < 0 and x2 < 0) or (y1 < 0 and y2 < 0) or (x1 > self.w and x2 > self.w) or (y1 > self.h and y2 > self.h) then
		return
	end
	local l = W.take(pool or self.pools.lines)
	l:SetStartPoint("TOPLEFT", self.canvas, x1, -y1)
	l:SetEndPoint("TOPLEFT", self.canvas, x2, -y2)
	l:SetThickness(thick or 2)
	l:SetDrawLayer("ARTWORK", sub or 0)
	local r, g, b = W.rgb(tone)
	l:SetColorTexture(r, g, b, alpha or 1)
	l:Show()
	return l
end

-- 5 px on, 4 off, each dash a Line; at most 48 dashes per view, beyond that one solid line at alpha .5.
function Map:Dashed(x1, y1, x2, y2, tone, alpha, thick)
	local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local n = math.floor(len / 9)
	if n < 1 then
		return self:Line(x1, y1, x2, y2, tone, alpha, thick)
	end
	if self.dashLeft < n then
		self.dashOver = (self.dashOver or 0) + 1
		return self:Line(x1, y1, x2, y2, tone, 0.5 * (alpha or 1), thick)
	end
	local ux, uy = (x2 - x1) / len, (y2 - y1) / len
	for i = 0, n - 1 do
		local a, b = i * 9, math.min(len, i * 9 + 5)
		if self:Line(x1 + ux * a, y1 + uy * a, x1 + ux * b, y1 + uy * b, tone, alpha, thick, 0, self.pools.dashes) then
			self.dashLeft = self.dashLeft - 1
		end
	end
end

function Map:Chevron(x1, y1, x2, y2, tone, alpha)
	local dx, dy = x2 - x1, y2 - y1
	if dx * dx + dy * dy < 1600 then
		return
	end
	local mx, my = (x1 + x2) / 2, (y1 + y2) / 2
	if not self:Vis(mx, my, 0) then
		return
	end
	local t = W.take(self.pools.chevs)
	t:ClearAllPoints()
	t:SetPoint("CENTER", self.canvas, "TOPLEFT", mx, -my)
	t:SetSize(10, 10)
	t:SetRotation(math.atan2(-dy, dx))
	local r, g, b = W.rgb(tone or "bone")
	t:SetVertexColor(r, g, b, alpha or 0.9)
	t:Show()
end

function Map:Num(x, y, s, tone, size, alpha, point)
	local fs = W.take(self.pools.nums)
	fs:SetFontHeight(size or 10)
	fs:ClearAllPoints()
	fs:SetPoint(point or "CENTER", self.canvas, "TOPLEFT", x, -y)
	W.set(fs, s, tone or "bone", alpha)
	fs:Show()
	return fs
end

function Map:Icon(x, y, size, atlas)
	if not W.hasAtlas(atlas) then
		return false
	end
	local t = W.take(self.pools.icons)
	t:ClearAllPoints()
	t:SetPoint("CENTER", self.canvas, "TOPLEFT", x, -y)
	t:SetSize(size, size)
	t:SetAtlas(atlas)
	t:Show()
	return true
end

function Map:Hit(x, y, tip, pin)
	self.hits[#self.hits + 1] = { x = x, y = y, tip = tip, pin = pin }
end

-- A numbered disc in the pin states (now, todo, done, other floor, unconfirmed).
function Map:Stop(x, y, n, o)
	local size = o.size or 16
	local tone = o.tone or "bone"
	local unsure = o.confidence and o.confidence ~= "confirmed"
	local a = o.alpha or 1
	if o.ring then
		self:Disc(x, y, size + 18, o.ring, 1, 0)
		self:Disc(x, y, size + 14, self.groundTone, 1, 1)
	end
	if o.hollow or unsure or o.state == "todo" then
		self:Disc(x, y, size, unsure and "parch" or tone, a * (o.hollow and 0.7 or 1), 2)
		self:Disc(x, y, size - 2, self.groundTone, 1, 3)
		if n then
			self:Num(x, y, n, unsure and "parch" or tone, o.font, a)
		end
	elseif o.state == "done" then
		self:Disc(x, y, size, "green", a, 2)
		self:Num(x, y, "v", "ink", o.font, a)
	else
		self:Disc(x, y, size, tone, a, 2)
		if n then
			self:Num(x, y, n, "ink", o.font, a)
		end
	end
	if o.visited then
		self:Disc(x + size / 2, y - size / 2, 10, "green", 1, 4)
	end
end

function Map:Diamond(x, y, size, tone, alpha, hollow)
	self:Quad(x, y, size, size, tone, alpha, 2, math.pi / 4)
	if hollow then
		self:Quad(x, y, size - 2, size - 2, self.groundTone, 1, 3, math.pi / 4)
	end
end

-- Sets the view-model. force: redraw even if the signature did not change.
function Map:Set(where, o)
	o = o or {}
	local key = where and where.key
	if key ~= self.key then
		-- a new place resets the user's mode, the floor and the live state
		self.key, self.wanted, self.floorWanted = key, o.mode or "auto", nil
		self.mode = nil
		self.live = {}
	elseif o.mode then
		self.wanted = o.mode
	end
	self.where = where
	if self.wanted == "travel" or self.wanted == "spot" then
		self.mode = self.wanted
	end
	self:Draw(o.force ~= false)
	self:Tick()
end

function Map:Signature()
	local w, l = self.where, self.live
	if not w then
		return "nil"
	end
	local v = {}
	for i, t in pairs(l.visited or {}) do
		if t then
			v[#v + 1] = tostring(i)
		end
	end
	table.sort(v)
	return table.concat({
		tostring(w),
		tostring(w.key),
		tostring(self.mode),
		tostring(self.floorWanted or l.floor),
		tostring(l.nextIndex),
		tostring(self.w),
		table.concat(v, ","),
	}, "|")
end

function Map:Draw(force)
	local sig = self:Signature()
	if not force and sig == self.sig then
		M.diag.skipped = M.diag.skipped + 1
		return
	end
	self.sig = sig
	M.diag.draws = M.diag.draws + 1
	local where, p = self.where, self.pools
	for _, pool in pairs(p) do
		W.start(pool)
	end
	self.hits = {}
	self.dashLeft, self.dashOver = 48, nil
	self.target, self.center = nil, nil
	local journal = self.opts.journal
	local function done()
		for _, pool in pairs(p) do
			W.finish(pool)
		end
	end

	if not where or where.empty then
		-- nothing to place: a quiet field that says so; the card under it carries the full explanation
		W.fill(self.ground, "field")
		self.dim:Hide()
		self.groundTone, self.mapMode = "field", "none"
		self:Header(nil)
		W.set(
			self.note,
			(where and where.empty and (where.empty.title or where.empty.text))
				or self.opts.emptyText
				or "No place to show for this step.",
			"ash"
		)
		self.note:Show()
		self.arrow:Hide()
		self.bearing:Hide()
		done()
		return
	end
	self.note:Hide()

	local L, textures, artWhy = M.art(where.map)
	local hasArt = L ~= nil
	L = L or VIRTUAL
	self.lw, self.lh = L.layerWidth, L.layerHeight
	local mode = self.mode
	if mode ~= "travel" and mode ~= "spot" then
		mode = (self.live.mode == "spot" and "spot") or "travel"
	end
	if mode == "spot" and not (where.route or (where.views and where.views.spot)) then
		mode = "travel"
	end
	self.mode = mode
	local view = M.viewOf(where, mode, self.w, self.h, L)
	self.k, self.ox, self.oy = M.layout(L, view, self.w, self.h)
	local mapMode = hasArt and M.modeFor(self.k) or "grid"
	self.artWhy = artWhy

	-- ground: tiles, the plain field, or the coordinate grid
	if mapMode == "map" or mapMode == "soft" then
		local soft = mapMode == "soft"
		for _, t in ipairs(M.tiles(L, self.k, self.ox, self.oy, self.w, self.h)) do
			local tile = W.take(p.tiles)
			local id = textures[t.index]
			local ok = id ~= nil and pcall(tile.SetTexture, tile, id, nil, nil, "TRILINEAR")
			if not ok or (tile.GetTexture and tile:GetTexture() == nil) then
				-- the broken link: this client will not give addon code this tile. No art for this map from now on.
				M.refuse(
					where.map,
					("Texture:SetTexture refused tile %d of map %s (fileID %s)"):format(
						t.index,
						tostring(where.map),
						tostring(id)
					)
				)
				self.artWhy = M.diag.lastWhy
				mapMode = "plan"
				W.start(p.tiles)
				break
			end
			tile:ClearAllPoints()
			tile:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", t.x, -t.y)
			tile:SetSize(t.w, t.h)
			tile:SetDesaturation(soft and 0.7 or 0.35)
			tile:SetVertexColor(0.85, 0.85, 0.85)
			tile:Show()
		end
	end
	if mapMode == "map" or mapMode == "soft" then
		W.fill(self.ground, "ink")
		W.fill(self.dim, "ink", mapMode == "soft" and 0.5 or 0.28)
		self.dim:Show()
		self.groundTone = "ink"
	elseif mapMode == "grid" then
		W.fill(self.ground, "ink")
		W.fill(self.dim, "parch", 0.1)
		self.dim:Show()
		self.groundTone = "ink"
		self:Grid()
	else
		W.fill(self.ground, "field")
		self.dim:Hide()
		self.groundTone = "field"
	end
	self.mapMode = mapMode

	local color = where.color or "bone"
	local unsure = where.confidence and where.confidence ~= "confirmed"

	-- area: disc at .14 with a 24-segment outline, every other segment hidden when the place is not confirmed
	local a = where.area
	if a and a.shape ~= "poly" and num(a.x) and num(a.y) and num(a.r) then
		local cx, cy = self:XY(a.x, a.y)
		local rx, ry = a.r * self.lw * self.k, a.r * self.lw * self.k
		self.center = { a.x, a.y }
		if mode == "travel" or not where.route then
			self:Disc(cx, cy, rx * 2, color, 0.14, -1, "BORDER")
			for i = 0, 23 do
				if not unsure or i % 2 == 0 then
					local a1, a2 = i / 24 * 2 * math.pi, (i + 1) / 24 * 2 * math.pi
					self:Line(
						cx + math.cos(a1) * rx,
						cy + math.sin(a1) * ry,
						cx + math.cos(a2) * rx,
						cy + math.sin(a2) * ry,
						unsure and "parch" or color,
						0.8,
						1
					)
				end
			end
		end
	elseif a and a.points then
		local n = #a.points
		for i = 1, n do
			local x1, y1 = xy(a.points[i])
			local x2, y2 = xy(a.points[i % n + 1])
			if x1 and x2 and (not unsure or i % 2 == 1) then
				local sx1, sy1 = self:XY(x1, y1)
				local sx2, sy2 = self:XY(x2, y2)
				self:Line(sx1, sy1, sx2, sy2, unsure and "parch" or color, 0.8, 1)
			end
		end
	end

	local route = where.route
	local stops, skipped = M.tour(route)
	self.stops = stops
	if route and mode == "spot" and where.confidence ~= "approx" then
		self:Loop(route, stops, skipped, color)
	elseif route and #stops > 2 then
		-- travel mode: the loop is only its hull, so the eye lands on it
		local hull = M.hull(route.pts)
		for i = 1, #hull do
			local x1, y1 = self:XY(xy(hull[i]))
			local x2, y2 = self:XY(xy(hull[i % #hull + 1]))
			self:Line(x1, y1, x2, y2, color, 0.5, 1)
		end
		local x, y = xy(route.pts[stops[1].i])
		self.target = self.target or { x, y }
	end

	-- the lead-in (flight point to entrance), dashed
	local lead = where.leadIn and where.leadIn.points
	if lead and mode == "travel" then
		for i = 1, #lead - 1 do
			local x1, y1 = xy(lead[i])
			local x2, y2 = xy(lead[i + 1])
			if x1 and x2 then
				local sx1, sy1 = self:XY(x1, y1)
				local sx2, sy2 = self:XY(x2, y2)
				self:Dashed(sx1, sy1, sx2, sy2, "bone", 0.85, 2)
			end
		end
	end

	-- errand stops: numbered pins joined in order; the leg to the current stop at .85, later legs at .5
	if where.stops then
		local prev, current
		for _, s in ipairs(where.stops) do
			local x, y = xy(s)
			if x then
				local sx, sy = self:XY(x, y)
				if prev then
					self:Dashed(prev[1], prev[2], sx, sy, "bone", current and 0.5 or 0.85, 2)
				end
				prev = { sx, sy }
				if s.state == "now" or (not current and s.state ~= "done") then
					current = current or s
				end
				if self:Vis(sx, sy) then
					self:Stop(sx, sy, s.n, {
						state = s.state,
						tone = color,
						confidence = s.confidence,
						size = 16,
						ring = s == current and color or nil,
					})
					self:Hit(sx, sy, s.tip or s.name, s)
				end
			end
		end
		if current then
			self.target = { xy(current) }
		end
	end

	-- pins of the model (flight point, entrance, mailbox, stairs, extra stops)
	for _, pin in ipairs(where.pins or {}) do
		local x, y = xy(pin)
		if x then
			local sx, sy = self:XY(x, y)
			if self:Vis(sx, sy) then
				local pinUnsure = pin.confidence and pin.confidence ~= "confirmed"
				if pin.kind == "stop" then
					self:Stop(sx, sy, pin.n, { state = pin.state, tone = color, confidence = pin.confidence })
				elseif pin.kind == "stairs" then
					self:Stairs(sx, sy, pin.up ~= false)
				else
					local atlas = PIN_ATLAS[pin.kind]
					if pin.kind == "flight" and pin.faction then
						atlas = "TaxiNode_" .. pin.faction
					end
					if pinUnsure or not self:Icon(sx, sy, 12, atlas) then
						-- no atlas on this client, or a place not yet seen in Forever: the drawn shape
						local tone = pinUnsure and "parch"
							or (pin.faction == "Horde" and "horde")
							or (pin.faction == "Alliance" and "alliance")
							or "bone"
						self:Disc(sx, sy, 10, tone, 1, 2)
						if pinUnsure then
							self:Disc(sx, sy, 8, self.groundTone, 1, 3)
						end
					end
				end
				if pin.label then
					self:Num(sx, sy + 12, pin.label, pinUnsure and "parch" or "ash", 10)
				end
				self:Hit(sx, sy, pin.tip or pin.label, pin)
				if pin.state == "now" and not self.target then
					self.target = { x, y }
				end
			end
		end
	end
	if not self.target and where.travel and where.travel[1] then
		local x, y = xy(where.travel[1])
		if x then
			self.target = { x, y }
		end
	end
	if not self.target and self.center then
		self.target = self.center
	end
	if not self.center then
		self.center = { view.cx, view.cy }
	end

	self:Header(where, mapMode, mode, journal)
	done()
	M.diag.last = self:Stats()
end

-- A loop in spot mode: numbered stops in band colours, the closed polyline with chevrons, floors and stairs.
function Map:Loop(route, stops, skipped, color)
	local live = self.live
	local nextN = live.nextIndex
	if not (nextN and stops[nextN]) then
		nextN = #stops > 0 and 1 or nil
	end
	self.nextN = nextN
	local floor = self.floorWanted or live.floor or (nextN and stops[nextN].p.floor) or (stops[1] and stops[1].p.floor)
	self.floor = floor
	local journal = self.opts.journal
	local visited = live.visited or {}
	local function other(p)
		return floor ~= nil and p.floor ~= nil and p.floor ~= floor
	end
	for _, s in ipairs(skipped) do
		local x, y = self:XY(xy(s.p))
		if self:Vis(x, y) then
			if s.band == "grey" then
				self:Diamond(x, y, 8, "grey", 0.4)
			else
				self:Diamond(x, y, 8, "warn", 1, true)
			end
			self:Hit(x, y, s.type and s.type.name, s)
		end
	end
	local n = #stops
	local closed = route.closed ~= false and n > 2
	for j = 1, (closed and n or n - 1) do
		local s1, s2 = stops[j], stops[j % n + 1]
		local x1, y1 = self:XY(xy(s1.p))
		local x2, y2 = self:XY(xy(s2.p))
		local far = other(s1.p) or other(s2.p)
		local change = s1.p.floor ~= s2.p.floor and s1.p.floor ~= nil and s2.p.floor ~= nil
		if change then
			self:Dashed(x1, y1, x2, y2, "bone", far and 0.5 or 0.85, 2)
			local sx, sy = (x1 + x2) / 2, (y1 + y2) / 2
			for _, st in ipairs(route.stairs or {}) do
				if
					(st.from == s1.p.floor and st.to == s2.p.floor) or (st.from == s2.p.floor and st.to == s1.p.floor)
				then
					local stx, sty = xy(st)
					if stx then
						sx, sy = self:XY(stx, sty)
					end
				end
			end
			self:Stairs(sx, sy, (s2.p.floor or 0) > (s1.p.floor or 0))
		else
			self:Line(x1, y1, x2, y2, "bone", far and 0.3 or 0.85, 2)
			self:Chevron(x1, y1, x2, y2, "bone", far and 0.3 or 0.9)
		end
	end
	for j, s in ipairs(stops) do
		local x, y = self:XY(xy(s.p))
		if self:Vis(x, y) then
			local isNext = j == nextN
			local wasVisited = visited[j] ~= nil and visited[j] ~= false
			local numbered = journal or isNext or j == 1 or (nextN and (j - nextN) % n < 5)
			if journal then
				self:Stop(x, y, s.n, {
					tone = s.band,
					hollow = other(s.p),
					alpha = wasVisited and 0.3 or 1,
					visited = wasVisited,
					ring = isNext and color or nil,
					size = 16,
					font = 10,
				})
			else
				if isNext then
					self:Disc(x, y, 20, color, 1, 0)
					self:Disc(x, y, 16, self.groundTone, 1, 1)
				end
				self:Diamond(x, y, 8, s.band, wasVisited and 0.3 or (other(s.p) and 0.7 or 1), other(s.p))
				if wasVisited then
					self:Disc(x + 5, y - 5, 6, "green", 1, 4)
				end
				if numbered then
					self:Num(x + 9, y - 7, s.n, "bone", 10, wasVisited and 0.4 or 1)
				end
			end
			-- the band letter in the tooltip repeats the pin's colour
			local name = s.type and s.type.name
			local tip = name and ("%d. %s (%s)"):format(s.n, name, s.band) or nil
			self:Hit(x, y, tip, s)
			if j == 1 then
				self:Num(x, y + (journal and 16 or 12), route.startLabel or "you come in here", "ash", 10)
			end
		end
	end
	if nextN then
		local x, y = xy(stops[nextN].p)
		self.target = { x, y }
	end
end

-- Stairs: an 18-px ink square with a bone edge and two stacked chevrons, up or down.
function Map:Stairs(x, y, up)
	if not self:Vis(x, y) then
		return
	end
	self:Quad(x, y, 18, 18, "bone", 1, 4)
	self:Quad(x, y, 16, 16, "ink", 1, 5)
	for _, dy in ipairs({ -3, 3 }) do
		local t = W.take(self.pools.chevs)
		t:ClearAllPoints()
		t:SetPoint("CENTER", self.canvas, "TOPLEFT", x, -(y + dy))
		t:SetSize(8, 8)
		t:SetRotation(up and math.pi / 2 or -math.pi / 2)
		t:SetVertexColor(W.rgb("bone"))
		t:Show()
	end
end

-- No art: 1-px lines every 5 map units (10 when they would crowd) with coordinate numbers.
function Map:Grid()
	local step = 0.05
	if step * self.lw * self.k < 28 then
		step = 0.1
	end
	if step * self.lw * self.k < 14 then
		return
	end
	for i = 0, math.floor(1 / step + 0.5) do
		local v = i * step
		local x, y = self:XY(v, v)
		if x >= 0 and x <= self.w then
			self:Quad(x, self.h / 2, 1, self.h, "line", 1, -3)
			self:Num(x + 3, 8, ("%d"):format(v * 100 + 0.5), "ash", 10, 0.9, "LEFT")
		end
		if y >= 0 and y <= self.h then
			self:Quad(self.w / 2, y, self.w, 1, "line", 1, -3)
			self:Num(4, y - 7, ("%d"):format(v * 100 + 0.5), "ash", 10, 0.9, "LEFT")
		end
	end
end

-- Title, chips, confidence tag, mode and floor controls, north mark and yard scale.
function Map:Header(where, mapMode, mode, journal)
	local full = where and self.opts.header ~= "none"
	self.scrim:SetShown(full and true or false)
	self.title:SetShown(full and true or false)
	self.sub:SetShown(full and true or false)
	if not where then
		for _, x in ipairs({
			self.mobs,
			self.dist,
			self.tag,
			self.north,
			self.northN,
			self.scaleText,
			self.scale[1],
			self.scale[2],
			self.scale[3],
		}) do
			x:Hide()
		end
		if self.modes then
			self.modes:Hide()
			self.floors:Hide()
		end
		return
	end
	if full then
		W.set(self.title, where.title, "bone")
		W.set(self.sub, where.sub, "ash")
		W.setMobChip(self.mobs, where.mobs)
		if not where.mobs then
			self.mobs:SetWidth(1)
		end
	else
		self.mobs:Hide()
	end
	local left, topY = 8, -8
	if self.modes then
		local showModes = where.route ~= nil or (where.views and where.views.spot ~= nil)
		if showModes then
			local labels = where.modeLabels or {}
			local wd = self.modes:Set(
				{
					{ id = "travel", label = labels.travel or "Getting there" },
					{ id = "spot", label = labels.spot or "The loop" },
				},
				mode,
				function(id)
					self:SetMode(id)
				end
			)
			left = left + wd + 6
		else
			self.modes:Hide()
		end
		local floors = where.route and where.route.floors
		if floors and #floors > 1 and mode == "spot" then
			local options = {}
			for _, f in ipairs(floors) do
				options[#options + 1] = {
					id = f.id,
					label = f.count and ("%s, %d"):format(f.label or f.id, f.count) or (f.label or tostring(f.id)),
				}
			end
			self.floors:ClearAllPoints()
			self.floors:SetPoint("TOPLEFT", left, -8)
			self.floors:Set(options, self.floor, function(id)
				self:SetFloor(id)
			end)
		else
			self.floors:Hide()
		end
		if showModes then
			left, topY = 8, -36
		end
	end
	local tag = where.tag
		or (where.confidence == "classic" and "from Classic, unconfirmed")
		or (where.confidence == "approx" and "area approximate")
		or nil
	if self.artWhy and mapMode == "grid" then
		tag = tag or "map art missing"
	end
	self.tag:ClearAllPoints()
	self.tag:SetPoint("TOPLEFT", left, topY)
	-- the technical reason (which call gave nothing) is in the tag's tooltip
	W.setChip(self.tag, tag, "parch", self.artWhy)

	-- north mark and yard scale: always in the journal, on the small views only on the plain field
	local marks = journal or mapMode == "plan"
	local ww = marks and M.worldSize(where.map)
	local yd, px
	if ww then
		yd, px = M.scaleBar(self.lw * self.k / ww)
	end
	self.north:SetShown(marks and true or false)
	self.northN:SetShown(marks and true or false)
	if marks then
		local ny = self.dist:IsShown() and -34 or -12
		self.north:ClearAllPoints()
		self.north:SetPoint("TOPRIGHT", -12, ny)
		self.north:SetVertexColor(W.rgb("ash"))
		self.northN:ClearAllPoints()
		self.northN:SetPoint("TOP", self.north, "BOTTOM", 0, -1)
		W.set(self.northN, "N", "ash")
	end
	local bar = yd ~= nil and px ~= nil and px <= self.w - 40
	for _, t in ipairs(self.scale) do
		t:SetShown(bar)
	end
	self.scaleText:SetShown(bar)
	if bar then
		local by = (full and where.mobs) and 34 or 10
		local line, e1, e2 = self.scale[1], self.scale[2], self.scale[3]
		line:ClearAllPoints()
		line:SetPoint("BOTTOMRIGHT", -10, by)
		line:SetSize(px, 1)
		e1:ClearAllPoints()
		e1:SetPoint("BOTTOMRIGHT", line, "BOTTOMRIGHT", 0, 0)
		e1:SetSize(1, 5)
		e2:ClearAllPoints()
		e2:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 0)
		e2:SetSize(1, 5)
		for _, t in ipairs(self.scale) do
			W.fill(t, "bone", 0.8)
		end
		self.scaleText:ClearAllPoints()
		self.scaleText:SetPoint("BOTTOMRIGHT", line, "TOPRIGHT", 0, 3)
		W.set(self.scaleText, ("%d yd"):format(yd), "bone", 0.8)
	end
	self.scaleYd = bar and yd or nil
end

-- The 10 Hz tick: reads the position once, moves the arrow, the bearing line and the distance chip. Everything else
-- is redrawn only when the signature changes (mode, next stop, floor, visits). Cost per tick while shown: one
-- C_Map.GetPlayerMapPosition, one GetPlayerFacing, about ten region setters.
function Map:Tick()
	local where = self.where
	if not where or where.empty or not self.k then
		return
	end
	M.diag.ticks = M.diag.ticks + 1
	local live = self.live
	local pos, why = M.position(where.map)
	live.ok, live.why = pos ~= nil and pos.x ~= nil, why
	live.x, live.y, live.facing, live.onMap =
		pos and pos.x, pos and pos.y, pos and pos.facing, pos and pos.onMap or false
	live.yards, live.bearing, live.compass = nil, nil, nil
	local target = self.target
	if live.ok and target and target[1] then
		local yards, bearing, sizeWhy = M.between(where.map, live.x, live.y, target[1], target[2])
		-- bearing in degrees clockwise from north, as Where.live gives it
		live.yards, live.bearing, live.compass = yards, bearing and math.deg(bearing) or nil, M.compass(bearing)
		live.distWhy = sizeWhy
	end
	-- auto mode: spot inside enterYd, travel again outside leaveYd; the gap stops flicker
	if live.ok and self.center and where.route then
		local d = M.between(where.map, live.x, live.y, self.center[1], self.center[2])
		if d then
			if d <= (where.enterYd or 80) then
				live.mode = "spot"
			elseif d >= (where.leaveYd or 160) or not live.mode then
				live.mode = "travel"
			end
		end
	end
	live.mode = live.mode or "travel"
	if self.wanted == "auto" and live.mode ~= self.mode and (live.mode == "travel" or where.route) then
		self.mode = live.mode
	end
	live.shown = self.mode
	-- the owner turns the live state into strings (provider.live) and may set nextIndex, floor and visited
	local strings = self.opts.onLive and self.opts.onLive(where, live, self) or nil
	self:Draw(false)

	if live.ok and self.k then
		local x, y = self:XY(live.x, live.y)
		local cx, cy = math.max(8, math.min(self.w - 8, x)), math.max(8, math.min(self.h - 8, y))
		local clamped = cx ~= x or cy ~= y
		self.arrow:ClearAllPoints()
		self.arrow:SetPoint("CENTER", self.canvas, "TOPLEFT", cx, -cy)
		self.arrow:SetRotation(live.facing or 0)
		self.arrow:SetAlpha(clamped and 0.7 or 1)
		self.arrow:Show()
		if target and target[1] and not clamped then
			local tx, ty = self:XY(target[1], target[2])
			self.bearing:SetStartPoint("TOPLEFT", self.canvas, cx, -cy)
			self.bearing:SetEndPoint("TOPLEFT", self.canvas, tx, -ty)
			local r, g, b = W.rgb(where.color or "bone")
			self.bearing:SetColorTexture(r, g, b, 0.9)
			self.bearing:Show()
		else
			self.bearing:Hide()
		end
	else
		self.arrow:Hide()
		self.bearing:Hide()
	end
	local dist = strings and strings.dist
	if not dist then
		if live.yards then
			dist = ("%d yd"):format(live.yards + 0.5)
		elseif live.ok then
			dist = "no distance"
		elseif pos and not pos.onMap then
			dist = nil -- on another map: the provider's string says how to get there; without one, no chip
		else
			dist = "no position"
		end
	end
	if self.opts.header == "none" then
		self.dist:Hide()
	else
		local tip = (not live.ok and live.why) or live.distWhy or nil
		W.setChip(self.dist, dist, nil, tip, nil)
		if not live.yards then
			W.setColor(self.dist.label, "ash")
		end
	end
	return live, strings
end

-- The pin nearest the cursor, within 10 px.
function Map:Nearest()
	local clip = self.frame
	local left, top, scale = clip:GetLeft(), clip:GetTop(), clip:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	if not (num(left) and num(top) and num(scale) and scale > 0 and num(cx) and num(cy)) then
		return nil
	end
	local lx, ly = cx / scale - left, top - cy / scale
	local best, bestD
	for _, hit in ipairs(self.hits) do
		local d = (hit.x - lx) ^ 2 + (hit.y - ly) ^ 2
		if d <= 100 and (not bestD or d < bestD) then
			best, bestD = hit, d
		end
	end
	return best and best.pin, best
end

function Map:Hover()
	local _, hit = self:Nearest()
	if hit and hit.tip then
		if self.tipOn ~= hit then
			self.tipOn = hit
			W.showTip(self.frame, hit.tip)
		end
	elseif self.tipOn then
		self.tipOn = nil
		W.hideTip(self.frame)
	end
end

-- Regions this view has made, by pool (a disc is a texture and its mask).
function Map:Pooled()
	local out, total = {}, 0
	for name, pool in pairs(self.pools) do
		out[name] = #pool.items
		total = total + #pool.items * (name == "discs" and 2 or 1)
	end
	out.total = total
	return out
end

function Map:Used()
	local out = {}
	for name, pool in pairs(self.pools) do
		out[name] = pool.n
	end
	return out
end

function Map:Stats()
	local where = self.where
	local used = self:Used()
	local visited = 0
	for _ in pairs(self.live.visited or {}) do
		visited = visited + 1
	end
	return {
		mapMode = self.mapMode,
		mode = self.mode,
		k = self.k and math.floor(self.k * 100 + 0.5) / 100 or nil,
		tiles = used.tiles,
		pins = #self.hits,
		lines = used.lines,
		dashes = used.dashes,
		chevs = used.chevs,
		pooled = self:Pooled(),
		artMissing = self.artWhy,
		positionWhy = self.live.why,
		confidence = where and where.confidence or nil,
		visited = visited,
		floor = self.floor,
		scaleYd = self.scaleYd,
		dashOver = self.dashOver,
	}
end
