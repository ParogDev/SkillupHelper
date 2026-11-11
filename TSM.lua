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

-- TSM moves Blizzard's ProfessionsFrame far off-screen while its own window shows, without hiding it.
function T.onScreen(f)
	if not f or not f:IsVisible() then
		return false
	end
	local left, top = f:GetLeft(), f:GetTop()
	return left ~= nil and top ~= nil and left < 20000 and top < 20000
end
