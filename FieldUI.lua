-- The small surfaces: the where-card (map, verb line, legs or stops, yields, next spot), the standalone field card
-- that holds it (SkillupHelperField) and the tracker (SkillupHelperTracker, 236 x 60). They draw view-models
-- (docs/ui.md) and answer "what now"; the journal holds the rest. Every frame here is insecure: GuideUI's secure
-- Target button is laid over F.targetAnchor() by its owner, out of combat.
local _, ns = ...
local W = ns.Widgets
local F = {}
ns.FieldUI = F
ns.Field = F

local CARD_W, MAP_W, MAP_H, PAD = 296, 292, 132, 10
local FIELD_W = 316
local TRACK_W, TRACK_H, TARGET_H = 236, 60, 26
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local ARROW_ATLAS, ARROW_FILE = "MiniMap-QuestArrow", "Interface\\Minimap\\MinimapArrow"
local TWO_PI = 2 * math.pi

F.stats = { cards = 0, fieldShows = 0, trackerShows = 0, ticks = 0 }

-- The saved state table (JournalUI.setState gives the SavedVariables one); plain fields only.
local function state(key)
	local s = W.state or {}
	W.state = s
	s[key] = s[key] or {}
	return s[key]
end

local function live(where, l)
	return W.live and W.live(where, l) or nil
end

---------------------------------------------------------------------------------------------------------- where-card

