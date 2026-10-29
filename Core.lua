--[[
    Gargul Pity Points: namespace, saved data (schema 3), points + ledger API, rows / CSV, slash commands and boot.

    Points live per campaign (team + instance, Raids[raidKey]), each with its own Rules. Every change goes through PP:setPoints, which writes a ledger entry
    and fires PP.callbacks "POINTS_CHANGED". Sheets, attendance and Close week live in Sheets.lua.
    Design: docs/Design-RaidsAndWeeks.md. Gargul hooks: Gargul.lua.
]]

local addonName, PP = ...;
_G.GargulPityPoints = PP;

PP.name = addonName;
PP.title = "Gargul Pity Points";
PP.icon = "Interface\\Icons\\INV_Misc_Coin_01";
PP.UNASSIGNED = "unassigned";

-- Per campaign (Raid.Rules), edited in UI/Campaign.lua
PP.RULE_DEFAULTS = {
    reserves = 2,
    perWeek = 10,
    cap = 0, -- 0 = no cap
    resetOnWin = true,
    resetNotReserved = true,
};

PP.DEFAULTS = {
    -- Gargul integration: a master switch, then one per hook (see Gargul.lua)
    gargul = true,
    autoSync = true,
    rollBonus = true, -- Also adds "PP roll+points" to the roll window's Note column
    trackWins = true,
    announce = true,
    channel = "RAID",
    trackMissingRolls = true,
    autoAwardSR = false, -- Moves loot, so opt-in
    whisperReply = true,
    srFollowUp = true,
    sharePoints = false, -- Rolls and resets span every campaign
    recordAttendance = true,
    snapshotMinutes = 5,
    sheetDate = "created",
    minimap = { hide = false, },
};

-- Which date names and orders sheets in the sidebar: value, label, Sheet field. Missing dates fall back to imported.
PP.SHEET_DATES = {
    { "created", "Sheet created (softres.it)", "createdAt", },
    { "raidStarts", "Raid start (softres.it)", "raidStartsAt", },
    { "locked", "Sheet locked (softres.it)", "lockedAt", },
    { "imported", "First imported (this add-on)", "firstSyncedAt", },
};

-- value -> label, in display order
PP.CHANNELS = {
    { "RAID", "Raid (party when not in a raid)", },
    { "RAID_WARNING", "Raid warning", },
    { "GUILD", "Guild", },
    { "OFFICER", "Officer", },
    { "SELF", "Only me (local chat frame)", },
};

-- softres.it instance slugs -> display names. Unknown slugs are shown as-is.
PP.INSTANCE_NAMES = {
    karazhan = "Karazhan", gruulslair = "Gruul's Lair", magtheridonslair = "Magtheridon's Lair",
    magtheridon = "Magtheridon's Lair", serpentshrinecavern = "Serpentshrine Cavern", ssc = "Serpentshrine Cavern",
    tempestkeep = "Tempest Keep", theeye = "Tempest Keep", hyjal = "Hyjal Summit", hyjalsummit = "Hyjal Summit",
    mounthyjal = "Hyjal Summit", blacktemple = "Black Temple", zulaman = "Zul'Aman", sunwellplateau = "Sunwell Plateau",
    sunwell = "Sunwell Plateau", moltencore = "Molten Core", onyxia = "Onyxia's Lair", blackwinglair = "Blackwing Lair",
    zulgurub = "Zul'Gurub", aq20 = "Ruins of Ahn'Qiraj", aq40 = "Temple of Ahn'Qiraj", naxxramas = "Naxxramas",
    unknown = "Unknown raid",
};

-- Raids offered when creating a campaign, in display order. Matching against sheets goes by name, so aliases are fine.
PP.RAID_CHOICES = {
    { "The Burning Crusade", { "karazhan", "gruulslair", "magtheridonslair", "serpentshrinecavern", "tempestkeep",
        "hyjal", "blacktemple", "zulaman", "sunwellplateau", }, },
    { "Classic", { "moltencore", "onyxia", "blackwinglair", "zulgurub", "aq20", "aq40", "naxxramas", }, },
};

PP.LEDGER_REASONS = {
    week = "Close week", win = "Won item", manual = "Manual edit", reset = "Not reserved again",
    reopen = "Week reopened", migrate = "Moved from before raid tracking", import = "Imported", undo = "Import undone",
};

