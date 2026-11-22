-- Where to go for the step to do now: which vendor, trainer or auctioneer serves it, the nearest one, and how far and
-- in which direction it is. Pure logic: no frames and no client calls except through `env`, so busted tests it whole;
-- GuideUI.lua does the client side (positions, the waypoint, the Target button).
--
-- An NPC record: { id, name, map, x, y, sells = { [item] = true }, trains = "Leatherworking", auction = true,
-- place = "Thunder Bluff", seed = true }. x and y are percent (0-100) on uiMap `map`. Seeds come from Data/Npcs.lua;
-- learned records (SavedVariables) replace a seed with the same id, since they were measured on this client.
local _, ns = ...
local G = {}
ns.Guide = G

G.NEAR = 60 -- yards: within this the Target button is offered (the client finds a unit by name about this far)
G.ARRIVED = 12 -- yards: "it is here, look around"
G.FAR = 75 -- yards: "near" is left only past this (hysteresis)

local TWO_PI = 2 * math.pi

-- The npc id in a creature GUID ("Creature-0-1-2-3-<npcID>-<spawn>"), or nil for players, pets and other units.
function G.npcId(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	if kind ~= "Creature" then
		return nil
	end
	return tonumber(id)
end

-- The town and zone of an unlock NPC (Data/Routes.lua routeRanks npcs: { id?, name, map, x, y, place? }): its own
-- place, else the place of the shipped or seeded row with its id, else the town of the nearest row on the same map
-- (G.placeNear), else the zone. zone: the map's name in Data/Spots.lua. data: ns.Data's shape (default ns.Data).
function G.unlockPlace(npc, data)
	data = data or ns.Data or {}
	local rows = {}
	for _, list in ipairs({ data.npcs or {}, data.trainers or {} }) do
		for _, r in ipairs(list) do
			rows[#rows + 1] = r
		end
	end
	local maps = type(data.spots) == "table" and data.spots.maps or {}
	local zone = npc.map and maps[npc.map] and maps[npc.map].name or nil
	local place = type(npc.place) == "string" and npc.place or nil
	if not place and npc.id then
		for _, r in ipairs(rows) do
			if r.id == npc.id and type(r.place) == "string" then
				place = r.place
				break
			end
		end
	end
	place = place or G.placeNear(npc.map, npc.x, npc.y, rows, nil)
	return place or zone, zone
end

-- An unlock's NPCs as guide records ({ id (the npc id, else "unlock:<name>"), name, map, x, y, place, zone, nopos,
-- shipped, confidence = "classic" }): they carry their own positions, so the chip works for an NPC no other data
-- lists. Not cached: the lists are two or three NPCs, and the places come from the data as it is now.
function G.unlockRecords(npcs, data)
	if type(npcs) ~= "table" then
		return {}
	end
	local out = {}
	for _, n in ipairs(npcs) do
		if type(n) == "table" and type(n.name) == "string" then
			local place, zone = G.unlockPlace(n, data)
			local nopos = n.map == nil or type(n.x) ~= "number" or type(n.y) ~= "number"
			out[#out + 1] = {
				id = n.id or ("unlock:" .. n.name),
				name = n.name,
				map = n.map,
				x = not nopos and n.x or nil,
				y = not nopos and n.y or nil,
				place = place,
				zone = zone,
				nopos = nopos or nil,
				shipped = true,
				confidence = "classic",
				unlock = true,
			}
		end
	end
	return out
end