-- The card of one place: 296 wide with a 3-px left rule in the step colour. card:Set(where) -> height.
-- Reused by the standalone field card; the docked panel can parent one in its Plan tab (F.newCard(scrollChild)).
function F.newCard(parent)
	F.stats.cards = F.stats.cards + 1
	local card = W.card(parent, CARD_W, 200)
	local inner = CARD_W - 4 - 2 * PAD
	card.map = ns.MapCanvas.new(card, MAP_W, MAP_H, {
		onClick = function(map, button, pin)
			local where = map.where
			if not where then
				return
			end
			if button == "RightButton" then
				W.act({ id = "pin", where = where, pin = pin, enabled = true })
			else
				W.act({
					id = "journal",
					page = "where",
					spot = where.key,
					profession = where.profession,
					enabled = true,
				})
			end
		end,
		onLive = function(where, l)
			local s = live(where, l)
			card:Live(l, s)
			return s
		end,
	})
	card.map:SetPoint("TOPLEFT", 4, 0)
	card.verb = W.text(card, "GameFontHighlight", 12)
	card.gain = W.text(card, "GameFontHighlightSmall", 11)
	card.gain:SetJustifyH("RIGHT")
	card.legs = W.legs(card, inner)
	card.stops = W.stops(card, inner)
	card.rule1 = W.tex(card, "BORDER")
	card.rule1:SetHeight(1)
	W.fill(card.rule1, "line")
	card.yields = W.yields(card, inner)
	card.note = W.para(card, "GameFontHighlightSmall", 10, inner)
	card.empty = W.empty(card, inner)
	card.next = W.rowButton(card, 34)
	card.next:SetWidth(CARD_W - 4)
	card.next.line = W.tex(card.next, "BORDER")
	card.next.line:SetHeight(1)
	card.next.line:SetPoint("TOPLEFT")
	card.next.line:SetPoint("TOPRIGHT")
	W.fill(card.next.line, "line")
	card.next.tri = W.tex(card.next, "ARTWORK")
	card.next.tri:SetSize(7, 7)
	card.next.tri:SetPoint("TOPLEFT", PAD, -8)
	card.next.tri:SetTexture(W.ARROW)
	card.next.l1 = W.text(card.next, "GameFontHighlightSmall", 11)
	card.next.l1:SetPoint("TOPLEFT", PAD + 12, -5)
	card.next.l1:SetPoint("RIGHT", -PAD, 0)
	card.next.l2 = W.text(card.next, "GameFontHighlightSmall", 10)
	card.next.l2:SetPoint("TOPLEFT", PAD + 12, -19)
	card.next.l2:SetPoint("RIGHT", -PAD, 0)
	card.next.labels = { card.next.l1, card.next.l2 }

	-- The tick's part: the live leg distance and the position note, redrawn only when their text changes.
	function card:Live(l, s)
		local where = self.where
		if not where then
			return
		end
		local dist = s and s.dist or nil
		local done = l and l.legsDone
		local sig = tostring(dist) .. "|" .. tostring(done and #done) .. "|" .. tostring(l and l.ok)
		if sig == self.liveSig then
			return
		end
		self.liveSig = sig
		if where.kind == "errand" then
			self.stops:Set(where.stops, where.color, 4, dist)
		else
			self.legs:Set(where.travel, done, dist)
		end
		local hidden = l and not l.ok and l.why == "in an instance"
		W.set(
			self.note,
			hidden and (s and s.hidden or "Position hidden here (in an instance). It comes back outside.") or "",
			"ash"
		)
	end

	function card:Set(where)
		self.where, self.liveSig = where, nil
		if not where or where.empty then
			-- no place: a card without a map that names what is missing and keeps the step
			self.map:Hide()
			for _, x in ipairs({
				self.verb,
				self.gain,
				self.legs,
				self.stops,
				self.rule1,
				self.yields,
				self.note,
				self.next,
			}) do
				x:Hide()
			end
			self:Rule(where and where.color or nil)
			self.empty:ClearAllPoints()
			self.empty:SetPoint("TOPLEFT", 4 + PAD, -PAD)
			local h = self.empty:Set(where and where.empty or {
				title = "No place for this step",
				text = "This step needs no trip, or the plan has not been read yet.",
			})
			self:SetHeight(h + 2 * PAD)
			return h + 2 * PAD
		end
		self.empty:Hide()
		self:Rule(where.color or "bone")
		self.map:Show()
		self.map:Set(where)
		local x, y = 4 + PAD, MAP_H + 7
		self.gain:ClearAllPoints()
		self.gain:SetPoint("TOPRIGHT", -PAD, -y - 1)
		W.set(self.gain, where.verb and where.verb.gain or "", where.color or "bone")
		self.gain:Show()
		self.verb:ClearAllPoints()
		self.verb:SetPoint("TOPLEFT", x, -y)
		self.verb:SetPoint("RIGHT", self.gain, "LEFT", -6, 0)
		W.set(self.verb, where.verb and where.verb.text or where.title, "bone")
		self.verb:Show()
		y = y + 21
		local used
		if where.kind == "errand" then
			self.legs:Hide()
			self.stops:ClearAllPoints()
			self.stops:SetPoint("TOPLEFT", x, -y)
			used = self.stops:Set(where.stops, where.color, 4)
		else
			self.stops:Hide()
			self.legs:ClearAllPoints()
			self.legs:SetPoint("TOPLEFT", x, -y)
			used = self.legs:Set(where.travel)
		end
		y = y + used
		self.note:ClearAllPoints()
		self.note:SetPoint("TOPLEFT", x, -y - 2)
		W.set(self.note, "", "ash")
		self.note:Show()
		local hasYields = where.yields and where.yields.rows and #where.yields.rows > 0
		self.rule1:SetShown(hasYields and used > 0)
		if hasYields then
			y = y + 6
			self.rule1:ClearAllPoints()
			self.rule1:SetPoint("TOPLEFT", x, -y)
			self.rule1:SetWidth(inner)
			y = y + 2
			self.yields:ClearAllPoints()
			self.yields:SetPoint("TOPLEFT", x, -y)
			y = y + self.yields:Set(where.yields, 4)
		else
			self.yields:Hide()
		end
		local nx = where.next
		if nx then
			y = y + 6
			self.next:ClearAllPoints()
			self.next:SetPoint("TOPLEFT", 4, -y)
			self.next.action =
				{ id = "journal", page = "where", spot = nx.key, profession = where.profession, enabled = true }
			self.next.tri:SetVertexColor(W.rgb("ash"))
			W.set(self.next.l1, nx.text, "bone")
			W.set(self.next.l2, nx.sub, nx.tone or "ash")
			self.next:Show()
			y = y + 34
		else
			self.next:Hide()
			y = y + PAD
		end
		self.liveSig = nil -- the next tick repaints the live leg distance over the rows laid out above
		self:SetHeight(y)
		return y
	end
	return card
end

------------------------------------------------------------------------------------------------------- field card

local field

local function placeField()
	local s = state("field")
	field:ClearAllPoints()
	local t = F.trackerFrame
	if t and t:IsShown() then
		-- under the tracker (4 px gap), or above it when there is no room below
		local bottom = t:GetBottom()
		local scale = t:GetScale() or 1
		local extra = (t.target and t.target:IsShown()) and TARGET_H or 0
		if bottom and bottom * scale - extra < field:GetHeight() + 8 then
			field:SetPoint("BOTTOMLEFT", t, "TOPLEFT", 0, 4)
		else
			field:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -4 - extra)
		end
	elseif type(s.point) == "table" and s.point[1] then
		field:SetPoint(s.point[1], UIParent, s.point[1], s.point[2] or 0, s.point[3] or 0)
	else
		field:SetPoint("RIGHT", UIParent, "RIGHT", -120, 0)
	end
	-- on whole pixels wherever it lands (a saved point from before the snap, or beside a tracker)
	W.snap(field)
end

