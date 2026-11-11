-- The side panel: draws View.describe's description. A header with the skill and a runway bar to the next colour
-- change, the Next card (two of them, swapped when the skill passes a step), the later steps as compact rows and
-- quiet footer lines, in a scroll frame. Rows are pooled; frames are made only when a pool is short.
local _, ns = ...
local UI = {}
ns.UI = UI

-- The panel is WIDTH wide with its scroll bar and NARROW without: the content column never moves.
local WIDTH, NARROW, INNER = 340, 316, 296
local PAD = 12
local FREE_HEIGHT = 480 -- the tallest the panel gets with no window to dock to
local DOCK_GAP, TAB_GAP = 2, 4
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION = 134400 -- INV_Misc_QuestionMark
local HANDLE_ICON = "Interface\\Icons\\INV_Misc_Note_01"

-- Panel diagnostics for the selftest.
UI.stats = {
	layout = "cards",
	animations = 0,
	played = {},
	docks = {},
	clicks = { craft = 0, open = 0, hide = 0, show = 0 },
}

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

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

-- How many casts of a learned recipe the client allows now, or nil and the link that broke (not learned, a secret
-- value, no count from the client).
function UI.craftable(spell)
	if secret(spell) or type(spell) ~= "number" then
		return nil, "no recipe id"
	end
	local ok, r = pcall(C_TradeSkillUI.GetRecipeInfo, spell)
	if not ok then
		return nil, "C_TradeSkillUI.GetRecipeInfo failed: " .. tostring(r)
	end
	if type(r) ~= "table" then
		return nil, "no recipe info for spell " .. spell
	end
	if secret(r.learned) then
		return nil, "recipe info is secret here"
	end
	if not r.learned then
		return nil, "recipe not learned"
	end
	local okCount, n = pcall(C_TradeSkillUI.GetCraftableCount, spell)
	if okCount and not secret(n) and type(n) == "number" then
		return n
	end
	n = r.numAvailable
	if not secret(n) and type(n) == "number" then
		return n
	end
	return nil, "the client gave no craftable count (GetCraftableCount, numAvailable)"
end

-- The env View.describe reads the client through.
function UI.env()
	return {
		nameOf = itemName,
		money = ns.Logic.money,
		have = function(item)
			return ns.Scan.have(item)
		end,
		craftable = UI.craftable,
		dock = ns.dockKind,
	}
end

-- A click on a card button. Each client call runs under pcall and leaves its result in UI.stats (selftest ui).
-- Only ever called from a button's OnClick: a craft needs the user's own click.
function UI.act(a)
	local stats = UI.stats
	if type(a) ~= "table" or not a.enabled or secret(a.spell) or type(a.spell) ~= "number" then
		return false
	end
	if a.id == "open" then
		stats.clicks.open = stats.clicks.open + 1
		local ok, err = pcall(C_TradeSkillUI.OpenRecipe, a.spell)
		stats.lastOpenError = not ok and ("C_TradeSkillUI.OpenRecipe: " .. tostring(err)) or nil
		return ok
	elseif a.id ~= "craft" then
		return false
	end
	stats.clicks.craft = stats.clicks.craft + 1
	-- the bags may have changed since the card was drawn: ask the client again
	local can, why = UI.craftable(a.spell)
	local n = math.floor(math.min(a.count or 0, can or 0))
	if n < 1 then
		stats.lastCraftError = "nothing craftable at the click: " .. (why or "the client counts 0")
		ns.refresh()
		return false
	end
	stats.lastCraft = { spell = a.spell, count = n }
	local ok, err = pcall(C_TradeSkillUI.CraftRecipe, a.spell, n)
	stats.lastCraftError = not ok and ("C_TradeSkillUI.CraftRecipe: " .. tostring(err)) or nil
	return ok
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

-- Four one-pixel edges around `owner`, drawn on `parent` (default: owner).
local function edges(owner, layer, parent)
	local out = {}
	for k, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local t = (parent or owner):CreateTexture(nil, layer or "BORDER")
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

local function paintEdges(list, r, g, b, a)
	for _, t in ipairs(list) do
		t:SetColorTexture(r, g, b, a or 1)
	end
