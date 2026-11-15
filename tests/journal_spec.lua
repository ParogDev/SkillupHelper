-- The journal, the field card, the tracker and the map view against a frame mock: every page builds from fixtures,
-- pools are reused, the map picks tiles / soft / plain field by magnification, a 60-point loop makes the regions it
-- should and no more on a second draw, nil view-models show their empty states, and clicks reach the provider.
-- The fixtures are written from the design's shapes (docs/ui.md), not from Where.lua, so this spec stands alone.

------------------------------------------------------------------------------------------------------------- mock

local made -- counts of what the mock created, by kind
local scrolls -- what would scroll: mouse-wheel handlers, and the frame types asked of CreateFrame
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
	if name == "OnMouseWheel" and fn then
		scrolls.wheel = scrolls.wheel + 1
	end
end
function METHODS:EnableMouseWheel(on)
	if on then
		scrolls.wheel = scrolls.wheel + 1
	end
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
	scrolls = { wheel = 0, types = {}, templates = {} }
	world = { pos = { 0.42, 0.13 }, instance = false, waypoints = {}, bound = {}, opened = {} }
	_G.GetPhysicalScreenSize = function()
		return 1024, 768
	end
	_G.CreateFrame = function(kind, name, _, template)
		local f = new("Frame")
		f.frameType, f.name, f.template = kind, name, template
		scrolls.types[kind] = (scrolls.types[kind] or 0) + 1
		if template then
			scrolls.templates[template] = (scrolls.templates[template] or 0) + 1
		end
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