-- What the step to do now needs a visit for, in the order to go: a list of
-- { kind = "vendor", items = { { item, count } } } | { kind = "trainer", profession = name }
-- | { kind = "auction", items = {...} } | { kind = "quest", quest, name = questName }. A need may carry npcs (guide
-- records, G.unlockRecords): then only those NPCs serve it (a rank unlock of Data/Routes.lua: the trainer, the book's
-- vendor or the quest giver the guide names). Empty when the step needs nothing from an NPC.
function G.needsOf(step, profession)
	local out = {}
	if type(step) ~= "table" then
		return out
	end
	local unlock = step.kind == "trainRank" and type(step.unlock) == "table" and step.unlock or nil
	if unlock and #(unlock.npcs or {}) > 0 then
		local npcs = G.unlockRecords(unlock.npcs)
		if unlock.kind == "book" and unlock.item then
			out[1] = { kind = "vendor", items = { { item = unlock.item, count = 1 } }, npcs = npcs }
			return out
		elseif unlock.kind == "quest" then
			-- the hand-in items first (vendor, then auction house), then the quest giver
			local vendor, ah = {}, {}
			for _, m in ipairs(unlock.mats or {}) do
				if m.where == "vendor" then
					vendor[#vendor + 1] = { item = m.item, count = m.count }
				elseif m.where == "ah" then
					ah[#ah + 1] = { item = m.item, count = m.count }
				end
			end
			if #vendor > 0 then
				out[#out + 1] = { kind = "vendor", items = vendor }
			end
			if #ah > 0 then
				out[#out + 1] = { kind = "auction", items = ah }
			end
			out[#out + 1] = { kind = "quest", quest = unlock.quest, name = unlock.questName, npcs = npcs }
			return out
		elseif unlock.kind == "trainer" then
			out[1] = {
				kind = "trainer",
				profession = profession,
				name = step.name,
				at = step.at,
				cap = step.cap,
				npcs = npcs,
			}
			return out
		end
	end
	if type(step.kind) == "string" and step.kind:find("^train") then
		-- "train" (a recipe) and any later train step (a rank-up): the service to learn is step.name, else step.rank
		-- cap: a rank-up's new skill cap (trainRank), which a trainer of a lower rank does not teach
		out[1] = {
			kind = "trainer",
			profession = profession,
			name = step.name or step.rank,
			at = step.at,
			cap = step.kind == "trainRank" and step.cap or nil,
			-- a recipe learned past an unlock rank's training skill: the trainers the guide names (Planner markUnlocks)
			-- join the pool (npcsAdd); every other trainer that teaches the recipe still serves it
			npcs = step.kind == "train" and type(step.trainers) == "table" and #step.trainers > 0 and G.unlockRecords(
				step.trainers
			) or nil,
		}
		out[1].npcsAdd = out[1].npcs and true or nil
		return out
	elseif step.kind == "buyRecipe" then
		-- a recipe item the data's vendor sells for less than the auction house goes to a vendor
		local kind = step.where == "vendor" and "vendor" or "auction"
		if step.where == "source" or not step.item then
			-- a recipe to get from a quest, a drop or a teacher: no NPC the guide knows
			return out
		end
		out[1] = { kind = kind, items = { { item = step.item, count = 1 } } }
		return out
	end
	local vendor, ah = {}, {}
	for _, b in ipairs(step.buy or {}) do
		if b.where == "vendor" then
			vendor[#vendor + 1] = { item = b.item, count = b.count }
		elseif b.where == "ah" then
			ah[#ah + 1] = { item = b.item, count = b.count }
		end
	end
	if #vendor > 0 then
		out[#out + 1] = { kind = "vendor", items = vendor }
	end
	if #ah > 0 then
		out[#out + 1] = { kind = "auction", items = ah }
	end
	return out
end

-- A need whose items are all in the bags already is done. have(item) -> count in bags (and bank).
function G.pending(needs, have)
	local out = {}
	for _, n in ipairs(needs) do
		-- a trainer or quest need stays open: no bag count closes it; it goes with its step once the rank is learned
		-- (the skill cap rises and the plan drops the trainRank step)
		local open = n.kind == "trainer" or n.kind == "quest"
		for _, it in ipairs(n.items or {}) do
			if (have(it.item) or 0) < it.count then
				open = true
			end
		end
		if open then
			out[#out + 1] = n
		end
	end
	return out
end

-- A trainer service name as the teaches set keys it: lowercased, trimmed. nil for anything but a non-empty string.
function G.norm(s)
	if type(s) ~= "string" then
		return nil
	end
	s = s:lower():match("^%s*(.-)%s*$")
	return s ~= "" and s or nil
end

-- Whether a trainer's line and a profession name are the same profession: equal, or one is the other behind a
-- prefix word ("Classic Leatherworking" and "Leatherworking"). Empty names match nothing.
function G.sameProfession(a, b)
	if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then
		return false
	end
	if a == b then
		return true
	end
	local long, short = a, b
	if #short > #long then
		long, short = short, long
	end
	return long:sub(-#short - 1) == " " .. short
end

-- The skill cap a trainer's rank (Data/Trainers.lua `rank`, from its title) teaches up to. Classic's ladder,
-- unconfirmed for Forever: a trainer without a rank in the data is taken to teach everything.
G.RANK_CAP = { apprentice = 75, journeyman = 150, expert = 225, artisan = 300, master = 300, ["grand master"] = 300 }

-- The ladder in order, for naming the rank a need asks for. The top cap (Artisan's, and the Master and Grand Master
-- titles, which train no higher here) teaches every recipe.
G.RANKS = { "apprentice", "journeyman", "expert", "artisan" }
G.TOP_CAP = 300

-- Whether a trainer's rank reaches a trainer need: a rank-up to need.cap, or a recipe learned at skill need.at.
-- A trainer teaches the recipes learned below the next rank's training skill (cap - 25): a Journeyman (cap 150)
-- teaches recipes learned up to 124, and one learned at 125 or more needs an Expert. True when either side is not
-- known.
function G.rankReaches(npc, need)
	local cap = type(npc.rank) == "string" and G.RANK_CAP[npc.rank] or nil
	if cap == nil then
		return true
	elseif type(need.cap) == "number" then
		return cap >= need.cap
	end
	local at = tonumber(need.at)
	return at == nil or cap >= G.TOP_CAP or at < cap - 25
end

-- The lowest rank that reaches a trainer need, capitalized ("Expert"), or nil when the need names no skill. A recipe
-- learned past the last rank's training skill still needs the top rank, never one past it.
function G.needRank(need)
	if type(need) ~= "table" or need.kind ~= "trainer" or not (tonumber(need.cap) or tonumber(need.at)) then
		return nil
	end
	for _, r in ipairs(G.RANKS) do
		if G.rankReaches({ rank = r }, need) then
			return G.rankTitle(r)
		end
	end
	return G.rankTitle(G.RANKS[#G.RANKS])
end

-- "an Expert", "a Journeyman": a rank name with its article.
function G.aRank(name)
	name = tostring(name)
	return (name:find("^[AEIOUaeiou]") and "an " or "a ") .. name
end

-- A trainer's rank as its title words ("Expert"), or nil.
function G.rankTitle(rank)
	if type(rank) ~= "string" or rank == "" then
		return nil
	end
	return (rank:gsub("(%a)(%a*)", function(a, b)
		return a:upper() .. b
	end))
end

-- How well an NPC serves a need: the number of the need's items it sells (vendor); 1 for an auctioneer; for a trainer
-- of the profession 2 when its learned service list has the need's name (certain), 1 when that is not known (a seed,
-- a trainer never opened, a list read in part, or a need without a name), 0 when its full list lacks the name or,
-- for a trainer never opened or read in part, when its rank is below the need (second value "rank": a Journeyman for
-- an Expert recipe). A whole list that has the name wins over the rank: it was read on this client.
function G.serves(npc, need)
	if type(need.npcs) == "table" and not need.npcsAdd then
		-- only the NPCs the need names (a rank unlock): matched by id, else by name; the guide says they serve it
		local hit = false
		for _, n in ipairs(need.npcs) do
			if (npc.id ~= nil and npc.id == n.id) or npc.name == n.name then
				hit = true
				break
			end
		end
		if not hit then
			return 0
		end
		return need.kind == "vendor" and #need.items or (need.kind == "trainer" and 2 or 1)
	end
	if need.kind == "vendor" then
		local n = 0
		for _, it in ipairs(need.items) do
			if npc.sells and npc.sells[it.item] then
				n = n + 1
			end
		end
		return n
	elseif need.kind == "trainer" then
		if not G.sameProfession(need.profession, npc.trains) then
			return 0
		end
		local name = G.norm(need.name)
		if name and type(npc.teaches) == "table" then
			-- a rank-up may be listed as the profession with the rank before it ("Expert Cooking")
			local prof = G.norm(npc.trains)
			if npc.teaches[name] or (prof and npc.teaches[name .. " " .. prof]) then
				return 2
			elseif not npc.teachesPartial then
				return 0
			end
		end
		-- never opened, read in part, or a need without a name: its title's rank says what it teaches
		if not G.rankReaches(npc, need) then
			return 0, "rank"
		end
		return 1
	elseif need.kind == "auction" then
		return npc.auction and 1 or 0
	end
	return 0
end

-- A learned record over the seed of the same id, as a new table (the learned one is SavedVariables): the visit's
-- position, name and service list win; the seed fills what the visit left empty (role, place); sells is the union.
local function merge(seed, npc)
	local m = {}
	for k, v in pairs(npc) do
		m[k] = v
	end
	m.trains = npc.trains or seed.trains
	m.auction = npc.auction or seed.auction
	m.place = npc.place or seed.place
	m.rank = npc.rank or seed.rank
	m.limited = npc.limited or seed.limited
	if seed.sells or npc.sells then
		m.sells = {}
		for item in pairs(seed.sells or {}) do
			m.sells[item] = true
		end
		for item in pairs(npc.sells or {}) do
			m.sells[item] = true
		end
	end
	return m
end

-- Every known NPC (same id merged): learned over seeded over shipped. shipped: G.shippedRecords' records
-- (Data/Trainers.lua); foreign: its second value, the ids of the other faction's NPCs, whose seeds are left out
-- (Data/Npcs.lua has no faction of its own). A learned NPC always stays: the player opened its window.
function G.known(seeds, learned, shipped, foreign)
	local byId, out = {}, {}
	for _, npc in ipairs(shipped or {}) do
		byId[npc.id] = npc
	end
	for _, npc in ipairs(seeds or {}) do
		if not (foreign and foreign[npc.id]) then
			local s = byId[npc.id]
			byId[npc.id] = s and merge(s, npc) or npc
		end
	end
	for id, npc in pairs(learned or {}) do
		local s = byId[id]
		byId[id] = s and merge(s, npc) or npc
	end
	for _, npc in pairs(byId) do
		out[#out + 1] = npc
	end
	return out
end

-- Where a record comes from: "learned" (a window the player opened; it wins over the other two), "seed"
-- (Data/Npcs.lua, SkillupHelper_Custom) or "shipped" (Data/Trainers.lua).
function G.sourceOf(npc)
	return npc.shipped and "shipped" or npc.seed and "seed" or "learned"
end

-- How far a record's position can be trusted: "confirmed" (learned, or the player's own Custom.lua row), "classic"
-- (a Classic position, unconfirmed for Forever) or "nopos" (no position: the zone name only, no waypoint).
function G.confidenceOf(npc)
	if G.sourceOf(npc) == "learned" then
		return "confirmed"
	elseif npc.nopos or type(npc.x) ~= "number" or type(npc.y) ~= "number" or npc.map == nil then
		return "nopos"
	end
	return npc.confidence or "classic"
end

G.TEXT = {
	classic = "position from Classic, unconfirmed",
	nopos = "position not known",
}

-- The confidence line of a pick for a card: nil when the position was measured on this client.
-- "Position from Classic, unconfirmed" | "In Desolace, position not known" | "Position not known".
function G.confidenceText(confidence, place)
	if confidence == "classic" then
		return "Position from Classic, unconfirmed"
	elseif confidence == "nopos" then
		return place and ("In %s, %s"):format(place, G.TEXT.nopos) or "Position not known"
	end
	return nil
end

-- "Horde", "Alliance" or nil -> "H", "A" or nil ("H" and "A" pass through).
function G.side(faction)
	local c = type(faction) == "string" and faction:sub(1, 1):upper() or nil
	return (c == "A" or c == "H") and c or nil
end

-- Data/Trainers.lua's rows as NPC records for one faction ("Horde" | "Alliance" | "H" | "A"; nil keeps every side):
-- trainers (trains, rank) and recipe vendors (sells) of that faction and neutral ones. Rows without a position are
-- kept with nopos = true (the zone in `place`, no waypoint); creatures that only drop a recipe are left out. Each
-- record has shipped = true and confidence "classic" | "confirmed". Where.trainerRecords builds the same records for
-- the errand map, without the nopos rows and the rank.
-- Returns the records and the set of ids of the other faction's NPCs.
function G.shippedRecords(rows, faction)
	local out, foreign = {}, {}
	local side = G.side(faction)
	for _, r in ipairs(rows or {}) do
		local f = r.faction
		local mine = f == nil or f == "B" or side == nil or f == side
		if not mine then
			foreign[r.id] = true
		elseif r.role == "trainer" or r.sells then
			local sells
			if r.sells then
				sells = {}
				for _, item in ipairs(r.sells) do
					sells[item] = true
				end
			end
			local nopos = r.nopos or r.map == nil or type(r.x) ~= "number" or type(r.y) ~= "number"
			out[#out + 1] = {
				id = r.id,
				name = r.name,
				map = r.map,
				x = not nopos and r.x or nil,
				y = not nopos and r.y or nil,
				place = r.place,
				sells = sells,
				trains = r.role == "trainer" and r.trains or nil,
				rank = r.rank,
				limited = r.limited,
				unsure = r.unsure,
				nopos = nopos or nil,
				shipped = true,
				confidence = r.classic and "classic" or "confirmed",
			}
		end
	end
	return out, foreign
end

-- Direction in radians, counter-clockwise from north (the convention of GetPlayerFacing), from world position a to
-- b. World coordinates as C_Map.GetWorldPosFromMapPos gives them: x grows north, y grows west.
function G.bearing(ax, ay, bx, by)
	local a = math.atan2(by - ay, bx - ax)
	if a < 0 then
		a = a + TWO_PI
	end
	return a
end

-- The arrow's rotation for a texture (SetRotation, counter-clockwise), the bearing seen from the player's facing.
function G.arrowAngle(bearing, facing)
	local a = (bearing - (facing or 0)) % TWO_PI
	return a
end

-- The NPCs to look through for a need: npcs as given, or for a need that names its NPCs (need.npcs) those, each as
-- the known record of the same id when there is one (a position measured on this client wins), else as named.
function G.needNpcs(npcs, need)
	if type(need) ~= "table" or type(need.npcs) ~= "table" then
		return npcs or {}
	end
	local byId = {}
	for _, npc in ipairs(npcs or {}) do
		if npc.id ~= nil then
			byId[npc.id] = npc
		end
	end
	local out = {}
	if need.npcsAdd then
		-- the whole pool, plus each named NPC no record lists, as a trainer of the need's profession (no rank: the
		-- guide says it teaches this)
		local names = {}
		for _, npc in ipairs(npcs or {}) do
			out[#out + 1] = npc
			names[npc.name or ""] = true
		end
		for _, n in ipairs(need.npcs) do
			if not byId[n.id] and not names[n.name] then
				local m = {}
				for key, v in pairs(n) do
					m[key] = v
				end
				m.trains = need.profession
				out[#out + 1] = m
			end
		end
		return out
	end
	for _, n in ipairs(need.npcs) do
		local k = byId[n.id]
		if k and G.confidenceOf(k) ~= "nopos" then
			local m = {}
			for key, v in pairs(k) do
				m[key] = v
			end
			m.place = k.place or n.place
			out[#out + 1] = m
		else
			out[#out + 1] = n
		end
	end
	return out
end

-- The nearest NPC serving `need`. here = { continent, x, y } (world yards) or nil when the position is unknown.
-- world(map, x, y) -> continent, wx, wy or nil. Picks the best server first (the higher G.serves score: a vendor
-- selling every item beats one selling some, a trainer known to teach the name beats one that may), then the
-- shortest distance on the player's continent; other continents last, without a distance.
-- An NPC without a position (nopos) comes after every NPC that has one: it has a zone, no distance and no waypoint.
-- Returns { npc, distance, bearing, wx, wy, continent, sameContinent, partial, certain, name, zone, source
-- ("learned" | "seed" | "shipped"), confidence ("confirmed" | "classic" | "nopos"), note (G.confidenceText), nopos,
-- unsure } or nil, how many serve it, how many trainers of the profession were left out because their full service
-- list lacks the name, and the counts { servers, excluded, belowRank (left out by their rank), profession (records
-- of the need's profession, whatever they teach), bySource = { shipped, learned, seed } (of the servers) }.
local function scan(npcs, need, here, world, each)
	npcs = G.needNpcs(npcs, need)
	local stats = { servers = 0, excluded = 0, belowRank = 0, profession = 0 }
	stats.bySource = { shipped = 0, learned = 0, seed = 0 }
	local named = need.kind == "trainer" and G.norm(need.name) ~= nil
	local want = need.kind == "vendor" and #need.items or 1
	for _, npc in ipairs(npcs) do
		local s, why = G.serves(npc, need)
		if need.kind == "trainer" and G.sameProfession(need.profession, npc.trains) then
			stats.profession = stats.profession + 1
			if why == "rank" then
				stats.belowRank = stats.belowRank + 1
			elseif s == 0 and named then
				stats.excluded = stats.excluded + 1
			end
		end
		if s > 0 then
			stats.servers = stats.servers + 1
			local source = G.sourceOf(npc)
			stats.bySource[source] = stats.bySource[source] + 1
			local confidence = G.confidenceOf(npc)
			local cont, wx, wy
			if confidence ~= "nopos" then
				cont, wx, wy = world(npc.map, npc.x, npc.y)
			end
			local dist, same = nil, false
			if here and cont and cont == here.continent then
				same = true
				local dx, dy = wx - here.x, wy - here.y
				dist = math.sqrt(dx * dx + dy * dy)
			end
			-- lower is better: a higher serve score, then the same continent, then distance; no position last
			local tier = confidence == "nopos" and 2e8 or (same and 0 or 1e8)
			each(npc, -s * 1e9 + tier + (dist or 0), s, dist, same, cont, wx, wy, source, confidence, named, want)
		end
	end
	return stats
end

local function pickOf(need, here, npc, s, dist, same, cont, wx, wy, source, confidence, named, want)
	local pick = {
		npc = npc,
		name = npc.name,
		zone = npc.place,
		distance = dist,
		wx = wx,
		wy = wy,
		continent = cont,
		sameContinent = same,
		partial = need.kind == "vendor" and s < want,
		-- false only for a named trainer need whose trainer may or may not teach it
		certain = not named or s >= 2,
		source = source,
		confidence = confidence,
		note = G.confidenceText(confidence, npc.place),
		nopos = confidence == "nopos" or nil,
		unsure = npc.unsure or nil,
	}
	if same then
		pick.bearing = G.bearing(here.x, here.y, wx, wy)
	end
	return pick
end

-- ids are numbers, or "name:<Name>" for an NPC learned without a readable GUID: compare as strings
local function before(keyA, idA, keyB, idB)
	if keyA ~= keyB then
		return keyA < keyB
	end
	return tostring(idA) < tostring(idB)
end

-- The nearest server of a need: documented above `scan`, which does the pass.
function G.nearest(npcs, need, here, world)
	local bestKey, best
	local stats = scan(npcs, need, here, world, function(npc, key, ...)
		if not best or before(key, npc.id, bestKey, best[1].id) then
			bestKey, best = key, { npc, ... }
		end
	end)
	local pick = best and pickOf(need, here, unpack(best, 1, 11)) or nil
	return pick, stats.servers, stats.excluded, stats
end

-- Every NPC serving `need`, best first (G.nearest's order and pick shape; the first is G.nearest's pick), and
-- the same counts. For a card that lists the choices.
function G.ranked(npcs, need, here, world)
	local list = {}
	local stats = scan(npcs, need, here, world, function(npc, key, ...)
		local pick = pickOf(need, here, npc, ...)
		pick.key = key
		list[#list + 1] = pick
	end)
	table.sort(list, function(a, b)
		return before(a.key, a.npc.id, b.key, b.npc.id)
	end)
	return list, stats
end

-- The guide's state for the chip and the card: "none" (no known NPC), "away" (another continent or no position),
-- "far", "near", "arrived", "here" (its window is open). targeted: the NPC is the player's target. prev: the phase
-- before, so "near" holds out to G.FAR yards and the chip does not flicker at the edge.
function G.phase(pick, open, targeted, prev)
	if not pick then
		return "none"
	end
	if open then
		return "here"
	end
	if targeted then
		return "targeted"
	end
	local d = pick.distance
	if not d then
		return "away"
	elseif d <= G.ARRIVED then
		return "arrived"
	elseif d <= G.NEAR or (d <= G.FAR and (prev == "near" or prev == "arrived" or prev == "targeted")) then
		return "near"
	end
	return "far"
end

-- "35 yd", "420 yd", "1.2 km"-style but in yards, the game's unit: rounded so the number does not flicker.
function G.distanceText(d)
	if not d then
		return nil
	end
	if d < 100 then
		return ("%d yd"):format(math.floor(d / 5 + 0.5) * 5)
	elseif d < 1000 then
		return ("%d yd"):format(math.floor(d / 10 + 0.5) * 10)
	end
	return ("%.1fk yd"):format(d / 1000)
end

-- Eight-way compass word for a bearing (counter-clockwise from north), for the text next to the arrow.
local COMPASS = { "north", "northwest", "west", "southwest", "south", "southeast", "east", "northeast" }
function G.compass(bearing)
	local i = math.floor(((bearing or 0) % TWO_PI) / (TWO_PI / 8) + 0.5) % 8
	return COMPASS[i + 1]
end

-- What a need is called in the guide's text. nameOf(item) -> item name.
function G.needLabel(need, nameOf)
	if need.kind == "trainer" then
		return ("%s trainer"):format(need.profession or "profession")
	elseif need.kind == "auction" then
		return "auction house"
	elseif need.kind == "quest" then
		return need.name and ("quest %s"):format(need.name) or "quest giver"
	end
	local names = {}
	for i, it in ipairs(need.items) do
		if i > 2 then
			names[#names + 1] = ("%d more"):format(#need.items - 2)
			break
		end
		names[#names + 1] = nameOf(it.item)
	end
	return table.concat(names, ", ")
end

-- The honest line when no NPC is known for a need. excluded: trainers of the profession whose full list lacks the
-- need's name (Guide.nearest's third value); belowRank: trainers left out because their rank is below the need's
-- (its fourth value's belowRank).
function G.unknownText(need, nameOf, excluded, belowRank)
	local rank = need.kind == "trainer" and (belowRank or 0) > 0 and G.needRank(need)
	-- the same order as G.describe and G.strip: opened trainers lacking the name first, then the rank
	if need.kind == "trainer" and need.name and (excluded or 0) > 0 then
		return ("No trainer you've opened teaches %s. It may come from a special NPC or a recipe item."):format(
			need.name
		)
	elseif rank then
		return ("%s needs %s %s trainer or better; the trainers I know are below that."):format(
			need.name or "This",
			G.aRank(rank),
			need.profession or "profession"
		)
	elseif need.kind == "trainer" then
		return ("No %s trainer known yet. Guards in any city point the way; I note trainers you open."):format(
			need.profession or "profession"
		)
	elseif need.kind == "auction" then
		return "No auctioneer known yet. Every capital has one; I note the ones you open."
	elseif need.kind == "quest" then
		return ("The guide names no quest giver for %s on your side."):format(tostring(need.name or "this quest"))
	end
	return ("No known vendor for %s yet. Trade Supplies vendors carry most of it; I note vendors you open."):format(
		G.needLabel(need, nameOf)
	)
end

-- The diagnostic `why` of the empty state: which link gave nothing for a need. c = { stats (G.nearest's fourth
-- value), faction ("Horde" | "Alliance" | nil), shipped (Data/Trainers.lua is loaded), thing (the first item's name) }.
function G.whyNone(need, c)
	c = c or {}
	local stats = c.stats or {}
	local side = G.side(c.faction)
	local who = side == "H" and "Horde"
		or side == "A" and "Alliance"
		or "an unknown faction (UnitFactionGroup gave none)"
	local data = c.shipped == false and "Data/Trainers.lua is not loaded" or nil
	if need.kind == "trainer" then
		local p = need.profession or "profession"
		if (stats.excluded or 0) > 0 then
			return ("%d %s trainer(s) opened, none lists %s"):format(stats.excluded, p, tostring(need.name))
		elseif (stats.belowRank or 0) > 0 then
			return ("Data/Trainers.lua has %d %s trainer(s) for %s, none of a rank that teaches %s (skill %s)"):format(
				stats.belowRank,
				p,
				who,
				tostring(need.name or "it"),
				tostring(need.cap or need.at or "?")
			)
		end
		return ("%s, and no %s trainer learned or seeded"):format(
			data or ("Data/Trainers.lua has no %s trainer for %s"):format(p, who),
			p
		)
	elseif need.kind == "auction" then
		return "Data/Npcs.lua has no auctioneer, and none learned"
	elseif type(need.npcs) == "table" then
		return ("Data/Routes.lua routeRanks names no NPC with a position for %s"):format(who)
	end
	return ("%s, and none in Data/Npcs.lua or learned"):format(
		data or ("Data/Trainers.lua has no vendor selling %s for %s"):format(tostring(c.thing or "these items"), who)
	)
end

-- A list of trainer service names as the set G.serves looks names up in.
function G.teachesSet(list)
	local set = {}
	for _, name in ipairs(list or {}) do
		local k = G.norm(name)
		if k then
			set[k] = true
		end
	end
	return set
end

-- One read of a trainer's service list during a visit. The server fills the list after TRAINER_SHOW and sends
-- TRAINER_UPDATE as it does, so: a read with no service is "not yet" (nothing saved), and a read with fewer names
-- than one already taken in the same visit (a list still loading, a filter changed) never replaces the fuller one.
-- visit = { id, best, reads, lastWhole, whole } of the visit so far, or nil at a new one. A list still filling can
-- read with no unreadable name and still be short, so the visit counts as whole (G.trainerWants stops) only when two
-- whole reads in a row give the same number of names. Returns teaches, partial to save (nil, nil: keep what is
-- saved), the visit, and why a read was held back.
function G.trainerRead(visit, id, names, partial, services)
	if type(visit) ~= "table" or visit.id ~= id then
		visit = { id = id, best = 0, reads = 0 }
	end
	visit.reads = (visit.reads or 0) + 1
	names = type(names) == "table" and names or {}
	if not partial and #names > 0 then
		visit.whole = visit.lastWhole == #names or nil
		visit.lastWhole = #names
	else
		visit.lastWhole = nil
	end
	if (tonumber(services) or 0) < 1 or #names == 0 then
		return nil, nil, visit, "not yet: the trainer listed no services (the list fills after the window opens)"
	end
	if #names < visit.best then
		return nil, nil, visit, ("kept the fuller list of this visit (%d names over %d)"):format(visit.best, #names)
	end
	visit.best = #names
	return names, partial and true or nil, visit, nil
end

-- At most this many reads of one trainer visit: each read switches the type filters, and every switch raises
-- another TRAINER_UPDATE, so reading on every update would never stop while the window is open.
G.TRAINER_READS = 6

-- Whether a TRAINER_UPDATE should read the list again in this visit: not after a whole list was read, and not past
-- G.TRAINER_READS reads. Returns the answer and why not.
function G.trainerWants(visit)
	if type(visit) ~= "table" then
		return true
	elseif visit.whole then
		return false, "the whole list was read this visit"
	elseif (visit.reads or 0) >= G.TRAINER_READS then
		return false, ("read %d times this visit, the list stayed in part"):format(visit.reads)
	end
	return true
end

-- Merges what a window just showed into the learned records. rec = { id, name, map, x, y, sells (list of item ids),
-- trains, auction, teaches (list of service names), teachesPartial }. Keeps what an earlier visit learned that this
-- one cannot see (a trainer that also sells). A trainer's service list is replaced, not merged: it is the whole list.
function G.learn(learned, rec, now)
	if not rec.id or not rec.map or not rec.x then
		return nil
	end
	local npc = learned[rec.id] or { id = rec.id }
	npc.name = rec.name or npc.name
	npc.map, npc.x, npc.y = rec.map, math.floor(rec.x * 10 + 0.5) / 10, math.floor(rec.y * 10 + 0.5) / 10
	if rec.sells then
		npc.sells = npc.sells or {}
		for _, item in ipairs(rec.sells) do
			npc.sells[item] = true
		end
	end
	if rec.teaches then
		npc.teaches = G.teachesSet(rec.teaches)
		npc.teachesPartial = rec.teachesPartial and true or nil
	elseif npc.teachesPartial and type(npc.teaches) == "table" and next(npc.teaches) == nil then
		-- an empty partial list saved before 0.3.0 by a read made before the trainer's list had filled: unknown,
		-- not "teaches nothing"; the next read with services replaces it
		npc.teaches, npc.teachesPartial = nil, nil
	end
	npc.trains = rec.trains or npc.trains
	npc.auction = rec.auction or npc.auction
	npc.place = rec.place or npc.place
	npc.seen = now
	learned[rec.id] = npc
	return npc
end

-- The town a learned NPC stands in: the place of the nearest seed on the same map within G.TOWN (percent of the map),
-- else the map's name (mapName, from C_Map.GetMapInfo; nil when unknown). Seeds name towns ("Crossroads") where a
-- map name would say only the zone.
G.TOWN = 6
function G.placeNear(map, x, y, seeds, mapName)
	local best, bestD
	for _, s in ipairs(seeds or {}) do
		if
			s.map == map
			and s.place
			and type(s.x) == "number"
			and type(s.y) == "number"
			and type(x) == "number"
			and type(y) == "number"
		then
			local dx, dy = s.x - x, s.y - y
			local d = math.sqrt(dx * dx + dy * dy)
			if d <= G.TOWN and (not bestD or d < bestD) then
				best, bestD = s.place, d
			end
		end
	end
	return best or mapName
end

-- Turns Data/Npcs.lua's rows ({ ..., role, sells = { ids } }) into NPC records. confirmed: a set of ids whose
-- position is the player's own (SkillupHelper_Custom rows); the others are Classic positions (G.confidenceOf).
local ROLE_TRAINS = { lwtrainer = "Leatherworking", cooktrainer = "Cooking" }
function G.seedRecords(rows, confirmed)
	local out = {}
	for _, r in ipairs(rows or {}) do
		local sells
		if r.sells then
			sells = {}
			for _, item in ipairs(r.sells) do
				sells[item] = true
			end
		end
		out[#out + 1] = {
			id = r.id,
			name = r.name,
			map = r.map,
			x = r.x,
			y = r.y,
			place = r.place,
			sells = sells,
			-- role "trainer" (SkillupHelper_Custom) names its profession itself
			trains = ROLE_TRAINS[r.role] or (r.role == "trainer" and r.trains or nil),
			auction = r.role == "auction" or nil,
			seed = true,
			confidence = confirmed and confirmed[r.id] and "confirmed" or nil,
		}
	end
	return out
end

-- A step's identity, for "Stop guiding this step" (the same shape as View's card key).
function G.stepKey(step)
	if type(step) ~= "table" then
		return nil
	end
	return table.concat(
		{ tostring(step.kind), tostring(step.spell or step.item or step.from), tostring(step.source or "") },
		":"
	)
end

-- The value seen most often in a list (nil entries skipped; ties go to the one seen first), or nil.
function G.mostCommon(list)
	local n, best, bestN = {}, nil, 0
	for i = 1, #list do
		local v = list[i]
		if v ~= nil then
			n[v] = (n[v] or 0) + 1
			if n[v] > bestN then
				best, bestN = v, n[v]
			end
		end
	end
	return best
end

-- The Target button's macro. "/tm !1" puts the star on without toggling it off when it is already there (Blizzard's
-- own check, so no secret raid-target index is read here); solo only, since a group would see it too. The target is
-- not cleared first: a click from too far away keeps the player's target (the star may then land on it, as Blizzard's
-- /tm does for any target).
function G.macro(name, solo)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local m = "/targetexact " .. name
	if solo then
		m = m .. "\n/tm !1"
	end
	return m
end

local function role(s)
	local need = s.need or {}
	if need.kind == "trainer" then
		local prof = s.profession or need.profession or "Profession"
		local rank = G.rankTitle(s.rank)
		return rank and ("%s %s trainer"):format(rank, prof) or ("%s trainer"):format(prof)
	elseif need.kind == "auction" then
		return "Auctioneer"
	elseif need.kind == "quest" then
		return need.name and ("Quest: %s"):format(need.name) or "Quest giver"
	end
	return s.thing and ("Sells " .. s.thing) or "Vendor"
end

local function withPlace(text, place)
	return place and (text .. ", " .. place) or text
end

-- The chip's copy for a guide state. s = { phase, need, name, distance, place, thing (first item's name),
-- profession, compass (a word, when the facing is unknown and the arrow is hidden), marked (solo: the star goes on),
-- color (the step's), why, certain (false: a trainer that may not teach need.name), excluded (Guide.nearest's),
-- belowRank (its stats'), rank (the picked trainer's, Data/Trainers.lua) }.
-- Phases: Guide.phase's, plus "done", "unknown" (no NPC known) and "notnow" (no position).
-- Returns { l1, r1, l2, action, style ("quiet" | "primary"), icon ("arrow" | "star" | "dot"), tint, why }.
function G.describe(s)
	local p, need = s.phase, s.need or {}
	local d = { l1 = s.name, r1 = G.distanceText(s.distance) or "", why = s.why }
	local maybe = need.kind == "trainer" and need.name and s.certain == false
	if p == "far" or p == "near" or p == "arrived" or p == "away" then
		d.action, d.style, d.icon = "Target " .. tostring(s.name), "quiet", "arrow"
		d.tint = "bone"
		d.l2 = withPlace(role(s), s.place)
		if p == "near" or p == "arrived" then
			d.style, d.tint = "primary", s.color or "bone"
			d.l2 = p == "near" and "Close. Target them to see who it is" or "Right here. Target them to find them"
		else
			-- /targetexact finds a unit only about G.NEAR yards away: say so before the click
			d.action = d.action .. " (when in sight)"
			if p == "away" then
				d.icon = nil
				d.l2 = withPlace(role(s), s.place or "another continent")
			end
		end
		local notes = {}
		if maybe then
			d.l2 = ("May teach %s: not checked yet"):format(need.name)
			notes[#notes + 1] = d.l2
		end
		-- on the way there the place and how far it can be trusted matter most: that line wins over "may teach"
		local note = G.confidenceText(s.confidence, s.place)
		if note then
			notes[#notes + 1] = note
			if s.confidence == "nopos" then
				d.icon, d.l2 = nil, note
			elseif p == "far" or p == "away" then
				d.l2 = ("%s, %s"):format(s.place or role(s), G.TEXT.classic)
			end
		end
		if s.unsure and need.kind == "vendor" then
			notes[#notes + 1] = "Listed as a source, not confirmed as a vendor"
		end
		d.note = notes[1] and table.concat(notes, ". ") or nil
		if s.compass and d.icon then
			d.icon = nil
			d.r1 = d.r1 ~= "" and (d.r1 .. " " .. s.compass) or s.compass
		end
	elseif p == "targeted" then
		d.action, d.style, d.icon, d.tint = "Target " .. tostring(s.name), "quiet", "star", "green"
		d.l2 = s.marked and "Marked with a star. Right-click them to talk" or "Right-click them to talk"
	elseif p == "here" then
		d.l1, d.r1, d.icon, d.tint = "You are here", "", "dot", "green"
		if need.kind == "trainer" and need.name then
			d.l2 = maybe and ("Look for %s in the list"):format(need.name) or ("Learn %s here"):format(need.name)
		elseif need.kind == "trainer" then
			d.l2 = "Learn the next rank here"
		elseif need.kind == "auction" then
			d.l2 = "Buy the materials on the list"
		elseif need.kind == "quest" then
			d.l2 = ("Take or hand in %s"):format(need.name or "the quest")
		else
			d.l2 = ("Buy %s from this window"):format(s.thing or "the materials")
		end
	elseif p == "done" then
		d.l1 = need.kind == "trainer" and "Trained" or "All bought"
		d.r1, d.icon, d.tint = "", "dot", "green"
		d.l2 = ("Open %s to craft"):format(s.profession or "the profession")
	elseif p == "unknown" then
		d.r1 = ""
		if need.kind == "trainer" and need.name and (s.excluded or 0) > 0 then
			d.l1 = "No trainer found"
			d.l2 = ("None you've opened teaches %s"):format(need.name)
		elseif need.kind == "trainer" and (s.belowRank or 0) > 0 then
			local rank = G.needRank(need)
			local prof = s.profession or need.profession or "profession"
			d.l1 = rank and ("No %s trainer known"):format(rank) or "No trainer of that rank known"
			d.l2 = rank and ("%s needs %s %s trainer or better"):format(need.name or "This", G.aRank(rank), prof)
				or ("Ask a city guard for a higher %s trainer"):format(prof)
		elseif need.kind == "trainer" then
			d.l1 = "No known trainer yet"
			d.l2 = ("Ask a city guard for the %s trainer"):format(s.profession or need.profession or "profession")
		elseif need.kind == "auction" then
			d.l1, d.l2 = "No auction house known", "The nearest is in a capital city"
		elseif need.kind == "quest" then
			d.l1, d.l2 =
				"No quest giver known", ("The guide names none for %s on your side"):format(need.name or "this quest")
		else
			d.l1 = "No known vendor yet"
			d.l2 = ("Trade supplies vendors sell %s"):format(s.thing or "most materials")
		end
	elseif p == "notnow" then
		d.l1, d.r1, d.l2 = "No directions in here", "", "They come back when you leave"
	else
		return nil
	end
	return d
end

-- What a need is called after "Then:" on the strip's second line.
local function thenLabel(need, profession)
	if need.kind == "trainer" then
		return ("%s trainer"):format(profession or need.profession or "profession")
	elseif need.kind == "auction" then
		return "auction house"
	elseif need.kind == "quest" then
		return "quest giver"
	end
	return "vendor"
end

local STRIP_TIP = "Click: pin on the map. The guide chip stays with you when you close this window."

-- The guide strip on the Next card: the chip's state, shorter. s is Guide.describe's input plus
-- thenNeed (the second pending need, or nil) and instance (the "not now" is an instance). Returns
-- { a, ar, arTint, b, icon, tint, phase, tip } or nil when the strip is gone (no guide, the need is covered).
function G.strip(s)
	local p, need = s.phase, s.need or {}
	local d = G.describe(s)
	if not d or p == "done" then
		return nil
	end
	local name = tostring(s.name)
	local out = { phase = p, icon = d.icon, tint = d.tint, ar = d.r1 or "", arTint = "ash", tip = STRIP_TIP }
	if p == "far" then
		out.a = ("%s, %s"):format(name, s.place or role(s):lower())
	elseif p == "away" and s.confidence == "nopos" then
		out.a = s.place and ("%s, in %s, %s"):format(name, s.place, G.TEXT.nopos)
			or ("%s, %s"):format(name, G.TEXT.nopos)
		out.tip = "No position known for this NPC: nothing to pin on the map."
	elseif p == "away" then
		out.a = ("%s, %s"):format(name, s.place or "another continent")
	elseif p == "near" or p == "arrived" then
		out.a, out.arTint = name .. " is close", s.color or "bone"
	elseif p == "targeted" then
		out.a = s.marked and ("Right-click %s (the star)"):format(name) or ("Right-click %s"):format(name)
		out.arTint = "green"
	elseif p == "here" then
		out.a, out.ar = "You are here", ""
	elseif p == "unknown" then
		out.ar = ""
		local rank = need.kind == "trainer" and (s.belowRank or 0) > 0 and G.needRank(need)
		if need.kind == "trainer" and need.name and (s.excluded or 0) > 0 then
			out.a = ("No trainer you've opened teaches %s"):format(need.name)
		elseif rank then
			out.a = ("No %s %s trainer known"):format(rank, s.profession or need.profession or "profession")
		elseif need.kind == "trainer" then
			out.a = ("No known %s trainer yet"):format(s.profession or need.profession or "profession")
		elseif need.kind == "auction" then
			out.a = "No auction house known yet"
		elseif need.kind == "quest" then
			out.a = "No quest giver known for this quest"
		else
			out.a = ("No known vendor for %s yet"):format(s.thing or "these materials")
		end
		out.tip = G.unknownText(need, function()
			return s.thing or "these materials"
		end, s.excluded, s.belowRank)
	elseif p == "notnow" then
		out.a, out.ar = s.instance and "No directions inside an instance" or "No directions right now", ""
		out.tip = s.why and ("Not now: %s"):format(s.why) or nil
	else
		return nil
	end
	if
		(p == "far" or p == "near" or p == "arrived")
		and need.kind == "trainer"
		and need.name
		and s.certain == false
	then
		out.b = ("May teach %s: not checked yet"):format(need.name)
	end
	if (p == "far" or p == "away") and s.confidence == "classic" then
		local c = G.confidenceText("classic")
		out.b = out.b and (out.b .. ". " .. c) or c
	end
	if s.thenNeed then
		local t = "Then: " .. thenLabel(s.thenNeed, s.profession)
		out.b = out.b and (out.b .. ". " .. t) or t
	end
	return out
end

return G