end

local function showTip(owner, tip)
	if not tip or not GameTooltip then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(tip, 1, 1, 1, 1, true)
	GameTooltip:Show()
end

local function hideTip(owner)
	if GameTooltip and GameTooltip:IsOwned(owner) then
		GameTooltip:Hide()
	end
end

-- A short fade that plays when something appears because the user asked for it.
local function appear(frame)
	local g = frame:CreateAnimationGroup()
	local a = g:CreateAnimation("Alpha")
	a:SetFromAlpha(0)
	a:SetToAlpha(1)
	a:SetDuration(0.15)
	g:SetToFinalAlpha(true)
	return g
end

------------------------------------------------------------------------------------------------------------ buttons

-- Flat buttons in the panel's palette. "primary" wears the step's colour, "quiet" is an outline, "inert" is a
-- primary that cannot act yet: it keeps its place and its label says what to do first.
local function paintButton(b)
	local over = b.over and b.style ~= "inert"
	local r, g, bl = rgb("line")
	if b.style == "primary" then
		r, g, bl = b.accent[1], b.accent[2], b.accent[3]
		b.bg:SetColorTexture(r, g, bl, over and 0.34 or 0.18)
		paintEdges(b.edge, r, g, bl, over and 1 or 0.8)
		setColor(b.label, "bone")
	elseif b.style == "quiet" then
		b.bg:SetColorTexture(r, g, bl, over and 0.5 or 0)
		paintEdges(b.edge, r, g, bl, 1)
		setColor(b.label, over and "bone" or "ash")
	else
		b.bg:SetColorTexture(r, g, bl, 0.25)
		paintEdges(b.edge, r, g, bl, 0.6)
		setColor(b.label, "ash")
	end
end

local function newButton(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetHeight(24)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.edge = edges(b)
	b.label = text(b, "GameFontHighlightSmall", 12)
	b.label:SetPoint("LEFT", 8, 0)
	b.label:SetPoint("RIGHT", -8, 0)
	b.label:SetJustifyH("CENTER")
	b.label:SetJustifyV("MIDDLE")
	b.label:SetWordWrap(false)
	b.style, b.accent = "quiet", ns.View.RGB.bone
	b:SetScript("OnEnter", function(self)
		self.over = true
		paintButton(self)
		-- a label cut short by the button's width is read whole in the tooltip
		showTip(self, self.tip or (self.label:IsTruncated() and self.label:GetText()) or nil)
	end)
	b:SetScript("OnLeave", function(self)
		self.over = false
		paintButton(self)
		hideTip(self)
	end)
	b:SetScript("OnClick", function(self)
		ns.guard("click", UI.act, self.action)
	end)
	return b
end

-- Shows a View action on a button.
local function setButton(b, a, accent)
	b.action, b.tip = a, a.tip
	b.style = (a.id == "open" and "quiet") or (a.enabled and "primary" or "inert")
	b.accent = accent
	b.label:SetText(a.label)
	paintButton(b)
	b:Show()
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
	card.rim = edges(card)
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
	card.buttons = { craft = newButton(card), open = newButton(card) }

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
		-- a quick second step may have made this card current again: only hide a card that is not
		if not card.live then
			card:Hide()
		end
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

	-- the buttons: Craft takes the row, Show recipe sits at its right when the view offers it
	local craft, open = card.buttons.craft, card.buttons.open
	craft:Hide()
	open:Hide()
	local byId = {}
	for _, a in ipairs(c.actions or {}) do
		byId[a.id] = a
	end
	if byId.craft then
		top = top + 10
		craft:ClearAllPoints()
		craft:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		local row = INNER - 2 * PAD - 2
		if byId.open then
			open:ClearAllPoints()
			open:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PAD, -top)
			open:SetWidth(96)
			craft:SetWidth(row - 96 - 6)
			setButton(open, byId.open, ns.View.RGB.bone)
		else
			craft:SetWidth(row)
		end
		setButton(craft, byId.craft, ns.View.RGB[col] or ns.View.RGB.bone)
		top = top + 24
	end
	UI.stats.actionsWhy = c.actionsWhy
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

