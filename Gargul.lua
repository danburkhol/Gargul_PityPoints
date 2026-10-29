--[[
    Every hook into Gargul lives here. See docs/GargulIntegration.md before changing anything.

      readSoftresSheet         -> Gargul's softres data + the raw softres.it export (instances, lockedAt, ...)
      GL.SOFTRES_IMPORTED      -> sync the sheet (asks for the team on a new softres id)
      GL.ROLLOFF_ROLL_ACCEPTED -> add pity points to the roll itself, so Gargul ranks by total; record the roller
      buildSortedRollData      -> (wrapped) show "PP raw+bonus" in the Note column, add "No roll yet" rows for missing reservers
      GL.ROLLOFF_STARTED       -> refresh the roll window so missing reservers show before anyone rolls
      GL.ROLLOFF_STOPPED       -> raid warning naming reservers who didn't roll
      GL.ITEM_AWARDED          -> record the win on the active sheet, reset points on win, announce the results
      GL.LOOT_ANNOUNCED        -> auto-award items only one raider soft reserved
      CHAT_MSG_WHISPER / !sr   -> !pp reply and the follow-up to Gargul's !sr reply

    Hooks are installed once and check PP:gargulFeature(setting) each time they run, so every
    feature (and the "gargul" master switch) can be toggled in Settings without a /reload.
]]

local _, PP = ...;

local GL;
local safe = PP.safe;

--[[ SOFT RESERVES ]]

function PP:isReserved(playerName, itemID)
    local key = self:key(playerName);
    itemID = tonumber(itemID);

    if (self.TestReserves[key] and self.TestReserves[key][itemID]) then
        return true;
    end

    return GL and GL.SoftRes:itemIDIsReservedByPlayer(itemID, playerName) or false;
end

--- Decode the raw softres.it export Gargul keeps in MetaData.importString (Gargul drops instances, lockedAt, note, order)
local function decodeImportString(importString)
    if (type(importString) ~= "string" or importString == "") then
        return nil;
    end

    local ok, Data = pcall(function ()
        local raw = GL.Base64.decode(importString);
        raw = LibStub("LibDeflate"):DecompressZlib(raw);
        return GL.JSON:decode(raw);
    end);

    if (ok and type(Data) == "table" and type(Data.metadata) == "table") then
        return Data;
    end
end

--[[
    Everything a sheet needs from Gargul:
    { id, url, note, createdAt, updatedAt, lockedAt, Instances, Reserves = { [key] = { [itemID] = order } }, Classes }
]]
function PP:readSoftresSheet()
    if (not GL) then
        return nil;
    end

    local Meta = GL.DB:get("SoftRes.MetaData", {}) or {};
    local Sheet = {
        id = (Meta.id and Meta.id ~= "") and Meta.id or ("import-" .. (Meta.importedAt or time())),
        url = Meta.url,
        createdAt = tonumber(Meta.createdAt),
        updatedAt = tonumber(Meta.updatedAt),
        raidStartsAt = tonumber(Meta.raidStartsAt),
        Reserves = {},
        Classes = {},
    };

    local Order = {};
    local Export = decodeImportString(Meta.importString);
    if (Export) then
        local Instances = {};
        for _, slug in ipairs(type(Export.metadata.instances) == "table" and Export.metadata.instances or {}) do
            if (type(slug) == "string" and slug ~= "") then
                tinsert(Instances, PP:slug(slug));
            end
        end
        Sheet.Instances = #Instances > 0 and Instances or nil;
        Sheet.lockedAt = tonumber(Export.metadata.lockedAt);
        Sheet.raidStartsAt = tonumber(Export.metadata.raidStartsAt) or Sheet.raidStartsAt;
        Sheet.createdAt = tonumber(Export.metadata.created_at) or Sheet.createdAt;
        Sheet.note = type(Export.metadata.note) == "string" and Export.metadata.note or nil;

        for _, Entry in ipairs(type(Export.softreserves) == "table" and Export.softreserves or {}) do
            if (type(Entry.name) == "string" and type(Entry.items) == "table") then
                local key = strlower(Entry.name);
                Order[key] = Order[key] or {};
                for _, Item in ipairs(Entry.items) do
                    local itemID = tonumber(Item.id);
                    if (itemID) then
                        Order[key][itemID] = tonumber(Item.order) or 0;
                    end
                end
            end
        end
    end

    -- Gargul stores a missing raid start as 0
    if (Sheet.raidStartsAt and Sheet.raidStartsAt <= 0) then
        Sheet.raidStartsAt = nil;
    end

    -- Reserves come from Gargul's materialized data, so Gargul's name fixes are respected
    local Materialized = GL.SoftRes.MaterializedData or {};
    for name, Details in pairs(Materialized.DetailsByPlayerName or {}) do
        for idString in pairs(Details.Items or {}) do
            local itemID = tonumber(idString);
            Sheet.Reserves[name] = Sheet.Reserves[name] or {};
            Sheet.Reserves[name][itemID] = Order[name] and Order[name][itemID] or 0;
        end
    end
    for name, class in pairs(Materialized.ClassByPlayerName or {}) do
        Sheet.Classes[name] = class;
    end

    return Sheet;
