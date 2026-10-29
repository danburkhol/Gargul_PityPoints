--[[
    Points log window (/pp log): every points change with when, who, why and which softres sheet.
]]

local _, PP = ...;

local ROW_HEIGHT = 20;
local COLUMNS = {
    { title = "When", width = 100, },
    { title = "Player", width = 100, },
    { title = "Item", width = 190, },
    { title = "Change", width = 55, },
    { title = "Now", width = 45, },
    { title = "Reason", width = 120, },
    { title = "Softres", width = 80, },
};

local Log;
local State = { raidKey = nil, search = "", Shown = {}, };

StaticPopupDialogs["GARGULPITYPOINTS_UNDO_IMPORT"] = {
    text = "%s",
    button1 = "Undo import",
    button2 = CANCEL,
    OnAccept = function (_, data) data.accept(); end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

StaticPopupDialogs["GARGULPITYPOINTS_NOTICE"] = {
    text = "%s",
    button1 = OKAY,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

local function confirmUndoImport(id)
    local Import = PP:import(id);
    local Blockers = PP:importUndoBlockers(id);

    if (Blockers) then
        local Lines = { "This import can't be undone." };
        for i, line in ipairs(Blockers) do
            if (i > 8) then
                tinsert(Lines, ("... and %d more"):format(#Blockers - 8));
                break;
            end
            tinsert(Lines, line);
        end
        if (Import and not Import.undoneAt) then
            tinsert(Lines, "\nThese points changed after the import. Set them back by hand first, or leave the import as it is.");
        end
        StaticPopup_Show("GARGULPITYPOINTS_NOTICE", table.concat(Lines, "\n"));
        return;
    end

    local text = ("Undo the import of %s by %s?\n\nIts %d changes go back to the points from before the import."):format(
        date("%Y-%m-%d %H:%M", Import.at), Import.by or "?", #PP:importEntries(id)
    );
    StaticPopup_Show("GARGULPITYPOINTS_UNDO_IMPORT", text, nil, {
        accept = function ()
            local count = PP:undoImport(id);
            if (count) then
                PP:print(("Import undone: %d points put back."):format(count));
            end
        end,
    });
end

local function initRow(row, Entry)
    if (not row.built) then
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD");
        row.Cells = {};

        local x = 4;
        for i, column in ipairs(COLUMNS) do
            local Text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
            Text:SetPoint("LEFT", x, 0);
            Text:SetWidth(column.width - 8);
            Text:SetJustifyH((i == 4 or i == 5) and "RIGHT" or "LEFT");
            Text:SetWordWrap(false);
            row.Cells[i] = Text;
            x = x + column.width;
        end

        row:SetScript("OnEnter", function (self)
            local E = self.data;
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetText(PP:raidLabel(E.raid), 1, 1, 1);
            GameTooltip:AddLine(("%s by %s"):format(date("%Y-%m-%d %H:%M:%S", E.at), E.by or "?"), 0.8, 0.8, 0.8);
            if (E.batch and E.reason == "import") then
                local Import = PP:import(E.batch);
                GameTooltip:AddLine(Import and Import.undoneAt and "This import was undone." or "Click to undo this whole import.", 0, 1, 0);
            end
            GameTooltip:Show();
        end);
        row:SetScript("OnLeave", GameTooltip_Hide);
        row:SetScript("OnClick", function (self)
            if (self.data.batch and self.data.reason == "import") then
                confirmUndoImport(self.data.batch);
            end
        end);

        row.built = true;
    end

    row.data = Entry;
    local C = row.Cells;
    C[1]:SetText(date("%m-%d %H:%M", Entry.at));
    C[2]:SetText(PP:displayName(Entry.player));
    C[3]:SetText(PP:itemLink(Entry.itemID) or PP:itemName(Entry.itemID));
    C[4]:SetText(Entry.delta > 0 and ("|cff00ff00+%d|r"):format(Entry.delta) or ("|cffff6060%d|r"):format(Entry.delta));
    C[5]:SetText(Entry.after);
    C[6]:SetText(PP.LEDGER_REASONS[Entry.reason] or Entry.reason);
    C[7]:SetText(Entry.sheet or "");
end

function PP:refreshLog()
    if (not Log or not Log:IsShown()) then
        return;
    end

    local needle = strlower(strtrim(State.search));
    local Shown = {};
    for _, Entry in ipairs(self:ledger(State.raidKey)) do
        if (needle == ""
            or Entry.player:find(needle, 1, true)
            or strlower(self:itemName(Entry.itemID)):find(needle, 1, true)
            or (Entry.sheet and strlower(Entry.sheet):find(needle, 1, true))
        ) then
            tinsert(Shown, Entry);
        end
    end
    State.Shown = Shown;

    Log.ScrollBox:SetDataProvider(CreateDataProvider(Shown), ScrollBoxConstants.RetainScrollPosition);
    Log.Subtitle:SetText(("%s  ·  %d entries"):format(State.raidKey and self:raidLabel(State.raidKey) or "All raids", #Shown));
end

local function createLog()
    local f = CreateFrame("Frame", "GargulPityPointsLog", UIParent, "BasicFrameTemplateWithInset");
    f:SetSize(730, 440);
    f:SetPoint("CENTER", 30, -30);
    f:SetToplevel(true);
    f:SetFrameStrata("HIGH");
    f:SetMovable(true);
    f:SetClampedToScreen(true);
    f:EnableMouse(true);
    f:RegisterForDrag("LeftButton");
    f:SetScript("OnDragStart", f.StartMoving);
    f:SetScript("OnDragStop", f.StopMovingOrSizing);
    f:Hide();
    tinsert(UISpecialFrames, f:GetName());

    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight");
    f.Title:SetPoint("TOP", 0, -5);
    f.Title:SetText(PP.title .. ": points log");

    local Search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate");
    Search:SetSize(200, 20);
    Search:SetPoint("TOPLEFT", 16, -30);
    Search.Instructions:SetText("Search player, item or softres");
    Search:HookScript("OnTextChanged", function (self)
        State.search = self:GetText();
        PP:refreshLog();
    end);

    f.Subtitle = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
    f.Subtitle:SetPoint("LEFT", Search, "RIGHT", 12, 0);

    local All = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    All:SetSize(90, 22);
    All:SetPoint("TOPRIGHT", -12, -29);
    All:SetText("All raids");
    All:SetScript("OnClick", function ()
        State.raidKey = nil;
        PP:refreshLog();
    end);

    local previous;
    for _, column in ipairs(COLUMNS) do
        local Header = CreateFrame("Button", nil, f, "ColumnDisplayButtonTemplate");
        Header:SetSize(column.width, 24);
        Header:SetText(column.title);
        Header:EnableMouse(false);
        if (previous) then
            Header:SetPoint("LEFT", previous, "RIGHT", -2, 0);
        else
            Header:SetPoint("TOPLEFT", 10, -56);
        end
        previous = Header;
    end

    local ScrollBox = CreateFrame("Frame", nil, f, "WowScrollBoxList");
    ScrollBox:SetPoint("TOPLEFT", 10, -82);
    ScrollBox:SetPoint("BOTTOMRIGHT", -30, 40);
    local ScrollBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar");
    ScrollBar:SetPoint("TOPLEFT", ScrollBox, "TOPRIGHT", 6, 0);
    ScrollBar:SetPoint("BOTTOMLEFT", ScrollBox, "BOTTOMRIGHT", 6, 0);
    local View = CreateScrollBoxListLinearView();
    View:SetElementExtent(ROW_HEIGHT);
    View:SetElementInitializer("Button", initRow);
    ScrollUtil.InitScrollBoxListWithScrollBar(ScrollBox, ScrollBar, View);
    f.ScrollBox = ScrollBox;

    local Export = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    Export:SetSize(110, 22);
    Export:SetPoint("BOTTOMRIGHT", -12, 10);
    Export:SetText("Export CSV");
    Export:SetScript("OnClick", function ()
        PP:showExport(PP:buildLedgerCSV(State.Shown), #State.Shown, "log");
    end);

    f:SetScript("OnShow", function () PP:refreshLog(); end);
    PP.RegisterCallback(f, "POINTS_CHANGED", function () PP:refreshLog(); end);

    return f;
end

--- Open the log, filtered to one raid (nil = all raids)
function PP:showLog(raidKey)
    Log = Log or createLog();
    State.raidKey = raidKey;
    Log:Show();
    Log:Raise();
    self:refreshLog();
end