local function createField()
	field = W.frame("Frame", "SkillupHelperField", UIParent, "BackdropTemplate")
	field:SetSize(FIELD_W, 300)
	field:SetFrameStrata("MEDIUM")
	field:SetClampedToScreen(true)
	field:EnableMouse(true)
	field:SetMovable(true)
	field:RegisterForDrag("LeftButton")
	field:SetScript("OnDragStart", function(self)
		local t = F.trackerFrame
		if not (t and t:IsShown()) then
			self:StartMoving()
		end
	end)
	field:SetScript("OnDragStop", function(self)
		-- the saved point is the snapped one
		local p = W.dragStop(self)
		if p then
			state("field").point = p
		end
	end)
	field:SetBackdrop({ bgFile = W.WHITE, edgeFile = W.WHITE, edgeSize = 1 })
	field:SetBackdropColor(W.rgb("ink"))
	field:SetBackdropBorderColor(W.rgb("line"))
	field.title = W.text(field, "GameFontNormal", 13)
	field.title:SetPoint("TOPLEFT", 12, -12)
	field.skill = W.text(field, "GameFontHighlight", 13)
	field.skill:SetPoint("TOPRIGHT", -34, -12)
	field.skill:SetJustifyH("RIGHT")
	field.title:SetPoint("RIGHT", field.skill, "LEFT", -8, 0)
	field.fold = W.button(field, 22, 22)
	field.fold:SetPoint("TOPRIGHT", -5, -7)
	field.fold.style = "link"
	field.fold.tip = "Fold the card. A click on the tracker opens it again."
	field.fold.bar = W.tex(field.fold, "ARTWORK")
	field.fold.bar:SetSize(10, 2)
	field.fold.bar:SetPoint("CENTER", 0, -3)
	W.fill(field.fold.bar, "ash")
	field.fold.onClick = function()
		F.hide()
	end
	W.paintButton(field.fold)
	field.runway = W.band(field, FIELD_W - 24, 5)
	field.runway:Place("TOPLEFT", field, "TOPLEFT", 12, -34)
	field.card = F.newCard(field)
	field.card:SetPoint("TOPLEFT", 10, -46)
	field.buttons = W.pool(function()
		return W.button(field, 96, 24)
	end)
	field:SetScript("OnShow", function(self)
		F.stats.fieldShows = F.stats.fieldShows + 1
		W.snap(self)
	end)
	field:Hide()
end

local function drawField(vm)
	vm = vm or {}
	local where = vm.where
	local color = vm.color or (where and where.color) or "bone"
	W.set(field.title, vm.title or vm.profession or (where and where.profession) or "SkillupHelper", "gold")
	W.set(field.skill, vm.skill or "", "bone")
	-- the runway: the fraction to the next colour change when the model gives one, else a full rule in the colour
	local frac = type(vm.runway) == "number" and math.max(0, math.min(1, vm.runway)) or 1
	field.runway:Set({ { from = 0, to = frac, color = color } }, { lo = 0, hi = 1 })
	local h = field.card:Set(where)
	local actions = vm.actions or (where and where.actions) or {}
	local n = W.buttonRow(field.buttons, field, actions, 10, -(46 + h + 8), FIELD_W - 20, color)
	field:SetHeight(46 + h + (n > 0 and 41 or 10))
	placeField()
end

-- Shows the standalone card for a field view-model { title, skill, color, runway, where, actions }.
function F.show(vm)
	F.vm = vm or F.vm
	if not field then
		createField()
	end
	state("field").open = true
	drawField(F.vm)
	field:Show()
	return field
end

-- A new view-model without opening the card: drawn now if the card is shown, kept for the next open otherwise.
function F.update(vm)
	F.vm = vm
	if field and field:IsShown() then
		drawField(vm)
	end
end

function F.hide()
	state("field").open = false
	if field then
		field:Hide()
	end
end

function F.toggle()
	if field and field:IsShown() then
		F.hide()
	else
		F.show()
	end
end

function F.frame()
	return field
end

-------------------------------------------------------------------------------------------------------------- tracker

local tracker
local angleShown, angleGoal

local function shortArc(a)
	return (a + math.pi) % TWO_PI - math.pi
end

local function trackerMenu()
	local s = state("tracker")
	local vm = F.trackerVM or {}
	local ok, why = W.menu(tracker, {
		title = "SkillupHelper",
		items = {
			{ label = "Open the journal", action = { id = "journal", page = "where", spot = vm.key, enabled = true } },
			{ label = "Pin on the map", action = { id = "pin", tracker = true, key = vm.key, enabled = true } },
			{
				label = "Lock position",
				kind = "check",
				checked = s.locked == true,
				func = function()
					s.locked = not s.locked or nil
				end,
			},
			{ label = "Hide the tracker", action = { id = "setting", key = "tracker", value = false, enabled = true } },
		},
	})
	if not ok then
		F.stats.menuWhy = why
	end
end

