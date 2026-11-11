-- Reads the open profession window through C_TradeSkillUI and the bag+bank counts through C_Item, and builds the
-- panel's model with ns.Logic. Each step that can fail says where (Fail at the Broken Link): the result's `why`.
local _, ns = ...
local S = {}
ns.Scan = S

local function secret(v)
	return issecretvalue ~= nil and v ~= nil and issecretvalue(v)
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

-- Basic reagents of a recipe from its schematic (optional and finishing slots left out).
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

-- Runs the planner for one profession entry of a v2 Data/Plan.lua. learned[spell] = true, difficulty[spell] = the
-- client's relativeDifficulty. Returns the plan (steps, hold, leftovers, fromStock) plus price diagnostics.
function S.runPlanner(plan, prof, skill, cap, learned, difficulty, settings)
	settings = settings or {}
	local t0 = clock()
	local now = GetTime and GetTime() or 0
	local pc = priceCache[prof]
	-- salvage values depend on the sell-share setting: a changed share refetches like an expired entry
	if not pc or now - pc.at > S.PRICE_TTL or now < pc.at or pc.sellShare ~= settings.sellShare then
		local price, product, counts = ns.TSM.prices(plan, prof, nil, settings.sellShare)
		pc = { at = now, price = price, product = product, counts = counts, stamp = (pc and pc.stamp or 0) + 1 }
		pc.sellShare = settings.sellShare
		priceCache[prof] = pc
	end
	local effort = settings.effort or plan.effort or ns.Planner.EFFORT
	local nLearned, learnedKey = 0, {}
	for spell in pairs(learned) do
		nLearned = nLearned + 1
		learnedKey[#learnedKey + 1] = spell
	end
	table.sort(learnedKey)
	local luck = settings.luck or ns.Planner.LUCK
	local key = table.concat({ skill, cap, pc.stamp, effort, luck, nLearned, table.concat(learnedKey, ",") }, ":")
	local bc = baseCache[prof]
	if not bc or bc.key ~= key then
		local ctx = ns.Planner.prepare({
			skill = skill,
			cap = cap,
			recipes = prof.recipes,
			items = plan.items,
			learned = learned,
			difficulty = difficulty,
			price = pc.price,
			product = pc.product,
			effort = effort,
			luck = luck,
		})
		bc = { key = key, ctx = ctx, baseline = ns.Planner.baseline(ctx) }
		baseCache[prof] = bc
	end
	local have = {}
	for item in pairs(pc.price) do
		local n = S.have(item)
		if n > 0 then
			have[item] = n
		end
	end
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
	local result = ns.Planner.finish(bc.ctx, bc.baseline, have, {
		commit = commit,
		gold = GetMoney and GetMoney() or nil,
	})
	result.ms = clock() - t0
	result.prices = pc.counts
	result.ageHours = ns.TSM.ageHours(plan)
	result.profKey = prof.name
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
	local counts = { ids = #ids, learned = 0, secret = 0, noSchematic = 0, clientColor = 0, dataThresholds = 0 }
	local learned, difficulties, greyCheck = {}, {}, {}
	for _, id in ipairs(ids) do
		local r = C_TradeSkillUI.GetRecipeInfo(id)
		if type(r) == "table" then
			if secret(r.name) or secret(r.learned) then
				counts.secret = counts.secret + 1
			elseif r.learned then
				counts.learned = counts.learned + 1
				learned[id] = true
				local reagents = S.reagents(id)
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
				if th then
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
	if prof and ns.Logic.isPlanV2(plan, prof) and info.maxSkillLevel and info.maxSkillLevel > skill then
		local ok, result = pcall(
			S.runPlanner,
			plan,
			prof,
			skill,
			info.maxSkillLevel,
			learned,
			difficulties,
			ns.settings and ns.settings()
		)
		if ok then
			model.planner = result
		else
			model.plannerWhy = "planner failed: " .. tostring(result)
		end
	elseif prof and not ns.Logic.isPlanV2(plan, prof) then
		model.plannerWhy =
			"Data/Plan.lua is version 1 (no recipe reagents): rerun tools/tsm/skillup_lua.py, then /reload"
	end
	if prof then
		model.step, model.nextStep, model.planState = ns.Logic.planStep(prof, skill)
		model.shopping, model.craftsLeft = ns.Logic.stepShopping(model.step, skill, S.have)
		model.buyRecipes = ns.Logic.recipesToBuy(prof, skill, function(spell)
			return learned[spell] or false
		end)
	elseif not plan then
		model.planWhy = "Data/Plan.lua absent: run tools/tsm/skillup_lua.py, then /reload"
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
