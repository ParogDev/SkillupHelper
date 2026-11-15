-- The docked panel, the glance beside the profession window: draws View.describe's description. Top to bottom: the
-- header with the skill, the whole path as one strip, the card of the step to do now (two cards, swapped when the
-- skill passes a step) with its buttons, the next few lines, and the button into the journal. Nothing here scrolls
-- and nothing is clipped: the panel is as tall as what it shows, never taller than the window it is docked to, and
-- what does not fit is left out whole by View.fit (the journal has it). Rows are pooled; frames are made only when
-- a pool is short.
local _, ns = ...
local UI = {}
ns.UI = UI

-- The panel is WIDTH wide; its content column is INNER wide, LEFT from the edge.
local WIDTH, INNER, LEFT = 316, 296, 10
local PAD = 12
local FREE_HEIGHT = 600 -- the tallest the panel gets with no window to dock to
local DOCK_GAP, TAB_GAP = 2, 4
local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION = 134400 -- INV_Misc_QuestionMark
local HANDLE_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local BAR_H, BAR_GAP = 24, 6 -- the action bar's buttons and the space between its rows
local PATH_H = 8 -- the path strip's bar
local SLIDE = 10 -- how far a card slides when the step changes: inside the panel's margin, nothing clips it

-- Panel diagnostics for the selftest.
UI.stats = {
	layout = "glance",
	views = {},
	animations = 0,
	played = {},
	docks = {},
	clicks = { craft = 0, open = 0, hide = 0, show = 0, buy = 0 },
	merchant = { open = false, shows = 0 },
}

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- A client count, or `default` when it is missing, not a number or a secret value.
local function cnt(v, default)
	if secret(v) or type(v) ~= "number" then
		return default
	end
	return v
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
	local plan = ns.plan and ns.plan()
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

-- The MerchantItemInfo fields an offer reads: any one secret makes the offer "not now".
local OFFER_FIELDS = { "price", "stackCount", "numAvailable", "hasExtendedCost", "currencyID", "isPurchasable" }

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
			for _, k in ipairs(OFFER_FIELDS) do
				if secret(info[k]) then
					return nil, "the vendor's offer is a secret value here"
				end
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
				maxStack = cnt(maxStack, nil),
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
	stack = cnt(stack, nil)
	if not stack then
		return nil -- item info not cached yet (or a secret): room unknown, the client refuses a buy that does not fit
	end
	isReagent = not secret(isReagent) and isReagent == true
	local family = cnt(C_Item.GetItemFamily and C_Item.GetItemFamily(item), 0)
	local bags = NUM_BAG_SLOTS or 4
	local free = 0
	for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or bags do
		local n, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
		n, bagFamily = cnt(n, 0), cnt(bagFamily, 0)
		if n > 0 then
			local fits
			if bag > bags then
				fits = isReagent
			else
				fits = bagFamily == 0 or bit.band(bagFamily, family) ~= 0
			end
			if fits then
				free = free + n
			end
		end
	end
	return ns.Logic.bagRoom(free, stack, cnt(C_Item.GetItemCount(item), 0))
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
		queued = ns.MailUI and ns.MailUI.queued or nil,
		mailQueue = ns.MailUI and ns.MailUI.toMe or nil,
		spellName = UI.spellName,
	}
end

-- A spell's name for the More tab's lists, or "spell <id>" when the client has none (or hands a secret).
function UI.spellName(id)
	local ok, name = pcall(C_Spell.GetSpellName, id)
	if ok and type(name) == "string" and not secret(name) and name ~= "" then
		return name
	end
	return "spell " .. tostring(id)
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
		local done, before = 0, cnt(C_Item.GetItemCount(it.item), 0)
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
		local now = cnt(C_Item.GetItemCount(it.item), nil)
		if it.got == nil and now then
			it.got = now - (it.before or 0)
			if it.got < it.requested and not UI.stats.lastBuyError then
				UI.stats.lastBuyError = ("item %d: asked for %d, the bags got %d"):format(it.item, it.requested, it.got)
			end
		end
	end
end

