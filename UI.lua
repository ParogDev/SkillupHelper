-- The side panel on the profession window: text lines built by UI.lines (tested offline), shown in a scroll frame.
local _, ns = ...
local UI = {}
ns.UI = UI

local COLOR = { orange = "ffff8040", yellow = "ffffff00", green = "ff40c040", grey = "ff808080" }
local HEAD, DIM, WARN = "ffffd100", "ffa0a0a0", "ffff6060"
UI.MAX_STOCK_LINES = 15
UI.MAX_STEPS = 8

local function c(hex, text)
	return "|c" .. hex .. text .. "|r"
end

local function itemName(item, fallback)
	local plan = ns.Data and ns.Data.plan
	local info = plan and plan.items and plan.items[item]
	fallback = fallback or (info and info.name)
	return ns.Scan and ns.Scan.itemName(item, fallback) or fallback or ("item " .. item)
end

local LABEL = { "NOW ", "NEXT", "THEN" }
local WHERE = { vendor = "vendor", ah = "AH" }

-- One planner step as panel lines.
local function stepLines(add, st, i, nameOf, money)
	local label = c(HEAD, LABEL[math.min(i, 3)])
	if st.kind == "gap" then
		add(("%s %s"):format(label, c(WARN, ("%d-%d: %s"):format(st.from, st.to, st.why))))
	elseif st.kind == "train" then
		add(("%s Train %s at the trainer (from %d)"):format(label, st.name, st.at))
	elseif st.kind == "buyRecipe" then
		local saves = st.saves and (", saves " .. money(st.saves)) or ""
		add(
			("%s Buy %s (AH %s), learn at %d%s"):format(
				label,
				nameOf(st.item, "Recipe: " .. st.name),
				money(st.price),
				st.learn or 0,
				saves
			)
		)
		if st.alt then
			add(c(DIM, ("      or skip it: %s instead, +%s"):format(st.alt.name, money(st.alt.extra))))
		end
	else
		local pct = st.chance and math.floor(st.chance[1] * 100 + 0.5) or 0
		local col = st.color == "orange" and "orange" or ("%s %d%%"):format(st.color, pct)
		add(
			("%s Craft %dx %s %s  %s"):format(
				label,
				st.crafts,
				c(COLOR[st.color] or HEAD, st.name),
				c(DIM, st.source == "buy" and "" or ("from " .. st.source)),
				c(DIM, ("%s, +%.1f, %d to %.0f"):format(col, st.points, math.floor(st.from), st.to))
			)
		)
		local parts = {}
		for _, b in ipairs(st.buy) do
			parts[#parts + 1] = ("%d %s (%s %s)"):format(
				b.count,
				nameOf(b.item),
				WHERE[b.where] or "?",
				money((b.each or 0) * b.count)
			)
		end
		if #parts > 0 then
			add(c(DIM, "      buy " .. table.concat(parts, ", ")))
		end
		local pre = {}
		for _, p in ipairs(st.pre) do
			pre[#pre + 1] = ("%d %s"):format(p.count, nameOf(p.item))
		end
		if #pre > 0 then
			add(c(DIM, "      craft first: " .. table.concat(pre, ", ")))
		end
		if #st.tags > 0 then
			add(c(DIM, "      " .. table.concat(st.tags, "; ")))
		end
		if st.alt then
			add(
				c(
					DIM,
					("      or use stock: %dx %s, +%s over the path"):format(
						st.alt.crafts,
						st.alt.name,
						money(st.alt.extra)
					)
				)
			)
		end
	end
end

local VERDICT = {
	now = "now",
	alternative = "now, as the alternative",
	ok = "ok",
	later = "keep for later",
	wasteful = "wasteful",
}

-- The planner's sections: warnings about prices, the steps, what to keep, leftovers, the from-stock verdicts.
local function plannerLines(add, m, nameOf)
	local p, money = m.planner, ns.Logic.money
	local age = p.ageHours
	if age == nil then
		add(c(DIM, "TSM data age unknown (Data/Plan.lua has no pricesAt)"))
	elseif age > ns.TSM.STALE_HOURS then
		add(c(DIM, ("TSM data is %.0f h old: sync the TSM app"):format(age)))
	end
	if p.prices and (p.prices.export or 0) > 0 then
		add(c(DIM, ("%d prices from the export (TSM had none)"):format(p.prices.export)))
	end
	add("")
	add(c(HEAD, ("Plan %d to %d"):format(p.skill, p.cap)))
	if #p.steps == 0 then
		add(c(DIM, "No step: nothing gives skill in range."))
	end
	for i, st in ipairs(p.steps) do
		if i > UI.MAX_STEPS then
			add(c(DIM, ("... and %d more steps"):format(#p.steps - UI.MAX_STEPS)))
			break
		end
		stepLines(add, st, i, nameOf, money)
	end
	for _, h in ipairs(p.hold) do
		add(c(DIM, ("Keep %d %s for %s at %d"):format(h.count, nameOf(h.item), h.name, h.at)))
	end
	for _, l in ipairs(p.leftovers) do
		add(
			c(
				DIM,
				("Leftover: %d %s, worth %s (%s); no skill-up use beats the plan"):format(
					l.count,
					nameOf(l.item),
					money(l.value),
					l.how == "ah" and "AH" or "vendor"
				)
			)
		)
	end
	if #p.fromStock > 0 then
		add("")
		add(c(HEAD, "Craftable from bags + bank"))
		for i, e in ipairs(p.fromStock) do
			if i > UI.MAX_STOCK_LINES then
				break
			end
			local v = VERDICT[e.verdict] or e.verdict
			if e.verdict == "wasteful" then
				v = ("wasteful, +%s a point"):format(money(e.extra))
			elseif e.verdict == "later" then
				v = ("keep for %d"):format(e.at or 0)
			end
			add(("  %s x%d  %s"):format(c(COLOR[e.color] or HEAD, e.name), e.crafts, c(DIM, v)))
		end
	end
end

-- The panel's text, one string per line.
function UI.lines(m, nameOf)
	nameOf = nameOf or itemName
	local out = {}
	local function add(s)
		out[#out + 1] = s
	end
	if m.why and not m.skill then
		add(c(m.state == "not now" and DIM or WARN, m.why))
		return out
	end
	add(c(HEAD, ("%s %d/%d"):format(m.profession or "?", m.skill or 0, m.maxSkill or 0)))
	if m.why then
		add(c(WARN, m.why))
	end
	if m.planner then
		plannerLines(add, m, nameOf)
		return out
	end
	if m.plannerWhy then
		add(c(WARN, m.plannerWhy))
	end

	add("")
	add(c(HEAD, "Craft now from bags + bank"))
	if #m.fromStock == 0 then
		add(c(DIM, "Nothing that still gives skill can be crafted from stock."))
	end
	for i, e in ipairs(m.fromStock) do
		if i > UI.MAX_STOCK_LINES then
			add(c(DIM, ("... and %d more"):format(#m.fromStock - UI.MAX_STOCK_LINES)))
			break
		end
		local crafts = e.crafts == math.huge and "vendor mats" or ("x" .. e.crafts)
		local pts = e.points and (" %s%.0f pts"):format(e.guessed and "~" or "", e.points) or ""
		local s = ("%s  %s%s"):format(c(COLOR[e.color], e.name), crafts, c(DIM, pts))
		if #e.toBuy > 0 then
			local buy = {}
			for _, b in ipairs(e.toBuy) do
				buy[#buy + 1] = b.need .. " " .. nameOf(b.item)
			end
			s = s .. c(DIM, "  buy " .. table.concat(buy, ", "))
		end
		add("  " .. s)
	end

	add("")
	local p = m.plan
	if not p then
		add(c(HEAD, "Cheapest next step"))
		add(c(DIM, m.planWhy or "no plan"))
		return out
	end
	add(c(HEAD, ("Cheapest next step (plan %d-%d)"):format(p.from, p.to)))
	if m.planState == "below" then
		add(c(WARN, ("Plan starts at %d; regenerate it (skillup_lua.py)."):format(p.from)))
	elseif m.planState == "done" then
		add(c(DIM, ("Plan done at %d. Train the next rank, then regenerate."):format(p.to)))
	elseif not m.step then
		add(c(DIM, "No step for this skill in the plan."))
	elseif not m.step.recipe then
		add(c(WARN, ("%d-%d: no priced recipe gives skill here"):format(m.step.from, m.step.to)))
	else
		local st = m.step
		add(
			("  %d-%d %s %s"):format(
				st.from,
				st.to,
				c(COLOR[ns.Logic.colorOf(m.skill, st.yellow, st.grey)] or HEAD, st.recipe),
				c(DIM, ("%d/%d/%d"):format(st.yellow, st.green, st.grey))
			)
		)
		add(
			c(
				DIM,
				("  ~%d crafts left, net %s for the step, %s"):format(
					m.craftsLeft or 0,
					ns.Logic.money(st.cost),
					st.source or "?"
				)
			)
		)
		local short = {}
		for _, s in ipairs(m.shopping or {}) do
			if s.short > 0 then
				short[#short + 1] = ("%d %s"):format(s.short, s.name or nameOf(s.item))
			end
		end
		if #short > 0 then
			add("  to buy: " .. table.concat(short, ", "))
		elseif m.shopping and #m.shopping > 0 then
			add(c(COLOR.green, "  materials for the rest of the step are in stock"))
		end
		if m.nextStep and m.nextStep.recipe then
			add(c(DIM, ("  then %d-%d %s"):format(m.nextStep.from, m.nextStep.to, m.nextStep.recipe)))
		end
	end

	if m.buyRecipes and #m.buyRecipes > 0 then
		add("")
		add(c(HEAD, "Recipes worth buying"))
		for _, b in ipairs(m.buyRecipes) do
			local when = b.learnable and c(COLOR.green, "learnable now")
				or c(DIM, ("needs %s"):format(tostring(b.learnRank or "?")))
			add(
				("  %s %s, for %d-%d, %s"):format(
					b.itemName or nameOf(b.item, b.recipe),
					ns.Logic.money(b.price),
					b.from,
					b.to,
					when
				)
			)
		end
	end
	if m.generatedAt then
		add("")
		add(c(DIM, "prices from " .. m.generatedAt))
	end
	return out
end

local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

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

function UI.create()
	if UI.frame then
		return UI.frame
	end
	local f = CreateFrame("Frame", "SkillupHelperPanel", UIParent, "BackdropTemplate")
	f:SetSize(340, 420)
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
	f:SetBackdropColor(0, 0, 0, 0.85)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("Skill-up helper")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function()
		ns.setShown(false)
	end)

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -32)
	scroll:SetPoint("BOTTOMRIGHT", -30, 10)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(300, 10)
	scroll:SetScrollChild(child)

	local text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("TOPLEFT")
	text:SetWidth(300)
	text:SetJustifyH("LEFT")
	text:SetJustifyV("TOP")
	text:SetSpacing(2)
	f.text, f.child = text, child
	UI.frame = f
	return f
end

function UI.show(model)
	local f = UI.frame
	if not f then
		return
	end
	f.text:SetText(table.concat(UI.lines(model), "\n"))
	f.child:SetHeight(math.max(10, (f.text:GetStringHeight() or 0) + 4))
end
