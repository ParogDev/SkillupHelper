-- The guide chip: a small floating frame that says where to go for the step to do now (vendor, trainer, auction
-- house), with an arrow that turns with the player, the distance, and a Target row. It stays up with the profession
-- window closed: that is its point. Guide.lua decides; this file reads the client and draws.
--
-- The Target row is drawn by the chip; the click goes to SkillupHelperGuideTarget, a separate secure button parented
-- to UIParent and laid over the row out of combat only (a frame anchored to a protected one becomes restricted too).
-- Nothing here sends input: the target and the star come from the player's own click on that button.
local _, ns = ...
local G = ns.Guide
local GUI = {}
ns.GuideUI = GUI

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local ARROW_ATLAS, ARROW_FILE = "MiniMap-QuestArrow", "Interface\\Minimap\\MinimapArrow"
local W, BODY, ROW = 236, 44, 26
local TICK = 0.1 -- position, facing and phase at 10 Hz; the arrow eases every frame
local DONE_HOLD, NOTNOW_HOLD = 6, 4
local TWO_PI = 2 * math.pi
local WINDOW_KIND = { MERCHANT_SHOW = "vendor", TRAINER_SHOW = "trainer", AUCTION_HOUSE_SHOW = "auction" }
local WINDOW_CLOSED = { MERCHANT_CLOSED = "vendor", TRAINER_CLOSED = "trainer", AUCTION_HOUSE_CLOSED = "auction" }

local status = {
	phase = "none",
	servers = 0,
	learned = 0,
	seeds = 0,
	waypoint = false,
	secureArmed = false,
	combatQueued = false,
	clicks = 0,
	worldMisses = 0,
}
local gdb -- SkillupHelperDB.guide
local seeds = {}
local cur -- the step to do now: { key, step, profession, color, base = { [item] = count at plan time }, hadNeeds }
local open -- the window open now: { kind, npc } (npc nil when it could not be recorded)
local worldCache = {}
local view = { phase = "none" } -- the last evaluation: phase, need, pick, d (Guide.describe), since
local want = { visible = false, row = false, name = nil }
local chip, row, sb
local armedName, fadingOut, dragging, dragStoppedAt
local waypointOurs -- { map, x, y } of the pin this addon set
local flashText, flashUntil = nil, 0
local angleShown, angleGoal
local evaluate

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

local function rgb(name)
	local c = ns.View.RGB[name] or ns.View.RGB.bone
	return c[1], c[2], c[3]
end

local function fail(why)
	status.lastError = why
	return nil, why
end

------------------------------------------------------------------------------------------------------------ positions

-- Continent and world yards of a map position (0-1). Each failure names the call that gave nothing.
local function worldPos(map, fx, fy)
	if secret(map) or secret(fx) or secret(fy) or type(fx) ~= "number" or type(fy) ~= "number" then
		return nil, ("map position on map %s is secret or absent"):format(tostring(map))
	end
	local ok, cont, v = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(fx, fy))
	if not ok then
		return nil, "C_Map.GetWorldPosFromMapPos failed: " .. tostring(cont)
	end
	if cont == nil or v == nil or secret(cont) then
		return nil, ("C_Map.GetWorldPosFromMapPos gave no world position for map %s"):format(tostring(map))
	end
	local wx, wy = v:GetXY()
	if secret(wx) or secret(wy) or type(wx) ~= "number" then
		return nil, ("world position for map %s is secret"):format(tostring(map))
	end
	return cont, wx, wy
end

-- Guide.nearest's world(): an NPC's stored percent position, converted once per spot.
local function world(map, x, y)
	local k = tostring(map) .. ":" .. tostring(x) .. ":" .. tostring(y)
	local c = worldCache[k]
	if c == nil then
		local cont, wx, wy = worldPos(map, (x or 0) / 100, (y or 0) / 100)
		if cont then
			c = { cont, wx, wy }
		else
			c = false
			status.worldMisses = status.worldMisses + 1
			status.lastError = wx
		end
		worldCache[k] = c
	end
	if c then
		return c[1], c[2], c[3]
	end
	return nil