-- Selects a recipe in Blizzard's open crafting page without a server trip: RecipeList:SelectRecipe fires
-- OnRecipeSelected -> CraftingPage:SelectRecipe. Returns the element data, or nil when the list does not hold the
-- recipe (another profession, filtered, collapsed) or the page is not up (TSM's window, another tab).
local function selectInList(spell)
	local frame = ProfessionsFrame
	local page = frame and frame:IsShown() and frame.CraftingPage
	local list = page and page:IsShown() and page.RecipeList
	if not (list and list.SelectRecipe and list.ScrollBox) then
		return nil, "crafting page not shown"
	end
	local info = C_TradeSkillUI.GetRecipeInfo(spell)
	if type(info) ~= "table" then
		return nil, "no recipe info"
	end
	local data = list:SelectRecipe(info, false)
	if not data then
		return nil, "not in the list"
	end
	list.ScrollBox:ScrollToElementData(data)
	return data
end

-- "Show recipe": select it in the open list (instant), else C_TradeSkillUI.OpenRecipe (a server round trip that
-- rebuilds the whole list). stats.lastOpen names the path that ran and why the fast one was skipped.
function UI.showRecipe(spell)
	local stats = UI.stats
	local ok, data, why = pcall(selectInList, spell)
	if ok and data then
		stats.lastOpen = { path = "list", spell = spell }
		stats.lastOpenError = nil
		return true
	end
	local skipped = ok and why or ("RecipeList:SelectRecipe: " .. tostring(data))
	local ok2, err = pcall(C_TradeSkillUI.OpenRecipe, spell)
	stats.lastOpen = { path = "OpenRecipe", spell = spell, why = skipped }
	stats.lastOpenError = not ok2 and ("C_TradeSkillUI.OpenRecipe: " .. tostring(err)) or nil
	return ok2
end

-- What the panel last showed (skill, profession). Journal.lua reads `preview` for the step to open at: the panel
-- previews nothing any more, so it is always nil and the journal opens at the step to do now.
UI.state = {}

-- The sections the user folded (SkillupHelperDB.ui.collapsed: key -> true or false), created on first use.
local function savedCollapsed()
	local db = SkillupHelperDB
	if type(db) ~= "table" then
		UI.stats.collapsedWhy = "SkillupHelperDB absent: section folds are not saved"
		return {}
	end
	db.ui = type(db.ui) == "table" and db.ui or {}
	db.ui.collapsed = type(db.ui.collapsed) == "table" and db.ui.collapsed or {}
	return db.ui.collapsed
end

-- A click on a card button. Each client call runs under pcall and leaves its result in UI.stats (selftest ui).
-- Only ever called from a button's OnClick: a craft needs the user's own click.
function UI.act(a)
	local stats = UI.stats
	if type(a) == "table" and type(a.id) == "string" and a.id:sub(1, 2) == "ah" then
		return UI.ahAct(a)
	end
	-- into the journal: the button, a next line, a link line, a click on the path strip
	if type(a) == "table" and a.id == "journal" then
		stats.clicks.journal = (stats.clicks.journal or 0) + 1
		if not (ns.JournalUI and ns.JournalUI.open) then
			stats.journalWhy = "JournalUI is not loaded: the journal cannot open"
			return false
		end
		stats.journalWhy = nil
		stats.lastJournal = { page = a.page, step = a.step }
		ns.JournalUI.open(a.page, { profession = a.profession, step = a.step })
		return true
	end
	if type(a) == "table" and a.id == "buy" then
		return a.enabled and buy(a) or false
	end
	-- a section folded on one of the journal's lists (SkillupHelperDB.ui.collapsed): no craft, purchase or mail
	if type(a) == "table" and a.id == "section" then
		if not a.enabled then
			return false
		end
		stats.clicks.section = (stats.clicks.section or 0) + 1
		savedCollapsed()[a.key] = not a.collapsed
		return UI.redraw()
	end
	-- a settings control: a setting the slash commands also write; it replans (never crafts, buys or mails)
	if type(a) == "table" and a.id == "setting" then
		if not a.enabled then
			return false
		end
		stats.clicks.setting = (stats.clicks.setting or 0) + 1
		stats.lastSetting = tostring(a.key)
		return ns.setSetting(a)
	end
	if type(a) == "table" and type(a.id) == "string" and a.id:sub(1, 4) == "mail" and ns.MailUI then
		stats.clicks[a.id] = (stats.clicks[a.id] or 0) + 1
		return ns.MailUI.act(a)
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
	if a.id == "useShortcut" or a.id == "hideShortcut" then
		stats.clicks[a.id] = (stats.clicks[a.id] or 0) + 1
		if a.id == "useShortcut" then
			return ns.useShortcut(a.spell, true)
		end
		return ns.hideShortcut(a.spell)
	elseif a.id == "swap" or a.id == "unswap" then
		stats.clicks[a.id] = (stats.clicks[a.id] or 0) + 1
		if a.id == "swap" then
			return not secret(a.from) and ns.useSwap(a.from, a.spell) or false
		end
		return ns.clearSwap(a.spell)
	elseif a.id == "open" then
		stats.clicks.open = stats.clicks.open + 1
		return UI.showRecipe(a.spell)
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
		-- `strong`: an outline button that is the way on (Open the journal) keeps its label bright
		setColor(b.label, (over or b.strong) and "bone" or "ash")
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
		local plan = ns.plan and ns.plan()
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

-- Whole screen pixels for a computed position or size (Widgets.px): strip segments, 1-px rules, the now-marker.
local function px(v, min)
	local W = ns.Widgets
	if W and W.px and UI.frame then
		return W.px(UI.frame, v, min)
	end
	return v
end

-- A button whose label may need two rows: the label wraps inside `w` and the button grows, so no label is cut.
local function fitButton(b, w, minH)
	b:SetWidth(w)
	b.label:SetWordWrap(true)
	b.label:ClearAllPoints()
	b.label:SetPoint("LEFT", 8, 0)
	b.label:SetWidth(w - 16)
	local h = math.max(minH, math.ceil((b.label:GetStringHeight() or 0) + 8))
	b:SetHeight(h)
	return h
end

---------------------------------------------------------------------------------------------------------- guide strip
-- Where to go for the step on the card: the guide chip's arrow, name and distance (GuideUI.lua decides, Guide.strip
-- words it). Plain card content: it takes no part in docking, and the Target button stays on the chip. Both lines
-- wrap, so a long name is never cut; the strip is as tall as they are.

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
	s.a:SetWidth(STRIP_W - 20)
	s.b = text(s, "GameFontHighlightSmall", 10)
	s.b:SetPoint("TOPLEFT", s.a, "BOTTOMLEFT", 0, -2)
	s.b:SetWidth(STRIP_W - 20)
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

