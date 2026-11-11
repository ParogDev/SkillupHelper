-- Ranks learned at the trainer (Scan.parseRankServices and friends) and the planner input Scan builds from them.
local function load()
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Planner.lua", "Scan.lua", "TSM.lua" }) do
		assert(loadfile(f))("SkillupHelper", ns)
	end
	return ns
end

local S
before_each(function()
	_G.issecretvalue = function()
		return false
	end
	S = load().Scan
end)

local NAMES = { "Apprentice", "Journeyman", "Expert", "Artisan", "Master", "Grand Master", "Illustrious", "Zen Master" }

describe("rankOrder", function()
	it("reads the rank from the sub text or the start of the name", function()
		assert.equal(3, S.rankOrder({ name = "Leatherworking", subText = "Expert" }, NAMES))
		assert.equal(2, S.rankOrder({ name = "Journeyman Leatherworker" }, NAMES))
		assert.equal(4, S.rankOrder({ name = "Artisan" }, NAMES))
	end)

	it("never reads Grand Master as Master, and skips recipes", function()
		assert.equal(6, S.rankOrder({ name = "Grand Master Leatherworker" }, NAMES))
		assert.is_nil(S.rankOrder({ name = "Masterwork Gloves", subText = "" }, NAMES))
		assert.is_nil(S.rankOrder({ name = "Heavy Armor Kit" }, NAMES))
	end)

	it("falls back to the enUS names when the GlobalStrings are absent", function()
		assert.equal("Expert", S.rankNames()[3])
	end)
end)

