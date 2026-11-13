-- Reads the open profession window through C_TradeSkillUI and the bag+bank counts through C_Item, and builds the
-- panel's model with ns.Logic. Each step that can fail says where (Fail at the Broken Link): the result's `why`.
local _, ns = ...
local S = {}
ns.Scan = S

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

-- The open profession: the info that carries a skill (Forever fills the base profession; Mainline the child).
function S.professionInfo()
	local TS = C_TradeSkillUI
	local base = TS.GetBaseProfessionInfo and TS.GetBaseProfessionInfo()
	local child = TS.GetChildProfessionInfo and TS.GetChildProfessionInfo()
	local pick
	-- not ipairs: a nil child would end the list before the base
	for k = 1, 2 do
		local info = k == 1 and child or base
		if type(info) == "table" and (info.maxSkillLevel or 0) > 0 and not secret(info.skillLevel) then
			pick = pick or info
		end
	end
	return pick, base, child
end

function S.isOwnWindow()
	local TS = C_TradeSkillUI
	if TS.IsTradeSkillLinked and TS.IsTradeSkillLinked() then
		return false, "a linked profession (someone else's)"
	end
	if TS.IsTradeSkillGuild and TS.IsTradeSkillGuild() then
		return false, "a guild profession list"
	end
	if TS.IsNPCCrafting and TS.IsNPCCrafting() then
		return false, "NPC crafting"
	end
	return true
end

local function recipeIDs()
	local TS = C_TradeSkillUI
	local ids = TS.GetAllRecipeIDs and TS.GetAllRecipeIDs()
	if type(ids) == "table" and #ids > 0 then
		return ids, "GetAllRecipeIDs"
	end
	ids = TS.GetFilteredRecipeIDs and TS.GetFilteredRecipeIDs()
	return type(ids) == "table" and ids or {}, "GetFilteredRecipeIDs"
end