PP.callbacks = LibStub("CallbackHandler-1.0"):New(PP);

-- Test-only reservations (/pp reserve, /pp test), not saved
PP.TestReserves = {};

local DB;

--[[ HELPERS ]]

function PP:print(...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff967FD2PityPoints:|r " .. strjoin(" ", tostringall(...)));
end

-- Run fn and surface errors to BugSack / the error frame without breaking the caller
function PP.safe(fn)
    return function (...)
        local args = { ... };
        local n = select("#", ...);
        xpcall(function () fn(unpack(args, 1, n)); end, geterrorhandler());
    end
end

function PP:gargul()
    return _G.Gargul;
end

--- Whether a Gargul integration feature is on: the master switch and, if given, the feature's own setting.
--- Hooks are always installed and check this when they run, so toggling needs no /reload.
function PP:gargulFeature(key)
    local S = self.db and self.db.Settings;
    return S ~= nil and S.gargul and (key == nil or S[key]) and true or false;
end

--- Same normalisation Gargul uses for softres lookups: lowercase, realm dropped when it's our own
function PP:key(playerName)
    local GL = self:gargul();
    if (GL and GL.disambiguateName) then
        return strlower(GL:disambiguateName(playerName));
    end

    return strlower(playerName);
end

function PP:displayName(key)
    return (key:gsub("^%l", strupper));
end

function PP:me()
    return UnitName("player");
end

--- Lowercase class token ("mage") from any softres sheet we've seen, else Gargul's current softres
function PP:playerClass(key)
    if (DB.Classes[key]) then
        return DB.Classes[key];
    end

    local GL = self:gargul();
    return GL and GL.SoftRes and (GL.SoftRes.MaterializedData.ClassByPlayerName or {})[key];
end

function PP:rememberClasses(Classes)
    for key, class in pairs(Classes or {}) do
        DB.Classes[key] = class;
    end
end

--- "Black Temple" / "black-temple" -> "blacktemple", for matching softres slugs to GetInstanceInfo()
function PP:slug(text)
    return (strlower(text or ""):gsub("[^%w]", ""));
end

function PP:instanceName(slug)
    return self.INSTANCE_NAMES[slug] or slug;
end

function PP:itemName(itemID)
    local name = GetItemInfo(itemID);
    if (name) then
        DB.ItemNames[itemID] = name;
        return name;
    end

    if (C_Item and C_Item.RequestLoadItemDataByID) then
        C_Item.RequestLoadItemDataByID(itemID);
    end

    return DB.ItemNames[itemID] or ("item:" .. itemID);
end

function PP:itemLink(itemID)
    local _, link = GetItemInfo(itemID);
    return link;
end

function PP:itemIcon(itemID)
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
        or GetItemIcon and GetItemIcon(itemID);

    return icon or 134400; -- question mark
end

function PP:notify()
    self.callbacks:Fire("POINTS_CHANGED");
end

--[[ RAIDS ]]

function PP:raidKey(team, Instances)
    return strlower(strtrim(team)) .. ":" .. table.concat(Instances, "+");
end

--- Create a campaign (team + raid) with its rules, or return the existing one
function PP:ensureRaid(team, Instances, Rules)
    local key = self:raidKey(team, Instances);

    if (not DB.Raids[key]) then
        local Names = {};
        for _, slug in ipairs(Instances) do
            tinsert(Names, self:instanceName(slug));
        end

        DB.Raids[key] = {
            team = team,
            Instances = Instances,
            label = team .. " · " .. table.concat(Names, " + "),
            Points = {},
            createdAt = time(),
        };
        self:setRules(key, Rules or DB.lastRules);
    end

    return key, DB.Raids[key];
end

local function fillRules(Rules)
    for k, v in pairs(PP.RULE_DEFAULTS) do
        if (Rules[k] == nil) then
            Rules[k] = v;
        end
    end
    return Rules;
end

function PP:rules(raidKey)
    local Raid = self:raid(raidKey);
    return Raid and Raid.Rules or self.RULE_DEFAULTS;
end

--- Store a campaign's rules. They apply from the next sync / Close week; past points are left alone.
function PP:setRules(raidKey, Rules)
    local Raid = self:raid(raidKey);
    if (not Raid) then
        return;
    end

    local function whole(value, minimum)
        return math.max(minimum, math.floor(tonumber(value) or minimum));
    end

    Rules = Rules or {};
    Raid.Rules = fillRules({
        reserves = Rules.reserves and whole(Rules.reserves, 1),
        perWeek = Rules.perWeek and whole(Rules.perWeek, 1),
        cap = Rules.cap and whole(Rules.cap, 0),
        resetOnWin = Rules.resetOnWin,
        resetNotReserved = Rules.resetNotReserved,
    });
    DB.lastRules = CopyTable(Raid.Rules);
    self:notify();
end

function PP:rulesText(raidKey)
    local R = self:rules(raidKey);
    return ("%d SR%s · +%d/week · %s"):format(
        R.reserves, R.reserves == 1 and "" or "s", R.perWeek, R.cap > 0 and ("cap " .. R.cap) or "no cap"
    );
end

-- Instance lists compared by display name, so softres aliases ("hyjal" / "hyjalsummit") match
local function instanceSignature(Instances)
    local Names = {};
    for _, slug in ipairs(Instances or {}) do
        tinsert(Names, strlower(PP:instanceName(slug)));
    end
    table.sort(Names);
    return table.concat(Names, "+");
end

function PP:sameInstances(A, B)
    return instanceSignature(A) == instanceSignature(B);
end

--- The campaign for this team and raid, if one exists
function PP:findCampaign(team, Instances)
    team = strlower(strtrim(team or ""));
    for key, Raid in pairs(DB.Raids) do
        if (key ~= self.UNASSIGNED and strlower(Raid.team) == team and self:sameInstances(Raid.Instances, Instances)) then
            return key;
        end
    end
end

--- Campaign keys (unassigned excluded), sorted by label: those for these instances first, then the rest
function PP:campaignKeys(Instances)
    local Matching, Other = {}, {};
    for _, key in ipairs(self:raidKeys()) do
        if (key ~= self.UNASSIGNED) then
            tinsert(Instances and self:sameInstances(DB.Raids[key].Instances, Instances) and Matching or Other, key);
        end
    end
    return Matching, Other;
end

function PP:raid(raidKey)
    return raidKey and DB.Raids[raidKey];
end

function PP:raidLabel(raidKey)
    local Raid = self:raid(raidKey);
    return Raid and Raid.label or tostring(raidKey);
end

--- Raid keys sorted by label, the unassigned bucket last
function PP:raidKeys()
    local Keys = {};
    for key in pairs(DB.Raids) do
        tinsert(Keys, key);
    end

    table.sort(Keys, function (a, b)
        if ((a == self.UNASSIGNED) ~= (b == self.UNASSIGNED)) then
            return b == self.UNASSIGNED;
        end
        return strlower(DB.Raids[a].label) < strlower(DB.Raids[b].label);
    end);

    return Keys;
end

function PP:addTeam(team)
    team = strtrim(team or "");
    if (team == "") then
        return;
    end

    for _, existing in ipairs(DB.Teams) do
        if (strlower(existing) == strlower(team)) then
            return existing;
        end
    end

    tinsert(DB.Teams, team);
    table.sort(DB.Teams);
    return team;
end

--[[ POINTS + LEDGER ]]

function PP:log(raidKey, sheetID, playerKey, itemID, delta, after, reason, batch)
    tinsert(DB.Ledger, {
        at = time(),
        raid = raidKey,
        sheet = sheetID,
        player = playerKey,
        itemID = itemID,
        delta = delta,
        after = after,
        reason = reason,
        batch = batch,
        by = self:me(),
    });
end

function PP:getPoints(raidKey, playerName, itemID)
    local Raid = self:raid(raidKey);
    local Items = Raid and Raid.Points[self:key(playerName)];
    return Items and Items[tonumber(itemID)] or 0;
end

--- The campaigns a player's points on an item count from: just raidKey, or with sharePoints every campaign holding some
function PP:pointCampaigns(raidKey, playerName, itemID)
    if (not DB.Settings.sharePoints) then
        return raidKey and { raidKey, } or {};
    end

    local Keys = {};
    for key in pairs(DB.Raids) do
        if (key ~= self.UNASSIGNED and self:getPoints(key, playerName, itemID) > 0) then
            tinsert(Keys, key);
        end
    end
    return Keys;
end

--- The points added to a roll: the campaign's own, or with sharePoints the sum over every campaign
function PP:rollPoints(raidKey, playerName, itemID)
    local total = 0;
    for _, key in ipairs(self:pointCampaigns(raidKey, playerName, itemID)) do
        total = total + self:getPoints(key, playerName, itemID);
    end
    return total;
end

--- The only writer of points. Logs the change; quiet = don't notify the UI (batch callers notify once).
--- batch tags the ledger entry with an import id (Import.lua).
function PP:setPoints(raidKey, playerName, itemID, points, reason, sheetID, quiet, batch)
    local Raid = self:raid(raidKey);
    if (not Raid) then
        return;
    end

    local key = self:key(playerName);
    itemID = tonumber(itemID);
    points = math.max(0, math.floor(tonumber(points) or 0));

    local before = self:getPoints(raidKey, key, itemID);
    if (before == points) then
        return;
    end

    Raid.Points[key] = Raid.Points[key] or {};
    Raid.Points[key][itemID] = points > 0 and points or nil;
    if (not next(Raid.Points[key])) then
        Raid.Points[key] = nil;
    end

    self:itemName(itemID); -- Warm the name cache for search
    self:log(raidKey, sheetID, key, itemID, points - before, points, reason or "manual", batch);

    if (not quiet) then
        self:notify();
    end
end

function PP:adjustPoints(raidKey, playerName, itemID, delta)
    local sheetID = self:currentSheetID(raidKey);
    self:setPoints(raidKey, playerName, itemID, self:getPoints(raidKey, playerName, itemID) + delta, "manual", sheetID);
end

function PP:resetPoints(raidKey, playerName, itemID)
    self:setPoints(raidKey, playerName, itemID, 0, "manual", self:currentSheetID(raidKey));
end

--- Move every point from one raid into another (used to adopt pre-v2 points)
function PP:movePoints(fromKey, toKey)
    local From, To = self:raid(fromKey), self:raid(toKey);
    if (not From or not To or fromKey == toKey) then
        return 0;
    end

    local moved = 0;
    for key, Items in pairs(From.Points) do
        for itemID, points in pairs(Items) do
            local total = self:getPoints(toKey, key, itemID) + points;
            self:setPoints(fromKey, key, itemID, 0, "migrate", nil, true);
            self:setPoints(toKey, key, itemID, total, "migrate", nil, true);
            moved = moved + 1;
        end
    end

    if (fromKey == self.UNASSIGNED and not next(From.Points)) then
        DB.Raids[fromKey] = nil;
    end

    self:notify();
    return moved;
end

--[[ ROWS AND CSV ]]

--- Every tracked player/item pair of a raid: anything with points plus everything on the raid's current sheet
function PP:rows(raidKey)
    local Raid = self:raid(raidKey);
    if (not Raid) then
        return {};
    end

    local Sheet = self:sheet(self:currentSheetID(raidKey));
    local Reserves = Sheet and Sheet.Reserves or {};
    local Rows, Seen = {}, {};

    local function add(key, itemID)
        local id = key .. ":" .. itemID;
        if (Seen[id]) then
            return;
        end
        Seen[id] = true;

        tinsert(Rows, {
            raid = raidKey,
            key = key,
            name = self:displayName(key),
            itemID = itemID,
            itemName = self:itemName(itemID),
            points = self:getPoints(raidKey, key, itemID),
            reserved = (Reserves[key] and Reserves[key][itemID]) and true or false,
        });
    end

    for key, Items in pairs(Raid.Points) do
        for itemID in pairs(Items) do
            add(key, itemID);
        end
    end

    for key, Items in pairs(Reserves) do
        for itemID in pairs(Items) do
            add(key, itemID);
        end
    end

    return Rows;
end

function PP:allRows()
    local Rows = {};
    for _, raidKey in ipairs(self:raidKeys()) do
        for _, Row in ipairs(self:rows(raidKey)) do
            tinsert(Rows, Row);
        end
    end
    return Rows;
end

local function csvField(value)
    value = tostring(value == nil and "" or value);
    if (value:find('[,"\n]')) then
        value = '"' .. value:gsub('"', '""') .. '"';
    end

    return value;
end

local function csv(Header, Lines)
    local Out = { table.concat(Header, ","), };
    for _, Fields in ipairs(Lines) do
        for i, value in ipairs(Fields) do
            Fields[i] = csvField(value);
        end
        tinsert(Out, table.concat(Fields, ","));
    end
    return table.concat(Out, "\n");
end

function PP:buildCSV(Rows)
    local Lines = {};
    for _, Row in ipairs(Rows) do
        local Raid = self:raid(Row.raid) or {};
        tinsert(Lines, {
            Raid.team or "", Raid.Instances and table.concat(Raid.Instances, "+") or "",
            Row.name, Row.itemID, Row.itemName, Row.points, Row.reserved and "yes" or "no",
        });
    end

    return csv({ "team", "raid", "player", "item_id", "item_name", "points", "reserved", }, Lines);
end

function PP:buildLedgerCSV(Entries)
    local Lines = {};
    for _, Entry in ipairs(Entries) do
        local Raid = self:raid(Entry.raid) or {};
        tinsert(Lines, {
            date("%Y-%m-%d %H:%M", Entry.at), Raid.label or Entry.raid, Entry.sheet or "",
            self:displayName(Entry.player), Entry.itemID, self:itemName(Entry.itemID),
            Entry.delta, Entry.after, Entry.reason, Entry.by or "",
        });
    end

    return csv({ "date", "raid", "softres", "player", "item_id", "item_name", "change", "points_after", "reason", "by", }, Lines);
end

--- Ledger entries newest first, optionally filtered to one raid / one sheet
function PP:ledger(raidKey, sheetID)
    local Entries = {};
    for i = #DB.Ledger, 1, -1 do
        local Entry = DB.Ledger[i];
        if ((not raidKey or Entry.raid == raidKey) and (not sheetID or Entry.sheet == sheetID)) then
            tinsert(Entries, Entry);
        end
    end
    return Entries;
end

--[[ SLASH COMMANDS ]]

local function itemIDFrom(arg)
    if (not arg) then
        return nil;
    end

    return tonumber(arg) or tonumber(arg:match("item:(%d+)"));
end

local function slash(msg)
    local cmd, a, b, c = strsplit(" ", strtrim(msg or ""), 4);
    cmd = strlower(cmd or "");
    local raidKey = PP:activeRaidKey();

    if (cmd == "") then
        PP:toggleManager();

    elseif (cmd == "config" or cmd == "settings" or cmd == "options") then
        PP:openSettings();

    elseif (cmd == "log") then
        PP:showLog(raidKey);

    elseif (cmd == "show") then
        local any = false;
        for _, Row in ipairs(PP:allRows()) do
            if (Row.points > 0) then
                any = true;
                PP:print(("%s  %s  %s  %d"):format(PP:raidLabel(Row.raid), Row.name, PP:itemLink(Row.itemID) or Row.itemName, Row.points));
            end
        end
        if (not any) then
            PP:print("No points stored.");
        end

    elseif (cmd == "set" and a and b and c) then
        -- /pp set Name [item] 30   (item link may contain spaces, so the points come last)
        if (not raidKey) then
            return PP:print("No active raid yet: import a softres sheet in Gargul and sync it first.");
        end

        local rest = strtrim(b .. " " .. c);
        local itemArg, points = rest:match("^(.-)%s+(%d+)$");
        local itemID = itemIDFrom(itemArg);
        if (not itemID) then
            return PP:print("Usage: /pp set <name> <itemID|link> <points>");
        end

        PP:setPoints(raidKey, a, itemID, points, "manual", PP:currentSheetID(raidKey));
        PP:print(("%s now has %d points on %s in %s."):format(a, PP:getPoints(raidKey, a, itemID), itemArg, PP:raidLabel(raidKey)));
        if (not PP:isReserved(a, itemID)) then
            PP:print(("Note: %s hasn't soft reserved it, so the points won't apply. Use |cffffff00/pp reserve|r to fake a reserve."):format(a));
        end

    elseif (cmd == "reserve" and a and b) then
        local itemArg = c and (b .. " " .. c) or b;
        local itemID = itemIDFrom(itemArg);
        if (not itemID) then
            return PP:print("Usage: /pp reserve <name> <itemID|link>");
        end

        local key = PP:key(a);
        PP.TestReserves[key] = PP.TestReserves[key] or {};
        PP.TestReserves[key][itemID] = true;
        PP:print(("%s now counts as having reserved %s (test only, cleared on /reload)."):format(a, itemArg));

    elseif (cmd == "sync") then
        PP:syncFromGargul();

    elseif (cmd == "snapshot") then
        PP:takeSnapshot("manual");

    elseif (cmd == "test") then
        PP:runTest();

    elseif (cmd == "whisper" and a) then
        -- Preview the !pp reply for a player without whispering anyone
        for _, line in ipairs(PP:pityPointsReply(a)) do
            PP:print(line);
        end

    else
        PP:print("/pp (window) | /pp config | /pp log | /pp sync | /pp snapshot | /pp show | /pp whisper <name> | /pp set <name> <item> <points> | /pp reserve <name> <item> | /pp test");
    end
end

--[[ BOOT ]]

local function migrate()
    -- Schema 1 (flat Points[player][item]) -> park everything in an "unassigned" raid until a sheet adopts it
    if (DB.schema == nil and DB.Points) then
        if (next(DB.Points)) then
            DB.Raids[PP.UNASSIGNED] = {
                team = "",
                Instances = { "unknown", },
                label = "Before raid tracking",
                Points = DB.Points,
                createdAt = time(),
            };
        end

        DB.Points, DB.LastReserves, DB.WonThisCycle, DB.lastSoftresID = nil, nil, nil, nil;
    end

    -- Schema 2 -> 3: the global point settings become each campaign's rules, so nothing changes on upgrade
    if ((DB.schema or 0) < 3) then
        local S = DB.Settings;
        local Old = fillRules({
            reserves = tonumber(S.reservesPerWeek),
            perWeek = tonumber(S.pointsPerWeek),
            cap = tonumber(S.cap), -- The PoC stored "no cap" as false
            resetOnWin = S.resetOnWin,
        });

        for _, Raid in pairs(DB.Raids) do
            Raid.Rules = Raid.Rules or CopyTable(Old);
        end
        DB.lastRules = DB.lastRules or Old;
        S.reservesPerWeek, S.pointsPerWeek, S.cap, S.resetOnWin = nil, nil, nil, nil;
    end

    DB.schema = 3;

    for _, Raid in pairs(DB.Raids) do
        Raid.Rules = fillRules(Raid.Rules or {});
    end
end

local function initDB()
    GargulPityPointsDB = GargulPityPointsDB or {};
    DB = GargulPityPointsDB;
    PP.db = DB;

    DB.Settings = DB.Settings or {};
    for k, v in pairs(PP.DEFAULTS) do
        if (DB.Settings[k] == nil) then
            DB.Settings[k] = type(v) == "table" and CopyTable(v) or v;
        end
    end
    DB.Settings.rollNote = nil; -- Merged into rollBonus

    DB.Raids = DB.Raids or {};
    DB.Sheets = DB.Sheets or {};
    DB.Ledger = DB.Ledger or {};
    DB.Imports = DB.Imports or {};
    DB.Teams = DB.Teams or {};
    DB.ItemNames = DB.ItemNames or {};
    DB.UI = DB.UI or {};
    DB.UI.Collapsed = DB.UI.Collapsed or {};

    migrate();

    -- Class cache, rebuilt from sheets synced before it existed
    if (not DB.Classes) then
        DB.Classes = {};
        for _, Sheet in pairs(DB.Sheets) do
            PP:rememberClasses(Sheet.Classes);
        end
    end
end

local Frame = CreateFrame("Frame");
Frame:RegisterEvent("ADDON_LOADED");
Frame:SetScript("OnEvent", function (self, _, loaded)
    if (loaded ~= addonName) then
        return;
    end
    self:UnregisterEvent("ADDON_LOADED");

    initDB();

    -- Each part boots on its own so one failure doesn't take the others down
    PP.safe(function () PP:initSheets(); end)();
    PP.safe(function () PP:initGargul(); end)();
    PP.safe(function () PP:initSettings(); end)();
    PP.safe(function () PP:initBroker(); end)();

    SLASH_GARGULPITYPOINTS1 = "/pp";
    SLASH_GARGULPITYPOINTS2 = "/pitypoints";
    SlashCmdList.GARGULPITYPOINTS = slash;
end);
