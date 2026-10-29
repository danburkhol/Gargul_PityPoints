--[[
    Points import: the points export CSV (PP:buildCSV) pasted back in. Each row sets one player's points on one item in an
    existing campaign; pairs not in the CSV are left alone. All or nothing: any error blocks the import.
    Every change is logged with reason "import" and the import's id (ledger batch), so an import can be undone as a whole.
    Design: docs/Design-Import.md. Window: UI/Import.lua.
]]

local _, PP = ...;

local REQUIRED = { "team", "raid", "player", "item_id", "points", };
local MAX_ERRORS = 50;

--- Split CSV text into records of trimmed fields. Handles a BOM, \r\n, quoted fields ("" escapes, commas and newlines inside)
--- and skips blank lines. Returns { { line = n, Fields = { ... } } }, plus true when a quote was left open.
local function parseCSV(text)
    text = text:gsub("^\239\187\191", ""):gsub("\r\n?", "\n");
    if (text:sub(-1) ~= "\n") then
        text = text .. "\n";
    end

    local Records, Fields, Buffer = {}, {}, {};
    local line, recordLine = 1, 1;
    local inQuotes = false;
    local i, n = 1, #text;

    local function endField()
        tinsert(Fields, strtrim(table.concat(Buffer)));
        Buffer = {};
    end

    while (i <= n) do
        local c = text:sub(i, i);

        if (inQuotes) then
            if (c == '"' and text:sub(i + 1, i + 1) == '"') then
                tinsert(Buffer, '"');
                i = i + 1;
            elseif (c == '"') then
                inQuotes = false;
            else
                if (c == "\n") then
                    line = line + 1;
                end
                tinsert(Buffer, c);
            end

        elseif (c == '"') then
            inQuotes = true;

        elseif (c == ",") then
            endField();

        elseif (c == "\n") then
            endField();
            if (table.concat(Fields) ~= "") then
                tinsert(Records, { line = recordLine, Fields = Fields, });
            end
            Fields = {};
            line = line + 1;
            recordLine = line;

        else
            tinsert(Buffer, c);
        end

        i = i + 1;
    end

    return Records, inQuotes;
end

local function wholeNumber(value)
    value = tonumber(value);
    return value and value == math.floor(value) and value or nil;
end

