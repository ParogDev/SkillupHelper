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
local CARD_LINES = 6 -- note lines under a card (notes, other ways, the stock option, tags); the rest join the last

-- Panel diagnostics for the selftest.
UI.stats = {
	layout = "cards",
	animations = 0,
	played = {},
	docks = {},
	clicks = { craft = 0, open = 0, hide = 0, show = 0, buy = 0 },
	merchant = { open = false, shows = 0 },
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

-- The open merchant's offer for an item: { index, price, lot, maxStack, available } (Logic.vendorLots), or nil and
-- the link that broke. The merchant API reads the vendor, not a frame: it answers the same under Blizzard's
-- MerchantFrame and TSM's vendoring window.
function UI.merchantOffer(item)
	if not ns.merchantOpen then
		return nil, "no vendor open"
	end
	local okN, n = pcall(GetMerchantNumItems)
	if not okN or secret(n) or type(n) ~= "number" then
		return nil, "GetMerchantNumItems failed: " .. tostring(n)
	end
	for i = 1, n do
		local okId, id = pcall(GetMerchantItemID, i)
		if okId and not secret(id) and id == item then
			local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
			if not ok or type(info) ~= "table" then
				return nil, "C_MerchantFrame.GetItemInfo failed: " .. tostring(info)
			end
			if info.hasExtendedCost or info.currencyID then
				return nil, "costs more than gold here"
			end
			if info.isPurchasable == false then
				return nil, "the vendor will not sell it to you"
			end
			local maxStack = GetMerchantItemMaxStack(i)
			return {
				index = i,
				price = info.price or 0,
				lot = math.max(1, info.stackCount or 1),
				maxStack = type(maxStack) == "number" and maxStack or nil,
				available = info.numAvailable,
			}
		end
	end
	if GetMerchantFilter and LE_LOOT_FILTER_ALL and GetMerchantFilter() ~= LE_LOOT_FILTER_ALL then
		return nil, "not in this vendor's list (its filter is not All)"
	end
	return nil, "this vendor does not sell it"
end

-- Units of `item` the bags take now: free slots of bags that accept it (general bags, a profession bag of its
-- family, the reagent bag for a crafting reagent) times its stack size, plus the top of a partial stack.
function UI.bagRoom(item)
	local _, _, _, _, _, _, _, stack, _, _, _, _, _, _, _, _, isReagent = C_Item.GetItemInfo(item)
	if not stack then
		return nil -- item info not cached yet: room unknown, the client refuses a buy that does not fit
	end
	local family = C_Item.GetItemFamily and C_Item.GetItemFamily(item) or 0
	local bags = NUM_BAG_SLOTS or 4
	local free = 0
	for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or bags do
		local n, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
		if type(n) == "number" and n > 0 then
			local fits
			if bag > bags then
				fits = isReagent == true
			else
				fits = (bagFamily or 0) == 0 or bit.band(bagFamily, family or 0) ~= 0
			end
			if fits then
				free = free + n
			end
		end
	end
	return ns.Logic.bagRoom(free, stack, C_Item.GetItemCount(item) or 0)
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
		merchant = ns.merchantOpen and UI.merchantOffer or nil,
		gold = GetMoney,
		bagRoom = UI.bagRoom,
		savedTrip = ns.savedTrip,
		where = ns.GuideUI and ns.GuideUI.where or nil,
	}
end

-- Which merchant window is up: Blizzard's, or another (TSM's vendoring frame hides MerchantFrame).
local function merchantUi()
	return (MerchantFrame and MerchantFrame:IsShown()) and "blizzard" or "other"
end

