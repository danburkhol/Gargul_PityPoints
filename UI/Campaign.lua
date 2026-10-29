--[[
    Campaigns: a team + raid (DB.Raids[raidKey]) with its own Rules (PP.RULE_DEFAULTS).
      Editor: create a campaign, or edit an existing one's rules (team and raid are fixed once created).
      Picker: shown when a new softres sheet is synced; the sheet goes into the campaign picked or created here.
]]

local _, PP = ...;

local WIDTH, LABEL_WIDTH, LINE = 400, 140, 28;
local Editor, Picker;

--[[ HELPERS ]]

local function createDialog(name, title)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset");
    f:SetWidth(WIDTH);
    f:SetPoint("CENTER", 0, 80);
    f:SetFrameStrata("DIALOG");
    f:SetToplevel(true);
    f:EnableMouse(true);
    f:SetMovable(true);
    f:RegisterForDrag("LeftButton");
    f:SetScript("OnDragStart", f.StartMoving);
    f:SetScript("OnDragStop", f.StopMovingOrSizing);
    f:Hide();
    tinsert(UISpecialFrames, name);

    f.Title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight");
    f.Title:SetPoint("TOP", 0, -5);
    f.Title:SetText(title);

    return f;
end

local function createLabel(f, text, y)
    local Label = f:CreateFontString(nil, "ARTWORK", "GameFontNormal");
    Label:SetPoint("TOPLEFT", 16, y);
    Label:SetWidth(LABEL_WIDTH);
    Label:SetJustifyH("LEFT");
    Label:SetText(text);
    return Label;
end

local function createButton(f, text, width)
    local Button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate");
    Button:SetSize(width, 22);
    Button:SetText(text);
    return Button;
end

local function createNote(f)
    local Note = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
    Note:SetJustifyH("LEFT");
    Note:SetJustifyV("TOP");
    Note:SetTextColor(0.75, 0.75, 0.75);
    return Note;
end

