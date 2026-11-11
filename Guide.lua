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

-- What the step to do now needs a visit for, in the order to go: a list of
-- { kind = "vendor", items = { { item, count } } } | { kind = "trainer", profession = name }
-- | { kind = "auction", items = {...} }. Empty when the step needs nothing from an NPC.
function G.needsOf(step, profession)
	local out = {}
	if type(step) ~= "table" then
		return out
	end
	if step.kind == "train" then
		out[1] = { kind = "trainer", profession = profession, name = step.name, at = step.at }
		return out
	elseif step.kind == "buyRecipe" then
		out[1] = { kind = "auction", items = { { item = step.item, count = 1 } } }
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
		local open = n.kind == "trainer"
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

-- How well an NPC serves a need: the number of the need's items it sells (vendor), 1 when it trains the profession
-- or is an auctioneer, 0 when it does not serve it.
function G.serves(npc, need)
	if need.kind == "vendor" then
		local n = 0
		for _, it in ipairs(need.items) do
			if npc.sells and npc.sells[it.item] then
				n = n + 1
			end
		end
		return n
	elseif need.kind == "trainer" then
		local p = need.profession
		local t = npc.trains
		if type(p) == "string" and type(t) == "string" and (p:find(t, 1, true) or t:find(p, 1, true)) then
			return 1
		end
		return 0
	elseif need.kind == "auction" then
		return npc.auction and 1 or 0
	end
	return 0
end

