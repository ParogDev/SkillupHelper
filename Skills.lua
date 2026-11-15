-- The rank and cap of any skill line, also one with no profession window (Lockpicking, 633). An ordered chain of
-- sources per line, and the result names the one that answered:
--   1. "skill api"       C_SkillInfo.GetSkillLineInfoByID (what Forever's character sheet and skills window read)
--   2. "tradeskill api"  C_TradeSkillUI.GetProfessionInfoBySkillLineID, then GetProfessions / GetProfessionInfo
--   3. "chat message"    the last "Your skill in X has increased to N" seen this session (CHAT_MSG_SKILL)
--   4. "saved"           the same value from an earlier session (SkillupHelperDB.skills[line])
--   5. "estimate"        no rank known; the cap alone (Lockpicking: 5 x character level)
-- Skills.read is pure: every client call comes in through `env`, so busted tests the chain whole. Skills.env builds
-- that env from the client and Skills.register wires the events; those two are the only client code here.
local _, ns = ...
local K = {}
ns.Skills = K

K.LOCKPICKING = 633
K.RANK_CAPS = { 75, 150, 225, 300 } -- the cap a saved rank is given when no api names one (an estimate)
K.TOP = 300

local function secret(v)
	return issecretvalue ~= nil and v ~= nil and issecretvalue(v)
end

-- v, or nil when it is a secret value
local function clean(v)
	if secret(v) then
		return nil
	end
	return v
end

local function num(v)
	v = clean(v)
	return type(v) == "number" and v == v and v or nil
end

local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

-- A Lua pattern for a localized format string ("Your skill in %s has increased to %d."), with one capture per
-- argument, and the argument number of each capture in order ("%2$d ... %1$s" gives { 2, 1 }). nil for anything but
-- a string with at least one argument.
function K.pattern(fmt)
	if type(fmt) ~= "string" or secret(fmt) or fmt == "" then
		return nil
	end
	local out, order, i, n = {}, {}, 1, 0
	while i <= #fmt do
		local c = fmt:sub(i, i)
		if c == "%" then
			local pos, kind = fmt:match("^%%(%d+)%$([sd])", i)
			if pos then
				i = i + #pos + 3
			else
				kind = fmt:match("^%%([sd])", i)
				if kind then
					i = i + 2
				end
			end
			if kind then
				n = n + 1
				order[#order + 1] = tonumber(pos) or n
				out[#out + 1] = kind == "d" and "(%d+)" or "(.-)"
			elseif fmt:sub(i + 1, i + 1) == "%" then
				out[#out + 1] = "%%"
				i = i + 2
			else
				out[#out + 1] = "%%"
				i = i + 1
			end
		else
			out[#out + 1] = c:gsub(MAGIC, "%%%0")
			i = i + 1
		end
	end
	if #order == 0 then
		return nil
	end
	return "^" .. table.concat(out) .. "$", order
end

local function captures(msg, fmt)
	local pat, order = K.pattern(fmt)
	if not pat then
		return nil
	end
	local got = { msg:match(pat) }
	if #got == 0 then
		return nil
	end
	local args = {}
	for i, pos in ipairs(order) do
		args[pos] = got[i]
	end
	return args
end

-- What a CHAT_MSG_SKILL line says. strings = { up = ERR_SKILL_UP_SI, gained = ERR_SKILL_GAINED_S } (the client's
-- localized formats, never English literals). Returns the skill's name and its new rank (1 for "you have gained"),
-- or nil and why.
function K.parse(msg, strings)
	if secret(msg) then
		return nil, nil, "the chat line is a secret value (in an instance)"
	end
	if type(msg) ~= "string" then
		return nil, nil, "no chat line"
	end
	strings = strings or {}
	local up = captures(msg, strings.up)
	if up and up[1] and tonumber(up[2]) then
		return up[1], tonumber(up[2])
	end
	local gained = captures(msg, strings.gained)
	if gained and gained[1] then
		return gained[1], 1
	end
	if not strings.up and not strings.gained then
		return nil, nil, "the client has no ERR_SKILL_UP_SI / ERR_SKILL_GAINED_S format"
	end
	return nil, nil, "not a skill-up line"
end

-- The skill line a localized name belongs to. names = { [line] = name }. nil when no line has that name.
function K.lineOfName(name, names)
	if type(name) ~= "string" then
		return nil
	end
	local want = name:lower()
	local best
	for line, n in pairs(names or {}) do
		if type(n) == "string" and n:lower() == want and (not best or line < best) then
			best = line
		end
	end
	return best
end

-- Stores a rank in the saved table (db.skills[line] = { rank, cap, at, from }). Secrets and non-numbers are refused:
-- nothing computed from a secret reaches SavedVariables. Returns the record, or nil and why.
function K.remember(db, line, rank, cap, now, from)
	if type(db) ~= "table" or type(line) ~= "number" then
		return nil, "no saved table"
	end
	rank, cap = num(rank), num(cap)
	if not rank then
		return nil, "no rank to save (nil or a secret value)"
	end
	db.skills = type(db.skills) == "table" and db.skills or {}
	local rec = db.skills[line] or {}
	rec.rank, rec.at, rec.from = rank, now, from or "chat"
	rec.cap = cap or rec.cap
	db.skills[line] = rec
	return rec
end

-- One CHAT_MSG_SKILL line into the saved table. session[line] = true marks it as seen this session. Returns the
-- line and rank, or nil and the broken link in words.
function K.onChat(db, msg, strings, names, now, session)
	local name, rank, why = K.parse(msg, strings)
	if not name then
		return nil, nil, why
	end
	local line = K.lineOfName(name, names)
	if not line then
		return nil, nil, ("skill-up for %q matched no known skill line (name not in the list)"):format(name)
	end
	local rec, err = K.remember(db, line, rank, nil, now, "chat")
	if not rec then
		return nil, nil, err
	end
	if type(session) == "table" then
		session[line] = true
	end
	return line, rank
end

-- Whether this character can have the line at all. who = { class = "ROGUE", level = 22 }. Lockpicking is the only
-- line with a rule here: rogues, from learnLevel (16). Returns ok, reason; ok nil = cannot say (class or level
-- unknown or secret).
function K.available(line, who, rules)
	if line ~= K.LOCKPICKING then
		return true
	end
	who, rules = who or {}, rules or {}
	local class, level = clean(who.class), num(who.level)
	local learn = rules.learnLevel or 16
	if type(class) ~= "string" then
		return nil, "class unknown"
	end
	if class ~= "ROGUE" then
		return false, "Rogues only"
	end
	if not level then
		return nil, "level unknown"
	end
	if level < learn then
		return false, ("Rogues learn it at level %d"):format(learn)
	end
	return true
end

local function capOfRank(rank)
	for _, cap in ipairs(K.RANK_CAPS) do
		if rank <= cap then
			return cap
		end
	end
	return K.TOP
end

-- The rank and cap of one line. env = {
--   api = { skillInfo = fn(line) -> { rank, maxRank } | nil, professionInfo = fn(line) -> { skillLevel, maxSkillLevel }
--           | nil, professions = fn() -> { [line] = { skill, cap } } },   -- any may be absent
--   db = SkillupHelperDB, session = { [line] = true }, class, level,
--   rules = { [line] = { capPerLevel, learnLevel } } }.
-- Returns { line, rank, cap, source, capSource, why, available, learned, notNow }:
--   rank nil = not known; `why` then names the link. available false = the class or level cannot have it ("not
--   available: <reason>", not an error). notNow = a secret value blocked an api that would otherwise answer.
function K.read(line, env)
	env = env or {}
	local api = env.api or {}
	local rule = (env.rules or {})[line] or {}
	local out = { line = line }
	local ok, reason = K.available(line, env, rule)
	out.available = ok ~= false
	if ok == false then
		out.learned = false
		out.why = "not available: " .. reason
		return out
	end
	local levelCap = rule.capPerLevel and num(env.level) and rule.capPerLevel * num(env.level) or nil
	local blocked, asked = false, false

	if api.skillInfo then
		asked = true
		local info = api.skillInfo(line)
		if type(info) == "table" then
			local rank, cap = num(info.rank), num(info.maxRank)
			if secret(info.rank) or secret(info.maxRank) then
				blocked = true
			elseif rank and (rank > 0 or (cap or 0) > 0) then
				out.rank, out.cap, out.source, out.learned = rank, cap, "skill api", true
				out.why = "C_SkillInfo.GetSkillLineInfoByID"
			end
		end
	end
	if not out.rank and api.professionInfo then
		asked = true
		local info = api.professionInfo(line)
		if type(info) == "table" then
			local rank, cap = num(info.skillLevel), num(info.maxSkillLevel)
			if secret(info.skillLevel) or secret(info.maxSkillLevel) then
				blocked = true
			elseif rank and cap and cap > 0 then
				out.rank, out.cap, out.source, out.learned = rank, cap, "tradeskill api", true
				out.why = "C_TradeSkillUI.GetProfessionInfoBySkillLineID"
			end
		end
	end
	if not out.rank and api.professions then
		asked = true
		local own = api.professions()
		local p = type(own) == "table" and own[line] or nil
		if type(p) == "table" and num(p.skill) then
			out.rank, out.cap, out.source, out.learned = num(p.skill), num(p.cap), "tradeskill api", true
			out.why = "GetProfessions"
		end
	end
	if out.rank then
		if not out.cap or out.cap <= 0 then
			out.cap, out.capSource = levelCap or capOfRank(out.rank), "estimate"
		end
		return out
	end

	local saved = type(env.db) == "table" and type(env.db.skills) == "table" and env.db.skills[line] or nil
	if type(saved) == "table" and num(saved.rank) then
		out.rank, out.learned = saved.rank, true
		local live = type(env.session) == "table" and env.session[line]
		out.source = live and "chat message" or "saved"
		out.why = live and "the last skill-up message this session" or "the last value seen in an earlier session"
		if levelCap then
			out.cap, out.capSource = math.max(levelCap, out.rank), "estimate"
		elseif num(saved.cap) and saved.cap >= out.rank then
			out.cap, out.capSource = saved.cap, "saved"
		else
			out.cap, out.capSource = capOfRank(out.rank), "estimate"
		end
		out.notNow = blocked or nil
		return out
	end

	out.notNow = blocked or nil
	if blocked then
		out.why = "skill hidden here (a secret value, in an instance). It comes back outside"
	elseif line == K.LOCKPICKING or not asked then
		-- a line the apis may not carry: the cap is known from the level, the rank only from a skill-up message
		out.source, out.cap = "estimate", levelCap
		out.capSource = levelCap and "estimate" or nil
		out.why = "skill unknown until the first skill-up message"
	else
		out.learned = false
		out.why = "not learned (no api lists this skill for the character)"
	end
	return out
end

-- Skills.read for a list of lines: { [line] = result }.
function K.all(lines, env)
	local out = {}
	for _, line in ipairs(lines or {}) do
		out[line] = K.read(line, env)
	end
	return out
end

-- "112 / 150", "? / 110" (cap only), "not learned", "Rogues only": the one text the frames show for a result.
function K.text(r)
	if type(r) ~= "table" then
		return "unknown"
	end
	if r.available == false then
		return (r.why or "not available"):gsub("^not available: ", "")
	end
	if r.rank then
		return r.cap and ("%d / %d"):format(r.rank, r.cap) or tostring(r.rank)
	end
	if r.learned == false then
		return "not learned"
	end
	return r.cap and ("? / %d"):format(r.cap) or "unknown"
end

------------------------------------------------------------------------------------------------- the client side

-- The localized name of each line, for matching chat lines: the skill api's own name, else the tradeskill api's,
-- else the data's English name (right on an enUS client; on another locale the chat line then matches nothing and
-- Skills.onChat says so).
function K.names(lines, fallback)
	local out = {}
	for _, line in ipairs(lines or {}) do
		local name
		if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
			local info = C_SkillInfo.GetSkillLineInfoByID(line)
			name = type(info) == "table" and clean(info.name) or nil
		end
		if type(name) ~= "string" and C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
			name = clean(C_TradeSkillUI.GetTradeSkillDisplayName(line))
		end
		if type(name) ~= "string" or name == "" then
			name = fallback and fallback[line] or nil
		end
		out[line] = name
	end
	return out
end

local session = {}

-- The live env for Skills.read.
function K.env()
	local api = {}
	if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
		api.skillInfo = C_SkillInfo.GetSkillLineInfoByID
	end
	if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
		api.professionInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID
	end
	if ns.Scan and ns.Scan.playerSkills then
		api.professions = ns.Scan.playerSkills
	end
	local rules = {}
	local spots = ns.Data and ns.Data.spots
	for line, def in pairs(spots and spots.skills or {}) do
		if def.capPerLevel or def.learnLevel then
			rules[line] = { capPerLevel = def.capPerLevel, learnLevel = def.learnLevel }
		end
	end
	return {
		api = api,
		db = SkillupHelperDB,
		session = session,
		class = UnitClassBase and UnitClassBase("player") or nil,
		level = UnitLevel and UnitLevel("player") or nil,
		rules = rules,
	}
end

-- Every line the data knows: the world skills of Data/Spots.lua and the professions of Data/Recipes.lua, with the
-- data's English names.
function K.lines()
	local list, names = {}, {}
	local data = ns.Data or {}
	for _, src in ipairs({ data.spots and data.spots.skills or {}, data.recipes and data.recipes.professions or {} }) do
		for line, def in pairs(src) do
			if type(line) == "number" and not names[line] then
				names[line] = def.name
				list[#list + 1] = line
			end
		end
	end
	table.sort(list)
	return list, names
end

local listeners = {}

-- fn(line, rank) is called after a skill-up message was stored, fn(nil) after any other skill change.
function K.listen(fn)
	listeners[#listeners + 1] = fn
end

local function fire(line, rank)
	for _, fn in ipairs(listeners) do
		fn(line, rank)
	end
end

K.last = nil -- the last event's outcome, for selftest: { event, line, rank, why }

-- One event. The integrator may call this from its own dispatcher instead of Skills.register.
function K.handle(event, ...)
	if event == "CHAT_MSG_SKILL" then
		local msg = ...
		local list, english = K.lines()
		local strings = { up = rawget(_G, "ERR_SKILL_UP_SI"), gained = rawget(_G, "ERR_SKILL_GAINED_S") }
		local line, rank, why = K.onChat(SkillupHelperDB, msg, strings, K.names(list, english), time(), session)
		K.last = { event = event, line = line, rank = rank, why = why }
		if line then
			fire(line, rank)
		end
	elseif event == "SKILL_LINES_CHANGED" or event == "PLAYER_LEVEL_UP" then
		-- keep what the apis say now, so "saved" has it where they turn secret (an instance)
		local env = K.env()
		for _, line in ipairs((K.lines())) do
			local r = K.read(line, env)
			if r.rank and (r.source == "skill api" or r.source == "tradeskill api") then
				K.remember(SkillupHelperDB, line, r.rank, r.capSource == nil and r.cap or nil, time(), "api")
			end
		end
		K.last = { event = event }
		fire(nil)
	end
end

K.EVENTS = { "CHAT_MSG_SKILL", "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP" }

-- The event wiring, in one place: registers the events on `frame` and routes them to Skills.handle (hooked, so the
-- frame's own OnEvent keeps running).
function K.register(frame)
	for _, ev in ipairs(K.EVENTS) do
		frame:RegisterEvent(ev)
	end
	local function onEvent(_, event, ...)
		if event == "CHAT_MSG_SKILL" or event == "SKILL_LINES_CHANGED" or event == "PLAYER_LEVEL_UP" then
			K.handle(event, ...)
		end
	end
	if frame:GetScript("OnEvent") then
		frame:HookScript("OnEvent", onEvent)
	else
		frame:SetScript("OnEvent", onEvent)
	end
end

return K