end

-- The player's position: { continent, x, y (world yards), map, mx, my (percent) }, or nil and why ("not now").
local function here()
	local okInst, inInstance = pcall(IsInInstance)
	if okInst and inInstance and not secret(inInstance) then
		return nil, "in an instance"
	end
	local map = C_Map.GetBestMapForUnit("player")
	if map == nil or secret(map) then
		return nil, "C_Map.GetBestMapForUnit(player) gave no map"
	end
	local pos = C_Map.GetPlayerMapPosition(map, "player")
	if pos == nil or secret(pos) then
		return nil, ("C_Map.GetPlayerMapPosition gave no position on map %d"):format(map)
	end
	local mx, my = pos:GetXY()
	local cont, wx, wy = worldPos(map, mx, my)
	if not cont then
		return nil, wx
	end
	return { continent = cont, x = wx, y = wy, map = map, mx = mx * 100, my = my * 100 }
end

local function facing()
	local f = GetPlayerFacing and GetPlayerFacing()
	if f == nil or secret(f) then
		return nil
	end
	return f
end

local function targetName()
	local n = UnitName("target")
	if n == nil or secret(n) then
		return nil
	end
	return n
end

-------------------------------------------------------------------------------------------------------------- learning

-- The NPC whose window just opened, with the player's position (the NPC stands within a few yards of it).
local function npcRecord()
	local name = UnitName("npc")
	if name == nil or secret(name) then
		return fail("UnitName(npc) is secret or absent: not learned")
	end
	local guid = UnitGUID("npc")
	local id
	if guid ~= nil and not secret(guid) then
		id = G.npcId(guid)
	end
	if not id then
		id = "name:" .. name
		status.lastIdWhy = (guid ~= nil and secret(guid)) and "UnitGUID(npc) is secret: keyed by name"
			or "no creature GUID: keyed by name"
	end
	local h, why = here()
	if not h then
		return { id = id, name = name }, why
	end
	return { id = id, name = name, map = h.map, x = h.mx, y = h.my }
end

