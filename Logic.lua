-- Pure logic: skill-up colours and chances, crafts possible from stock, the plan's next step. No frames, no client
-- calls except through the functions passed in, so busted tests it whole.
local _, ns = ...
local L = {}
ns.Logic = L

-- Enum.TradeskillRelativeDifficulty: Optimal = 0, Medium = 1, Easy = 2, Trivial = 3.
local DIFFICULTY_COLOR = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "grey" }
L.COLOR_RANK = { orange = 1, yellow = 2, green = 3, grey = 4 }
-- Chance by colour when no thresholds are known (mid-band guesses; marked "~" in the panel).
local COLOR_CHANCE = { orange = 1, yellow = 0.75, green = 0.25, grey = 0 }

function L.colorOf(skill, yellow, grey)
	if skill < yellow then
		return "orange"
	elseif skill >= grey then
		return "grey"
	elseif skill < math.floor((yellow + grey) / 2) then
		return "yellow"
	end
	return "green"
end

function L.colorOfDifficulty(difficulty)
	return DIFFICULTY_COLOR[difficulty]
end

-- Skill-up chance per craft (the vanilla-client formula; an assumption for Forever, as in tools/tsm/skillup.py).
function L.chance(skill, yellow, grey)
	if skill < yellow then
		return 1
	elseif skill >= grey or grey <= yellow then
		return 0
	end
	return (grey - skill) / (grey - yellow)
end

-- Expected skill points from `crafts` crafts starting at `skill`, the chance falling as the skill rises.
-- thresholds = { yellow, grey, skillups } or nil (then the colour guess, constant).
function L.expectedPoints(skill, crafts, thresholds, color)
	if crafts == math.huge then
		return nil
	end
	local s = skill
	for _ = 1, crafts do
		local p
		if thresholds then
			p = L.chance(math.floor(s), thresholds[1], thresholds[2]) * (thresholds[3] or 1)
		else
			p = COLOR_CHANCE[color] or 0
		end
		if p <= 0 then
			break
		end
		s = s + p
	end
	return s - skill
end

-- How many times a recipe can be crafted from stock. reagents = { { item = id, count = n }, ... };
-- have(item) -> count in bags+bank; vendor[item] -> copper when a vendor sells it (counted as unlimited).
-- Returns crafts (math.huge when every reagent is vendor-sold), the limiting item, and for those crafts
-- the vendor reagents still to buy: { { item, need } }.
function L.craftsPossible(reagents, have, vendor)
	local n, limiting = math.huge, nil
	for _, r in ipairs(reagents) do
		if r.count > 0 and not vendor[r.item] then
			local k = math.floor(have(r.item) / r.count)
			if k < n then
				n, limiting = k, r.item
			end
		end
	end
	local toBuy = {}
	if n > 0 and n ~= math.huge then
		for _, r in ipairs(reagents) do
			if vendor[r.item] then
				local need = r.count * n - have(r.item)
				if need > 0 then
					toBuy[#toBuy + 1] = { item = r.item, need = need }
				end
			end
		end
	end
	return n, limiting, toBuy
end

-- The from-stock list: recipes that give skill now and can be crafted at least once without buying from
-- the auction house. recipes = { { id, name, learned, difficulty, thresholds, reagents }, ... }.
function L.fromStock(recipes, skill, have, vendor)
	local out = {}
	for _, r in ipairs(recipes) do
		if r.learned and r.reagents and #r.reagents > 0 then
			local color = r.thresholds and L.colorOf(skill, r.thresholds[1], r.thresholds[2])
				or L.colorOfDifficulty(r.difficulty)
			-- the client's own colour wins when it gives one: it knows the real thresholds
			local clientColor = L.colorOfDifficulty(r.difficulty)
			if clientColor then
				color = clientColor
			end
			if color and color ~= "grey" then
				local crafts, limiting, toBuy = L.craftsPossible(r.reagents, have, vendor)
				if crafts > 0 then
					out[#out + 1] = {
						id = r.id,
						name = r.name,
						color = color,
						crafts = crafts,
						limiting = limiting,
						toBuy = toBuy,
						points = L.expectedPoints(skill, crafts, r.thresholds, color),
						guessed = r.thresholds == nil,
					}
				end
			end
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = L.COLOR_RANK[a.color], L.COLOR_RANK[b.color]
		if ra ~= rb then
			return ra < rb
		end
		local pa, pb = a.points or math.huge, b.points or math.huge
		if pa ~= pb then
			return pa > pb
		end
		return a.name < b.name
	end)
	return out
end

-- The plan's step at `skill` and the one after it. Returns step, nextStep, state:
-- "ok", "below" (skill under the plan's start), "done" (at or over its end), "none" (no plan for this profession).
function L.planStep(prof, skill)
	if not prof or not prof.rows then
		return nil, nil, "none"
	end
	if skill < (prof.from or 0) then
		return nil, nil, "below"
	end
	if skill >= (prof.to or 0) then
		return nil, nil, "done"
	end
	for i, row in ipairs(prof.rows) do
		if skill >= row.from and skill < row.to then
			return row, prof.rows[i + 1], "ok"
		end
	end
	return nil, nil, "none"
end

-- What is still to buy for the rest of a step: the materials of the remaining crafts minus stock.
-- Crafts left scale with the share of the step's skill range still ahead.
function L.stepShopping(row, skill, have)
	if not row or not row.mats then
		return {}, 0
	end
	local span = row.to - row.from
	local left = span > 0 and (row.to - skill) / span or 1
	local crafts = math.ceil((row.crafts or 0) * left - 1e-9)
	local out = {}
	for _, m in ipairs(row.mats) do
		local need = math.ceil(m.count * left - 1e-9)
		local got = have(m.item)
		out[#out + 1] = { item = m.item, name = m.name, need = need, have = got, short = math.max(0, need - got) }
	end
	return out, crafts
end

-- Recipe items the plan buys that are not learned yet. isLearned(spell) -> bool or nil (unknown).
function L.recipesToBuy(prof, skill, isLearned)
	local out = {}
	for _, b in ipairs(prof and prof.buyRecipes or {}) do
		if isLearned(b.spell) ~= true and (b.to or math.huge) > skill then
			out[#out + 1] = {
				item = b.item,
				itemName = b.itemName,
				recipe = b.recipe,
				price = b.price,
				learnRank = b.learnRank,
				from = b.from,
				to = b.to,
				learnable = (b.learnRank or 0) <= skill,
			}
		end
	end
	return out
end

-- Copper as "1g 2s 3c" (gold and silver only when present).
function L.money(c)
	if not c then
		return "-"
	end
	local neg = c < 0
	c = math.floor(math.abs(c) + 0.5)
	local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	local parts = {}
	if g > 0 then
		parts[#parts + 1] = g .. "g"
	end
	if s > 0 or g > 0 then
		parts[#parts + 1] = s .. "s"
	end
	parts[#parts + 1] = cc .. "c"
	return (neg and "-" or "") .. table.concat(parts, " ")
end

-- The plan's profession entry for a profession the client names: by skill line id, then parent id, then name.
function L.findProfession(plan, info)
	if not plan or not plan.professions or not info then
		return nil
	end
	local p = plan.professions[info.professionID] or plan.professions[info.parentProfessionID or -1]
	if p then
		return p
	end
	local names = { info.professionName, info.parentProfessionName }
	for _, prof in pairs(plan.professions) do
		for _, n in pairs(names) do
			if type(n) == "string" and prof.name and n:lower() == prof.name:lower() then
				return prof
			end
		end
	end
	return nil
end