-- Paints a strip from Guide.strip's table and returns its height; collapsed = the Buy button carries the action
-- ("You are here" alone).
local function paintStrip(s, g, color, collapsed)
	-- the guide ticks at 10 Hz: repaint only what changed
	local sig = table.concat({
		tostring(g.a),
		tostring(g.ar),
		tostring(g.arTint),
		tostring(g.b),
		tostring(g.phase),
		tostring(g.icon),
		tostring(g.tint),
		tostring(color),
		tostring(collapsed),
	}, "|")
	if sig == s.sig then
		return s.h
	end
	s.sig = sig
	s.ar:SetText(g.ar or "")
	setColor(s.ar, g.arTint or "ash")
	-- the name wraps in what the distance leaves it
	local arW = (g.ar and g.ar ~= "") and ((s.ar:GetStringWidth() or 0) + 8) or 0
	s.a:SetWidth(STRIP_W - 20 - arW)
	s.a:SetText(g.a or "")
	setColor(s.a, g.phase == "here" and "green" or (g.phase == "unknown" or g.phase == "notnow") and "ash" or "bone")
	local b = not collapsed and g.b or nil
	s.b:SetText(b or "")
	setColor(s.b, "ash")
	s.b:SetShown(b ~= nil)
	s.tip = g.tip
	s.h = math.ceil(7 + math.max(14, s.a:GetStringHeight() or 0) + (b and (2 + (s.b:GetStringHeight() or 0)) or 0) + 7)
	s:SetHeight(s.h)
	local icon, tint = g.icon, g.tint
	if icon == s.icon and tint == s.tint and color == s.color then
		return s.h
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
	return s.h
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
	-- the title and the line under it wrap beside the icon: "Craft 12 Rough Grinding Stone", "28 to 40, orange"
	card.title = text(card, "GameFontHighlightLarge", 15)
	card.title:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, 1)
	card.title:SetWidth(INNER - PAD * 2 - 46)
	card.sub = text(card, "GameFontHighlight", 12)
	card.sub:SetWidth(INNER - PAD * 2 - 46)
	card.lines = {} -- what to buy, what it costs, the notes: sentences that wrap, made as needed
	card.links = {}
	card.guide = newStrip(card)
	-- what a line shortened ("Also buy 4 Salt and 2 more", "price unknown for 2 items") is read whole on hover;
	-- clicks pass through to the panel
	card:EnableMouse(true)
	if card.SetMouseClickEnabled then
		card:SetMouseClickEnabled(false)
	end
	card:SetScript("OnEnter", function(self)
		local tips = {}
		for _, l in ipairs(self.tips or {}) do
			tips[#tips + 1] = l.tip
		end
		showTip(self, #tips > 0 and table.concat(tips, "\n\n") or nil)
	end)
	card:SetScript("OnLeave", hideTip)

	-- slide: in from the right with a fade, out to the left
	local ig = card:CreateAnimationGroup()
	local inMove = ig:CreateAnimation("Translation")
	inMove:SetOffset(-SLIDE, 0)
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
	outMove:SetOffset(-SLIDE, 0)
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

-- Fills a card from a View card (title, sub, lines, links, the guide strip) and returns its height and how much of
-- it the notes take. `noNotes` leaves the notes out (View.fit dropped them); everything else always shows.
local function fillCard(card, c, noNotes)
	local col = c.color
	local r, g, b = rgb(col)
	card.stripe:SetColorTexture(r, g, b, 1)
	card.wash:SetColorTexture(r, g, b, 0.07)
	for _, t in ipairs(card.rim) do
		t:SetColorTexture(r, g, b, 0.55)
	end
	card.icon:SetTexture(iconOf(c))
	card.icon:SetShown(c.kind ~= "gap" and c.kind ~= "world")
	card.title:SetText(c.title or c.name or "")
	card.title:SetTextColor(r, g, b, 1)
	card.sub:SetText(c.sub or "")
	setColor(card.sub, "bone")
	card.sub:ClearAllPoints()
	card.sub:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)
	local textHeight = card.title:GetStringHeight() + 4 + card.sub:GetStringHeight()
	local top = PAD + math.max(36, textHeight) + 8
	local wide = INNER - PAD * 2 - 2

	-- the lines: what to buy, what it costs, then the notes; each wraps, none is cut
	local noteH, shown = 0, 0
	for k = 1, math.max(#card.lines, #(c.lines or {})) do
		local e = c.lines and c.lines[k]
		local fs = card.lines[k]
		if e and not (noNotes and e.note) then
			if not fs then
				fs = text(card, "GameFontHighlightSmall", 11)
				fs:SetWidth(wide)
				card.lines[k] = fs
				UI.frame.grew = true
			end
			shown = shown + 1
			local gap = shown == 1 and 0 or 3
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -(top + gap))
			fs:SetText(e.text)
			setColor(fs, e.color)
			fs:Show()
			local h = gap + math.ceil(fs:GetStringHeight())
			top = top + h
			noteH = noteH + (e.note and h or 0)
		elseif fs then
			fs:Hide()
		end
	end
	card.tips = c.lines

	-- link lines: one per journal page that holds more for this plan (Shopping, Alts and mail)
	for i, l in ipairs(c.links or {}) do
		local lb = card.links[i]
		if not lb then
			lb = newButton(card)
			lb.label:SetJustifyH("LEFT")
			card.links[i] = lb
			UI.frame.grew = true
		end
		top = top + (i == 1 and 8 or 3)
		lb:ClearAllPoints()
		lb:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		setButton(lb, l.action, ns.View.RGB[l.tone] or ns.View.RGB.ash)
		lb.style = "quiet"
		paintButton(lb)
		setColor(lb.label, l.tone or "ash")
		top = top + fitButton(lb, wide, 18)
	end
	for i = #(c.links or {}) + 1, #card.links do
		card.links[i]:Hide()
	end

	-- the card's actions sit in the bar under it (drawBar); the strip only needs to know of Buy
	local buying = false
	for _, a in ipairs(c.actions or {}) do
		buying = buying or a.id == "buy"
	end

	-- where to go for this step (the guide)
	local gs = ns.GuideUI and ns.GuideUI.strip and ns.GuideUI.strip() or nil
	card.stripBuy = buying
	card.stripColor = col
	card.stripH = 0
	if gs then
		top = top + 8
		local s = card.guide
		s:ClearAllPoints()
		s:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 2, -top)
		card.stripH = paintStrip(s, gs, col, gs.phase == "here" and buying)
		s:Show()
		top = top + card.stripH
	else
		card.guide:Hide()
	end

	UI.stats.actionsWhy = c.actionsWhy
	local h = top + PAD
	card:SetHeight(h)
	return h, noteH
