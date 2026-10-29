# Gargul integration research (Part 2)

Reviewed: **Gargul v8.0.1** source in `Interface/AddOns/Gargul` (TBC Anniversary install).
Every finding below comes from reading the code. The proof of concept in `Core.lua` exercises the main hooks, but **it has not been run in game yet.**

## Summary

**Full integration is possible without changing Gargul.** Gargul publishes itself as `_G.Gargul` and has an internal event bus. A separate add-on can listen for the roll-off start, each accepted roll, the roll-off end, a soft-reserve import and an award. The most important result: when it accepts a roll, Gargul fires an event *before* it sorts and redraws the roll window. If we change `Roll.amount` in that event, Gargul ranks and awards by the adjusted total. The bonus is therefore not just for show.

Everything here uses Gargul's internals. None of it is a versioned public API, so a Gargul update can break it.

---

### 1. Public API: is there a global table or official API?
- **Possible:** Yes, informally. **Confidence:** High.
- `bootstrap.lua:11`: `_G.Gargul = GL; -- Open Gargul up to other developer integrations`. Every module hangs off this table: `GL.RollOff`, `GL.SoftRes`, `GL.AwardedLoot`, `GL.MasterLooterUI`, `GL.Events`, `GL.Settings`, `GL.DB`.
- No documented API, version number or compatibility promise. The one existing outward integration is a push to CLM (`AwardedLoot.lua`, `CLM_EXTERNAL_EVENT_ITEM_AWARDED`).
- **Risk:** Medium. Function and field names are internal and can change in any release. Check `GL.version` and degrade gracefully when something is missing.

### 2. Extension mechanism
- **Possible:** No formal mechanism exists. In practice you don't need one. **Confidence:** High.
- The "built-in extensions" (SoftRes, TMB, BoostedRolls, PlusOnes, AutoRoll, GDKP) are ordinary classes listed in Gargul's own `.toc`. Each one attaches to `GL` and calls `GL.Events:register(...)`. There is no plugin registry or loader.
- An external add-on can do exactly what they do: `## Dependencies: Gargul`, then `_G.Gargul.Events:register(id, "GL.SOME_EVENT", fn)`.
- **Gotcha:** `Events:listen` runs every listener inside `pcall` and **silently discards errors**. The PoC wraps its callbacks so errors still show up in BugSack.

### 3. Roll events
- **Possible:** Yes. **Confidence:** High.
- `GL.ROLLOFF_STARTED` has no arguments. Read `GL.RollOff.CurrentRollOff` (`itemID`, `itemLink`, `time`, `initiator`, `Rolls`).
- `GL.ROLLOFF_ROLL_ACCEPTED` has no arguments. The new roll is the last entry in `GL.RollOff.CurrentRollOff.Rolls`, with the shape `{player, class, amount, min, max, time, classification, priority}`. It fires inside `RollOff:processRoll` **after** the insert and **before** `refreshRollsTable()`.
- `GL.ROLLOFF_STOPPED` has no arguments. Gargul keeps accepting rolls for `RollTracking.rollOffEndLeeway` seconds afterwards (default 1), so wait before you finalise.
- `GL.ROLLOFF_START_FAILED` also exists.
- `RollOff:startedByMe()` tells you whether this client is the loot master for the roll.
- Gargul throws away a roll before the event fires if its range doesn't match a configured bracket (unless `trackAll` is on) or if the roller isn't in the group.

### 4. Roll window UI: extra columns
- **Possible:** Yes, by hooking. There's no supported way. **Confidence:** High for the Note-column approach. Medium for adding real columns.
- The table is a lib-st `ScrollingTable` built by `MasterLooterUI:tableColumns()` (10 columns, some hidden for sorting) and filled by `RollOff:refreshRollsTable()` from `RollOff:buildSortedRollData()`.
- **PoC approach:** wrap `GL.RollOff.buildSortedRollData` and add `PP raw+bonus` to each entry's `rollNotes`. Gargul shows that in its "Note" column, while the "Roll" column already shows the total.
- **Real columns:** wrap `MasterLooterUI.tableColumns` before the window is first drawn to append columns 11+, then post-hook `refreshRollsTable` to fill those cells. The table width is fixed at `SetWidth(430)` inside a fixed-size frame, so the layout needs adjusting.
- **Never insert columns in the middle.** The Award button reads `cols[1]`, `cols[2]` and `cols[4]` by position.

