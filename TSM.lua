-- TradeSkillMaster's crafting window, through its public TSM_API only (TSM's own frames are never touched).
-- TSM gives its crafting frame no global name and pools it, so the frame comes from RegisterUICallback each time
-- it shows, and is dropped when it hides. TSM_API has no call that adds to TSM's crafting queue.
local ADDON, ns = ...
local T = {}
ns.TSM = T

local frame -- TSM's crafting base frame while it is shown
local state = { api = false, callback = "not registered" }

function T.register()
	if type(TSM_API) ~= "table" or type(TSM_API.RegisterUICallback) ~= "function" then
		state.callback = "TSM_API.RegisterUICallback missing (TSM not loaded?)"
		return false
	end
	state.api = true
	local ok, err = pcall(TSM_API.RegisterUICallback, "CRAFTING", ADDON .. ":dock", function(shown, f)
		frame = shown and f or nil
		state.lastCallback = shown and "shown" or "hidden"
		if ns.onTSMChanged then
			ns.onTSMChanged()
		end
	end)
	state.callback = ok and "registered" or ("RegisterUICallback failed: " .. tostring(err))
	return ok
end

function T.craftingFrame()
	if frame and type(TSM_API) == "table" and TSM_API.IsUIVisible and not TSM_API.IsUIVisible("CRAFTING") then
		frame = nil
	end
	return frame
end

function T.status()
	return { api = state.api, callback = state.callback, lastCallback = state.lastCallback, docked = frame ~= nil }
end

-- One live TSM price in copper, or nil and why (TSM_API missing, an error, or no AuctionDB data for the item).
function T.value(source, item)
	if type(TSM_API) ~= "table" or type(TSM_API.GetCustomPriceValue) ~= "function" then
		return nil, "TSM_API.GetCustomPriceValue missing"
	end
	local ok, v, err = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. item)
	if not ok then
		return nil, tostring(v)
	end
	if type(v) ~= "number" or v ~= v then
		return nil, err or "no value"
	end
	return v
end

-- The batch-2 post-or-vendor test (tools/tsm/skillup.py Prices.product): copper per stack.
local POST_FAST_MIN, POST_SLOW_MIN, FAST_SALE_RATE, DEPOSIT_SHARE, AH_CUT, SELL_DAYS = 500, 5000, 0.25, 0.3, 0.95, 2

-- Prices for the planner from TSM live, Data/Plan.lua's export when TSM returns nothing. The desktop app keeps
-- AuctionDB synced, so live prices are the primary source; Plan.lua's are the fallback, and every fallback is counted.
-- plan: Data/Plan.lua's table; prof: its profession entry; get(source, item) -> copper or nil (default T.value).
-- Returns price[item] = { buy, where, salvage, export }, product[spell] = { vendor, sell, takes, export }, counts.
function T.prices(plan, prof, get, sellShare)
	get = get or T.value
	sellShare = sellShare or (plan and plan.sellShare) or 0.5
	local items = plan and plan.items or {}
	local vendor = plan and plan.vendor or {}
	local counts = { live = 0, export = 0, none = 0, products = { live = 0, export = 0 } }
	local price, product = {}, {}
	local market = {}
	local function marketOf(i)
		if market[i] == nil then
			local v = get("dbmarket", i) or get("dbminbuyout", i) or get("dbregionmarketavg", i)
			market[i] = v and { v, false } or ((items[i] and items[i].mv) and { items[i].mv, true } or false)
		end
		return market[i] and market[i][1], market[i] and market[i][2]
	end
	local function sellOf(i)
		return get("vendorsell", i) or (items[i] and items[i].sell) or 0
	end
	local function addItem(i)
		if price[i] then
			return
		end
		local e = {}
		if vendor[i] then
			local v = get("vendorbuy", i)
			e.buy, e.where, e.export = v or vendor[i], "vendor", v == nil
		else
			local v, fromExport = marketOf(i)
			e.buy, e.where, e.export = v, v and "ah" or nil, fromExport
		end
		if e.buy == nil then
			counts.none = counts.none + 1
		elseif e.export then
			counts.export = counts.export + 1
		else
			counts.live = counts.live + 1
		end
		local mv = marketOf(i)
		e.salvage = math.max(sellOf(i), sellShare * (mv or 0))
		price[i] = e
	end
	for spell, r in pairs(prof and prof.recipes or {}) do
		local mats = r.mats or {}
		for k = 1, #mats - 1, 2 do
			addItem(mats[k])
		end
		if r.item then
			addItem(r.item)
		end
		if r.makes then
			local n = r.n or 1
			local vs = sellOf(r.makes)
			local p = { vendor = vs * n, takes = 0 }
			local house = get("dbmarket", r.makes) or get("dbregionmarketavg", r.makes)
			local sale = get("dbregionsaleavg", r.makes)
			if house or sale then
				counts.products.live = counts.products.live + 1
				local s = math.min(house or sale, sale or house)
				local rate = get("dbregionsalerate", r.makes)
				if rate and rate > 1 then
					rate = rate / 1000 -- a raw per-mille value
				end
				local perDay = get("dbregionsoldperday", r.makes) or 0
				local stack = items[r.makes] and items[r.makes].stack or 1
				local net = AH_CUT * s - math.max(vs, 0.001) * (1 + DEPOSIT_SHARE * (1 / (rate or FAST_SALE_RATE) - 1))
				local fast = (rate or 0) >= FAST_SALE_RATE and perDay >= stack
				if net * stack >= (fast and POST_FAST_MIN or POST_SLOW_MIN) then
					p.sell, p.takes = (vs + net) * n, perDay * SELL_DAYS / n
				end
			elseif r.sell then
				counts.products.export = counts.products.export + 1
				p.sell, p.takes, p.export = r.sell, r.takes or 0, true
			end
			product[spell] = p
		end
	end
	return price, product, counts
end

-- Hours since the AuctionDB data the export saw was downloaded (Data/Plan.lua pricesAt), or nil when unknown.
-- TSM_API has no data-age call; the desktop app syncs AuctionDB and the export records its download time.
function T.ageHours(plan, now)
	local at = plan and plan.pricesAt
	if type(at) ~= "number" or at <= 0 then
		return nil
	end
	return ((now or time()) - at) / 3600
end
T.STALE_HOURS = 24

-- TSM moves Blizzard's ProfessionsFrame far off-screen while its own window shows, without hiding it.
function T.onScreen(f)
	if not f or not f:IsVisible() then
		return false
	end
	local left, top = f:GetLeft(), f:GetTop()
	return left ~= nil and top ~= nil and left < 20000 and top < 20000
end