end

---------------------------------------------------------------------------------------------------------- next lines

-- One line under "Next": a pip in the line's colour, its number, the title (it wraps to a second row, it is never
-- cut) and under it the range and the cost. A click opens that step in the journal.
local NEXT_X = 34 -- where a line's text starts, right of the pip and the number
local NEXT_W = INNER - NEXT_X - 4

local function newNextRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(INNER, 18)
	row:RegisterForClicks("LeftButtonUp")
	row.hover = row:CreateTexture(nil, "BACKGROUND")
	row.hover:SetAllPoints()
	fill(row.hover, "line", 0.5)
	row.hover:Hide()
	row:SetScript("OnEnter", function(self)
		self.hover:Show()
		local e = self.info
		if e and e.action then
			showTip(self, (e.tip and (e.tip .. "\n") or "") .. "Click: open this step in the journal")
		end
	end)
	row:SetScript("OnLeave", function(self)
		self.hover:Hide()
		hideTip(self)
	end)
	row:SetScript("OnClick", function(self)
		hideTip(self)
		if self.info and self.info.action then
			ns.guard("click", UI.act, self.info.action)
		end
	end)
	row.pip = row:CreateTexture(nil, "ARTWORK")
	row.pip:SetSize(6, 6)
	row.pip:SetPoint("TOPLEFT", 4, -7)
	row.n = text(row, "GameFontHighlightSmall", 11)
	row.n:SetPoint("TOPLEFT", 14, -4)
	row.n:SetWidth(16)
	row.n:SetJustifyH("RIGHT")
	row.n:SetWordWrap(false)
	row.title = text(row, "GameFontHighlight", 12)
	row.title:SetPoint("TOPLEFT", NEXT_X, -3)
	row.title:SetWidth(NEXT_W)
	row.meta = text(row, "GameFontHighlightSmall", 10)
	row.meta:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
	row.meta:SetWidth(NEXT_W)
	return row
end

-- Fills a row from a View.nextLines entry and returns its height.
local function fillNextRow(row, e)
	row.info = e
	fill(row.pip, e.color or "ash")
	row.n:SetText(e.n and tostring(e.n) or "")
	setColor(row.n, "ash")
	row.title:SetText(e.title or "")
	setColor(row.title, e.kind == "rank" and "gold" or "bone")
	local h = 3 + math.ceil(row.title:GetStringHeight())
	if e.meta and e.meta ~= "" then
		row.meta:SetText(e.meta)
		setColor(row.meta, e.tone or "ash")
		row.meta:Show()
		h = h + 2 + math.ceil(row.meta:GetStringHeight())
	else
		row.meta:Hide()
	end
	h = h + 4
	row:SetHeight(h)
	return h
end

---------------------------------------------------------------------------------------------------------- path strip

-- The whole path, skill 1 to 300, on the panel's width (View.strip): a segment per plan line in its colour, what is
-- done dimmed, a hole in the warn colour between two solid edges, 1-px ticks at the rank caps, the now-marker at the
-- skill. Every x comes from the view as a 0..1 fraction and is put on whole pixels here. Hover names the line under
-- the cursor; a click opens it in the journal.
local function newPath(f)
	local s = CreateFrame("Button", nil, f)
	s:SetSize(INNER, PATH_H)
	s:RegisterForClicks("LeftButtonUp")
	s.track = s:CreateTexture(nil, "BACKGROUND")
	s.track:SetAllPoints()
	fill(s.track, "line", 0.6)
	s.segs, s.edges, s.ticks = {}, {}, {}
	s.now = s:CreateTexture(nil, "OVERLAY", nil, 2)
	fill(s.now, "bone")
	s.caption = text(f, "GameFontHighlightSmall", 10)
	s.caption:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -6)
	s.caption:SetWordWrap(false)
	s.right = text(f, "GameFontHighlightSmall", 10)
	s.right:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", 0, -6)
	s.right:SetJustifyH("RIGHT")
	s.right:SetWordWrap(false)
	local function under(self)
		local cx = cnt(GetCursorPosition and GetCursorPosition(), nil)
		local scale, left, w = self:GetEffectiveScale(), self:GetLeft(), self:GetWidth()
		if not cx or type(left) ~= "number" or not scale or scale <= 0 or not w or w <= 0 then
			return nil
		end
		return ns.View.stripAt(self.model, (cx / scale - left) / w)
	end
	s:SetScript("OnEnter", function(self)
		self.seg = false
		self:SetScript("OnUpdate", function(me)
			local seg = under(me)
			if seg ~= me.seg then
				me.seg = seg
				hideTip(me)
				showTip(me, seg and seg.tip)
			end
		end)
	end)
	s:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		hideTip(self)
	end)
	s:SetScript("OnClick", function(self)
		local seg = under(self)
		local j = UI.last and UI.last.journal
		if j then
			ns.guard("click", UI.act, {
				id = "journal",
				page = "path",
				profession = j.profession,
				step = seg and seg.step or j.step,
				enabled = true,
			})
		end
	end)
	return s
