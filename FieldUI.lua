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
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		if point then
			state("field").point = { point, x, y }
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
	field:SetScript("OnShow", function()
		F.stats.fieldShows = F.stats.fieldShows + 1
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
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		if point then
			state("tracker").point = { point, x, y }
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
