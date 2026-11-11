-- The side panel: draws View.describe's description. A header with the skill and a runway bar to the next colour
-- change, the Next card (two of them, swapped when the skill passes a step), the later steps as compact rows and
-- quiet footer lines, in a scroll frame. Rows are pooled; frames are made only when a pool is short.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, INNER = 340, 296
local PAD = 12
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION = 134400 -- INV_Misc_QuestionMark

-- Panel diagnostics for the selftest.
UI.stats = { layout = "cards", animations = 0, played = {}, docks = {} }

local function count(kind)
	UI.stats.animations = UI.stats.animations + 1
	UI.stats.played[kind] = (UI.stats.played[kind] or 0) + 1
end

local function rgb(name)
	local c = ns.View.RGB[name] or ns.View.RGB.bone
	return c[1], c[2], c[3]
end

local function itemName(item, fallback)
	local plan = ns.Data and ns.Data.plan
	local info = plan and plan.items and plan.items[item]
	fallback = fallback or (info and info.name)
	return ns.Scan and ns.Scan.itemName(item, fallback) or fallback or ("item " .. item)
end

-- The env View.describe reads the client through.
function UI.env()
	return {
		nameOf = itemName,
		money = ns.Logic.money,
		have = function(item)
			return ns.Scan.have(item)
		end,
	}
end