end

-- Draws a View.strip on the path frame. Returns what it drew, for the selftest.
local function paintPath(s, strip, runway)
	s.model = strip
	local w = INNER
	local one = px(1, 1)
	local nSeg, nEdge = 0, 0
	for _, seg in ipairs(strip.segments) do
		nSeg = nSeg + 1
		local t = s.segs[nSeg]
		if not t then
			t = s:CreateTexture(nil, "ARTWORK")
			s.segs[nSeg] = t
			UI.frame.grew = true
		end
		local x0, x1 = px(seg.x0 * w), px(seg.x1 * w)
		-- a pixel of the track between two segments, unless the segment is no wider than that
		local width = math.max(one, x1 - x0 - (x1 - x0 > 2 * one and one or 0))
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", s, "TOPLEFT", x0, 0)
		t:SetSize(width, PATH_H)
		fill(t, seg.color, seg.none and 0 or (seg.gap and 0.3) or (seg.done and 0.35) or 1)
		t:Show()
		if seg.gap then
			-- a hole reads without its colour: a solid edge on each side
			for _, x in ipairs({ x0, math.max(x0, x0 + width - one) }) do
				nEdge = nEdge + 1
				local e = s.edges[nEdge]
				if not e then
					e = s:CreateTexture(nil, "ARTWORK", nil, 1)
					s.edges[nEdge] = e
					UI.frame.grew = true
				end
				e:ClearAllPoints()
				e:SetPoint("TOPLEFT", s, "TOPLEFT", x, 0)
				e:SetSize(one, PATH_H)
				fill(e, "warn")
				e:Show()
			end
		end
	end
	for i = nSeg + 1, #s.segs do
		s.segs[i]:Hide()
	end
	for i = nEdge + 1, #s.edges do
		s.edges[i]:Hide()
	end
	for i, cap in ipairs(strip.caps) do
		local t = s.ticks[i]
		if not t then
			t = s:CreateTexture(nil, "OVERLAY", nil, 1)
			s.ticks[i] = t
			UI.frame.grew = true
		end
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", s, "TOPLEFT", px(cap.x * w), 0)
		t:SetSize(one, PATH_H + px(3))
		fill(t, "bone", 0.7)
		t:Show()
	end
	for i = #strip.caps + 1, #s.ticks do
		s.ticks[i]:Hide()
	end
	local nowW = px(2, 2)
	s.now:ClearAllPoints()
	s.now:SetPoint("TOPLEFT", s, "TOPLEFT", math.max(0, math.min(w - nowW, px(strip.now.x * w) - one)), px(3))
	s.now:SetSize(nowW, PATH_H + px(6))
	s.caption:SetText(strip.caption or "")
	setColor(s.caption, strip.gaps > 0 and "warn" or "ash")
	s.right:SetText(runway and runway.label or "")
	if runway then
		s.right:SetTextColor(rgb(runway.next))
	end
	return { segments = nSeg, gaps = strip.gaps, now = strip.now.skill }
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

-- Puts the panel on whole screen pixels (Widgets.snap): text and 1-px rules then look the same wherever the window
-- it is docked to sits. Called after it is docked, shown, resized or dragged.
function UI.snap()
	local f, W = UI.frame, ns.Widgets
	if not (f and W and W.snap) then
		UI.stats.snapWhy = "Widgets.snap absent: the panel is not put on whole pixels"
		return false
	end
	local ok, why = W.snap(f)
	UI.stats.snapped = (UI.stats.snapped or 0) + 1
	UI.stats.snapWhy = not ok and why or nil
	return ok
end