describe("parseRankServices", function()
	local services = {
		{ name = "Leatherworking", subText = "Journeyman", type = "used", reqLevel = 10, cost = 500 },
		{
			name = "Leatherworking",
			subText = "Expert",
			type = "available",
			reqLevel = 20,
			levelReq = 20,
			cost = 10000,
			skillName = "Leatherworking",
			skillRank = 125,
			description = "Raises your maximum skill to 225.",
		},
		{
			name = "Leatherworking",
			subText = "Artisan",
			type = "unavailable",
			skillName = "Leatherworking",
			skillRank = 200,
		},
		{ name = "Heavy Armor Kit", type = "available", cost = 900 },
	}

	it("takes the known rank's cap from the rank bar and the next from its description", function()
		local out = S.parseRankServices(services, { rank = 140, maxRank = 150 }, NAMES)
		assert.equal(2, #out.ranks)
		local j, e = out.ranks[1], out.ranks[2]
		assert.same({ "Journeyman", 150, "GetTrainerTradeskillRankValues" }, { j.name, j.cap, j.capFrom })
		assert.is_nil(j.skill)
		assert.equal(10, j.level)
		assert.same({ "Expert", 225, "description", 125, 20, 10000, "trainer" }, {
			e.name,
			e.cap,
			e.capFrom,
			e.skill,
			e.level,
			e.cost,
			e.where,
		})
		assert.same({ "Artisan" }, out.noCap)
	end)

	it("leaves the cap unknown when the rank bar is empty and no description has one", function()
		local out = S.parseRankServices({ services[1], services[3] }, {}, NAMES)
		assert.equal(0, #out.ranks)
		assert.same({ "Journeyman", "Artisan" }, out.noCap)
	end)

	it("drops a description cap that does not rise with the rank order", function()
		local bad = {
			services[1],
			{ name = "Leatherworking", subText = "Expert", description = "Requires 140 skill." },
		}
		local out = S.parseRankServices(bad, { rank = 140, maxRank = 150 }, NAMES)
		assert.equal(1, #out.ranks)
		assert.same({ "Expert" }, out.noCap)
	end)
end)

describe("saved ranks", function()
	it("saves by skill line and cap and reads back a sorted array", function()
		local store = {}
		local out = S.parseRankServices({
			{ name = "Leatherworking", subText = "Expert", description = "to 225", skillName = "LW", skillRank = 125 },
			{ name = "Leatherworking", subText = "Journeyman", type = "used", cost = 500 },
		}, { rank = 140, maxRank = 150 }, NAMES)
		assert.equal(2, S.saveRanks(store, 165, out.ranks, 1234))
		assert.same(
			{ name = "Expert", cap = 225, skill = 125, cost = nil, level = nil, where = "trainer", seen = 1234 },
			store[165][225]
		)
		local arr = S.ranksArray(store[165])
		assert.same({ 150, 225 }, { arr[1].cap, arr[2].cap })
		assert.is_nil(arr[1].seen)
	end)

	it("aims at the highest rank cap, else the plan's to, never below the live cap", function()
		assert.equal(300, S.target({ { cap = 225 }, { cap = 300 } }, { to = 250 }, 150))
		assert.equal(250, S.target({}, { to = 250 }, 150))
		assert.equal(150, S.target({}, nil, 150))
		assert.equal(225, S.target({ { cap = 150 } }, { to = 100 }, 225))
	end)

	it("keys ranks and exclusions for the planner cache", function()
		assert.equal("150/nil/10/500/trainer", S.ranksKey({ { cap = 150, level = 10, cost = 500, where = "trainer" } }))
		assert.equal(
			"true/false/true/7,9",
			S.excludeKey({ dungeon = true, notNow = { [9] = true, [7] = true, [8] = false } })
		)
		assert.equal("false/false/true/", S.excludeKey(nil))
		assert.equal("false/false/false/", S.excludeKey({ special = false }))
		assert.equal("-", S.seenKey(nil))
		assert.equal("2545,goldthorn tea", S.seenKey({ ["goldthorn tea"] = true, [2545] = true }))
	end)
end)

describe("trainerSeen", function()
	it("keys recipe services by spell ID, else lowercased name, and skips ranks and headers", function()
		local seen, byName = S.trainerSeenSet({
			{ name = "Leatherworking", subText = "Expert" },
			{ name = "Cooking", type = "header" },
			{ name = "Heavy Armor Kit", type = "available", spellID = 3780 },
			{ name = "Spiced Wolf Meat", type = "used" },
			{ type = "available" },
		}, NAMES)
		assert.same({ [3780] = true, ["spiced wolf meat"] = true }, seen)
		assert.equal(1, byName)
	end)
end)

describe("readTrainer", function()
	local services
	before_each(function()
		services = {
			{ "Leatherworking", "used", nil, 10, "Journeyman" },
			{ "Leatherworking", "available", nil, 20, "Expert" },
		}
		_G.IsTradeskillTrainer = function()
			return true
		end
		_G.GetNumTrainerServices = function()
			return #services
		end
		_G.GetTrainerServiceInfo = function(i)
			return unpack(services[i])
		end
		_G.GetTrainerServiceLevelReq = function(i)
			return services[i][4]
		end
		_G.GetTrainerServiceCost = function(i)
			return i * 500, true
		end
		_G.GetTrainerServiceSkillReq = function(i)
			if i == 2 then
				return "Leatherworking", 125, true
			end
		end
		_G.GetTrainerServiceDescription = function()
			return nil
		end
		_G.GetTrainerServiceSkillLine = function()
			return "Leatherworking"
		end
		_G.GetTrainerTradeskillRankValues = function()
			return 140, 150, 0
		end
		_G.GetProfessions = function()
			return 1, nil, nil, nil, 2
		end
		_G.GetProfessionInfo = function(i)
			if i == 1 then
				return "Leatherworking", nil, 140, 150, 0, 0, 165
			end
			return "Cooking", nil, 1, 75, 0, 0, 185
		end
	end)
	after_each(function()
		for _, g in ipairs({
			"IsTradeskillTrainer",
			"GetNumTrainerServices",
			"GetTrainerServiceInfo",
			"GetTrainerServiceLevelReq",
			"GetTrainerServiceCost",
			"GetTrainerServiceSkillReq",
			"GetTrainerServiceDescription",
			"GetTrainerServiceSkillLine",
			"GetTrainerTradeskillRankValues",
			"GetProfessions",
			"GetProfessionInfo",
		}) do
			_G[g] = nil
		end
	end)

	it("reads the known rank and names the one whose cap is unknown", function()
		local parsed, why = S.readTrainer()
		assert.equal(165, parsed.skillLine)
		assert.equal(1, #parsed.ranks)
		assert.same({ "Journeyman", 150, 10, 500 }, {
			parsed.ranks[1].name,
			parsed.ranks[1].cap,
			parsed.ranks[1].level,
			parsed.ranks[1].cost,
		})
		assert.matches("cap unknown for Expert", why)
	end)

	it("records the recipes it teaches, by spell ID from the tooltip data or by name", function()
		services[3] = { "Heavy Armor Kit", "available", nil, 1, nil }
		services[4] = { "Rugged Leather", "available", nil, 1, nil }
		_G.Enum = { TooltipDataType = { Spell = 1 } }
		_G.C_TooltipInfo = {
			GetTrainerService = function(i)
				return i == 3 and { type = 1, id = 3780 } or { type = 0, id = 4234 }
			end,
		}
		local parsed = S.readTrainer()
		_G.Enum, _G.C_TooltipInfo = nil, nil
		assert.same({ [3780] = true, ["rugged leather"] = true }, parsed.seen)
		assert.equal(1, parsed.seenByName)
	end)

	it("keeps the recipes of a trainer without rank services", function()
		services = { { "Heavy Armor Kit", "available", nil, 1, nil } }
		local parsed, why = S.readTrainer()
		assert.equal(165, parsed.skillLine)
		assert.same({ ["heavy armor kit"] = true }, parsed.seen)
		assert.matches("no rank service", why)
	end)

	it("says not now at a class trainer", function()
		_G.IsTradeskillTrainer = function()
			return false
		end
		local parsed, why, state = S.readTrainer()
		assert.is_nil(parsed)
		assert.equal("not now", state)
		assert.matches("not a profession trainer", why)
	end)

	it("names the empty rank bar", function()
		_G.GetTrainerTradeskillRankValues = function()
			return nil
		end
		_G.GetTrainerServiceSkillLine = function()
			return "Leatherworking"
		end
		local parsed, why = S.readTrainer()
		assert.equal(0, #parsed.ranks)
		assert.matches("GetTrainerTradeskillRankValues returned nothing", why)
	end)

	it("treats secret values as unknown", function()
		_G.issecretvalue = function(v)
			return v == 500
		end
		local parsed = S.readTrainer()
		assert.is_nil(parsed.ranks[1].cost)
	end)
end)