-- Basic reagents of a recipe from its schematic (optional and finishing slots left out), then the item it makes and
-- how many (nil, nil for a recipe with no item output: an enchant, a buff).
function S.reagents(recipeID)
	local schem = C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
	if type(schem) ~= "table" or type(schem.reagentSlotSchematics) ~= "table" then
		return nil
	end
	local out = {}
	for _, slot in ipairs(schem.reagentSlotSchematics) do
		local first = slot.reagents and slot.reagents[1]
		if first and first.itemID and slot.required ~= false and (slot.quantityRequired or 0) > 0 then
			out[#out + 1] = { item = first.itemID, count = slot.quantityRequired }
		end
	end
	local makes = clean(schem.outputItemID)
	if type(makes) ~= "number" or makes <= 0 then
		makes = nil
	end
	local n = clean(schem.quantityMin)
	return out, makes, makes and (type(n) == "number" and n > 0 and n or 1) or nil
end

-- Learned recipes the export does not list (a pattern bought after the export, a profession it never covered) --------
-- The client gives a learned recipe's grey (maxTrivialLevel), its skill-ups and its colour at the current skill, but
-- not where it turns yellow. That threshold starts at grey - LIVE_SPAN (the export's most common span) and is narrowed
-- by every colour the client showed for it (SkillupHelperDB.colorSeen: the highest skill seen orange, the lowest
-- seen yellow or green), so the estimate sharpens as the skill climbs. The planner's client-colour check
-- (Planner.prepare) corrects the current colour on top.
S.LIVE_SPAN = 25

-- Records the colour the client shows for spell at skill into seen ({ o = highest orange, y = lowest yellow or
-- green }). Returns true when the record changed.
function S.noteColor(seen, spell, skill, difficulty)
	if not seen or type(skill) ~= "number" then
		return false
	end
	local color = ns.Logic.colorOfDifficulty(difficulty)
	local e = seen[spell]
	if color == "orange" then
		if not e or not e.o or skill > e.o then
			e = e or {}
			e.o = skill
			seen[spell] = e
			return true
		end
	elseif color == "yellow" or color == "green" then
		if not e or not e.y or skill < e.y then
			e = e or {}
			e.y = skill
			seen[spell] = e
			return true
		end
	end
	return false
end

-- The yellow threshold of a recipe whose grey is g, from the colours seen (nil = none seen).
function S.yellowOf(g, seen)
	local y = g - S.LIVE_SPAN
	if seen and seen.o and y <= seen.o then
		y = seen.o + 1
	end
	if seen and seen.y and y > seen.y then
		y = seen.y
	end
	return math.min(y, g)
end

-- A planner entry (Data/Plan.lua's recipe shape) for a learned recipe from what the client says, or nil and why.
-- r = { id, name, grey, skillUps, reagents, makes, n }.
function S.liveEntry(r, seen)
	local g = r.grey
	if type(g) ~= "number" or g <= 0 then
		return nil, "no grey level (maxTrivialLevel)"
	end
	if not r.reagents then
		return nil, "no schematic"
	end
	if #r.reagents == 0 then
		-- only optional or finishing slots: priced at nothing it would look free
		return nil, "no basic reagents"
	end
	local mats = {}
	for _, m in ipairs(r.reagents) do
		mats[#mats + 1] = m.item
		mats[#mats + 1] = m.count
	end
	local k = tonumber(r.skillUps)
	return {
		y = S.yellowOf(g, seen),
		g = g,
		k = (k and k > 0) and k or 1,
		name = r.name,
		mats = mats,
		makes = r.makes,
		n = r.makes and (r.n or 1) or nil,
		src = "known",
		live = true,
	}
end

-- The profession entry the planner runs on: the export's (prof, may be nil) with every learned recipe it does not
-- list added from the client (live[spell] = entry). Returns nil when neither has a recipe. The export is never
-- changed: a copy carries the additions.
function S.mergeProf(prof, live, info)
	if not prof and not next(live) then
		return nil
	end
	local out = {}
	for k, v in pairs(prof or {}) do
		out[k] = v
	end
	local recipes = {}
	for spell, r in pairs(prof and prof.recipes or {}) do
		recipes[spell] = r
	end
	local added = 0
	for spell, r in pairs(live) do
		if not recipes[spell] then
			recipes[spell] = r
			added = added + 1
		end
	end
	out.recipes = recipes
	-- the planner caches by name: a profession without one keys by its id, never a shared "?"
	local pname = info and clean(info.professionName)
	out.name = out.name
		or (type(pname) == "string" and pname)
		or ("profession " .. tostring(info and clean(info.professionID)))
	out.liveAdded = added
	return out
end

-- Bag+bank count; the bank's part is the client's cache, so it holds while the bank is closed.
function S.have(item)
	return C_Item.GetItemCount(item, true) or 0
end

function S.itemName(item, fallback)
	local n = C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)
	if type(n) == "string" and not secret(n) then
		return n
	end
	return fallback or ("item " .. item)
end

-- Live prices are cached per profession for PRICE_TTL seconds; the planner's pass 1 until skill, cap, learned
-- recipes, prices or the effort setting change. Bag updates rerun only passes 2 to 4.
S.PRICE_TTL = 300
local priceCache, baseCache = {}, {}

function S.resetCaches()
	priceCache, baseCache = {}, {}
end

local function clock()
	return debugprofilestop and debugprofilestop() or os.clock() * 1000
end

-- Cache-key text of the ranks array (input.ranks) and of the exclude table (input.exclude).
function S.ranksKey(ranks)
	local parts = {}
	for _, r in ipairs(ranks or {}) do
		parts[#parts + 1] = table.concat({
			tostring(r.cap),
			tostring(r.skill),
			tostring(r.level),
			tostring(r.cost),
			tostring(r.where),
		}, "/")
	end
	return table.concat(parts, ",")
end

function S.excludeKey(exclude)
	exclude = exclude or {}
	local spells = {}
	for spell, on in pairs(exclude.notNow or {}) do
		if on then
			spells[#spells + 1] = tostring(spell)
		end
	end
	table.sort(spells)
	local allowed = {}
	for spell, on in pairs(exclude.allow or {}) do
		if on then
			allowed[#allowed + 1] = tostring(spell)
		end
	end
	table.sort(allowed)
	local key = ("%s/%s/%s/%s"):format(
		tostring(exclude.dungeon == true),
		tostring(exclude.ahPatterns == true),
		-- special teachers are excluded unless set to false
		tostring(exclude.special ~= false),
		table.concat(spells, ",")
	)
	-- gated recipes the user chose to use ("Use it" on a shortcut)
	return #allowed > 0 and (key .. "/+" .. table.concat(allowed, ",")) or key
end

-- Cache-key text of input.trainerSeen ({ [spellID or lowercased name] = true }), "-" when nil.
function S.seenKey(seen)
	if not seen then
		return "-"
	end
	local keys = {}
	for k, on in pairs(seen) do
		if on then
			keys[#keys + 1] = tostring(k)
		end
	end
	table.sort(keys)
	return table.concat(keys, ",")
end

-- The skill the plan aims for: the highest saved rank cap, else Data/Plan.lua's `to`, else the live cap; never
-- below the live cap (a stale rank or an old export must not shorten the plan the client allows).
function S.target(ranks, prof, cap)
	local t
	for _, r in ipairs(ranks or {}) do
		if r.cap and (not t or r.cap > t) then
			t = r.cap
		end
	end
	t = t or (prof and tonumber(prof.to)) or cap
	if cap and (not t or cap > t) then
		t = cap
	end
	return t
end

-- Runs the planner for one profession entry of a v2 Data/Plan.lua. learned[spell] = true, difficulty[spell] = the
-- client's relativeDifficulty. Returns the plan (steps, hold, leftovers, fromStock) plus price diagnostics.
-- caps (optional) = { target, level, ranks, exclude } for the cap model: target defaults to cap (the live cap).
function S.runPlanner(plan, prof, skill, cap, learned, difficulty, settings, caps)
	settings = settings or {}
	caps = caps or {}
	local target = caps.target or cap
	local ranks = caps.ranks or {}
	local exclude = caps.exclude or {}
	local t0 = clock()
	local now = GetTime and GetTime() or 0
	-- caches are per profession name: the entry the scan passes is a fresh merge of the export and the client
	local cacheKey = prof.name or "?"
	-- the recipes the plan may use, with the client-built ones' thresholds: a recipe learned (or a threshold the
	-- client narrowed) since the last run prices its reagents and replans
	local recipeKey = {}
	for spell, r in pairs(prof.recipes or {}) do
		recipeKey[#recipeKey + 1] = r.live and (spell .. "~" .. tostring(r.y) .. "-" .. tostring(r.g))
			or tostring(spell)
	end
	table.sort(recipeKey)
	recipeKey = table.concat(recipeKey, ",")
	local pc = priceCache[cacheKey]
	-- salvage values depend on the sell-share setting: a changed share refetches like an expired entry
	if
		not pc
		or now - pc.at > S.PRICE_TTL
		or now < pc.at
		or pc.sellShare ~= settings.sellShare
		or pc.recipeKey ~= recipeKey
	then
		local price, product, counts = ns.TSM.prices(plan, prof, nil, settings.sellShare)
		pc = { at = now, price = price, product = product, counts = counts, stamp = (pc and pc.stamp or 0) + 1 }
		pc.sellShare = settings.sellShare
		pc.recipeKey = recipeKey
		priceCache[cacheKey] = pc
	end
	local effort = settings.effort or (plan and plan.effort) or ns.Planner.EFFORT
	local nLearned, learnedKey = 0, {}
	for spell in pairs(learned) do
		nLearned = nLearned + 1
		learnedKey[#learnedKey + 1] = spell
	end
	table.sort(learnedKey)
	local noRecipeBuys = settings.noRecipeBuys == true
	local luck = settings.luck or ns.Planner.LUCK
	local key = table.concat({
		skill,
		cap,
		pc.stamp,
		effort,
		tostring(noRecipeBuys),
		luck,
		nLearned,
		table.concat(learnedKey, ","),
		target,
		tostring(caps.level),
		S.ranksKey(ranks),
		S.excludeKey(exclude),
		S.seenKey(caps.trainerSeen),
		recipeKey,
	}, ":")
	local bc = baseCache[cacheKey]
	if not bc or bc.key ~= key then
		local ctx = ns.Planner.prepare({
			skill = skill,
			cap = cap,
			target = target,
			level = caps.level,
			ranks = ranks,
			exclude = exclude,
			trainerSeen = caps.trainerSeen,
			recipes = prof.recipes,
			items = plan and plan.items or {},
			learned = learned,
			difficulty = difficulty,
			price = pc.price,
			product = pc.product,
			effort = effort,
			noRecipeBuys = noRecipeBuys,
			luck = luck,
		})
		bc = { key = key, ctx = ctx, baseline = ns.Planner.baseline(ctx) }
		baseCache[cacheKey] = bc
	end
	local have, haveKey = {}, {}
	for item in pairs(pc.price) do
		local n = S.have(item)
		if n > 0 then
			have[item] = n
			haveKey[#haveKey + 1] = item .. "=" .. n
		end
	end
	table.sort(haveKey)
	-- the AH trip list the user keeps for this profession: its steps are committed until their target is reached
	-- (planner rule 3); a list saved before 0.2.6 has only route and to
	local saved = settings.trips and settings.trips[prof.name]
	local commit
	if saved and skill < (saved.to or 0) then
		commit = {}
		for _, cm in ipairs(saved.commit or {}) do
			if skill < (cm.to or 0) then
				commit[#commit + 1] = { spell = cm.spell, to = cm.to }
			end
		end
		if not saved.commit then
			for _, spell in ipairs(saved.route or {}) do
				commit[#commit + 1] = { spell = spell, to = saved.to }
			end
		end
	end
	local commitKey = {}
	for _, cm in ipairs(commit or {}) do
		commitKey[#commitKey + 1] = tostring(cm.spell) .. ":" .. tostring(cm.to)
	end
	local gold = GetMoney and GetMoney() or nil
	-- the stock run also reruns on a changed trip list or a whole gold more or less (the trip's gold cut)
	haveKey = table.concat({
		table.concat(haveKey, ","),
		commit and table.concat(commitKey, ",") or "-",
		tostring(math.floor((gold or 0) / 10000)),
	}, "|")
	-- BAG_UPDATE_DELAYED fires for every bag change, most of them not in a reagent: same counts, same plan
	S.stockRuns = S.stockRuns or 0
	if bc.haveKey ~= haveKey or not bc.result then
		bc.haveKey, bc.result = haveKey, ns.Planner.finish(bc.ctx, bc.baseline, have, { commit = commit, gold = gold })
		bc.ms = clock() - t0
		S.stockRuns = S.stockRuns + 1
	end
	-- a shallow copy per build, so the per-build fields below never write into the cached plan
	local result = {}
	for k, v in pairs(bc.result) do
		result[k] = v
	end
	result.ms = bc.ms -- what the planner cost when it last ran, not the cache lookup
	result.prices = pc.counts
	result.ageHours = ns.TSM.ageHours(plan)
	result.profKey = prof.name
	-- recipes planned from the client alone (no export row): their yellow threshold is an estimate
	result.liveRecipes = prof.liveAdded
	return result
end

-- The model the panel shows, or { why = "..." } naming the link that broke or why not now.
function S.build(plan)
	local own, notOwn = S.isOwnWindow()
	if not own then
		return { why = "not your own profession window: " .. notOwn, state = "not now" }
	end
	local info, base, child = S.professionInfo()
	local diag = {
		base = base and { id = base.professionID, name = base.professionName, skill = base.skillLevel } or nil,
		child = child and { id = child.professionID, name = child.professionName, skill = child.skillLevel } or nil,
	}
	if not info then
		return { why = "C_TradeSkillUI gave no profession with a skill (base and child info empty)", diag = diag }
	end
	local skill = info.skillLevel
	local prof = ns.Logic.findProfession(plan, info) or ns.Logic.findProfession(plan, base)
	local thresholds = prof and prof.recipes or {}
	local vendor = plan and plan.vendor or {}
	local ids, idSource = recipeIDs()
	local recipes = {}
	local counts = {
		ids = #ids,
		learned = 0,
		secret = 0,
		noSchematic = 0,
		clientColor = 0,
		dataThresholds = 0,
		-- learned recipes the export does not list, planned from the client; and those it could not plan, by reason
		live = 0,
		liveSkipped = {},
	}
	local learned, difficulties, greyCheck = {}, {}, {}
	local live = {}
	local colorSeen = ns.savedColorSeen and ns.savedColorSeen() or nil
	for _, id in ipairs(ids) do
		local r = C_TradeSkillUI.GetRecipeInfo(id)
		if type(r) == "table" then
			if secret(r.name) or secret(r.learned) then
				counts.secret = counts.secret + 1
			elseif r.learned then
				counts.learned = counts.learned + 1
				learned[id] = true
				local reagents, makes, makesN = S.reagents(id)
				if not reagents then
					counts.noSchematic = counts.noSchematic + 1
				end
				local difficulty = r.relativeDifficulty
				if r.canSkillUp == false then
					difficulty = 3
				end
				if difficulty ~= nil then
					counts.clientColor = counts.clientColor + 1
					difficulties[id] = difficulty
				end
				local th = ns.Logic.thresholds(thresholds[id])
				if not thresholds[id] then
					-- not in the export: plan it from the client, its colours narrowing the yellow threshold
					S.noteColor(colorSeen, id, skill, difficulty)
					local entry, skipWhy = S.liveEntry({
						name = r.name,
						grey = clean(r.maxTrivialLevel),
						skillUps = clean(r.numSkillUps),
						reagents = reagents,
						makes = makes,
						n = makesN,
					}, colorSeen and colorSeen[id])
					if entry then
						live[id] = entry
						counts.live = counts.live + 1
						th = { entry.y, entry.g, entry.k }
					else
						counts.liveSkipped[skipWhy] = (counts.liveSkipped[skipWhy] or 0) + 1
					end
				end
				if th and thresholds[id] then
					counts.dataThresholds = counts.dataThresholds + 1
					-- the client's grey (maxTrivialLevel) next to the export's, for a few recipes (selftest)
					if #greyCheck < 5 and not secret(r.maxTrivialLevel) then
						greyCheck[#greyCheck + 1] = { spell = id, client = r.maxTrivialLevel, plan = th[2] }
					end
				end
				recipes[#recipes + 1] = {
					id = id,
					name = r.name,
					learned = true,
					difficulty = difficulty,
					thresholds = th,
					reagents = reagents,
				}
			end
		end
	end
	local model = {
		profession = info.professionName,
		professionID = info.professionID,
		skill = skill,
		maxSkill = info.maxSkillLevel,
		idSource = idSource,
		counts = counts,
		diag = diag,
		plan = prof,
		generatedAt = plan and plan.generatedAt,
		fromStock = ns.Logic.fromStock(recipes, skill, S.have, vendor),
		greyCheck = greyCheck,
	}
	-- the cap model: ranks learned at the trainer (SkillupHelperDB.ranks), the character level and the exclusions
	local settings = ns.settings and ns.settings() or {}
	local function lookup(fn)
		return fn and (fn(info.professionID) or (base and fn(base.professionID)) or fn(info.parentProfessionID)) or nil
	end
	local ranks = S.ranksArray(lookup(ns.savedRanks))
	-- recipes seen in this profession's trainer list (nil when no trainer was ever read)
	local trainerSeen = lookup(ns.savedTrainerSeen)
	local level = UnitLevel and clean(UnitLevel("player")) or nil
	local target = S.target(ranks, prof, info.maxSkillLevel)
	model.target, model.ranks = target, ranks
	-- the planner runs on the export's recipes plus every learned recipe it does not list, read from the client: a
	-- pattern learned since the export, or a profession the export never covered (First Aid, Tailoring...), plans too
	local v1 = prof and not ns.Logic.isPlanV2(plan, prof)
	local merged = not v1 and S.mergeProf(prof, live, info) or nil
	if merged and target and target > skill then
		local ok, result =
			pcall(S.runPlanner, plan, merged, skill, info.maxSkillLevel, learned, difficulties, settings, {
				target = target,
				level = level,
				ranks = ranks,
				exclude = settings.exclude,
				trainerSeen = trainerSeen,
			})
		if ok then
			model.planner = result
		else
			model.plannerWhy = "planner failed: " .. tostring(result)
		end
	elseif v1 then
		model.plannerWhy =
			"Data/Plan.lua is version 1 (no recipe reagents): the price plan needs regenerating on the PC, then /reload"
	end
	if prof then
		model.step, model.nextStep, model.planState = ns.Logic.planStep(prof, skill)
		model.shopping, model.craftsLeft = ns.Logic.stepShopping(model.step, skill, S.have)
		model.buyRecipes = ns.Logic.recipesToBuy(prof, skill, function(spell)
			return learned[spell] or false
		end)
	elseif model.planner then
		-- no export for this profession: planned from the client's recipes and TSM's live prices alone, nothing broken
		model.planner.clientOnly = true
	elseif merged and ns.View and ns.View.atCapLine(model) then
		-- planned from the client, at the live cap: not now, nothing broken
		model.planWhy = ns.View.atCapLine(model)
	elseif not plan then
		model.planWhy = "Data/Plan.lua absent: the price plan was not generated for this copy of the addon"
	else
		model.planWhy = ("Data/Plan.lua has no plan for %s (id %s)"):format(
			tostring(info.professionName),
			tostring(info.professionID)
		)
	end
	if #ids == 0 then
		model.why = "C_TradeSkillUI listed no recipes (" .. idSource .. ")"
	end
	return model
end

-- Profession ranks, learned at the trainer -----------------------------------------------------------------------
-- Forever has no rank table: nothing in the client data or UI code holds 75/150/225/300, so the ranks are read live
-- at a profession trainer and kept in SkillupHelperDB.ranks[skillLineID][cap]. A field the trainer does not give
-- stays nil ("unknown"), never guessed.

-- Rank names, in rank order: the client's GlobalStrings (vendored enUS.lua: APPRENTICE "Apprentice", JOURNEYMAN,
-- EXPERT, ARTISAN, MASTER, GRAND_MASTER "Grand Master", ILLUSTRIOUS, ZEN_MASTER), read at run time so a localized
-- client matches its own trainer; the enUS text is the fallback.
S.RANK_KEYS = { "APPRENTICE", "JOURNEYMAN", "EXPERT", "ARTISAN", "MASTER", "GRAND_MASTER", "ILLUSTRIOUS", "ZEN_MASTER" }
local RANK_EN =
	{ "Apprentice", "Journeyman", "Expert", "Artisan", "Master", "Grand Master", "Illustrious", "Zen Master" }

function S.rankNames()
	local out = {}
	for i, k in ipairs(S.RANK_KEYS) do
		local v = clean(_G[k])
		out[i] = (type(v) == "string" and v ~= "") and v or RANK_EN[i]
	end
	return out
end

-- The rank order of a trainer service, or nil: its sub text is a rank name, or its name is one or starts with one and
-- a space ("Expert Leatherworker"). The longest name wins, so "Grand Master" is never read as "Master".
function S.rankOrder(service, names)
	local best, bestLen
	local name, sub = service.name, service.subText
	for order, n in ipairs(names or S.rankNames()) do
		local hit = sub == n or name == n or (type(name) == "string" and name:sub(1, #n + 1) == n .. " ")
		if hit and (not bestLen or #n > bestLen) then
			best, bestLen = order, #n
		end
	end
	return best
end

-- Parses the services of one profession trainer into ranks. `services` is a list of
-- { name, type, subText, reqLevel, levelReq, cost, skillName, skillRank, description, skillLine } as the trainer
-- getters return them (nil where a getter gave nothing or a secret); `values` = { rank, maxRank, modifier } from
-- GetTrainerTradeskillRankValues().
--
-- Where a rank's cap comes from: the trainer has no per-service cap getter. GetTrainerTradeskillRankValues() is the
-- rank bar of the trainer window (Blizzard_TrainerUI.lua, "rank status bar"): the player's current skill and cap in
-- the trainer's profession, not a service's. So
--   1. the highest rank the player already knows (service type "used") has cap = that live maxRank;
--   2. any other rank takes the largest number in its description (GetTrainerServiceDescription, the rank spell's
--      text) that is above its skill requirement and, for a rank not yet known, above the live cap;
--   3. else the cap is unknown: the rank goes to `noCap` (it cannot be saved, the store is keyed by cap).
-- Caps must rise with rank order; a description cap that breaks the order is dropped to `noCap`.
-- Returns { ranks = { {name, order, cap, capFrom, skill, level, cost, where = "trainer", skillLine} }, noCap = {names} }.
function S.parseRankServices(services, values, names)
	names = names or S.rankNames()
	values = values or {}
	local maxRank = tonumber(values.maxRank)
	local found, highestUsed = {}, nil
	for _, sv in ipairs(services or {}) do
		local order = S.rankOrder(sv, names)
		if order then
			local level = tonumber(sv.levelReq) or tonumber(sv.reqLevel)
			local r = {
				name = names[order],
				order = order,
				skill = sv.skillName and tonumber(sv.skillRank) or nil,
				level = level,
				cost = tonumber(sv.cost),
				where = "trainer",
				skillLine = sv.skillLine,
				used = sv.type == "used",
				description = sv.description,
			}
			-- the same rank listed twice (a filter header, a second skill line): keep the first
			local dupe = false
			for _, f in ipairs(found) do
				dupe = dupe or f.order == order
			end
			if not dupe then
				found[#found + 1] = r
				if r.used and (not highestUsed or order > highestUsed.order) then
					highestUsed = r
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return a.order < b.order
	end)
	for _, r in ipairs(found) do
		if r == highestUsed and maxRank and maxRank > 0 then
			r.cap, r.capFrom = maxRank, "GetTrainerTradeskillRankValues"
		elseif type(r.description) == "string" then
			local floor = r.skill or 0
			if not r.used and maxRank then
				floor = math.max(floor, maxRank)
			end
			local best
			for n in r.description:gmatch("%d+") do
				n = tonumber(n)
				if n > floor and (not best or n > best) then
					best = n
				end
			end
			if best then
				r.cap, r.capFrom = best, "description"
			end
		end
	end
	local out = { ranks = {}, noCap = {} }
	local lastCap = 0
	for _, r in ipairs(found) do
		if r.cap and r.capFrom == "description" and r.cap <= lastCap then
			r.cap, r.capFrom = nil, nil
		end
		if r.cap then
			lastCap = r.cap
			r.used, r.description = nil, nil
			out.ranks[#out.ranks + 1] = r
		else
			out.noCap[#out.noCap + 1] = r.name
		end
	end
	return out
end

-- Writes parsed ranks into the store (SkillupHelperDB.ranks), contract shape. Returns the number written.
function S.saveRanks(store, skillLineID, ranks, now)
	store[skillLineID] = store[skillLineID] or {}
	local n = 0
	for _, r in ipairs(ranks) do
		store[skillLineID][r.cap] = {
			name = r.name,
			cap = r.cap,
			skill = r.skill,
			level = r.level,
			cost = r.cost,
			where = r.where,
			seen = now,
		}
		n = n + 1
	end
	return n
end

-- The saved ranks of one profession as the planner's sorted array (input.ranks).
function S.ranksArray(saved)
	local out = {}
	for cap, r in pairs(type(saved) == "table" and saved or {}) do
		if type(r) == "table" then
			out[#out + 1] = {
				name = r.name,
				cap = r.cap or cap,
				skill = r.skill,
				level = r.level,
				cost = r.cost,
				where = r.where,
			}
		end
	end
	table.sort(out, function(a, b)
		return a.cap < b.cap
	end)
	return out
end

-- The skill line id of the player's profession named `name`, or of the one whose skill and cap match the trainer's
-- rank bar when the name is missing (nil when none or several match).
function S.playerSkillLine(name, values)
	if not GetProfessions or not GetProfessionInfo then
		return nil, "GetProfessions/GetProfessionInfo absent"
	end
	-- prof1, prof2, first aid, fishing, cooking (Camelot ProfessionsBook.lua); nil holes, so walk by count
	local function pack(...)
		return { n = select("#", ...), ... }
	end
	local list = pack(GetProfessions())
	local byValues, nValues = nil, 0
	for i = 1, list.n do
		local index = list[i]
		if index then
			local pname, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
			pname, rank, maxRank, skillLine = clean(pname), clean(rank), clean(maxRank), clean(skillLine)
			if type(name) == "string" and type(pname) == "string" and pname:lower() == name:lower() then
				return skillLine
			end
			if values and rank == values.rank and maxRank == values.maxRank then
				byValues, nValues = skillLine, nValues + 1
			end
		end
	end
	if not name and nValues == 1 then
		return byValues
	end
	return nil, ("trainer's profession %s is not one of yours (GetProfessions)"):format(tostring(name or "unnamed"))
end

-- The trainerSeen key of a recipe service: its spell ID when the trainer gave one, else its lowercased name (the same
-- key the vendor guide keeps in SkillupHelperDB.guide.npcs[id].teaches). The planner matches either.
function S.trainerKey(sv)
	if type(sv.spellID) == "number" then
		return sv.spellID
	end
	if type(sv.name) == "string" and sv.name ~= "" then
		return sv.name:lower()
	end
	return nil
end

-- The recipe services of a trainer list (no rank services, no headers) as a set of trainerKey()s, and how many were
-- keyed by name only.
function S.trainerSeenSet(services, names)
	local seen, byName = {}, 0
	for _, sv in ipairs(services or {}) do
		if sv.type ~= "header" and not S.rankOrder(sv, names) then
			local key = S.trainerKey(sv)
			if key then
				seen[key] = true
				if type(key) == "string" then
					byName = byName + 1
				end
			end
		end
	end
	return seen, byName
end

-- The spell ID of a trainer service: C_TooltipInfo.GetTrainerService(i) is TooltipData whose `id` is the spell ID
-- when its `type` is Enum.TooltipDataType.Spell (TooltipUtil.lua reads tooltipData.id the same way). The legacy
-- GetTrainerService* getters give no spell ID; anything else is nil (the service is then keyed by name).
local function serviceSpellID(i)
	if not (C_TooltipInfo and C_TooltipInfo.GetTrainerService and Enum and Enum.TooltipDataType) then
		return nil
	end
	local ok, data = pcall(C_TooltipInfo.GetTrainerService, i)
	if not ok or type(data) ~= "table" or secret(data.type) or data.type ~= Enum.TooltipDataType.Spell then
		return nil
	end
	local id = clean(data.id)
	return type(id) == "number" and id or nil
end

-- Reads the open trainer. Returns { skillLine, ranks, noCap, seen, seenByName } (ranks may be empty: a trainer
-- without rank services still lists the recipes it teaches) or nil, and the broken link ("not now" when the trainer
-- is not a profession trainer).
function S.readTrainer()
	if IsTradeskillTrainer and not IsTradeskillTrainer() then
		return nil, "not a profession trainer", "not now"
	end
	if not GetNumTrainerServices or not GetTrainerServiceInfo then
		return nil, "GetNumTrainerServices/GetTrainerServiceInfo absent"
	end
	local n = clean(GetNumTrainerServices())
	if type(n) ~= "number" or n < 1 then
		return nil, "GetNumTrainerServices returned nothing (the filter hides every service?)"
	end
	local values = {}
	if GetTrainerTradeskillRankValues then
		local rank, maxRank, modifier = GetTrainerTradeskillRankValues()
		values = { rank = clean(rank), maxRank = clean(maxRank), modifier = clean(modifier) }
	end
	local names = S.rankNames()
	local services, all = {}, {}
	local profName
	for i = 1, n do
		local name, kind, _, reqLevel, subText = GetTrainerServiceInfo(i)
		local sv = { name = clean(name), type = clean(kind), reqLevel = clean(reqLevel), subText = clean(subText) }
		all[#all + 1] = sv
		if sv.type ~= "header" then
			sv.skillLine = GetTrainerServiceSkillLine and clean(GetTrainerServiceSkillLine(i))
			profName = profName or sv.skillLine
		end
		if S.rankOrder(sv, names) then
			sv.levelReq = GetTrainerServiceLevelReq and clean(GetTrainerServiceLevelReq(i))
			sv.cost = GetTrainerServiceCost and clean((GetTrainerServiceCost(i)))
			if GetTrainerServiceSkillReq then
				local skillName, skillRank = GetTrainerServiceSkillReq(i)
				sv.skillName, sv.skillRank = clean(skillName), clean(skillRank)
			end
			sv.description = GetTrainerServiceDescription and clean(GetTrainerServiceDescription(i))
			services[#services + 1] = sv
		elseif sv.type ~= "header" then
			sv.spellID = serviceSpellID(i)
		end
	end
	local parsed = S.parseRankServices(services, values, names)
	parsed.seen, parsed.seenByName = S.trainerSeenSet(all, names)
	local skillLine, why = S.playerSkillLine(profName, values.maxRank and values or nil)
	if not skillLine then
		return nil, why
	end
	parsed.skillLine = skillLine
	if #services == 0 then
		return parsed, ("no rank service among %d (names %s)"):format(n, table.concat(names, "/"))
	end
	if #parsed.ranks == 0 then
		local how = (values.maxRank and values.maxRank > 0) and "no known rank listed (filter hides used services?)"
			or "GetTrainerTradeskillRankValues returned nothing"
		return parsed,
			("cap unknown for %s: %s, no cap in the descriptions"):format(table.concat(parsed.noCap, ", "), how)
	end
	if #parsed.noCap > 0 then
		return parsed, ("cap unknown for %s (no cap in the descriptions)"):format(table.concat(parsed.noCap, ", "))
	end
	return parsed
end
