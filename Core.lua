--[[
    Gargul Pity Points: namespace, saved data (schema 2), points + ledger API, rows / CSV, slash commands and boot.

    Points live per raid (team + instance). Every change goes through PP:setPoints, which writes a ledger entry
    and fires PP.callbacks "POINTS_CHANGED". Sheets, attendance and Close week live in Sheets.lua.
    Design: docs/Design-RaidsAndWeeks.md. Gargul hooks: Gargul.lua.
]]

local addonName, PP = ...;
_G.GargulPityPoints = PP;

PP.name = addonName;
PP.title = "Gargul Pity Points";
PP.icon = "Interface\\Icons\\INV_Misc_Coin_01";
PP.UNASSIGNED = "unassigned";

PP.DEFAULTS = {
    reservesPerWeek = 2,
    pointsPerWeek = 10,
    cap = 0, -- 0 = no cap
    resetOnWin = true,
    -- Gargul integration: a master switch, then one per hook (see Gargul.lua)
    gargul = true,
    autoSync = true,
    rollBonus = true,
    rollNote = true,
    trackWins = true,
    announce = true,
    channel = "RAID",
    whisperReply = true,
    srFollowUp = true,
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

PP.LEDGER_REASONS = {
    week = "Close week", win = "Won item", manual = "Manual edit", reset = "Not reserved again",
    reopen = "Week reopened", migrate = "Moved from before raid tracking",
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

function PP:ensureRaid(team, Instances)
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
    end

    return key, DB.Raids[key];
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

function PP:log(raidKey, sheetID, playerKey, itemID, delta, after, reason)
    tinsert(DB.Ledger, {
        at = time(),
        raid = raidKey,
        sheet = sheetID,
        player = playerKey,
        itemID = itemID,
        delta = delta,
        after = after,
        reason = reason,
        by = self:me(),
    });
end

function PP:getPoints(raidKey, playerName, itemID)
    local Raid = self:raid(raidKey);
    local Items = Raid and Raid.Points[self:key(playerName)];
    return Items and Items[tonumber(itemID)] or 0;
end

--- The only writer of points. Logs the change; quiet = don't notify the UI (batch callers notify once).
function PP:setPoints(raidKey, playerName, itemID, points, reason, sheetID, quiet)
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
    self:log(raidKey, sheetID, key, itemID, points - before, points, reason or "manual");

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

    DB.schema = 2;
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

    -- PoC stored "no cap" as false
    if (type(DB.Settings.cap) ~= "number") then
        DB.Settings.cap = 0;
    end

    DB.Raids = DB.Raids or {};
    DB.Sheets = DB.Sheets or {};
    DB.Ledger = DB.Ledger or {};
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
