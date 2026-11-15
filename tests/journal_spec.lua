-- The journal, the field card, the tracker and the map view against a frame mock: every page builds from fixtures,
-- pools are reused, the map picks tiles / soft / plain field by magnification, a 60-point loop makes the regions it
-- should and no more on a second draw, nil view-models show their empty states, and clicks reach the provider.
-- The fixtures are written from the design's shapes (docs/ui.md), not from Where.lua, so this spec stands alone.

------------------------------------------------------------------------------------------------------------- mock

local made -- counts of what the mock created, by kind
local SECRET = {}
local world -- what the fake client answers

local METHODS = {}
local function noop() end

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

local function new(kind, parent)
	made[kind] = (made[kind] or 0) + 1
	return setmetatable({ kind = kind, parent = parent, shown = true, scripts = {}, points = {} }, MT)
end

-- Show and Hide run OnShow / OnHide when the state changes, as the client does.
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
	return #tostring(self.text or "") * (self.fontHeight or 10) * 0.5
end
function METHODS:GetStringHeight()
	return self.fontHeight or 10
end
function METHODS:IsTruncated()
	return self.truncated == true
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
function METHODS:SetPoint(...)
	self.points[#self.points + 1] = { ... }
end
function METHODS:ClearAllPoints()
	self.points = {}
end
function METHODS:GetPoint()
	return "CENTER", nil, "CENTER", 0, 0
end
function METHODS:SetScript(name, fn)
	self.scripts[name] = fn
end
function METHODS:GetScript(name)
	return self.scripts[name]
end
function METHODS:SetTexture(id)
	if id == "bad" then
		error("texture refused")
	end
	self.texture = id
end
function METHODS:GetTexture()
	return self.texture
end
function METHODS:SetAtlas(name)
	self.atlas = name
end
function METHODS:SetDesaturation(v)
	self.desat = v
end
function METHODS:SetRotation(v)
	self.rotation = v
end
function METHODS:SetAlpha(a)
	self.alpha = a
end
function METHODS:SetColorTexture(r, g, b, a)
	self.color = { r, g, b, a }
end
function METHODS:SetStartPoint(_, _, x, y)
	self.x1, self.y1 = x, y
end
function METHODS:SetEndPoint(_, _, x, y)
	self.x2, self.y2 = x, y
end
function METHODS:GetLeft()
	return 0
end
function METHODS:GetTop()
	return 600
end
function METHODS:GetBottom()
	return 300
end
function METHODS:GetEffectiveScale()
	return 1
end
function METHODS:GetScale()
	return 1
end
function METHODS:GetFrameLevel()
	return 1
end
function METHODS:IsOwned()
	return false
end
function METHODS:CreateTexture()
	return new("Texture", self)
end
function METHODS:CreateFontString()
	return new("FontString", self)
end
function METHODS:CreateLine()
	return new("Line", self)
end
function METHODS:CreateMaskTexture()
	return new("MaskTexture", self)
end

local function fire(obj, script, ...)
	local fn = obj.scripts[script]
	assert(fn, "no script " .. script)
	return fn(obj, ...)
end

local function total()
	local n = 0
	for _, v in pairs(made) do
		n = n + v
	end
	return n
end

local ATLASES = {
	["MiniMap-QuestArrow"] = true,
	TaxiNode_Horde = true,
	TaxiNode_Neutral = true,
	["poi-door-arrow-up"] = true,
	Mailbox = true,
	Profession = true,
	DungeonSkull = true,
	VignetteLoot = true,
}

local function install()
	made = {}
	world = { pos = { 0.42, 0.13 }, instance = false, waypoints = {}, bound = {}, opened = {} }
	_G.CreateFrame = function(kind, name)
		local f = new("Frame")
		f.frameType, f.name = kind, name
		if name then
			_G[name] = f
		end
		return f
	end
	_G.UIParent = new("Frame")
	_G.UIParent.h = 768
	_G.GameTooltip = new("Frame")
	made = {} -- the client's own frames do not count
	_G.UISpecialFrames = {}
	_G.issecretvalue = function(v)
		return v == SECRET
	end
	_G.CreateColor = function(r, g, b, a)
		return { r = r, g = g, b = b, a = a }
	end
	_G.GetCursorPosition = function()
		return 0, 0
	end
	_G.IsInInstance = function()
		return world.instance
	end
	_G.GetPlayerFacing = function()
		return 0
	end
	_G.InCombatLockdown = function()
		return world.combat or false
	end
	_G.GetBindingKey = function()
		return world.key
	end
	_G.GetCurrentBindingSet = function()
		return 1
	end
	_G.SetBinding = function(key, command)
		world.bound[#world.bound + 1] = { key, command }
		return true
	end
	_G.SaveBindings = noop
	_G.OpenWorldMap = function(map)
		world.opened[#world.opened + 1] = map
	end
	_G.C_Texture = {
		GetAtlasInfo = function(name)
			return ATLASES[name] and {} or nil
		end,
	}
	_G.UiMapPoint = {
		CreateFromCoordinates = function(map, x, y)
			return { map = map, x = x, y = y }
		end,
	}
	_G.C_SuperTrack = { SetSuperTrackedUserWaypoint = noop }
	_G.C_Map = {
		-- map 1: art, 4 x 3 tiles. map 2: no art. map 3: art whose tiles the client refuses.
		GetMapArtLayers = function(map)
			if map == 2 then
				return nil
			end
			return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } }
		end,
		GetMapArtLayerTextures = function(map)
			local out = {}
			for i = 1, 12 do
				out[i] = map == 3 and "bad" or (1000 + i)
			end
			return out
		end,
		GetMapWorldSize = function()
			return 3000, 2000
		end,
		GetPlayerMapPosition = function()
			if not world.pos then
				return nil
			end
			return {
				GetXY = function()
					return world.pos[1], world.pos[2]
				end,
			}
		end,
		CanSetUserWaypointOnMap = function()
			return true
		end,
		SetUserWaypoint = function(point)
			world.waypoints[#world.waypoints + 1] = point
		end,
	}
	_G.MenuUtil = {
		CreateContextMenu = function(_, generator)
			local root = { items = {} }
			local function add(kind)
				return function(_, label, a, b)
					local item = { kind = kind, label = label, run = b or a, SetEnabled = noop }
					root.items[#root.items + 1] = item
					return item
				end
			end
			root.CreateTitle = function(_, title)
				root.title = title
			end
			root.CreateRadio, root.CreateCheckbox, root.CreateButton = add("radio"), add("check"), add("button")
			generator(nil, root)
			world.menu = root
		end,
	}
end

local function load()
	install()
	local ns = {}
	for _, f in ipairs({ "Widgets.lua", "MapCanvas.lua", "FieldUI.lua", "JournalUI.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

--------------------------------------------------------------------------------------------------------- fixtures

local function copy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = copy(v)
	end
	return out
end

local function yields(skill)
	return {
		axis = { lo = 60, hi = 300 },
		skill = skill,
		rows = {
			{
				pk = "dented",
				icon = "atlas:VignetteLoot",
				name = "Dented Footlocker",
				req = 175,
				segs = { { from = 175, to = 200, color = "orange" }, { from = 200, to = 225, color = "yellow" } },
				state = "orange",
				right = "to 200",
				tone = "orange",
			},
			{ pk = "battered", name = "Battered Footlocker", req = 70, segs = {}, state = "grey", right = "none" },
			{
				pk = "mossy",
				name = "Mossy Footlocker",
				req = 225,
				segs = { { from = 225, to = 250, color = "orange" } },
				state = "locked",
				right = "needs 225",
			},
		},
	}
end

-- A loop of n points on a circle of radius r (map units 0-1), all one orange type, on map `map`.
local function loop(n, map, span)
	local pts = {}
	for i = 1, n do
		local a = (i - 1) / n * 2 * math.pi
		pts[i] = { x = 0.42 + math.cos(a) * 0.04, y = 0.12 + math.sin(a) * 0.04, pk = "dented", floor = 1 }
	end
	return {
		kind = "loop",
		key = "angor" .. n,
		profession = "Lockpicking",
		color = "orange",
		title = "Angor Fortress",
		sub = "Badlands, 42, 12",
		verb = { text = "Open footlockers", gain = "8 points to 190" },
		map = map or 1,
		confidence = "classic",
		views = { travel = { cx = 0.42, cy = 0.2, span = 0.5 }, spot = { cx = 0.42, cy = 0.12, span = span or 0.1 } },
		enterYd = 80,
		leaveYd = 160,
		area = { shape = "circle", x = 0.42, y = 0.12, r = 0.03 },
		pins = {
			{
				id = "fp",
				kind = "flight",
				faction = "Horde",
				x = 0.3,
				y = 0.3,
				tip = "Kargath",
				confidence = "confirmed",
			},
			{ id = "door", kind = "entrance", x = 0.41, y = 0.16, tip = "Gate", confidence = "classic" },
		},
		leadIn = { points = { { 0.3, 0.3 }, { 0.41, 0.16 } }, yards = 600 },
		route = {
			pts = pts,
			closed = true,
			loopYd = 310,
			poolsOf = 6,
			respawnSec = 300,
			types = { dented = { name = "Dented Footlocker", band = "orange" } },
		},
		travel = {
			{ icon = "flight", text = "Fly to Kargath", x = 0.3, y = 0.3, doneYd = 40, confidence = "confirmed" },
			{ icon = "entrance", text = "Through the gate", x = 0.41, y = 0.16, doneYd = 15, confidence = "classic" },
		},
		flight = { name = "Kargath", yards = 1150 },
		mobs = {
			min = 38,
			max = 40,
			elite = false,
			label = "Mobs 38-40",
			tone = "orange",
			phrase = "3 above you",
			names = { "Shadowforge Guard 38-40" },
		},
		yields = yields(182),
		caption = { line1 = "Loop 310 yd, about 6 boxes up, mobs 38-40", line3 = "The view zooms in at 80 yd." },
		next = {
			key = "swamp",
			text = "At 225: Mossy Footlockers, Swamp of Sorrows",
			sub = "Mobs 35-37.",
			tone = "green",
		},
	}
end

local function errand()
	return {
		kind = "errand",
		key = "errand:org",
		profession = "Blacksmithing",
		color = "gold",
		title = "Orgrimmar",
		sub = "Valley of Honor",
		verb = { text = "Three stops in Orgrimmar" },
		map = 1,
		confidence = "confirmed",
		views = { travel = { cx = 0.5, cy = 0.5, span = 0.4 } },
		stops = {
			{
				n = 1,
				kind = "trainer",
				name = "Saru Steelfury",
				what = "Train Journeyman",
				cost = "5s",
				place = "The Burning Anvil",
				x = 0.5,
				y = 0.5,
				state = "now",
				confidence = "confirmed",
				target = "Saru Steelfury",
			},
			{
				n = 2,
				kind = "vendor",
				name = "Sumi",
				what = "Buy 20 Coal",
				place = "The Burning Anvil",
				x = 0.52,
				y = 0.5,
				leg = "+12 yd",
				state = "todo",
				confidence = "classic",
			},
			{
				n = 3,
				kind = "auction",
				name = "Auction House",
				what = "3 items",
				x = 0.6,
				y = 0.6,
				leg = "+310 yd",
				state = "todo",
				confidence = "confirmed",
			},
		},
		caption = { line1 = "Orgrimmar, 3 stops" },
	}
end

local function overview(n)
	local rows = {}
	local names = {
		"Alchemy",
		"Blacksmithing",
		"Cooking",
		"Enchanting",
		"Engineering",
		"First Aid",
		"Fishing",
		"Herbalism",
		"Leatherworking",
		"Lockpicking",
		"Mining",
		"Skinning",
		"Tailoring",
		"Poisons",
		"Riding",
		"Smelting",
		"Survival",
	}
	for i = 1, n or #names do
		local learned = i % 3 ~= 0
		rows[i] = {
			key = names[i],
			name = names[i],
			icon = 134400,
			learned = learned,
			usable = names[i] ~= "Lockpicking",
			why = names[i] == "Lockpicking" and "Rogues only" or nil,
			skill = learned and (i * 15) or nil,
			cap = 150,
			cost = {
				total = i == 4 and nil or (i .. "g"),
				mats = "1g",
				recipes = "20s",
				training = "5s",
				copper = i ~= 4 and i * 10000 or nil,
			},
			coverage = {
				done = learned and i * 15 or 0,
				gaps = i == 2 and { { from = 225, to = 240, reason = "no priced recipe", lacks = { "Thorium Bar" } } }
					or {},
			},
			status = i == 2 and "gaps" or "complete",
			statusText = i == 2 and "1 gap" or "complete",
			line = i == 2 and "225 to 240: no priced recipe. TSM lacks 1 price" or nil,
			lineTone = "warn",
			tsmMissing = i == 2 and 1 or 0,
		}
	end
	return { rows = rows, totals = { tsmMissing = 1, priceAge = "2 h" } }
end

local function path()
	local rows = {
		{ kind = "fold", title = "6 steps done, 1 to 150", action = { id = "section", key = "done", enabled = true } },
	}
	for i = 1, 40 do
		rows[#rows + 1] = {
			kind = i == 7 and "gap" or (i == 3 and "unlock" or "step"),
			n = i,
			icon = 134400,
			title = "Craft 14 Heavy Grinding Stone " .. i,
			sub = "usually 10. 42 Heavy Stone",
			range = "150-165",
			rangeTone = "orange",
			cost = "12s",
			ways = i % 2 == 0 and 3 or 1,
			action = i == 7 and { id = "fillGap", label = "Fill this gap", enabled = true } or nil,
		}
	end
	return {
		profession = "Blacksmithing",
		skill = 150,
		caps = {
			{ at = 75, label = "Apprentice 75" },
			{ at = 150, label = "Journeyman 150" },
			{ at = 225, label = "Expert 225" },
			{ at = 300, label = "Artisan 300" },
		},
		gates = { 50, 125, 200 },
		segments = {
			{
				step = 1,
				from = 1,
				to = 150,
				name = "Rough Sharpening Stone",
				bands = { { from = 1, to = 150, color = "orange" } },
				done = true,
			},
			{
				step = 2,
				from = 150,
				to = 165,
				name = "Heavy Grinding Stone",
				bands = { { from = 150, to = 160, color = "orange" }, { from = 160, to = 165, color = "yellow" } },
			},
			{ step = 7, from = 225, to = 240, gap = { reason = "no priced recipe" } },
		},
		markers = {
			{ at = 125, kind = "train", step = 3, tip = "Train Journeyman" },
			{ at = 165, kind = "ah", step = 4, tip = "Plans from the auction house" },
			{ at = 180, kind = "vendor" },
			{ at = 200, kind = "bop" },
		},
		rows = rows,
		selected = 2,
		detail = {
			title = "Heavy Grinding Stone",
			color = "orange",
			lines = { { text = "Craft 14, usually 10. Bought for a bad-luck run at 90%", tone = "bone" } },
			learn = {
				skill = 125,
				text = "Learned at 125 from any Blacksmithing trainer, 10s.",
				known = true,
				confidence = "classic",
			},
			reagents = {
				{ name = "Heavy Stone", need = 42, have = 12, source = "Auction House", price = "40c" },
				{ name = "Coal", need = 2, have = 2, source = "vendor" },
			},
			ways = {
				title = "Ways from 150 to 165",
				rows = {
					{
						label = "Heavy Grinding Stone",
						right = "",
						picked = true,
						action = { id = "swap", spell = 1, enabled = true },
					},
					{
						label = "Green Iron Boots",
						right = "+1g 20s",
						picked = false,
						action = { id = "swap", spell = 2, enabled = true },
					},
				},
			},
			where = errand(),
			actions = {
				{ id = "journal", page = "where", label = "Open in Where", enabled = true },
				{ id = "showRecipe", label = "Show recipe", enabled = true },
			},
		},
	}
end

local function whereList()
	return {
		head = { title = "Lockpicking 182 / 225", sub = "Spots that still give points, nearest first" },
		spots = {
			{
				key = "angor16",
				title = "Angor Fortress",
				sub = "Badlands",
				flight = "Flight: Kargath, 1,150 yd",
				mobs = { label = "Mobs 38-40", tone = "orange", phrase = "3 above you" },
				right = "2 flights",
				confidence = "classic",
				selected = true,
			},
			{
				key = "swamp",
				title = "Pool of Tears",
				sub = "Swamp of Sorrows",
				yield = "Mossy Footlocker, orange to 250",
				yieldTone = "orange",
				mobs = { label = "Mobs 35-37", tone = "green" },
				right = "later",
				locked = "needs 225, you have 182",
				confidence = "confirmed",
			},
		},
		itinerary = {
			title = "Route to 300",
			rows = {
				{ range = "175-225", title = "Angor Fortress", sub = "Badlands", key = "angor16", tone = "orange" },
			},
		},
		selected = loop(16),
	}
end

local function shopping()
	return {
		total = "3g 18s, 3 stops",
		stops = 3,
		blocks = {
			{ kind = "line", text = "Total 3g 18s, 3 stops", color = "bone", size = 12 },
			{
				kind = "head",
				key = "shop:vendor:Orgrimmar",
				text = "Vendor, Orgrimmar: 40c",
				collapsed = false,
				action = { id = "section", key = "shop:vendor:Orgrimmar", enabled = true },
			},
			{ kind = "row", name = "Coal", right = "20 x 5c", mark = "gold" },
			{ kind = "row", name = "Weak Flux", right = "covered", tone = "green" },
			{ kind = "button", action = { id = "buy", label = "Buy", enabled = true } },
		},
		errand = errand(),
		stock = { "Keep 3 Heavy Stone", "Spare 2 Coal" },
	}
end

local function alts()
	return {
		counted = "34 reagents counted on 2 characters",
		characters = {
			{
				name = "Alt",
				rows = {
					{
						item = "Iron Bar",
						want = 14,
						held = 30,
						state = "not queued",
						action = { id = "mailQueue", label = "Queue", enabled = true },
					},
				},
				all = { id = "mailQueue", label = "Queue all for Alt", enabled = true },
			},
		},
		queue = {
			title = "Mail 1 of 2",
			groups = {
				{
					to = "Main",
					fill = { id = "mailFill", label = "Fill mail", enabled = false },
					note = { text = "Open a mailbox", tone = "ash" },
				},
			},
		},
		howto = "Open a mailbox on Alt; Blizzard's Send sends.",
		countAlts = {
			text = "Count reagents on my other characters",
			on = true,
			action = { id = "setting", key = "alts", value = false, enabled = true },
		},
	}
end

local function settings()
	return {
		planner = {
			{
				kind = "dropdown",
				key = "luck",
				label = "Buy for bad luck",
				value = 90,
				text = "90%",
				options = { 50, 75, 80, 90, 95, 99 },
			},
			{ kind = "slider", key = "effort", label = "Effort per craft", value = 20, min = 0, max = 200, step = 5 },
			{ kind = "stepper", key = "sell", label = "Sell share", value = 85, text = "85%", step = 5 },
			{ kind = "check", key = "recipes", label = "Suggest recipes to buy", value = true },
			{ kind = "check", key = "alts", label = "Count reagents on my other characters", value = false },
			{ kind = "check", key = "special", label = "Use special teachers", value = true },
			{
				kind = "list",
				key = "hidden",
				label = "Hidden recipes",
				rows = {
					{
						text = "Green Iron Boots",
						action = { id = "shortcut", spell = 2, label = "Offer again", enabled = true },
					},
				},
			},
			{ kind = "link", label = "Cost to 300 for every profession", page = "overview" },
			{ kind = "key", label = "Key", value = "not set" },
		},
		data = {
			{
				id = "recipes",
				label = "Shipped recipes",
				state = "ok",
				detail = "build 0.3.0, 1,240 recipes, 13 professions",
			},
			{ id = "prices", label = "Local price file", state = "absent", detail = "not present" },
			{
				id = "custom",
				label = "Your Custom file",
				state = "broken",
				detail = "loaded, 2 errors",
				errors = { "recipes.99999: unknown item 99999", "spots.x: no map" },
			},
		},
		learned = {
			{
				id = "ranks",
				title = "Trainer ranks",
				count = 14,
				rows = { { text = "Blacksmithing Journeyman", sub = "at 50, 5s" } },
				reset = { id = "resetLearned", list = "ranks", label = "Reset", enabled = true },
			},
			{ id = "vendors", title = "Vendors seen", count = 0, rows = {} },
		},
	}
end

local FIXTURE =
	{ overview = overview, path = path, where = whereList, shopping = shopping, alts = alts, settings = settings }
local PAGES = { "overview", "path", "where", "shopping", "alts", "settings" }

-------------------------------------------------------------------------------------------------------------- specs

describe("Map view: pure helpers", function()
	local M
	before_each(function()
		M = load().MapCanvas
	end)

	it("picks tiles, soft tiles or the plain field by magnification", function()
		assert.same(
			{ "map", "map", "soft", "soft", "plan" },
			{ M.modeFor(0.3), M.modeFor(2), M.modeFor(2.01), M.modeFor(4), M.modeFor(4.01) }
		)
		assert.equal("plan", M.modeFor(nil))
	end)

	it("lays tiles row-major and keeps only those in the crop", function()
		local L = { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 }
		local k, ox, oy = M.layout(L, { cx = 0.5, cy = 0.5, span = 1 }, 628, 430)
		local all = M.tiles(L, k, ox, oy, 628, 430)
		assert.equal(12, #all)
		assert.same({ 1, 1, 1 }, { all[1].col, all[1].row, all[1].index })
		assert.same({ 4, 3, 12 }, { all[12].col, all[12].row, all[12].index })
		-- a card-sized crop of a quarter of the zone needs at most 6 tiles
		k, ox, oy = M.layout(L, { cx = 0.42, cy = 0.12, span = 0.25 }, 292, 132)
		local few = M.tiles(L, k, ox, oy, 292, 132)
		assert.is_true(#few >= 1 and #few <= 6)
		for _, t in ipairs(few) do
			assert.equal((t.row - 1) * 4 + t.col, t.index)
		end
	end)

	it("picks a 1 / 2 / 5 yard scale whose bar is 80 to 140 px", function()
		local yd, px = M.scaleBar(0.25)
		assert.same({ 500, 125 }, { yd, px })
		yd, px = M.scaleBar(3)
		-- 3 px per yard: 20 yd is 60 px and 50 yd is 150 px, so no value fits; the nearest to 110 px is taken
		assert.same({ 50, 150 }, { yd, px })
		yd, px = M.scaleBar(1.1)
		assert.same({ 100, 110 }, { yd, math.floor(px + 0.5) })
		assert.is_nil(M.scaleBar(0))
	end)

	it("names the bearing in eight words and measures yards on the map", function()
		assert.same(
			{ "north", "east", "south-west" },
			{ M.compass(0), M.compass(math.pi / 2), M.compass(math.pi * 1.25) }
		)
		local yards, bearing = M.between(1, 0.4, 0.5, 0.5, 0.5)
		assert.equal(300, math.floor(yards + 0.5))
		assert.equal("east", M.compass(bearing))
	end)

	it("leaves grey and locked points out of the tour and renumbers the rest", function()
		local route = {
			pts = {
				{ x = 0.1, y = 0.1, pk = "a" },
				{ x = 0.2, y = 0.1, pk = "b" },
				{ x = 0.3, y = 0.1, pk = "c" },
				{ x = 0.4, y = 0.1, pk = "a" },
				{ y = 0.5, pk = "a" },
			},
			types = { a = { band = "orange" }, b = { band = "grey" }, c = { band = "locked" } },
		}
		local stops, skipped = M.tour(route)
		assert.same({ 2, 1, 4 }, { #stops, stops[1].i, stops[2].i })
		assert.same({ 2, "grey", "locked" }, { #skipped, skipped[1].band, skipped[2].band })
		assert.equal(1, M.diag.badPoints) -- the point without an x is counted, not drawn
	end)
end)

describe("Map view: drawing", function()
	local ns, M
	before_each(function()
		ns = load()
		M = ns.MapCanvas
	end)

	local function view(w, h, opts)
		return M.new(CreateFrame("Frame"), w, h, opts)
	end

	it("draws tiles at low magnification, desaturated tiles between 2x and 4x, no tiles above", function()
		local map = view(628, 430, { journal = true })
		local where = loop(16)
		where.views.spot = nil
		where.route = nil
		map:Set(where) -- travel view, span 0.5: k = 1.25
		local s = map:Stats()
		assert.same({ "map", 1.25 }, { s.mapMode, s.k })
		assert.is_true(s.tiles >= 4 and s.tiles <= 12)
		assert.equal(0.35, map.pools.tiles.items[1].desat)
		assert.equal(1001, map.pools.tiles.items[1].texture)

		where = copy(where)
		where.views.travel.span = 0.2 -- k = 3.13
		map:Set(where)
		s = map:Stats()
		assert.equal("soft", s.mapMode)
		assert.equal(0.7, map.pools.tiles.items[1].desat)

		where = copy(where)
		where.views.travel.span = 0.05 -- k = 12.5
		map:Set(where)
		s = map:Stats()
		assert.same({ "plan", 0 }, { s.mapMode, s.tiles })
		assert.is_false(map.pools.tiles.items[1].shown)
		assert.is_true(map.north.shown)
		assert.is_number(s.scaleYd)
	end)

	it("falls back to a coordinate grid when the client has no art, and says which call gave nothing", function()
		local map = view(628, 430, { journal = true })
		map:Set(loop(16, 2))
		local s = map:Stats()
		assert.equal("grid", s.mapMode)
		assert.matches("C_Map.GetMapArtLayers gave nothing for map 2", s.artMissing, 1, true)
		assert.matches("gave nothing for map 2", M.diag.artMissing[2], 1, true)
		assert.equal(0, s.tiles)
		assert.is_true(s.pins > 0)
	end)

	it("falls back to the plain field when a tile is refused, once, and keeps the pins", function()
		local map = view(628, 430, { journal = true })
		local where = loop(16, 3)
		map:Set(where, { mode = "travel" })
		local s = map:Stats()
		assert.equal("plan", s.mapMode)
		assert.equal(0, s.tiles)
		assert.equal(1, M.diag.tileFailures)
		assert.matches("SetTexture refused tile", M.diag.artMissing[3], 1, true)
		assert.is_true(s.pins > 0)
		map:Set(copy(where), { mode = "travel" })
		assert.equal(1, M.diag.tileFailures) -- not retried: the map draws without art from now on
		assert.equal("grid", map:Stats().mapMode)
	end)

	it("draws a 60-point loop with the regions it needs and no more on a second draw", function()
		local map = view(628, 430, { journal = true })
		local where = loop(60)
		map:Set(where, { mode = "spot" })
		local s = map:Stats()
		assert.same({ "plan", "spot" }, { s.mapMode, s.mode })
		local used = map:Used()
		assert.equal(60, used.lines) -- the closed polyline
		-- 60 stops, the two discs of the next-stop ring, and the unconfirmed entrance pin (a hollow disc: two)
		assert.equal(64, used.discs)
		assert.equal(61, used.nums) -- 60 numbers and "you come in here"
		assert.equal(0, used.chevs) -- every segment is under 40 px
		assert.equal(0, used.tiles)
		assert.equal(61, s.pins) -- 60 stops and the entrance; the flight point is outside this crop
		local frames, before = made.Frame, total()
		map:Set(copy(where), { mode = "spot" })
		assert.same({ frames, before }, { made.Frame, total() })
		assert.same(used, map:Used())
		-- a smaller spot afterwards hides the tail of the pools instead of destroying it
		map:Set(loop(8), { mode = "spot" })
		assert.equal(8, map:Used().lines)
		assert.equal(60, map:Pooled().lines)
		assert.is_false(map.pools.lines.items[9].shown)
		-- its eight long segments each take a chevron (the 60-point loop needed none): the only new regions
		assert.equal(8, map:Used().chevs)
		assert.equal(before + 8, total())
	end)

	it("puts chevrons on long segments and dashes the lead-in within its budget", function()
		local map = view(628, 430, { journal = true })
		map:Set(loop(6), { mode = "spot" })
		assert.equal(6, map:Used().chevs)
		map:Set(loop(6), { mode = "travel" })
		local used = map:Used()
		assert.is_true(used.dashes > 0 and used.dashes <= 48)
		assert.is_true(used.lines > 0) -- the area outline and the loop's hull
	end)

	it("marks floors: other-floor stops hollow, a stairs mark on the changing segment", function()
		local where = loop(6)
		for i = 4, 6 do
			where.route.pts[i].floor = 2
		end
		where.route.floors = { { id = 1, label = "Lower", count = 3 }, { id = 2, label = "Upper", count = 3 } }
		local map = view(628, 430, { journal = true })
		map:Set(where, { mode = "spot" })
		assert.equal(1, map:Stats().floor)
		local used = map:Used()
		assert.is_true(used.dashes > 0) -- the two floor-changing segments are dashed
		assert.equal(4, used.lines) -- the other four are solid
		assert.equal(4, used.quads) -- two stairs marks, two squares each
		assert.is_true(map.floors.shown)
		map:SetFloor(2)
		assert.equal(2, map:Stats().floor)
	end)

	it("moves the arrow on the tick and names why there is no position", function()
		local map = view(628, 430, { journal = true })
		local seen
		map.opts.onLive = function(_, live)
			seen = live
			return nil
		end
		map:Set(loop(16), { mode = "spot" })
		assert.is_true(map.arrow.shown)
		assert.is_true(seen.ok)
		assert.equal("spot", seen.shown)
		assert.is_number(seen.yards)
		assert.is_string(seen.compass)
		assert.matches("yd$", map.dist.label.text)
		world.instance = true
		map:Tick()
		assert.is_false(map.arrow.shown)
		assert.same({ false, "in an instance" }, { seen.ok, seen.why })
		assert.equal("no position", map.dist.label.text)
		world.instance, world.pos = false, nil
		map:Tick()
		assert.equal("not on this map", seen.why)
		assert.is_false(map.arrow.shown)
	end)

	it("switches to the loop when the player is inside, and keeps a manual choice", function()
		local map = view(628, 430, { journal = true })
		world.pos = { 0.9, 0.9 }
		map:Set(loop(16))
		assert.equal("travel", map:Stats().mode)
		world.pos = { 0.42, 0.12 }
		map:Tick()
		assert.equal("spot", map:Stats().mode)
		map:SetMode("travel")
		map:Tick()
		assert.equal("travel", map:Stats().mode)
	end)

	it("shows a quiet field with the reason for a nil or an empty model", function()
		local map = view(292, 132)
		map:Set(nil)
		assert.equal("none", map.mapMode)
		assert.is_true(map.note.shown)
		map:Set({ empty = { title = "Nothing mapped for Fishing 225 to 300", text = "No spot covers it." } })
		assert.equal("Nothing mapped for Fishing 225 to 300", map.note.text)
		assert.is_false(map.arrow.shown)
	end)

	it("survives a model with holes in it", function()
		local map = view(292, 132)
		map:Set({ kind = "spot", key = "x", map = 1 })
		map:Set({
			kind = "loop",
			key = "y",
			map = SECRET,
			route = { pts = { { pk = "a" } } },
			pins = { { kind = "flight" } },
			area = { shape = "poly", points = { { 0.1, 0.1 }, { 0.2, 0.2 }, {} } },
		})
		assert.equal("grid", map:Stats().mapMode)
	end)
end)

describe("Widgets", function()
	local W
	before_each(function()
		W = load().Widgets
	end)

	it("splits the band the now-line crosses and dims what is spent", function()
		local band = W.band(CreateFrame("Frame"), 84, 6)
		local cut = band:Set({ { from = 100, to = 200, color = "orange" } }, { lo = 100, hi = 300 }, 150)
		assert.equal(21, cut)
		assert.equal(2, band.segs.n)
		assert.equal(0.38, band.segs.items[1].color[4])
		assert.equal(1, band.segs.items[2].color[4])
		-- a secret skill: the whole bar, nothing dimmed
		band:Set({ { from = 100, to = 200, color = "orange" } }, { lo = 100, hi = 300 }, SECRET)
		assert.equal(1, band.segs.n)
		-- a gap is hatched: a pattern, not only a colour
		band:Set({ { from = 100, to = 200, hatch = true } }, { lo = 100, hi = 300 })
		assert.is_true(band.stripes.n >= 8)
	end)

	it("draws the yields block with one now-line, and none for a secret skill", function()
		local y = W.yields(CreateFrame("Frame"), 272)
		assert.equal(15 + 3 * 20, y:Set(yields(182)))
		assert.is_true(y.nowLine.shown)
		assert.equal("O to 200", y.rows.items[1].right.text) -- the letter repeats the colour
		assert.equal("needs 225", y.rows.items[3].right.text)
		y:Set(yields(SECRET))
		assert.is_false(y.nowLine.shown)
		assert.equal(0, y:Set(nil))
		assert.is_false(y.shown)
	end)

	it("keeps only the rows in view for a long list", function()
		local drawn = 0
		local list = W.list(CreateFrame("Frame"), 568, 376, {
			rowHeight = 46,
			make = function(l)
				return CreateFrame("Button", nil, l)
			end,
			draw = function()
				drawn = drawn + 1
			end,
		})
		local items = {}
		for i = 1, 500 do
			items[i] = { n = i }
		end
		list:SetItems(items)
		assert.is_true(#list.rows.items <= 10)
		local rows = #list.rows.items
		list:ScrollTo(46 * 300)
		assert.equal(rows, #list.rows.items)
		assert.is_true(list.bar.shown)
		list:SetItems({ { n = 1 } })
		assert.is_false(list.bar.shown)
		assert.is_false(list.rows.items[2].shown)
	end)

	it("shows the full text of a truncated label in the tooltip", function()
		local b = W.button(CreateFrame("Frame"))
		W.setButton(b, { id = "x", label = "A very long label that is cut", enabled = true })
		assert.is_nil(W.tipOf(b, b.label))
		b.label.truncated = true
		assert.same({ "A very long label that is cut" }, W.tipOf(b, b.label))
		b.tip = "Own tip"
		assert.equal("Own tip", W.tipOf(b, b.label))
	end)

	it("drops a click on a disabled action and counts one with no handler", function()
		W.onAction = nil
		W.act({ id = "x", enabled = false })
		assert.equal(0, W.dropped)
		W.act({ id = "x", enabled = true })
		assert.equal(1, W.dropped)
	end)
end)

describe("Journal", function()
	local ns, J, calls
	before_each(function()
		ns = load()
		J = ns.JournalUI
		calls = {}
		local function rec(name)
			return function(...)
				calls[#calls + 1] = { name, ... }
				return true
			end
		end
		J.provider = {
			journal = function()
				return {
					profession = "Blacksmithing",
					status = "Prices read 2 h ago",
					crumb = "Step 2: Heavy Grinding Stone",
					professions = {
						{ key = "Blacksmithing", name = "Blacksmithing", learned = true },
						{ key = "Mining", name = "Mining", learned = false },
					},
					tabs = { { id = "shopping", count = 3 }, { id = "settings", pip = true } },
				}
			end,
			page = function(name, ctx)
				calls[#calls + 1] = { "page", name, ctx }
				return FIXTURE[name]()
			end,
		}
		for _, name in ipairs({
			"selectProfession",
			"selectStep",
			"selectSpot",
			"trackSpot",
			"chooseWay",
			"shortcut",
			"setting",
			"waypoint",
			"openMap",
			"resetLearned",
			"act",
		}) do
			J.provider[name] = rec(name)
		end
	end)

	local function last(name)
		for i = #calls, 1, -1 do
			if calls[i][1] == name then
				return calls[i]
			end
		end
	end

	it("creates nothing until it is first opened", function()
		assert.equal(0, made.Frame or 0)
		assert.is_nil(J.frame())
		assert.is_false(J.diag().created)
	end)

	it("builds every page from its fixture, twice, without making more frames or regions", function()
		for _, name in ipairs(PAGES) do
			J.setPage(name, FIXTURE[name]())
			local before = total()
			J.setPage(name, FIXTURE[name]())
			assert.equal(before, total(), name .. " made new frames or regions on its second draw")
			assert.equal(2, J.diag().pages[name].draws)
			assert.is_true(J.page(name).shown)
		end
		local d = J.diag()
		assert.equal(17, d.pages.overview.rows)
		assert.equal(1, d.pages.overview.gaps)
		assert.equal(41, d.pages.path.steps)
		assert.equal(2, d.pages.where.spots)
		assert.equal(9, d.pages.settings.controls)
		assert.equal(2, d.pages.settings.errors)
	end)

	it("shows an empty state that explains itself for a nil view-model on every page", function()
		for _, name in ipairs(PAGES) do
			J.setPage(name, nil)
			local d = J.diag()
			assert.is_true(d.pages[name].empty)
			assert.is_string(d.emptyTitle)
			assert.is_true(#d.emptyTitle > 8, name)
			-- and the page comes back when a model arrives
			J.setPage(name, FIXTURE[name]())
			assert.is_nil(J.diag().emptyTitle)
		end
	end)

	it("handles empty lists and an empty place", function()
		J.setPage("overview", { rows = {} })
		assert.is_true(J.page("overview").none.shown)
		J.setPage("where", {
			head = { title = "Fishing 240 / 300" },
			spots = {},
			selected = {
				empty = {
					title = "Nothing mapped for Fishing 225 to 300",
					text = "No fishing spot covers this bracket yet.",
				},
			},
			empty = "Nothing to fetch right now.",
		})
		local p = J.page("where")
		assert.equal("Nothing mapped for Fishing 225 to 300", p.line1.text)
		assert.is_true(p.none.shown)
		assert.equal("none", p.map.mapMode)
		J.setPage("path", { profession = "Mining", skill = SECRET, rows = {}, segments = {} })
		J.setPage("shopping", { blocks = {}, empty = "Nothing to buy for Mining." })
		assert.equal("Nothing to buy", J.diag().emptyTitle)
		J.setPage("alts", { characters = {} })
		J.setPage("settings", {})
	end)

	it("virtualises the overview and the step list", function()
		J.setPage("overview", overview(17))
		assert.is_true(#J.page("overview").list.rows.items <= 14)
		J.setPage("path", path())
		assert.is_true(#J.page("path").list.rows.items <= 10)
	end)

	it("filters and sorts the overview", function()
		local state = {}
		J.setState(state)
		J.setPage("overview", overview(17))
		local p = J.page("overview")
		assert.equal(17, #p.list.items)
		fire(p.filters.pool.items[1], "OnClick") -- Mine
		assert.equal("mine", state.journal.filter)
		assert.equal(12, #p.list.items)
		fire(p.filters.pool.items[4], "OnClick") -- Gathering
		assert.equal(5, #p.list.items)
		fire(p.filters.pool.items[2], "OnClick") -- All
		fire(p.sorts.pool.items[3], "OnClick") -- Cost: cheapest first, no price last
		assert.equal("Alchemy", p.list.items[1].name)
		assert.equal("Enchanting", p.list.items[17].name)
	end)

	it("opens, toggles, remembers the page and closes on Escape's list", function()
		local state = {}
		J.setState(state)
		assert.is_true(J.Toggle("path"))
		assert.is_true(J.frame().shown)
		assert.equal("SkillupHelperJournal", _G.UISpecialFrames[1])
		assert.equal("path", state.journal.page)
		assert.same({ "page", "path" }, { last("page")[1], last("page")[2] })
		assert.is_true(J.Toggle("where")) -- another page: stays open, switches
		assert.equal("where", state.journal.page)
		assert.is_false(J.Toggle("where"))
		assert.is_false(J.frame().shown)
		_G.SkillupHelper_OnCompartmentClick("SkillupHelper", "LeftButton")
		assert.is_true(J.frame().shown)
		assert.equal("where", J.diag().page) -- the last page
		assert.equal("Open the SkillupHelper journal", _G.BINDING_NAME_SKILLUPHELPER_JOURNAL)
		assert.equal(1, J.diag().opened - 1)
	end)

	it("closes when a fight starts unless the setting is off", function()
		local state = {}
		J.setState(state)
		J.open("overview")
		fire(J.frame(), "OnEvent", "PLAYER_REGEN_DISABLED")
		assert.is_false(J.frame().shown)
		state.journal.closeInCombat = false
		J.open("overview")
		fire(J.frame(), "OnEvent", "PLAYER_REGEN_DISABLED")
		assert.is_true(J.frame().shown)
	end)

	it("does no provider work while hidden", function()
		J.open("overview")
		J.close()
		local n = #calls
		J.refresh()
		assert.equal(n, #calls)
	end)

	it("sends clicks to the provider with the right arguments", function()
		J.setState({})
		J.open("overview")
		-- an overview row opens that profession's path
		local row = J.page("overview").list.rows.items[2]
		assert.equal("Blacksmithing", row.name.text)
		fire(row, "OnClick", "LeftButton")
		assert.same({ "selectProfession", "Blacksmithing" }, last("selectProfession"))
		assert.equal("path", J.diag().page)
		assert.equal("Blacksmithing", last("page")[3].profession)

		-- a step row selects its step; the ways button asks for the Way menu with the button as owner
		local list = J.page("path").list
		fire(list.rows.items[2], "OnClick", "LeftButton")
		assert.same({ "selectStep", 1 }, { last("selectStep")[1], last("selectStep")[2] })
		local ways = list.rows.items[3].btn
		assert.equal("3 ways", ways.label.text)
		fire(ways, "OnClick", "LeftButton")
		assert.same(
			{ "wayMenu", 2, ways },
			{ last("chooseWay")[2].id, last("chooseWay")[2].step, last("chooseWay")[3] }
		)

		-- a way in the detail
		fire(J.page("path").detail.ways.items[2], "OnClick", "LeftButton")
		assert.same({ "swap", 2 }, { last("chooseWay")[2].id, last("chooseWay")[2].spell })

		J.act({ id = "selectSpot", key = "swamp", enabled = true })
		assert.same({ "selectSpot", "swamp" }, last("selectSpot"))
		assert.equal("swamp", last("page")[3].spot)
		J.act({ id = "trackSpot", key = "swamp", enabled = true })
		assert.same({ "trackSpot", "swamp" }, last("trackSpot"))
		J.act({ id = "allow", spell = 9, enabled = true })
		assert.equal(9, last("shortcut")[2].spell)
		J.act({ id = "setting", key = "luck", value = 95, enabled = true })
		assert.same({ "setting", "luck", 95 }, { last("setting")[1], last("setting")[2], last("setting")[3] })
		J.act({ id = "resetLearned", list = "ranks", enabled = true })
		assert.same({ "resetLearned", "ranks" }, last("resetLearned"))
		J.act({ id = "showRecipe", spell = 7, enabled = true })
		assert.equal("showRecipe", last("act")[2].id)
		local n = #calls
		J.act({ id = "setting", key = "luck", value = 50, enabled = false })
		assert.equal(n, #calls) -- a disabled action goes nowhere
	end)

	it("pins and opens the map through the provider, or by itself when the provider has no callback", function()
		J.open("where")
		local where = J.page("where").where
		J.act({ id = "pin", where = where, pin = { x = 0.4, y = 0.1 }, enabled = true })
		assert.same({ "waypoint", where }, { last("waypoint")[1], last("waypoint")[2] })
		J.act({ id = "openMap", where = where, enabled = true })
		assert.same({ "openMap", 1 }, { last("openMap")[1], last("openMap")[2] })
		J.provider.waypoint, J.provider.openMap = nil, nil
		J.act({ id = "pin", where = where, pin = { x = 0.4, y = 0.1 }, enabled = true })
		assert.same({ 1, 0.4, 0.1 }, { world.waypoints[1].map, world.waypoints[1].x, world.waypoints[1].y })
		J.act({ id = "openMap", where = where, enabled = true })
		assert.same({ 1 }, world.opened)
		-- the caption's buttons carry the same actions
		local pin = J.page("where").buttons.items[1]
		assert.equal("Pin on the map", pin.label.text)
		fire(pin, "OnClick", "LeftButton")
		assert.equal(2, #world.waypoints)
	end)

	it("changes settings through controls and asks once before a reset", function()
		J.open("settings")
		local p = J.page("settings")
		local col = p.cols[1].pools
		fire(col.checks.items[1], "OnClick", "LeftButton") -- Suggest recipes to buy: on -> off
		assert.same({ "setting", "recipes", false }, { last("setting")[1], last("setting")[2], last("setting")[3] })
		fire(col.drops.items[1].btn, "OnClick", "LeftButton") -- the luck dropdown opens a radio menu
		assert.equal(6, #world.menu.items)
		world.menu.items[6].run()
		assert.same({ "luck", 99 }, { last("setting")[2], last("setting")[3] })
		fire(col.steppers.items[1].inc, "OnClick", "LeftButton")
		assert.same({ "sell", 90 }, { last("setting")[2], last("setting")[3] })
		col.sliders.items[1].fire(35)
		assert.same({ "effort", 35 }, { last("setting")[2], last("setting")[3] })

		-- reset: the first click only asks; Keep leaves the data, Reset fires
		local function button(label)
			for _, b in ipairs(p.cols[3].pools.buttons.items) do
				if b.shown and b.label.text == label then
					return b
				end
			end
		end
		assert.is_nil(last("resetLearned"))
		fire(button("Reset"), "OnClick", "LeftButton")
		assert.is_nil(last("resetLearned"))
		assert.is_true(p.confirm.ranks)
		fire(button("Keep"), "OnClick", "LeftButton")
		assert.is_nil(p.confirm.ranks)
		fire(button("Reset"), "OnClick", "LeftButton")
		fire(button("Reset"), "OnClick", "LeftButton")
		assert.same({ "resetLearned", "ranks" }, last("resetLearned"))
	end)

	it("binds a key from the next key press and refuses in a fight", function()
		J.open("settings")
		J.act({ id = "bindKey", enabled = true })
		assert.is_true(J.capturing)
		fire(J.frame(), "OnKeyDown", "LSHIFT") -- a modifier alone is not a key
		assert.is_true(J.capturing)
		fire(J.frame(), "OnKeyDown", "J")
		assert.same({ "J", "SKILLUPHELPER_JOURNAL" }, world.bound[1])
		assert.is_nil(J.capturing)
		J.act({ id = "bindKey", enabled = true })
		fire(J.frame(), "OnKeyDown", "ESCAPE")
		assert.equal(1, #world.bound)
		world.combat = true
		J.act({ id = "bindKey", enabled = true })
		assert.is_nil(J.capturing)
	end)

	it("names a provider callback that is missing or that fails, and does not error", function()
		J.provider = {
			page = function()
				error("boom")
			end,
		}
		J.open("overview")
		local d = J.diag()
		assert.is_true(d.missing.journal)
		assert.matches("provider.page failed", d.lastWhy, 1, true)
		assert.is_true(d.pages.overview.empty)
	end)

	it("gives the docked panel an open-journal button", function()
		J.provider.context = function()
			return { profession = "Mining", step = 4 }
		end
		local b = J.newOpenButton(CreateFrame("Frame"))
		fire(b, "OnClick", "LeftButton")
		assert.is_true(J.frame().shown)
		assert.same({ "path", "Mining", 4 }, { last("page")[2], last("page")[3].profession, last("page")[3].step })
	end)
end)

describe("Field card and tracker", function()
	local ns, F
	before_each(function()
		ns = load()
		F = ns.FieldUI
	end)

	it("shows the standalone card for a loop, an errand and a missing place", function()
		local state = {}
		ns.JournalUI.setState(state)
		local f = F.show({
			title = "Lockpicking",
			skill = "182 / 225",
			where = loop(16),
			actions = {
				{ id = "pin", label = "Pin on the map", enabled = true },
				{ id = "openMap", label = "Open zone map", enabled = true },
			},
		})
		assert.is_true(f.shown)
		assert.is_true(state.field.open)
		local loopH = f.h
		assert.is_true(loopH > 300)
		assert.equal("Open footlockers", f.card.verb.text)
		assert.is_true(f.card.yields.shown)
		local before = total()
		F.update({ title = "Lockpicking", skill = "183 / 225", where = loop(16) })
		assert.equal("183 / 225", f.skill.text)
		assert.equal(before, total())
		F.update({ title = "Blacksmithing", where = errand() })
		assert.is_true(f.card.stops.shown)
		assert.is_false(f.card.legs.shown)
		F.update({
			title = "Fishing",
			where = {
				color = "ash",
				empty = {
					title = "Nothing mapped for Fishing 225 to 300",
					text = "No fishing spot covers this bracket yet.",
					action = { id = "selectSpot", key = "lower", label = "Show the nearest lower spot", enabled = true },
				},
			},
		})
		assert.is_false(f.card.map.frame.shown)
		assert.equal("Nothing mapped for Fishing 225 to 300", f.card.empty.title.text)
		assert.is_true(f.h < loopH)
		F.update(nil)
		assert.is_true(f.card.empty.shown)
		F.hide()
		assert.is_false(state.field.open)
	end)

	it("a click on the card's map opens the journal's Where page; a right click pins", function()
		local seen = {}
		local f = F.show({ where = loop(16) })
		ns.Widgets.onAction = function(a)
			seen[#seen + 1] = a
		end
		fire(f.card.map.frame, "OnMouseUp", "LeftButton")
		assert.same({ "journal", "where", "angor16" }, { seen[1].id, seen[1].page, seen[1].spot })
		fire(f.card.map.frame, "OnMouseUp", "RightButton")
		assert.equal("pin", seen[2].id)
	end)

	it("draws the tracker's three bars and leaves an anchor for the secure Target button", function()
		assert.is_nil(F.targetAnchor())
		local t = F.setTracker({
			key = "a",
			color = "orange",
			title = "Angor Fortress",
			right = "214 yd",
			sub = "Fly to Kargath",
			gain = "orange to 200",
			gainTone = "orange",
			bar = {
				kind = "band",
				segs = { { from = 175, to = 200, color = "orange" } },
				axis = { lo = 100, hi = 300 },
				skill = 182,
			},
			mobs = { label = "Mobs 38-40", tone = "orange" },
		})
		assert.is_true(t.shown)
		assert.same({ 236, 60 }, { t.w, t.h })
		assert.is_nil(F.targetAnchor())
		local ticks = {}
		for i = 1, 16 do
			ticks[i] = { state = i < 7 and "done" or (i == 7 and "next" or "todo"), raised = i > 10 }
		end
		F.setTracker({
			key = "a",
			color = "orange",
			title = "Stop 7 of 16",
			right = "38 yd",
			sub = "Dented Footlocker",
			bar = { kind = "ticks", ticks = ticks },
		})
		assert.equal(16, t.ticks.n)
		local many = {}
		for i = 1, 30 do
			many[i] = { state = "todo" }
		end
		F.setTracker({ key = "a", title = "Stop 1 of 30", bar = { kind = "ticks", ticks = many } })
		assert.equal(0, t.ticks.n) -- over 20 stops: a plain bar
		F.setTracker({
			key = "e",
			color = "gold",
			title = "1 of 3: Saru Steelfury",
			right = "140 yd",
			sub = "Train Journeyman",
			gain = "then vendor, AH",
			bar = { kind = "steps", done = 1, total = 3 },
			target = { name = "Saru Steelfury", label = "Target Saru Steelfury" },
		})
		assert.equal(3, t.ticks.n)
		assert.equal(t.target, F.targetAnchor())
		assert.equal("Target Saru Steelfury", t.target.label.text)
		world.combat = true
		ns.JournalUI.provider.trackerLive = function()
			return { right = "120 yd", angle = 1 }
		end
		F.trackerTick()
		assert.equal("Target after the fight", t.target.label.text)
		assert.equal("120 yd", t.right.text)
		F.setTracker(nil)
		assert.is_false(t.shown)
	end)

	it("opens the card from the tracker and the menu from a right click", function()
		local state = {}
		ns.JournalUI.setState(state)
		local t = F.setTracker({ key = "a", title = "Angor Fortress" })
		F.update({ where = loop(16) })
		fire(t, "OnClick", "LeftButton")
		assert.is_true(F.frame().shown)
		fire(t, "OnClick", "LeftButton")
		assert.is_false(F.frame().shown)
		fire(t, "OnClick", "RightButton")
		assert.same({ "Open the journal", "Pin on the map", "Lock position", "Hide the tracker" }, {
			world.menu.items[1].label,
			world.menu.items[2].label,
			world.menu.items[3].label,
			world.menu.items[4].label,
		})
		world.menu.items[3].run()
		assert.is_true(state.tracker.locked)
	end)
end)