-- The limit changed (another window, a resized one): lays the last description out again under it.
function UI.fit()
	if UI.frame and UI.last then
		UI.draw(UI.last, UI.last)
	end
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
		-- never taller than the window it stands beside
		local h = target:GetHeight()
		limit = (not secret(h) and type(h) == "number" and h > 0) and h or FREE_HEIGHT
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
	if f.dockedTo ~= key or f.dockGap ~= gap then
		f:ClearAllPoints()
		if target then
			f:SetPoint("TOPLEFT", target, "TOPRIGHT", gap, 0)
		else
			-- by its top, so the panel does not jump when its height follows the content
			local at = f.freePoint
			if at then
				f:SetPoint(at[1], UIParent, at[1], at[2], at[3])
			else
				f:SetPoint("TOP", UIParent, "CENTER", 300, FREE_HEIGHT / 2)
			end
		end
		f.dockedTo, f.dockGap = key, gap
		UI.stats.dockGap = gap
	end
	-- the docked window may have moved since the last look (the user dragged it): back on whole pixels
	if f.IsShown and f:IsShown() then
		UI.snap()
	end
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
	if open and shown then
		UI.snap()
	end
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
	f:SetScript("OnDragStop", function(self)
		-- stop, land on whole pixels, and keep the place for the next time the panel is free
		local W = ns.Widgets
		local at
		if W and W.dragStop then
			at = W.dragStop(self)
		else
			self:StopMovingOrSizing()
		end
		self.freePoint = at
		if at and type(SkillupHelperDB) == "table" then
			SkillupHelperDB.ui = type(SkillupHelperDB.ui) == "table" and SkillupHelperDB.ui or {}
			SkillupHelperDB.ui.panelPoint = at
		end
	end)
	local saved = type(SkillupHelperDB) == "table"
		and type(SkillupHelperDB.ui) == "table"
		and SkillupHelperDB.ui.panelPoint
	if
		type(saved) == "table"
		and type(saved[1]) == "string"
		and type(saved[2]) == "number"
		and type(saved[3]) == "number"
	then
		f.freePoint = saved
	end
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
	-- the open-journal button left of the hide control (Journal.lua, guarded: the panel never depends on it)
	f.journal = ns.Provider and ns.Provider.openButton(f) or nil
	if f.journal then
		f.skill:ClearAllPoints()
		f.skill:SetPoint("TOPRIGHT", -56, -PAD)
	end

	-- the whole path as one strip under the header
	f.path = newPath(f)
	f.path:SetPoint("TOPLEFT", LEFT, -36)

	f.stale = text(f, "GameFontHighlightSmall", 10)
	f.stale:SetWidth(INNER)
	f.message = text(f, "GameFontHighlight", 12)
	f.message:SetWidth(INNER - 8)

	-- the cards sit on a home anchor; a card sliding in starts right of it and re-anchors when done
	f.home = CreateFrame("Frame", nil, f)
	f.home:SetSize(INNER, 1)
	f.home:SetPoint("TOPLEFT", LEFT, -60)
	f.cards = { newCard(f), newCard(f) }
	for _, c in ipairs(f.cards) do
		c.home = f.home
		c:SetPoint("TOPLEFT", f.home, "TOPLEFT", 0, 0)
		c:Hide()
	end
	f.current = 1

	-- the card's buttons, right under it
	local ab = CreateFrame("Frame", nil, f)
	ab:SetSize(INNER, 1)
	ab.buttons = {}
	ab:Hide()
	f.actions, f.barH = ab, 0

	-- the next few lines, and the way to all the others
	f.nextLabel = text(f, "GameFontNormalSmall", 11)
	f.nextLabel:SetText("Next")
	f.nextRows = {}
	f.journalButton = newButton(f)
	f.journalButton:SetSize(INNER, 22)

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
	-- every region rounds its own layout to whole pixels (Widgets "pixels"); pools that grow do it again in UI.draw
	if ns.Widgets and ns.Widgets.roundAll then
		ns.Widgets.roundAll(f)
		ns.Widgets.roundAll(h)
	else
		UI.stats.snapWhy = "Widgets.roundAll absent: the panel's regions do not round to whole pixels"
	end
	return f
end

---------------------------------------------------------------------------------------------------------- drawing