local function createTracker()
	tracker = W.frame("Button", "SkillupHelperTracker", UIParent)
	F.trackerFrame = tracker
	tracker:SetSize(TRACK_W, TRACK_H)
	tracker:SetFrameStrata("MEDIUM")
	tracker:SetClampedToScreen(true)
	tracker:SetMovable(true)
	tracker:RegisterForDrag("LeftButton")
	tracker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	tracker.bg = W.tex(tracker, "BACKGROUND")
	tracker.bg:SetAllPoints()
	W.fill(tracker.bg, "ink", 0.92)
	tracker.edge = W.edges(tracker)
	W.paintEdges(tracker.edge, "line")
	tracker.rule = W.tex(tracker, "BORDER", 1)
	tracker.rule:SetWidth(3)
	tracker.rule:SetPoint("TOPLEFT")
	tracker.rule:SetPoint("BOTTOMLEFT")
	tracker.arrow = W.tex(tracker, "ARTWORK")
	tracker.arrow:SetSize(14, 14)
	tracker.arrow:SetPoint("TOPLEFT", 9, -7)
	W.atlas(tracker.arrow, ARROW_ATLAS, ARROW_FILE)
	tracker.arrow:SetDesaturated(true)
	tracker.right = W.text(tracker, "GameFontHighlightSmall", 11)
	tracker.right:SetPoint("TOPRIGHT", -8, -8)
	tracker.right:SetJustifyH("RIGHT")
	tracker.title = W.text(tracker, "GameFontHighlight", 12)
	tracker.title:SetPoint("TOPLEFT", 28, -8)
	tracker.title:SetPoint("RIGHT", tracker.right, "LEFT", -6, 0)
	tracker.gain = W.text(tracker, "GameFontHighlightSmall", 11)
	tracker.gain:SetPoint("TOPRIGHT", -8, -25)
	tracker.gain:SetJustifyH("RIGHT")
	tracker.sub = W.text(tracker, "GameFontHighlightSmall", 11)
	tracker.sub:SetPoint("TOPLEFT", 28, -25)
	tracker.sub:SetPoint("RIGHT", tracker.gain, "LEFT", -6, 0)
	tracker.mobs = W.text(tracker, "GameFontHighlightSmall", 11)
	tracker.mobs:SetPoint("BOTTOMRIGHT", -8, 7)
	tracker.mobs:SetJustifyH("RIGHT")
	tracker.band = W.band(tracker, 118, 4)
	tracker.band:Place("BOTTOMLEFT", tracker, "BOTTOMLEFT", 28, 10)
	tracker.ticks = W.pool(function()
		return W.tex(tracker, "ARTWORK", 3)
	end)
	-- the Target row: a drawn button only. The secure button belongs to GuideUI and is laid over this frame.
	tracker.target = W.frame("Frame", nil, tracker)
	tracker.target:SetSize(TRACK_W, TARGET_H)
	tracker.target:SetPoint("TOPLEFT", tracker, "BOTTOMLEFT", 0, 0)
	tracker.target.bg = W.tex(tracker.target, "BACKGROUND")
	tracker.target.bg:SetAllPoints()
	tracker.target.edge = W.edges(tracker.target)
	tracker.target.star = W.tex(tracker.target, "ARTWORK")
	tracker.target.star:SetSize(14, 14)
	tracker.target.star:SetPoint("LEFT", 9, 0)
	tracker.target.star:SetTexture(STAR)
	tracker.target.label = W.text(tracker.target, "GameFontHighlight", 12)
	tracker.target.label:SetPoint("LEFT", 28, 0)
	tracker.target.label:SetPoint("RIGHT", -8, 0)
	tracker.target:Hide()

	tracker:SetScript("OnDragStart", function(self)
		if not state("tracker").locked then
			self:StartMoving()
		end
	end)
	tracker:SetScript("OnDragStop", function(self)
		-- the saved point is the snapped one
		local p = W.dragStop(self)
		if p then
			state("tracker").point = p
		end
		if field and field:IsShown() then
			placeField()
		end
	end)
	tracker:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			trackerMenu()
		else
			F.toggle()
		end
	end)
	tracker:SetScript("OnEnter", function(self)
		W.fill(self.bg, "surface", 0.96)
		W.showTip(self, W.tipOf(self, self.title, self.sub) or self.hint)
	end)
	tracker:SetScript("OnLeave", function(self)
		W.fill(self.bg, "ink", 0.92)
		W.hideTip(self)
	end)
	-- While shown: the arrow eases every frame (one setter); every 0.1 s one provider call for the live strings.
	-- Hidden, the script does not run.
	local acc = 0
	tracker:SetScript("OnUpdate", function(self, elapsed)
		elapsed = elapsed or 0
		if angleGoal and self.arrow:IsShown() then
			angleShown = angleShown or angleGoal
			angleShown = (angleShown + shortArc(angleGoal - angleShown) * math.min(1, elapsed * 12)) % TWO_PI
			self.arrow:SetRotation(angleShown)
		end
		acc = acc + elapsed
		if acc >= 0.1 then
			acc = 0
			F.trackerTick()
		end
	end)
	local s = state("tracker")
	if type(s.point) == "table" and s.point[1] then
		tracker:SetPoint(s.point[1], UIParent, s.point[1], s.point[2] or 0, s.point[3] or 0)
	else
		tracker:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -260, -220)
	end
	-- a point saved before the snap existed (or at another UI scale) is put on whole pixels, now and at each show
	W.snap(tracker)
	tracker:SetScript("OnShow", function(self)
		W.snap(self)
	end)
	tracker:Hide()
