-- The docked panel (UI.lua) against a frame mock: what it creates, how tall it gets and where things land. The
-- owner's rules are the asserts: nothing scrolls (no scroll frame, slider, mouse wheel or clip area for any
-- fixture), the panel is never taller than the window beside it, the next lines wrap and are never cut, the path
-- strip covers 1 to 300 on whole pixels, and the window is snapped after it is docked. A mock proves the code runs
-- and measures a made-up font (half the font height per character); how it looks is checked in game.

------------------------------------------------------------------------------------------------------------- mock

local frames -- every frame the code created, in order
local calls -- how often each recorded method ran
local tooltip -- the last text the tooltip showed
local opened -- what JournalUI.open was called with

local METHODS = {}
local function noop() end
local RECORDED = { EnableMouseWheel = true, SetClipsChildren = true, SetScrollChild = true, SetVerticalScroll = true }

local MT = {
	__index = function(_, k)
		local m = METHODS[k]
		if m then
			return m
		end
		if RECORDED[k] then
			return function()
				calls[k] = (calls[k] or 0) + 1
			end
		end
		-- any other widget method is accepted and ignored; lower-case keys are plain fields
		if type(k) == "string" and k:match("^%u") then
			return noop
		end
		return nil
	end,
}

local function new(kind, parent)
	local o = { kind = kind, parent = parent, shown = true, scripts = {}, points = {}, regions = {}, children = {} }
	return setmetatable(o, MT)
end

function METHODS:SetShown(on)
	self.shown = on and true or false
end
function METHODS:Show()
	self.shown = true
end
function METHODS:Hide()
	self.shown = false
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
function METHODS:SetWordWrap(on)
	self.wrap = on
end
function METHODS:GetStringWidth()
	return #tostring(self.text or "") * (self.fontHeight or 12) * 0.5
end
-- A wrapping string is as many rows as its width needs; one that may not wrap is one row.
function METHODS:GetStringHeight()
	local fh = self.fontHeight or 12
	if self.wrap == false or not self.w or self.w <= 0 then
		return fh
	end
	return math.max(1, math.ceil(self:GetStringWidth() / self.w)) * fh
