-- The mail queue on screen. On the main, the Next card's "Queue mail" button (UI.lua) saves which alt sends what.
-- On the alt, at an open mailbox, a panel beside the MailFrame lists that alt's queue; its Fill button, under the
-- user's own click, opens the Send Mail tab, writes the recipient and subject and attaches whole stacks from the bags.
-- The user presses Blizzard's Send. This file never calls SendMail and sends no input.
local _, ns = ...
local M = {}
ns.MailUI = M

local stats = { open = false, shows = 0, fills = 0, sent = 0, failed = 0, selfSkipped = 0 }
local state = {} -- pending = recipient being filled, attached = { [item] = units }, note = { to, text, tone }

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
end

local function db()
	return SkillupHelperDB
end

-- The saved queue slice of this faction and realm, and this character's name; nil when unknown (secret, no db).
local function queue()
	if type(db()) ~= "table" then
		return nil
	end
	return ns.Alts.myQueue(db())
end

-- env.queued(alt, item, count): is at least count of that part on the queue to this character?
function M.queued(alt, item, count)
	local q, me = queue()
	for _, e in ipairs(q and q[alt] or {}) do
		if e.item == item and e.to == me and e.count >= (count or 1) then
			return true
		end
	end
	return false
end

-- env.mailQueue(): the rows queued to this character, for the footer.
function M.toMe()
	local q, me = queue()
	return q and ns.Alts.toMe(q, me) or {}
end

function M.status()
	local q = queue()
	local alts, rows = 0, 0
	for _, list in pairs(q or {}) do
		alts = alts + 1
		rows = rows + #list
	end
	stats.queuedAlts, stats.queuedRows = alts, rows
	stats.pending = state.pending ~= nil
	return stats
end

