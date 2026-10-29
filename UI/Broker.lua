--[[
    LibDataBroker data object (shows up in Titan Panel, ChocolateBar, Bazooka, ...) and LibDBIcon minimap button.
]]

local _, PP = ...;

local BROKER_NAME = "Gargul_PityPoints";
local LDB = LibStub("LibDataBroker-1.1");
local DBIcon = LibStub("LibDBIcon-1.0");

local function entriesWithPoints()
    local Rows = {};
    for _, Row in ipairs(PP:allRows()) do
        if (Row.points > 0) then
            tinsert(Rows, Row);
        end
    end
    table.sort(Rows, function (a, b) return a.points > b.points; end);

    return Rows;
end

local function updateText()
    PP.broker.text = ("%d with points"):format(#entriesWithPoints());
end

local function showTooltip(tooltip)
    tooltip:AddLine(PP.title);

    local activeID = PP:activeSheetID();
    if (activeID) then
        tooltip:AddLine(("Active: %s  (%s)"):format(PP:raidLabel(PP:activeRaidKey()), activeID), 0.8, 0.8, 0.8);
    end

    local Rows = entriesWithPoints();
    if (#Rows == 0) then
        tooltip:AddLine("No points tracked yet.", 0.6, 0.6, 0.6);
    else
        for i = 1, math.min(8, #Rows) do
            local Row = Rows[i];
            tooltip:AddDoubleLine(
                ("%s  %s"):format(Row.name, PP:itemLink(Row.itemID) or Row.itemName),
                Row.points,
                1, 1, 1, 1, 1, 1
            );
        end
        if (#Rows > 8) then
            tooltip:AddLine(("...and %d more"):format(#Rows - 8), 0.6, 0.6, 0.6);
        end
    end

    tooltip:AddLine(" ");
    tooltip:AddLine("|cffffd100Left-click|r: open the manager", 0.8, 0.8, 0.8);
    tooltip:AddLine("|cffffd100Shift-click|r: points log", 0.8, 0.8, 0.8);
    tooltip:AddLine("|cffffd100Right-click|r: settings", 0.8, 0.8, 0.8);
end

function PP:initBroker()
    self.broker = LDB:NewDataObject(BROKER_NAME, {
        type = "data source",
        label = "Pity Points",
        text = "Pity Points",
        icon = self.icon,
        OnClick = function (_, button)
            if (button == "RightButton") then
                PP:openSettings();
            elseif (IsShiftKeyDown()) then
                PP:showLog(PP:activeRaidKey());
            else
                PP:toggleManager();
            end
        end,
        OnTooltipShow = showTooltip,
    });

    DBIcon:Register(BROKER_NAME, self.broker, self.db.Settings.minimap);

    self.RegisterCallback(BROKER_NAME, "POINTS_CHANGED", updateText);
    updateText();
end

function PP:setMinimapShown(shown)
    self.db.Settings.minimap.hide = not shown;

    if (shown) then
        DBIcon:Show(BROKER_NAME);
    else
        DBIcon:Hide(BROKER_NAME);
    end
end