### 5. Winner logic (critical)
- **Possible:** Yes. The total can decide the winner. **Confidence:** High.
- Gargul **never picks a roll-off winner automatically.** The loot master selects a row and clicks Award (`MasterLooterUI.lua` ~L440), which calls `RollOff:award(selectedPlayer, …)`.
- Sort order is a hidden priority column (col 6: SR = 1 when `sortBySoftRes` is on, TMB prio/wish, otherwise 10000 plus the bracket priority), then optionally +1s, then `Roll.amount` descending (lib-st sort settings, mirrored by the `table.sort` in `buildSortedRollData`).
- **How:** in `GL.ROLLOFF_ROLL_ACCEPTED`, set `Roll.amount = raw + bonus` and keep `Roll.ppRaw` / `Roll.ppBonus`. Sorting, the top row, tie detection (`identicalRollDetected` compares `Roll.amount`) and the raider-side roll tracker (`RollerUI`) all use the total.
- **Risk:** Award history (`AwardEntry.Rolls`), the award overview and softres exports will record the **total** as the roll amount. The extra `ppRaw` / `ppBonus` fields are cloned into history too, so the raw roll can still be recovered.

### 6. Soft reserve data
- **Possible:** Yes. **Confidence:** High.
- Raw data is in `GargulDB.SoftRes.SoftReserves`, an array of `{ name, class, note, plusOnes, Items = { itemID, … } }`. `GargulDB.SoftRes.MetaData` holds `{ id, importedAt, updatedAt, raidStartsAt, url, playerMap, … }`.
- Indexed data is in `GL.SoftRes.MaterializedData`: `DetailsByPlayerName[lowername].Items[idString] = count` and `PlayerNamesByItemID[idString] = { lowername, … }`.
- Helpers: `SoftRes:itemIDIsReservedByPlayer(itemID, name)` (also handles linked item IDs), `playerReservesOnItem`, `byItemID`, `getDetailsForPlayer`.
- Names are lowercase and realm-less where the realm is unambiguous. Gargul's auto name-fix map is in `MetaData.playerMap`.
- **Gap:** Gargul does **not** store the raid instance from a softres.it import. Per-instance tracking needs `GetInstanceInfo()`, a user setting or a mapping from item ID to instance.

### 7. Soft reserve import event
- **Possible:** Yes. **Confidence:** High.
- `GL.SOFTRES_IMPORTED` (no arguments) fires after the data is materialised. `GL.SOFTRES_CLEARED` also exists.
- It fires again when the same raid is re-imported, and on raiders' clients when the loot master broadcasts. The PoC treats a **new softres.it `MetaData.id`** as "new week". CSV and LootReserve imports have no ID, so they need a manual trigger.

### 8. Award history
- **Possible:** Yes. **Confidence:** High.
- `GL.ITEM_AWARDED(AwardEntry)` fires for local awards and for awards received from another officer over addon comms. Also available: `GL.ITEM_UNAWARDED(AwardEntry)` and `GL.ITEM_AWARD_EDITED`.
- `AwardEntry` has `{ checksum, awardedTo (Name-Realm), itemID, itemLink, timestamp, OS, SR, BRCost, softresID, Rolls, … }`.
- History is stored in `GL.DB.AwardHistory[checksum]`. `GL.AwardedLoot:byWinner(name, afterTimestamp)` queries it.
- **To do:** handle `ITEM_UNAWARDED` and `ITEM_AWARD_EDITED` to undo or move a win-reset. The PoC doesn't do this yet.

