-- luacheck for a WoW: Forever addon. Run from this folder (tools\lua.ps1 does): the generated globals list
-- lives in the scaffolding root; standalone (CI in this repo) falls back to a short list.
std = "lua51"
max_line_length = 140
codes = true
ignore = {
	"212/self", -- unused self
	"212/_.*", -- unused args named _x
}

local ok, wow = pcall(dofile, "../../tools/luacheck-wow-globals.lua")
if ok and type(wow) == "table" then
	read_globals = wow.read_globals
else
	-- CI in this repo runs standalone: every global the addon touches must be here.
	read_globals = {
		"CreateFrame", "C_AddOns", "C_Timer", "C_Item", "C_TradeSkillUI", "GetBuildInfo", "WOW_PROJECT_ID",
		"issecretvalue", "date", "time", "GetTime", "debugprofilestop",
		"C_MerchantFrame", "C_Container", "GetMerchantNumItems", "GetMerchantItemID", "GetMerchantItemMaxStack",
		"GetMerchantFilter", "BuyMerchantItem", "GetMoney", "bit",
	}
end
-- FrameXML globals for the vendor buy: the merchant window and bag constants.
for _, g in ipairs({ "MerchantFrame", "LE_LOOT_FILTER_ALL", "NUM_BAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS" }) do
	read_globals[#read_globals + 1] = g
end
-- FrameXML globals the generated list doesn't carry (it is built from the C API lists).
read_globals[#read_globals + 1] = "ProfessionsFrame"
read_globals[#read_globals + 1] = "UIParent"
read_globals[#read_globals + 1] = "GameTooltip"
read_globals[#read_globals + 1] = "debugstack"
-- TradeSkillMaster's public API (a required dependency).
read_globals[#read_globals + 1] = "TSM_API"

globals = { "SkillupHelper", "SkillupHelperDB", "SLASH_SKILLUPHELPER1", "SlashCmdList" }

files["Data/"] = { max_line_length = false }
files["tests/"] = { std = "+busted", globals = { "SkillupHelper", "SkillupHelperDB", "_G" } }
exclude_files = { ".luacheckrc" }
