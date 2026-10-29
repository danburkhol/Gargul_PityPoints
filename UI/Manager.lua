--[[
    Pity Point manager window (/pp).
      Sidebar: campaigns (team · instance) with their softres sheets underneath, and New campaign.
      Campaign selected: points list with search, +/- and reset.
      Sheet selected: attendance checklist (attended / bench) and Close week.
]]

local _, PP = ...;

local ROW_HEIGHT = 22;
local SIDEBAR_WIDTH = 210;

local POINT_COLUMNS = {
    { key = "name", title = "Player", width = 130, ascending = true, },
    { key = "itemName", title = "Item", width = 280, ascending = true, },
    { key = "points", title = "Points", width = 60, ascending = false, },
};

local SHEET_COLUMNS = {
    { key = "name", title = "Player", width = 110, ascending = true, },
    { key = "itemsText", title = "Reserves", width = 185, ascending = true, },
    { key = "evidenceRank", title = "Seen", width = 110, ascending = false, },
    { key = "attendedRank", title = "Attended", width = 62, ascending = false, },
    { key = "benchRank", title = "Bench", width = 50, ascending = false, },
    { key = "result", title = "Points", width = 70, ascending = false, },
};

local State = {
    selection = nil, -- { kind = "raid" | "sheet", id = raidKey | softresID }
    search = "",
    onlyWithPoints = false,
    Sort = {
        points = { key = "name", ascending = true, },
        sheet = { key = "name", ascending = true, },
    },
    Shown = {}, -- Point rows currently listed (used by Export)
};

local Manager;

--[[ HELPERS ]]

local function classColor(class)
    local Color = class and RAID_CLASS_COLORS[strupper(class)];
    return Color or HIGHLIGHT_FONT_COLOR;
end