local function tooltipOnEnter(owner, title, text)
    owner:SetScript("OnEnter", function (self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:SetText(title, 1, 1, 1);
        GameTooltip:AddLine(text, nil, nil, nil, true);
        GameTooltip:Show();
    end);
    owner:SetScript("OnLeave", GameTooltip_Hide);
end

local function instancesText(Instances)
    local Names = {};
    for _, slug in ipairs(Instances or {}) do
        tinsert(Names, PP:instanceName(slug));
    end
    return table.concat(Names, " + ");
end

--[[ EDITOR ]]

--- Raids the editor offers: PP.RAID_CHOICES, with the prefilled sheet's own slugs swapped in (or added) by name
local function raidEntries(Prefill)
    local Entries = {};
    for _, Group in ipairs(PP.RAID_CHOICES) do
        for _, slug in ipairs(Group[2]) do
            tinsert(Entries, { slug = slug, name = PP:instanceName(slug), group = Group[1], });
        end
    end

    for _, slug in ipairs(Prefill or {}) do
        local found = false;
        for _, Entry in ipairs(Entries) do
            if (Entry.name == PP:instanceName(slug)) then
                Entry.slug, found = slug, true;
                break;
            end
        end
        if (not found) then
            tinsert(Entries, { slug = slug, name = PP:instanceName(slug), group = "From this sheet", });
        end
    end

    return Entries;
end

local function createNumberRow(f, text, y, hint, tooltip)
    local Label = createLabel(f, text, y);

    local Box = CreateFrame("EditBox", nil, f, "InputBoxTemplate");
    Box:SetSize(44, 20);
    Box:SetPoint("LEFT", Label, "RIGHT", 10, 0);
    Box:SetAutoFocus(false);
    Box:SetNumeric(true);
    Box:SetMaxLetters(3);
    Box:SetJustifyH("CENTER");
    Box:SetScript("OnEscapePressed", Box.ClearFocus);
    Box:SetScript("OnEnterPressed", Box.ClearFocus);
    tooltipOnEnter(Box, text, tooltip);

    local Hint = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall");
    Hint:SetPoint("LEFT", Box, "RIGHT", 8, 0);
    Hint:SetTextColor(0.6, 0.6, 0.6);
    Hint:SetText(hint or "");

    return Box;
end

local function createCheckRow(f, text, y, tooltip)
    local Check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate");
    Check:SetSize(24, 24);
    Check:SetPoint("TOPLEFT", 12, y + 5);
    Check.Text:SetText(text);
    tooltipOnEnter(Check, text, tooltip);
    return Check;
end

local function createEditor()
    local f = createDialog("GargulPityPointsCampaign", "Campaign");

    f.Heading = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge");
    f.Heading:SetPoint("TOPLEFT", 16, -34);
    f.Heading:SetPoint("RIGHT", -16, 0);
    f.Heading:SetJustifyH("LEFT");

    local y = -68;

    -- Team: free text, with the known teams one click away
    local TeamLabel = createLabel(f, "Team", y);
    f.Team = CreateFrame("EditBox", nil, f, "InputBoxTemplate");
    f.Team:SetSize(120, 20);
    f.Team:SetPoint("LEFT", TeamLabel, "RIGHT", 10, 0);
    f.Team:SetAutoFocus(false);
    f.Team:SetMaxLetters(32);
    f.Team:SetScript("OnEscapePressed", f.Team.ClearFocus);
    f.Team:SetScript("OnEnterPressed", f.Team.ClearFocus);

    f.Teams = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate");
    f.Teams:SetWidth(90);
    f.Teams:SetPoint("LEFT", f.Team, "RIGHT", 6, 0);
    f.Teams:OverrideText("Teams");
    f.Teams:SetupMenu(function (_, Root)
        for _, team in ipairs(PP.db.Teams) do
            Root:CreateButton(team, function () f.Team:SetText(team); end);
        end
    end);
    y = y - LINE;

    -- Raid: one or more instances, a combined sheet (Hyjal + BT) is one campaign
    local RaidLabel = createLabel(f, "Raid", y);
    f.Raid = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate");
    f.Raid:SetWidth(216);
    f.Raid:SetPoint("LEFT", RaidLabel, "RIGHT", 6, 0);
    f.Raid:SetDefaultText("Pick the raid");
    f.Raid:SetupMenu(function (_, Root)
        local group;
        for i, Entry in ipairs(f.Entries or {}) do
            if (Entry.group ~= group) then
                group = Entry.group;
                Root:CreateTitle(group);
            end
            Root:CreateCheckbox(Entry.name,
                function (index) return f.Chosen[index] == true; end,
                function (index) f.Chosen[index] = not f.Chosen[index] or nil; end,
                i
            );
        end
    end);
    y = y - LINE - 6;

    f.Reserves = createNumberRow(f, "SRs per week", y, nil,
        "How many items each player may soft reserve. Players over the limit are listed when syncing.");
    y = y - LINE;
    f.PerWeek = createNumberRow(f, "Points per week", y, nil,
        "Points added at Close week on each reserved item of players who attended or were benched and didn't win it.");
    y = y - LINE;
    f.Cap = createNumberRow(f, "Points cap", y, "0 = no cap",
        "Maximum points a player can have on one item.");
    y = y - LINE;

    f.ResetOnWin = createCheckRow(f, "Reset points on win", y,
        "When Gargul awards an item, reset the winner's points on that item to zero. Needs \"Record wins from Gargul awards\" in the settings.");
    y = y - LINE;
    f.ResetNotReserved = createCheckRow(f, "Reset items not reserved again", y,
        "When the next week's sheet is synced, reset points on items a player didn't reserve again. Off: points stay until the item is won or reset by hand.");
    y = y - LINE - 4;

    f.Note = createNote(f);
    f.Note:SetPoint("TOPLEFT", 16, y);
    f.Note:SetPoint("RIGHT", -16, 0);

    f.Error = f:CreateFontString(nil, "ARTWORK", "GameFontRedSmall");
    f.Error:SetPoint("BOTTOMLEFT", 16, 40);
    f.Error:SetPoint("RIGHT", -16, 0);
    f.Error:SetJustifyH("LEFT");

    f.Save = createButton(f, "Save", 120);
    f.Save:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 12);
    f.Save:SetScript("OnClick", function () PP:saveCampaign(); end);

    f.Cancel = createButton(f, CANCEL, 120);
    f.Cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 12);
    f.Cancel:SetScript("OnClick", function () f:Hide(); end);

    f:SetHeight(-y + 100);

    -- Closing without saving (Cancel, Escape, the X) hands back to whoever opened it, e.g. the picker
    f:SetScript("OnHide", function ()
        local onCancel = f.onCancel;
        f.onCancel, f.onSave = nil, nil;
        if (onCancel) then
            onCancel();
        end
    end);

    return f;