local function text(parent, font, height, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFontObject(font)
	if height then
		fs:SetFontHeight(height)
	end
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(true)
	return fs
end

local function setColor(fs, name, alpha)
	local r, g, b = rgb(name)
	fs:SetTextColor(r, g, b, alpha or 1)
end

local function fill(tex, name, alpha)
	local r, g, b = rgb(name)
	tex:SetColorTexture(r, g, b, alpha or 1)
end

-- The icon of a step: the recipe's own icon, else its product's, else a question mark.
local function iconOf(card)
	if card.item and C_Item.GetItemIconByID then
		local icon = C_Item.GetItemIconByID(card.item)
		if icon then
			return icon
		end
	end
	if card.spell then
		local r = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(card.spell)
		if type(r) == "table" and r.icon and not (issecretvalue and issecretvalue(r.icon)) then
			return r.icon
		end
		local plan = ns.Data and ns.Data.plan
		for _, prof in pairs(plan and plan.professions or {}) do
			local row = prof.recipes and prof.recipes[card.spell]
			if row and row.makes and C_Item.GetItemIconByID then
				local icon = C_Item.GetItemIconByID(row.makes)
				if icon then
					return icon
				end
			end
		end
	end
	return QUESTION
end

---------------------------------------------------------------------------------------------------------- materials

-- A material row in a card: name left, have/need or buy line right. Its strike sweeps across and the row dips when
-- the bags drop between two refreshes of the same step, with the units gone floating off.
local function newMatRow(card)
	local row = CreateFrame("Frame", nil, card)
	row:SetSize(INNER - 2 * PAD, 16)
	row.name = text(row, "GameFontHighlightSmall", 11)
	row.name:SetPoint("TOPLEFT", 0, 0)
	row.name:SetWordWrap(false)
	row.right = text(row, "GameFontHighlightSmall", 11)
	row.right:SetPoint("TOPRIGHT", 0, 0)
	row.right:SetJustifyH("RIGHT")
	row.name:SetPoint("RIGHT", row.right, "LEFT", -8, 0)
	row.mark = row:CreateTexture(nil, "ARTWORK")
	row.mark:SetSize(3, 3)
	row.mark:SetPoint("RIGHT", row.name, "LEFT", -5, 0)

	row.strike = row:CreateTexture(nil, "OVERLAY")
	row.strike:SetHeight(1)
	row.strike:SetPoint("LEFT", row.name, "LEFT", 0, 0)
	row.strike:SetPoint("RIGHT", row.right, "RIGHT", 0, 0)
	fill(row.strike, "bone")
	row.strike:SetAlpha(0)
	local sg = row.strike:CreateAnimationGroup()
	local show = sg:CreateAnimation("Alpha")
	show:SetFromAlpha(1)
	show:SetToAlpha(1)
	show:SetDuration(0.2)
	show:SetOrder(1)
	local sweep = sg:CreateAnimation("Scale")
	sweep:SetOrigin("LEFT", 0, 0)
	sweep:SetScaleFrom(0.01, 1)
	sweep:SetScaleTo(1, 1)
	sweep:SetDuration(0.2)
	sweep:SetSmoothing("OUT")
	sweep:SetOrder(1)
	local gone = sg:CreateAnimation("Alpha")
	gone:SetFromAlpha(1)
	gone:SetToAlpha(0)
	gone:SetStartDelay(0.35)
	gone:SetDuration(0.35)
	gone:SetOrder(2)
	sg:SetToFinalAlpha(true)
	row.strikeAnim = sg

	local dg = row:CreateAnimationGroup()
	local down = dg:CreateAnimation("Alpha")
	down:SetFromAlpha(1)
	down:SetToAlpha(0.35)
	down:SetDuration(0.18)
	down:SetOrder(1)
	local up = dg:CreateAnimation("Alpha")
	up:SetFromAlpha(0.35)
	up:SetToAlpha(1)
	up:SetStartDelay(0.3)
	up:SetDuration(0.4)
	up:SetOrder(2)
	row.dipAnim = dg

	row.float = text(row, "GameFontHighlightSmall", 11)
	row.float:SetPoint("RIGHT", row.right, "LEFT", -4, 0)
	row.float:SetAlpha(0)
	local fg = row.float:CreateAnimationGroup()
	local rise = fg:CreateAnimation("Translation")
	rise:SetOffset(0, 12)
	rise:SetDuration(0.8)
	rise:SetSmoothing("OUT")
	local fadeIn = fg:CreateAnimation("Alpha")
	fadeIn:SetFromAlpha(0)
	fadeIn:SetToAlpha(1)
	fadeIn:SetDuration(0.12)
	local fadeOut = fg:CreateAnimation("Alpha")
	fadeOut:SetFromAlpha(1)
	fadeOut:SetToAlpha(0)
	fadeOut:SetStartDelay(0.35)
	fadeOut:SetDuration(0.45)
	fg:SetToFinalAlpha(true)
	row.floatAnim = fg
	return row
end

local function playConsumed(row, units)
	row.float:SetText("-" .. units)
	setColor(row.float, "warn")
	row.strikeAnim:Stop()
	row.dipAnim:Stop()
	row.floatAnim:Stop()
	row.strikeAnim:Play()
	row.dipAnim:Play()
	row.floatAnim:Play()
	count("consumed")
end

---------------------------------------------------------------------------------------------------------- the card

local function newCard(parent)
	local card = CreateFrame("Frame", nil, parent)
	card:SetWidth(INNER)
	card.bg = card:CreateTexture(nil, "BACKGROUND")
	card.bg:SetAllPoints()
	fill(card.bg, "surface", 0.95)
	-- the pulse: a wash and a rim in the step's colour, breathing behind the content
	card.wash = card:CreateTexture(nil, "BORDER")
	card.wash:SetAllPoints()
	card.rim = {}
	for k, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local t = card:CreateTexture(nil, "BORDER")
		if k <= 2 then
			t:SetHeight(1)
			t:SetPoint(side .. "LEFT")
			t:SetPoint(side .. "RIGHT")
		else
			t:SetWidth(1)
			t:SetPoint("TOP" .. side)
			t:SetPoint("BOTTOM" .. side)
		end
		card.rim[k] = t
	end
	card.stripe = card:CreateTexture(nil, "ARTWORK")
	card.stripe:SetWidth(3)
	card.stripe:SetPoint("TOPLEFT")
	card.stripe:SetPoint("BOTTOMLEFT")

	card.glow = CreateFrame("Frame", nil, card)
	card.glow:SetAllPoints()
	card.glow:SetFrameLevel(card:GetFrameLevel())
	card.wash:SetParent(card.glow)
	for _, t in ipairs(card.rim) do
		t:SetParent(card.glow)
	end
	local pg = card.glow:CreateAnimationGroup()
	pg:SetLooping("BOUNCE")
	local breathe = pg:CreateAnimation("Alpha")
	breathe:SetFromAlpha(0.25)
	breathe:SetToAlpha(1)
	breathe:SetDuration(1.1)
	breathe:SetSmoothing("IN_OUT")
	card.pulse = pg

	card.icon = card:CreateTexture(nil, "ARTWORK")
	card.icon:SetSize(36, 36)
	card.icon:SetPoint("TOPLEFT", PAD + 2, -PAD)
	card.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	card.name = text(card, "GameFontHighlightLarge", 16)
	card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, 1)
	card.name:SetWidth(INNER - PAD * 2 - 46)
	card.verb = text(card, "GameFontHighlight", 12)
	card.verb:SetWidth(INNER - PAD * 2 - 46)
	card.cost = text(card, "GameFontHighlightSmall", 11)
	card.cost:SetWidth(INNER - PAD * 2 - 46)
	card.mats = {}
	card.lines = {}
	for k = 1, 3 do
		card.lines[k] = text(card, "GameFontHighlightSmall", 11)
		card.lines[k]:SetWidth(INNER - PAD * 2)
	end

	-- slide: in from the right with a fade, out to the left
	local ig = card:CreateAnimationGroup()
	local inMove = ig:CreateAnimation("Translation")
	inMove:SetOffset(-28, 0)
	inMove:SetDuration(0.32)
	inMove:SetSmoothing("OUT")
	local inFade = ig:CreateAnimation("Alpha")
	inFade:SetFromAlpha(0)
	inFade:SetToAlpha(1)
	inFade:SetDuration(0.32)
	ig:SetToFinalAlpha(true)
	ig:SetScript("OnFinished", function()
		card:ClearAllPoints()
		card:SetPoint("TOPLEFT", card.home, "TOPLEFT", 0, 0)
	end)
	card.slideIn = ig
	local og = card:CreateAnimationGroup()
	local outMove = og:CreateAnimation("Translation")
	outMove:SetOffset(-28, 0)
	outMove:SetDuration(0.25)
	outMove:SetSmoothing("IN")
	local outFade = og:CreateAnimation("Alpha")
	outFade:SetFromAlpha(1)
	outFade:SetToAlpha(0)
	outFade:SetDuration(0.25)
	og:SetToFinalAlpha(true)
	og:SetScript("OnFinished", function()
		card:Hide()
	end)
	card.slideOut = og
	local fg = card:CreateAnimationGroup()
	local fadeIn = fg:CreateAnimation("Alpha")
	fadeIn:SetFromAlpha(0)
	fadeIn:SetToAlpha(1)
	fadeIn:SetDuration(0.22)
	fg:SetToFinalAlpha(true)
	card.fadeIn = fg
	return card