end
function METHODS:IsTruncated()
	return self.wrap == false and self.w ~= nil and self:GetStringWidth() > self.w
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
function METHODS:SetPoint(point, a, b, c, d)
	-- (point), (point, x, y), (point, rel, relPoint, x, y)
	local p = { point = point }
	if type(a) == "table" then
		p.rel, p.relPoint, p.x, p.y = a, b, c or 0, d or 0
	else
		p.x, p.y = a or 0, b or 0
	end
	self.points[#self.points + 1] = p
end
function METHODS:ClearAllPoints()
	self.points = {}
end
function METHODS:GetNumPoints()
	return #self.points
end
function METHODS:GetPoint(i)
	local p = self.points[i or 1]
	if not p then
		return nil
	end
	return p.point, p.rel, p.relPoint or p.point, p.x, p.y
end
-- Where a frame with one anchor sits: beside what it is anchored to, else on the screen's own corner.
function METHODS:GetLeft()
	local p = self.points[1]
	if not p then
		return self.left
	end
	local rel = p.rel
	if rel and rel.GetLeft and rel:GetLeft() then
		local right = tostring(p.relPoint or ""):find("RIGHT") ~= nil
		return rel:GetLeft() + (right and rel:GetWidth() or 0) + p.x
	end
	return (self.left or 0) + p.x
end
function METHODS:GetTop()
	local p = self.points[1]
	if not p then
		return self.top
	end
	local rel = p.rel
	if rel and rel.GetTop and rel:GetTop() then
		return rel:GetTop() + p.y
	end
	return (self.top or 768) + p.y
end
function METHODS:SetScript(name, fn)
	self.scripts[name] = fn
end
function METHODS:GetScript(name)
	return self.scripts[name]
end
function METHODS:SetColorTexture(r, g, b, a)
	self.color = { r, g, b, a }
end
function METHODS:SetRoundLayoutToNearestPixel(on)
	self.rounded = on
end
function METHODS:GetEffectiveScale()
	return 1
end
function METHODS:GetFrameLevel()
	return 1
end
function METHODS:IsOwned()
	return true
end
function METHODS:CreateTexture()
	local t = new("Texture", self)
	self.regions[#self.regions + 1] = t
	return t
end
function METHODS:CreateFontString()
	local t = new("FontString", self)
	self.regions[#self.regions + 1] = t
	return t
end
function METHODS:CreateMaskTexture()
	return new("MaskTexture", self)
end
function METHODS:CreateAnimationGroup()
	return new("AnimationGroup", self)
end
function METHODS:CreateAnimation()
	return new("Animation", self)
end
function METHODS:GetRegions()
	return unpack(self.regions)
end
function METHODS:GetChildren()
	return unpack(self.children)
end

local function fire(obj, script, ...)
	local fn = obj.scripts[script]
	assert(fn, "no script " .. script)
	return fn(obj, ...)
end

local PX = 1080 / 768 -- physical pixels per UI unit of the mock screen

local function whole(v)
	local p = v * PX
	return math.abs(p - math.floor(p + 0.5)) < 1e-6
end

local F = dofile("tests/fixtures.lua")

-- The addon's pure files, Widgets.lua and UI.lua over the mock. opts.strip: what the guide says (GuideUI.strip).
local function load(opts)
	opts = opts or {}
	frames, calls, tooltip, opened = {}, {}, nil, {}
	_G.CreateFrame = function(kind, name, parent, template)
		local f = new("Frame", parent)
		f.frameType, f.name, f.template = kind, name, template
		if parent and parent.children then
			parent.children[#parent.children + 1] = f
		end
		if name then
			_G[name] = f
		end
		frames[#frames + 1] = f
		return f
	end
	_G.UIParent = new("Frame")
	_G.UIParent.w, _G.UIParent.h, _G.UIParent.left, _G.UIParent.top = 1366, 768, 0, 768
	_G.GameTooltip = new("Frame")
	_G.GameTooltip.SetText = function(_, s)
		tooltip = s
	end
	_G.GameTooltip.Hide = function()
		tooltip = nil
	end
	_G.GetPhysicalScreenSize = function()
		return 1920, 1080
	end
	_G.GetCursorPosition = function()
		return opts.cursor or 0, 0
	end
	_G.SkillupHelperDB = nil
	_G.C_Item = {}
	_G.C_Texture = nil
	_G.C_TradeSkillUI = {
		GetRecipeInfo = function()
			return opts.learned and { learned = true } or nil
		end,
		GetCraftableCount = function()
			return opts.craftable or 0
		end,
	}
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "TSM.lua", "View.lua", "Where.lua", "Widgets.lua", "UI.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	ns.guard = function(_, fn, ...)
		return fn(...)
	end
	ns.Scan = {
		have = function()
			return 0
		end,
		itemName = function(item, fallback)
			return fallback or ("item " .. item)
		end,
	}
	ns.dockKind = opts.dock
	ns.GuideUI = opts.strip and {
		strip = function()
			return opts.strip
		end,
	} or nil
	ns.JournalUI = {
		open = function(page, c)
			opened[#opened + 1] = { page = page, profession = c and c.profession, step = c and c.step }
		end,
	}
	ns.MailUI = opts.mail and {
		queued = function()
			return false
		end,
	} or nil
	return ns
end

-- The window the panel is docked to: off the pixel grid on purpose.
local function window(h)
	local t = new("Frame")
	t.left, t.top, t.w, t.h = 100.37, 700.41, 800, h or 600
	return t
end

local function show(ns, model, h)
	local UI = ns.UI
	UI.create()
	UI.setShown(true, true)
	UI.dock(window(h), "tsm")
	UI.show(model)
	return UI.frame, UI.stats
end

--------------------------------------------------------------------------------------------------------- fixtures

local LONG = {
	"Green Iron Gauntlets of the Whale and of the Bear",
	"Dazzling Mithril Rapier of the Northern Marches",
	"Heavy Mithril Breastplate of the Sunken Temple",
	"Radiant Boots of the Blackrock Depths Quartermaster",
}

local function craft(spell, name, from, to, extra)
	local st = {
		kind = "craft",
		spell = spell,
		name = name,
		crafts = 40 + spell,
		from = from,
		to = to,
		points = to - from,
		color = "orange",
		used = {},
		buy = { { item = 2318, count = 6, each = 20, where = "ah" } },
	}
	for k, v in pairs(extra or {}) do
		st[k] = v
	end
	return st
end

local function plan(steps, extra)
	local p = { steps = steps, hold = {}, leftovers = {}, fromStock = {}, ageHours = 1, prices = {} }
	for k, v in pairs(extra or {}) do
		p[k] = v
	end
	return p
end

local function model(p, skill)
	return { profession = "Blacksmithing", professionID = 164, skill = skill or 28, maxSkill = 75, planner = p }
end

local SHOPPING = {
	order = { "trainer", "vendor", "ah" },
	trainer = { { kind = "train", name = LONG[1], skill = 28, step = 1 } },
	vendor = { { item = 2320, name = "Coal", count = 4, price = 10, merchant = "Supplies", step = 2 } },
	ah = { { item = 2318, name = "Iron Bar", count = 6, price = 20, kind = "reagent", step = 2 } },
}

-- A trip: go and train a recipe, with three stops on the shopping list, reagents on alts, the guide's two lines,
-- and three next lines whose names need two rows each.
local function trip()
	return model(plan({
		{ kind = "train", spell = 1, name = LONG[1], at = 28, cost = 100, unchecked = true },
		craft(1, LONG[1], 28, 90),
		craft(2, LONG[2], 90, 150),
		craft(3, LONG[3], 150, 185),
		{ kind = "gap", from = 185, to = 215, why = "only a recipe to buy gives skill here, and that is turned off" },
		craft(4, LONG[4], 215, 300),
	}, { shopping = SHOPPING, mail = { { who = "Alt", item = 2318, count = 3 } }, profKey = "Blacksmithing" }))
end

local GUIDE = {
	phase = "far",
	icon = "arrow",
	a = "Bengus Deepforge, The Great Forge in Ironforge, at the anvils beside the lava",
	ar = "1,240 yd",
	b = "May teach " .. LONG[1] .. ": not checked yet. Then: vendor",
	tip = "Click: pin on the map.",
}

-- A craft step with everything a card can carry: five reagents to buy, something to craft first, notes, mail from
-- alts, Craft and Show recipe.
local function heavy()
	local buy = {}
	for i = 1, 5 do
		buy[i] = { item = 100 + i, count = 10 * i, each = 25, where = i % 2 == 0 and "ah" or "vendor" }
	end
	local first = craft(1, LONG[1], 28, 90, {
		buy = buy,
		used = { { item = 2318, count = 3, mail = { { who = "Alt", count = 3 } } } },
		pre = { { item = 7, count = 3 } },
		rankUp = { name = "Journeyman", at = 50, by = 75 },
		expected = 30,
		costPt = 12,
	})
	return model(plan({
		first,
		{ kind = "trainRank", name = "Journeyman", cap = 150, at = 50, by = 75, cost = 500, skill = 50 },
		craft(2, LONG[2], 90, 150),
		craft(3, LONG[3], 150, 185),
		craft(4, LONG[4], 185, 300),
	}, { shopping = SHOPPING, mail = { { who = "Alt", item = 2318, count = 3 } }, profKey = "Blacksmithing" }))
end

local function cooking(ns)
	local have = { [F.ITEM.LION] = 7, [F.ITEM.BEAR] = 1 }
	local input = F.cooking()
	input.have = have
	local p = ns.Planner.run(input)
	p.prices, p.ageHours = { live = 10, export = 0, none = 0 }, 2
	return { profession = "Cooking", professionID = 185, skill = 173, maxSkill = 225, planner = p }
end

local function shownRows(f)
	local out = {}
	for _, row in ipairs(f.nextRows) do
		if row:IsShown() then
			out[#out + 1] = row
		end
	end
	return out
end

------------------------------------------------------------------------------------------------------------ specs

describe("Action bar", function()
	local V
	before_each(function()
		V = load().View
	end)

	local function ids(row)
		local out = {}
		for _, a in ipairs(row) do
			out[#out + 1] = a.id
		end
		return table.concat(out, ",")
	end

	it("puts mail and Buy on rows of their own above Craft and Show recipe", function()
		local card = {
			actions = {
				{ id = "mailQueue", label = "Queue mail" },
				{ id = "buy", label = "Buy" },
				{ id = "craft", label = "Craft 3" },
				{ id = "open", label = "Show recipe" },
			},
		}
		local rows = V.actionBar(card)
		assert.same({ "mailQueue", "buy", "craft,open" }, { ids(rows[1]), ids(rows[2]), ids(rows[3]) })
	end)

	it("leaves out empty rows and has no bar without actions", function()
		local rows = V.actionBar({ actions = { { id = "craft" } } })
		assert.equal(1, #rows)
		assert.equal("craft", ids(rows[1]))
		assert.is_nil(V.actionBar({}))
		assert.is_nil(V.actionBar({ actions = {} }))
	end)
end)

describe("The docked panel never scrolls", function()
	local fixtures = {
		cooking = function(ns)
			return cooking(ns)
		end,
		trip = trip,
		heavy = heavy,
		message = function()
			return { why = "Open a profession window", state = "not now" }
		end,
		atCap = function()
			return model(plan({}), 75)
		end,
		legacy = function()
			return {
				profession = "Cooking",
				skill = 10,
				maxSkill = 75,
				craftsLeft = 4,
				step = { recipe = "Spice Bread", spell = 5, from = 10, to = 40, yellow = 30, grey = 50, cost = 120 },
				shopping = { { item = 1, name = "Flour", have = 1, need = 4, short = 3 } },
				fromStock = { { name = "Bread", crafts = 3, color = "green" } },
			}
		end,
	}

	for name, make in pairs(fixtures) do
		it("creates no scroll frame, slider, mouse wheel or clip area: " .. name, function()
			local ns = load({ strip = GUIDE, learned = true, craftable = 2, dock = "blizzard", mail = true })
			local f, stats = show(ns, make(ns), 600)
			-- a second draw of the same model, as every refresh does
			ns.UI.show(make(ns))
			assert.is_true(#frames > 0)
			for _, fr in ipairs(frames) do
				assert.is_nil(tostring(fr.frameType):find("Scroll"), fr.frameType)
				assert.not_equal("Slider", fr.frameType)
				assert.not_equal("EditBox", fr.frameType)
				assert.is_nil(tostring(fr.template or ""):find("Scroll"), tostring(fr.template))
				assert.is_nil(fr.scripts.OnMouseWheel)
				assert.is_nil(fr.scripts.OnVerticalScroll)
			end
			assert.same({}, calls)
			assert.is_nil(f.scroll)
			assert.is_nil(f.tabs)
			-- as tall as what it shows (on whole pixels), within the window beside it
			assert.is_false(stats.fit.overflow)
			assert.is_true(f:GetHeight() <= 600)
			assert.near(stats.fit.height, f:GetHeight(), 0.5 / PX + 1e-9)
			assert.is_true(whole(f:GetHeight()))
			assert.is_true(stats.fit.laid <= stats.fit.height)
			assert.equal("glance", stats.layout)
		end)
	end

	it("the panel's own frames stop growing: a second draw creates nothing", function()
		local ns = load({ strip = GUIDE, learned = true, craftable = 2, dock = "blizzard", mail = true })
		show(ns, heavy(), 600)
		local n = #frames
		ns.UI.show(heavy())
		ns.UI.show(heavy())
		assert.equal(n, #frames)
	end)
end)

describe("Worst case", function()
	it("a trip with three stops, both links, the guide's two lines and three two-row next lines fits whole", function()
		local ns = load({ strip = GUIDE, mail = true })
		local f, stats = show(ns, trip(), 600)
		local d = ns.UI.last
		assert.equal("Train " .. LONG[1], d.now.title)
		assert.same(
			{ "Shopping: 1s 60c, 3 stops, 1 price unknown", "3 reagents on your other characters, not queued" },
			{ d.now.links[1].text, d.now.links[2].text }
		)
		assert.equal(0, stats.bar.rows) -- a training step has no button: the guide's strip says where to go
		-- nothing was left out, and it is inside the window
		assert.same({}, stats.fit.dropped)
		assert.is_false(stats.fit.overflow)
		assert.is_true(stats.fit.height <= 600)
		assert.equal(stats.fit.content, stats.fit.height)
		assert.equal(stats.fit.laid, stats.fit.height)
		local rows = shownRows(f)
		assert.equal(3, #rows)
		for _, row in ipairs(rows) do
			-- two rows of title, wrapped; never cut
			assert.equal(24, row.title:GetStringHeight())
			assert.is_false(row.title:IsTruncated())
			assert.is_false(row.meta:IsTruncated())
			assert.is_true(row:GetHeight() >= 24 + 10)
		end
		-- the guide's strip wraps too
		local card = f.cards[f.current]
		assert.is_true(card.guide:IsShown())
		assert.is_false(card.guide.a:IsTruncated())
		assert.is_true(card.guide.a:GetStringHeight() > 11)
		assert.is_true(card.guide.b:GetStringHeight() > 10)
		assert.is_false(card.title:IsTruncated())
	end)

	it(
		"the heaviest card in a short window leaves whole pieces out, last first, and still does not overflow",
		function()
			local ns = load({ strip = GUIDE, learned = true, craftable = 2, dock = "blizzard", mail = true })
			-- five lines on the card, both links, the guide's two lines, three rows of buttons, a rank line and two
			-- two-row next lines: all of it shows beside a window of 700
			local f, stats = show(ns, heavy(), 700)
			assert.same({}, stats.fit.dropped)
			assert.equal(stats.fit.content, stats.fit.height)
			assert.equal(3, stats.bar.rows) -- Queue mail; Buy; Craft with Show recipe
			assert.equal(5, stats.views.lines)
			assert.equal(3, #shownRows(f))
			local content = stats.fit.content
			-- beside a window of 600 the third next line is left out whole, and the button counts it
			ns.UI.dock(window(600), "tsm")
			stats = ns.UI.stats
			assert.is_true(content > 600)
			assert.same({ "next3" }, stats.fit.dropped)
			assert.is_false(stats.fit.overflow)
			assert.is_true(f:GetHeight() <= 600)
			assert.equal(stats.fit.laid, stats.fit.height)
			assert.is_false(f.nextRows[3]:IsShown())
			assert.is_true(f.nextRows[1]:IsShown() and f.nextRows[2]:IsShown())
			assert.is_true(f.journalButton:IsShown())
			-- shorter still: the note goes before the second next line, the first stays to the end
			ns.UI.dock(window(content - 95), "tsm")
			stats = ns.UI.stats
			assert.same({ "next2", "note", "next3" }, stats.fit.dropped)
			assert.is_false(stats.fit.overflow)
			assert.is_true(f:GetHeight() <= content - 95)
			assert.equal(stats.fit.laid, stats.fit.height)
			assert.equal(1, #shownRows(f))
			-- "First craft" is not a note: it stays on the card
			local texts = {}
			for _, fs in ipairs(f.cards[f.current].lines) do
				if fs:IsShown() then
					texts[#texts + 1] = fs:GetText()
				end
			end
			assert.equal("First craft 3 item 7", texts[#texts])
			assert.equal(4, #texts)
		end
	)

	it("a button whose label is too long for it wraps and grows", function()
		local ns = load({ learned = true, craftable = 0, dock = "blizzard" })
		ns.Scan.itemName = function()
			return "Enchanted Thorium Bar of the Deep Forge"
		end
		local f = show(ns, heavy(), 600)
		local craftButton, open
		for _, b in ipairs(f.actions.buttons) do
			if b:IsShown() and b.action.id == "craft" then
				craftButton = b
			elseif b:IsShown() and b.action.id == "open" then
				open = b
			end
		end
		-- nothing craftable: the button says what to do first, beside Show recipe, in two rows
		assert.equal("Buy 10 Enchanted Thorium Bar of the Deep Forge first", craftButton.label:GetText())
		assert.is_false(craftButton.label:IsTruncated())
		assert.equal(24, craftButton.label:GetStringHeight())
		assert.equal(32, craftButton:GetHeight())
		assert.equal(32, open:GetHeight())
		for _, b in ipairs(f.actions.buttons) do
			assert.is_false(b.label:IsTruncated())
		end
	end)
end)

describe("Next lines", function()
	it("are numbered on from the card, whole, and open their step in the journal", function()
		local ns = load({})
		local f = show(ns, trip(), 600)
		local rows = shownRows(f)
		local numbers = {}
		for i, row in ipairs(rows) do
			local text = row.title:GetText() .. " " .. (row.meta:GetText() or "")
			assert.is_nil(text:find("…", 1, true))
			assert.is_nil(text:find("...", 1, true))
			assert.is_nil(text:lower():find("shortcut", 1, true))
			assert.is_nil(row.n:GetText():find("…", 1, true))
			numbers[i] = tonumber(row.n:GetText())
		end
		assert.same({ 1, 2, 3 }, numbers)
		assert.equal("Craft 41 " .. LONG[1], rows[1].title:GetText())
		assert.equal("28 to 90, 1s 20c", rows[1].meta:GetText())
		fire(rows[2], "OnClick", "LeftButton")
		assert.same({ page = "path", profession = 164, step = 3 }, opened[1])
		-- the rest is the journal's, and the button says how much there is
		assert.equal("Open the journal: 2 more steps", f.journalButton.label:GetText())
		fire(f.journalButton, "OnClick")
		assert.same({ page = "path", profession = 164, step = 1 }, opened[2])
		-- a link line opens its page
		fire(f.cards[f.current].links[1], "OnClick")
		assert.same({ page = "shopping", profession = 164 }, opened[3])
		assert.equal(3, ns.UI.stats.clicks.journal)
	end)

	it("says why when the journal is not there, instead of failing", function()
		local ns = load({})
		local f = show(ns, trip(), 600)
		ns.JournalUI = nil
		fire(f.journalButton, "OnClick")
		assert.matches("JournalUI is not loaded", ns.UI.stats.journalWhy)
	end)
end)

describe("Path strip", function()
	it("covers 1 to 300 edge to edge on whole pixels, with the now-marker inside", function()
		local ns = load({})
		local f, stats = show(ns, trip(), 600)
		local s = f.path
		local strip = ns.UI.last.strip
		assert.equal(#strip.segments, stats.views.strip.segments)
		local width = s:GetWidth()
		local at = 0
		for i, seg in ipairs(strip.segments) do
			local t = s.segs[i]
			assert.is_true(t:IsShown())
			local x = t.points[1].x
			-- each starts where the last one's share ended, in order, and on a whole pixel
			assert.near(seg.x0 * width, x, 1 / PX)
			assert.is_true(x >= at)
			assert.is_true(whole(x), "segment " .. i .. " starts off the pixel grid")
			assert.is_true(whole(t:GetWidth()), "segment " .. i .. " is not whole pixels wide")
			assert.is_true(t:GetWidth() >= 1 / PX - 1e-9)
			at = x + t:GetWidth()
		end
		assert.same({ 1, 0 }, { strip.segments[1].from, strip.segments[1].x0 })
		assert.same({ 300, 1 }, { strip.segments[#strip.segments].to, strip.segments[#strip.segments].x1 })
		-- up to the pixel of track left after each segment
		assert.near(width, at, 2 / PX)
		-- the hole has a solid edge on each side
		assert.equal(1, strip.gaps)
		assert.is_true(s.edges[1]:IsShown() and s.edges[2]:IsShown())
		assert.is_true(whole(s.edges[1]:GetWidth()))
		-- the now-marker sits inside the strip, at the skill
		local nowX = s.now.points[1].x
		assert.is_true(nowX >= 0 and nowX + s.now:GetWidth() <= width)
		assert.near(strip.now.x * width, nowX, 2 / PX)
		assert.is_true(whole(nowX))
		-- a tick at each rank cap, one pixel wide
		for i = 1, 3 do
			assert.is_true(s.ticks[i]:IsShown())
			assert.near(1 / PX, s.ticks[i]:GetWidth(), 1e-9)
		end
		assert.equal("5 steps to 300, 1 gap", s.caption:GetText())
	end)

	it("names the line under the cursor and opens it on a click", function()
		local ns = load({})
		local f = show(ns, trip(), 600)
		local s = f.path
		-- the cursor at skill 200: in the hole
		local opts = (200 - 1) / 299 * s:GetWidth() + s:GetLeft()
		_G.GetCursorPosition = function()
			return opts, 0
		end
		fire(s, "OnEnter")
		fire(s, "OnUpdate", 0.1)
		assert.matches("^4%. No recipe from 185 to 215\nOnly a recipe to buy gives skill here", tooltip)
		fire(s, "OnClick")
		assert.same({ page = "path", profession = 164, step = 5 }, opened[1])
		fire(s, "OnLeave")
		assert.is_nil(s.scripts.OnUpdate)
		assert.is_nil(tooltip)
	end)
end)

describe("Pixels", function()
	it("snaps the panel after it is docked and rounds every region it made", function()
		local ns = load({ strip = GUIDE, mail = true })
		local f, stats = show(ns, trip(), 600)
		-- the window it stands beside is off the grid; the panel is not
		assert.is_false(whole(100.37 + 800 + 2))
		assert.is_true(whole(f:GetLeft()), "left " .. f:GetLeft())
		assert.is_true(whole(f:GetTop()), "top " .. f:GetTop())
		assert.is_true(whole(f:GetHeight()))
		assert.is_true(whole(f:GetWidth()))
		assert.is_true(stats.snapped >= 1)
		assert.is_nil(stats.snapWhy)
		assert.is_true(ns.Widgets.pixel.snaps >= 1)
		assert.is_true(ns.Widgets.pixel.moved >= 1)
		-- it stays anchored to the window, so it follows it
		assert.equal(1, f:GetNumPoints())
		-- the window moved by a fraction of a pixel: the next look at the dock puts the panel back on the grid
		local target = f.points[1].rel
		target.left = 250.11
		ns.UI.dock(target, "tsm")
		assert.is_true(whole(f:GetLeft()))
		local function check(o)
			assert.is_true(o.rounded, o.kind .. " does not round its layout")
			for _, r in ipairs(o.regions) do
				assert.is_true(r.rounded, r.kind .. " does not round its layout")
			end
			for _, c in ipairs(o.children) do
				check(c)
			end
		end
		check(f)
	end)

	it("a drag ends on whole pixels and the place is kept", function()
		local ns = load({})
		_G.SkillupHelperDB = {}
		local UI = ns.UI
		UI.create()
		UI.setShown(true, true)
		UI.dock(nil, nil)
		local f = UI.frame
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 211.3, -90.7)
		fire(f, "OnDragStop")
		assert.is_true(whole(f:GetLeft()))
		assert.is_true(whole(f:GetTop()))
		local at = _G.SkillupHelperDB.ui.panelPoint
		assert.equal("TOPLEFT", at[1])
		assert.is_true(whole(at[2]) and whole(at[3]))
		_G.SkillupHelperDB = nil
	end)
end)

describe("AH list", function()
	it("pages a long list: five rows, Previous and Next, never a scroll bar", function()
		local ns = load({})
		local UI = ns.UI
		UI.ah.open = true
		UI.ah.list = {}
		for i = 1, 12 do
			UI.ah.list[i] = { item = 100 + i, name = "Thing " .. i, count = 2, each = 50 }
		end
		UI.ahDraw()
		local f = UI.ahFrame
		local function count()
			local n = 0
			for _, row in ipairs(f.rows) do
				n = n + (row:IsShown() and 1 or 0)
			end
			return n
		end
		assert.equal(5, count())
		assert.equal("1 to 5 of 12", f.pager.text:GetText())
		assert.equal("Thing 1 x2", f.rows[1].name:GetText())
		assert.is_false(f.pager.prev.action.enabled)
		fire(f.pager.next, "OnClick")
		assert.equal("6 to 10 of 12", f.pager.text:GetText())
		assert.equal("Thing 6 x2", f.rows[1].name:GetText())
		fire(f.pager.next, "OnClick")
		assert.equal(2, count())
		assert.is_false(f.pager.next.action.enabled)
		-- a refused click changes nothing
		fire(f.pager.next, "OnClick")
		assert.equal("11 to 12 of 12", f.pager.text:GetText())
		-- the list shrank: the page follows, and a list that fits has no pager
		UI.ah.list = { UI.ah.list[1], UI.ah.list[2] }
		UI.ahDraw()
		assert.equal(2, count())
		assert.is_false(f.pager:IsShown())
		for _, fr in ipairs(frames) do
			assert.is_nil(tostring(fr.frameType):find("Scroll"))
			assert.is_nil(tostring(fr.template or ""):find("Scroll"))
		end
		assert.same({}, calls)
	end)
end)

describe("Secret values from the vendor and the bags", function()
	local SECRET = {}
	local NAMES = {
		"issecretvalue",
		"GetMerchantNumItems",
		"GetMerchantItemID",
		"GetMerchantItemMaxStack",
		"GetMerchantFilter",
		"C_MerchantFrame",
		"C_Container",
		"NUM_BAG_SLOTS",
		"NUM_TOTAL_EQUIPPED_BAG_SLOTS",
	}
	local saved

	before_each(function()
		saved = {}
		for _, k in ipairs(NAMES) do
			saved[k] = rawget(_G, k)
		end
	end)

	after_each(function()
		for _, k in ipairs(NAMES) do
			rawset(_G, k, saved[k])
		end
	end)

	local function client(info, stack, free)
		_G.issecretvalue = function(v)
			return v == SECRET
		end
		_G.GetMerchantNumItems = function()
			return 1
		end
		_G.GetMerchantItemID = function()
			return 2318
		end
		_G.GetMerchantItemMaxStack = function()
			return SECRET
		end
		_G.GetMerchantFilter = nil
		_G.C_MerchantFrame = {
			GetItemInfo = function()
				return info
			end,
		}
		_G.NUM_BAG_SLOTS, _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 0, 0
		_G.C_Container = {
			GetContainerNumFreeSlots = function()
				return free, 0
			end,
		}
		local ns = load({})
		ns.merchantOpen = true
		_G.C_Item.GetItemInfo = function()
			return nil, nil, nil, nil, nil, nil, nil, stack
		end
		_G.C_Item.GetItemCount = function()
			return SECRET
		end
		return ns
	end

	it("a secret vendor offer is not now, never an error", function()
		local ns = client({ price = 10, stackCount = SECRET, numAvailable = -1 }, 20, 1)
		local offer, why = ns.UI.merchantOffer(2318)
		assert.is_nil(offer)
		assert.matches("secret", why)
	end)

	it("a secret max stack is dropped from a readable offer", function()
		local ns = client({ price = 10, stackCount = 5, numAvailable = -1 }, 20, 1)
		local offer = ns.UI.merchantOffer(2318)
		assert.equal(5, offer.lot)
		assert.is_nil(offer.maxStack)
	end)

	it("a secret stack size makes the bag room unknown", function()
		local ns = client({}, SECRET, 1)
		assert.is_nil(ns.UI.bagRoom(2318))
	end)

	it("a secret free-slot count or bag count counts as nothing", function()
		local ns = client({}, 20, SECRET)
		assert.equal("number", type(ns.UI.bagRoom(2318)))
	end)
end)