end

--[[
    Options: { raidKey } to edit, or { team, Instances } to prefill a new one.
    onSave(raidKey) after saving, onCancel() when closed without saving.
]]
function PP:showCampaignEditor(Options)
    Options = Options or {};
    Editor = Editor or createEditor();
    local f = Editor;

    if (f:IsShown()) then
        f.onCancel = nil;
        f:Hide();
    end

    local Raid = self:raid(Options.raidKey);
    local Rules = Raid and self:rules(Options.raidKey) or self.db.lastRules or self.RULE_DEFAULTS;

    f.raidKey = Raid and Options.raidKey or nil;
    f.onSave, f.onCancel = Options.onSave, Options.onCancel;

    f.Heading:SetText(Raid and ("Edit " .. Raid.label) or "New campaign");
    f.Team:SetText(Raid and Raid.team or Options.team or self.db.lastTeam or "");
    if (Raid) then
        f.Team:Disable();
    else
        f.Team:Enable();
    end
    f.Teams:SetShown(not Raid and #self.db.Teams > 0);

    f.Entries = raidEntries(Raid and Raid.Instances or Options.Instances);
    f.Chosen = {};
    local Preset = Raid and Raid.Instances or Options.Instances or {};
    for i, Entry in ipairs(f.Entries) do
        for _, slug in ipairs(Preset) do
            if (Entry.slug == slug) then
                f.Chosen[i] = true;
            end
        end
    end
    f.Raid:SetEnabled(not Raid);
    f.Raid:GenerateMenu();

    f.Reserves:SetText(Rules.reserves);
    f.PerWeek:SetText(Rules.perWeek);
    f.Cap:SetText(Rules.cap);
    f.ResetOnWin:SetChecked(Rules.resetOnWin);
    f.ResetNotReserved:SetChecked(Rules.resetNotReserved);

    f.Note:SetText(Raid
        and "Team and raid are fixed. Rule changes apply from the next sync and Close week; points already given stay as they are."
        or "Softres sheets for this team and raid are synced into this campaign, which keeps its own points.");
    f.Error:SetText("");

    f:Show();
    f:Raise();
end

function PP:saveCampaign()
    local f = Editor;

    local function fail(message)
        f.Error:SetText(message);
    end

    local Rules = {
        reserves = tonumber(f.Reserves:GetText()),
        perWeek = tonumber(f.PerWeek:GetText()),
        cap = tonumber(f.Cap:GetText()) or 0,
        resetOnWin = f.ResetOnWin:GetChecked() and true or false,
        resetNotReserved = f.ResetNotReserved:GetChecked() and true or false,
    };
    if (not Rules.reserves or Rules.reserves < 1) then
        return fail("SRs per week must be at least 1.");
    end
    if (not Rules.perWeek or Rules.perWeek < 1) then
        return fail("Points per week must be at least 1.");
    end

    local raidKey = f.raidKey;
    if (raidKey) then
        self:setRules(raidKey, Rules);
        self:print(("Rules for %s: %s."):format(self:raidLabel(raidKey), self:rulesText(raidKey)));
    else
        local team = strtrim(f.Team:GetText() or "");
        if (team == "") then
            return fail("Enter the team's name.");
        end

        local Instances = {};
        for i, Entry in ipairs(f.Entries) do
            if (f.Chosen[i]) then
                tinsert(Instances, Entry.slug);
            end
        end
        if (#Instances == 0) then
            return fail("Pick the raid.");
        end

        local existing = self:findCampaign(team, Instances);
        if (existing) then
            return fail(("%s already exists."):format(self:raidLabel(existing)));
        end

        team = self:addTeam(team);
        self.db.lastTeam = team;
        raidKey = self:ensureRaid(team, Instances, Rules);
        self:print(("New campaign %s: %s."):format(self:raidLabel(raidKey), self:rulesText(raidKey)));
    end

    local onSave = f.onSave;
    f.onCancel = nil;
    f:Hide();
    if (onSave) then
        onSave(raidKey);
    end
end

--[[ PICKER ]]

local function pickerChoose(raidKey)
    local f = Picker;
    f.choice = raidKey;
    f.Use:SetEnabled(raidKey ~= nil);

    if (not raidKey) then
        f.Rules:SetText(#f.Matching == 0
            and "No campaign for this raid yet: click |cffffd100New campaign|r."
            or "Pick the campaign this sheet belongs to.");
        return;
    end

    local text = PP:rulesText(raidKey);
    if (not PP:sameInstances(PP:raid(raidKey).Instances, f.Data.Instances)) then
        text = text .. "\n|cffff6060That campaign is for a different raid than this sheet.|r";
    end
    f.Rules:SetText(text);
end

local function createPicker()
    local f = createDialog("GargulPityPointsCampaignPicker", "New softres sheet");

    f.Text = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight");
    f.Text:SetPoint("TOPLEFT", 16, -36);
    f.Text:SetPoint("RIGHT", -16, 0);
    f.Text:SetJustifyH("LEFT");
    f.Text:SetJustifyV("TOP");

    f.Dropdown = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate");
    f.Dropdown:SetWidth(WIDTH - 32);
    f.Dropdown:SetDefaultText("Pick a campaign");
    f.Dropdown:SetupMenu(function (_, Root)
        local function add(key)
            Root:CreateRadio(PP:raidLabel(key),
                function (k) return f.choice == k; end,
                function (k) pickerChoose(k); end,
                key
            );
        end

        for _, key in ipairs(f.Matching or {}) do
            add(key);
        end
        if (#(f.Other or {}) > 0) then
            Root:CreateTitle("Other raids");
            for _, key in ipairs(f.Other) do
                add(key);
            end
        end
    end);

    f.Rules = createNote(f);
    f.Rules:SetPoint("TOPLEFT", f.Dropdown, "BOTTOMLEFT", 0, -8);
    f.Rules:SetPoint("RIGHT", -16, 0);

    f.Use = createButton(f, "Use campaign", 120);
    f.Use:SetPoint("BOTTOMLEFT", 12, 12);
    f.Use:SetScript("OnClick", function ()
        local onPick, raidKey = f.onPick, f.choice;
        f.onPick = nil;
        f:Hide();
        onPick(raidKey);
    end);

    f.New = createButton(f, "New campaign...", 120);
    f.New:SetPoint("LEFT", f.Use, "RIGHT", 6, 0);
    f.New:SetScript("OnClick", function ()
        local Data, onPick = f.Data, f.onPick;
        f.onPick = nil;
        f:Hide();
        PP:showCampaignEditor({
            Instances = Data.Instances,
            onSave = onPick,
            onCancel = function () PP:showCampaignPicker(Data, onPick); end,
        });
    end);

    f.Cancel = createButton(f, CANCEL, 120);
    f.Cancel:SetPoint("LEFT", f.New, "RIGHT", 6, 0);
    f.Cancel:SetScript("OnClick", function () f:Hide(); end);

    f:SetScript("OnHide", function ()
        if (f.onPick) then
            f.onPick = nil;
            PP:print(("Softres sheet %s not synced. Click |cffffd100Sync SR|r when you're ready to pick its campaign."):format(f.Data.id));
        end
    end);

    return f;
end

--- Ask which campaign a new softres sheet goes into. onPick(raidKey) runs once one is picked or created.
function PP:showCampaignPicker(Data, onPick)
    Picker = Picker or createPicker();
    local f = Picker;

    if (f:IsShown()) then
        f.onPick = nil;
        f:Hide();
    end

    local reserves = 0;
    for _, Items in pairs(Data.Reserves or {}) do
        for _ in pairs(Items) do
            reserves = reserves + 1;
        end
    end

    f.Data, f.onPick = Data, onPick;
    f.Matching, f.Other = self:campaignKeys(Data.Instances);

    f.Text:SetText(("Softres sheet |cffffd100%s|r for |cffffd100%s|r, %d reserves.\n\nWhich campaign is it for? Its rules set the SRs, points per week and cap."):format(
        Data.id, instancesText(Data.Instances), reserves
    ));
    f.Dropdown:ClearAllPoints();
    f.Dropdown:SetPoint("TOPLEFT", 16, -36 - f.Text:GetStringHeight() - 12);
    f.Dropdown:SetEnabled(#f.Matching + #f.Other > 0);

    -- One campaign for this raid: preselect it, the user still confirms
    pickerChoose(#f.Matching == 1 and f.Matching[1] or nil);
    f.Dropdown:GenerateMenu();

    f:SetHeight(36 + f.Text:GetStringHeight() + 12 + 26 + 8 + 40 + 46);
    f:Show();
    f:Raise();
end