end

local TICK_TONE = { done = "green", visited = "green", next = nil, todo = "line" }

local function drawBar(vm)
	local bar, color = vm.bar, vm.color or "bone"
	W.start(tracker.ticks)
	local function plain(done, total, tone)
		local frac = total > 0 and done / total or 0
		tracker.band:Set({ { from = 0, to = frac, color = tone } }, { lo = 0, hi = 1 })
	end
	if not bar then
		tracker.band:Hide()
	elseif bar.kind == "band" then
		tracker.band:Set(bar.segs, bar.axis, bar.skill)
	elseif bar.kind == "ticks" then
		local ticks = bar.ticks or {}
		if #ticks > 20 then
			-- too many stops for one tick each: a plain progress bar
			local done = 0
			for _, t in ipairs(ticks) do
				if t.state == "done" or t.state == "visited" then
					done = done + 1
				end
			end
			plain(done, #ticks, "green")
		else
			tracker.band:Hide()
			for i, t in ipairs(ticks) do
				local x = W.take(tracker.ticks)
				x:ClearAllPoints()
				-- other-floor ticks stand 3 px higher; the next stop is taller as well as coloured
				x:SetPoint("BOTTOMLEFT", tracker, "BOTTOMLEFT", 28 + (i - 1) * 8, 10 + (t.raised and 3 or 0))
				x:SetSize(6, t.state == "next" and 6 or 4)
				W.fill(x, t.state == "next" and color or TICK_TONE[t.state] or "line")
				x:Show()
			end
		end
	elseif bar.kind == "steps" then
		tracker.band:Hide()
		local total = math.max(1, math.min(bar.total or 1, 12))
		local wd = math.floor((118 - (total - 1) * 2) / total)
		for i = 1, total do
			local x = W.take(tracker.ticks)
			x:ClearAllPoints()
			x:SetPoint("BOTTOMLEFT", tracker, "BOTTOMLEFT", 28 + (i - 1) * (wd + 2), 10)
			x:SetSize(wd, i <= (bar.done or 0) and 4 or 2)
			W.fill(x, i <= (bar.done or 0) and "gold" or "line")
			x:Show()
		end
	else
		tracker.band:Hide()
	end
	W.finish(tracker.ticks)
end

local function drawTarget(vm)
	local t = tracker.target
	if not vm.target then
		t:Hide()
		return
	end
	local fight = InCombatLockdown and InCombatLockdown()
	local color = vm.color or "bone"
	W.fill(t.bg, fight and "line" or color, fight and 0.25 or 0.18)
	W.paintEdges(t.edge, fight and "line" or color, 0.8)
	W.set(t.label, fight and "Target after the fight" or vm.target.label or vm.target.name, fight and "ash" or "bone")
	t:Show()
end

local function drawTracker(vm)
	local color = vm.color or "bone"
	W.fill(tracker.rule, color)
	W.set(tracker.title, vm.title, "bone")
	W.set(tracker.right, vm.right, vm.rightTone or "bone")
	W.set(tracker.sub, vm.sub, "ash")
	W.set(tracker.gain, vm.gain or "", vm.gainTone or "bone")
	W.set(tracker.mobs, vm.mobs and vm.mobs.label or "", vm.mobs and vm.mobs.tone or "bone")
	tracker.arrow:SetVertexColor(W.rgb(color))
	tracker.arrow:SetShown(vm.arrow ~= false)
	tracker.hint = "Click: the card. Right click: more."
	drawBar(vm)
	drawTarget(vm)
end

-- Shows the tracker for a tracker view-model (spec 7.2); nil hides it.
function F.setTracker(vm)
	F.trackerVM = vm
	if not vm then
		if tracker then
			tracker:Hide()
		end
		return
	end
	if not tracker then
		createTracker()
	end
	drawTracker(vm)
	if not tracker:IsShown() then
		F.stats.trackerShows = F.stats.trackerShows + 1
		tracker:Show()
	end
	return tracker
end

-- The live row: provider.trackerLive() -> { title, right, rightTone, angle, ticks } (all optional) at 10 Hz.
function F.trackerTick()
	local vm = F.trackerVM
	if not (vm and tracker) then
		return
	end
	F.stats.ticks = F.stats.ticks + 1
	local s = W.trackerLive and W.trackerLive(vm)
	if type(s) ~= "table" then
		return
	end
	if s.title then
		W.set(tracker.title, s.title, "bone")
	end
	if s.right then
		W.set(tracker.right, s.right, s.rightTone or vm.rightTone or "bone")
	end
	if type(s.angle) == "number" then
		angleGoal = s.angle % TWO_PI
	end
	if s.ticks and vm.bar and vm.bar.kind == "ticks" then
		vm.bar.ticks = s.ticks
		drawBar(vm)
	end
	-- the Target row's wording follows combat; the secure button itself is GuideUI's business
	if vm.target then
		drawTarget(vm)
	end
end

-- Where GuideUI lays its secure Target button: the drawn Target row under the tracker (236 x 26), or nil when the
-- tracker has none. Out of combat only: SkillupHelperGuideTarget:SetAllPoints(F.targetAnchor()).
function F.targetAnchor()
	if tracker and tracker.target:IsShown() then
		return tracker.target
	end
	return nil
end

function F.diag()
	return {
		cards = F.stats.cards,
		fieldShown = field ~= nil and field:IsShown() or false,
		fieldShows = F.stats.fieldShows,
		trackerShown = tracker ~= nil and tracker:IsShown() or false,
		trackerShows = F.stats.trackerShows,
		ticks = F.stats.ticks,
		menuWhy = F.stats.menuWhy,
		map = field and field.card.map:Stats() or nil,
	}
end

------------------------------------------------------------------------------------------------------ minimap button

-- One button on the minimap's edge (no LibDBIcon: nothing is vendored). Left click toggles the journal, right click
-- opens a menu, a left drag moves it around the edge. The angle and the hidden flag are saved in
-- SkillupHelperDB.ui.minimap = { angle, hide }. What a click does and what the tooltip says come from
-- F.minimapProvider = { toggle(), menu() -> W.menu's table, tip() -> lines } (Journal.lua sets it): this file only
-- draws. The frame is insecure and a child of Minimap (Blizzard_Minimap/Mainline/Minimap.xml: no protected
-- attribute), so it may be shown, hidden and moved in combat.
local MM_SIZE, MM_PAD, MM_ANGLE = 31, 5, 215
local MM_ICON = "Interface\\Icons\\Trade_LeatherWorking" -- the TOC's IconTexture
local MM_BORDER = "Interface\\Minimap\\MiniMap-TrackingBorder"
local MM_HIGHLIGHT = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local MM_HINT = "Left-click: journal. Right-click: menu. Drag: move."

-- LibDBIcon's table: per minimap shape, which quadrants are round ({ bottom-right, bottom-left, top-right,
-- top-left }). GetMinimapShape is a global that addons which reshape the minimap define; absent means "ROUND".
F.MINIMAP_SHAPES = {
	ROUND = { true, true, true, true },
	SQUARE = { false, false, false, false },
	["CORNER-TOPLEFT"] = { false, false, false, true },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
	["SIDE-LEFT"] = { false, true, false, true },
	["SIDE-RIGHT"] = { true, false, true, false },
	["SIDE-TOP"] = { false, false, true, true },
	["SIDE-BOTTOM"] = { true, true, false, false },
	["TRICORNER-TOPLEFT"] = { false, true, true, true },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local mm
F.minimapStats = { clicks = 0 }

-- Pure. The button's offset from the minimap's centre for an angle in degrees (0 = east, counter-clockwise), the
-- minimap's half width and half height and its shape: on the circle of radius half + 5 in a round quadrant, on the
-- square's edge in a square one (LibDBIcon's rule).
function F.minimapOffset(angleDeg, halfW, halfH, shape)
	local a = math.rad(type(angleDeg) == "number" and angleDeg or MM_ANGLE)
	local x, y, q = math.cos(a), math.sin(a), 1
	if x < 0 then
		q = q + 1
	end
	if y > 0 then
		q = q + 2
	end
	local quads = type(shape) == "string" and F.MINIMAP_SHAPES[shape] or F.MINIMAP_SHAPES.ROUND
	halfW = type(halfW) == "number" and halfW or 0
	local w, h = halfW + MM_PAD, (type(halfH) == "number" and halfH or halfW) + MM_PAD
	if quads[q] then
		return x * w, y * h
	end
	local dw, dh = math.sqrt(2 * w * w) - 10, math.sqrt(2 * h * h) - 10
	return math.max(-w, math.min(x * dw, w)), math.max(-h, math.min(y * dh, h))
