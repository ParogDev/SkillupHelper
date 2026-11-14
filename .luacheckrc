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
	-- SlashCmdList is written (the /skillup handler): it is in `globals` below, so not read-only here
	read_globals = {}
	for _, g in ipairs(wow.read_globals) do
		if g ~= "SlashCmdList" then
			read_globals[#read_globals + 1] = g
		end
	end
else
	-- CI in this repo runs standalone: every global the addon touches must be here.
	read_globals = {
		"CreateFrame", "C_AddOns", "C_Timer", "C_Item", "C_TradeSkillUI", "GetBuildInfo", "WOW_PROJECT_ID",
		"issecretvalue", "date", "time", "GetTime", "debugprofilestop",
		"C_MerchantFrame", "C_Container", "GetMerchantNumItems", "GetMerchantItemID", "GetMerchantItemMaxStack",
		"GetMerchantFilter", "BuyMerchantItem", "GetMoney", "bit",
		-- the guide (GuideUI.lua)
		"C_Map", "C_SuperTrack", "C_Texture", "IsInInstance", "GetPlayerFacing", "UnitName", "UnitGUID", "IsInGroup",
		"InCombatLockdown", "GetNumTrainerServices", "GetTrainerServiceSkillLine", "hooksecurefunc",
		"GetTrainerServiceInfo", "GetTrainerServiceTypeFilter", "SetTrainerServiceTypeFilter",
		-- rank and recipe learning at the trainer (Scan.lua)
		"UnitLevel", "GetProfessions", "GetProfessionInfo", "C_TooltipInfo", "Enum", "IsTradeskillTrainer",
		"GetTrainerServiceCost", "GetTrainerServiceDescription", "GetTrainerServiceLevelReq",
		"GetTrainerServiceSkillReq", "GetTrainerTradeskillRankValues",
	}
end
-- FrameXML globals for the vendor buy: the merchant window and bag constants.
for _, g in ipairs({ "MerchantFrame", "LE_LOOT_FILTER_ALL", "NUM_BAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS" }) do
	read_globals[#read_globals + 1] = g
end
-- FrameXML helpers of the guide (Lua mixins, not C API).
read_globals[#read_globals + 1] = "CreateVector2D"
read_globals[#read_globals + 1] = "UiMapPoint"
read_globals[#read_globals + 1] = "MenuUtil"
read_globals[#read_globals + 1] = "GameTooltip_SetTitle"
read_globals[#read_globals + 1] = "C_Spell"
-- FrameXML globals the generated list doesn't carry (it is built from the C API lists).
read_globals[#read_globals + 1] = "ProfessionsFrame"
read_globals[#read_globals + 1] = "UIParent"
read_globals[#read_globals + 1] = "GameTooltip"
read_globals[#read_globals + 1] = "debugstack"
-- TradeSkillMaster's public API (a required dependency), and its saved settings' character list (read only).
read_globals[#read_globals + 1] = "TSM_API"
-- The mailbox (MailUI.lua) and the alts' names (Alts.lua): FrameXML frames and helpers, and the C API the
-- standalone list lacks.
for _, g in ipairs({
	"MailFrame", "OpenMailFrame", "SendMailFrame", "SendMailNameEditBox", "SendMailSubjectEditBox",
	"MailFrameTab_OnClick", "GetSendMailItem", "UnitFactionGroup", "GetRealmName", "InCombatLockdown",
	"NUM_BAG_SLOTS", "C_Container", "issecretvalue", "UnitName", "C_Item", "CursorHasItem", "ClearCursor",
}) do
	read_globals[#read_globals + 1] = g
end

globals = { "SkillupHelper", "SkillupHelperDB", "SLASH_SKILLUPHELPER1", "SlashCmdList" }

files["Data/"] = { max_line_length = false }
files["tests/"] = { std = "+busted", globals = { "SkillupHelper", "SkillupHelperDB", "_G" } }
exclude_files = { ".luacheckrc" }
