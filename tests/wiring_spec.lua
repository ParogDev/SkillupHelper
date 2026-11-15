-- The wiring (Journal.lua) against the whole addon: every file the TOC lists, loaded in TOC order into a sandboxed
-- global table with a small client mock, then the events the game sends at login. Checks that nothing fails or
-- leaks a global on load, that the provider returns a view-model for every page for five kinds of character, and
-- that every slash-command setting has a Settings control that writes the same SavedVariables.

local PAGES = { "overview", "path", "where", "shopping", "alts", "settings" }
local ALLOWED_GLOBALS = {
	SkillupHelper = true,
	SkillupHelperDB = true,
	SLASH_SKILLUPHELPER1 = true,
	BINDING_NAME_SKILLUPHELPER_JOURNAL = true,
	SkillupHelper_OnCompartmentClick = true,
	SkillupHelper_OnCompartmentEnter = true,
	SkillupHelper_OnCompartmentLeave = true,
}
-- Listed in the TOC, absent from the repo: the game skips them (local files a player may add).
local OPTIONAL = { ["Data/Plan.lua"] = true, ["Data/Custom.lua"] = true }

local function tocFiles()
	local out = {}
	for line in io.lines("SkillupHelper.toc") do
		line = line:gsub("\r$", "")
		if line ~= "" and not line:match("^#") then
			out[#out + 1] = (line:gsub("\\", "/"))
		end
	end
	return out
end

-- A frame: scripts and events are kept, every other method does nothing and returns nil.
local function newFrame(registry)
	local f = { scripts = {}, events = {} }
	local methods = {}
	function methods.SetScript(self, name, fn)
		self.scripts[name] = fn
	end
	function methods.GetScript(self, name)
		return self.scripts[name]
	end
	function methods.HookScript(self, name, fn)
		local old = self.scripts[name]
		self.scripts[name] = function(...)
			if old then
				old(...)
			end
			fn(...)
		end
	end
	function methods.RegisterEvent(self, e)
		self.events[e] = true
	end
	function methods.RegisterUnitEvent(self, e)
		self.events[e] = true
	end
	function methods.IsShown()
		return false
	end
	registry[#registry + 1] = f
	return setmetatable(f, {
		__index = function(_, k)
			return methods[k] or function() end
		end,
	})
end

-- The client a scenario describes: { class, level, faction, professions = { { line, rank, cap } },
-- skillInfo = { [line] = { rank, maxRank } }, prices = true | false | nil (nil: TSM not loaded) }.
local function client(sc, registry, printed)
	local G = {}
	G.CreateFrame = function()
		return newFrame(registry)
	end
	G.hooksecurefunc = function(t, name, fn)
		local old = t[name]
		t[name] = function(...)
			local a, b, c = old(...)
			fn(...)
			return a, b, c
		end
	end
	G.SlashCmdList = {}
	G.print = function(s)
		printed[#printed + 1] = tostring(s)
	end
	G.GetBuildInfo = function()
		return "1.60.1", "70888", "Nov 1 2026", 16001
	end
	G.WOW_PROJECT_ID = 99
	G.GetLocale = function()
		return "enUS"
	end
	G.GetTime = os.clock
	G.time = os.time
	G.date = os.date
	G.debugprofilestop = function()
		return os.clock() * 1000
	end
	G.issecretvalue = function()
		return false
	end
	G.InCombatLockdown = function()
		return false
	end
	G.C_Timer = {
		After = function() end,
		NewTicker = function()
			return { Cancel = function() end }
		end,
	}
	G.C_AddOns = {
		GetAddOnMetadata = function()
			return nil
		end,
	}
	G.UnitLevel = function()
		return sc.level or 60
	end
	G.UnitClassBase = function()
		return sc.class or "WARRIOR"
	end
	G.UnitFactionGroup = function()
		return sc.faction or "Horde"
	end
	G.UnitGUID = function()
		return "Player-0-00000001"
	end
	G.UnitName = function()
		return "Tester"
	end
	G.GetRealmName = function()
		return "Realm"
	end
	G.GetProfessions = function()
		local idx = {}
		for i = 1, #(sc.professions or {}) do
			idx[i] = i
		end
		return unpack(idx)
	end
	G.GetProfessionInfo = function(i)
		local p = sc.professions[i]
		return "Profession", 0, p[2], p[3], 0, 0, p[1]
	end
	G.C_SkillInfo = {
		GetSkillLineInfoByID = function(line)
			return sc.skillInfo and sc.skillInfo[line] or nil
		end,
	}
	G.GetBindingKey = function()
		return nil
	end
	if sc.prices ~= nil then
		G.TSM_API = {
			GetCustomPriceValue = function(_, item)
				if not sc.prices then
					return nil
				end
				local id = tonumber(tostring(item):match("%d+")) or 1
				return 50 + (id % 400)
			end,
			RegisterUICallback = function() end,
		}
	end
	return G
end

-- Loads every TOC file in order into one sandbox. Returns the sandbox, the namespace, load errors, globals written,
-- and fire(event, ...), which runs every registered frame's OnEvent and returns the errors.
local function loadAddon(sc)
	local registry, printed = {}, {}
	local G = client(sc or {}, registry, printed)
	local written, errors = {}, {}
	local env = setmetatable({}, {
		__index = function(_, k)
			local v = G[k]
			if v ~= nil then
				return v
			end
			return rawget(_G, k)
		end,
		__newindex = function(t, k, v)
			written[k] = true
			rawset(t, k, v)
		end,
	})
	rawset(env, "_G", env)
	local ns = {}
	for _, file in ipairs(tocFiles()) do
		local chunk, err = loadfile(file)
		if not chunk then
			if not OPTIONAL[file] then
				errors[#errors + 1] = file .. ": " .. tostring(err)
			end
		else
			setfenv(chunk, env)
			local ok, e = pcall(chunk, "SkillupHelper", ns)
			if not ok then
				errors[#errors + 1] = file .. ": " .. tostring(e)
			end
		end
	end
	local function fire(event, ...)
		local errs = {}
		for _, f in ipairs(registry) do
			if f.events[event] and f.scripts.OnEvent then
				local ok, e = pcall(f.scripts.OnEvent, f, event, ...)
				if not ok then
					errs[#errs + 1] = event .. ": " .. tostring(e)
				end
			end
		end
		return errs
	end
	return { env = env, ns = ns, errors = errors, written = written, fire = fire, printed = printed }
end

local function login(sc)
	local a = loadAddon(sc)
	assert.same({}, a.errors)
	assert.same({}, a.fire("ADDON_LOADED", "SkillupHelper"))
	assert.same({}, a.fire("PLAYER_LOGIN"))
	a.P = a.ns.Provider
	a.P.sync = true
	return a
end

-- Every page's view-model for the scenario, through the provider as JournalUI.refresh calls it.
local function pages(a, profession)
	local out = {}
	for _, page in ipairs(PAGES) do
		local c = { page = page, profession = profession }
		local j = a.P.provider.journal(c)
		assert.is_table(j, page .. ": journal shell")
		out[page] = a.P.provider.page(page, c)
		assert.is_table(out[page], page .. ": view-model")
	end
	out.journal = a.P.provider.journal({ page = "overview" })
	return out
end

local function row(ov, line)
	for _, r in ipairs(ov.rows) do
		if r.key == line then
			return r
		end
	end
end

describe("Load order", function()
	it("loads every TOC file in order with no error and no global beyond the allowed ones", function()
		local a = loadAddon({})
		assert.same({}, a.errors)
		local extra = {}
		for k in pairs(a.written) do
			if not ALLOWED_GLOBALS[k] then
				extra[#extra + 1] = k
			end
		end
		table.sort(extra)
		assert.same({}, extra)
		assert.is_function(a.env.SkillupHelper_OnCompartmentClick)
		assert.is_function(a.env.SlashCmdList.SKILLUPHELPER)
	end)

	it("lists Journal.lua after Core.lua and the frames before UI.lua", function()
		local at = {}
		for i, f in ipairs(tocFiles()) do
			at[f] = i
		end
		assert.is_true(at["Journal.lua"] > at["Core.lua"])
		for _, f in ipairs({ "Skills.lua", "Where.lua", "Widgets.lua", "MapCanvas.lua", "FieldUI.lua", "JournalUI.lua" }) do
			assert.is_true(at[f] < at["UI.lua"], f)
		end
		assert.is_true(at["Data/Spots.lua"] < at["Where.lua"])
	end)

	it("wires the provider and the login events without an error", function()
		local a = login({})
		assert.equal(a.P.provider, a.ns.JournalUI.provider)
		assert.is_nil(a.P.diag.firstError)
		-- first run: one chat line, then the button pulses
		local n = 0
		for _, line in ipairs(a.printed) do
			n = n + (line:find("the journal shows every profession", 1, true) and 1 or 0)
		end
		assert.equal(1, n)
		assert.is_true(a.P.pulse)
		assert.same({}, a.fire("PLAYER_LOGOUT"))
		local st = a.env.SkillupHelperDB.selftest
		assert.is_table(st.journalWiring)
		assert.is_table(st.firstLaunch)
		assert.is_true(st.firstLaunch.compartment)
		assert.is_true(st.firstLaunch.bindingName)
	end)

	it("/skillup journal opens the journal; /skillup with no profession window toggles it", function()
		local a = login({})
		local opened, toggled = {}, 0
		a.ns.JournalUI.open = function(page)
			opened[#opened + 1] = page or "default"
		end
		a.ns.JournalUI.Toggle = function()
			toggled = toggled + 1
		end
		a.env.SlashCmdList.SKILLUPHELPER("journal where")
		a.env.SlashCmdList.SKILLUPHELPER("")
		assert.same({ "where" }, opened)
		assert.equal(1, toggled)
		-- Core's commands still answer
		assert.is_true(a.ns.command("luck 95"))
		assert.equal(95, a.env.SkillupHelperDB.luck)
	end)
end)

describe("Provider: a view-model for every page", function()
	it("a crafter with shipped data and TSM prices", function()
		local a = login({ prices = true, professions = { { 164, 50, 150 }, { 186, 60, 150 } } })
		local p = pages(a, 164)
		local bs = row(p.overview, 164)
		assert.is_truthy(bs.cost.total, "Blacksmithing has a cost")
		assert.is_true(#p.path.rows > 0, "Blacksmithing has steps")
		assert.equal("Levelled at a crafting window", p.where.empty.title)
		assert.equal("TSM prices: live", a.P.prices().text)
		assert.is_nil(a.P.diag.firstError)
		-- the planner's cost, once per profession (cached): the slowest run must not stall a frame for long
		io.stderr:write(
			("\n[wiring] %d planner runs, slowest %.0f ms, total %.0f ms\n"):format(
				a.P.diag.costRuns,
				a.P.diag.costMaxMs,
				a.P.diag.costMs
			)
		)
		local runs = a.P.diag.costRuns
		pages(a, 164)
		assert.equal(runs, a.P.diag.costRuns, "a second refresh replans nothing")
		-- Mining: the node route on Path and Where, the shopping page not empty-handed
		local m = pages(a, 186)
		assert.is_true(#m.path.rows > 0)
		assert.is_true(#m.where.spots > 0)
		assert.is_table(m.where.selected)
		assert.equal("trackSpot", m.where.selected.actions[1].id)
	end)

	for _, rank in ipairs({ 1, 120, 300 }) do
		it("a rogue with Lockpicking " .. rank, function()
			local a = login({ class = "ROGUE", level = 60, skillInfo = { [633] = { rank = rank, maxRank = 300 } } })
			assert.equal(633, a.P.defaultProfession(a.P.snapshot()))
			local p = pages(a)
			local lp = row(p.overview, 633)
			assert.equal(rank, lp.skill)
			if rank >= 300 then
				assert.equal("complete", lp.status)
			else
				assert.is_true(#p.path.rows > 0)
				assert.is_true(#p.where.spots > 0 or p.where.empty ~= nil)
			end
			assert.is_nil(a.P.diag.firstError)
		end)
	end

	it("a gatherer: tracks a spot, the tracker and the chip share one slot", function()
		local a = login({ prices = true, professions = { { 182, 100, 150 }, { 393, 50, 75 } } })
		assert.equal(182, a.P.defaultProfession(a.P.snapshot()))
		local p = pages(a)
		assert.is_true(#p.where.spots > 0)
		local key = p.where.selected.key
		a.env.SkillupHelper.Widgets.state = { journal = { profession = 182 } }
		-- the frames themselves are journal_spec's business: here only what the wiring hands them
		local trackerVM, fieldVM = "unset", nil
		a.ns.FieldUI.setTracker = function(vm)
			trackerVM = vm
		end
		a.ns.FieldUI.update = function(vm)
			fieldVM = vm
		end
		a.ns.FieldUI.hide = function() end
		assert.is_true(a.P.provider.trackSpot(key))
		assert.same({ line = 182, spot = key }, a.P.tracked())
		assert.is_true(a.P.chipYields())
		assert.equal(key, trackerVM.key)
		assert.is_string(trackerVM.title)
		assert.equal(key, fieldVM.where.key)
		local live = a.P.provider.trackerLive()
		assert.is_table(live)
		-- a second click stops tracking
		a.P.provider.trackSpot(key)
		assert.is_nil(a.P.tracked())
		assert.is_false(a.P.chipYields())
		assert.is_nil(trackerVM)
		assert.is_nil(a.P.diag.firstError)
	end)

	it("a character with no profession", function()
		local a = login({ prices = true, class = "WARRIOR" })
		assert.is_nil(a.P.defaultProfession(a.P.snapshot()))
		local p = pages(a)
		assert.equal("No profession yet", p.path.empty.title)
		assert.is_true(#p.overview.rows >= 10)
		assert.truthy(p.overview.notice:find("no profession yet", 1, true))
		assert.is_nil(a.P.diag.firstError)
	end)

	it("no TSM prices: the status says what to do", function()
		local a = login({ prices = false, professions = { { 197, 30, 75 } } })
		local p = pages(a, 197)
		assert.equal(a.P.TEXT.noPrices, p.journal.status)
		local tsm
		for _, r in ipairs(p.settings.data) do
			if r.id == "tsm" then
				tsm = r
			end
		end
		assert.equal(a.P.TEXT.noPrices, tsm.detail)
		assert.is_truthy(row(p.overview, 197).cost.total, "costed from the shipped estimates")
	end)
end)

describe("Settings page", function()
	-- slash command -> the journal control (key, value, action extras) that must leave the same SavedVariables
	local CASES = {
		{ "luck 95", "luck", 95 },
		{ "effort 30", "effort", 30 },
		{ "recipes off", "recipes", false },
		{ "exclude dungeon", "dungeon", false },
		{ "exclude ahpatterns", "ahPatterns", false },
		{ "exclude special", "special", true },
		{ "exclude 12345", "notNow", true, { spell = 12345 } },
		{ "allow 12345", "allow", true, { spell = 12345 } },
	}
	local function state(db)
		return {
			luck = db.luck,
			effort = db.effort,
			noRecipeBuys = db.noRecipeBuys,
			exclude = {
				dungeon = db.exclude.dungeon,
				ahPatterns = db.exclude.ahPatterns,
				special = db.exclude.special,
				notNow = db.exclude.notNow[12345],
				allow = db.exclude.allow[12345],
			},
		}
	end

	for _, c in ipairs(CASES) do
		it(("/skillup %s and its control write the same"):format(c[1]), function()
			local a = login({})
			a.ns.command(c[1])
			local bySlash = state(a.env.SkillupHelperDB)
			local b = login({})
			local action = { id = "setting", key = c[2], value = c[3] }
			for k, v in pairs(c[4] or {}) do
				action[k] = v
			end
			b.P.provider.setting(c[2], c[3], action)
			assert.same(bySlash, state(b.env.SkillupHelperDB))
		end)
	end

	it("has a control for every slash setting", function()
		local a = login({})
		local keys = {}
		for _, e in ipairs(a.P.settingsPage().planner) do
			if e.key then
				keys[e.key] = e.kind
			end
		end
		for _, c in ipairs(CASES) do
			assert.is_truthy(keys[c[2]], c[2])
			assert.is_function(a.P.SETTING[c[2]], c[2])
		end
	end)
end)
