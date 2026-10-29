--[[
    Softres sheets: sync from Gargul, the active sheet, attendance snapshots, wins / rolls and Close week.
    Design: docs/Design-RaidsAndWeeks.md
]]

local _, PP = ...;

local DB;

local function countPairs(Reserves)
    local n = 0;
    for _, Items in pairs(Reserves) do
        for _ in pairs(Items) do
            n = n + 1;
        end
    end
    return n;
end

--[[ LOOKUPS ]]

function PP:sheet(id)
    return id and DB.Sheets[id];
end

--- The latest sheet synced for a raid (what the points list compares against)
function PP:currentSheetID(raidKey)
    local Raid = self:raid(raidKey);
    return Raid and Raid.currentSheet;
end

--- The date the sidebar uses for a sheet (Settings > Sheet date), falling back to when we first imported it
function PP:sheetDate(id)
    local Sheet = self:sheet(id);
    if (not Sheet) then
        return 0, false;
    end

    for _, Option in ipairs(self.SHEET_DATES) do
        if (Option[1] == DB.Settings.sheetDate) then
            local at = tonumber(Sheet[Option[3]]);
            if (at and at > 0) then
                return at, true;
            end
        end
    end

    return Sheet.firstSyncedAt or 0, false;
end

--- Sheets of a raid, most recent first by the configured sheet date
function PP:sheetIDs(raidKey)
    local IDs = {};
    for id, Sheet in pairs(DB.Sheets) do
        if (Sheet.raidKey == raidKey) then
            tinsert(IDs, id);
        end
    end

    table.sort(IDs, function (a, b)
        local da, db = self:sheetDate(a), self:sheetDate(b);
        if (da ~= db) then
            return da > db;
        end
        return a < b;
    end);

    return IDs;
end

--- The open sheet rolls, wins and attendance count towards: the one matching the instance we're in, else the latest synced
function PP:activeSheetID()
    local inInstance = IsInInstance();
    local here = inInstance and self:slug((GetInstanceInfo())) or "";
    local best, bestScore;

    for id, Sheet in pairs(DB.Sheets) do
        if (not Sheet.closedAt) then
            local score = Sheet.lastSyncedAt or 0;

            if (here ~= "") then
                for _, slug in ipairs(Sheet.Instances or {}) do
                    if (slug ~= "" and (here:find(slug, 1, true) or slug:find(here, 1, true))) then
                        score = score + 1e10;
                        break;
                    end
                end
            end

            if (not bestScore or score > bestScore) then
                best, bestScore = id, score;
            end
        end
    end

    return best;
end

function PP:activeRaidKey()
    local Sheet = self:sheet(self:activeSheetID());
    return Sheet and Sheet.raidKey;
end

function PP:sheetLabel(id)
    if (not self:sheet(id)) then
        return tostring(id);
    end

    local at, exact = self:sheetDate(id);
    return ("%s%s  %s"):format(exact and "" or "~", date("%a %d %b", at), id);
end

--[[ DELETE ]]

--- Remove a sheet record. Points stay as they are (reopen the week first to take its points back).
function PP:deleteSheet(id)
    local Sheet = self:sheet(id);
    if (not Sheet) then
        return;
    end

    DB.Sheets[id] = nil;

    local Raid = self:raid(Sheet.raidKey);
    if (Raid and Raid.currentSheet == id) then
        Raid.currentSheet = self:sheetIDs(Sheet.raidKey)[1];
    end

    self:print(("Deleted sheet %s."):format(id));
    self:notify();
end

--- Remove a raid, its points and its sheets. The ledger keeps its history.
function PP:deleteRaid(raidKey)
    local Raid = self:raid(raidKey);
    if (not Raid) then
        return;
    end

    for _, id in ipairs(self:sheetIDs(raidKey)) do
        DB.Sheets[id] = nil;
    end

    DB.Raids[raidKey] = nil;
    DB.UI.Collapsed[raidKey] = nil;

    self:print(("Deleted %s with its points and sheets."):format(Raid.label));
    self:notify();
end

--[[ SYNC ]]