-- The card's buttons (View.actionBar rows): full-width rows for Queue mail and Buy, then Craft with Show recipe at
-- its right. A label too long for its button wraps and the button grows. Returns the bar's height (0 without one).
local function drawBar(f, rows, color)
	local bar = f.actions
	local used = 0
	local y = 6
	for _, row in ipairs(rows or {}) do
		local rowH, x = BAR_H, 0
		for k, a in ipairs(row) do
			used = used + 1
			local b = bar.buttons[used]
			if not b then
				b = newButton(bar)
				bar.buttons[used] = b
				f.grew = true
			end
			local accent = (a.id == "mailQueue" or a.id == "buy") and ns.View.RGB.gold
				or (a.id == "open" or a.id == "mailUnqueue") and ns.View.RGB.bone
				or ns.View.RGB[color or "bone"]
				or ns.View.RGB.bone
			setButton(b, a, accent)
			-- the wide button first, the narrow one (Show recipe) at its right
			local w = #row == 1 and INNER or (k == 1 and INNER - 96 - 6 or 96)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -y)
			rowH = math.max(rowH, fitButton(b, w, BAR_H))
			x = x + w + 6
		end
		for k = used - #row + 1, used do
			bar.buttons[k]:SetHeight(rowH)
		end
		y = y + rowH + BAR_GAP
	end
	for i = used + 1, #bar.buttons do
		bar.buttons[i]:Hide()
	end
	f.barH = used > 0 and (y - BAR_GAP) or 0
	bar:SetHeight(math.max(1, f.barH))
	bar:SetShown(used > 0)
	UI.stats.bar = { rows = rows and #rows or 0, buttons = used }
	return f.barH
end

-- Header, path strip, stale line; returns the y offset where the content starts.
local function drawHeader(f, d)
	local h = d.header
	f.title:SetText(h and h.title or "Skill-up helper")
	f.skill:SetText(h and h.skill or "")
	setColor(f.skill, "bone")
	local y = 36
	if d.strip then
		UI.stats.views.strip = paintPath(f.path, d.strip, d.runway)
		f.path:Show()
		f.path.caption:Show()
		f.path.right:Show()
		y = y + PATH_H + 6 + 10 + 10
	else
		UI.stats.views.strip = nil
		f.path:Hide()
		f.path.caption:Hide()
		f.path.right:Hide()
	end
	if h and h.stale then
		f.stale:ClearAllPoints()
		f.stale:SetPoint("TOPLEFT", LEFT, -y)
		f.stale:SetText(h.stale)
		setColor(f.stale, "ash")
		f.stale:Show()
		y = y + math.ceil(f.stale:GetStringHeight()) + 6
	else
		f.stale:Hide()
	end
	return y
end

-- Draws a description. prev is the last one drawn, for the transition. Every piece is filled and measured first;
-- View.fit then says which of the optional ones (the next lines, the card's notes) fit under the docked window's
-- height, and only those are placed. The panel ends up exactly as tall as what it shows.
function UI.draw(d, prev)
	local f = UI.frame
	local views = UI.stats.views
	local y = drawHeader(f, d)
	-- the handle wears the colour of the step it hides
	local handle = UI.handle
	handle.color = d.now and d.now.color or "gold"
	fill(handle.stripe, handle.color)

	if d.state == "message" or d.notice or d.empty then
		f.message:ClearAllPoints()
		f.message:SetPoint("TOPLEFT", LEFT + 4, -y)
		f.message:SetText(d.message or d.notice or d.empty)
		setColor(f.message, d.tone or (d.notice and "warn" or "ash"))
		f.message:Show()
		y = y + math.ceil(f.message:GetStringHeight()) + 10
	else
		f.message:Hide()
	end
	f.home:ClearAllPoints()
	f.home:SetPoint("TOPLEFT", LEFT, -y)

	local how = ns.View.transition(prev, d)
	local cur = f.cards[f.current]
	local cardH, noteH = 0, 0
	if d.now then
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
		cardH, noteH = fillCard(cur, d.now)
		cur:SetFrameLevel(f:GetFrameLevel() + 2)
	else
		for _, c in ipairs(f.cards) do
			c.live = false
			c.pulse:Stop()
			c:Hide()
		end
	end
	local barH = drawBar(f, d.now and d.now.bar, d.now and d.now.color)

	-- the next lines, filled to be measured
	local entries = d.next and d.next.entries or {}
	local heights = {}
	for i, e in ipairs(entries) do
		local row = f.nextRows[i]
		if not row then
			row = newNextRow(f)
			f.nextRows[i] = row
			f.grew = true
		end
		heights[i] = fillNextRow(row, e)
	end
	local jb = f.journalButton
	local journalH = 0
	if d.journal then
		setButton(jb, d.journal, ns.View.RGB.gold)
		jb.style, jb.strong = "quiet", true
		paintButton(jb)
		journalH = 10 + fitButton(jb, INNER, 22)
	else
		jb:Hide()
	end

	-- what always shows, then the optional pieces, the most important first
	local fixed = y + (cardH - noteH) + barH + journalH + 10
	local optional = {}
	local function piece(key, h)
		optional[#optional + 1] = { key = key, h = h }
	end
	if heights[1] then
		piece("next1", 12 + 16 + heights[1])
	end
	if heights[2] then
		piece("next2", heights[2])
	end
	if noteH > 0 then
		piece("note", noteH)
	end
	for i = 3, #heights do
		piece("next" .. i, heights[i])
	end
	-- a pixel under the window's height: the snap to whole pixels below may round the panel up by half of one
	local fit = ns.View.fit(fixed, optional, (f.limit or FREE_HEIGHT) - px(1, 1))
	if noteH > 0 and not fit.shown.note then
		cardH = fillCard(cur, d.now, true)
	end

	if d.now then
		if how == "advance" then
			cur:SetAlpha(0)
			cur:ClearAllPoints()
			cur:SetPoint("TOPLEFT", cur.home, "TOPLEFT", SLIDE, 0)
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
		y = y + cardH
	end
	f.actions:ClearAllPoints()
	f.actions:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, -y)
	y = y + barH

	local shown = 0
	if fit.shown.next1 then
		y = y + 12
		f.nextLabel:ClearAllPoints()
		f.nextLabel:SetPoint("TOPLEFT", LEFT + 4, -y)
		setColor(f.nextLabel, "gold")
		f.nextLabel:Show()
		y = y + 16
	else
		f.nextLabel:Hide()
	end
	for i, row in ipairs(f.nextRows) do
		if heights[i] and fit.shown["next" .. i] then
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, -y)
			row:Show()
			y = y + heights[i]
			shown = shown + 1
		else
			row:Hide()
		end
	end
	if d.journal then
		y = y + 10
		jb:ClearAllPoints()
		jb:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, -y)
		y = y + journalH - 10
	end

	f:SetSize(WIDTH, fit.height)
	-- new regions round their own layout too; then the window itself goes on whole pixels
	if f.grew and ns.Widgets and ns.Widgets.roundAll then
		ns.Widgets.roundAll(f)
	end
	f.grew = false
	if f:IsShown() then
		UI.snap()
	end
	UI.stats.fit = {
		height = fit.height,
		limit = fit.limit,
		content = fit.content,
		-- where the last piece placed ends, plus the bottom margin: equal to height unless the minimum applied
		laid = y + 10,
		dropped = fit.dropped,
		-- true would mean the layout is wrong: even what must show is taller than the window beside it
		overflow = fit.overflow,
	}
	views.card = d.now and d.now.key or nil
	views.lines = d.now and #(d.now.lines or {}) or 0
	views.links = d.now and #(d.now.links or {}) or 0
	views.next = shown
	views.more = d.next and d.next.more or 0
	views.nextWhy = d.next and d.next.why or nil
