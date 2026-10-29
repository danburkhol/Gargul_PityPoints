--[[
    Blizzard Settings panel: Esc > Options > AddOns > Gargul Pity Points.
    Reference: wow-ui-source Blizzard_Settings_Shared/Blizzard_ImplementationReadme.lua
]]

local _, PP = ...;

local function formatCap(value)
    value = math.floor(value + 0.5);
    return value == 0 and "Off" or tostring(value);
end

local function formatWhole(value)
    return tostring(math.floor(value + 0.5));
end

function PP:initSettings()
    if (not Settings or not Settings.RegisterVerticalLayoutCategory) then
        return self:print("This client has no Settings panel, use |cffffff00/pp|r instead.");
    end

    local S = self.db.Settings;
    local category, layout = Settings.RegisterVerticalLayoutCategory(self.title);
    self.settingsCategory = category;

    local function register(key, varType, name)
        return Settings.RegisterAddOnSetting(category, "GargulPityPoints_" .. key, key, S, varType, name, PP.DEFAULTS[key]);
    end

    local function header(text)
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text));
    end

    local function slider(key, name, minValue, maxValue, step, tooltip, formatter)
        local setting = register(key, Settings.VarType.Number, name);
        local options = Settings.CreateSliderOptions(minValue, maxValue, step);
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter or formatWhole);
        Settings.CreateSlider(category, setting, options, tooltip);

        -- Sliders can hand back fractions, points are whole numbers
        setting:SetValueChangedCallback(function (_, value)
            S[key] = math.floor(value + 0.5);
        end);
    end

    local function checkbox(key, name, tooltip)
        Settings.CreateCheckbox(category, register(key, Settings.VarType.Boolean, name), tooltip);
    end

    header("Manager");
    layout:AddInitializer(CreateSettingsButtonInitializer(
        "Pity Point manager",
        "Open",
        function ()
            if (SettingsPanel and SettingsPanel:IsShown()) then
                HideUIPanel(SettingsPanel);
            end
            PP:openManager();
        end,
        "Browse, search and edit points per player and item. Also: /pp",
        true
    ));

    header("Points");
    slider("pointsPerWeek", "Points per week", 1, 100, 1,
        "Points added at Close week on each reserved item of players who attended or were benched and didn't win it.");
    slider("cap", "Points cap", 0, 500, 5,
        "Maximum points a player can have on one item. Off = no cap.", formatCap);
    slider("reservesPerWeek", "Reserves per week", 1, 10, 1,
        "How many items each player may soft reserve. Players over the limit are listed when syncing.");
    checkbox("resetOnWin", "Reset on win",
        "When Gargul awards an item, reset the winner's points on that item to zero.");

    header("Soft reserves");
    checkbox("autoSync", "Sync automatically on import",
        "When a softres.it sheet is imported in Gargul, sync it straight away. A new softres id starts a new sheet (you'll be asked for the team); re-importing the same sheet only records what changed.");

    header("Attendance");
    checkbox("recordAttendance", "Record raid attendance",
        "While you're in a raid group, note who is in the raid on every boss kill and on a timer inside the raid instance. Close week uses this to pre-tick attendees.");
    slider("snapshotMinutes", "Attendance check interval (minutes)", 1, 30, 1,
        "How often to note the raid roster while inside a raid instance, on top of boss kills.");

    header("Announcements");
    checkbox("announce", "Announce results",
        "When a roll-off you started ends, post the winner with their roll, points and total, followed by the other rolls.");

    local channel = register("channel", Settings.VarType.String, "Announcement channel");
    Settings.CreateDropdown(category, channel, function ()
        local Container = Settings.CreateControlTextContainer();
        for _, Option in ipairs(PP.CHANNELS) do
            Container:Add(Option[1], Option[2]);
        end
        return Container:GetData();
    end, "Where results are posted.");

    header("Whispers");
    checkbox("whisperReply", "Reply to !pp whispers",
        "When a player whispers you !pp or !pitypoints, reply with all their pity points per raid. Like Gargul's !sr, only the loot master and assists reply while in a group.");
    checkbox("srFollowUp", "Add points to Gargul's !sr reply",
        "After Gargul answers a !sr whisper, send a second whisper with the player's pity points on each item they reserved.");

    header("Display");

    local sheetDate = register("sheetDate", Settings.VarType.String, "Sheet date in the sidebar");
    Settings.CreateDropdown(category, sheetDate, function ()
        local Container = Settings.CreateControlTextContainer();
        for _, Option in ipairs(PP.SHEET_DATES) do
            Container:Add(Option[1], Option[2]);
        end
        return Container:GetData();
    end, "Which date labels and orders softres sheets in the manager's sidebar, most recent first. Sheets without that date use the first-imported date, shown with a ~.");
    sheetDate:SetValueChangedCallback(function ()
        PP:refreshManager();
    end);
    local minimap = Settings.RegisterProxySetting(category, "GargulPityPoints_minimap", Settings.VarType.Boolean,
        "Show minimap button", true,
        function () return not S.minimap.hide; end,
        function (value) PP:setMinimapShown(value); end
    );
    Settings.CreateCheckbox(category, minimap,
        "Show the Pity Points button on the minimap. The launcher is also available in Titan Panel and other LibDataBroker displays.");

    Settings.RegisterAddOnCategory(category);
end

function PP:openSettings()
    if (self.settingsCategory) then
        Settings.OpenToCategory(self.settingsCategory:GetID());
    end
end