end

-- Pure. The angle in degrees (0 to 360) from the minimap's centre to the cursor. The cursor is in screen pixels
-- (GetCursorPosition), the centre in the minimap's own units, `scale` the minimap's effective scale (what
-- MinimapMixin:OnClick divides by). nil and the broken link when it cannot say.
function F.minimapAngle(cursorX, cursorY, centerX, centerY, scale)
	local function num(v)
		return not W.secret(v) and type(v) == "number"
	end
	if not (num(cursorX) and num(cursorY) and num(centerX) and num(centerY)) then
		return nil, "the cursor or the minimap's centre is not readable"
	end
	if not num(scale) or scale <= 0 then
		scale = 1
	end
	local dx, dy = cursorX / scale - centerX, cursorY / scale - centerY
	if dx == 0 and dy == 0 then
		return nil, "the cursor is on the minimap's centre"
	end
	return math.deg(math.atan2(dy, dx)) % 360
end

-- Pure. Where a tooltip goes so it stays on screen: its own point and the button's point, from the button's centre
-- and the screen's size in the same units (LibDBIcon's rule).
function F.minimapTipAnchor(x, y, screenW, screenH)
	if type(x) ~= "number" or type(y) ~= "number" or type(screenW) ~= "number" or type(screenH) ~= "number" then
		return "TOPRIGHT", "BOTTOMLEFT"
	end
	local h = x > screenW * 2 / 3 and "RIGHT" or (x < screenW / 3 and "LEFT" or "")
	local v = y > screenH / 2 and "TOP" or "BOTTOM"
	return v .. h, (v == "TOP" and "BOTTOM" or "TOP") .. h