### 9. Announcements
- **Possible:** No conflict. Gargul's messages can be switched off. **Confidence:** High.
- Gargul **does not** announce a winner when a roll-off ends. It posts "Stop your rolls!" (`MasterLooting.announceRollEnd`). When the item is awarded, it posts "%s was awarded to %s. Congrats!" (`AwardingLoot.awardMessagesEnabled`, in raid warning if `announceAwardMessagesInRW` is on).
- Our "X wins with a roll of …" message fits in between. To replace Gargul's award message: `GL.Settings:set("AwardingLoot.awardMessagesEnabled", false)`.
- `GL:sendChatMessage(msg, channel, nil, nil, false)` is reusable. It prints locally when you're solo, which helps testing.

### 10. Game version support
- **Possible:** The same integration works across versions. **Confidence:** High.
- One codebase ships seven TOCs: Vanilla/Era/SoD `11509`, TBC/Anniversary `20506` (also the default `Gargul.toc`), Wrath `30405`, Cata `40402`, Mists `50504/50505` and "Camelot"/Forever `16001`.
- Version differences are runtime flags (`GL.isEra`, `GL.isClassic`, `GL.isSoD`, `GL.isForever`). The RollOff, SoftRes and AwardedLoot paths aren't version-specific.
- Roll parsing uses the localised `RANDOM_ROLL_RESULT`, so it works in any client language.

### 11. Fallback approach
- **Possible:** Yes, but not needed. **Confidence:** High.
- `CHAT_MSG_SYSTEM` plus a pattern built from `RANDOM_ROLL_RESULT` is exactly how Gargul does it (`RollOff:listenForRolls` / `processRoll`). A companion window could work standalone, but it couldn't change Gargul's ranking, and the loot master would have two windows. Keep it only as a backup if the hooks break.

### 12. Is the author open to official hooks?
- **Unknown from the code.** The `_G.Gargul` comment ("Open Gargul up to other developer integrations") and the CLM push point to goodwill. Ask on the Gargul Discord (linked in the `.toc`).
- Useful things to request: arguments on `ROLLOFF_ROLL_ACCEPTED` (pass the `Roll`), a "roll modifier" callback, and an API for extra roll-window columns.

### 13. Licence
- **Restrictive.** `LICENSE` and `## X-License: ARR` say All Rights Reserved: "No part … may be modified, redistributed, sublicensed, or used to create derivative works without explicit written permission."
- Our add-on doesn't copy, modify or redistribute Gargul code. It calls Gargul at runtime, which is common practice for WoW add-ons. Whether runtime hooking counts as a "derivative work" is a legal question, not a technical one. **Get the author's written OK before publishing.** (This is not legal advice.)

---

## Related built-in feature worth knowing about
Gargul already turns **softres.it bonus rolls** into Boosted Roll points (`BoostedRolls:importFromSoftres`, `consumeSoftresBonus`). That feature changes the **roll range** players type (e.g. `/roll 21-120`). It doesn't add points to a normal roll. softres.it's own SR+ might cover part of the pity-points idea without a custom add-on.

## Proof of concept: how to try it
1. `/reload`. You should see "PityPoints: Hooked into Gargul 8.0.1".
2. `/gl roll [item link]`, then click **Start** (this works solo).
3. `/pp test` adds fake rolls: Alice 50 + 20 pity = **70** (reserved), Bob **65** (not reserved), plus you.
   - Expected: Alice sorts above Bob, and her Note shows `PP 50+20`.
4. When the timer ends, the announcement prints, e.g. "Alice wins with a roll of 50 and points of 20 for a total of 70."
5. Award Alice. The chat says her pity points were reset.

To test with real rolls without importing a softres raid, fake a reserve first. Bonus points only apply to reserved items:
`/pp reserve Name [item]`, then `/pp set Name [item] 20`. A player who has points but no reserve gets a chat warning when they roll.

Other commands: `/pp` (manager window), `/pp config`, `/pp sync [week]` (re-read Gargul's softres; add `week` to process it as a new week), `/pp show`, `/pp set <name> <item> <points>`.