-- A click on Buy: asks the merchant again (the list, prices, gold and bags may have changed since the draw) and buys
-- what View.buyAction allows now, every call a whole number of the vendor's lots.
local function buy(a)
	local stats = UI.stats
	stats.clicks.buy = (stats.clicks.buy or 0) + 1
	-- a second click before the bags report the first buy would buy again from the same short counts
	if UI.buyPending then
		stats.lastBuyError = "refused at the click: the last buy has not reached the bags yet"
		return false
	end
	local fresh = ns.View.buyAction(a.want, UI.env())
	if not fresh or not fresh.enabled then
		stats.lastBuyError = "refused at the click: " .. tostring(fresh and fresh.label or "nothing to buy")
		ns.refresh()
		return false
	end
	local bought, err = {}, nil
	for _, it in ipairs(fresh.items) do
		local done, before = 0, C_Item.GetItemCount(it.item) or 0
		for _, n in ipairs(it.calls) do
			local ok, e = pcall(BuyMerchantItem, it.index, n)
			if not ok then
				err = ("BuyMerchantItem(%d, %d): %s"):format(it.index, n, tostring(e))
				break
			end
			done = done + n
		end
		-- requested: what the calls asked for. got: what reached the bags (UI.noteBags); a refusal raises no error
		bought[#bought + 1] = { item = it.item, requested = done, before = before, cost = it.cost, calls = #it.calls }
		if err then
			break
		end
	end
	local ui = merchantUi()
	stats.buysByUi = stats.buysByUi or {}
	stats.buysByUi[ui] = (stats.buysByUi[ui] or 0) + 1
	stats.lastBuy = { at = date("%Y-%m-%d %H:%M:%S"), ui = ui, cost = fresh.cost, items = bought }
	stats.lastBuyError = err
	UI.buyPending = true
	return err == nil
end

-- BAG_UPDATE_DELAYED: what the last buy put in the bags, and the Buy button may act again. A buy the client
-- refused (gold, bags, stock) shows as got < requested and names itself in lastBuyError.
function UI.noteBags()
	if not UI.buyPending then
		return
	end
	UI.buyPending = false
	local last = UI.stats.lastBuy
	for _, it in ipairs(last and last.items or {}) do
		if it.got == nil then
			it.got = (C_Item.GetItemCount(it.item) or 0) - (it.before or 0)
			if it.got < it.requested and not UI.stats.lastBuyError then
				UI.stats.lastBuyError = ("item %d: asked for %d, the bags got %d"):format(it.item, it.requested, it.got)
			end
		end
	end
end

-- A click on a card button. Each client call runs under pcall and leaves its result in UI.stats (selftest ui).
-- Only ever called from a button's OnClick: a craft needs the user's own click.
function UI.act(a)
	local stats = UI.stats
	if type(a) == "table" and type(a.id) == "string" and a.id:sub(1, 2) == "ah" then
		return UI.ahAct(a)
	end
	if type(a) == "table" and a.id == "buy" then
		return a.enabled and buy(a) or false
	end
	if type(a) == "table" and (a.id == "trip" or a.id == "untrip") then
		stats.clicks[a.id] = (stats.clicks[a.id] or 0) + 1
		if a.id == "trip" then
			return ns.saveTrip(a.block)
		end
		return ns.clearTrip(a.block and a.block.prof)
	end
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

---------------------------------------------------------------------------------------------------------- guide strip
-- One row on the Next card that repeats the guide chip's arrow, name and distance (GuideUI.lua decides, Guide.strip
-- words it). Plain card content: it takes no part in docking, and the Target button stays on the chip.

local STRIP_W = INNER - 2 * PAD - 2
local STRIP_ARROW_ATLAS, STRIP_ARROW_FILE = "MiniMap-QuestArrow", "Interface\\Minimap\\MinimapArrow"
local STRIP_STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local STRIP_CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