end

function PP:onSoftResImported()
    if (not self:gargulFeature()) then
        return;
    end
    if (not self:gargulFeature("autoSync")) then
        return self:print("Soft reserves imported. Auto sync is off, click |cffffff00Sync SR|r in the |cffffff00/pp|r window.");
    end

    self:syncFromGargul();
end

--[[ ROLLS: ADD BONUS TO THE ROLL ITSELF ]]

--- Fired by Gargul right after it inserts a Roll and right before it refreshes the roll window
function PP:onRollAccepted()
    local RollOff = GL.RollOff;
    if (not self:gargulFeature() or not RollOff:startedByMe()) then
        return; -- Only the loot master's numbers matter
    end

    local Rolls = RollOff.CurrentRollOff.Rolls or {};
    local Roll = Rolls[#Rolls];
    if (not Roll or Roll.ppRaw) then
        return; -- Already adjusted
    end

    self:recordRoll(Roll.player);

    local itemID = RollOff.CurrentRollOff.itemID;
    Roll.ppRaw = Roll.amount;
    Roll.ppBonus = 0;

    local raidKey = self:activeRaidKey();
    if (not self:gargulFeature("rollBonus") or (not raidKey and not self.db.Settings.sharePoints)) then
        return;
    end

    local bonus = self:rollPoints(raidKey, Roll.player, itemID);
    if (bonus <= 0) then
        return;
    end

    if (not self:isReserved(Roll.player, itemID)) then
        self:print(("%s has %d points on %s but didn't soft reserve it, so no bonus."):format(
            Roll.player, bonus, RollOff.CurrentRollOff.itemLink or itemID
        ));
        return;
    end

    Roll.ppBonus = bonus;
    -- Gargul sorts, detects ties and stores award history using Roll.amount, so it ranks by total
    Roll.amount = Roll.ppRaw + bonus;
end

--[[ ROLL WINDOW: SHOW RAW + BONUS, AND WHO HASN'T ROLLED ]]

local function findRoll(player, amount)
    for _, Roll in pairs(GL.RollOff.CurrentRollOff.Rolls or {}) do
        if (Roll.ppRaw and Roll.player == player and Roll.amount == amount) then
            return Roll;
        end
    end
end

--- Soft reservers of the current roll-off's item who are in the group and haven't rolled yet (lowercase keys, sorted)
function PP:missingRollers()
    local CurrentRollOff = GL.RollOff.CurrentRollOff;
    local itemID = tonumber(CurrentRollOff.itemID);
    if (not itemID) then
        return {};
    end

    local Rolled = {};
    for _, Roll in pairs(CurrentRollOff.Rolls or {}) do
        Rolled[self:key(Roll.player)] = true;
    end

    local Reservers = GL.SoftRes:byItemID(itemID, true);
    for key, Items in pairs(self.TestReserves) do
        if (Items[itemID]) then
            tinsert(Reservers, key);
        end
    end

    local Missing, Seen = {}, {};
    for _, name in ipairs(Reservers) do
        local key = self:key(name);
        if (not Rolled[key] and not Seen[key]) then
            Seen[key] = true;
            tinsert(Missing, key);
        end
    end
    table.sort(Missing);

    return Missing;
end

-- Set while Gargul fills the loot master's roll window, so only that table gets "No roll yet" rows
local fillingRollWindow = false;

local function missingRollEntry(key)
    return {
        player = key,
        displayName = PP:displayName(key),
        class = PP:playerClass(key) or GL:playerClassByName(key),
        amount = 0, -- lib-st sorts the Roll column numerically
        plusOnes = 0,
        plusOnesRaw = 0,
        classification = "",
        sortPriority = 99999, -- Below every real roll
        rollNotes = { "|cffff4040No roll yet|r", },
        relevantGear = {},
        ppMissing = true,
    };
end

local function wrapRollTable()
    local original = GL.RollOff.buildSortedRollData;

    GL.RollOff.buildSortedRollData = function (RollOff, ...)
        local Entries = original(RollOff, ...);
        if (not PP:gargulFeature()) then
            return Entries;
        end

        local showNote = PP:gargulFeature("rollBonus");
        for _, Entry in ipairs(Entries) do
            local Roll = findRoll(Entry.player, Entry.amount);
            Entry.ppRaw = Roll and Roll.ppRaw or Entry.amount;
            Entry.ppBonus = Roll and Roll.ppBonus or 0;

            if (showNote and Entry.ppBonus > 0) then
                -- Shown in Gargul's "Note" column, the "Roll" column already shows the total
                tinsert(Entry.rollNotes, 1, ("|cff00ff00PP %d+%d|r"):format(Entry.ppRaw, Entry.ppBonus));
            end
        end

        if (fillingRollWindow and PP:gargulFeature("trackMissingRolls") and RollOff:startedByMe()) then
            for _, key in ipairs(PP:missingRollers()) do
                tinsert(Entries, missingRollEntry(key));
            end
        end

        return Entries;
    end

    local refresh = GL.RollOff.refreshRollsTable;
    GL.RollOff.refreshRollsTable = function (...)
        fillingRollWindow = true;
        local ok, err = pcall(refresh, ...);
        fillingRollWindow = false;
        if (not ok) then
            error(err, 0);
        end
    end
end

--[[ ANNOUNCE RESULTS ON AWARD, MISSING ROLLS WHEN THE ROLL-OFF ENDS ]]

local function send(message)
    local channel = PP.db.Settings.channel;

    if (channel == "SELF") then
        return PP:print(message);
    end

    if (channel == "RAID" and not IsInRaid()) then
        channel = "GROUP";
    end

    -- Gargul's helper maps GROUP, falls back from RAID_WARNING and prints locally when solo
    GL:sendChatMessage(message, channel, nil, nil, false);
end

--- Post the winner of an award with roll + points = total, then everyone else's best roll
function PP:announceAward(AwardEntry)
    local item = AwardEntry.itemLink or self:itemName(AwardEntry.itemID);
    local winner = self:key(AwardEntry.awardedTo);

    -- AwardEntry.Rolls is Gargul's copy of the roll-off's rolls, our ppRaw / ppBonus included
    local Best = {};
    for _, Roll in pairs(AwardEntry.Rolls or {}) do
        local key = Roll.player and self:key(Roll.player);
        if (key and (not Best[key] or (Roll.amount or 0) > (Best[key].amount or 0))) then
            Best[key] = Roll;
        end
    end

    -- raw, bonus, total
    local function describe(Roll)
        return Roll.ppRaw or Roll.amount or 0, Roll.ppBonus or 0, Roll.amount or 0;
    end

    local name = GL:disambiguateName(AwardEntry.awardedTo);
    local Won = Best[winner];
    if (Won) then
        send(("%s wins %s with a roll of %d and points of %d for a total of %d."):format(name, item, describe(Won)));
    elseif (next(Best) == nil and self:isReserved(AwardEntry.awardedTo, AwardEntry.itemID)) then
        return send(("%s wins %s as the only soft reserve."):format(name, item));
    else
        send(("%s wins %s."):format(name, item));
    end

    local Others = {};
    for key, Roll in pairs(Best) do
        if (key ~= winner) then
            tinsert(Others, Roll);
        end
    end
    table.sort(Others, function (a, b)
        return (a.amount or 0) > (b.amount or 0);
    end);

    local Parts = {};
    for _, Roll in ipairs(Others) do
        local raw, bonus, total = describe(Roll);
        tinsert(Parts, ("%s: %d + %d = %d"):format(GL:disambiguateName(Roll.player), raw, bonus, total));
    end
    if (#Parts > 0) then
        send("Others: " .. table.concat(Parts, ", "));
    end
end

function PP:announceMissingRolls()
    local Missing = self:missingRollers();
    if (#Missing == 0) then
        return;
    end

    local Names = {};
    for _, key in ipairs(Missing) do
        tinsert(Names, self:displayName(key));
    end

    local CurrentRollOff = GL.RollOff.CurrentRollOff;
    GL:sendChatMessage(("No roll on %s from: %s"):format(
        CurrentRollOff.itemLink or self:itemName(CurrentRollOff.itemID), table.concat(Names, ", ")
    ), "RAID_WARNING", nil, nil, false);
end

function PP:onRollOffStarted()
    if (self:gargulFeature("trackMissingRolls") and GL.RollOff:startedByMe()) then
        GL.RollOff:refreshRollsTable(); -- Show the reservers before anyone rolls
    end
end

function PP:onRollOffStopped()
    if (not self:gargulFeature("trackMissingRolls") or not GL.RollOff:startedByMe()) then
        return;
    end

    -- Gargul keeps accepting rolls for RollTracking.rollOffEndLeeway seconds after the stop
    local leeway = GL.Settings:get("RollTracking.rollOffEndLeeway", 1) or 1;
    C_Timer.After(leeway + 0.5, safe(function () PP:announceMissingRolls(); end));
end

--[[ WINS ]]

function PP:onItemAwarded(_, AwardEntry)
    if (type(AwardEntry) ~= "table" or not AwardEntry.awardedTo or not AwardEntry.itemID) then
        return;
    end

    -- Before recordWin, so the announcement still sees the points that are about to reset.
    -- Awards other officers make reach us over comms too; only the one who awarded announces.
    if (self:gargulFeature("announce") and GL:iEquals(AwardEntry.awardedBy, GL.User.fqn)) then
        self:announceAward(AwardEntry);
    end

    if (not self:gargulFeature("trackWins")) then
        return;
    end

    local had, reset = self:recordWin(AwardEntry.awardedTo, AwardEntry.itemID);
    if (reset) then
        self:print(("%s won %s, pity points reset (had %d)."):format(
            GL:disambiguateName(AwardEntry.awardedTo), AwardEntry.itemLink or AwardEntry.itemID, had
        ));
    end
end

--[[ AUTO-AWARD ITEMS ONLY ONE RAIDER SOFT RESERVED ]]

-- sourceGUID .. ":" .. itemID of drops already auto-awarded this session, so reopening the loot window doesn't award again
local autoAwarded = {};

--- The single in-group reserver of an item, or nil when nobody or several players reserved it
local function soleReserver(itemID)
    local Keys = {};
    for _, name in ipairs(GL.SoftRes:byItemID(itemID, true)) do
        Keys[PP:key(name)] = name;
    end

    local only, name = next(Keys);
    if (only and next(Keys, only) == nil) then
        return name;
    end
end

function PP:onLootAnnounced()
    if (not self:gargulFeature("autoAwardSR") or not GL.User.isMasterLooter or GL.GetLootMethod() ~= "master") then
        return;
    end

    local Done = {}; -- One copy per item: duplicates in the same window are left for a roll
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot);
        local itemID = link and GL:getItemIDFromLink(link);
        local source = GetLootSourceInfo(slot) or "?";
        local id = itemID and (source .. ":" .. itemID);

        if (itemID and not Done[itemID]) then
            Done[itemID] = true;

            local winner = not autoAwarded[id] and soleReserver(itemID);
            if (winner) then
                autoAwarded[id] = true;
                self:print(("Auto-awarding %s to %s, the only soft reserve in the raid."):format(link, self:displayName(self:key(winner))));
                GL.AwardedLoot:addWinner({ winner = winner, itemLink = link, });
            end
        end
    end
end

--[[ WHISPERS: !pp AND THE !sr FOLLOW-UP ]]

local WHISPER_PREFIX = "Pity points ";
local MAX_WHISPER = 250; -- Chat messages cap at 255 characters
local REPLY_THROTTLE = 10; -- Seconds between replies to the same player
local lastReplyAt = {};

--- Pack "label: part, part, ..." into as few whisper-sized lines as possible
local function chunkLines(Lines, label, Parts)
    local line = label;
    local first = true;

    for _, part in ipairs(Parts) do
        local separator = first and "" or ", ";
        if (#line + #separator + #part > MAX_WHISPER and not first) then
            tinsert(Lines, line);
            line, separator = label, "";
        end
        line = line .. separator .. part;
        first = false;
    end

    tinsert(Lines, line);
end

--- The lines a !pp whisper gets: every raid where the player has points
function PP:pityPointsReply(playerName)
    local key = self:key(playerName);
    local Lines = {};

    for _, raidKey in ipairs(self:raidKeys()) do
        local Items = self:raid(raidKey).Points[key];
        if (Items) then
            local Parts = {};
            for itemID, points in pairs(Items) do
                tinsert(Parts, ("%s %d"):format(self:itemLink(itemID) or self:itemName(itemID), points));
            end
            table.sort(Parts);
            chunkLines(Lines, ("%s(%s): "):format(WHISPER_PREFIX, self:raidLabel(raidKey)), Parts);
        end
    end

    if (#Lines == 0) then
        Lines[1] = WHISPER_PREFIX .. ": you don't have any pity points yet.";
    end

    return Lines;
end

local function whisper(Lines, target)
    for _, line in ipairs(Lines) do
        -- false = no "{rt3} Gargul :" prefix
        GL:sendChatMessage(line, "WHISPER", nil, target, false);
    end
end

local function throttled(sender)
    local key = strlower(sender);
    if (lastReplyAt[key] and GetTime() - lastReplyAt[key] < REPLY_THROTTLE) then
        return true;
    end

    lastReplyAt[key] = GetTime();
    return false;
end

-- Same rule Gargul uses for !sr, so only the loot master / assists answer and players don't get duplicates
local function mayReply()
    return GL.SoftRes.userIsAllowedToBroadcast == nil or GL.SoftRes:userIsAllowedToBroadcast();
end

function PP:onWhisper(message, sender)
    message = strlower(strtrim(message or ""));
    local isCommand = message == "!pp" or message == "!pitypoints"
        or message:find("^!pp%s") or message:find("^!pitypoints%s");

    if (not isCommand or not self:gargulFeature("whisperReply") or not mayReply() or throttled(sender)) then
        return;
    end

    whisper(self:pityPointsReply(sender), sender);
end

--- Runs after Gargul's own !sr reply: the points on each item the player currently reserves
function PP:onSoftResWhisper(message, sender)
    if (not self:gargulFeature("srFollowUp") or type(message) ~= "string") then
        return;
    end

    local isCommand = false;
    for _, prefix in ipairs(GL:explode(Gargul_L["!sr|!softres|!softreserve"], "|") or {}) do
        if (GL:strStartsWith(message, prefix)) then
            isCommand = true;
            break;
        end
    end
    if (not isCommand) then
        return;
    end

    -- The raid of the sheet Gargul has loaded right now
    local Sheet = self:sheet(GL.DB:get("SoftRes.MetaData.id"));
    local raidKey = Sheet and Sheet.raidKey or self:activeRaidKey();
    local Reserves = GL:tableGet(GL.SoftRes.MaterializedData, "DetailsByPlayerName." .. self:key(sender) .. ".Items", {});
    if (not raidKey or not next(Reserves)) then
        return;
    end

    local Parts = {};
    for idString in pairs(Reserves) do
        local itemID = tonumber(idString);
        tinsert(Parts, ("%s %d"):format(self:itemLink(itemID) or self:itemName(itemID), self:rollPoints(raidKey, sender, itemID)));
    end
    table.sort(Parts);

    local Lines = {};
    chunkLines(Lines, ("%s(%s): "):format(WHISPER_PREFIX, self:raidLabel(raidKey)), Parts);

    -- Gargul answers once its item links have loaded, so follow up a moment later
    C_Timer.After(1.5, function ()
        whisper(Lines, sender);
    end);
end

--[[ SOLO TEST ]]

function PP:runTest()
    local RollOff = GL.RollOff;
    local itemID = RollOff.CurrentRollOff.itemID;
    if (not RollOff.inProgress or not RollOff:startedByMe() or not itemID) then
        return self:print("Start a roll-off first: |cffffff00/gl roll [item]|r then click Start, then run |cffffff00/pp test|r.");
    end

    if (not self:gargulFeature("rollBonus")) then
        return self:print("Adding points to rolls is off: turn on |cffffff00Gargul integration|r and |cffffff00Add points to rolls|r in |cffffff00/pp config|r.");
    end

    local raidKey = self:activeRaidKey();
    if (not raidKey) then
        return self:print("No open sheet: import a softres sheet in Gargul and sync it first (|cffffff00/pp sync|r).");
    end

    -- Two fake raiders: Alice reserved the item and has 20 points, Bob didn't reserve it
    self.TestReserves.alice = { [itemID] = true, };
    self:setPoints(raidKey, "Alice", itemID, 20, "manual", self:activeSheetID());

    for _, Fake in ipairs({
        { player = "Alice", class = "mage", amount = 50, },
        { player = "Bob", class = "warrior", amount = 65, },
        { player = GL.User.name, class = strlower(select(2, UnitClass("player"))), amount = math.random(1, 100), },
    }) do
        -- Mirror what RollOff:processRoll does after it parses a CHAT_MSG_SYSTEM roll
        tinsert(RollOff.CurrentRollOff.Rolls, {
            player = Fake.player, class = Fake.class, amount = Fake.amount,
            min = 1, max = 100, time = GetServerTime(), classification = "MS", priority = 1,
        });
        GL.Events:fire("GL.ROLLOFF_ROLL_ACCEPTED");
        RollOff:refreshRollsTable();
    end

    self:print("Injected 3 fake rolls. Expect Alice 50+20=70 above Bob 65. Award a roll to see the results announced.");
end

--[[ BOOT ]]

function PP:initGargul()
    GL = self:gargul(); -- Gargul publishes itself here "for other developer integrations"
    if (not GL or not GL.Events or not GL.RollOff or not GL.SoftRes) then
        return self:print("Gargul not found, roll integration is disabled.");
    end

    -- Gargul's internal "GL.*" events are fired manually, so registering works regardless of load order.
    -- Gargul pcalls listeners and drops errors, safe() re-surfaces ours.
    GL.Events:register("PityPoints.SoftResImported", "GL.SOFTRES_IMPORTED", safe(function () PP:onSoftResImported(); end));
    GL.Events:register("PityPoints.SoftResCleared", "GL.SOFTRES_CLEARED", safe(function () PP:notify(); end));
    GL.Events:register("PityPoints.RollAccepted", "GL.ROLLOFF_ROLL_ACCEPTED", safe(function () PP:onRollAccepted(); end));
    GL.Events:register("PityPoints.RollOffStarted", "GL.ROLLOFF_STARTED", safe(function () PP:onRollOffStarted(); end));
    GL.Events:register("PityPoints.RollOffStopped", "GL.ROLLOFF_STOPPED", safe(function () PP:onRollOffStopped(); end));
    GL.Events:register("PityPoints.ItemAwarded", "GL.ITEM_AWARDED", safe(function (...) PP:onItemAwarded(...); end));
    GL.Events:register("PityPoints.LootAnnounced", "GL.LOOT_ANNOUNCED", safe(function () PP:onLootAnnounced(); end));

    wrapRollTable();

    -- !pp / !pitypoints
    local Whispers = CreateFrame("Frame");
    Whispers:RegisterEvent("CHAT_MSG_WHISPER");
    Whispers:SetScript("OnEvent", safe(function (_, _, message, sender)
        PP:onWhisper(message, sender);
    end));

    -- Gargul only calls handleWhisperCommand after its own checks (softres loaded, allowed to broadcast, enabled)
    if (type(GL.SoftRes.handleWhisperCommand) == "function") then
        hooksecurefunc(GL.SoftRes, "handleWhisperCommand", safe(function (_, _, message, sender)
            PP:onSoftResWhisper(message, sender);
        end));
    end

    if (self:gargulFeature()) then
        self:print(("Hooked into Gargul %s. Type |cffffff00/pp|r to open the manager."):format(tostring(GL.version)));
    else
        self:print("Gargul integration is off in settings (|cffffff00/pp config|r). Points and the manager still work.");
    end
end
