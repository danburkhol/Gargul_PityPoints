std = "lua51"
max_line_length = false

-- Lint only our own code, not the embedded libraries.
exclude_files = { "Libs/**" }

-- 212/self: methods defined with `:` that don't need self.
ignore = { "212/self" }

-- Globals this addon creates or modifies (incl. Blizzard tables we add fields to).
globals = {
	"GargulPityPoints",
	"GargulPityPointsDB",
	"SLASH_GARGULPITYPOINTS1",
	"SLASH_GARGULPITYPOINTS2",
	"SlashCmdList",
	"StaticPopupDialogs",
	"UISpecialFrames",
}

-- WoW API and UI globals we only read.
read_globals = {
	-- Lua/WoW helpers
	"date",
	"time",
	"tinsert",
	"tremove",
	"wipe",
	"strtrim",
	"strsplit",
	"strjoin",
	"strlower",
	"strupper",
	"strsub",
	"hooksecurefunc",
	"geterrorhandler",
	"tostringall",
	"CopyTable",
	"LibStub",
	-- Game state
	"GetTime",
	"GetServerTime",
	"GetInstanceInfo",
	"IsInInstance",
	"IsInRaid",
	"GetNumGroupMembers",
	"GetRaidRosterInfo",
	"UnitName",
	"UnitClass",
	"RAID_CLASS_COLORS",
	"C_Timer",
	-- Loot window
	"GetNumLootItems",
	"GetLootSlotLink",
	"GetLootSourceInfo",
	-- Items
	"C_Item",
	"GetItemInfo",
	"GetItemIcon",
	"IsModifiedClick",
	"HandleModifiedItemClick",
	"IsShiftKeyDown",
	-- Frames / UI
	"CreateFrame",
	"UIParent",
	"DEFAULT_CHAT_FRAME",
	"GameTooltip",
	"GameTooltip_Hide",
	"HideUIPanel",
	"StaticPopup_Show",
	"MenuUtil",
	"ScrollUtil",
	"ScrollBoxConstants",
	"CreateDataProvider",
	"CreateScrollBoxListLinearView",
	"HIGHLIGHT_FONT_COLOR",
	"GRAY_FONT_COLOR",
	"CANCEL",
	"CLOSE",
	"DELETE",
	"OKAY",
	"YES",
	"NO",
	-- Settings (options panel)
	"Settings",
	"SettingsPanel",
	"MinimalSliderWithSteppersMixin",
	"CreateSettingsListSectionHeaderInitializer",
	"CreateSettingsButtonInitializer",
	-- Gargul (read only, hooked at runtime)
	"Gargul",
	"Gargul_L",
}