end

local function mmState()
	local s = state("minimap")
	if type(s.angle) ~= "number" then
		s.angle = MM_ANGLE
	end
	s.hide = s.hide == true
	return s
end

local function minimapShape()
	local s = GetMinimapShape and GetMinimapShape() or "ROUND"
	if W.secret(s) or type(s) ~= "string" or not F.MINIMAP_SHAPES[s] then
		return "ROUND"
	end
	return s
end

-- Puts the button at its saved angle; the offsets are whole pixels.
function F.minimapPlace()
	if not (mm and Minimap) then
		return false
	end
	local shape = minimapShape()
	F.minimapStats.shape = shape
	local x, y = F.minimapOffset(mmState().angle, (Minimap:GetWidth() or 0) / 2, (Minimap:GetHeight() or 0) / 2, shape)
	mm:ClearAllPoints()
	mm:SetPoint("CENTER", Minimap, "CENTER", W.px(mm, x), W.px(mm, y))
	return true
end

-- The tooltip's lines: { title, line, ... }, a line a string or { text, tone } (the provider guards secrets).
function F.minimapTipLines()
	local p = F.minimapProvider
	local lines = p and p.tip and p.tip()
	if type(lines) ~= "table" or lines[1] == nil then
		lines = { "SkillupHelper", { MM_HINT, "ash" } }
	end
	return lines
end

-- Adds the lines to a tooltip (ours, or the one an LDB display hands to OnTooltipShow).
function F.minimapFillTip(tt)
	for i, l in ipairs(F.minimapTipLines()) do
		local s = type(l) == "table" and l[1] or l
		local r, g, b = W.rgb(i == 1 and "gold" or (type(l) == "table" and l[2] or "ash"))
		tt:AddLine(s, r, g, b, i > 1)
	end
end