local function merchantItems()
	local out = {}
	local okN, n = pcall(GetMerchantNumItems)
	if not okN or type(n) ~= "number" or secret(n) then
		return out
	end
	for i = 1, n do
		local ok, item = pcall(GetMerchantItemID, i)
		if ok and type(item) == "number" and not secret(item) then
			out[#out + 1] = item
		end
	end
	return out
end

local function trainerLine()
	local okN, n = pcall(GetNumTrainerServices)
	if not okN or type(n) ~= "number" or secret(n) then
		return nil
	end
	local lines = {}
	for i = 1, n do
		local ok, line = pcall(GetTrainerServiceSkillLine, i)
		if ok and type(line) == "string" and not secret(line) then
			lines[#lines + 1] = line
		end
	end
	return G.mostCommon(lines)
end

local function countLearned()
	local n = 0
	for _ in pairs(gdb and gdb.npcs or {}) do
		n = n + 1
	end
	status.learned = n
end

local function learn(kind)
	local rec, why = npcRecord()
	open = { kind = kind, npc = rec }
	if not rec then
		return
	end
	if kind == "vendor" then
		rec.sells = merchantItems()
	elseif kind == "trainer" then
		rec.trains = trainerLine()
	elseif kind == "auction" then
		rec.auction = true
	end
	if not rec.map then
		status.lastLearn = { kind = kind, name = rec.name, why = why }
		return
	end
	local npc = gdb and G.learn(gdb.npcs, rec, time())
	if npc then
		open.npc = npc
		status.lastLearn = { kind = kind, name = npc.name, id = npc.id, map = npc.map }
		countLearned()
	end
end

---------------------------------------------------------------------------------------------------------- the model

local function trim(step)
	local buy = {}
	for i, b in ipairs(step.buy or {}) do
		buy[i] = { item = b.item, count = b.count, where = b.where }
	end
	return {
		kind = step.kind,
		spell = step.spell,
		item = step.item,
		from = step.from,
		source = step.source,
		name = step.name,
		at = step.at,
		color = step.color,
		buy = buy,
	}
end

local function have(item)
	local ok, n = pcall(ns.Scan.have, item)
	if not ok or type(n) ~= "number" or secret(n) then
		n = 0
	end
	return n
end

-- UI.show(model) runs after every scan: the planner's first step is the step to do now.
local function onModel(model)
	if not gdb or type(model) ~= "table" or type(model.planner) ~= "table" then
		return
	end
	local step = model.planner.steps and model.planner.steps[1]
	if not step then
		cur, gdb.last = nil, nil
		evaluate()
		return
	end
	local key = G.stepKey(step)
	local base = {}
	for _, b in ipairs(step.buy or {}) do
		base[b.item] = have(b.item)
	end
	local color = (step.kind == "train" or step.kind == "buyRecipe") and "gold" or step.color or "grey"
	local hadNeeds = cur and cur.key == key and cur.hadNeeds or nil
	cur = { key = key, step = trim(step), profession = model.profession, color = color, base = base }
	cur.hadNeeds = hadNeeds
	gdb.last = cur
	evaluate()
end

-- Bags count from the plan's snapshot: the step's buy counts are what to buy beyond what was owned then.
local function bought(item)
	return have(item) - (cur.base[item] or 0)
end

local function itemName(item)
	return ns.Scan.itemName(item)
end

------------------------------------------------------------------------------------------------------------- drawing

local function paintRow(style, accent)
	row.style, row.accent = style, accent or row.accent or "bone"
	local over = row.over and style ~= "inert"
	local r, g, b = rgb("line")
	if style == "primary" then
		r, g, b = rgb(row.accent)
		row.bg:SetColorTexture(r, g, b, over and 0.34 or 0.18)
		row.hair:SetColorTexture(r, g, b, 0.8)
		row.label:SetTextColor(rgb("bone"))
	elseif style == "quiet" then
		row.bg:SetColorTexture(r, g, b, over and 0.5 or 0)
		row.hair:SetColorTexture(r, g, b, 1)
		row.label:SetTextColor(rgb(over and "bone" or "ash"))
	else
		row.bg:SetColorTexture(r, g, b, 0.25)
		row.hair:SetColorTexture(r, g, b, 0.6)
		row.label:SetTextColor(rgb("ash"))
	end
	local pulse = style == "primary" and not dragging
	if pulse then
		row.glowTex:SetColorTexture(r, g, b, 0.22)
		if not row.pulse:IsPlaying() then
			row.pulse:Play()
		end
	elseif row.pulse:IsPlaying() then
		row.pulse:Stop()
		row.glow:SetAlpha(0)
	end
end

local function setIcon(icon, tint)
	local a = chip.arrow
	if icon == "star" then
		a:SetTexture(STAR)
		a:SetDesaturated(false)
		a:SetVertexColor(1, 1, 1)
		a:SetRotation(0)
		a:Show()
		chip.dot:Hide()
	elseif icon == "dot" then
		a:Hide()
		chip.dot:SetVertexColor(rgb(tint or "green"))
		chip.dot:Show()
	elseif icon == "arrow" then
		if chip.arrowAtlas then
			a:SetAtlas(ARROW_ATLAS)
		else
			a:SetTexture(ARROW_FILE)
		end
		a:SetDesaturated(true)
		a:SetVertexColor(rgb(tint or "bone"))
		a:Show()
		chip.dot:Hide()
	else
		a:Hide()
		chip.dot:Hide()
	end
	chip.icon = icon
end

local function draw()
	local d = view.d
	if not d or not chip then
		return
	end
	chip.stripe:SetColorTexture(rgb(cur and cur.color or "grey"))
	chip.l1:SetText(d.l1 or "")
	chip.r1:SetText(d.r1 or "")
	chip.l2:SetText((flashText and GetTime() < flashUntil) and flashText or d.l2 or "")
	if d.icon ~= chip.icon or d.tint ~= chip.tint then
		-- far to near: the arrow takes the step's colour with a small bump
		if d.icon == "arrow" and chip.icon == "arrow" and chip.tint == "bone" and d.tint ~= "bone" then
			chip.arrive:Play()
		end
		setIcon(d.icon, d.tint)
		chip.tint = d.tint
	end
	if d.action then
		local stale = InCombatLockdown() and want.name ~= armedName
		if stale then
			row.label:SetText("In combat: updates after")
			paintRow("inert")
		else
			row.label:SetText(d.action)
			paintRow(dragging and "inert" or d.style, d.tint)
		end
	end
end

local function placeSecure()
	if not sb then
		return
	end
	if InCombatLockdown() then
		status.combatQueued = true
		return
	end
	if chip:IsShown() and not fadingOut and row:IsShown() and armedName then
		local l, b, w, h = row:GetRect()
		if l then
			local s = row:GetEffectiveScale() / UIParent:GetEffectiveScale()
			sb:ClearAllPoints()
			sb:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l * s, b * s)
			sb:SetSize(w * s, h * s)
			sb:SetFrameLevel(chip:GetFrameLevel() + 5)
			sb:Show()
			status.secureArmed = true
			return
		end
	end
	sb:Hide()
	status.secureArmed = false
end

-- Show, hide, resize and arm: out of combat only; in combat the change waits for PLAYER_REGEN_ENABLED.
local function structure()
	if InCombatLockdown() then
		if
			want.visible ~= (chip:IsShown() and not fadingOut)
			or want.row ~= row:IsShown()
			or want.name ~= armedName
		then
			status.combatQueued = true
		end
		return
	end
	local queued = status.combatQueued
	status.combatQueued = false
	local changed = queued or want.row ~= row:IsShown() or want.visible ~= (chip:IsShown() and not fadingOut)
	local solo = not IsInGroup()
	if want.name ~= armedName or solo ~= sb.solo then
		armedName, sb.solo, changed = want.name, solo, true
		sb:SetAttribute("macrotext", G.macro(armedName, solo))
	end
	if not changed then
		return
	end
	row:SetShown(want.row)
	chip:SetHeight(BODY + (want.row and ROW or 0))
	if want.visible then
		if not chip:IsShown() or fadingOut then
			chip.fadeOut:Stop()
			fadingOut = false
			chip:Show()
			chip.fadeIn:Play()
		end
	elseif chip:IsShown() and not fadingOut then
		fadingOut = true
		chip.fadeOut:Play()
	end
	placeSecure()
end

local function isOurPin()
	if not waypointOurs or not C_Map.HasUserWaypoint() then
		return false
	end
	local p = C_Map.GetUserWaypoint()
	if not p or p.uiMapID ~= waypointOurs.map or not p.position then
		return false
	end
	local x, y = p.position:GetXY()
	return math.abs(x - waypointOurs.x) < 1e-3 and math.abs(y - waypointOurs.y) < 1e-3
end

local function clearPin()
	if isOurPin() then
		pcall(C_Map.ClearUserWaypoint)
	end
	waypointOurs = nil
	status.waypoint = false
end

local function flash(text, secs)
	flashText, flashUntil = text, GetTime() + secs
	draw()
end

local function togglePin()
	if waypointOurs then
		clearPin()
		flash("Pin removed", 2)
		return
	end
	local npc = view.pick and view.pick.npc
	if not npc then
		return
	end
	local okCan, can = pcall(C_Map.CanSetUserWaypointOnMap, npc.map)
	if not okCan or not can then
		fail(("C_Map.CanSetUserWaypointOnMap(%s) refused: no pin on this map"):format(tostring(npc.map)))
		flash("This map takes no pin", 2)
		return
	end
	local point = UiMapPoint.CreateFromCoordinates(npc.map, npc.x / 100, npc.y / 100)
	local ok, err = pcall(C_Map.SetUserWaypoint, point)
	if not ok then
		fail("C_Map.SetUserWaypoint failed: " .. tostring(err))
		return
	end
	pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	waypointOurs = { map = npc.map, x = npc.x / 100, y = npc.y / 100 }
	status.waypoint = true
	flash("Pinned on your map", 2)
end

------------------------------------------------------------------------------------------------------------ the state

function evaluate()
	if not chip then
		return
	end
	local now = GetTime()
	local phase, need, pick, why
	if not gdb or not cur then
		phase, why = "none", "no plan step yet (open a profession once)"
	elseif gdb.stopped[cur.key] then
		phase, why = "none", "stopped for this step"
	else
		need = G.pending(G.needsOf(cur.step, cur.profession), bought)[1]
		if not need then
			phase = cur.hadNeeds and "done" or "none"
			need = cur.lastNeed
		else
			cur.hadNeeds, cur.lastNeed = true, need
			local h, hwhy = here()
			local servers
			pick, servers = G.nearest(G.known(seeds, gdb.npcs), need, h, world)
			status.servers = servers
			local openServes = open
				and open.kind == need.kind
				and (not open.npc or not open.npc.map or G.serves(open.npc, need) > 0)
			if openServes then
				phase = "here"
			elseif not h then
				phase, why = "notnow", hwhy
			elseif not pick then
				phase = "unknown"
				why = (#seeds == 0 and status.learned == 0) and "no seed and nothing learned"
					or ("no known NPC serves this %s need"):format(need.kind)
			else
				local name = targetName()
				phase = G.phase(pick, false, name ~= nil and name == pick.npc.name, view.phase)
			end
		end
	end
	if phase ~= view.phase then
		view.since = now
		if phase == "here" or phase == "done" then
			clearPin()
		end
	end
	view.phase, view.need, view.pick, view.why = phase, need, pick, why
	status.phase, status.why = phase, why
	status.need = need and need.kind
	status.npc = pick and pick.npc.name
	status.distance = pick and pick.distance and math.floor(pick.distance + 0.5)
	local f = facing()
	local thing = need and need.items and need.items[1] and itemName(need.items[1].item)
	view.d = G.describe({
		phase = phase,
		need = need,
		name = pick and pick.npc.name,
		distance = pick and pick.distance,
		place = pick and pick.npc.place,
		thing = thing,
		profession = cur and cur.profession,
		compass = (not f and pick and pick.bearing) and G.compass(pick.bearing) or nil,
		marked = not IsInGroup(),
		color = cur and cur.color,
		why = why,
	})
	angleGoal = (f and pick and pick.bearing) and G.arrowAngle(pick.bearing, f) or nil
	local held = now - (view.since or now)
	want.visible = view.d ~= nil
		and not (phase == "done" and held > DONE_HOLD)
		and not (phase == "notnow" and held > NOTNOW_HOLD)
	want.row = want.visible and view.d.action ~= nil
	want.name = want.row and pick and pick.npc.name or nil
	if want.visible then
		draw()
	end
	structure()
end

-------------------------------------------------------------------------------------------------------------- frames

local function savePoint()
	local point, _, rel, x, y = chip:GetPoint(1)
	gdb.chip = { point = point, rel = rel, x = x, y = y }
end

local function placeChip()
	chip:ClearAllPoints()
	local p = gdb and gdb.chip
	if p and p.point then
		chip:SetPoint(p.point, UIParent, p.rel or p.point, p.x or 0, p.y or 0)
	else
		chip:SetPoint("TOP", UIParent, "TOP", 0, -170)
	end
end

local function tip(owner, lines)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for i, l in ipairs(lines) do
		if i == 1 then
			GameTooltip:SetText(l, 1, 1, 1, 1, true)
		else
			GameTooltip:AddLine(l, nil, nil, nil, true)
		end
	end
	GameTooltip:Show()
end

local function untip(owner)
	if GameTooltip and GameTooltip:IsOwned(owner) then
		GameTooltip:Hide()
	end
end

local function menu()
	if not MenuUtil or not cur then
		return
	end
	MenuUtil.CreateContextMenu(chip, function(_, root)
		root:CreateTitle("Skillup guide")
		root:CreateButton("Stop guiding this step", function()
			gdb.stopped[cur.key] = true
			clearPin()
			ns.guard("guide stop", evaluate)
		end)
		root:CreateCheckbox("Lock position", function()
			return gdb.locked == true
		end, function()
			gdb.locked = not gdb.locked or nil
		end)
		root:CreateButton("Reset position", function()
			if InCombatLockdown() then
				return
			end
			gdb.chip = nil
			placeChip()
			placeSecure()
		end)
	end)
end

local function text(parent, font, height)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(font)
	fs:SetFontHeight(height)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(false)
	return fs
end

local function circle(parent, size, layer, sub)
	local t = parent:CreateTexture(nil, layer, nil, sub)
	t:SetSize(size, size)
	t:SetTexture(WHITE)
	local m = parent:CreateMaskTexture()
	m:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	m:SetAllPoints(t)
	t:AddMaskTexture(m)
	return t
end

local function shortArc(a)
	return (a + math.pi) % TWO_PI - math.pi
end

local elapsedTick = 0
local function onUpdate(_, elapsed)
	elapsedTick = elapsedTick + elapsed
	if elapsedTick >= TICK then
		elapsedTick = 0
		evaluate()
	end
	if chip.icon == "arrow" and angleGoal then
		angleShown = angleShown or angleGoal
		angleShown = (angleShown + shortArc(angleGoal - angleShown) * math.min(1, elapsed * 12)) % TWO_PI
		chip.arrow:SetRotation(angleShown)
	end
end

local function create()
	chip = CreateFrame("Frame", nil, UIParent)
	chip:SetSize(W, BODY + ROW)
	chip:SetFrameStrata("MEDIUM")
	chip:SetClampedToScreen(true)
	chip:SetMovable(true)
	chip:Hide()
	placeChip()

	local bg = chip:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(ns.View.RGB.surface[1], ns.View.RGB.surface[2], ns.View.RGB.surface[3], 0.95)
	for k, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local t = chip:CreateTexture(nil, "BORDER")
		t:SetColorTexture(rgb("line"))
		if k <= 2 then
			t:SetHeight(1)
			t:SetPoint(side .. "LEFT")
			t:SetPoint(side .. "RIGHT")
		else
			t:SetWidth(1)
			t:SetPoint("TOP" .. side)
			t:SetPoint("BOTTOM" .. side)
		end
	end

	local body = CreateFrame("Button", nil, chip)
	body:SetPoint("TOPLEFT")
	body:SetSize(W, BODY)
	body:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	body:RegisterForDrag("LeftButton")
	chip.body = body

	chip.stripe = body:CreateTexture(nil, "ARTWORK")
	chip.stripe:SetPoint("TOPLEFT")
	chip.stripe:SetPoint("BOTTOMLEFT")
	chip.stripe:SetWidth(3)

	local dial = CreateFrame("Frame", nil, body)
	dial:SetSize(32, 32)
	dial:SetPoint("LEFT", 11, 0)
	chip.dial = dial
	local ring = circle(dial, 32, "ARTWORK", 1)
	ring:SetPoint("CENTER")
	ring:SetVertexColor(rgb("line"))
	local hole = circle(dial, 30, "ARTWORK", 2)
	hole:SetPoint("CENTER")
	hole:SetVertexColor(rgb("surface"))
	chip.dot = circle(dial, 10, "OVERLAY", 1)
	chip.dot:SetPoint("CENTER")
	chip.dot:Hide()
	chip.arrow = dial:CreateTexture(nil, "OVERLAY", nil, 2)
	chip.arrow:SetSize(24, 24)
	chip.arrow:SetPoint("CENTER")
	chip.arrowAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ARROW_ATLAS) ~= nil
	status.arrow = chip.arrowAtlas and ("atlas " .. ARROW_ATLAS) or ("file " .. ARROW_FILE .. " (atlas missing)")

	local arrive = dial:CreateAnimationGroup()
	local grow = arrive:CreateAnimation("Scale")
	grow:SetScaleFrom(1, 1)
	grow:SetScaleTo(1.25, 1.25)
	grow:SetDuration(0.15)
	grow:SetOrder(1)
	local shrink = arrive:CreateAnimation("Scale")
	shrink:SetScaleFrom(1.25, 1.25)
	shrink:SetScaleTo(1, 1)
	shrink:SetDuration(0.15)
	shrink:SetOrder(2)
	chip.arrive = arrive

	chip.r1 = text(body, "GameFontHighlight", 12)
	chip.r1:SetPoint("TOPRIGHT", -10, -8)
	chip.r1:SetJustifyH("RIGHT")
	chip.r1:SetTextColor(rgb("bone"))
	chip.l1 = text(body, "GameFontHighlight", 12)
	chip.l1:SetPoint("TOPLEFT", 51, -8)
	chip.l1:SetPoint("RIGHT", chip.r1, "LEFT", -8, 0)
	chip.l1:SetTextColor(rgb("bone"))
	chip.l2 = text(body, "GameFontHighlightSmall", 11)
	chip.l2:SetPoint("TOPLEFT", 51, -25)
	chip.l2:SetWidth(175)
	chip.l2:SetTextColor(rgb("ash"))

	row = CreateFrame("Frame", nil, chip)
	row:SetPoint("TOPLEFT", 0, -BODY)
	row:SetSize(W, ROW)
	row.bg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.bg:SetAllPoints()
	row.hair = row:CreateTexture(nil, "BORDER")
	row.hair:SetHeight(1)
	row.hair:SetPoint("TOPLEFT")
	row.hair:SetPoint("TOPRIGHT")
	row.label = text(row, "GameFontHighlightSmall", 12)
	row.label:SetPoint("LEFT", 8, 0)
	row.label:SetPoint("RIGHT", -8, 0)
	row.label:SetJustifyH("CENTER")
	row.label:SetJustifyV("MIDDLE")
	row.glow = CreateFrame("Frame", nil, row)
	row.glow:SetAllPoints()
	row.glow:SetAlpha(0)
	row.glowTex = row.glow:CreateTexture(nil, "BACKGROUND", nil, 2)
	row.glowTex:SetAllPoints()
	row.pulse = row.glow:CreateAnimationGroup()
	row.pulse:SetLooping("BOUNCE")
	local breathe = row.pulse:CreateAnimation("Alpha")
	breathe:SetFromAlpha(0.25)
	breathe:SetToAlpha(1)
	breathe:SetDuration(1.1)
	breathe:SetSmoothing("IN_OUT")
	row:Hide()

	chip.fadeIn = chip:CreateAnimationGroup()
	local fin = chip.fadeIn:CreateAnimation("Alpha")
	fin:SetFromAlpha(0)
	fin:SetToAlpha(1)
	fin:SetDuration(0.25)
	fin:SetSmoothing("OUT")
	chip.fadeIn:SetToFinalAlpha(true)
	chip.fadeOut = chip:CreateAnimationGroup()
	local fout = chip.fadeOut:CreateAnimation("Alpha")
	fout:SetFromAlpha(1)
	fout:SetToAlpha(0)
	fout:SetDuration(0.2)
	chip.fadeOut:SetToFinalAlpha(true)
	chip.fadeOut:SetScript("OnFinished", function()
		fadingOut = false
		if not InCombatLockdown() then
			chip:Hide()
			chip:SetAlpha(1)
		end
		placeSecure()
	end)

	body:SetScript("OnClick", function(_, button)
		if dragStoppedAt and GetTime() - dragStoppedAt < 0.2 then
			return
		end
		if button == "RightButton" then
			ns.guard("guide menu", menu)
		else
			ns.guard("guide pin", togglePin)
		end
	end)
	body:SetScript("OnDragStart", function()
		if InCombatLockdown() or gdb.locked then
			return
		end
		dragging = true
		chip:StartMoving()
		draw()
	end)
	body:SetScript("OnDragStop", function()
		if not dragging then
			return
		end
		chip:StopMovingOrSizing()
		dragging, dragStoppedAt = false, GetTime()
		savePoint()
		placeSecure()
		draw()
	end)
	body:SetScript("OnEnter", function(self)
		local lines = { "Click: pin on the map. Right-click: more." }
		if view.why then
			lines[2] = view.why
		end
		tip(self, lines)
	end)
	body:SetScript("OnLeave", untip)
	chip:SetScript("OnUpdate", function(self, elapsed)
		ns.guard("guide tick", onUpdate, self, elapsed)
	end)

	sb = CreateFrame("Button", "SkillupHelperGuideTarget", UIParent, "SecureActionButtonTemplate")
	sb:SetFrameStrata("MEDIUM")
	sb:RegisterForClicks("AnyUp", "AnyDown")
	sb:SetAttribute("type", "macro")
	sb:Hide()
	sb:HookScript("OnEnter", function(self)
		row.over = true
		draw()
		if armedName then
			tip(self, { ("Works once %s is in sight."):format(armedName) })
		end
	end)
	sb:HookScript("OnLeave", function(self)
		row.over = false
		draw()
		untip(self)
	end)
	sb:HookScript("PostClick", function(_, _, down)
		if down then
			return
		end
		status.clicks = status.clicks + 1
		local name = armedName
		C_Timer.After(0.3, function()
			if name and targetName() ~= name then
				flash("Not in sight yet. Keep walking", 3)
			end
		end)
	end)
end

-------------------------------------------------------------------------------------------------------------- events

local function init()
	SkillupHelperDB = SkillupHelperDB or {}
	local g = SkillupHelperDB.guide
	if type(g) ~= "table" then
		g = {}
		SkillupHelperDB.guide = g
	end
	g.npcs = type(g.npcs) == "table" and g.npcs or {}
	g.stopped = type(g.stopped) == "table" and g.stopped or {}
	gdb = g
	seeds = G.seedRecords(ns.Data.npcs)
	status.seeds = #seeds
	if not ns.Data.npcs then
		status.lastError = "Data/Npcs.lua not loaded: no seeds"
	end
	countLearned()
	if type(g.last) == "table" and type(g.last.step) == "table" and g.last.key then
		cur = g.last
		cur.base = type(cur.base) == "table" and cur.base or {}
	end
	create()
	hooksecurefunc(ns.UI, "show", function(model)
		ns.guard("guide model", onModel, model)
	end)
	evaluate()
end

local events = CreateFrame("Frame")
local EVENTS = {
	"PLAYER_LOGIN",
	"PLAYER_ENTERING_WORLD",
	"ZONE_CHANGED",
	"ZONE_CHANGED_INDOORS",
	"ZONE_CHANGED_NEW_AREA",
	"BAG_UPDATE_DELAYED",
	"PLAYER_TARGET_CHANGED",
	"PLAYER_REGEN_DISABLED",
	"PLAYER_REGEN_ENABLED",
	"MERCHANT_SHOW",
	"MERCHANT_UPDATE",
	"MERCHANT_CLOSED",
	"TRAINER_SHOW",
	"TRAINER_CLOSED",
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
}
status.events = {}
for _, e in ipairs(EVENTS) do
	local ok, err = pcall(events.RegisterEvent, events, e)
	if not ok then
		status.events[e] = "not registered: " .. tostring(err)
	end
end
if next(status.events) == nil then
	status.events = "all registered"
end

events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		ns.guard("guide init", init)
		return
	end
	if not gdb then
		return
	end
	if WINDOW_KIND[event] then
		ns.guard("guide learn", learn, WINDOW_KIND[event])
	elseif event == "MERCHANT_UPDATE" then
		if open and open.kind == "vendor" then
			ns.guard("guide learn", learn, "vendor")
		end
	elseif WINDOW_CLOSED[event] then
		if open and open.kind == WINDOW_CLOSED[event] then
			open = nil
		end
	end
	ns.guard("guide " .. event, evaluate)
end)

-- For the selftest: what the guide shows and why, and the links it depends on.
function GUI.status()
	local s = {}
	for k, v in pairs(status) do
		s[k] = v
	end
	s.waypoint = waypointOurs ~= nil and isOurPin()
	s.shown = chip ~= nil and chip:IsShown()
	s.step = cur and cur.key
	return s
end