-- A path of n lines from 150 to 300 in stretches of at most six (the shape Where.pathSelect gives): row i selects
-- planner step 2 * i. `shown` is the stretch the list shows; the selected line is the second.
local function path(n, shown)
	n = n or 20
	local rows, stretches = {}, {}
	for i = 1, n do
		local from, to = 150 + math.floor((i - 1) * 150 / n), 150 + math.floor(i * 150 / n)
		rows[i] = {
			kind = i == 7 and "gap" or (i == 3 and "unlock" or "step"),
			n = i,
			step = 2 * i,
			icon = i % 2 == 0 and 134400 or nil,
			title = i == 7 and ("No recipe from %d to %d"):format(from, to)
				or ("Buy the recipe and craft 14 Heavy Grinding Stone " .. i),
			sub = "Usually 10 crafts. Buy 42 Heavy Stone, 14 Coal and 2 more",
			subFull = "Usually 10 crafts. Buy 42 Heavy Stone, 14 Coal, 3 Weak Flux, 1 Silver Bar",
			from = from,
			to = to,
			range = ("%d to %d"):format(from, to),
			rangeTone = i == 7 and "warn" or "orange",
			cost = i ~= 7 and "12s" or nil,
			costNote = i == 4 and "+ unpriced" or nil,
			selected = i == 2,
			tip = { "Line " .. i },
			action = { id = "selectStep", step = 2 * i, enabled = true },
		}
		local k = math.floor((i - 1) / 6) + 1
		stretches[k] = stretches[k] or { index = k, rows = {}, ranks = {} }
		table.insert(stretches[k].rows, rows[i])
	end
	for k, s in ipairs(stretches) do
		s.from, s.to = s.rows[1].from, s.rows[#s.rows].to
		s.label = ("%d to %d"):format(s.from, s.to)
		s.current, s.selected = k == 1, k == (shown or 1)
		s.state = k == 1 and "you are here" or nil
		s.action = { id = "selectStretch", index = k, enabled = true }
		s.head = {
			title = "Expert, " .. s.label,
			lines = k == 1 and {
				"Train Expert at 125, 50s 0c: needed to pass 150",
				"Train Artisan at 200, 5g 0s 0c, needs level 35, you are 30: needed to pass 225",
				"Train Master at 275, 10g: needed to pass 300",
			} or {},
		}
		s.tip = { s.head.title }
	end
	return {
		lines = rows,
		stretches = stretches,
		stretch = shown or 1,
		shade = { from = stretches[shown or 1].from, to = stretches[shown or 1].to },
		crumb = rows[2].title,
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
		selected = 4,
		detail = {
			title = "Heavy Grinding Stone",
			n = 2,
			color = "orange",
			dothis = {
				{ text = "Craft up to 14. Usually 10 are enough.", tone = "bone" },
				{ text = "Skill 150 to 165, orange at the start.", tone = "orange" },
			},
			note = "Price unknown for 1 item: Silver Bar. Not in the cost.",
			recipe = { text = "From the trainer at 125, 10s.", tone = "bone" },
			materials = {
				{ name = "Heavy Stone", need = 42, have = 12, right = "auction, 40c each" },
				{ name = "Coal", need = 2, have = 2, right = "vendor, 5c each" },
			},
			ways = {
				title = "Other ways from 150 to 165",
				rows = {
					{
						label = "Heavy Grinding Stone",
						right = "the plan's pick",
						picked = true,
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

-- Walks a paged owner (a W.list or a W.pages area) from its first page to its last: the pages' ranges must tile
-- 1..total, so no item is on two pages or on none. Returns the total. A single page holds everything.
local function tiles(owner)
	if (owner.pageCount or 1) <= 1 then
		assert.is_false(owner.pager.shown)
		return owner.pager.total or 0
	end
	owner:Turn(-owner.pageCount)
	local nextFirst = 1
	for _ = 1, owner.pageCount do
		assert.is_true(owner.pager.shown)
		assert.equal(nextFirst, owner.pager.first)
		nextFirst = owner.pager.last + 1
		owner:Turn(1)
	end
	assert.equal(owner.pager.total, nextFirst - 1)
	return nextFirst - 1
end

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

	it("pages a long list at row boundaries, with a pager and no scrolling", function()
		local drawn = {}
		local list = W.list(CreateFrame("Frame"), 568, 376, {
			rowHeight = 46,
			noun = "spots",
			make = function(l)
				return CreateFrame("Button", nil, l)
			end,
			draw = function(_, item)
				drawn[#drawn + 1] = item.n
			end,
		})
		local items = {}
		for i = 1, 500 do
			items[i] = { n = i }
		end
		list:SetItems(items)
		-- 376 px less the 26-px pager hold seven 46-px rows
		assert.same({ 7, 72, 7 }, { #list.rows.items, list.pageCount, #drawn })
		assert.is_true(list.pager.shown)
		assert.equal("1 to 7 of 500 spots", list.pager.label.text)
		assert.equal("inert", list.pager.prev.style)
		fire(list.pager.next, "OnClick")
		assert.equal("8 to 14 of 500 spots", list.pager.label.text)
		assert.equal(8, drawn[#drawn - 6])
		list:Reveal(500)
		assert.same({ 72, "498 to 500 of 500 spots" }, { list.page, list.pager.label.text })
		assert.equal("inert", list.pager.next.style)
		assert.is_false(list.rows.items[4].shown)
		assert.equal(500, tiles(list))
		assert.equal(0, list:Unplaced())
		-- the same page is kept when the items are set again with keepPage, the first page otherwise
		list:Reveal(15)
		list:SetItems(items, true)
		assert.equal(3, list.page)
		list:SetItems({ { n = 1 } })
		assert.same({ 1, 1 }, { list.page, list.pageCount })
		assert.is_false(list.pager.shown)
		assert.is_false(list.rows.items[2].shown)
		assert.equal(0, scrolls.wheel)
		assert.equal(0, W.overflow.count)
	end)

	it("keeps a header with the row after it, and counts a row taller than the box", function()
		local list = W.list(CreateFrame("Frame"), 300, 100, {
			make = function(l)
				return CreateFrame("Button", nil, l)
			end,
			draw = function() end,
			height = function(it)
				return it.h
			end,
			keep = function(it)
				return it.head == true
			end,
		})
		-- 30 + 30 fit on page 1; the header (20) would fit too but its row (30) would not: both go to page 2
		list:SetItems({ { h = 30 }, { h = 30 }, { h = 20, head = true }, { h = 30 }, { h = 30 } })
		assert.same({ 1, 1, 2, 2, 3 }, list.pageOf)
		assert.equal(0, W.overflow.count)
		list:SetBox(40)
		list:SetItems({ { h = 60 } })
		assert.equal(1, W.overflow.count)
		assert.matches("list row needs 60 px, has 40", W.overflow.last, 1, true)
	end)

	it("pages view items and hand-laid pieces inside a fixed area", function()
		local area = W.pages(CreateFrame("Frame"), 300, 120, "test area")
		local items = { { kind = "head", text = "Group" } }
		for i = 1, 12 do
			items[#items + 1] = { kind = "row", name = "Row " .. i, right = "1" }
		end
		W.items(area, items, 286)
		assert.is_true(area.pageCount > 1)
		assert.is_true(area.pager.shown)
		assert.matches("of 13 lines$", area.pager.label.text)
		assert.equal(13, tiles(area))
		W.items(area, { { kind = "line", text = "One line" } }, 286)
		assert.same({ 1, false }, { area.pageCount, area.pager.shown })

		-- a flow: pieces of any kind; a gap is dropped at the top of a page; a piece laid over another follows it
		local area2 = W.pages(CreateFrame("Frame"), 300, 100, "flow area")
		local flow = W.flow(area2)
		local pieces = {}
		for i = 1, 6 do
			pieces[i] = CreateFrame("Frame")
			flow:Gap(10)
			local e = flow:Add(pieces[i], 30, 0, i == 3)
			if i == 5 then
				pieces.over = CreateFrame("Button")
				flow:With(e, pieces.over)
			end
		end
		-- the room is 100 - 26 = 74: two 30-px pieces and their gap per page; piece 3 keeps piece 4 with it
		assert.equal(3, flow:Finish("rows"))
		assert.same({ true, true, false }, { pieces[1].shown, pieces[2].shown, pieces[3].shown })
		assert.equal("1 to 2 of 6 rows", area2.pager.label.text)
		area2.redraw = function()
			flow:Finish("rows")
		end
		assert.equal(6, tiles(area2))
		area2:Turn(-9)
		while not pieces[5].shown do
			area2:Turn(1)
		end
		assert.is_true(pieces.over.shown)
		assert.is_false(pieces[1].shown)
		-- a hand-laid total over the box is counted and named, never scrolled
		assert.equal(0, W.overflow.count)
		area2:SetContentHeight(140)
		assert.equal(1, W.overflow.count)
		assert.equal("flow area needs 140 px, has 100", W.overflow.last)
		assert.equal(0, scrolls.wheel)
	end)

	it("puts values on whole pixels and draws the close button from lines", function()
		assert.equal(1, W.pxPerUnit(CreateFrame("Frame"))) -- 768 px high at scale 1
		assert.same({ 3 / 1.3125, 1 / 1.3125, 0 }, {
			W.snapValue(2.4, 1.3125),
			W.snapValue(0.2, 1.3125, 1), -- a rule is never thinner than one pixel
			W.snapValue(0.2, 1.3125),
		})
		local b = W.closeButton(CreateFrame("Frame"))
		assert.equal(2, #b.cross)
		assert.is_false(b.label.shown)
		assert.is_number(b.cross[1].rotation)
		assert.equal("Close (Escape)", b.tip)
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
					professions = {
						{ key = "Blacksmithing", name = "Blacksmithing", learned = true },
						{ key = "Mining", name = "Mining", learned = false },
					},
					tabs = {
						{ id = "overview", count = 3, tip = "3 gaps" },
						{ id = "shopping", count = 3, tip = "3 things to buy" },
						{ id = "alts", count = 2 },
						{ id = "settings", pip = true },
					},
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
			"selectStretch",
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
		assert.same({ 20, 4, 1, 6 }, {
			d.pages.path.steps,
			d.pages.path.stretches,
			d.pages.path.stretch,
			d.pages.path.shown,
		})
		assert.is_true(d.pages.path.detailFits)
		assert.equal(2, d.pages.where.spots)
		assert.equal(9, d.pages.settings.controls)
		assert.equal(2, d.pages.settings.errors)
		assert.same({ 0, nil }, { d.overflow.count, d.overflow.last })
		assert.is_table(d.pixel)
	end)

	it("the shell: a real close button, a breadcrumb that adds something, counts with a noun, a key hint", function()
		J.setState({})
		J.open("path")
		-- the client's close button template, never a letter in a font; its click closes the journal
		assert.equal(1, scrolls.templates.UIPanelCloseButton)
		assert.equal("template", J.diag().close)
		assert.is_nil(J.shell().close.text)
		fire(J.shell().close, "OnClick")
		assert.is_false(J.frame().shown)
		J.open("path")
		-- the dropdown says the profession; the breadcrumb says the selected line, never the profession again
		assert.equal("Buy the recipe and craft 14 Heavy Grinding Stone 2", J.diag().crumb)
		J.open("where")
		assert.equal("Angor Fortress", J.diag().crumb)
		J.provider.page = function()
			local vm = whereList()
			vm.selected.title = "Blacksmithing"
			return vm
		end
		J.open("where")
		assert.is_nil(J.diag().crumb)
		-- tabs: "Shopping 3" has its noun in the tooltip; Overview never carries a count; a count without a noun is dropped
		local labels, tips = {}, {}
		for i, b in ipairs(J.shell().tabs) do
			labels[i], tips[i] = b.label.text, b.tip
		end
		assert.same({ "Overview", "Path", "Where", "Shopping 3", "Alts and mail", "Settings and data" }, labels)
		assert.equal("3 things to buy", tips[4])
		-- the footer hint: a sentence without a key, the key with one; a click opens the settings page
		local hint = J.shell().hint
		assert.equal("No key opens the journal yet. Set one under Settings and data.", hint.label.text)
		fire(hint, "OnClick")
		assert.equal("settings", J.diag().page)
		world.key = "K"
		J.refresh()
		assert.equal("Journal key: K", hint.label.text)
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

	it("the overview is a grid of cards: 17 professions on one page, each card with its four facts", function()
		local vm = overview(17)
		vm.rows[1].skillText, vm.rows[1].costText, vm.rows[1].coverText = "15 / 150", "To 300: 1g", "Path complete"
		vm.rows[2].costText, vm.rows[2].costTone = "To 300: 2g + unpriced", "warn"
		vm.rows[2].coverText, vm.rows[2].coverTone = "1 gap: 225 to 240", "warn"
		vm.rows[2].unpriced = { "Thorium Bar" }
		J.setPage("overview", vm)
		local p = J.page("overview")
		assert.same({ 17, 17, 1 }, { p.cards.n, #p.cards.items, p.grid.pageCount })
		assert.is_false(p.grid.pager.shown)
		local a, b = p.cards.items[1], p.cards.items[2]
		assert.same(
			{ "Alchemy", "15 / 150", "To 300: 1g", "Path complete" },
			{ a.name.text, a.skill.text, a.cost.text, a.cover.text }
		)
		assert.same({ "To 300: 2g + unpriced", "1 gap: 225 to 240" }, { b.cost.text, b.cover.text })
		-- three columns of 306 px, rows of 75 px: card 4 starts the second row, and the last row ends in the body
		assert.same({ "TOPLEFT", 0, -81 }, p.cards.items[4].points[1])
		assert.same({ "TOPLEFT", 315, -405 }, p.cards.items[17].points[1])
		-- the tooltip carries what the card leaves out: the gap's reason, the unpriced items, the cost breakdown
		local tip = table.concat(
			(function()
				local out = {}
				for i, l in ipairs(b.tip) do
					out[i] = type(l) == "table" and l[1] or l
				end
				return out
			end)(),
			" | "
		)
		for _, want in ipairs({
			"225 to 240: no priced recipe",
			"Price unknown, not in the cost: Thorium Bar",
			"Materials: 1g",
			"Recipes: 20s",
			"Training: 5s",
		}) do
			assert.matches(want, tip, 1, true)
		end
		-- "Rogues only" is said on the card, which is dimmed and opens nothing
		local lock = p.cards.items[10]
		assert.same({ "Lockpicking", "Rogues only", false }, { lock.name.text, lock.skill.text, lock.action.enabled })
		-- more professions than the grid holds turn pages (no data ships that many): nothing scrolls
		local many = overview(17)
		for i = 18, 40 do
			many.rows[i] = copy(many.rows[1])
			many.rows[i].key, many.rows[i].name = "Extra" .. i, "Extra " .. i
		end
		J.setPage("overview", many)
		assert.same({ 3, 15, true }, { p.grid.pageCount, p.cards.n, p.grid.pager.shown })
		assert.equal("1 to 15 of 40 professions", p.grid.pager.label.text)
		assert.equal(40, tiles(p.grid))
		assert.equal(0, ns.Widgets.overflow.count)
	end)

	it("the path shows one stretch that fits, its rank trainings, and the stretch bar", function()
		J.setPage("path", path(30))
		local p = J.page("path")
		assert.same({ 6, 5 }, { p.rows.n, #p.vm.stretches })
		-- the header: the stretch, its place in the path, two rank lines and the count of the rest
		assert.same({
			"Expert, 150 to 180",
			"1 to 6 of the path",
			"Train Expert at 125, 50s 0c: needed to pass 150",
			"Train Artisan at 200, 5g 0s 0c, needs level 35, you are 30: needed to pass 225, and 1 more",
		}, { p.head.title.text, p.head.count.text, p.head.lines[1].text, p.head.lines[2].text })
		assert.equal("Train Master at 275, 10g: needed to pass 300", p.head.tip[4])
		-- header (22 + 2 * 16) and six rows of 46 px end inside the 338-px box
		assert.same({ "TOPLEFT", 0, -(54 + 5 * 46) }, p.rows.items[6].points[1])
		assert.is_true(54 + 6 * 46 <= p.area.h)
		-- a row: number, title with the whole width, what to buy, range with the band letter, cost and its note
		local r = p.rows.items[4]
		assert.same(
			{ "4", "Buy the recipe and craft 14 Heavy Grinding Stone 4", "O 165 to 170", "12s", "+ unpriced" },
			{ r.n.text, r.title.text, r.range.text, r.cost.text, r.note.text }
		)
		assert.equal("Usually 10 crafts. Buy 42 Heavy Stone, 14 Coal and 2 more", r.sub.text)
		assert.is_nil(r.btn) -- no "N ways" button in a row
		for _, row in ipairs(p.rows.items) do
			for _, fs in ipairs({ row.title, row.sub, row.range }) do
				assert.is_nil(tostring(fs.text):find("...", 1, true))
			end
		end
		-- the bar: one button per stretch, the current one marked, Previous inert on the first
		local bar = p.bar
		assert.equal(5, bar.pool.n)
		assert.same(
			{ "150 to 180", "you are here", true },
			{ bar.pool.items[1].label.text, bar.pool.items[1].state.text, bar.pool.items[1].selected }
		)
		assert.same({ "inert", "quiet" }, { bar.prev.style, bar.next.style })
		fire(bar.pool.items[3], "OnClick", "LeftButton")
		assert.same({ "selectStretch", 3 }, { calls[#calls][1], calls[#calls][2] })
		fire(bar.next, "OnClick", "LeftButton")
		assert.same({ "selectStretch", 2 }, { calls[#calls][1], calls[#calls][2] })
		-- another stretch shown: the detail keeps the selected line, the list shows the stretch's lines
		J.setPage("path", path(30, 3))
		assert.equal("13", tostring(p.rows.items[1].n.text))
		assert.is_true(bar.pool.items[3].selected)
		assert.equal("Heavy Grinding Stone", p.detail.title.text)
	end)

	it("the path's detail fits: sections, one paged list of materials and ways, the map only with room", function()
		local vm = path()
		J.setPage("path", vm)
		local d = J.page("path").detail
		local texts = {}
		for i = 1, d.labels.n do
			texts[#texts + 1] = d.labels.items[i].text
		end
		for i = 1, d.paras.n do
			texts[#texts + 1] = d.paras.items[i].text
		end
		assert.same({
			"Do this",
			"Get the recipe",
			"Craft up to 14. Usually 10 are enough.",
			"Skill 150 to 165, orange at the start.",
			"Price unknown for 1 item: Silver Bar. Not in the cost.",
			"From the trainer at 125, 10s.",
		}, texts)
		-- the list: Materials (2), Other ways (2), each under its header; beside the map it takes two pages, and
		-- a header never ends a page
		local kinds = {}
		for i, it in ipairs(d.list.items) do
			kinds[i] = it.kind
		end
		assert.same({ "head", "material", "material", "head", "way", "way" }, kinds)
		assert.same({ 2, true }, { d.list.pageCount, d.map.frame.shown })
		assert.same({ 1, 1, 1, 2, 2, 2 }, d.list.pageOf)
		local mat = d.list.rows.items[2]
		assert.same(
			{ "Heavy Stone", "12 / 42", "auction, 40c each" },
			{ mat.label.text, mat.count.text, mat.right.text }
		)
		d.list:Turn(1)
		local pick = d.list.rows.items[2]
		assert.same(
			{ "Heavy Grinding Stone", "the plan's pick", true },
			{ pick.label.text, pick.right.text, pick.dot.shown }
		)
		-- without the unpriced note there is room for all of it beside the map
		vm.detail.note = nil
		J.setPage("path", vm)
		assert.same({ 1, true }, { d.list.pageCount, d.map.frame.shown })
		-- twelve materials and nine ways: the map gives way, the list pages, the card still fits its box
		for i = 3, 12 do
			vm.detail.materials[i] = { name = "Material " .. i, need = i, have = 0, right = "auction, 1s each" }
		end
		for i = 3, 9 do
			vm.detail.ways.rows[i] =
				{ label = "Way " .. i, right = "+1s", action = { id = "swap", spell = i, enabled = true } }
		end
		J.setPage("path", vm)
		local st = J.diag().pages.path
		assert.same({ true, true }, { st.detailFits, st.mapDropped })
		assert.is_false(d.map.frame.shown)
		assert.is_true(d.list.pageCount > 1)
		assert.equal(23, tiles(d.list))
		assert.equal(0, ns.Widgets.overflow.count)
		-- no model: one sentence, nothing else
		d:Set(nil)
		assert.matches("^Pick a line", d.paras.items[1].text)
	end)

	it("the timeline: marker shapes in the legend, the shaded stretch, every edge on a whole pixel", function()
		J.setPage("path", path(30))
		local t = J.page("path").timeline
		local labels = {}
		for i = 1, t.labels.n do
			labels[t.labels.items[i].text] = true
		end
		for _, word in ipairs({ "Trainer", "Auction recipe", "Vendor recipe", "Shortcut", "No recipe", "You, 150" }) do
			assert.is_true(labels[word], word)
		end
		for text in pairs(labels) do
			assert.is_nil(tostring(text):find("Diamond", 1, true)) -- the legend sentence is gone
		end
		assert.is_true(#t.edges > 40)
		for _, x in ipairs(t.edges) do
			assert.equal(math.floor(x + 0.5), x) -- one pixel per unit in this mock: whole units
		end
		-- the timeline is navigation: a click on a segment or on a marker selects that line
		_G.GetCursorPosition = function()
			return 18 + 152 * 3, 600 - 60 -- skill 152, in the segment lane
		end
		fire(t, "OnMouseUp")
		assert.same({ "selectStep", 2 }, { calls[#calls][1], calls[#calls][2] })
		_G.GetCursorPosition = function()
			return 18 + 165 * 3, 600 - 32 -- the auction-recipe marker at 165
		end
		fire(t, "OnMouseUp")
		assert.same({ "selectStep", 4 }, { calls[#calls][1], calls[#calls][2] })
	end)

	it("filters and sorts the overview", function()
		local state = {}
		J.setState(state)
		J.setPage("overview", overview(17))
		local p = J.page("overview")
		assert.equal(17, #p.rows)
		fire(p.filters.pool.items[1], "OnClick") -- Mine
		assert.equal("mine", state.journal.filter)
		assert.equal(12, #p.rows)
		fire(p.filters.pool.items[4], "OnClick") -- Gathering
		assert.equal(5, #p.rows)
		fire(p.filters.pool.items[2], "OnClick") -- All
		fire(p.sorts.pool.items[3], "OnClick") -- Cost: cheapest first, no price last
		assert.equal("Alchemy", p.rows[1].name)
		assert.equal("Enchanting", p.rows[17].name)
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
		local row = J.page("overview").cards.items[2]
		assert.equal("Blacksmithing", row.name.text)
		fire(row, "OnClick", "LeftButton")
		assert.same({ "selectProfession", "Blacksmithing" }, last("selectProfession"))
		assert.equal("path", J.diag().page)
		assert.equal("Blacksmithing", last("page")[3].profession)

		-- a row selects its line by the planner step it stands for; a stretch button asks for that stretch
		local pp = J.page("path")
		fire(pp.rows.items[3], "OnClick", "LeftButton")
		assert.same({ "selectStep", 6 }, { last("selectStep")[1], last("selectStep")[2] })
		assert.equal(6, last("page")[3].step)
		fire(pp.bar.pool.items[2], "OnClick", "LeftButton")
		assert.same({ "selectStretch", 2 }, { last("selectStretch")[1], last("selectStretch")[2] })

		-- another way is picked in the detail (the second page of its list), never in a row
		pp.detail.list:Turn(1)
		local way = pp.detail.list.rows.items[3]
		assert.equal("Green Iron Boots", way.label.text)
		fire(way, "OnClick", "LeftButton")
		assert.same({ "swap", 2 }, { last("chooseWay")[2].id, last("chooseWay")[2].spell })
		assert.is_nil(J.diag().acts.wayMenu)

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

---------------------------------------------------------------------------------------------------------- no scrolling

-- The owner's rule: "If the information requires scroll bars, then the layout is wrong." No page may create a
-- mouse-wheel handler, a Slider or a ScrollFrame, lay content out over its box, or leave an item on no page.
describe("Nothing scrolls", function()
	local ns, J, W
	before_each(function()
		ns = load()
		J, W = ns.JournalUI, ns.Widgets
		J.setState({})
	end)

	-- the worst case the pages must hold: 17 professions, a 30-line path, 25 spots with a 12-leg route, 40 things
	-- to buy with 30 stock lines, 6 other characters with 30 rows each, every settings list long and open
	local WORST = {
		overview = function()
			return overview(17)
		end,
		path = function()
			local vm = path(30)
			for i = 3, 14 do
				vm.detail.materials[i] =
					{ name = "Material " .. i, need = 20, have = i, right = "auction, 1s 20c each" }
			end
			for i = 3, 12 do
				vm.detail.ways.rows[i] = { label = "Another recipe " .. i, right = "+1g 20s" }
			end
			return vm
		end,
		where = function()
			local vm = whereList()
			for i = 3, 25 do
				vm.spots[i] = copy(vm.spots[2])
				vm.spots[i].key, vm.spots[i].title = "spot" .. i, "Spot " .. i
			end
			for i = 2, 12 do
				vm.itinerary.rows[i] =
					{ range = "200 to 225", title = "Leg " .. i, sub = "Somewhere", key = "spot" .. i }
			end
			for i = 4, 9 do
				vm.selected.yields.rows[i] = copy(vm.selected.yields.rows[1])
			end
			return vm
		end,
		shopping = function()
			local vm = shopping()
			for i = 1, 40 do
				vm.blocks[#vm.blocks + 1] = { kind = "row", name = "Reagent " .. i, right = "20 x 5c", mark = "gold" }
			end
			for i = 3, 30 do
				vm.stock[i] = "Keep " .. i .. " of something for a later step"
			end
			return vm
		end,
		alts = function()
			local vm = alts()
			for c = 1, 6 do
				local rows = {}
				for i = 1, 30 do
					rows[i] = { item = "Item " .. i, want = 2, held = 9, state = "not queued" }
				end
				vm.characters[c] = { name = "Alt " .. c, rows = rows }
			end
			for g = 2, 12 do
				vm.queue.groups[g] = { to = "Main", rows = { { name = "Iron Bar", right = "14" } } }
			end
			return vm
		end,
		settings = function()
			local vm = settings()
			for _, e in ipairs(vm.planner) do
				if e.kind == "list" then
					for i = 1, 40 do
						e.rows[i] = {
							text = "Hidden recipe " .. i,
							action = { id = "shortcut", spell = i, label = "Offer again", enabled = true },
						}
					end
				end
			end
			for i = 4, 12 do
				vm.data[i] = { id = "layer" .. i, label = "Layer " .. i, state = "broken", errors = { "one", "two" } }
			end
			for _, l in ipairs(vm.learned) do
				l.count = 40
				for i = 1, 40 do
					l.rows[i] = { text = "Learned row " .. i, sub = "at " .. i }
				end
				l.reset = { id = "resetLearned", list = l.id, label = "Reset", enabled = true }
			end
			return vm
		end,
	}

	-- every paged owner of a page: its lists and areas
	local function owners(name)
		local p = J.page(name)
		if name == "overview" then
			return { p.grid }
		elseif name == "path" then
			return { p.detail.list }
		elseif name == "where" then
			return { p.mode == "route" and p.route or p.list }
		elseif name == "shopping" or name == "alts" then
			return { p.main, p.side }
		end
		return { p.cols[1], p.cols[2], p.cols[3] }
	end

	local function check(name, what)
		local label = name .. " (" .. what .. ")"
		assert.equal(0, scrolls.wheel, label .. ": a mouse-wheel handler")
		assert.is_nil(scrolls.types.Slider, label .. ": a Slider")
		assert.is_nil(scrolls.types.ScrollFrame, label .. ": a ScrollFrame")
		assert.is_nil(W.scroll, "the scroll area is gone")
		assert.equal(0, W.overflow.count, label .. ": " .. tostring(W.overflow.last))
		local sum = 0
		for _, owner in ipairs(owners(name)) do
			sum = sum + tiles(owner)
		end
		assert.equal(0, W.overflow.count, label .. ", after turning every page: " .. tostring(W.overflow.last))
		return sum
	end

	it("no fixture page makes a wheel handler, a slider or a scroll frame, or overflows its box", function()
		for _, name in ipairs(PAGES) do
			J.setPage(name, FIXTURE[name]())
			check(name, "fixture")
			J.setPage(name, nil)
			assert.equal(0, W.overflow.count, name .. " empty: " .. tostring(W.overflow.last))
		end
	end)

	it("the worst case fits every page: what does not fit one page is on another", function()
		local totals = {}
		for _, name in ipairs(PAGES) do
			if name == "settings" then
				J.setPage(name, WORST[name]())
				local p = J.page("settings")
				p.open.ranks, p.open.vendors, p.confirm.ranks = true, true, true
			end
			J.setPage(name, WORST[name]())
			totals[name] = check(name, "worst case")
		end
		-- the path: 30 lines in 5 stretches, each line in exactly one, none longer than its box
		local vm = WORST.path()
		local inStretch = {}
		for _, s in ipairs(vm.stretches) do
			assert.is_true(#s.rows <= 6)
			for _, r in ipairs(s.rows) do
				inStretch[r.n] = (inStretch[r.n] or 0) + 1
			end
		end
		for i = 1, 30 do
			assert.equal(1, inStretch[i])
		end
		for k = 1, #vm.stretches do
			J.setPage("path", path(30, k))
			assert.equal(#vm.stretches[k].rows, J.page("path").rows.n)
			assert.equal(0, W.overflow.count, "stretch " .. k .. ": " .. tostring(W.overflow.last))
		end
		-- the detail's 14 materials and 12 ways under their two headers
		assert.equal(28, totals.path)
		-- where: the selected spot is the card, the other 24 are the list; the 12-leg route takes the list's place
		assert.equal(24, totals.where)
		local where = J.page("where")
		where.list:Turn(-99)
		assert.equal("1 to 3 of 24 spots", where.list.pager.label.text)
		fire(where.listMode.pool.items[2], "OnClick")
		assert.same({ "route", true, false }, { where.mode, where.route.shown, where.list.shown })
		assert.equal(12, tiles(where.route))
		assert.matches("of 12 legs$", where.route.pager.label.text)
		assert.equal(0, W.overflow.count, tostring(W.overflow.last))
		-- settings: 40 hidden recipes, 40 learned rows per open list and the reset question all page in their columns
		local cols = J.page("settings").cols
		assert.is_true(cols[1].pageCount > 1 and cols[2].pageCount > 1 and cols[3].pageCount > 1)
		assert.is_true(totals.settings > 150)
		assert.is_true(totals.shopping > 70 and totals.alts > 180)
		assert.equal(0, scrolls.wheel)
	end)

	it("the map view has no wheel: its two-segment control switches the view", function()
		local map = ns.MapCanvas.new(CreateFrame("Frame"), 628, 430, { journal = true })
		map:Set(loop(16), { mode = "travel" })
		assert.equal(0, scrolls.wheel)
		assert.is_nil(map.frame.scripts.OnMouseWheel)
		map:SetMode("spot")
		assert.equal("spot", map:Stats().mode)
	end)
end)