--- Check a pasted CSV against the current points without changing anything.
--- Plan = { rows, unchanged, Changes = { { line, raidKey, key, itemID, before, after } }, Raids = { [raidKey] = changes },
---          Errors = { "Line n: ..." }, ok }. ok = no errors and at least one change.
function PP:planImport(text)
    local Plan = { rows = 0, unchanged = 0, Changes = {}, Raids = {}, Errors = {}, ok = false, };

    local function fail(line, message, ...)
        tinsert(Plan.Errors, ("Line %d: " .. message):format(line, ...));
    end

    local Records, open = parseCSV(text or "");
    if (open) then
        tinsert(Plan.Errors, "A quoted field is never closed (a \" is missing).");
    end

    local Header = tremove(Records, 1);
    if (not Header) then
        tinsert(Plan.Errors, "Paste the CSV, starting with its header row.");
        return Plan;
    end

    local Column = {};
    for i, name in ipairs(Header.Fields) do
        name = strlower(name);
        Column[name] = Column[name] or i;
    end

    for _, name in ipairs(REQUIRED) do
        if (not Column[name]) then
            fail(Header.line, "the header has no %s column. Expected: team,raid,player,item_id,item_name,points,reserved", name);
        end
    end
    if (#Plan.Errors > 0) then
        return Plan;
    end

    local Campaigns, Seen = {}, {};

    for _, Record in ipairs(Records) do
        local line = Record.line;
        local function get(name)
            return Record.Fields[Column[name]] or "";
        end

        local team, raid, player = get("team"), get("raid"), get("player");
        local itemID, points = wholeNumber(get("item_id")), wholeNumber(get("points"));
        Plan.rows = Plan.rows + 1;

        local raidKey;
        if (team ~= "" and raid ~= "") then
            local cacheKey = strlower(team) .. "\n" .. strlower(raid);
            if (Campaigns[cacheKey] == nil) then
                local Instances = {};
                for _, part in ipairs({ strsplit("+", raid), }) do
                    tinsert(Instances, self:slug(part));
                end
                Campaigns[cacheKey] = self:findCampaign(team, Instances) or false;
            end
            raidKey = Campaigns[cacheKey];
        end

        if (team == "" or raid == "") then
            fail(line, "team and raid are required.");
        elseif (not raidKey) then
            fail(line, "there's no campaign for team \"%s\" and raid \"%s\". Create it in the sidebar first.", team, raid);
        elseif (player == "") then
            fail(line, "player is empty.");
        elseif (not itemID or itemID <= 0) then
            fail(line, "item_id \"%s\" isn't an item id.", get("item_id"));
        elseif (not points or points < 0) then
            fail(line, "points \"%s\" must be a whole number, 0 or more.", get("points"));
        else
            local key = self:key(player);
            local id = raidKey .. "|" .. key .. "|" .. itemID;

            if (Seen[id]) then
                fail(line, "%s on item %d in %s is already set on line %d.", player, itemID, self:raidLabel(raidKey), Seen[id]);
            else
                Seen[id] = line;
                local before = self:getPoints(raidKey, key, itemID);
                if (before == points) then
                    Plan.unchanged = Plan.unchanged + 1;
                else
                    tinsert(Plan.Changes, { line = line, raidKey = raidKey, key = key, itemID = itemID, before = before, after = points, });
                    Plan.Raids[raidKey] = (Plan.Raids[raidKey] or 0) + 1;
                end
            end
        end

        if (#Plan.Errors >= MAX_ERRORS) then
            tinsert(Plan.Errors, ("Stopped after %d errors."):format(MAX_ERRORS));
            break;
        end
    end

    if (Plan.rows == 0 and #Plan.Errors == 0) then
        tinsert(Plan.Errors, "The CSV has a header but no rows.");
    end

    Plan.ok = #Plan.Errors == 0 and #Plan.Changes > 0;
    return Plan;
end

--- Write a checked plan. Returns the import id, or nil when the plan isn't ok.
function PP:applyImport(Plan)
    if (not Plan or not Plan.ok) then
        return nil;
    end

    local Imports = self.db.Imports;
    local id = #Imports + 1;
    Imports[id] = {
        at = time(),
        by = self:me(),
        rows = Plan.rows,
        changes = #Plan.Changes,
        Raids = CopyTable(Plan.Raids),
    };

    for _, Change in ipairs(Plan.Changes) do
        self:setPoints(Change.raidKey, Change.key, Change.itemID, Change.after, "import", self:currentSheetID(Change.raidKey), true, id);
    end

    self:notify();
    return id;
end

function PP:import(id)
    return self.db.Imports[id];
end

--- The ledger entries an import wrote
function PP:importEntries(id)
    local Entries = {};
    for _, Entry in ipairs(self.db.Ledger) do
        if (Entry.batch == id and Entry.reason == "import") then
            tinsert(Entries, Entry);
        end
    end
    return Entries;
end

--- Why an import can't be undone, as lines to show, or nil when it can: already undone, or points changed since the import
function PP:importUndoBlockers(id)
    local Import = self:import(id);
    if (not Import) then
        return { "This import no longer exists.", };
    end

    if (Import.undoneAt) then
        return { ("It was already undone on %s by %s."):format(date("%Y-%m-%d %H:%M", Import.undoneAt), Import.undoneBy or "?"), };
    end

    local Blockers = {};
    for _, Entry in ipairs(self:importEntries(id)) do
        local now = self:getPoints(Entry.raid, Entry.player, Entry.itemID);
        if (now ~= Entry.after) then
            tinsert(Blockers, ("%s, %s: %d now, %d after the import"):format(
                self:displayName(Entry.player), self:itemName(Entry.itemID), now, Entry.after
            ));
        end
    end

    return #Blockers > 0 and Blockers or nil;
end

--- Put every pair an import changed back to its value before the import. Returns the number of pairs, or nil when blocked.
function PP:undoImport(id)
    if (self:importUndoBlockers(id)) then
        return nil;
    end

    local Entries = self:importEntries(id);
    for _, Entry in ipairs(Entries) do
        self:setPoints(Entry.raid, Entry.player, Entry.itemID, Entry.after - Entry.delta, "undo", Entry.sheet, true, id);
    end

    local Import = self:import(id);
    Import.undoneAt, Import.undoneBy = time(), self:me();

    self:notify();
    return #Entries;
end