end

function UI.show(model)
	local f = UI.frame
	if not f then
		return
	end
	local s = UI.state
	local m = type(model) == "table" and model or {}
	s.skill, s.profession = m.skill, m.profession
	local d = ns.View.describe(model, UI.env())
	UI.draw(d, UI.last)
	UI.last = d
	UI.model = model
end

-- Draws the last model again with the panel state changed by a click (preview, an expander, a section).
function UI.redraw()
	if not (UI.model and UI.frame) then
		return false
	end
	UI.show(UI.model)
	return true
end

-- The guide's tick (GuideUI, 10 Hz and on events): repaints the live card's strip in place, and redraws the panel
-- only when the strip appears, goes, or changes height.
function UI.guideStrip(g)
	local f = UI.frame
	if not f or not f:IsShown() or not UI.last or not UI.last.now then
		return
	end
	local card = f.cards[f.current]
	if not card or not card.live then
		return
	end
	-- in place when the strip keeps its height; a strip that comes, goes or wraps differently is a new layout
	local h = 0
	if g and card.stripH > 0 then
		h = paintStrip(card.guide, g, card.stripColor, g.phase == "here" and card.stripBuy)
	elseif g then
		h = -1
	end
	if h ~= card.stripH then
		UI.stats.stripRelayouts = (UI.stats.stripRelayouts or 0) + 1
		UI.draw(UI.last, UI.last)
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
	local n = cnt(C_AuctionHouse.GetNumCommoditySearchResults(item), 0)
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
	local n = cnt(C_AuctionHouse.GetNumItemSearchResults(key), 0)
	for i = 1, n do
		local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
		if type(r) == "table" and not secret(r.buyoutAmount) and not secret(r.quantity) and not secret(r.auctionID) then
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
	-- the list pages, it never scrolls: Previous / Next only change which rows are drawn
	if a.id == "ahPage" then
		if not a.enabled then
			return false
		end
		ah.page = a.page
		UI.ahDraw()
		return true
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

-- The drawing helpers MailUI.lua builds its mailbox panel with, so it looks like the AH list.
UI.kit = {
	PAD = PAD,
	WIDTH = AH_WIDTH,
	text = text,
	setColor = setColor,
	fill = fill,
	edges = edges,
	paintEdges = paintEdges,
	rgb = rgb,
	newButton = newButton,
	setButton = setButton,
	itemName = itemName,
}

local function ahRowFrame(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetWidth(AH_WIDTH - 2 * PAD)
	row.name = text(row, "GameFontHighlight", 12)
	row.name:SetPoint("TOPLEFT", 0, 0)
	row.name:SetWidth(AH_WIDTH - 2 * PAD)
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
	local d = ns.View.ahPanel(UI.ah.list, UI.ah.live, UI.ahEnv(), UI.ah.page)
	UI.ah.page = d.page
	for _, r in ipairs(d.all) do
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
	-- a list longer than a page: "1 to 5 of 21" between Previous and Next
	if d.pager and not f.pager then
		local pg = CreateFrame("Frame", nil, f)
		pg:SetSize(AH_WIDTH - 2 * PAD, 22)
		pg.prev = newButton(pg)
		pg.prev:SetSize(72, 22)
		pg.prev:SetPoint("LEFT", 0, 0)
		pg.next = newButton(pg)
		pg.next:SetSize(72, 22)
		pg.next:SetPoint("RIGHT", 0, 0)
		pg.text = text(pg, "GameFontHighlightSmall", 11)
		pg.text:SetPoint("LEFT", pg.prev, "RIGHT", 4, 0)
		pg.text:SetPoint("RIGHT", pg.next, "LEFT", -4, 0)
		pg.text:SetJustifyH("CENTER")
		pg.text:SetJustifyV("MIDDLE")
		pg.text:SetWordWrap(false)
		f.pager = pg
	end
	if d.pager then
		local pg = f.pager
		pg:ClearAllPoints()
		pg:SetPoint("TOPLEFT", PAD, -y)
		for _, key in ipairs({ "prev", "next" }) do
			setButton(pg[key], d.pager[key], ns.View.RGB.bone)
			pg[key].style = d.pager[key].enabled and "quiet" or "inert"
			paintButton(pg[key])
		end
		pg.text:SetText(d.pager.text)
		setColor(pg.text, "ash")
		pg:Show()
		y = y + 22 + 10
	elseif f.pager then
		f.pager:Hide()
	end
	UI.stats.ah.rows = #d.all
	UI.stats.ah.page = d.pager and d.pager.text or nil
	f:SetHeight(y + PAD - 6)
	f:Show()
	if ns.Widgets and ns.Widgets.roundAll and ns.Widgets.snap then
		ns.Widgets.roundAll(f)
		ns.Widgets.snap(f)
	end
end
