--[[
    CSV export window. Add-ons can't write files, so the CSV is shown as selectable text to copy.
]]

local _, PP = ...;

local Export;

local function createExport()
    local f = CreateFrame("Frame", "GargulPityPointsExport", UIParent, "BasicFrameTemplateWithInset");
    f:SetSize(560, 420);
    f:SetPoint("CENTER", 40, -40);
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
    f.Title:SetText(PP.title .. ": CSV export");

    f.Hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall");
    f.Hint:SetPoint("TOPLEFT", 14, -32);
    f.Hint:SetPoint("RIGHT", -14, 0);
    f.Hint:SetJustifyH("LEFT");

    local Edit = CreateFrame("Frame", nil, f, "ScrollingEditBoxTemplate");
    Edit:SetPoint("TOPLEFT", 14, -52);
    Edit:SetPoint("BOTTOMRIGHT", -32, 40);
    f.Edit = Edit;

    local ScrollBar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar");
    ScrollBar:SetPoint("TOPLEFT", Edit, "TOPRIGHT", 8, 0);
    ScrollBar:SetPoint("BOTTOMLEFT", Edit, "BOTTOMRIGHT", 8, 0);
    ScrollUtil.RegisterScrollBoxWithScrollBar(Edit:GetScrollBox(), ScrollBar);

    -- Keep the text as exported: typing restores it, so a stray key can't corrupt the copy
    Edit:GetEditBox():HookScript("OnTextChanged", function (self, userInput)
        if (userInput) then
            self:SetText(f.csv or "");
            self:HighlightText();
        end
    end);

    local SelectAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    SelectAll:SetSize(110, 22);
    SelectAll:SetPoint("BOTTOMLEFT", 12, 10);
    SelectAll:SetText("Select all");
    SelectAll:SetScript("OnClick", function ()
        Edit:SetFocus();
        Edit:GetEditBox():HighlightText();
    end);

    local Close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    Close:SetSize(90, 22);
    Close:SetPoint("BOTTOMRIGHT", -12, 10);
    Close:SetText(CLOSE);
    Close:SetScript("OnClick", function () f:Hide(); end);

    return f;
end

--- Show CSV text to copy. count/what only label the hint ("12 points rows").
function PP:showExport(csv, count, what)
    Export = Export or createExport();
    Export.csv = csv;
    Export.Hint:SetText(("%d %s rows. Press Ctrl+C to copy, then paste into a spreadsheet or a .csv file."):format(count, what or ""));
    Export:Show();
    Export:Raise();

    Export.Edit:SetText(Export.csv);
    Export.Edit:SetFocus();
    Export.Edit:GetEditBox():HighlightText();
end