-- This character's bags, bank and mailbox units of an item, and its bag stacks (unlocked ones only).
local function live(item)
	local bags = C_Item.GetItemCount(item) or 0
	local all = C_Item.GetItemCount(item, true) or bags
	local mail = 0
	if type(TSM_API) == "table" and type(TSM_API.GetMailQuantity) == "function" then
		local ok, n = pcall(TSM_API.GetMailQuantity, "i:" .. item)
		mail = ok and type(n) == "number" and n or 0
	end
	local stacks = {}
	for bag = 0, NUM_BAG_SLOTS + 1 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if
				info
				and not secret(info.itemID)
				and not secret(info.stackCount)
				and info.itemID == item
				and not info.isLocked
			then
				stacks[#stacks + 1] = { bag = bag, slot = slot, n = info.stackCount or 1 }
			end
		end
	end
	return { bags = bags, bank = math.max(0, all - bags), mail = mail, stacks = stacks }
end

local function attachedNow()
	local out, any = {}, false
	for i = 1, ns.Alts.MAX_ATTACH do
		local ok, name, itemID, _, n = pcall(GetSendMailItem, i)
		if ok and name and itemID and not secret(itemID) and not secret(n) then
			out[itemID] = (out[itemID] or 0) + (n or 1)
			any = true
		end
	end
	return out, any
end

-- The send form holds something this panel did not put there (a recipient typed, an item attached by hand).
local function formBusy()
	if state.pending then
		return false
	end
	local _, any = attachedNow()
	local name = SendMailNameEditBox and SendMailNameEditBox:GetText() or ""
	return any or (name ~= "" and not secret(name))
end

----------------------------------------------------------------------------------------------------------- the panel

local function frame()
	if M.frame then
		return M.frame
	end
	local K = ns.UI.kit
	local f = CreateFrame("Frame", "SkillupHelperMailList", UIParent)
	f:SetWidth(K.WIDTH)
	f:SetFrameStrata("HIGH")
	f.bg = f:CreateTexture(nil, "BACKGROUND")
	f.bg:SetAllPoints()
	K.fill(f.bg, "ink", 0.96)
	f.edge = K.edges(f)
	K.paintEdges(f.edge, K.rgb("line"))
	f.title = K.text(f, "GameFontNormal", 13)
	f.title:SetPoint("TOPLEFT", K.PAD, -K.PAD)
	f.title:SetWidth(K.WIDTH - 2 * K.PAD)
	f.pool = { fs = {}, buttons = {} }
	M.frame = f
	return f
end

function M.draw()
	if not stats.open then
		return
	end
	local q, me = queue()
	if not q then
		return
	end
	local groups = {}
	for _, g in ipairs(ns.Alts.forAlt(q, me)) do
		if g.to == me then
			stats.selfSkipped = stats.selfSkipped + 1
		else
			groups[#groups + 1] = g
		end
	end
	if #groups == 0 and not state.done then
		if M.frame then
			M.frame:Hide()
		end
		return
	end
	local K = ns.UI.kit
	local d = ns.View.mailPanel(groups, live, {
		pending = state.pending,
		note = state.note,
		combat = InCombatLockdown and InCombatLockdown(),
		busy = formBusy(),
	}, { nameOf = K.itemName }, ns.Alts.pickStacks, ns.Alts.MAX_ATTACH)
	local f = frame()
	f:ClearAllPoints()
	local anchor = (OpenMailFrame and OpenMailFrame:IsShown()) and OpenMailFrame or MailFrame
	if anchor and anchor:IsShown() then
		f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
	else
		f:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0) -- TSM's mail UI hides MailFrame
	end
	f.title:SetText(d.title)
	local nfs, nb = 0, 0
	local function line(s, font, size, color, indent)
		nfs = nfs + 1
		local fs = f.pool.fs[nfs] or K.text(f, font, size)
		f.pool.fs[nfs] = fs
		fs:SetFontObject(font)
		fs:SetWidth(K.WIDTH - 2 * K.PAD - (indent or 0))
		fs:SetText(s)
		K.setColor(fs, color)
		fs:Show()
		return fs
	end
	local function button(a, accent)
		nb = nb + 1
		local b = f.pool.buttons[nb] or K.newButton(f)
		f.pool.buttons[nb] = b
		K.setButton(b, a, accent)
		b:Show()
		return b
	end
	local y = K.PAD + f.title:GetStringHeight() + 8
	if d.empty then
		local fs = line(d.empty, "GameFontHighlightSmall", 11, "ash")
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", K.PAD, -y)
		y = y + fs:GetStringHeight() + 6
	end
	for _, g in ipairs(d.groups) do
		local t = line(g.title, "GameFontHighlightSmall", 11, "gold")
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", K.PAD, -y)
		y = y + t:GetStringHeight() + 4
		for _, r in ipairs(g.rows) do
			local n = line(r.name, "GameFontHighlight", 12, r.color)
			n:ClearAllPoints()
			n:SetPoint("TOPLEFT", K.PAD, -y)
			n:SetJustifyH("LEFT")
			local rt = line(r.right, "GameFontHighlightSmall", 11, r.tone)
			rt:ClearAllPoints()
			rt:SetPoint("TOPRIGHT", -K.PAD, -y)
			rt:SetJustifyH("RIGHT")
			y = y + 16
		end
		if g.note then
			local nt = line(g.note.text, "GameFontHighlightSmall", 11, g.note.tone)
			nt:ClearAllPoints()
			nt:SetPoint("TOPLEFT", K.PAD, -y)
			y = y + nt:GetStringHeight() + 4
		end
		local fb = button(g.fill, ns.View.RGB.gold)
		fb:ClearAllPoints()
		fb:SetPoint("TOPLEFT", K.PAD, -(y + 2))
		fb:SetWidth(K.WIDTH - 2 * K.PAD - 56)
		local db2 = button(g.drop, ns.View.RGB.ash)
		db2:ClearAllPoints()
		db2:SetPoint("TOPRIGHT", -K.PAD, -(y + 2))
		db2:SetWidth(50)
		y = y + 2 + 24 + 10
	end
	for k = nfs + 1, #f.pool.fs do
		f.pool.fs[k]:Hide()
	end
	for k = nb + 1, #f.pool.buttons do
		f.pool.buttons[k]:Hide()
	end
	f:SetHeight(y + K.PAD - 6)
	if not f:IsShown() then
		stats.shows = stats.shows + 1
	end
	f:Show()
end

-- Fill: one user click. Re-reads the bags (the draw may be old), then the tab, recipient, subject and attachments.
local function fillMail(a)
	if InCombatLockdown and InCombatLockdown() then
		return false
	end
	local q, me = queue()
	if not q or not stats.open then
		stats.lastFillError = "mailbox closed or queue unknown at the click"
		return false
	end
	local group
	for _, g in ipairs(ns.Alts.forAlt(q, me)) do
		if g.to == a.to then
			group = g
		end
	end
	if not group then
		return false
	end
	local fresh = ns.View.mailPanel({ group }, live, {}, { nameOf = tostring }, ns.Alts.pickStacks, ns.Alts.MAX_ATTACH)
	local picks = fresh.groups[1] and fresh.groups[1].fill.picks or {}
	if #picks == 0 then
		state.note = { to = a.to, text = "Nothing attached: the bags changed. Click again.", tone = "warn" }
		M.draw()
		return false
	end
	if SendMailFrame and not SendMailFrame:IsShown() and MailFrameTab_OnClick then
		pcall(MailFrameTab_OnClick, nil, 2)
	end
	if not (SendMailFrame and SendMailFrame:IsShown()) then
		stats.lastFillError = "the Send Mail tab did not open"
		state.note = { to = a.to, text = "Open the Send Mail tab, then click again.", tone = "warn" }
		M.draw()
		return false
	end
	SendMailNameEditBox:SetText(a.to)
	local n = 0
	for _, s in ipairs(picks) do
		local ok, err = pcall(C_Container.UseContainerItem, s.bag, s.slot)
		if ok then
			n = n + 1
		else
			stats.lastFillError = "UseContainerItem: " .. tostring(err)
		end
	end
	if n == 0 then
		state.note = { to = a.to, text = "Nothing attached: " .. tostring(stats.lastFillError), tone = "warn" }
		M.draw()
		return false
	end
	SendMailSubjectEditBox:SetText(("SkillupHelper: %d reagent stack%s"):format(n, n == 1 and "" or "s"))
	stats.fills = stats.fills + 1
	-- pending holds until the send succeeds or fails, or the mailbox closes: the form empties on a send too
	state.pending, state.note, state.attached = a.to, nil, nil
	M.draw()
	return n > 0
end

function M.act(a)
	local q, me = queue()
	if not q then
		return false
	end
	if a.id == "mailQueue" then
		for _, r in ipairs(a.rows or {}) do
			ns.Alts.enqueue(q, r.alt, me, r.item, r.count)
		end
	elseif a.id == "mailUnqueue" then
		for _, r in ipairs(a.rows or {}) do
			ns.Alts.remove(q, r.alt, me, r.item)
		end
	elseif a.id == "mailDrop" then
		for _, e in ipairs(ns.Alts.forAlt(q, me)) do
			if e.to == a.to then
				for _, r in ipairs(e.rows) do
					ns.Alts.remove(q, me, a.to, r.item)
				end
			end
		end
		if state.pending == a.to then
			state.pending = nil
		end
		M.draw()
		return true
	elseif a.id == "mailFill" then
		return a.enabled and fillMail(a) or false
	else
		return false
	end
	ns.refresh()
	return true
end

------------------------------------------------------------------------------------------------------------ events

local ev = CreateFrame("Frame")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_INFO_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED" }) do
	local ok, err = pcall(ev.RegisterEvent, ev, e)
	if not ok then
		stats.eventErrors = stats.eventErrors or {}
		stats.eventErrors[e] = tostring(err)
	end
end
ev:SetScript("OnEvent", function(_, event)
	if event == "MAIL_SHOW" then
		stats.open, state.done = true, nil
		ns.guard("mail draw", M.draw)
	elseif event == "MAIL_CLOSED" then
		stats.open, state.pending, state.attached, state.note, state.done = false, nil, nil, nil, nil
		if M.frame then
			M.frame:Hide()
		end
	elseif event == "MAIL_SEND_INFO_UPDATE" then
		if state.pending then
			-- what the user leaves attached is what counts as sent: the last non-empty form (the form empties on a
			-- successful send, before or after MAIL_SEND_SUCCESS)
			local att, any = attachedNow()
			if any then
				state.attached = att
			end
		end
		ns.guard("mail draw", M.draw)
	elseif event == "MAIL_SEND_SUCCESS" then
		local q, me = queue()
		if state.pending and state.attached and q then
			ns.Alts.sent(q, me, state.pending, state.attached)
			stats.sent = stats.sent + 1
			state.note = { to = state.pending, text = ("Sent to %s."):format(state.pending), tone = "green" }
			state.done = true
		end
		state.pending, state.attached = nil, nil
		ns.guard("mail draw", M.draw)
	elseif event == "MAIL_FAILED" then
		if state.pending then
			stats.failed = stats.failed + 1
			state.note = {
				to = state.pending,
				text = "The mail was not sent. Nothing left the queue. Fix it and press Send again, or clear the form.",
				tone = "warn",
			}
		end
		ns.guard("mail draw", M.draw)
	end
end)