-- How far Blizzard's profession tabs stick out of the window's right edge. On this client they are side tabs
-- anchored TOPLEFT to the frame's TOPRIGHT (Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml:
-- ProfessionsOverviewTab and the rightProfessionTabs array), sized from their art, so the width is read from the
-- frames. Reading only: Blizzard's frames are never changed.
local function sideTabsWidth(target)
	local widest = 0
	local function see(tab)
		if type(tab) == "table" and tab.IsShown and tab:IsShown() then
			local w = tab:GetWidth()
			if not secret(w) and type(w) == "number" and w > widest then
				widest = w
			end
		end
	end
	see(target.ProfessionsOverviewTab)
	for _, tab in ipairs(type(target.rightProfessionTabs) == "table" and target.rightProfessionTabs or {}) do
		see(tab)
	end
	return widest
end

-- Sizes the panel to what it shows, up to the docked window's height, and shows the scroll bar only on overflow.
function UI.fit()
	local f = UI.frame
	if not f or not f.chrome then
		return
	end
	local fit = ns.View.fit(f.contentHeight, f.chrome, f.limit or FREE_HEIGHT)
	f:SetSize(fit.scroll and WIDTH or NARROW, fit.height)
	f.scroll:ClearAllPoints()
	f.scroll:SetPoint("TOPLEFT", PAD - 2, -f.top)
	f.scroll:SetPoint("BOTTOMRIGHT", fit.scroll and -26 or -(PAD - 2), 8)
	if f.scroll.ScrollBar then
		f.scroll.ScrollBar:SetShown(fit.scroll)
	end
	if not fit.scroll then
		f.scroll:SetVerticalScroll(0)
	end
	UI.stats.fit = { height = fit.height, scroll = fit.scroll, content = f.contentHeight, limit = f.limit }
end

-- Docks the panel to the right of `target` (TSM's crafting frame or Blizzard's ProfessionsFrame, `kind` "tsm" or
-- "blizzard"), or leaves it free and movable where the user put it when there is no window to dock to. Beside
-- Blizzard's window it stands clear of the profession tabs on that window's right edge.
function UI.dock(target, kind)
	local f = UI.frame
	if not f then
		return
	end
	local limit, gap = FREE_HEIGHT, 0
	if target then
		local h = target:GetHeight()
		limit = (h and h > 0) and math.max(200, math.min(600, h)) or FREE_HEIGHT
		gap = DOCK_GAP
		if kind == "blizzard" then
			local tabs = sideTabsWidth(target)
			gap = gap + (tabs > 0 and tabs + TAB_GAP or 0)
		end
	end
	if f.limit ~= limit then
		f.limit = limit
		UI.fit()
	end
	-- false = free, so the first call with no target still anchors the panel
	local key = target or false
	if f.dockedTo == key and f.dockGap == gap then
		return
	end
	f:ClearAllPoints()
	if target then
		f:SetPoint("TOPLEFT", target, "TOPRIGHT", gap, 0)
	else
		-- by its top, so the panel does not jump when its height follows the content
		f:SetPoint("TOP", UIParent, "CENTER", 300, FREE_HEIGHT / 2)
	end
	f.dockedTo, f.dockGap = key, gap
	UI.stats.dockGap = gap
end

