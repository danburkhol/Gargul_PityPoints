--[[
    Every hook into Gargul lives here. See docs/GargulIntegration.md before changing anything.

      readSoftresSheet         -> Gargul's softres data + the raw softres.it export (instances, lockedAt, ...)
      GL.SOFTRES_IMPORTED      -> sync the sheet (asks for the team on a new softres id)
      GL.ROLLOFF_ROLL_ACCEPTED -> add pity points to the roll itself, so Gargul ranks by total; record the roller
      buildSortedRollData      -> (wrapped) show "PP raw+bonus" in the roll window's Note column
      GL.ROLLOFF_STOPPED       -> announce the results
      GL.ITEM_AWARDED          -> record the win on the active sheet, reset points on win
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
    if (not self.db.Settings.autoSync) then
        return self:print("Soft reserves imported. Auto sync is off, click |cffffff00Sync SR|r in the |cffffff00/pp|r window.");
    end

    self:syncFromGargul();
end

--[[ ROLLS: ADD BONUS TO THE ROLL ITSELF ]]

--- Fired by Gargul right after it inserts a Roll and right before it refreshes the roll window
function PP:onRollAccepted()
    local RollOff = GL.RollOff;
    if (not RollOff:startedByMe()) then
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
    if (not raidKey) then
        return;
    end

    local bonus = self:getPoints(raidKey, Roll.player, itemID);
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

--[[ ROLL WINDOW: SHOW RAW + BONUS ]]

local function findRoll(player, amount)
    for _, Roll in pairs(GL.RollOff.CurrentRollOff.Rolls or {}) do
        if (Roll.ppRaw and Roll.player == player and Roll.amount == amount) then
            return Roll;
        end
    end
end

local function wrapRollTable()
    local original = GL.RollOff.buildSortedRollData;

    GL.RollOff.buildSortedRollData = function (RollOff, ...)
        local Entries = original(RollOff, ...);

        for _, Entry in ipairs(Entries) do
            local Roll = findRoll(Entry.player, Entry.amount);
            Entry.ppRaw = Roll and Roll.ppRaw or Entry.amount;
            Entry.ppBonus = Roll and Roll.ppBonus or 0;

            if (Entry.ppBonus > 0) then
                -- Shown in Gargul's "Note" column, the "Roll" column already shows the total
                tinsert(Entry.rollNotes, 1, ("|cff00ff00PP %d+%d|r"):format(Entry.ppRaw, Entry.ppBonus));
            end
        end

        return Entries;
    end
end

--[[ ANNOUNCE WHEN THE ROLL-OFF ENDS ]]

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

function PP:announceResults()
    -- Same order the loot master sees in the roll window (softres / prio brackets first, then total)
    local Entries = GL.RollOff:buildSortedRollData();
    if (#Entries == 0) then
        return;
    end

    local Seen = {};
    local Lines = {};
    for _, Entry in ipairs(Entries) do
        if (not Seen[Entry.player]) then
            Seen[Entry.player] = true;

            local name = GL:disambiguateName(Entry.player);
            local raw, bonus = Entry.ppRaw or Entry.amount, Entry.ppBonus or 0;
            if (#Lines == 0) then
                tinsert(Lines, ("%s wins with a roll of %d and points of %d for a total of %d."):format(name, raw, bonus, Entry.amount));
            else
                tinsert(Lines, ("%s: %d + %d = %d"):format(name, raw, bonus, Entry.amount));
            end
        end
    end

    send(Lines[1]);
    if (#Lines > 1) then
        send("Others: " .. table.concat(Lines, ", ", 2));
    end
end

function PP:onRollOffStopped()
    if (not self.db.Settings.announce or not GL.RollOff:startedByMe()) then
        return;
    end

    -- Gargul keeps accepting rolls for RollTracking.rollOffEndLeeway seconds after the stop
    local leeway = GL.Settings:get("RollTracking.rollOffEndLeeway", 1) or 1;
    C_Timer.After(leeway + 0.5, safe(function () PP:announceResults(); end));
end

--[[ WINS ]]

function PP:onItemAwarded(_, AwardEntry)
    if (type(AwardEntry) ~= "table" or not AwardEntry.awardedTo or not AwardEntry.itemID) then
        return;
    end

    local had = self:recordWin(AwardEntry.awardedTo, AwardEntry.itemID);
    if (self.db.Settings.resetOnWin and had > 0) then
        self:print(("%s won %s, pity points reset (had %d)."):format(
            GL:disambiguateName(AwardEntry.awardedTo), AwardEntry.itemLink or AwardEntry.itemID, had
        ));
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

    if (not isCommand or not self.db.Settings.whisperReply or not mayReply() or throttled(sender)) then
        return;
    end

    whisper(self:pityPointsReply(sender), sender);
end

--- Runs after Gargul's own !sr reply: the points on each item the player currently reserves
function PP:onSoftResWhisper(message, sender)
    if (not self.db.Settings.srFollowUp or type(message) ~= "string") then
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
        tinsert(Parts, ("%s %d"):format(self:itemLink(itemID) or self:itemName(itemID), self:getPoints(raidKey, sender, itemID)));
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

    self:print("Injected 3 fake rolls. Expect Alice 50+20=70 above Bob 65. Results announce when the timer ends.");
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
    GL.Events:register("PityPoints.RollOffStopped", "GL.ROLLOFF_STOPPED", safe(function () PP:onRollOffStopped(); end));
    GL.Events:register("PityPoints.ItemAwarded", "GL.ITEM_AWARDED", safe(function (...) PP:onItemAwarded(...); end));

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

    self:print(("Hooked into Gargul %s. Type |cffffff00/pp|r to open the manager."):format(tostring(GL.version)));
end
