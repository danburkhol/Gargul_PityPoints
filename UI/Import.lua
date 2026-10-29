--[[
    CSV import window: paste the points export CSV, preview the changes, then import. Logic in Import.lua.
]]

local _, PP = ...;

local MAX_PREVIEW_LINES = 400;

local Import;

local function red(text)
    return "|cffff6060" .. text .. "|r";
end

local function previewText(Plan)
    local Lines = {};

    if (#Plan.Errors > 0) then
        tinsert(Lines, red(("%d error%s. Fix the CSV and preview again; nothing is imported while there are errors."):format(
            #Plan.Errors, #Plan.Errors == 1 and "" or "s"
        )));
        for _, message in ipairs(Plan.Errors) do
            tinsert(Lines, "  " .. message);
        end
        tinsert(Lines, "");
    end

    tinsert(Lines, ("%d rows  ·  %d change%s  ·  %d already the same"):format(
        Plan.rows, #Plan.Changes, #Plan.Changes == 1 and "" or "s", Plan.unchanged
    ));

    if (#Plan.Errors == 0 and #Plan.Changes == 0 and Plan.rows > 0) then
        tinsert(Lines, "Every row already matches the stored points. Nothing to import.");
    end

    -- Changes grouped by campaign, players A -> Z
    local ByRaid = {};
    for _, Change in ipairs(Plan.Changes) do
        ByRaid[Change.raidKey] = ByRaid[Change.raidKey] or {};
        tinsert(ByRaid[Change.raidKey], Change);
    end

    local shown = 0;
    for _, raidKey in ipairs(PP:raidKeys()) do
        local Changes = ByRaid[raidKey];
        if (Changes) then
            table.sort(Changes, function (a, b)
                if (a.key ~= b.key) then
                    return a.key < b.key;
                end
                return a.itemID < b.itemID;
            end);

            tinsert(Lines, "");
            tinsert(Lines, ("|cffffd100%s|r: %d change%s"):format(PP:raidLabel(raidKey), #Changes, #Changes == 1 and "" or "s"));
            for _, Change in ipairs(Changes) do
                shown = shown + 1;
                if (shown > MAX_PREVIEW_LINES) then
                    break;
                end
                tinsert(Lines, ("  %s  ·  %s  ·  %d -> %d"):format(
                    PP:displayName(Change.key), PP:itemName(Change.itemID), Change.before, Change.after
                ));
            end
        end
    end

    if (shown > MAX_PREVIEW_LINES) then
        tinsert(Lines, ("  ... and %d more"):format(#Plan.Changes - MAX_PREVIEW_LINES));
    end

    return table.concat(Lines, "\n");
end

local function scrollingText(f, ScrollBar)
    local Edit = CreateFrame("Frame", nil, f, "ScrollingEditBoxTemplate");
    ScrollBar:SetPoint("TOPLEFT", Edit, "TOPRIGHT", 8, 0);
    ScrollBar:SetPoint("BOTTOMLEFT", Edit, "BOTTOMRIGHT", 8, 0);
    ScrollUtil.RegisterScrollBoxWithScrollBar(Edit:GetScrollBox(), ScrollBar);

    local Background = f:CreateTexture(nil, "BACKGROUND", nil, 1);
    Background:SetPoint("TOPLEFT", Edit, -4, 4);
    Background:SetPoint("BOTTOMRIGHT", Edit, 4, -4);
    Background:SetColorTexture(0, 0, 0, 0.35);

    return Edit;
end

local function setPlan(Plan)
    Import.Plan = Plan;
    Import.ImportButton:SetEnabled(Plan ~= nil and Plan.ok);
end

local function createImport()
    local f = CreateFrame("Frame", "GargulPityPointsImport", UIParent, "BasicFrameTemplateWithInset");
    f:SetSize(640, 560);
    f:SetPoint("CENTER", 20, -20);
    f:SetToplevel(true);
    f:SetFrameStrata("DIALOG");
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
    f.Title:SetText(PP.title .. ": CSV import");

    local Hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
    Hint:SetPoint("TOPLEFT", 14, -32);
    Hint:SetPoint("RIGHT", -14, 0);
    Hint:SetJustifyH("LEFT");
    Hint:SetText("Paste a CSV in the Export CSV format, header row first:\n"
        .. "|cffffffffteam,raid,player,item_id,item_name,points,reserved|r\n"
        .. "Each row sets that player's points on that item in an existing campaign. Points not in the CSV stay as they are.");

    local PasteBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar");
    local Paste = scrollingText(f, PasteBar);
    Paste:SetPoint("TOPLEFT", 18, -88);
    Paste:SetPoint("RIGHT", -36, 0);
    Paste:SetHeight(170);
    Paste:GetEditBox():SetMaxLetters(0);
    f.Paste = Paste;

    local PreviewLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal");
    PreviewLabel:SetPoint("TOPLEFT", Paste, "BOTTOMLEFT", -4, -12);
    PreviewLabel:SetText("Preview");

    local PreviewBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar");
    local Preview = scrollingText(f, PreviewBar);
    Preview:SetPoint("TOPLEFT", PreviewLabel, "BOTTOMLEFT", 4, -8);
    Preview:SetPoint("BOTTOMRIGHT", -36, 44);
    f.Preview = Preview;

    -- The preview is read-only: typing restores it
    Preview:GetEditBox():HookScript("OnTextChanged", function (self, userInput)
        if (userInput) then
            self:SetText(f.previewText or "");
        end
    end);

    local function showPreview(text)
        f.previewText = text;
        Preview:SetText(text);
    end
    f.showPreview = showPreview;

    -- Any edit to the pasted text needs a new preview before importing
    Paste:GetEditBox():HookScript("OnTextChanged", function (_, userInput)
        if (userInput and f.Plan) then
            setPlan(nil);
            showPreview("The CSV changed. Click Preview to check it again.");
        end
    end);

    local PreviewButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    PreviewButton:SetSize(100, 22);
    PreviewButton:SetPoint("BOTTOMLEFT", 12, 12);
    PreviewButton:SetText("Preview");
    PreviewButton:SetScript("OnClick", function ()
        Paste:ClearFocus();
        local Plan = PP:planImport(Paste:GetInputText());
        setPlan(Plan);
        showPreview(previewText(Plan));
    end);

    local ImportButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    ImportButton:SetSize(100, 22);
    ImportButton:SetPoint("LEFT", PreviewButton, "RIGHT", 4, 0);
    ImportButton:SetText("Import");
    ImportButton:SetScript("OnClick", function ()
        local Plan = f.Plan;
        local id = PP:applyImport(Plan);
        setPlan(nil);
        if (id) then
            local text = ("Imported %d change%s from %d rows. To undo, open the Log and click an \"Imported\" entry."):format(
                #Plan.Changes, #Plan.Changes == 1 and "" or "s", Plan.rows
            );
            showPreview(text);
            PP:print(text);
        end
    end);
    f.ImportButton = ImportButton;

    local Close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    Close:SetSize(90, 22);
    Close:SetPoint("BOTTOMRIGHT", -12, 12);
    Close:SetText(CLOSE);
    Close:SetScript("OnClick", function () f:Hide(); end);

    return f;
end

function PP:showImport()
    Import = Import or createImport();
    Import:Show();
    Import:Raise();

    if (not Import.Plan) then
        setPlan(nil);
        Import.showPreview("Paste the CSV above, then click Preview. Nothing changes until you click Import.");
    end
end
