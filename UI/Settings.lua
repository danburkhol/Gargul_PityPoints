--[[
    Blizzard Settings panel: Esc > Options > AddOns > Gargul Pity Points.
    Reference: wow-ui-source Blizzard_Settings_Shared/Blizzard_ImplementationReadme.lua
]]

local _, PP = ...;

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
        return Settings.CreateCheckbox(category, register(key, Settings.VarType.Boolean, name), tooltip);
    end

    -- Greys out an option while its parent setting is off
    local function dependsOn(initializer, parentInitializer, ...)
        local Keys = { ..., };
        initializer:SetParentInitializer(parentInitializer, function ()
            for _, key in ipairs(Keys) do
                if (not S[key]) then
                    return false;
                end
            end
            return true;
        end);
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
        "Browse, search and edit points per player and item. SRs per week, points per week, the cap and resets are set per campaign there (New campaign / Edit campaign). Also: /pp",
        true
    ));

    header("Points");
    checkbox("sharePoints", "Share points between campaigns",
        "For teams whose players float between groups. A roll adds the player's points on that item from every campaign, and resets (winning the item, not reserving it again) apply in every campaign.");

    header("Attendance");
    checkbox("recordAttendance", "Record raid attendance",
        "While you're in a raid group, note who is in the raid on every boss kill and on a timer inside the raid instance. Close week uses this to pre-tick attendees.");
    slider("snapshotMinutes", "Attendance check interval (minutes)", 1, 30, 1,
        "How often to note the raid roster while inside a raid instance, on top of boss kills.");

    header("Gargul integration");
    local gargul = checkbox("gargul", "Enable Gargul integration",
        "Master switch for everything below. When off, this add-on doesn't react to Gargul at all: no bonus on rolls, no syncing on import, no win tracking, announcements or whisper replies. Points, the manager and the Sync SR button still work. Changes apply straight away, no /reload needed.");

    local function feature(key, name, tooltip)
        local initializer = checkbox(key, name, tooltip);
        dependsOn(initializer, gargul, "gargul");
        return initializer;
    end

    feature("autoSync", "Sync automatically on import",
        "When a softres.it sheet is imported in Gargul, sync it straight away. A new softres id starts a new sheet (you'll pick or create its campaign); re-importing the same sheet only records what changed.");
    feature("rollBonus", "Add points to rolls",
        "When a player rolls on an item they soft reserved, add their pity points to the roll itself, so Gargul ranks the roll window by the total. Rolls that got a bonus show \"PP roll+points\" in the Note column.");

    feature("trackWins", "Record wins from Gargul awards",
        "When Gargul awards an item, record the win on the active sheet. Close week doesn't add points to items a player won, and campaigns with \"Reset points on win\" reset the winner's points.");

    local announce = feature("announce", "Announce results",
        "When you award an item in Gargul, post the winner with their roll, points and total, followed by the other rolls.");
    local channel = register("channel", Settings.VarType.String, "Announcement channel");
    dependsOn(Settings.CreateDropdown(category, channel, function ()
        local Container = Settings.CreateControlTextContainer();
        for _, Option in ipairs(PP.CHANNELS) do
            Container:Add(Option[1], Option[2]);
        end
        return Container:GetData();
    end, "Where results are posted."), announce, "gargul", "announce");

    feature("trackMissingRolls", "Track missing rolls",
        "In Gargul's roll window, list soft reservers in the raid who haven't rolled yet (\"No roll yet\"). When the roll-off ends, name them in a raid warning.");
    feature("autoAwardSR", "Automatically award soft reserves",
        "When you open a loot window as master looter and an item is soft reserved by only one player in the raid, award it to them through Gargul. If several copies drop, only one is awarded; the rest are left for a roll.");

    feature("whisperReply", "Reply to !pp whispers",
        "When a player whispers you !pp or !pitypoints, reply with all their pity points per raid. Like Gargul's !sr, only the loot master and assists reply while in a group.");
    feature("srFollowUp", "Add points to Gargul's !sr reply",
        "After Gargul answers a !sr whisper, send a second whisper with the player's pity points on each item they reserved.");

    -- Options only re-check their direct parent, so pass master switch changes down to the grandchildren
    gargul:GetSetting():SetValueChangedCallback(function ()
        announce:GetSetting():NotifyUpdate();
    end);

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