local function newStrip(card)
	local s = CreateFrame("Button", nil, card)
	s:SetSize(STRIP_W, 28)
	s:RegisterForClicks("LeftButtonUp")
	s.hover = s:CreateTexture(nil, "BACKGROUND")
	s.hover:SetAllPoints()
	fill(s.hover, "line", 0.5)
	s.hover:Hide()
	s.hair = s:CreateTexture(nil, "BORDER")
	s.hair:SetHeight(1)
	s.hair:SetPoint("TOPLEFT")
	s.hair:SetPoint("TOPRIGHT")
	fill(s.hair, "line")
	s.arrow = s:CreateTexture(nil, "ARTWORK")
	s.arrow:SetSize(14, 14)
	s.arrow:SetPoint("TOPLEFT", 0, -7)
	s.arrowAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(STRIP_ARROW_ATLAS) ~= nil
	s.dot = s:CreateTexture(nil, "ARTWORK")
	s.dot:SetSize(8, 8)
	s.dot:SetPoint("CENTER", s.arrow, "CENTER")
	s.dot:SetTexture(WHITE)
	local m = s:CreateMaskTexture()
	m:SetTexture(STRIP_CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	m:SetAllPoints(s.dot)
	s.dot:AddMaskTexture(m)
	s.ar = text(s, "GameFontHighlightSmall", 11)
	s.ar:SetPoint("TOPRIGHT", 0, -7)
	s.ar:SetJustifyH("RIGHT")
	s.ar:SetWordWrap(false)
	s.a = text(s, "GameFontHighlightSmall", 11)
	s.a:SetPoint("TOPLEFT", 20, -7)
	s.a:SetPoint("RIGHT", s.ar, "LEFT", -8, 0)
	s.a:SetWordWrap(false)
	s.b = text(s, "GameFontHighlightSmall", 10)
	s.b:SetPoint("TOPLEFT", s.a, "BOTTOMLEFT", 0, -2)
	s.b:SetWidth(STRIP_W - 20)
	s.b:SetWordWrap(false)
	s:SetScript("OnEnter", function(self)
		self.hover:Show()
		showTip(self, self.tip)
	end)
	s:SetScript("OnLeave", function(self)
		self.hover:Hide()
		hideTip(self)
	end)
	s:SetScript("OnClick", function()
		UI.stats.clicks.strip = (UI.stats.clicks.strip or 0) + 1
		if ns.GuideUI and ns.GuideUI.stripClick then
			ns.guard("strip click", ns.GuideUI.stripClick)
		end
	end)
	s:Hide()
	return s
end

-- Paints a strip from Guide.strip's table; collapsed = the Buy button carries the action ("You are here" alone).
local function paintStrip(s, g, color, collapsed)
	s.a:SetText(g.a or "")
	setColor(s.a, g.phase == "here" and "green" or (g.phase == "unknown" or g.phase == "notnow") and "ash" or "bone")
	s.ar:SetText(g.ar or "")
	setColor(s.ar, g.arTint == "ash" and "ash" or g.arTint or "ash")
	local b = not collapsed and g.b or nil
	s.b:SetText(b or "")
	setColor(s.b, "ash")
	s.b:SetShown(b ~= nil)
	s.tip = g.tip
	local icon, tint = g.icon, g.tint
	if icon == s.icon and tint == s.tint and color == s.color then
		return b ~= nil
	end
	s.tint, s.color = tint, color
	if icon == "arrow" then
		if s.arrowAtlas then
			s.arrow:SetAtlas(STRIP_ARROW_ATLAS)
		else
			s.arrow:SetTexture(STRIP_ARROW_FILE)
		end
		s.arrow:SetDesaturated(true)
		local tc = tint == "bone" and "bone" or (tint or color or "bone")
		s.arrow:SetVertexColor(rgb(tc))
		s.arrow:Show()
		s.dot:Hide()
	elseif icon == "star" then
		s.arrow:SetTexture(STRIP_STAR)
		s.arrow:SetDesaturated(false)
		s.arrow:SetVertexColor(1, 1, 1)
		s.arrow:SetRotation(0)
		s.arrow:Show()
		s.dot:Hide()
	elseif icon == "dot" then
		s.arrow:Hide()
		s.dot:SetVertexColor(rgb(tint or "green"))
		s.dot:Show()
	else
		s.arrow:Hide()
		s.dot:Hide()
	end
	s.icon = icon
	return b ~= nil
end

-- The strip's height for a Guide.strip table: 28, 40 with a second line, 0 when there is none.
local function stripHeight(g, collapsed)
	if not g then
		return 0
	end
	return (g.b and not collapsed) and 40 or 28
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
	for k = 1, CARD_LINES do
		card.lines[k] = text(card, "GameFontHighlightSmall", 11)
		card.lines[k]:SetWidth(INNER - PAD * 2)
	end
	card.blockTitles = {}
	card.tripRows = {}
	card.buttons = { trip = newButton(card), buy = newButton(card), craft = newButton(card), open = newButton(card) }
	card.guide = newStrip(card)

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

	-- the shopping list: one block per place in travel order (or the AH trip alone), spares for bad luck included
	local nTrip, nTitle = 0, 0
	for _, blk in ipairs(c.blocks or {}) do
		nTitle = nTitle + 1
		local title = card.blockTitles[nTitle]
		if not title then
			title = text(card, "GameFontHighlightSmall", 11)
			title:SetWidth(INNER - PAD * 2)
			card.blockTitles[nTitle] = title
		end
		top = top + 8
		title:ClearAllPoints()
		title:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		title:SetText(blk.title)
		setColor(title, "gold")
		title:Show()
		top = top + title:GetStringHeight() + 4
		for _, tr in ipairs(blk.rows) do
			nTrip = nTrip + 1
			local row = card.tripRows[nTrip] or newMatRow(card)
			card.tripRows[nTrip] = row
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 10, -top)
			row.name:SetText(tr.name)
			setColor(row.name, "bone")
			row.right:SetText(tr.right)
			setColor(row.right, "bone")
			fill(row.mark, "gold")
			row:Show()
			top = top + 16
		end
	end
	for i = nTitle + 1, #card.blockTitles do
		card.blockTitles[i]:Hide()
	end
	for i = nTrip + 1, #card.tripRows do
		card.tripRows[i]:Hide()
	end

	local extra = {}
	for _, n in ipairs(c.notes) do
		extra[#extra + 1] = { n, "bone" }
	end
	for _, o in ipairs(c.others or {}) do
		extra[#extra + 1] = { o, "ash" }
	end
	if c.alt then
		extra[#extra + 1] = { c.alt, "bone" }
	end
	if c.tags then
		extra[#extra + 1] = { c.tags, "ash" }
	end
	local joined = {}
	for k = 1, CARD_LINES do
		local fs = card.lines[k]
		local e = extra[k]
		if k == CARD_LINES and #extra > CARD_LINES then
			for j = CARD_LINES, #extra do
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

	-- the buttons: Buy (vendor reagents the step lacks) takes a row of its own above; Craft takes the next row, Show
	-- recipe sits at its right when the view offers it
	local craft, open, buyButton = card.buttons.craft, card.buttons.open, card.buttons.buy
	local tripButton = card.buttons.trip
	craft:Hide()
	open:Hide()
	buyButton:Hide()
	tripButton:Hide()
	local byId = {}
	for _, a in ipairs(c.actions or {}) do
		byId[a.id] = a
	end

	-- the guide strip: where to go for this step, after the notes and before the buttons
	local gs = ns.GuideUI and ns.GuideUI.strip and ns.GuideUI.strip() or nil
	local collapsed = gs ~= nil and gs.phase == "here" and byId.buy ~= nil
	card.stripShape = gs and (stripHeight(gs, collapsed) .. ":" .. tostring(byId.buy ~= nil)) or "none"
	card.stripBuy = byId.buy ~= nil
	card.stripColor = col
	if gs then
		top = top + 8
		local s = card.guide
		s:ClearAllPoints()
		s:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		s:SetHeight(stripHeight(gs, collapsed))
		paintStrip(s, gs, col, collapsed)
		s:Show()
		top = top + stripHeight(gs, collapsed)
	else
		card.guide:Hide()
	end

	local ta = byId.trip or byId.untrip
	if ta then
		top = top + 10
		tripButton:ClearAllPoints()
		tripButton:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		tripButton:SetWidth(INNER - 2 * PAD - 2)
		setButton(tripButton, ta, ta.id == "trip" and ns.View.RGB.gold or ns.View.RGB.ash)
		top = top + 20
	end
	if byId.buy then
		top = top + 10
		buyButton:ClearAllPoints()
		buyButton:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		buyButton:SetWidth(INNER - 2 * PAD - 2)
		setButton(buyButton, byId.buy, ns.View.RGB.gold)
		top = top + 20 -- the Craft row adds its 10 on top: 6 px between the two buttons
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
	-- "Show recipe" for a learned craft step beside Blizzard's window (View.rowOpen); hidden otherwise
	row.open = newButton(row)
	row.open:SetSize(52, 16)
	row.open:SetPoint("RIGHT", -2, 0)
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
		row.right:ClearAllPoints()
		if r.open then
			setButton(row.open, r.open, ns.View.RGB.bone)
			row.right:SetPoint("RIGHT", row.open, "LEFT", -6, 0)
		else
			row.open:Hide()
			row.right:SetPoint("RIGHT", -2, 0)
		end
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

-- The guide's tick (GuideUI, 10 Hz and on events): repaints the live card's strip in place, and redraws the panel
-- only when the strip appears, goes, or changes height.
function UI.guideStrip(g)
	local f = UI.frame
	if not f or not f:IsShown() or not UI.last or not UI.last.next then
		return
	end
	local card = f.cards[f.current]
	if not card or not card.live then
		return
	end
	local collapsed = g ~= nil and g.phase == "here" and card.stripBuy
	local shape = g and (stripHeight(g, collapsed) .. ":" .. tostring(card.stripBuy)) or "none"
	if shape ~= card.stripShape then
		UI.stats.stripRelayouts = (UI.stats.stripRelayouts or 0) + 1
		UI.draw(UI.last, UI.last)
		return
	end
	if g then
		paintStrip(card.guide, g, card.stripColor, collapsed)
	end
end

-- The guide's eased arrow angle, every frame while the chip turns: the strip's arrow follows it.
function UI.guideStripAngle(angle)
	local f = UI.frame
	local card = f and f:IsShown() and f.cards[f.current]
	if card and card.live and card.guide:IsShown() and card.guide.icon == "arrow" then
		card.guide.arrow:SetRotation(angle)
	end
end

------------------------------------------------------------------------------------------------------- the AH list
-- At the auction house the saved AH list (SkillupHelperDB.trips) becomes buy rows in a small frame beside
-- Blizzard's AuctionHouseFrame (or on the right of the screen under TSM's AH UI). C_AuctionHouse only. Every purchase
-- step (StartCommoditiesPurchase, ConfirmCommoditiesPurchase, PlaceBid) runs from the user's click on a row; only
-- the price searches run on their own, one at a time, when the AH opens.

-- FrameXML's AH frame and the AH API (the standalone CI globals list in .luacheckrc does not carry them)
-- luacheck: read globals AuctionHouseFrame C_AuctionHouse Enum

UI.ah = { open = false, live = {}, list = {} }
UI.stats.ah = { open = false, shows = 0, searches = 0, rows = 0 }

local AH_SEARCH_TIMEOUT, AH_QUOTE_TIMEOUT = 5, 30

local function ahSorts()
	local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
	return { { sortOrder = order, reverseSort = false } }
end

local function ahError(msg)
	UI.stats.lastAhError = { at = date("%Y-%m-%d %H:%M:%S"), err = msg }
end

function UI.ahEnv()
	local busy = UI.ah.busy
	return { nameOf = itemName, money = ns.Logic.money, gold = GetMoney, busy = busy and busy.item or nil }
end

-- Sends the next price search: one in flight at a time (100 a minute is the client's limit).
local function ahNextSearch()
	local ah = UI.ah
	if not ah.open or ah.searching then
		return
	end
	for _, r in ipairs(ah.list) do
		if not ah.live[r.item] then
			local lv = { state = "searching", kind = r.pattern and "item" or "commodity" }
			ah.live[r.item] = lv
			local ok, err = pcall(function()
				local key = C_AuctionHouse.MakeItemKey(r.item)
				C_AuctionHouse.SendSearchQuery(key, ahSorts(), true)
			end)
			if not ok then
				lv.state, lv.err = "failed", "C_AuctionHouse.SendSearchQuery: " .. tostring(err)
				ahError(lv.err)
			else
				ah.searching = r.item
				UI.stats.ah.searches = UI.stats.ah.searches + 1
				local item = r.item
				C_Timer.After(AH_SEARCH_TIMEOUT, function()
					if ah.searching == item and lv.state == "searching" then
						-- no results event: the search was throttled or dropped. The row offers "Search again".
						lv.state, lv.err = "unavailable", "no search results after 5 s (throttled?)"
						ah.searching = nil
						UI.ahDraw()
						ahNextSearch()
					end
				end)
				return
			end
		end
	end
end

local function commodityResults(item)
	local list = {}
	local n = C_AuctionHouse.GetNumCommoditySearchResults(item) or 0
	for i = 1, n do
		local r = C_AuctionHouse.GetCommoditySearchResultInfo(item, i)
		if type(r) == "table" and not secret(r.unitPrice) and not secret(r.quantity) then
			list[#list + 1] = { unitPrice = r.unitPrice, quantity = r.quantity }
		end
	end
	return list
end

local function itemResults(key)
	local list = {}
	local n = C_AuctionHouse.GetNumItemSearchResults(key) or 0
	for i = 1, n do
		local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
		if type(r) == "table" and not secret(r.buyoutAmount) then
			list[#list + 1] = {
				auctionID = r.auctionID,
				buyoutAmount = r.buyoutAmount,
				quantity = r.quantity,
				containsOwnerItem = r.containsOwnerItem,
			}
		end
	end
	return list
end

local function ahResults(item, kind, results)
	local ah = UI.ah
	local lv = ah.live[item]
	if not lv then
		return
	end
	lv.kind, lv.results = kind, results
	if lv.state == "searching" or lv.state == "unavailable" or lv.state == "failed" then
		lv.state = "listed"
	end
	if ah.searching == item then
		ah.searching = nil
		ahNextSearch()
	end
end

local function ahDone(lv, ok, err)
	local ah, busy = UI.ah, UI.ah.busy
	ah.busy = nil
	local last = UI.stats.lastAhBuy
	if ok then
		lv.state = "bought"
		if busy then
			ns.noteAhBought(busy.item, busy.qty or 1)
			ns.setAhSkip(busy.item, nil)
		end
		if last then
			last.done = true
		end
	else
		lv.state, lv.err = "failed", err
		ahError(err)
		if last then
			last.failed = err
		end
	end
	ns.refresh()
end

-- AH events (Core.lua wires them). Returns nothing; draws the frame when it is up.
function UI.ahEvent(event, a1, a2)
	local ah = UI.ah
	local st = UI.stats.ah
	if event == "AUCTION_HOUSE_SHOW" then
		ah.open, st.open = true, true
		st.shows = st.shows + 1
		ah.live, ah.busy, ah.searching = {}, nil, nil
		ah.list = ns.Logic.ahList(ns.savedTrips())
		st.rows = #ah.list
		UI.ahDraw()
		ahNextSearch()
		return
	elseif event == "AUCTION_HOUSE_CLOSED" then
		if ah.busy and ah.busy.kind == "commodity" then
			pcall(C_AuctionHouse.CancelCommoditiesPurchase)
		end
		ah.open, st.open, ah.busy, ah.searching = false, false, nil, nil
		if UI.ahFrame then
			UI.ahFrame:Hide()
		end
		return
	end
	if not ah.open then
		return
	end
	local busy = ah.busy
	local blv = busy and ah.live[busy.item]
	if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		if not secret(a1) and ah.live[a1] then
			ahResults(a1, "commodity", commodityResults(a1))
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		local id = type(a1) == "table" and a1.itemID
		if id and not secret(id) and ah.live[id] then
			ahResults(id, "item", itemResults(a1))
		end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		-- no item in the payload: it answers the one purchase this panel started, if any
		if blv and busy.kind == "commodity" and blv.state == "quoting" and not secret(a1) and not secret(a2) then
			blv.state, blv.quote, blv.qty = "quoted", { unit = a1, total = a2 }, busy.qty
			busy.quotedAt = GetTime()
			local item = busy.item
			C_Timer.After(AH_QUOTE_TIMEOUT, function()
				local b = UI.ah.busy
				if b and b.item == item and blv.state == "quoted" then
					pcall(C_AuctionHouse.CancelCommoditiesPurchase)
					UI.ah.busy = nil
					blv.state, blv.quote = "listed", nil
					UI.ahDraw()
				end
			end)
		end
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		if blv and busy.kind == "commodity" then
			ah.busy = nil
			blv.state = "unavailable"
			ahError("COMMODITY_PRICE_UNAVAILABLE for item " .. tostring(busy.item))
		end
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		if blv and busy.kind == "commodity" then
			ahDone(blv, true)
		end
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		if blv and busy.kind == "commodity" then
			ahDone(blv, false, "COMMODITY_PURCHASE_FAILED: the client refused the purchase")
		end
	elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
		if blv and busy.kind == "item" and busy.auctionID == a1 then
			ahDone(blv, true)
		end
	elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
		if blv and blv.state == "buying" then
			ahDone(blv, false, "AUCTION_HOUSE_SHOW_ERROR " .. tostring(a1))
		end
	end
	UI.ahDraw()
end

-- A click on an AH row's button. One client call per click; nothing is queued or chained.
function UI.ahAct(a)
	local ah, stats = UI.ah, UI.stats
	stats.clicks[a.id] = (stats.clicks[a.id] or 0) + 1
	if not ah.open then
		ahError("refused at the click: the auction house is closed")
		return false
	end
	local lv = ah.live[a.item]
	if a.id == "ahSearch" then
		ah.live[a.item] = nil
		ahNextSearch()
		UI.ahDraw()
		return true
	end
	if not a.enabled or not lv then
		return false
	end
	if ah.busy and ah.busy.item ~= a.item then
		ahError("refused at the click: another buy is in progress")
		return false
	end
	local now = date("%Y-%m-%d %H:%M:%S")
	local ok, err
	if a.id == "ahStart" then
		ok, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, a.item, a.qty)
		if ok then
			ah.busy = { item = a.item, qty = a.qty, kind = "commodity" }
			lv.state = "quoting"
			stats.lastAhBuy = { at = now, item = a.item, qty = a.qty, kind = "commodity", expect = a.cost }
		else
			err = "C_AuctionHouse.StartCommoditiesPurchase: " .. tostring(err)
		end
	elseif a.id == "ahConfirm" then
		ok, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, a.item, a.qty)
		if ok then
			lv.state = "buying"
			if stats.lastAhBuy then
				stats.lastAhBuy.quote = a.cost
				stats.lastAhBuy.confirmedAt = now
			end
		else
			err = "C_AuctionHouse.ConfirmCommoditiesPurchase: " .. tostring(err)
		end
	elseif a.id == "ahBid" then
		ok, err = pcall(C_AuctionHouse.PlaceBid, a.auctionID, a.buyout)
		if ok then
			ah.busy = { item = a.item, qty = a.qty or 1, kind = "item", auctionID = a.auctionID }
			lv.state = "buying"
			stats.lastAhBuy = { at = now, item = a.item, qty = a.qty or 1, kind = "item", expect = a.buyout }
		else
			err = "C_AuctionHouse.PlaceBid: " .. tostring(err)
		end
	else
		return false
	end
	if not ok then
		lv.state, lv.err = "failed", err
		ah.busy = nil
		ahError(err)
	end
	UI.ahDraw()
	return ok
end

local AH_WIDTH = 300

local function ahRowFrame(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetWidth(AH_WIDTH - 2 * PAD)
	row.name = text(row, "GameFontHighlight", 12)
	row.name:SetPoint("TOPLEFT", 0, 0)
	row.name:SetWidth(AH_WIDTH - 2 * PAD)
	row.name:SetWordWrap(false)
	row.right = text(row, "GameFontHighlightSmall", 11)
	row.right:SetWidth(AH_WIDTH - 2 * PAD)
	row.note = text(row, "GameFontHighlightSmall", 11)
	row.note:SetWidth(AH_WIDTH - 2 * PAD)
	row.button = newButton(row)
	row.button:SetWidth(AH_WIDTH - 2 * PAD)
	return row
end

local function ahFrame()
	if UI.ahFrame then
		return UI.ahFrame
	end
	local f = CreateFrame("Frame", "SkillupHelperAHList", UIParent)
	f:SetWidth(AH_WIDTH)
	f:SetFrameStrata("HIGH")
	f.bg = f:CreateTexture(nil, "BACKGROUND")
	f.bg:SetAllPoints()
	fill(f.bg, "ink", 0.96)
	f.edge = edges(f)
	paintEdges(f.edge, rgb("line"))
	f.title = text(f, "GameFontNormal", 13)
	f.title:SetPoint("TOPLEFT", PAD, -PAD)
	f.title:SetWidth(AH_WIDTH - 2 * PAD)
	f.rows = {}
	UI.ahFrame = f
	return f
end

-- Draws the AH list frame from View.ahPanel, and keeps SkillupHelperDB.ahSkip in step with the rows.
function UI.ahDraw()
	if not UI.ah.open then
		return
	end
	local d = ns.View.ahPanel(UI.ah.list, UI.ah.live, UI.ahEnv())
	for _, r in ipairs(d.rows) do
		if r.skip then
			ns.setAhSkip(r.item, r.skip)
		end
	end
	local f = ahFrame()
	f:ClearAllPoints()
	if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
		f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
	else
		-- TSM's AH UI hides AuctionHouseFrame: sit on the right of the screen
		f:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
	end
	f.title:SetText(d.title)
	local y = PAD + f.title:GetStringHeight() + 8
	if d.empty then
		f.empty = f.empty or text(f, "GameFontHighlightSmall", 11)
		f.empty:SetWidth(AH_WIDTH - 2 * PAD)
		f.empty:ClearAllPoints()
		f.empty:SetPoint("TOPLEFT", PAD, -y)
		f.empty:SetText(d.empty)
		setColor(f.empty, "ash")
		f.empty:Show()
		y = y + f.empty:GetStringHeight() + 6
	elseif f.empty then
		f.empty:Hide()
	end
	for i, r in ipairs(d.rows) do
		local row = f.rows[i] or ahRowFrame(f)
		f.rows[i] = row
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PAD, -y)
		row.name:SetText(r.name)
		setColor(row.name, "bone")
		local h = row.name:GetStringHeight() + 2
		row.right:ClearAllPoints()
		row.right:SetPoint("TOPLEFT", 0, -h)
		row.right:SetText(r.warn and (r.right .. ", " .. r.warn) or r.right)
		setColor(row.right, r.warn and "warn" or "ash")
		h = h + row.right:GetStringHeight() + 2
		if r.note then
			row.note:ClearAllPoints()
			row.note:SetPoint("TOPLEFT", 0, -h)
			row.note:SetText(r.note)
			setColor(row.note, "warn")
			row.note:Show()
			h = h + row.note:GetStringHeight() + 2
		else
			row.note:Hide()
		end
		row.button:ClearAllPoints()
		row.button:SetPoint("TOPLEFT", 0, -(h + 2))
		setButton(row.button, r.action, ns.View.RGB.gold)
		h = h + 2 + 24
		row:SetHeight(h)
		row:Show()
		y = y + h + 10
	end
	for i = #d.rows + 1, #f.rows do
		f.rows[i]:Hide()
	end
	f:SetHeight(y + PAD - 6)
	f:Show()
end