-- Every known NPC, learned over seeded (same id).
function G.known(seeds, learned)
	local byId, out = {}, {}
	for id, npc in pairs(learned or {}) do
		byId[id] = npc
	end
	for _, npc in ipairs(seeds or {}) do
		if not byId[npc.id] then
			byId[npc.id] = npc
		end
	end
	for _, npc in pairs(byId) do
		out[#out + 1] = npc
	end
	return out
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

-- The nearest NPC serving `need`. here = { continent, x, y } (world yards) or nil when the position is unknown.
-- world(map, x, y) -> continent, wx, wy or nil. Picks the best server first (a vendor selling every item beats one
-- selling some), then the shortest distance on the player's continent; other continents last, without a distance.
-- Returns { npc, distance, bearing, wx, wy, continent, sameContinent, partial } or nil, and how many serve it.
function G.nearest(npcs, need, here, world)
	local best, bestKey, servers = nil, nil, 0
	local want = need.kind == "vendor" and #need.items or 1
	for _, npc in ipairs(npcs) do
		local s = G.serves(npc, need)
		if s > 0 then
			servers = servers + 1
			local cont, wx, wy = world(npc.map, npc.x, npc.y)
			local dist, same = nil, false
			if here and cont and cont == here.continent then
				same = true
				local dx, dy = wx - here.x, wy - here.y
				dist = math.sqrt(dx * dx + dy * dy)
			end
			-- lower is better: missing items, then other continent, then distance
			local key = (want - s) * 1e9 + (same and 0 or 1e8) + (dist or 0)
			-- ids are numbers, or "name:<Name>" for an NPC learned without a readable GUID: compare as strings
			if not bestKey or key < bestKey or (key == bestKey and tostring(npc.id) < tostring(best.npc.id)) then
				bestKey = key
				best = {
					npc = npc,
					distance = dist,
					wx = wx,
					wy = wy,
					continent = cont,
					sameContinent = same,
					partial = s < want,
				}
				if same then
					best.bearing = G.bearing(here.x, here.y, wx, wy)
				end
			end
		end
	end
	return best, servers
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

-- The honest line when no NPC is known for a need.
function G.unknownText(need, nameOf)
	if need.kind == "trainer" then
		return ("No %s trainer known yet. Guards in any city point the way; I note trainers you open."):format(
			need.profession or "profession"
		)
	elseif need.kind == "auction" then
		return "No auctioneer known yet. Every capital has one; I note the ones you open."
	end
	return ("No known vendor for %s yet. Trade Supplies vendors carry most of it; I note vendors you open."):format(
		G.needLabel(need, nameOf)
	)
end

-- Merges what a window just showed into the learned records. rec = { id, name, map, x, y, sells (list of item ids),
-- trains, auction }. Keeps what an earlier visit learned that this one cannot see (a trainer that also sells).
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
	npc.trains = rec.trains or npc.trains
	npc.auction = rec.auction or npc.auction
	npc.seen = now
	learned[rec.id] = npc
	return npc
end

-- Turns Data/Npcs.lua's rows ({ ..., role, sells = { ids } }) into NPC records.
local ROLE_TRAINS = { lwtrainer = "Leatherworking", cooktrainer = "Cooking" }
function G.seedRecords(rows)
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
			trains = ROLE_TRAINS[r.role],
			auction = r.role == "auction" or nil,
			seed = true,
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
-- cleared first so a /targetexact that finds nobody leaves nothing for the star to land on.
function G.macro(name, solo)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local m = "/cleartarget\n/targetexact " .. name
	if solo then
		m = m .. "\n/tm !1"
	end
	return m
end

local function role(s)
	local need = s.need or {}
	if need.kind == "trainer" then
		return ("%s trainer"):format(s.profession or need.profession or "Profession")
	elseif need.kind == "auction" then
		return "Auctioneer"
	end
	return s.thing and ("Sells " .. s.thing) or "Vendor"
end

local function withPlace(text, place)
	return place and (text .. ", " .. place) or text
end

-- The chip's copy for a guide state. s = { phase, need, name, distance, place, thing (first item's name),
-- profession, compass (a word, when the facing is unknown and the arrow is hidden), marked (solo: the star goes on),
-- color (the step's), why }. Phases: Guide.phase's, plus "done", "unknown" (no NPC known) and "notnow" (no position).
-- Returns { l1, r1, l2, action, style ("quiet" | "primary"), icon ("arrow" | "star" | "dot"), tint, why }.
function G.describe(s)
	local p, need = s.phase, s.need or {}
	local d = { l1 = s.name, r1 = G.distanceText(s.distance) or "", why = s.why }
	if p == "far" or p == "near" or p == "arrived" or p == "away" then
		d.action, d.style, d.icon = "Target " .. tostring(s.name), "quiet", "arrow"
		d.tint = "bone"
		d.l2 = withPlace(role(s), s.place)
		if p == "near" or p == "arrived" then
			d.style, d.tint = "primary", s.color or "bone"
			d.l2 = p == "near" and "Close. Target them to see who it is" or "Right here. Target them to find them"
		elseif p == "away" then
			d.icon = nil
			d.l2 = withPlace(role(s), s.place or "another continent")
		end
		if s.compass and d.icon then
			d.icon = nil
			d.r1 = d.r1 ~= "" and (d.r1 .. " " .. s.compass) or s.compass
		end
	elseif p == "targeted" then
		d.action, d.style, d.icon, d.tint = "Target " .. tostring(s.name), "quiet", "star", "green"
		d.l2 = s.marked and "Marked with a star. Right-click them to talk" or "Right-click them to talk"
	elseif p == "here" then
		d.l1, d.r1, d.icon, d.tint = "You are here", "", "dot", "green"
		if need.kind == "trainer" then
			d.l2 = "Learn the next rank here"
		elseif need.kind == "auction" then
			d.l2 = "Buy the materials on the list"
		else
			d.l2 = ("Buy %s from this window"):format(s.thing or "the materials")
		end
	elseif p == "done" then
		d.l1 = need.kind == "trainer" and "Trained" or "All bought"
		d.r1, d.icon, d.tint = "", "dot", "green"
		d.l2 = ("Open %s to craft"):format(s.profession or "the profession")
	elseif p == "unknown" then
		d.r1 = ""
		if need.kind == "trainer" then
			d.l1 = "No known trainer yet"
			d.l2 = ("Ask a city guard for the %s trainer"):format(s.profession or need.profession or "profession")
		elseif need.kind == "auction" then
			d.l1, d.l2 = "No auction house known", "The nearest is in a capital city"
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

return G