end

-- Fills a card from a View card and returns its height.
local function fillCard(card, c, consumed)
	local col = c.color
	local r, g, b = rgb(col)
	card.stripe:SetColorTexture(r, g, b, 1)
	card.wash:SetColorTexture(r, g, b, 0.07)
	for _, t in ipairs(card.rim) do
		t:SetColorTexture(r, g, b, 0.55)
	end
	card.icon:SetTexture(iconOf(c))
	card.icon:SetShown(c.kind ~= "gap")
	card.name:SetText(c.name or "")
	card.name:SetTextColor(r, g, b, 1)
	card.verb:SetText(c.gain and (c.verb .. ", " .. c.gain) or (c.verb or ""))
	setColor(card.verb, "bone")
	card.cost:SetText(c.cost or "")
	setColor(card.cost, "ash")

	card.verb:ClearAllPoints()
	card.verb:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -4)
	card.cost:ClearAllPoints()
	card.cost:SetPoint("TOPLEFT", card.verb, "BOTTOMLEFT", 0, -3)
	local textHeight = card.name:GetStringHeight() + 4 + card.verb:GetStringHeight() + 3
	if c.cost then
		textHeight = textHeight + card.cost:GetStringHeight()
	end
	local top = PAD + math.max(36, textHeight) + 10

	for i, m in ipairs(c.mats) do
		local row = card.mats[i] or newMatRow(card)
		card.mats[i] = row
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 10, -top)
		row.name:SetText(m.name)
		setColor(row.name, m.covered and "bone" or "ash")
		row.right:SetText(m.right)
		setColor(row.right, m.covered and "green" or "bone")
		fill(row.mark, m.covered and "green" or "ash")
		row:Show()
		if consumed and consumed[m.item] then
			playConsumed(row, consumed[m.item])
		end
		top = top + 16
	end
	for i = #c.mats + 1, #card.mats do
		card.mats[i]:Hide()
	end

	local extra = {}
	for _, n in ipairs(c.notes) do
		extra[#extra + 1] = { n, "bone" }
	end
	if c.alt then
		extra[#extra + 1] = { c.alt, "bone" }
	end
	if c.tags then
		extra[#extra + 1] = { c.tags, "ash" }
	end
	local joined = {}
	for k = 1, 3 do
		local fs = card.lines[k]
		local e = extra[k]
		if k == 3 and #extra > 3 then
			for j = 3, #extra do
				joined[#joined + 1] = extra[j][1]
			end
			e = { table.concat(joined, "; "), "ash" }
		end
		if e then
			top = top + (k == 1 and 6 or 3)
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
			fs:SetText(e[1])
			setColor(fs, e[2])
			fs:Show()
			top = top + fs:GetStringHeight()
		else
			fs:Hide()
		end
	end
	local h = top + PAD
	card:SetHeight(h)
	return h
end

---------------------------------------------------------------------------------------------------------- later rows

local function newLaterRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(INNER, 18)
	row.pip = row:CreateTexture(nil, "ARTWORK")
	row.pip:SetSize(6, 6)
	row.pip:SetPoint("LEFT", 4, 0)
	row.n = text(row, "GameFontHighlightSmall", 11)
	row.n:SetPoint("LEFT", 16, 0)
	row.n:SetWidth(16)
	row.right = text(row, "GameFontHighlightSmall", 11)
	row.right:SetPoint("RIGHT", -2, 0)
	row.right:SetJustifyH("RIGHT")
	row.right:SetJustifyV("MIDDLE")
	row.text = text(row, "GameFontHighlight", 12)
	row.text:SetPoint("LEFT", 34, 0)
	row.text:SetPoint("RIGHT", row.right, "LEFT", -8, 0)
	row.text:SetWordWrap(false)
	row.text:SetJustifyV("MIDDLE")
	return row
end

local function footerLine(parent)
	local fs = text(parent, "GameFontHighlightSmall", 10)
	fs:SetWidth(INNER - 8)
	return fs
end

---------------------------------------------------------------------------------------------------------- runway

-- Eases the bar to `value` over a short time, then stops its OnUpdate.
local function easeBar(bar, value)
	bar.goal = value
	bar.t0 = bar:GetValue()
	bar.elapsed = 0
	if math.abs(bar.goal - bar.t0) < 0.001 then
		bar:SetValue(value)
		return
	end
	count("bar")
	bar:SetScript("OnUpdate", function(self, dt)
		self.elapsed = self.elapsed + dt
		local k = math.min(1, self.elapsed / 0.45)
		k = 1 - (1 - k) ^ 3
		self:SetValue(self.t0 + (self.goal - self.t0) * k)
		if k >= 1 then
			self:SetScript("OnUpdate", nil)
		end
	end)
end

---------------------------------------------------------------------------------------------------------- dock

-- Docks the panel to the right of `target` (TSM's crafting frame or Blizzard's ProfessionsFrame), or leaves it
-- free and movable where the user put it when there is no window to dock to.
function UI.dock(target)
	local f = UI.frame
	if not f then
		return
	end
	if target then
		local h = target:GetHeight()
		f:SetHeight((h and h > 0) and math.max(300, math.min(600, h)) or 420)
	end
	-- false = free, so the first call with no target still anchors the panel
	local key = target or false
	if f.dockedTo == key then
		return
	end
	f:ClearAllPoints()
	if target then
		f:SetPoint("TOPLEFT", target, "TOPRIGHT", 2, 0)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
		f:SetHeight(420)
	end
	f.dockedTo = key
end

-- Records which window the panel sat beside (selftest ui.lastDock and ui.docks).
function UI.noteDock(kind)
	UI.stats.lastDock = kind
	UI.stats.docks[kind] = true
end

---------------------------------------------------------------------------------------------------------- frame

local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

function UI.create()
	if UI.frame then
		return UI.frame
	end
	local f = CreateFrame("Frame", "SkillupHelperPanel", UIParent, "BackdropTemplate")
	f:SetSize(WIDTH, 420)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		if not self.dockedTo then
			self:StartMoving()
		end
	end)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(rgb("ink"))
	f:SetBackdropBorderColor(rgb("line"))

	f.title = text(f, "GameFontNormal", 13)
	f.title:SetPoint("TOPLEFT", PAD, -PAD)
	f.skill = text(f, "GameFontHighlight", 13)
	f.skill:SetPoint("TOPRIGHT", -30, -PAD)
	f.skill:SetJustifyH("RIGHT")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function()
		ns.setShown(false)
	end)

	local bar = CreateFrame("StatusBar", nil, f)
	bar:SetPoint("TOPLEFT", PAD, -34)
	bar:SetPoint("TOPRIGHT", -PAD - 74, -34)
	bar:SetHeight(5)
	bar:SetStatusBarTexture(WHITE)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar.track = bar:CreateTexture(nil, "BACKGROUND")
	bar.track:SetAllPoints()
	bar.label = text(f, "GameFontHighlightSmall", 11)
	bar.label:SetPoint("LEFT", bar, "RIGHT", 8, 0)
	bar.label:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	bar.label:SetJustifyH("RIGHT")
	bar.label:SetJustifyV("MIDDLE")
	f.bar = bar

	f.stale = text(f, "GameFontHighlightSmall", 10)
	f.stale:SetWidth(WIDTH - 2 * PAD)

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("BOTTOMRIGHT", -26, 8)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(INNER, 10)
	scroll:SetScrollChild(child)
	f.scroll, f.child = scroll, child

	-- the cards sit on a home anchor; a card sliding in starts right of it and re-anchors when done
	child.home = CreateFrame("Frame", nil, child)
	child.home:SetSize(INNER, 1)
	child.home:SetPoint("TOPLEFT")
	f.cards = { newCard(child), newCard(child) }
	for _, c in ipairs(f.cards) do
		c.home = child.home
		c:SetPoint("TOPLEFT", child.home, "TOPLEFT", 0, 0)
		c:Hide()
	end
	f.current = 1

	f.message = text(child, "GameFontHighlight", 12)
	f.message:SetWidth(INNER - 8)
	f.thenLabel = text(child, "GameFontNormalSmall", 11)
	f.thenLabel:SetText("Then")
	f.later, f.footer = {}, {}
	f.rule = child:CreateTexture(nil, "ARTWORK")
	f.rule:SetHeight(1)
	fill(f.rule, "line")
	UI.frame = f
	return f
end

-- Header, runway, stale line; returns the y offset where the scroll area starts.
local function drawHeader(f, d)
	local h = d.header
	f.title:SetText(h and h.title or "Skill-up helper")
	f.skill:SetText(h and h.skill or "")
	setColor(f.skill, "bone")
	local y = 34
	local rw = d.runway
	if rw then
		local r, g, b = rgb(rw.color)
		f.bar:SetStatusBarColor(r, g, b, 1)
		fill(f.bar.track, rw.next, 0.22)
		f.bar.label:SetText(rw.label)
		f.bar.label:SetTextColor(rgb(rw.next))
		f.bar:Show()
		f.bar.label:Show()
		if f.bar.band ~= rw.color .. rw.target then
			-- a new band starts empty-to-here rather than draining back from the last one
			f.bar:SetValue(0)
			f.bar.band = rw.color .. rw.target
		end
		easeBar(f.bar, rw.frac)
		y = y + 5 + 8
	else
		f.bar:Hide()
		f.bar.label:Hide()
		f.bar.band = nil
	end
	if h and h.stale then
		f.stale:ClearAllPoints()
		f.stale:SetPoint("TOPLEFT", PAD, -y)
		f.stale:SetText(h.stale)
		setColor(f.stale, "ash")
		f.stale:Show()
		y = y + f.stale:GetStringHeight() + 6
	else
		f.stale:Hide()
	end
	return y + 2
end

-- Draws a description. prev is the last one drawn, for the transition and the consumed-material diff.
function UI.draw(d, prev)
	local f = UI.frame
	local top = drawHeader(f, d)
	f.scroll:ClearAllPoints()
	f.scroll:SetPoint("TOPLEFT", PAD - 2, -top)
	f.scroll:SetPoint("BOTTOMRIGHT", -26, 8)

	local y = 0
	if d.state == "message" or d.notice or d.empty then
		f.message:ClearAllPoints()
		f.message:SetPoint("TOPLEFT", 4, 0)
		f.message:SetText(d.message or d.notice or d.empty)
		setColor(f.message, d.tone or (d.notice and "warn" or "ash"))
		f.message:Show()
		y = f.message:GetStringHeight() + 10
	else
		f.message:Hide()
	end
	f.cards[1].home:ClearAllPoints()
	f.cards[1].home:SetPoint("TOPLEFT", 0, -y)

	local how = ns.View.transition(prev, d)
	local cur = f.cards[f.current]
	if d.next then
		if how == "advance" or how == "replace" then
			local old = cur
			f.current = 3 - f.current
			cur = f.cards[f.current]
			if how == "advance" and old:IsShown() then
				old.pulse:Stop()
				old.slideIn:Stop()
				old.slideOut:Play()
				count("slide")
			else
				old:Hide()
			end
		end
		local consumed = how == "same" and ns.View.consumed(prev and prev.next, d.next) or nil
		local h = fillCard(cur, d.next, consumed)
		cur:SetFrameLevel(f.child:GetFrameLevel() + 2)
		if how == "advance" then
			cur:SetAlpha(0)
			cur:ClearAllPoints()
			cur:SetPoint("TOPLEFT", cur.home, "TOPLEFT", 28, 0)
			cur:Show()
			cur.slideIn:Play()
			count("slide")
		elseif how ~= "same" then
			cur:ClearAllPoints()
			cur:SetPoint("TOPLEFT", cur.home, "TOPLEFT", 0, 0)
			cur:SetAlpha(0)
			cur:Show()
			cur.fadeIn:Play()
		end
		if not cur.pulse:IsPlaying() then
			cur.pulse:Play()
			count("pulse")
		end
		y = y + h + 14
	else
		for _, c in ipairs(f.cards) do
			c.pulse:Stop()
			c:Hide()
		end
	end

	if #d.later > 0 then
		f.thenLabel:ClearAllPoints()
		f.thenLabel:SetPoint("TOPLEFT", 4, -y)
		setColor(f.thenLabel, "ash")
		f.thenLabel:Show()
		y = y + 16
	else
		f.thenLabel:Hide()
	end
	for i, r in ipairs(d.later) do
		local row = f.later[i] or newLaterRow(f.child)
		f.later[i] = row
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		fill(row.pip, r.color)
		row.pip:SetShown(r.n ~= nil)
		row.n:SetText(r.n and tostring(r.n) or "")
		setColor(row.n, "ash")
		row.text:SetText(r.text)
		setColor(row.text, r.n and "bone" or "ash")
		row.right:SetText(r.right or "")
		setColor(row.right, "ash")
		row:Show()
		y = y + 18
	end
	for i = #d.later + 1, #f.later do
		f.later[i]:Hide()
	end

	if #d.footer > 0 then
		y = y + 8
		f.rule:ClearAllPoints()
		f.rule:SetPoint("TOPLEFT", 4, -y)
		f.rule:SetPoint("TOPRIGHT", -4, -y)
		f.rule:Show()
		y = y + 8
	else
		f.rule:Hide()
	end
	for i, line in ipairs(d.footer) do
		local fs = f.footer[i] or footerLine(f.child)
		f.footer[i] = fs
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", 4, -y)
		fs:SetText(line)
		setColor(fs, "ash")
		fs:Show()
		y = y + fs:GetStringHeight() + 3
	end
	for i = #d.footer + 1, #f.footer do
		f.footer[i]:Hide()
	end
	f.child:SetHeight(math.max(10, y + 4))
end

function UI.show(model)
	local f = UI.frame
	if not f then
		return
	end
	local d = ns.View.describe(model, UI.env())
	UI.draw(d, UI.last)
	UI.last = d
end
