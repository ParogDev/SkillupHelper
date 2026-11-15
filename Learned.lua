-- What the game taught the addon, in one table: SkillupHelperDB.learned. No frames, no events; Core, Scan and GuideUI
-- call in. The table is anonymous by rule: game facts only (spells, items, NPCs, map positions, skill numbers,
-- prices, the client build they were seen on). Nothing that names a character, a realm, an account, a guild or a
-- faction goes in, so the SavedVariables file can be shared (tools/import_savedvars.py reads this table and nothing
-- else). Shape, version 1 (docs/data-sources.md, "The game"):
--
--   learned = {
--     version = 1, build = "1.60.1.70938" (the newest client build that wrote here), locale = "enUS",
--     trainers = { [skillLine] = { [spell or lowercased name] = { skill, cost, seenAt = build } } },
--     ranks    = { [skillLine] = { [cap] = { name, cap, skill, level, cost, where, seen, seenAt = build } } },
--     vendors  = { [npcId] = { map, x, y, seenAt = build, items = { [item] = { price, stock } } } },
--     npcs     = { [npcId] = { id, name, map, x, y, place, sells, teaches, trains, auction, seen } },
--     colors   = { [spell] = { o, y, n, g, seenAt = build } },
--     skillups = { [skillLine] = { [spell or target key] = { [skill bucket] = { t = tries, u = skill-ups } } } },
--   }
--
-- colors: o = the highest skill the recipe was seen orange at, y = the lowest seen yellow or green, n = the highest
-- seen not grey, g = the lowest seen grey. So the yellow threshold is in o+1 .. y and the grey one in n+1 .. g.
-- Before 0.3.0 these lived at the top of SkillupHelperDB (trainerReq, ranks, colorSeen, guide.npcs): L.attach moves
-- them here once.
local _, ns = ...
local L = {}
ns.Learned = L

L.VERSION = 1
L.BUCKET = 5 -- skill points per skill-up bucket
-- Bumped by every write to learned.trainers, so a reader that keeps a derived copy (Scan.withTrainerReq) knows it
-- is stale.
L.trainersVersion = 0

local function tbl(v)
	return type(v) == "table" and v or {}
end

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
end

-- A client value that can be used as a table key or in arithmetic: present and not a secret value (in an instance
-- or encounter the client hands secrets, and a secret as a key or operand is a Lua error: "not now", skip it).
local function usable(v)
	return v ~= nil and not secret(v)
end

-- A number from the client, or nil when it is missing, not a number or a secret value.
local function num(v)
	if type(v) ~= "number" or secret(v) then
		return nil
	end
	return v
end

-- "1.60.1.70938": the client version and build number, or nil when the client gives neither.
function L.buildText(version, buildNumber)
	if type(version) ~= "string" or version == "" then
		return nil
	end
	if buildNumber == nil or buildNumber == "" then
		return version
	end
	return version .. "." .. tostring(buildNumber)
end

local buildNow
function L.build()
	if buildNow == nil and GetBuildInfo then
		local ok, version, buildNumber = pcall(GetBuildInfo)
		buildNow = ok and L.buildText(version, buildNumber) or false
	end
	return buildNow or nil
end