-- Prefer the sheet's own class data, then every sheet we've ever synced (not just Gargul's loaded one)
local function playerClass(key, Sheet)
    if (Sheet and Sheet.Classes and Sheet.Classes[key]) then
        return Sheet.Classes[key];
    end

    return PP:playerClass(key);
end

local function showTooltip(owner, title, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT");
    GameTooltip:SetText(title, 1, 1, 1);
    for i = 1, select("#", ...) do
        local line = select(i, ...);
        if (line) then
            GameTooltip:AddLine(line, nil, nil, nil, true);
        end
    end
    GameTooltip:Show();
end

local function step(raidKey)
    return IsShiftKeyDown() and 1 or PP:rules(raidKey).perWeek;
end

local function selected()
    local Selection = State.selection;
    if (Selection and Selection.kind == "raid" and PP:raid(Selection.id)) then
        return "raid", Selection.id;
    end
    if (Selection and Selection.kind == "sheet" and PP:sheet(Selection.id)) then
        return "sheet", Selection.id;
    end

    -- Default: the active raid, else the first one
    local raidKey = PP:activeRaidKey() or PP:raidKeys()[1];
    if (raidKey) then
        State.selection = { kind = "raid", id = raidKey, };
        return "raid", raidKey;
    end
end

local function selectEntry(kind, id)
    State.selection = { kind = kind, id = id, };
    PP:refreshManager();
end

local function sortRows(Rows, Sort)
    local key, ascending = Sort.key, Sort.ascending;

    local function value(Row)
        local v = Row[key];
        if (type(v) == "boolean") then
            return v and 1 or 0;
        end
        if (type(v) == "string") then
            return strlower(v);
        end
        return v or 0;
    end

    table.sort(Rows, function (a, b)
        local va, vb = value(a), value(b);
        if (va ~= vb) then
            if (ascending) then
                return va < vb;
            end
            return va > vb;
        end
        if (a.key ~= b.key) then
            return a.key < b.key;
        end
        return (a.itemName or "") < (b.itemName or "");
    end);
end

local function matches(needle, ...)
    if (needle == "") then
        return true;
    end

    for i = 1, select("#", ...) do
        local text = select(i, ...);
        if (text and strlower(text):find(needle, 1, true)) then
            return true;
        end
    end

    return false;
end

--[[ COLUMN HEADERS ]]

local function createHeaders(parent, Columns, sortName)
    local Headers, previous = {}, nil;

    for _, column in ipairs(Columns) do
        local Header = CreateFrame("Button", nil, parent, "ColumnDisplayButtonTemplate");
        Header:SetSize(column.width, 24);
        Header:SetText(column.title);
        if (previous) then
            Header:SetPoint("LEFT", previous, "RIGHT", -2, 0);
        else
            Header:SetPoint("TOPLEFT", 2, -2);
        end

        Header.Arrow = Header:CreateTexture(nil, "OVERLAY");
        Header.Arrow:SetTexture("Interface\\Buttons\\UI-SortArrow");
        Header.Arrow:SetSize(9, 8);
        Header.Arrow:SetPoint("RIGHT", -6, 0);
        Header.Arrow:Hide();

        Header:SetScript("OnClick", function ()
            local Sort = State.Sort[sortName];
            if (Sort.key == column.key) then
                Sort.ascending = not Sort.ascending;
            else
                Sort.key, Sort.ascending = column.key, column.ascending;
            end
            PP:refreshManager();
        end);

        Header.column = column;
        tinsert(Headers, Header);
        previous = Header;
    end

    -- Empty header so the header bar spans the full width
    local Filler = CreateFrame("Button", nil, parent, "ColumnDisplayButtonTemplate");
    Filler:SetHeight(24);
    Filler:SetPoint("LEFT", previous, "RIGHT", -2, 0);
    Filler:SetPoint("RIGHT", parent, "RIGHT", -2, 0);
    Filler:SetText("");
    Filler:EnableMouse(false);

    return Headers;
end

local function updateArrows(Headers, Sort)
    for _, Header in ipairs(Headers) do
        local isSorted = Header.column.key == Sort.key;
        Header.Arrow:SetShown(isSorted);
        if (isSorted) then
            if (Sort.ascending) then
                Header.Arrow:SetTexCoord(0, 0.5625, 1, 0);
            else
                Header.Arrow:SetTexCoord(0, 0.5625, 0, 1);
            end
        end
    end
end

local function createList(parent, top, initializer)
    local ScrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList");
    ScrollBox:SetPoint("TOPLEFT", 4, top);
    ScrollBox:SetPoint("BOTTOMRIGHT", -22, 4);

    local ScrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar");
    ScrollBar:SetPoint("TOPLEFT", ScrollBox, "TOPRIGHT", 6, 0);
    ScrollBar:SetPoint("BOTTOMLEFT", ScrollBox, "BOTTOMRIGHT", 6, 0);

    local View = CreateScrollBoxListLinearView();
    View:SetElementExtent(ROW_HEIGHT);
    View:SetElementInitializer("Button", initializer);
    ScrollUtil.InitScrollBoxListWithScrollBar(ScrollBox, ScrollBar, View);
    ScrollBox.initializer = initializer;

    return ScrollBox;
end

--[[
    Show Rows in a list. A new data provider hides and re-shows every row, which drops a click that's
    half done (mouse down before, up after) and made ticking checkboxes quickly miss clicks. So when the
    view (signature) and the set of rows (rowID) are unchanged, update the rows in place, keeping their
    order: rows don't jump under the mouse; they re-sort when the sort, search or selection changes.
    Returns the rows as listed.
]]
local function setRows(ScrollBox, Rows, signature, rowID)
    local Provider = ScrollBox:GetDataProvider();

    if (Provider and ScrollBox.signature == signature and Provider:GetSize() == #Rows) then
        local ByID = {};
        for _, Row in ipairs(Rows) do
            ByID[rowID(Row)] = Row;
        end

        local Listed = Provider:GetCollection();
        local same = true;
        for _, Old in ipairs(Listed) do
            if (not ByID[rowID(Old)]) then
                same = false;
                break;
            end
        end

        if (same) then
            for _, Old in ipairs(Listed) do
                local New = ByID[rowID(Old)];
                wipe(Old);
                for k, v in pairs(New) do
                    Old[k] = v;
                end
            end
            ScrollBox:ForEachFrame(function (frame, data)
                ScrollBox.initializer(frame, data);
            end);
            return Listed;
        end
    end

    ScrollBox.signature = signature;
    ScrollBox:SetDataProvider(CreateDataProvider(Rows), ScrollBoxConstants.RetainScrollPosition);
    return Rows;
end

local function sortSignature(Sort)
    return Sort.key .. (Sort.ascending and "+" or "-");
end

local function cell(row, x, width, justify, font)
    local Text = row:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight");
    Text:SetPoint("LEFT", x, 0);
    Text:SetWidth(width);
    Text:SetJustifyH(justify or "LEFT");
    Text:SetWordWrap(false);
    return Text;
end

--[[ SIDEBAR ]]

local confirmCloseWeek; -- Defined with the dialogs below

local function dateOrDash(at)
    at = tonumber(at);
    return (at and at > 0) and date("%Y-%m-%d %H:%M", at) or "-";
end

local function toggleCollapsed(raidKey)
    local Collapsed = PP.db.UI.Collapsed;
    Collapsed[raidKey] = not Collapsed[raidKey] or nil;
    PP:refreshManager();
end

StaticPopupDialogs["GARGULPITYPOINTS_DELETE"] = {
    text = "%s",
    button1 = DELETE,
    button2 = CANCEL,
    OnAccept = function (_, data) data.accept(); end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

local function confirmDelete(kind, id)
    local text, accept;

    if (kind == "raid") then
        local Raid = PP:raid(id);
        text = ("Delete campaign |cffffd100%s|r?\n\nThis removes its rules, points and its %d softres sheets. The points log keeps its history."):format(
            Raid.label, #PP:sheetIDs(id)
        );
        accept = function () PP:deleteRaid(id); end;
    else
        local Sheet = PP:sheet(id);
        text = ("Delete softres sheet |cffffd100%s|r from %s?\n\nIts reserves, attendance and sync history are removed. Points stay as they are%s."):format(
            id, PP:raidLabel(Sheet.raidKey),
            Sheet.closedAt and " (reopen the week first if you want the points it added taken back)" or ""
        );
        accept = function () PP:deleteSheet(id); end;
    end

    StaticPopup_Show("GARGULPITYPOINTS_DELETE", text, nil, { accept = accept, });
end

local function showSidebarMenu(row)
    local data = row.data;

    if (not (MenuUtil and MenuUtil.CreateContextMenu)) then
        return confirmDelete(data.kind, data.id);
    end

    MenuUtil.CreateContextMenu(row, function (_, Root)
        Root:CreateTitle(data.label);

        if (data.kind == "raid") then
            if (data.id ~= PP.UNASSIGNED) then
                Root:CreateButton("Edit campaign...", function () PP:showCampaignEditor({ raidKey = data.id, }); end);
            end
            Root:CreateButton(PP.db.UI.Collapsed[data.id] and "Expand" or "Collapse", function () toggleCollapsed(data.id); end);
            Root:CreateButton("Points log", function () PP:showLog(data.id); end);
        else
            local Sheet = PP:sheet(data.id);
            Root:CreateButton(Sheet.closedAt and "Reopen week..." or "Close week...", function () confirmCloseWeek(data.id); end);
        end

        Root:CreateDivider();
        Root:CreateButton("|cffff6060Delete...|r", function () confirmDelete(data.kind, data.id); end);
    end);
end

local function initSidebarRow(row, data)
    if (not row.built) then
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp");
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD");

        row.Selected = row:CreateTexture(nil, "BACKGROUND");
        row.Selected:SetAllPoints();
        row.Selected:SetColorTexture(1, 0.82, 0, 0.18);

        row.Toggle = CreateFrame("Button", nil, row);
        row.Toggle:SetSize(14, 14);
        row.Toggle:SetPoint("LEFT", 4, 0);
        row.Toggle:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD");
        row.Toggle:SetScript("OnClick", function ()
            toggleCollapsed(row.data.id);
        end);

        row.Text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal");
        row.Text:SetJustifyH("LEFT");
        row.Text:SetWordWrap(false);

        row.Sub = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
        row.Sub:SetPoint("RIGHT", -6, 0);
        row.Sub:SetJustifyH("RIGHT");

        row:SetScript("OnClick", function (self, button)
            if (button == "RightButton") then
                showSidebarMenu(self);
            else
                selectEntry(self.data.kind, self.data.id);
            end
        end);
        row:SetScript("OnEnter", function (self)
            showTooltip(self, self.data.label, unpack(self.data.tooltip));
        end);
        row:SetScript("OnLeave", GameTooltip_Hide);

        row.built = true;
    end

    row.data = data;
    local isRaid = data.kind == "raid";

    row.Toggle:SetShown(isRaid);
    if (isRaid) then
        local icon = PP.db.UI.Collapsed[data.id] and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up";
        row.Toggle:SetNormalTexture(icon);
        row.Toggle:SetPushedTexture(icon);
    end

    row.Text:ClearAllPoints();
    row.Text:SetPoint("LEFT", isRaid and 22 or 26, 0);
    row.Text:SetPoint("RIGHT", row.Sub, "LEFT", -4, 0);
    row.Text:SetFontObject(isRaid and "GameFontNormal" or "GameFontHighlightSmall");
    row.Text:SetText(data.label);
    row.Sub:SetText(data.sub or "");

    local kind, id = selected();
    row.Selected:SetShown(kind == data.kind and id == data.id);
end

local function sidebarData()
    local Data = {};
    local activeID = PP:activeSheetID();

    for _, raidKey in ipairs(PP:raidKeys()) do
        local Raid = PP:raid(raidKey);
        local SheetIDs = PP:sheetIDs(raidKey);
        local collapsed = PP.db.UI.Collapsed[raidKey];
        local withPoints = 0;
        for _, Items in pairs(Raid.Points) do
            for _ in pairs(Items) do
                withPoints = withPoints + 1;
            end
        end

        tinsert(Data, {
            kind = "raid", id = raidKey, label = Raid.label,
            sub = collapsed and ("|cff999999%d sheets|r"):format(#SheetIDs) or (withPoints > 0 and tostring(withPoints) or ""),
            tooltip = {
                raidKey ~= PP.UNASSIGNED and ("|cffffd100%s|r"):format(PP:rulesText(raidKey)) or "Points from before raid tracking.",
                ("%d player/item entries with points, %d softres sheets."):format(withPoints, #SheetIDs),
                "Click: view and edit points. Right-click: edit, collapse, log, delete.",
            },
        });

        if (not collapsed) then
            for _, id in ipairs(SheetIDs) do
                local Sheet = PP:sheet(id);
                local sub, status;
                if (Sheet.closedAt) then
                    sub, status = "|cff999999closed|r", "Week closed " .. dateOrDash(Sheet.closedAt);
                elseif (id == activeID) then
                    sub, status = "|cff00ff00active|r", "Open, receiving rolls, wins and attendance.";
                else
                    sub, status = "|cffffd100open|r", "Open.";
                end

                tinsert(Data, {
                    kind = "sheet", id = id, label = PP:sheetLabel(id), sub = sub,
                    tooltip = {
                        status,
                        "Created: " .. dateOrDash(Sheet.createdAt),
                        "Raid starts: " .. dateOrDash(Sheet.raidStartsAt),
                        "Locked: " .. dateOrDash(Sheet.lockedAt),
                        "First imported: " .. dateOrDash(Sheet.firstSyncedAt),
                        "Click: attendance and Close week. Right-click: close/reopen, delete.",
                    },
                });
            end
        end
    end

    return Data;
end

--[[ POINTS VIEW ]]

local function initPointRow(row, data)
    if (not row.built) then
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD");

        local x = 4;
        row.Name = cell(row, x, POINT_COLUMNS[1].width - 8);
        x = x + POINT_COLUMNS[1].width;

        -- Item cell is its own button for the item tooltip, shift-click linking and click-to-filter
        row.Item = CreateFrame("Button", nil, row);
        row.Item:SetPoint("LEFT", x - 4, 0);
        row.Item:SetSize(POINT_COLUMNS[2].width - 4, ROW_HEIGHT);
        row.Item.Icon = row.Item:CreateTexture(nil, "ARTWORK");
        row.Item.Icon:SetSize(16, 16);
        row.Item.Icon:SetPoint("LEFT");
        row.Item.Text = row.Item:CreateFontString(nil, "ARTWORK", "GameFontHighlight");
        row.Item.Text:SetPoint("LEFT", row.Item.Icon, "RIGHT", 4, 0);
        row.Item.Text:SetPoint("RIGHT", -4, 0);
        row.Item.Text:SetJustifyH("LEFT");
        row.Item.Text:SetWordWrap(false);
        row.Item:SetScript("OnEnter", function (self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink("item:" .. row.data.itemID);
            GameTooltip:AddLine(" ");
            GameTooltip:AddLine("Click: show only this item. Shift-click: link in chat.", 0.6, 0.6, 0.6, true);
            GameTooltip:Show();
        end);
        row.Item:SetScript("OnLeave", GameTooltip_Hide);
        row.Item:SetScript("OnClick", function ()
            if (IsModifiedClick()) then
                local link = PP:itemLink(row.data.itemID);
                if (link) then
                    HandleModifiedItemClick(link);
                end
            else
                PP:setManagerSearch(row.data.itemName);
            end
        end);
        x = x + POINT_COLUMNS[2].width;

        row.Points = cell(row, x - 4, POINT_COLUMNS[3].width - 12, "RIGHT");
        x = x + POINT_COLUMNS[3].width;

        local function button(text, width, onClick, onEnter)
            local Button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate");
            Button:SetSize(width, 18);
            Button:SetText(text);
            Button:SetScript("OnClick", onClick);
            Button:SetScript("OnEnter", onEnter);
            Button:SetScript("OnLeave", GameTooltip_Hide);
            return Button;
        end

        row.Minus = button("-", 22, function ()
            PP:adjustPoints(row.data.raid, row.data.key, row.data.itemID, -step(row.data.raid));
        end, function (self)
            showTooltip(self, ("Remove %d points"):format(PP:rules(row.data.raid).perWeek), "Shift-click: 1 point");
        end);
        row.Minus:SetPoint("LEFT", x - 6, 0);

        row.Plus = button("+", 22, function ()
            PP:adjustPoints(row.data.raid, row.data.key, row.data.itemID, step(row.data.raid));
        end, function (self)
            showTooltip(self, ("Add %d points"):format(PP:rules(row.data.raid).perWeek), "Shift-click: 1 point");
        end);
        row.Plus:SetPoint("LEFT", row.Minus, "RIGHT", 2, 0);

        row.Reset = button("Reset", 48, function ()
            PP:resetPoints(row.data.raid, row.data.key, row.data.itemID);
        end, function (self)
            showTooltip(self, "Reset to 0", "Sets this player's points on this item to zero.");
        end);
        row.Reset:SetPoint("LEFT", row.Plus, "RIGHT", 2, 0);

        row:SetScript("OnClick", function ()
            PP:setManagerSearch(row.data.name);
        end);
        row:SetScript("OnEnter", function (self)
            showTooltip(self, row.data.name,
                row.data.reserved and "|cff00ff00On the raid's current softres sheet.|r"
                    or "|cff999999Not on the current sheet: no bonus, and it resets when the next sheet is synced.|r",
                "Click: show only this player.");
        end);
        row:SetScript("OnLeave", GameTooltip_Hide);

        row.built = true;
    end

    row.data = data;
    row.Name:SetText(data.name);
    row.Name:SetTextColor(classColor(playerClass(data.key)):GetRGB());
    row.Item.Icon:SetTexture(PP:itemIcon(data.itemID));
    row.Item.Text:SetText(PP:itemLink(data.itemID) or data.itemName);
    row.Points:SetText(data.points);
    row.Points:SetTextColor((data.points > 0 and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR):GetRGB());
    row.Minus:SetEnabled(data.points > 0);
    row.Reset:SetEnabled(data.points > 0);
end

local function refreshPoints(raidKey)
    local Panel = Manager.PointsPanel;
    local All = PP:rows(raidKey);
    local needle = strlower(strtrim(State.search or ""));
    local Shown = {};

    for _, Row in ipairs(All) do
        if (matches(needle, Row.key, Row.itemName) and (not State.onlyWithPoints or Row.points > 0)) then
            tinsert(Shown, Row);
        end
    end

    sortRows(Shown, State.Sort.points);
    State.Shown = setRows(Panel.ScrollBox, Shown,
        strjoin("|", raidKey, needle, sortSignature(State.Sort.points), tostring(State.onlyWithPoints)),
        function (Row) return Row.key .. ":" .. Row.itemID; end
    );
    updateArrows(Panel.Headers, State.Sort.points);
    Manager.Empty:SetShown(#Shown == 0);
    Manager.Empty:SetText(#All == 0
        and "No points or reserves in this campaign yet.\n\nSync a softres sheet into it, or select a sheet in the sidebar."
        or "Nothing matches the search.");

    local currentID = PP:currentSheetID(raidKey);
    local Current = PP:sheet(currentID);
    Manager.Status:SetText(("%s  ·  %d of %d entries  ·  current sheet: %s"):format(
        PP:raidLabel(raidKey), #Shown, #All,
        Current and (currentID .. (Current.closedAt and " (closed)" or " (open)")) or "none"
    ));
end

--[[ SHEET VIEW ]]

local function evidenceText(Sheet, key)
    local Parts = {};
    local Seen = Sheet.Seen[key];
    if (Seen) then
        tinsert(Parts, Seen.bosses > 0 and (Seen.bosses .. " bosses") or (Seen.snapshots .. " checks"));
    end
    if (Sheet.Rolled[key]) then
        tinsert(Parts, "rolled");
    end
    if (Sheet.Wins[key]) then
        tinsert(Parts, "won");
    end

    return #Parts > 0 and table.concat(Parts, ", ") or "|cff999999not seen|r", #Parts;
end

local function initSheetRow(row, data)
    if (not row.built) then
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD");

        local x = 4;
        row.Name = cell(row, x, SHEET_COLUMNS[1].width - 8);
        x = x + SHEET_COLUMNS[1].width;

        row.Items = CreateFrame("Button", nil, row);
        row.Items:SetPoint("LEFT", x - 4, 0);
        row.Items:SetSize(SHEET_COLUMNS[2].width - 4, ROW_HEIGHT);
        row.Items.Icons = {};
        for i = 1, 3 do
            local Icon = row.Items:CreateTexture(nil, "ARTWORK");
            Icon:SetSize(16, 16);
            Icon:SetPoint("LEFT", (i - 1) * 18, 0);
            row.Items.Icons[i] = Icon;
        end
        row.Items.Text = row.Items:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
        row.Items.Text:SetPoint("RIGHT", -4, 0);
        row.Items.Text:SetJustifyH("LEFT");
        row.Items.Text:SetWordWrap(false);
        row.Items:SetScript("OnEnter", function (self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetText(row.data.name .. "'s reserves", 1, 1, 1);
            for _, Item in ipairs(row.data.Items) do
                GameTooltip:AddDoubleLine(
                    ("%d. %s"):format(Item.order + 1, PP:itemLink(Item.itemID) or PP:itemName(Item.itemID)),
                    ("%d pts"):format(PP:getPoints(row.data.raid, row.data.key, Item.itemID)),
                    1, 1, 1, 0.8, 0.8, 0.8
                );
            end
            GameTooltip:Show();
        end);
        row.Items:SetScript("OnLeave", GameTooltip_Hide);
        x = x + SHEET_COLUMNS[2].width;

        row.Seen = cell(row, x, SHEET_COLUMNS[3].width - 8, "LEFT", "GameFontHighlightSmall");
        x = x + SHEET_COLUMNS[3].width;

        local function checkbox(columnX, onClick)
            local Check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate");
            Check:SetSize(22, 22);
            Check:SetPoint("LEFT", columnX, 0);
            Check:SetScript("OnClick", onClick);
            Check:SetScript("OnLeave", GameTooltip_Hide);
            return Check;
        end

        row.Attended = checkbox(x + 14, function (self)
            PP:setAttended(row.data.sheet, row.data.key, self:GetChecked() and true or false);
        end);
        row.Attended:SetScript("OnEnter", function (self)
            local evidence = evidenceText(PP:sheet(row.data.sheet), row.data.key);
            showTooltip(self, "Attended", "Recorded: " .. evidence,
                row.data.overridden and "|cffffd100You changed this by hand.|r" or nil,
                "Attended or benched players gain points on their reserves at Close week.");
        end);
        x = x + SHEET_COLUMNS[4].width;

        row.Bench = checkbox(x + 10, function (self)
            PP:setBench(row.data.sheet, row.data.key, self:GetChecked());
        end);
        row.Bench:SetScript("OnEnter", function (self)
            showTooltip(self, "Bench", "Was on the bench and ready to go. Counts the same as attending.");
        end);
        x = x + SHEET_COLUMNS[5].width;

        row.Result = CreateFrame("Button", nil, row);
        row.Result:SetPoint("LEFT", x - 4, 0);
        row.Result:SetSize(SHEET_COLUMNS[6].width - 4, ROW_HEIGHT);
        row.Result.Text = row.Result:CreateFontString(nil, "ARTWORK", "GameFontHighlight");
        row.Result.Text:SetPoint("RIGHT", -8, 0);
        row.Result.Text:SetJustifyH("RIGHT");
        row.Result:SetScript("OnEnter", function (self)
            local Row = row.data;
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetText(Row.closed and "Points this week added" or "Points Close week will add", 1, 1, 1);
            if (#Row.Gains == 0) then
                GameTooltip:AddLine(Row.closed and "Nothing: absent, or won every reserved item."
                    or "Nothing: tick Attended or Bench to give this player points.", 0.7, 0.7, 0.7, true);
            end
            for _, Gain in ipairs(Row.Gains) do
                GameTooltip:AddDoubleLine(
                    PP:itemLink(Gain.itemID) or PP:itemName(Gain.itemID),
                    ("+%d  (now %d)"):format(Gain.delta, Gain.now),
                    1, 1, 1, 0.4, 1, 0.4
                );
            end
            GameTooltip:Show();
        end);
        row.Result:SetScript("OnLeave", GameTooltip_Hide);

        row.built = true;
    end

    row.data = data;
    local closed = data.closed;

    row.Name:SetText(data.name);
    row.Name:SetTextColor(classColor(data.class):GetRGB());

    for i, Icon in ipairs(row.Items.Icons) do
        local Item = data.Items[i];
        Icon:SetShown(Item ~= nil);
        if (Item) then
            Icon:SetTexture(PP:itemIcon(Item.itemID));
        end
    end
    row.Items.Text:SetPoint("LEFT", math.min(#data.Items, 3) * 18 + 2, 0);
    row.Items.Text:SetText(data.itemsText);

    row.Seen:SetText(data.evidence);

    row.Attended:SetChecked(data.attended);
    row.Attended:SetEnabled(not closed);
    row.Bench:SetChecked(data.bench);
    row.Bench:SetEnabled(not closed);

    -- Per item, not summed: "+10 each" for two items, so +20 isn't read as +20 per item
    local text = "|cff999999-|r";
    if (#data.Gains > 0) then
        local low, high = math.huge, -math.huge;
        for _, Gain in ipairs(data.Gains) do
            low, high = math.min(low, Gain.delta), math.max(high, Gain.delta);
        end
        if (low ~= high) then
            text = ("+%d to +%d"):format(low, high); -- The cap trimmed some items
        elseif (#data.Gains > 1) then
            text = ("+%d each"):format(low);
        else
            text = ("+%d"):format(low);
        end
        text = (closed and "|cff00ff00" or "|cffffd100") .. text .. "|r";
    end
    row.Result.Text:SetText(text);
end

local INFO_LABEL_WIDTH, INFO_VALUE_WIDTH, INFO_COLUMN_GAP, INFO_LINE = 78, 200, 14, 15;

--- Label/value grid: 4 rows x 2 columns, a full-width "Bosses" row, then help text
local function createInfo(parent)
    local Info = CreateFrame("Frame", nil, parent);
    Info:SetPoint("TOPLEFT", 10, -8);
    Info:SetPoint("TOPRIGHT", -10, -8);
    Info:SetHeight(108);
    Info.Fields = {};

    local function field(row, column, fullWidth)
        local x = (column - 1) * (INFO_LABEL_WIDTH + INFO_VALUE_WIDTH + INFO_COLUMN_GAP);
        local Label = Info:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
        Label:SetPoint("TOPLEFT", x, -(row - 1) * INFO_LINE);
        Label:SetWidth(INFO_LABEL_WIDTH);
        Label:SetJustifyH("LEFT");

        local Value = Info:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
        Value:SetPoint("TOPLEFT", Label, "TOPRIGHT", 4, 0);
        if (fullWidth) then
            Value:SetPoint("RIGHT", Info, "RIGHT");
        else
            Value:SetWidth(INFO_VALUE_WIDTH);
        end
        Value:SetJustifyH("LEFT");
        Value:SetWordWrap(false);

        tinsert(Info.Fields, { Label = Label, Value = Value, });
    end

    for row = 1, 4 do
        field(row, 1);
        field(row, 2);
    end
    field(5, 1, true);

    Info.Help = Info:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
    Info.Help:SetPoint("TOPLEFT", 0, -5 * INFO_LINE - 6);
    Info.Help:SetPoint("RIGHT");
    Info.Help:SetJustifyH("LEFT");
    Info.Help:SetJustifyV("TOP");
    Info.Help:SetTextColor(0.75, 0.75, 0.75);

    Info:EnableMouse(true);
    return Info;
end

local function fillInfo(Info, id, Sheet)
    local status;
    if (Sheet.closedAt) then
        status = ("|cff999999Closed|r %s by %s"):format(dateOrDash(Sheet.closedAt), Sheet.closedBy or "?");
    elseif (id == PP:activeSheetID()) then
        status = "|cff00ff00Active|r (rolls, wins and attendance count here)";
    else
        status = "|cffffd100Open|r";
    end

    local Bosses = {};
    for _, Boss in ipairs(Sheet.Bosses) do
        tinsert(Bosses, ("%s (%d)"):format(Boss.name, Boss.count or 0));
    end

    local Values = {
        { "Campaign", PP:raidLabel(Sheet.raidKey), },
        { "Softres ID", id, },
        { "Created", dateOrDash(Sheet.createdAt), },
        { "Raid starts", dateOrDash(Sheet.raidStartsAt), },
        { "Locked", Sheet.lockedAt and ("|cff00ff00" .. dateOrDash(Sheet.lockedAt) .. "|r") or "|cffff6060not locked yet|r", },
        { "Status", status, },
        { "First synced", dateOrDash(Sheet.firstSyncedAt), },
        { "Last synced", ("%s  |cff999999(%d syncs, hover for history)|r"):format(dateOrDash(Sheet.lastSyncedAt), #Sheet.Syncs), },
        { "Bosses", #Bosses > 0 and table.concat(Bosses, ", ") or "|cff999999none recorded yet|r", },
    };

    for i, Field in ipairs(Info.Fields) do
        Field.Label:SetText(Values[i][1]);
        Field.Value:SetText(Values[i][2]);
    end

    if (Sheet.closedAt) then
        Info.Help:SetText("This week is closed and its points were added (Points column, per item; hover for details).\nReopen the week to change attendance; that takes those points back off.");
    else
        Info.Help:SetText("Attended is pre-ticked from boss kills, raid checks and rolls. Tick Bench for players who were ready to go.\nThe Points column previews what each reserved item gains. After the raid week, click Close week to add them.");
    end
end

local function sheetHistoryTooltip(owner, id)
    local Sheet = PP:sheet(id);
    if (not Sheet) then
        return;
    end

    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM");
    GameTooltip:SetText("Sync history: " .. id, 1, 1, 1);
    for _, Sync in ipairs(Sheet.Syncs) do
        local what = Sync.first and ("first sync, %d reserves"):format(Sync.reserves or 0)
            or ("+%d / -%d reserves"):format(#(Sync.Added or {}), #(Sync.Removed or {}));
        GameTooltip:AddDoubleLine(date("%Y-%m-%d %H:%M", Sync.at), what, 0.8, 0.8, 0.8, 1, 1, 1);
        for _, Change in ipairs(Sync.Added or {}) do
            GameTooltip:AddLine(("   + %s: %s"):format(PP:displayName(Change[1]), PP:itemName(Change[2])), 0.4, 1, 0.4);
        end
        for _, Change in ipairs(Sync.Removed or {}) do
            GameTooltip:AddLine(("   - %s: %s"):format(PP:displayName(Change[1]), PP:itemName(Change[2])), 1, 0.4, 0.4);
        end
    end
    if (Sheet.note) then
        GameTooltip:AddLine(" ");
        GameTooltip:AddLine(Sheet.note, 0.7, 0.7, 0.7, true);
    end
    GameTooltip:Show();
end

local function refreshSheet(id)
    local Panel = Manager.SheetPanel;
    local Sheet = PP:sheet(id);
    local needle = strlower(strtrim(State.search or ""));
    local closed = Sheet.closedAt ~= nil;
    local Rows = {};
    local attended, bench, absent = 0, 0, 0;

    -- Closed: what Close week added. Open: what it would add right now.
    local GainsByPlayer = {};
    if (closed) then
        for key, Items in pairs(PP:weekGains(id)) do
            GainsByPlayer[key] = {};
            for itemID, delta in pairs(Items) do
                tinsert(GainsByPlayer[key], { itemID = itemID, delta = delta, now = PP:getPoints(Sheet.raidKey, key, itemID), });
            end
        end
    else
        for _, Award in ipairs(PP:closeWeekPlan(id).Awards) do
            GainsByPlayer[Award.key] = GainsByPlayer[Award.key] or {};
            tinsert(GainsByPlayer[Award.key], { itemID = Award.itemID, delta = Award.to - Award.from, now = Award.to, });
        end
    end

    for key, Reserved in pairs(Sheet.Reserves) do
        local Items, Names = {}, {};
        for itemID, order in pairs(Reserved) do
            tinsert(Items, { itemID = itemID, order = order or 0, });
        end
        table.sort(Items, function (a, b) return a.order < b.order; end);
        for _, Item in ipairs(Items) do
            tinsert(Names, PP:itemName(Item.itemID));
        end

        local isAttended, isBench = PP:isAttended(Sheet, key), Sheet.Bench[key] == true;
        if (isAttended) then
            attended = attended + 1;
        elseif (isBench) then
            bench = bench + 1;
        else
            absent = absent + 1;
        end

        local itemsText = table.concat(Names, ", ");
        if (matches(needle, key, itemsText)) then
            local evidence, evidenceRank = evidenceText(Sheet, key);
            local Gains, total = GainsByPlayer[key] or {}, 0;
            for _, Gain in ipairs(Gains) do
                total = total + Gain.delta;
            end
            table.sort(Gains, function (a, b) return (Reserved[a.itemID] or 0) < (Reserved[b.itemID] or 0); end);
            tinsert(Rows, {
                sheet = id,
                raid = Sheet.raidKey,
                key = key,
                name = PP:displayName(key),
                class = playerClass(key, Sheet),
                Items = Items,
                itemsText = itemsText,
                evidence = evidence,
                evidenceRank = evidenceRank,
                attended = isAttended,
                attendedRank = isAttended and 1 or 0,
                overridden = Sheet.Override[key] ~= nil,
                bench = isBench,
                benchRank = isBench and 1 or 0,
                closed = closed,
                Gains = Gains,
                result = total,
            });
        end
    end

    sortRows(Rows, State.Sort.sheet);

    fillInfo(Panel.Info, id, Sheet);
    Panel.Info.sheetID = id;
    setRows(Panel.ScrollBox, Rows,
        strjoin("|", id, needle, sortSignature(State.Sort.sheet)),
        function (Row) return Row.key; end
    );
    updateArrows(Panel.Headers, State.Sort.sheet);
    Manager.Empty:SetShown(#Rows == 0);
    Manager.Empty:SetText("Nothing matches the search.");

    Manager.Status:SetText(("%d players reserved  ·  %d attended  ·  %d bench  ·  %d absent"):format(
        attended + bench + absent, attended, bench, absent
    ));

    Manager.CloseWeek:SetText(closed and "Reopen week" or "Close week");
end

--[[ REFRESH ]]

function PP:refreshManager()
    if (not Manager or not Manager:IsShown()) then
        return;
    end

    local kind, id = selected();

    -- The sidebar is already in order, so its signature is its rows: any change in the list rebuilds it
    local Sidebar = sidebarData();
    local SidebarIDs = {};
    for i, Row in ipairs(Sidebar) do
        SidebarIDs[i] = Row.kind .. ":" .. Row.id;
    end
    setRows(Manager.Sidebar.ScrollBox, Sidebar, table.concat(SidebarIDs, "|"),
        function (Row) return Row.kind .. ":" .. Row.id; end
    );

    Manager.PointsPanel:SetShown(kind == "raid");
    Manager.SheetPanel:SetShown(kind == "sheet");
    Manager.OnlyPoints:SetShown(kind == "raid");
    Manager.Export:SetShown(kind == "raid");
    Manager.EditCampaign:SetShown(kind == "raid" and id ~= PP.UNASSIGNED);
    Manager.CloseWeek:SetShown(kind == "sheet");

    if (kind == "raid") then
        refreshPoints(id);
    elseif (kind == "sheet") then
        refreshSheet(id);
    else
        Manager.Empty:Show();
        Manager.Empty:SetText("No campaigns yet.\n\nClick |cffffd100New campaign|r to set up a team and raid with its rules, then import a softres.it sheet in Gargul (|cffffd100/gl sr|r) and click |cffffd100Sync SR|r.");
        Manager.Status:SetText("");
    end
end

-- Item names and timer snapshots arrive in bursts, refresh at most a few times a second
local refreshQueued = false;
local function queueRefresh()
    if (refreshQueued) then
        return;
    end
    refreshQueued = true;

    C_Timer.After(0.25, function ()
        refreshQueued = false;
        PP:refreshManager();
    end);
end

--[[ DIALOGS ]]

local CONFIRM_WIDTH, CONFIRM_LABEL_WIDTH = 400, 110;
local Confirm;

local function createConfirm()
    local f = CreateFrame("Frame", "GargulPityPointsConfirm", UIParent, "BasicFrameTemplateWithInset");
    f:SetWidth(CONFIRM_WIDTH);
    f:SetPoint("CENTER", 0, 80);
    f:SetFrameStrata("DIALOG");
    f:SetToplevel(true);
    f:EnableMouse(true);
    f:Hide();
    tinsert(UISpecialFrames, f:GetName());

    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight");
    f.Title:SetPoint("TOP", 0, -5);

    f.Heading = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge");
    f.Heading:SetPoint("TOPLEFT", 16, -36);
    f.Heading:SetPoint("RIGHT", -16, 0);
    f.Heading:SetJustifyH("LEFT");

    f.Fields = {};

    f.Note = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
    f.Note:SetJustifyH("LEFT");
    f.Note:SetJustifyV("TOP");
    f.Note:SetTextColor(0.75, 0.75, 0.75);

    f.Accept = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    f.Accept:SetSize(120, 22);
    f.Accept:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 12);
    f.Accept:SetScript("OnClick", function ()
        f:Hide();
        f.onAccept();
    end);

    f.Cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    f.Cancel:SetSize(120, 22);
    f.Cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 12);
    f.Cancel:SetText(CANCEL);
    f.Cancel:SetScript("OnClick", function () f:Hide(); end);

    return f;
end

--- A confirmation laid out as a label/value table: { title, heading, Fields = { { label, value } }, note, accept, onAccept }
local function showConfirm(Options)
    Confirm = Confirm or createConfirm();
    local f = Confirm;

    f.Title:SetText(Options.title);
    f.Heading:SetText(Options.heading);
    f.Accept:SetText(Options.accept);
    f.onAccept = Options.onAccept;

    local y = -36 - f.Heading:GetStringHeight() - 12;
    for i, Values in ipairs(Options.Fields) do
        local Field = f.Fields[i];
        if (not Field) then
            Field = {
                Label = f:CreateFontString(nil, "ARTWORK", "GameFontNormal"),
                Value = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight"),
            };
            Field.Label:SetWidth(CONFIRM_LABEL_WIDTH);
            Field.Label:SetJustifyH("LEFT");
            Field.Value:SetPoint("TOPLEFT", Field.Label, "TOPRIGHT", 6, 0);
            Field.Value:SetPoint("RIGHT", f, "RIGHT", -16, 0);
            Field.Value:SetJustifyH("LEFT");
            f.Fields[i] = Field;
        end

        Field.Label:SetPoint("TOPLEFT", 16, y);
        Field.Label:SetText(Values[1]);
        Field.Value:SetText(Values[2]);
        Field.Label:Show();
        Field.Value:Show();
        y = y - math.max(Field.Value:GetStringHeight(), 14) - 6;
    end
    for i = #Options.Fields + 1, #f.Fields do
        f.Fields[i].Label:Hide();
        f.Fields[i].Value:Hide();
    end

    f.Note:ClearAllPoints();
    f.Note:SetPoint("TOPLEFT", 16, y - 6);
    f.Note:SetPoint("RIGHT", -16, 0);
    f.Note:SetText(Options.note or "");
    local noteHeight = Options.note and (f.Note:GetStringHeight() + 6) or 0;

    f:SetHeight(-y + noteHeight + 52);
    f:Show();
    f:Raise();
end

local function players(count)
    return count == 1 and "1 player" or (count .. " players");
end

function confirmCloseWeek(id)
    local Sheet = PP:sheet(id);
    local Rules = PP:rules(Sheet.raidKey);

    if (Sheet.closedAt) then
        local items, points = 0, 0;
        for _, Items in pairs(PP:weekGains(id)) do
            for _, delta in pairs(Items) do
                items, points = items + 1, points + delta;
            end
        end

        showConfirm({
            title = "Reopen week",
            heading = "Reopen this week?",
            Fields = {
                { "Campaign", PP:raidLabel(Sheet.raidKey), },
                { "Softres sheet", id, },
                { "Closed", ("%s by %s"):format(dateOrDash(Sheet.closedAt), Sheet.closedBy or "?"), },
                { "Taken back", ("|cffff6060%d points|r from %d items"):format(points, items), },
            },
            note = "The points Close week added are taken off again. Attendance, bench and everything else stays, so you can fix it and close again.",
            accept = "Reopen week",
            onAccept = function () PP:reopenWeek(id); end,
        });
        return;
    end

    local Plan = PP:closeWeekPlan(id);
    local gaining = {};
    for _, Award in ipairs(Plan.Awards) do
        gaining[Award.key] = true;
    end
    local gainingPlayers = 0;
    for _ in pairs(gaining) do
        gainingPlayers = gainingPlayers + 1;
    end

    local Notes = {
        "Attended and benched players gain points on each item they reserved, except items they won. Absent players get nothing.",
    };
    if (not Sheet.lockedAt) then
        tinsert(Notes, "|cffff6060This sheet isn't locked on softres.it, reserves may still change.|r");
    end

    showConfirm({
        title = "Close week",
        heading = "Close this week and add points?",
        Fields = {
            { "Campaign", PP:raidLabel(Sheet.raidKey), },
            { "Softres sheet", id, },
            { "Attended", players(Plan.attended), },
            { "Bench", players(Plan.bench), },
            { "Absent", ("%s  |cff999999(no points)|r"):format(players(Plan.absent)), },
            { "Points", ("|cff00ff00+%d|r on each reserved item%s"):format(Rules.perWeek, Rules.cap > 0 and (" (cap " .. Rules.cap .. ")") or ""), },
            { "Items gaining", ("%d items across %s"):format(#Plan.Awards, players(gainingPlayers)), },
        },
        note = table.concat(Notes, "\n\n"),
        accept = "Close week",
        onAccept = function () PP:closeWeek(id); end,
    });
end

--[[ WINDOW ]]

local function createManager()
    local f = CreateFrame("Frame", "GargulPityPointsManager", UIParent, "ButtonFrameTemplate");
    f:SetSize(840, 520);
    f:SetPoint("CENTER");
    f:SetToplevel(true);
    f:SetMovable(true);
    f:SetClampedToScreen(true);
    f:EnableMouse(true);
    f:RegisterForDrag("LeftButton");
    f:SetScript("OnDragStart", f.StartMoving);
    f:SetScript("OnDragStop", f.StopMovingOrSizing);
    f:Hide();
    tinsert(UISpecialFrames, f:GetName()); -- Escape closes it

    f.TitleText:SetText(PP.title);
    -- Classic's template has two portrait textures; the visible one is PortraitContainer.portrait, above the border
    if (f.SetPortraitToAsset and f.PortraitContainer) then
        f:SetPortraitToAsset(PP.icon);
    end
    if (f.portrait) then
        f.portrait:SetTexture(PP.icon);
    end

    -- Sidebar inset on the left, the template's inset becomes the main area
    local Sidebar = CreateFrame("Frame", nil, f, "InsetFrameTemplate");
    Sidebar:SetPoint("TOPLEFT", 4, -60);
    Sidebar:SetPoint("BOTTOMLEFT", 4, 52);
    Sidebar:SetWidth(SIDEBAR_WIDTH);
    Sidebar.ScrollBox = createList(Sidebar, -4, initSidebarRow);
    f.Sidebar = Sidebar;

    local NewCampaign = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    NewCampaign:SetHeight(22);
    NewCampaign:SetPoint("TOPLEFT", Sidebar, "BOTTOMLEFT", 0, -2);
    NewCampaign:SetPoint("TOPRIGHT", Sidebar, "BOTTOMRIGHT", 0, -2);
    NewCampaign:SetText("New campaign");
    NewCampaign:SetScript("OnClick", function ()
        PP:showCampaignEditor({
            onSave = function (raidKey) selectEntry("raid", raidKey); end,
        });
    end);
    NewCampaign:SetScript("OnEnter", function (self)
        showTooltip(self, "New campaign",
            "A team and raid with its own rules: SRs per week, points per week, cap and resets. Softres sheets are synced into a campaign.");
    end);
    NewCampaign:SetScript("OnLeave", GameTooltip_Hide);

    local Inset = f.Inset;
    Inset:ClearAllPoints();
    Inset:SetPoint("TOPLEFT", Sidebar, "TOPRIGHT", 2, 0);
    Inset:SetPoint("BOTTOMRIGHT", -6, 26);

    -- Top bar: search, filter, sync
    local Search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate");
    Search:SetSize(200, 20);
    Search:SetPoint("TOPLEFT", Inset, "TOPLEFT", 6, 26);
    Search.Instructions:SetText("Search player or item");
    Search:HookScript("OnTextChanged", function (self)
        State.search = self:GetText();
        PP:refreshManager();
    end);
    f.Search = Search;

    local OnlyPoints = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate");
    OnlyPoints:SetSize(24, 24);
    OnlyPoints:SetPoint("LEFT", Search, "RIGHT", 10, 0);
    OnlyPoints.Text:SetText("Only with points");
    OnlyPoints.Text:SetFontObject("GameFontHighlightSmall");
    OnlyPoints:SetScript("OnClick", function (self)
        State.onlyWithPoints = self:GetChecked();
        PP:refreshManager();
    end);
    f.OnlyPoints = OnlyPoints;

    local Sync = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    Sync:SetSize(96, 22);
    Sync:SetPoint("TOPRIGHT", -10, -32);
    Sync:SetText("Sync SR");
    Sync:SetScript("OnClick", function () PP:syncFromGargul(); end);
    Sync:SetScript("OnEnter", function (self)
        showTooltip(self, "Sync soft reserves",
            "Read the soft reserves imported in Gargul. A new softres id starts a new sheet in a campaign you pick (or create), and resets items that weren't reserved again if the campaign says so. A known id just updates the sheet's reserves.");
    end);
    Sync:SetScript("OnLeave", GameTooltip_Hide);

    -- Points panel
    local PointsPanel = CreateFrame("Frame", nil, Inset);
    PointsPanel:SetAllPoints();
    PointsPanel.Headers = createHeaders(PointsPanel, POINT_COLUMNS, "points");
    PointsPanel.ScrollBox = createList(PointsPanel, -28, initPointRow);
    f.PointsPanel = PointsPanel;

    -- Sheet panel: info block, headers, checklist
    local SheetPanel = CreateFrame("Frame", nil, Inset);
    SheetPanel:SetAllPoints();
    SheetPanel.Info = createInfo(SheetPanel);
    SheetPanel.Info:SetScript("OnEnter", function (self) sheetHistoryTooltip(self, self.sheetID); end);
    SheetPanel.Info:SetScript("OnLeave", GameTooltip_Hide);

    local HeaderBar = CreateFrame("Frame", nil, SheetPanel);
    HeaderBar:SetPoint("TOPLEFT", 0, -122);
    HeaderBar:SetPoint("BOTTOMRIGHT");
    SheetPanel.Headers = createHeaders(HeaderBar, SHEET_COLUMNS, "sheet");
    SheetPanel.ScrollBox = createList(HeaderBar, -28, initSheetRow);
    f.SheetPanel = SheetPanel;

    f.Empty = Inset:CreateFontString(nil, "OVERLAY", "GameFontDisable");
    f.Empty:SetPoint("CENTER", 0, -20);
    f.Empty:SetWidth(420);

    -- Bottom bar: status, actions
    f.Status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
    f.Status:SetPoint("BOTTOMLEFT", 12, 8);
    f.Status:SetPoint("RIGHT", f, "BOTTOMRIGHT", -400, 0);
    f.Status:SetJustifyH("LEFT");
    f.Status:SetWordWrap(false);

    local function bottomButton(text, width, anchor, onClick)
        local Button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
        Button:SetSize(width, 22);
        Button:SetText(text);
        if (anchor) then
            Button:SetPoint("RIGHT", anchor, "LEFT", -2, 0);
        else
            Button:SetPoint("BOTTOMRIGHT", -6, 3);
        end
        Button:SetScript("OnClick", onClick);
        return Button;
    end

    local SettingsButton = bottomButton("Settings", 80, nil, function () PP:openSettings(); end);
    local Log = bottomButton("Log", 70, SettingsButton, function ()
        local kind, id = selected();
        PP:showLog(kind == "raid" and id or (kind == "sheet" and PP:sheet(id).raidKey) or nil);
    end);

    f.Export = bottomButton("Export CSV", 96, Log, function ()
        PP:showExport(PP:buildCSV(State.Shown), #State.Shown, "points");
    end);
    f.Export:SetScript("OnEnter", function (self)
        showTooltip(self, "Export CSV", "Exports the rows currently listed. Clear the search to export the whole raid.");
    end);
    f.Export:SetScript("OnLeave", GameTooltip_Hide);

    f.EditCampaign = bottomButton("Edit campaign", 110, f.Export, function ()
        local kind, id = selected();
        if (kind == "raid") then
            PP:showCampaignEditor({ raidKey = id, });
        end
    end);
    f.EditCampaign:SetScript("OnEnter", function (self)
        local kind, id = selected();
        showTooltip(self, "Edit campaign", kind == "raid" and PP:rulesText(id) or nil,
            "Change this campaign's rules. Changes apply from the next sync and Close week; points already given stay.");
    end);
    f.EditCampaign:SetScript("OnLeave", GameTooltip_Hide);

    f.CloseWeek = bottomButton("Close week", 110, Log, function ()
        local kind, id = selected();
        if (kind == "sheet") then
            confirmCloseWeek(id);
        end
    end);

    f:SetScript("OnShow", function () PP:refreshManager(); end);
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED");
    f:SetScript("OnEvent", function (self)
        if (self:IsShown()) then
            queueRefresh();
        end
    end);

    PP.RegisterCallback(f, "POINTS_CHANGED", queueRefresh);

    return f;
end

--[[ PUBLIC ]]

function PP:openManager()
    Manager = Manager or createManager();
    Manager:Show();
    Manager:Raise();
end

function PP:toggleManager()
    if (Manager and Manager:IsShown()) then
        Manager:Hide();
    else
        self:openManager();
    end
end

function PP:setManagerSearch(text)
    self:openManager();
    Manager.Search:SetText(text or "");
    Manager.Search:ClearFocus();
end
