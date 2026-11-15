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

local function tbl(v)
	return type(v) == "table" and v or {}
end

local function secret(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
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

-- Moves `from[key]` entries into `into` where `into` has none (what is already in `learned` is the newer copy).
local function adopt(into, from)
	for k, v in pairs(tbl(from)) do
		if into[k] == nil then
			into[k] = v
		elseif type(into[k]) == "table" and type(v) == "table" then
			for k2, v2 in pairs(v) do
				if into[k][k2] == nil then
					into[k][k2] = v2
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
	adopt(l.trainers, db.trainerReq)
	adopt(l.ranks, db.ranks)
	adopt(l.colors, db.colorSeen)
	db.trainerReq, db.ranks, db.colorSeen = nil, nil, nil
	if type(db.guide) == "table" then
		adopt(l.npcs, db.guide.npcs)
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
	if type(learned) ~= "table" or skillLine == nil then
		return 0
	end
	local store = tbl(learned.trainers[skillLine])
	local n = 0
	for key, e in pairs(tbl(req)) do
		store[key] = { skill = e.skill, cost = e.cost, seenAt = build }
		n = n + 1
	end
	learned.trainers[skillLine] = store
	return n
end

-- Stamps the rank rows of one skill line (written by Scan.saveRanks) with the build they were read on.
function L.stampRanks(learned, skillLine, caps, build)
	local store = type(learned) == "table" and learned.ranks[skillLine]
	if type(store) ~= "table" then
		return
	end
	for _, r in ipairs(tbl(caps)) do
		if type(store[r.cap]) == "table" then
			store[r.cap].seenAt = build
		end
	end
end

-- The colour the client shows for a learned recipe at this skill (difficulty: 0 orange, 1 yellow, 2 green, 3 grey).
-- Returns true when the record changed.
function L.noteColor(colors, spell, skill, difficulty, build)
	if type(colors) ~= "table" or type(spell) ~= "number" or type(skill) ~= "number" then
		return false
	end
	if secret(skill) or secret(difficulty) then
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
	if type(learned) ~= "table" or type(npc) ~= "table" or type(npc.id) ~= "number" then
		return nil
	end
	local sold, n = {}, 0
	for _, it in ipairs(tbl(items)) do
		if type(it.item) == "number" then
			sold[it.item] = { price = it.price, stock = it.stock }
			n = n + 1
		end
	end
	if n == 0 then
		return nil
	end
	local function tenth(v)
		return type(v) == "number" and math.floor(v * 10 + 0.5) / 10 or nil
	end
	local v = { map = npc.map, x = tenth(npc.x), y = tenth(npc.y), seenAt = build, items = sold }
	learned.vendors[npc.id] = v
	return v
end

-- One try at a skill-up: a craft of `key` (its spell) or a use of a world target (its key) at `skill`.
function L.noteTry(learned, skillLine, key, skill, up)
	if type(learned) ~= "table" or skillLine == nil or key == nil or type(skill) ~= "number" then
		return false
	end
	if secret(skill) or secret(key) then
		return false
	end
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
	if #spells ~= 1 or type(skillNow) ~= "number" then
		return 0
	end
	local p = pending[spells[1]]
	if type(p.skill) ~= "number" or (type(cap) == "number" and p.skill >= cap) then
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