-- a < b for two "1.60.1.70938" texts, part by part.
function L.olderBuild(a, b)
	local pa, pb = {}, {}
	for n in tostring(a or ""):gmatch("%d+") do
		pa[#pa + 1] = tonumber(n)
	end
	for n in tostring(b or ""):gmatch("%d+") do
		pb[#pb + 1] = tonumber(n)
	end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x < y
		end
	end
	return false
end

-- Moves `from` entries into `into`. What is already in `learned` is the newer copy: its values win, and an old
-- record only fills the fields the newer one lacks, `depth` table levels down (trainers and ranks are
-- [skillLine][key][field]: 3, so a rank row learned since keeps its seenAt and gains the old row's other fields).
local function adopt(into, from, depth)
	for k, v in pairs(tbl(from)) do
		if into[k] == nil then
			into[k] = v
		elseif depth > 1 and type(into[k]) == "table" and type(v) == "table" then
			adopt(into[k], v, depth - 1)
		end
	end
end

-- The old colorSeen rows into learned.colors by the colour rules (o, n: the highest; y, g: the lowest), so an old
-- observation narrows a threshold instead of being dropped or overwriting a sharper one.
local function adoptColors(into, from)
	for spell, old in pairs(tbl(from)) do
		local e = into[spell]
		if type(e) ~= "table" then
			into[spell] = old
		elseif type(old) == "table" then
			for field, pick in pairs({ o = math.max, n = math.max, y = math.min, g = math.min }) do
				local a, b = tonumber(e[field]), tonumber(old[field])
				if a and b then
					e[field] = pick(a, b)
				elseif b then
					e[field] = b
				end
			end
		end
	end
end

-- Makes SkillupHelperDB.learned (db = SkillupHelperDB), moving the pre-0.3.0 fields into it: trainerReq -> trainers,
-- ranks -> ranks, colorSeen -> colors, guide.npcs -> npcs. The old fields are removed, so each fact is saved once.
-- Safe to call again (GuideUI and Core both do, whichever loads first). build / locale: the running client's.
function L.attach(db, build, locale)
	if type(db) ~= "table" then
		return nil
	end
	local l = tbl(db.learned)
	l.version = L.VERSION
	for _, key in ipairs({ "trainers", "ranks", "vendors", "npcs", "colors", "skillups" }) do
		l[key] = tbl(l[key])
	end
	if db.trainerReq ~= nil or l ~= db.learned then
		L.trainersVersion = L.trainersVersion + 1
	end
	adopt(l.trainers, db.trainerReq, 3)
	adopt(l.ranks, db.ranks, 3)
	adoptColors(l.colors, db.colorSeen)
	db.trainerReq, db.ranks, db.colorSeen = nil, nil, nil
	if type(db.guide) == "table" then
		adopt(l.npcs, db.guide.npcs, 2)
		db.guide.npcs = nil
	end
	if build and (l.build == nil or L.olderBuild(l.build, build)) then
		l.build = build
	end
	if type(locale) == "string" and not secret(locale) then
		l.locale = locale
	end
	db.learned = l
	return l
end

-- What a trainer asks for each recipe (Scan.trainerReqSet's { [key] = { skill, cost } }), stamped with the build.
function L.noteTrainer(learned, skillLine, req, build)
	if type(learned) ~= "table" or not usable(skillLine) then
		return 0
	end
	learned.trainers = tbl(learned.trainers)
	local store = tbl(learned.trainers[skillLine])
	local n = 0
	for key, e in pairs(tbl(req)) do
		if usable(key) and type(e) == "table" then
			store[key] = { skill = num(e.skill), cost = num(e.cost), seenAt = build }
			n = n + 1
		end
	end
	learned.trainers[skillLine] = store
	L.trainersVersion = L.trainersVersion + 1
	return n
end

-- Stamps the rank rows of one skill line (written by Scan.saveRanks) with the build they were read on.
function L.stampRanks(learned, skillLine, caps, build)
	local store = type(learned) == "table" and usable(skillLine) and tbl(learned.ranks)[skillLine]
	if type(store) ~= "table" then
		return
	end
	for _, r in ipairs(tbl(caps)) do
		if usable(r.cap) and type(store[r.cap]) == "table" then
			store[r.cap].seenAt = build
		end
	end
end

-- The colour the client shows for a learned recipe at this skill (difficulty: 0 orange, 1 yellow, 2 green, 3 grey).
-- Returns true when the record changed.
function L.noteColor(colors, spell, skill, difficulty, build)
	if type(colors) ~= "table" or not num(spell) or not num(skill) or secret(difficulty) then
		return false
	end
	local e = tbl(colors[spell])
	local changed = false
	local function keep(field, better)
		if e[field] == nil or better(skill, e[field]) then
			e[field] = skill
			changed = true
		end
	end
	local function higher(a, b)
		return a > b
	end
	local function lower(a, b)
		return a < b
	end
	if difficulty == 0 then
		keep("o", higher)
	elseif difficulty == 1 or difficulty == 2 then
		keep("y", lower)
	end
	if difficulty == 0 or difficulty == 1 or difficulty == 2 then
		keep("n", higher)
	elseif difficulty == 3 then
		keep("g", lower)
	end
	if changed then
		e.seenAt = build or e.seenAt
		colors[spell] = e
	end
	return changed
end

-- A vendor window: npc = { id, map, x, y }, items = { { item, price, stock }, ... } (price in copper for one item,
-- nil when it costs something else; stock nil = unlimited). The list replaces the last one: it is the whole window.
function L.noteVendor(learned, npc, items, build)
	if type(learned) ~= "table" or type(npc) ~= "table" or not num(npc.id) then
		return nil
	end
	local sold, n = {}, 0
	for _, it in ipairs(tbl(items)) do
		if type(it) == "table" and num(it.item) then
			sold[it.item] = { price = num(it.price), stock = num(it.stock) }
			n = n + 1
		end
	end
	if n == 0 then
		return nil
	end
	local function tenth(v)
		v = num(v)
		return v and math.floor(v * 10 + 0.5) / 10 or nil
	end
	learned.vendors = tbl(learned.vendors)
	local v = { map = num(npc.map), x = tenth(npc.x), y = tenth(npc.y), seenAt = build, items = sold }
	learned.vendors[npc.id] = v
	return v
end

-- One try at a skill-up: a craft of `key` (its spell) or a use of a world target (its key) at `skill`.
function L.noteTry(learned, skillLine, key, skill, up)
	if type(learned) ~= "table" or not usable(skillLine) or not usable(key) or not num(skill) or secret(up) then
		return false
	end
	learned.skillups = tbl(learned.skillups)
	local line = tbl(learned.skillups[skillLine])
	local byKey = tbl(line[key])
	local bucket = math.floor(skill / L.BUCKET) * L.BUCKET
	local e = tbl(byKey[bucket])
	e.t = (e.t or 0) + 1
	if up then
		e.u = (e.u or 0) + 1
	end
	byKey[bucket] = e
	line[key] = byKey
	learned.skillups[skillLine] = line
	return true
end

-- Crafts seen between two scans of a profession. pending = { [spell] = { n = crafts, skill = skill at the first } }.
-- settle() gives each pending craft a try, and the skill gained since (at most one per craft) as skill-ups, oldest
-- recipe first; with more than one recipe pending the gain cannot be told apart and nothing is recorded.
function L.settle(learned, skillLine, pending, skillNow, cap)
	local spells = {}
	for spell in pairs(tbl(pending)) do
		spells[#spells + 1] = spell
	end
	if #spells ~= 1 or not num(skillNow) then
		return 0 -- a secret skill (an instance): not now, the crafts stay pending
	end
	local p = pending[spells[1]]
	cap = num(cap)
	if not num(p.skill) or not num(p.n) or (cap and p.skill >= cap) then
		return 0 -- at the rank cap nothing can give a point: not a try
	end
	local gained = math.max(0, math.min(p.n, skillNow - p.skill))
	for i = 1, p.n do
		L.noteTry(learned, skillLine, spells[1], math.min(p.skill + i - 1, skillNow), i <= gained)
	end
	return p.n
end

-- Counts for the selftest: how much the table holds.
function L.status(learned)
	if type(learned) ~= "table" then
		return "SkillupHelperDB.learned absent"
	end
	local function count(t, deep)
		local n = 0
		for _, v in pairs(tbl(t)) do
			if deep then
				for _ in pairs(tbl(v)) do
					n = n + 1
				end
			else
				n = n + 1
			end
		end
		return n
	end
	return {
		version = learned.version,
		build = learned.build,
		locale = learned.locale,
		trainers = count(learned.trainers, true),
		ranks = count(learned.ranks, true),
		vendors = count(learned.vendors),
		npcs = count(learned.npcs),
		colors = count(learned.colors),
		skillups = count(learned.skillups, true),
	}
end
