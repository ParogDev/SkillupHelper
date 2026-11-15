-- Skills.lua: the rank and cap of any skill line from an ordered chain of sources. The client calls come in through
-- `env.api`, so the chain and the chat parsing run here whole; Skills.env / Skills.register are checked in game.
local SECRET = {}

local function load()
	local ns = {}
	assert(loadfile("Skills.lua"))("SkillupHelper", ns)
	return ns.Skills
end

local UP, GAINED = "Your skill in %s has increased to %d.", "You have gained the %s skill."
local STRINGS = { up = UP, gained = GAINED }
local NAMES = { [633] = "Lockpicking", [186] = "Mining", [356] = "Fishing" }
local RULES = { [633] = { capPerLevel = 5, learnLevel = 16 } }

describe("Skills", function()
	local K
	before_each(function()
		_G.issecretvalue = function(v)
			return v == SECRET
		end
		K = load()
	end)
	after_each(function()
		_G.issecretvalue = nil
	end)

	describe("pattern", function()
		it("builds a capture pattern from the localized format", function()
			local pat, order = K.pattern(UP)
			assert.same({ 1, 2 }, order)
			assert.same({ "Lockpicking", "112" }, { ("Your skill in Lockpicking has increased to 112."):match(pat) })
		end)

		it("follows positional arguments of another locale", function()
			local pat, order = K.pattern("%2$d: das ist jetzt Eure Fertigkeit in %1$s.")
			assert.same({ 2, 1 }, order)
			assert.same({ "75", "Bergbau" }, { ("75: das ist jetzt Eure Fertigkeit in Bergbau."):match(pat) })
		end)

		it("escapes magic characters and literal percent signs", function()
			local pat = K.pattern("(%s) is 100%% [+%d]")
			assert.same({ "Mining", "3" }, { ("(Mining) is 100% [+3]"):match(pat) })
		end)

		it("gives nil for a format with no argument, a non-string or a secret", function()
			assert.is_nil(K.pattern("no arguments"))
			assert.is_nil(K.pattern(nil))
			assert.is_nil(K.pattern(SECRET))
		end)
	end)

	describe("parse", function()
		it("reads a skill-up and a newly gained skill", function()
			assert.same({ "Lockpicking", 112 }, { K.parse("Your skill in Lockpicking has increased to 112.", STRINGS) })
			assert.same({ "Fishing", 1 }, { K.parse("You have gained the Fishing skill.", STRINGS) })
		end)

		it("reads a two-word skill name", function()
			assert.same({ "First Aid", 40 }, { K.parse("Your skill in First Aid has increased to 40.", STRINGS) })
		end)

		it("reads the German word order", function()
			local s = { up = "Eure Fertigkeit '%s' hat sich auf %d erhoeht." }
			assert.same(
				{ "Schlossknacken", 20 },
				{ K.parse("Eure Fertigkeit 'Schlossknacken' hat sich auf 20 erhoeht.", s) }
			)
		end)

		it("names why a line is not a skill-up", function()
			local name, rank, why = K.parse("You receive loot: Copper Ore.", STRINGS)
			assert.is_nil(name)
			assert.is_nil(rank)
			assert.equal("not a skill-up line", why)
			assert.equal("the chat line is a secret value (in an instance)", select(3, K.parse(SECRET, STRINGS)))
			assert.equal("no chat line", select(3, K.parse(nil, STRINGS)))
			assert.matches("ERR_SKILL_UP_SI", select(3, K.parse("x", {})))
		end)
	end)

	describe("onChat", function()
		it("stores the rank under the line and marks the session", function()
			local db, session = {}, {}
			local line, rank =
				K.onChat(db, "Your skill in Lockpicking has increased to 112.", STRINGS, NAMES, 1000, session)
			assert.same({ 633, 112 }, { line, rank })
			assert.same({ rank = 112, at = 1000, from = "chat" }, db.skills[633])
			assert.is_true(session[633])
		end)

		it("matches the name without regard to case", function()
			assert.equal(186, (K.onChat({}, "Your skill in mining has increased to 5.", STRINGS, NAMES, 1)))
		end)

		it("names the skill it could not match and stores nothing", function()
			local db = {}
			local line, _, why = K.onChat(db, "Your skill in Swords has increased to 5.", STRINGS, NAMES, 1)
			assert.is_nil(line)
			assert.matches('"Swords" matched no known skill line', why, 1, true)
			assert.is_nil(db.skills)
		end)

		it("stores nothing from a secret line", function()
			local db = {}
			assert.is_nil((K.onChat(db, SECRET, STRINGS, NAMES, 1)))
			assert.is_nil(db.skills)
		end)
	end)

	describe("remember", function()
		it("refuses a secret or missing rank", function()
			local db = {}
			assert.is_nil((K.remember(db, 633, SECRET, nil, 1)))
			assert.is_nil((K.remember(db, 633, nil, nil, 1)))
			assert.is_nil(db.skills)
			assert.is_nil((K.remember(nil, 633, 5, nil, 1)))
		end)

		it("keeps an earlier cap when the new value has none", function()
			local db = {}
			K.remember(db, 186, 70, 75, 1, "api")
			K.remember(db, 186, 71, nil, 2, "chat")
			assert.same({ rank = 71, cap = 75, at = 2, from = "chat" }, db.skills[186])
		end)
	end)

	describe("available", function()
		it("gates Lockpicking on class and level only", function()
			assert.same({ true }, { K.available(186, { class = "WARRIOR", level = 1 }) })
			assert.same({ false, "Rogues only" }, { K.available(633, { class = "MAGE", level = 60 }, RULES[633]) })
			assert.same(
				{ false, "Rogues learn it at level 16" },
				{ K.available(633, { class = "ROGUE", level = 15 }, RULES[633]) }
			)
			assert.same({ true }, { K.available(633, { class = "ROGUE", level = 16 }, RULES[633]) })
		end)

		it("cannot say with the class or level unknown or secret", function()
			assert.same({ nil, "class unknown" }, { K.available(633, { level = 20 }) })
			assert.same({ nil, "class unknown" }, { K.available(633, { class = SECRET, level = 20 }) })
			assert.same({ nil, "level unknown" }, { K.available(633, { class = "ROGUE", level = SECRET }) })
		end)
	end)

	describe("read", function()
		local function env(extra)
			local e = { class = "ROGUE", level = 30, rules = RULES, api = {} }
			for k, v in pairs(extra or {}) do
				e[k] = v
			end
			return e
		end

		it("takes the skill api first and names it", function()
			local r = K.read(
				633,
				env({
					api = {
						skillInfo = function(line)
							return line == 633 and { rank = 112, maxRank = 150 } or nil
						end,
						professionInfo = function()
							error("not reached")
						end,
					},
				})
			)
			assert.same({ 112, 150, "skill api" }, { r.rank, r.cap, r.source })
			assert.equal("C_SkillInfo.GetSkillLineInfoByID", r.why)
			assert.is_true(r.learned)
			assert.is_true(r.available)
		end)

		it("falls to the tradeskill api when the skill api has no such line", function()
			local r = K.read(186, {
				api = {
					skillInfo = function()
						return nil
					end,
					professionInfo = function()
						return { skillLevel = 80, maxSkillLevel = 150 }
					end,
				},
			})
			assert.same({ 80, 150, "tradeskill api" }, { r.rank, r.cap, r.source })
		end)

		it("skips a tradeskill answer of 0 / 0 and reads GetProfessions", function()
			local r = K.read(186, {
				api = {
					professionInfo = function()
						return { skillLevel = 0, maxSkillLevel = 0 }
					end,
					professions = function()
						return { [186] = { skill = 61, cap = 75 } }
					end,
				},
			})
			assert.same({ 61, 75, "tradeskill api", "GetProfessions" }, { r.rank, r.cap, r.source, r.why })
		end)

		it("uses the chat value of this session, with Lockpicking's cap from the level", function()
			local r = K.read(633, env({ db = { skills = { [633] = { rank = 112 } } }, session = { [633] = true } }))
			assert.same({ 112, 150, "chat message", "estimate" }, { r.rank, r.cap, r.source, r.capSource })
		end)

		it("calls an earlier session's value saved", function()
			local r = K.read(633, env({ db = { skills = { [633] = { rank = 112 } } }, session = {} }))
			assert.equal("saved", r.source)
			assert.equal("the last value seen in an earlier session", r.why)
		end)

		it("estimates the cap of a saved rank from the rank steps when nothing says it", function()
			local r = K.read(186, { db = { skills = { [186] = { rank = 80 } } } })
			assert.same({ 80, 150, "saved", "estimate" }, { r.rank, r.cap, r.source, r.capSource })
			r = K.read(186, { db = { skills = { [186] = { rank = 80, cap = 225 } } } })
			assert.same({ 225, "saved" }, { r.cap, r.capSource })
		end)

		it("gives Lockpicking its cap and says the rank waits for a skill-up message", function()
			local r = K.read(
				633,
				env({
					api = {
						skillInfo = function()
							return nil
						end,
					},
				})
			)
			assert.is_nil(r.rank)
			assert.same({ 150, "estimate" }, { r.cap, r.source })
			assert.equal("skill unknown until the first skill-up message", r.why)
			assert.is_true(r.available)
		end)

		it("says not available for a rogue below 16 and for another class", function()
			local r = K.read(633, env({ level = 12 }))
			assert.same(
				{ false, false, "not available: Rogues learn it at level 16" },
				{ r.available, r.learned, r.why }
			)
			assert.is_nil(r.rank)
			r = K.read(633, env({ class = "PRIEST" }))
			assert.equal("not available: Rogues only", r.why)
		end)

		it("says not learned when the apis answer and have no such line", function()
			local r = K.read(186, {
				api = {
					skillInfo = function()
						return nil
					end,
				},
			})
			assert.same({ false, "not learned (no api lists this skill for the character)" }, { r.learned, r.why })
			assert.is_nil(r.source)
		end)

		it("says unknown, not unlearned, when there is no api at all", function()
			local r = K.read(186, {})
			assert.equal("skill unknown until the first skill-up message", r.why)
			assert.is_nil(r.learned)
		end)

		it("never takes a secret: falls to the saved value and flags not now", function()
			local e = env({
				api = {
					skillInfo = function()
						return { rank = SECRET, maxRank = SECRET }
					end,
				},
				db = { skills = { [633] = { rank = 100 } } },
			})
			local r = K.read(633, e)
			assert.same({ 100, "saved", true }, { r.rank, r.source, r.notNow })
			e.db = nil
			r = K.read(633, e)
			assert.is_nil(r.rank)
			assert.is_true(r.notNow)
			assert.matches("secret value", r.why, 1, true)
		end)

		it("reads every line asked for", function()
			local all = K.all({ 186, 633 }, env())
			assert.equal(186, all[186].line)
			assert.equal(633, all[633].line)
		end)
	end)

	describe("text", function()
		it("words each state", function()
			assert.equal("112 / 150", K.text({ rank = 112, cap = 150 }))
			assert.equal("? / 150", K.text({ cap = 150 }))
			assert.equal("not learned", K.text({ learned = false }))
			assert.equal("Rogues only", K.text({ available = false, why = "not available: Rogues only" }))
			assert.equal("unknown", K.text({}))
			assert.equal("unknown", K.text(nil))
		end)
	end)

	describe("register", function()
		it("registers its events and hooks the frame's handler", function()
			local events, hooked, set = {}, nil, nil
			local frame = {
				RegisterEvent = function(_, ev)
					events[#events + 1] = ev
				end,
				GetScript = function()
					return nil
				end,
				SetScript = function(_, _, fn)
					set = fn
				end,
				HookScript = function(_, _, fn)
					hooked = fn
				end,
			}
			K.register(frame)
			assert.same({ "CHAT_MSG_SKILL", "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP" }, events)
			assert.is_function(set)
			assert.is_nil(hooked)
			frame.GetScript = function()
				return function() end
			end
			K.register(frame)
			assert.is_function(hooked)
		end)
	end)
end)