-- Shows the panel, or its handle when the user hid it; neither while no profession is open. `byUser` plays the
-- short fade of a change the user asked for.
function UI.setShown(shown, open, byUser)
	local f, h = UI.frame, UI.handle
	if not f then
		return
	end
	local coming = (open and shown) and f or ((open and not shown) and h or nil)
	local animate = byUser and coming and not coming:IsShown()
	f:SetShown(open and shown)
	h:SetShown(open and not shown)
	if animate then
		coming.appear:Play()
	end
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
	f.appear = appear(f)

	-- the hide control: a minimise bar, because the panel folds to its handle rather than closing
	local hide = CreateFrame("Button", nil, f)
	hide:SetSize(22, 22)
	hide:SetPoint("TOPRIGHT", -5, -7)
	hide.bar = hide:CreateTexture(nil, "ARTWORK")
	hide.bar:SetSize(10, 2)
	hide.bar:SetPoint("CENTER", 0, -3)
	fill(hide.bar, "ash")
	hide:SetScript("OnEnter", function(self)
		fill(self.bar, "bone")
		showTip(self, "Hide the plan. The tab left here brings it back.")
	end)
	hide:SetScript("OnLeave", function(self)
		fill(self.bar, "ash")
		hideTip(self)
	end)
	hide:SetScript("OnClick", function(self)
		UI.stats.clicks.hide = UI.stats.clicks.hide + 1
		hideTip(self)
		ns.setShown(false, true)
	end)
	f.hide = hide

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
	f.stale:SetWidth(NARROW - 2 * PAD)

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	-- the template hides its bar when nothing scrolls (SecureScrollTemplates.lua); UI.fit also sets it outright
	scroll.scrollBarHideable = true
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

	-- the handle: what stays at the panel's corner while it is hidden, and brings it back with one click
	local h = CreateFrame("Button", "SkillupHelperHandle", UIParent)
	h:SetSize(26, 96)
	h:SetFrameStrata("HIGH")
	h:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	h.bg = h:CreateTexture(nil, "BACKGROUND")
	h.bg:SetAllPoints()
	fill(h.bg, "ink")
	h.edge = edges(h)
	paintEdges(h.edge, rgb("line"))
	h.stripe = h:CreateTexture(nil, "ARTWORK")
	h.stripe:SetWidth(3)
	h.stripe:SetPoint("TOPLEFT")
	h.stripe:SetPoint("BOTTOMLEFT")
	fill(h.stripe, "gold")
	h.icon = h:CreateTexture(nil, "ARTWORK")
	h.icon:SetSize(16, 16)
	h.icon:SetPoint("TOP", 1, -7)
	h.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	h.icon:SetTexture(HANDLE_ICON)
	h.label = text(h, "GameFontHighlightSmall", 11)
	h.label:SetWordWrap(false)
	h.label:SetJustifyH("CENTER")
	h.label:SetText("Skill-up")
	setColor(h.label, "ash")
	if h.label.SetRotation then
		-- read top to bottom, like the spine of a book
		h.label:SetPoint("CENTER", 1, -10)
		h.label:SetRotation(-math.pi / 2)
		UI.stats.handle = "icon and label"
	else
		h.label:Hide()
		h:SetHeight(30)
		UI.stats.handle = "icon only (FontString:SetRotation missing)"
	end
	h:SetScript("OnEnter", function(self)
		local r, g, b = rgb(self.color or "gold")
		paintEdges(self.edge, r, g, b, 1)
		setColor(self.label, "bone")
		showTip(self, "Show the skill-up plan")
	end)
	h:SetScript("OnLeave", function(self)
		paintEdges(self.edge, rgb("line"))
		setColor(self.label, "ash")
		hideTip(self)
	end)
	h:SetScript("OnClick", function(self)
		UI.stats.clicks.show = UI.stats.clicks.show + 1
		hideTip(self)
		paintEdges(self.edge, rgb("line"))
		setColor(self.label, "ash")
		ns.setShown(true, true)
	end)
	h.appear = appear(h)
	h:Hide()
	UI.handle = h
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
	f.top = drawHeader(f, d)
	-- the handle wears the colour of the step it hides
	local handle = UI.handle
	handle.color = d.next and d.next.color or "gold"
	fill(handle.stripe, handle.color)

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
			old.live = false
			if how == "advance" and old:IsShown() then
				old.pulse:Stop()
				old.slideIn:Stop()
				old.slideOut:Play()
				count("slide")
			else
				old:Hide()
			end
		end
		cur.live = true
		if how ~= "same" then
			-- the card may still be sliding out from a step ago: stop that before it is reused
			cur.slideOut:Stop()
			cur.slideIn:Stop()
			cur.fadeIn:Stop()
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
			c.live = false
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
	f.contentHeight = math.max(10, y + 4)
	f.child:SetHeight(f.contentHeight)
	-- header above, 8 below, and 2 of slack so a rounded string height never leaves a pixel to scroll
	f.chrome = f.top + 8 + 2
	UI.fit()
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