local function showMinimapTip(self)
	if not GameTooltip then
		return
	end
	local x, y = self:GetCenter()
	local k = (self:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
	local point, relPoint = F.minimapTipAnchor(
		type(x) == "number" and x * k or nil,
		type(y) == "number" and y * k or nil,
		UIParent:GetWidth(),
		UIParent:GetHeight()
	)
	GameTooltip:SetOwner(self, "ANCHOR_NONE")
	GameTooltip:SetPoint(point, self, relPoint, 0, 0)
	F.minimapFillTip(GameTooltip)
	GameTooltip:Show()
end

-- A click, from the button or an LDB display: left toggles the journal, right opens the menu at `owner`.
function F.minimapClick(button, owner)
	F.minimapStats.clicks = F.minimapStats.clicks + 1
	local p = F.minimapProvider or {}
	if button == "RightButton" then
		local ok, why = W.menu(owner or mm or UIParent, p.menu and p.menu() or nil)
		F.minimapStats.why = not ok and why or nil
		return ok, why
	end
	if not p.toggle then
		F.minimapStats.why = "the journal is not wired to the button"
		return false, F.minimapStats.why
	end
	p.toggle()
	return true
end

local function dragTick()
	local cx, cy = GetCursorPosition()
	local mx, my = Minimap:GetCenter()
	local a, why = F.minimapAngle(cx, cy, mx, my, Minimap:GetEffectiveScale())
	if not a then
		F.minimapStats.why = why
		return
	end
	mmState().angle = math.floor(a * 10 + 0.5) / 10
	F.minimapPlace()
end

-- Makes the button (once). nil and the broken link when the client has no Minimap frame.
function F.minimapCreate()
	if mm then
		return mm
	end
	if not Minimap then
		F.minimapStats.why = "the Minimap frame is absent"
		return nil, F.minimapStats.why
	end
	mm = W.frame("Button", "SkillupHelperMinimapButton", Minimap)
	mm:SetSize(MM_SIZE, MM_SIZE)
	-- above the minimap and its own art, as LibDBIcon does; fixed, so a raise of the minimap does not bury it
	mm:SetFrameStrata("MEDIUM")
	mm:SetFrameLevel(8)
	if mm.SetFixedFrameStrata then
		mm:SetFixedFrameStrata(true)
	end
	if mm.SetFixedFrameLevel then
		mm:SetFixedFrameLevel(true)
	end
	mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	mm:RegisterForDrag("LeftButton")
	mm:SetHighlightTexture(MM_HIGHLIGHT, "ADD")
	-- LibDBIcon's layout: a 20-px icon inside the 53-px ring texture whose ring sits in its top-left 31 px
	mm.icon = W.tex(mm, "BACKGROUND")
	mm.icon:SetSize(20, 20)
	mm.icon:SetPoint("TOPLEFT", 7, -5)
	mm.icon:SetTexture(MM_ICON)
	mm.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	if mm.CreateMaskTexture and mm.icon.AddMaskTexture then
		mm.mask = mm:CreateMaskTexture()
		mm.mask:SetAllPoints(mm.icon)
		mm.mask:SetTexture(W.CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		mm.icon:AddMaskTexture(mm.mask)
	end
	mm.border = W.tex(mm, "OVERLAY")
	mm.border:SetSize(53, 53)
	mm.border:SetPoint("TOPLEFT")
	mm.border:SetTexture(MM_BORDER)

	mm:SetScript("OnClick", function(self, button)
		F.minimapClick(button, self)
	end)
	mm:SetScript("OnDragStart", function(self)
		self.dragging = true
		self:LockHighlight()
		if GameTooltip then
			GameTooltip:Hide()
		end
		self:SetScript("OnUpdate", dragTick)
	end)
	mm:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		dragTick() -- where the button was let go; the angle is already in the saved table
		self.dragging = false
		self:UnlockHighlight()
	end)
	mm:SetScript("OnEnter", function(self)
		if not self.dragging then
			showMinimapTip(self)
		end
	end)
	mm:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	return mm
end

-- Shows or hides the button and keeps the choice. Hidden is hidden, never destroyed.
function F.minimapSetShown(show)
	show = show and true or false
	mmState().hide = not show
	local b = F.minimapCreate()
	if not b then
		return false, F.minimapStats.why
	end
	if show then
		F.minimapPlace()
	end
	b:SetShown(show)
	return true
end

-- A LibDataBroker launcher when another addon brought LibDataBroker (it is not vendored here), so broker bars show
-- the same click and the same tooltip. Nothing is registered with LibDBIcon even when it is loaded: the button
-- above is the icon, and a second one would sit beside it.
function F.minimapPublish()
	if F.minimapLDB then
		return true
	end
	local ok, ldb = pcall(function()
		return LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
	end)
	if not (ok and type(ldb) == "table" and ldb.NewDataObject) then
		F.minimapStats.ldb = "LibDataBroker not loaded"
		return false, F.minimapStats.ldb
	end
	local made, obj = pcall(ldb.NewDataObject, ldb, "SkillupHelper", {
		type = "launcher",
		label = "SkillupHelper",
		icon = MM_ICON,
		OnClick = function(owner, button)
			F.minimapClick(button, owner)
		end,
		OnTooltipShow = function(tt)
			F.minimapFillTip(tt)
		end,
	})
	if not (made and obj) then
		F.minimapStats.ldb = "LibDataBroker refused the data object"
		return false, F.minimapStats.ldb
	end
	F.minimapLDB = obj
	F.minimapStats.ldb = "published"
	return true
end

-- At PLAYER_LOGIN, after the saved state is attached: one button, at its saved angle, hidden if the user hid it.
function F.minimapInit()
	local b = F.minimapCreate()
	if b then
		F.minimapPlace()
		b:SetShown(not mmState().hide)
	end
	F.minimapPublish()
	return b
end

function F.minimapButton()
	return mm
end

function F.minimapDiag()
	local s = mmState()
	return {
		created = mm ~= nil,
		shown = mm ~= nil and mm:IsShown() or false,
		angle = s.angle,
		hide = s.hide,
		shape = F.minimapStats.shape or minimapShape(),
		ldb = F.minimapStats.ldb or "not tried yet (before PLAYER_LOGIN)",
		clicks = F.minimapStats.clicks,
		why = F.minimapStats.why,
	}
end