local function overLimit(Reserves, raidKey)
    local limit = PP:rules(raidKey).reserves;
    local Names = {};
    for key, Items in pairs(Reserves) do
        local n = 0;
        for _ in pairs(Items) do
            n = n + 1;
        end
        if (n > limit) then
            tinsert(Names, PP:displayName(key));
        end
    end
    table.sort(Names);

    if (#Names > 0) then
        PP:print(("Reserved more than %d items: %s"):format(limit, table.concat(Names, ", ")));
    end
end

local function fallbackInstances()
    local inInstance, instanceType = IsInInstance();
    if (inInstance and instanceType == "raid") then
        return { PP:slug((GetInstanceInfo())), };
    end

    return { "unknown", };
end

--- Rule 6: a new week resets every item with points that the player didn't reserve again
function PP:resetNotReservedAgain(Sheet)
    local Raid = self:raid(Sheet.raidKey);
    local reset = 0;

    for key, Items in pairs(Raid.Points) do
        for itemID in pairs(Items) do
            if (not (Sheet.Reserves[key] and Sheet.Reserves[key][itemID])) then
                self:setPoints(Sheet.raidKey, key, itemID, 0, "reset", Sheet.id, true);
                reset = reset + 1;
            end
        end
    end

    return reset;
end

--- Start a sheet record for a new softres ID under an existing campaign
function PP:createSheet(Data, raidKey)
    local Raid = self:raid(raidKey);
    if (not Raid) then
        return;
    end

    local Instances = Data.Instances or fallbackInstances();
    local now = time();

    local Sheet = {
        id = Data.id,
        raidKey = raidKey,
        Instances = Instances,
        url = Data.url,
        note = Data.note,
        createdAt = Data.createdAt,
        updatedAt = Data.updatedAt,
        lockedAt = Data.lockedAt,
        raidStartsAt = Data.raidStartsAt,
        firstSyncedAt = now,
        lastSyncedAt = now,
        Reserves = Data.Reserves,
        Classes = Data.Classes,
        Syncs = { { at = now, updatedAt = Data.updatedAt, first = true, reserves = countPairs(Data.Reserves), }, },
        Seen = {},
        Bosses = {},
        Rolled = {},
        Wins = {},
        Bench = {},
        Override = {},
    };

    DB.Sheets[Data.id] = Sheet;
    Raid.currentSheet = Data.id;
    self:rememberClasses(Data.Classes);

    local function finish()
        if (self:rules(raidKey).resetNotReserved) then
            self:print(("New sheet %s for %s: %d reserves, %d items reset (not reserved again)."):format(
                Data.id, Raid.label, Sheet.Syncs[1].reserves, self:resetNotReservedAgain(Sheet)
            ));
        else
            self:print(("New sheet %s for %s: %d reserves."):format(Data.id, Raid.label, Sheet.Syncs[1].reserves));
        end
        overLimit(Sheet.Reserves, raidKey);
        self:notify();
    end

    -- Points from before raid tracking existed: offer to adopt them into the first real raid
    local Unassigned = self:raid(self.UNASSIGNED);
    if (Unassigned and next(Unassigned.Points)) then
        StaticPopup_Show("GARGULPITYPOINTS_ADOPT", Raid.label, nil, {
            accept = function ()
                self:print(("Moved %d entries into %s."):format(self:movePoints(self.UNASSIGNED, raidKey), Raid.label));
                finish();
            end,
            cancel = finish,
        });
        return;
    end

    finish();
end

function PP:updateSheet(Sheet, Data)
    local Added, Removed = {}, {};

    for key, Items in pairs(Data.Reserves) do
        for itemID in pairs(Items) do
            if (not (Sheet.Reserves[key] and Sheet.Reserves[key][itemID])) then
                tinsert(Added, { key, itemID, });
            end
        end
    end
    for key, Items in pairs(Sheet.Reserves) do
        for itemID in pairs(Items) do
            if (not (Data.Reserves[key] and Data.Reserves[key][itemID])) then
                tinsert(Removed, { key, itemID, });
            end
        end
    end

    Sheet.lastSyncedAt = time();
    Sheet.lockedAt = Data.lockedAt or Sheet.lockedAt;
    Sheet.raidStartsAt = Data.raidStartsAt or Sheet.raidStartsAt;
    Sheet.createdAt = Sheet.createdAt or Data.createdAt;
    Sheet.note = Data.note or Sheet.note;
    self:rememberClasses(Data.Classes);

    if (#Added == 0 and #Removed == 0) then
        self:print(("Sheet %s is already up to date."):format(Sheet.id));
        self:notify();
        return;
    end

    Sheet.Reserves = Data.Reserves;
    Sheet.Classes = Data.Classes;
    Sheet.updatedAt = Data.updatedAt;
    tinsert(Sheet.Syncs, {
        at = time(), updatedAt = Data.updatedAt, Added = Added, Removed = Removed, reserves = countPairs(Data.Reserves),
    });

    self:print(("Sheet %s updated: %d reserves added, %d removed. Points unchanged."):format(Sheet.id, #Added, #Removed));
    overLimit(Sheet.Reserves, Sheet.raidKey);
    self:notify();
end

--- Read Gargul's current soft reserves and create or update the matching sheet
function PP:syncFromGargul()
    local Data = self:readSoftresSheet();
    if (not Data or not next(Data.Reserves)) then
        return self:print("No soft reserves imported in Gargul. Import a softres.it raid with |cffffff00/gl sr|r first.");
    end

    local Sheet = self:sheet(Data.id);
    if (Sheet) then
        return self:updateSheet(Sheet, Data);
    end

    -- New softres ID: it has to go into a campaign, picked (or created) now
    Data.Instances = Data.Instances or fallbackInstances();
    self:showCampaignPicker(Data, function (raidKey)
        PP:createSheet(Data, raidKey);
    end);
end

--[[ ROLLS, WINS AND ATTENDANCE ]]

function PP:recordRoll(playerName)
    local Sheet = self:sheet(self:activeSheetID());
    if (Sheet) then
        Sheet.Rolled[self:key(playerName)] = true;
    end
end

--- Returns the points the winner had on the item, and whether the campaign's rules reset them
function PP:recordWin(playerName, itemID)
    local id = self:activeSheetID();
    local Sheet = self:sheet(id);
    if (not Sheet) then
        return 0, false;
    end

    local key = self:key(playerName);
    itemID = tonumber(itemID);
    Sheet.Wins[key] = Sheet.Wins[key] or {};
    Sheet.Wins[key][itemID] = true;

    local had = self:getPoints(Sheet.raidKey, key, itemID);
    local reset = self:rules(Sheet.raidKey).resetOnWin and had > 0;
    if (reset) then
        self:setPoints(Sheet.raidKey, key, itemID, 0, "win", id);
    else
        self:notify();
    end

    return had, reset;
end

--- Record everyone online in the raid group against the active sheet. reason: boss name, "timer" or "manual".
function PP:takeSnapshot(reason)
    local manual = reason == "manual";

    if (not IsInRaid()) then
        return manual and self:print("You're not in a raid group.");
    end

    local id = self:activeSheetID();
    local Sheet = self:sheet(id);
    if (not Sheet) then
        return manual and self:print("No open sheet to record attendance on. Sync the softres sheet first.");
    end

    local now, count = time(), 0;
    local isBoss = reason ~= "timer" and not manual;

    for i = 1, GetNumGroupMembers() do
        local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i);
        if (name and online) then
            local key = self:key(name);
            local Seen = Sheet.Seen[key] or { first = now, snapshots = 0, bosses = 0, };
            Seen.last = now;
            Seen.snapshots = Seen.snapshots + 1;
            if (isBoss) then
                Seen.bosses = Seen.bosses + 1;
            end
            Sheet.Seen[key] = Seen;
            count = count + 1;
        end
    end

    if (isBoss) then
        tinsert(Sheet.Bosses, { at = now, name = reason, count = count, });
    end
    Sheet.lastSnapshotAt = now;

    if (manual or isBoss) then
        self:print(("Attendance recorded for %s: %d players%s."):format(
            self:raidLabel(Sheet.raidKey), count, isBoss and (" (" .. reason .. ")") or ""
        ));
    end

    self:notify();
end

function PP:autoAttended(Sheet, key)
    return Sheet.Seen[key] ~= nil or Sheet.Rolled[key] == true or Sheet.Wins[key] ~= nil;
end

function PP:isAttended(Sheet, key)
    if (Sheet.Override[key] ~= nil) then
        return Sheet.Override[key];
    end

    return self:autoAttended(Sheet, key);
end

function PP:setAttended(id, key, value)
    local Sheet = self:sheet(id);
    if (not Sheet or Sheet.closedAt) then
        return;
    end

    -- Only store an override when it disagrees with what was recorded
    if (value == self:autoAttended(Sheet, key)) then
        Sheet.Override[key] = nil;
    else
        Sheet.Override[key] = value;
    end
    self:notify();
end

function PP:setBench(id, key, value)
    local Sheet = self:sheet(id);
    if (not Sheet or Sheet.closedAt) then
        return;
    end

    Sheet.Bench[key] = value and true or nil;
    self:notify();
end

--[[ CLOSE WEEK ]]

--- What closing the week would do: { players, attended, bench, absent, Awards = { { key, itemID, from, to } } }
function PP:closeWeekPlan(id)
    local Sheet = self:sheet(id);
    local Plan = { players = 0, attended = 0, bench = 0, absent = 0, Awards = {}, };
    if (not Sheet) then
        return Plan;
    end

    local Rules = self:rules(Sheet.raidKey);
    local step, cap = Rules.perWeek, Rules.cap;
    Plan.Rules = Rules;

    for key, Items in pairs(Sheet.Reserves) do
        Plan.players = Plan.players + 1;

        local attended, bench = self:isAttended(Sheet, key), Sheet.Bench[key] == true;
        if (attended) then
            Plan.attended = Plan.attended + 1;
        elseif (bench) then
            Plan.bench = Plan.bench + 1;
        else
            Plan.absent = Plan.absent + 1;
        end

        if (attended or bench) then
            for itemID in pairs(Items) do
                if (not (Sheet.Wins[key] and Sheet.Wins[key][itemID])) then
                    local from = self:getPoints(Sheet.raidKey, key, itemID);
                    local to = from + step;
                    if (cap > 0) then
                        to = math.min(to, cap);
                    end
                    if (to ~= from) then
                        tinsert(Plan.Awards, { key = key, itemID = itemID, from = from, to = to, });
                    end
                end
            end
        end
    end

    return Plan;
end

function PP:closeWeek(id)
    local Sheet = self:sheet(id);
    if (not Sheet or Sheet.closedAt) then
        return;
    end

    local Plan = self:closeWeekPlan(id);
    for _, Award in ipairs(Plan.Awards) do
        self:setPoints(Sheet.raidKey, Award.key, Award.itemID, Award.to, "week", id, true);
    end

    Sheet.closedAt = time();
    Sheet.closedBy = self:me();
    Sheet.closeSummary = {
        attended = Plan.attended, bench = Plan.bench, absent = Plan.absent, awards = #Plan.Awards,
        Rules = CopyTable(Plan.Rules), -- Rules can change later; keep what this close used
    };

    self:print(("Closed week %s for %s: %d items gained points (%d attended, %d bench, %d absent)."):format(
        id, self:raidLabel(Sheet.raidKey), #Plan.Awards, Plan.attended, Plan.bench, Plan.absent
    ));
    self:notify();
end

--- Undo a Close week: subtract what it added, keep everything else
function PP:reopenWeek(id)
    local Sheet = self:sheet(id);
    if (not Sheet or not Sheet.closedAt) then
        return;
    end

    for _, Entry in ipairs(self:ledger(Sheet.raidKey, id)) do
        if (Entry.reason == "week" and Entry.delta > 0) then
            local current = self:getPoints(Sheet.raidKey, Entry.player, Entry.itemID);
            self:setPoints(Sheet.raidKey, Entry.player, Entry.itemID, current - Entry.delta, "reopen", id, true);
        end
    end

    Sheet.closedAt, Sheet.closedBy, Sheet.closeSummary = nil, nil, nil;
    self:print(("Reopened week %s for %s."):format(id, self:raidLabel(Sheet.raidKey)));
    self:notify();
end

--- Points this sheet's Close week gave, per item: { [playerKey] = { [itemID] = delta } }
function PP:weekGains(id)
    local Gains = {};
    for _, Entry in ipairs(self:ledger(nil, id)) do
        if (Entry.reason == "week" or Entry.reason == "reopen") then
            Gains[Entry.player] = Gains[Entry.player] or {};
            Gains[Entry.player][Entry.itemID] = (Gains[Entry.player][Entry.itemID] or 0) + Entry.delta;
        end
    end

    -- A close + reopen nets out to 0, drop those
    for key, Items in pairs(Gains) do
        for itemID, delta in pairs(Items) do
            if (delta == 0) then
                Items[itemID] = nil;
            end
        end
        if (not next(Items)) then
            Gains[key] = nil;
        end
    end

    return Gains;
end

--[[ DIALOGS ]]

StaticPopupDialogs["GARGULPITYPOINTS_ADOPT"] = {
    text = "You have points from before raid tracking.\n\nMove them into |cffffd100%s|r?",
    button1 = YES,
    button2 = NO,
    OnAccept = function (_, data) data.accept(); end,
    OnCancel = function (_, data) data.cancel(); end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

--[[ BOOT ]]

function PP:initSheets()
    DB = self.db;

    local Events = CreateFrame("Frame");
    Events:RegisterEvent("ENCOUNTER_END");
    Events:SetScript("OnEvent", PP.safe(function (_, _, _, encounterName, _, _, success)
        if (success == 1 and DB.Settings.recordAttendance and IsInRaid()) then
            PP:takeSnapshot(encounterName or "Boss");
        end
    end));

    -- Timer snapshots while inside a raid instance, as a fallback for nights without kills
    C_Timer.NewTicker(30, PP.safe(function ()
        if (not DB.Settings.recordAttendance or not IsInRaid()) then
            return;
        end

        local inInstance, instanceType = IsInInstance();
        if (not inInstance or instanceType ~= "raid") then
            return;
        end

        local Sheet = PP:sheet(PP:activeSheetID());
        if (Sheet and time() - (Sheet.lastSnapshotAt or 0) >= DB.Settings.snapshotMinutes * 60) then
            PP:takeSnapshot("timer");
        end
    end));
end
