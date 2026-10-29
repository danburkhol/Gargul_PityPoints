# Gargul integration reference (for agents)

This is the working reference for adding more Gargul integration to Gargul_PityPoints. Read it **before** touching `Gargul.lua`.
It was verified against **Gargul v8.0.1** source. Line numbers are approximate after Gargul updates, so grep for the quoted names.
For the original question-by-question feasibility write-up, see [Research.md](Research.md).

## Ground rules

- **Never modify, copy or redistribute Gargul code.** Gargul's licence is All Rights Reserved (`Gargul/LICENSE`). We integrate only through runtime hooks on `_G.Gargul`.
- All Gargul hooks live in `Gargul.lua`. The UI and data layer (`Core.lua`, `UI/*`) must not call Gargul directly, except for these read-only helpers already wrapped in `Core.lua`: `PP:currentReserves()`, `PP:isReserved()` and `PP:softresMeta()`.
- Gargul's event bus runs listeners inside `pcall` and **swallows errors**. Always register through `safe(fn)` in `Gargul.lua` so errors still reach BugSack.
- Gargul's source is in the sibling folder `../Gargul/` (installed copy). The WoW Classic UI source used for reference is in `../ExtendedMacroUI/wow-ui-source/` (branch `classic_era`, 1.15.9). The target client is TBC Anniversary (Interface 20506), which uses the same modern UI framework.

## How to reach Gargul

| Thing | Where | Notes |
|---|---|---|
| Global table | `_G.Gargul` (`bootstrap.lua:11`) | Explicitly opened "for other developer integrations". Available by the time our `ADDON_LOADED` fires (`## Dependencies: Gargul`). |
| Event bus | `GL.Events:register(id, "GL.EVENT", fn)` / `:unregister(id)` / `:fire(...)` (`Classes/Events.lua`) | `GL.*` events are fired manually, with no frame involved. The listener signature is `fn(eventName, ...)`. |
| Settings | `GL.Settings:get("Path.key", default)` / `:set(...)` | Keys are in `Data/DefaultSettings.lua`. |
| Saved data | `GL.DB:get("Path.key", default)` → `GargulDB` | |
| Version | `GL.version` (e.g. `"8.0.1"`) | Use for version gates. |
| Chat helper | `GL:sendChatMessage(msg, chatType, nil, nil, false)` (`Utils/Messaging.lua:251`) | `"GROUP"` maps to raid or party. When solo it prints locally, which helps testing. Pass `false` as the 5th argument to drop Gargul's `{rt3} Gargul :` prefix. |
| Names | `GL:disambiguateName(name)`, `GL:stripRealm`, `GL:addRealm` (`Utils/PlayerNames.lua`) | Our DB keys are `strlower(GL:disambiguateName(name))`, which matches Gargul's softres keys. |

## Events (with timing)

| Event | Args | Fired from | When / caveats |
|---|---|---|---|
| `GL.ROLLOFF_STARTED` | none | `RollOff:start` (`Classes/RollOff.lua` ~606) | On every client in the group. Read `GL.RollOff.CurrentRollOff`. |
| `GL.ROLLOFF_ROLL_ACCEPTED` | none | `RollOff:processRoll` (~1198) | The new roll is the **last element** of `CurrentRollOff.Rolls`. Fires **after** the insert and **before** `refreshRollsTable()`. **This is where we add pity points.** |
| `GL.ROLLOFF_STOPPED` | none | `RollOff:stop` (~834) | Rolls are still accepted for `RollTracking.rollOffEndLeeway` seconds (default 1) afterwards, so wait leeway + 0.5s. |
| `GL.ROLLOFF_START_FAILED` | none | watchdog (~232) | |
| `GL.SOFTRES_IMPORTED` | none | `SoftRes:import` finalize (~959), LootReserve import (~1159) | After `materializeData()`. Also fires on re-imports of the same raid and on raiders who receive a broadcast. |
| `GL.SOFTRES_CLEARED` | none | `SoftRes:clear` (~617) | |
| `GL.ITEM_AWARDED` | `AwardEntry` | `AwardedLoot:addWinner` (~727), `receiveAwardedItem` (~1300, awards from **other** officers over comms) | |
| `GL.ITEM_UNAWARDED` | `AwardEntry` **or nothing** | `deleteWinner` (~304), `Exporter` (~155/186 clear all, **no args**) | |
| `GL.ITEM_AWARD_EDITED` | `AwardEntry` | `editWinner` (~423), remote edit (~1336) | `awardedTo` is already **overwritten** with the new winner. Remember the old winner yourself, keyed by `AwardEntry.checksum`. |

`RollOff:startedByMe()` is true on the loot master's client for the current roll. Gate any roll mutation or announcement on it.

## Data shapes

**Roll** (`CurrentRollOff.Rolls[i]`, built in `processRoll`):
`{ player, class, amount, min, max, time, classification, priority }`. We add `ppRaw` and `ppBonus`, and overwrite `amount` with the total.

**CurrentRollOff**: `{ initiator, time, itemID, itemName, itemLink, itemIcon, SupportedRolls, note, Rolls, bth, boostedRollIdentifier }`. It is replaced with a new table on every new roll-off.

**Soft reserves**:
- Raw data: `GargulDB.SoftRes.SoftReserves = { { name, class, note, plusOnes, Items = { itemID, ... } }, ... }`.
- Materialized: `GL.SoftRes.MaterializedData.DetailsByPlayerName[lowername].Items[idString] = count` and `PlayerNamesByItemID[idString] = { lowername, ... }`.
- Helpers: `GL.SoftRes:itemIDIsReservedByPlayer(itemID, name)` (handles linked item IDs), `:playerReservesOnItem`, `:byItemID`, `:getDetailsForPlayer`.
- Meta: `GL.DB:get("SoftRes.MetaData")` → `{ id, importedAt, updatedAt, raidStartsAt, url, playerMap, hidden, ... }`. `id` is the softres.it raid id. CSV and LootReserve imports have **no id**.
- Gargul does **not** keep the raid instance, but it **does keep the raw import** in `MetaData.importString` (see below).

**Full softres.it export (decode `MetaData.importString` ourselves).** This is the same pipeline as `SoftRes:importGargulData`: `GL.Base64.decode(str)` → `LibStub("LibDeflate"):DecompressZlib(...)` → `GL.JSON:decode(...)`. All three are available at runtime. Wrap the whole thing in `pcall`. CSV and LootReserve imports have no import string.
Verified against a real Black Temple sheet (2026-10-29):

| Field | Kept by Gargul? | Notes |
|---|---|---|
| `metadata.id`, `url`, `created_at`, `updated_at`, `discordUrl`, `hidden`, `bonusrolls_consumed_on_use` | yes (camelCase in MetaData) | `updated_at` changes when anyone edits the sheet. |
| `metadata.raidStartsAt` | yes | Often `null`. |
| `metadata.instances` | **no** | List of slugs, e.g. `["blacktemple"]`. **Use this as the raid key.** |
| `metadata.lockedAt` | **no** | Set when the raid leader locks the sheet; `null` while open. |
| `metadata.note` | **no** | The sheet's rules text. |
| `softreserves[].name / class / note` | yes | |
| `softreserves[].items[].id` | yes | |
| `softreserves[].items[].order / note` | **no** | `order` = reserve slot (0, 1). `note` = per-item note. |
| `hardreserves[].id / for / note` | yes | |
| `bonusrolls[]` | consumed into BoostedRolls | softres.it SR+ data. |

Offline check: a Python one-off (base64 → zlib → json) on `WTF/Account/*/SavedVariables/Gargul.lua` prints the same structure.

**AwardEntry** (`AwardedLoot.lua` ~594): `{ checksum, itemLink, itemID, itemGUID, awardedTo (Name-Realm), awardedBy, timestamp, softresID, received, OS, SR, WL, PL, BRCost, winningRollType, Rolls }`. Stored in `GargulDB.AwardHistory[checksum]`. Query with `GL.AwardedLoot:byWinner(name, afterTimestamp)`.

## Roll window (loot master)

- lib-st table: `GL.Interface:get(GL.MasterLooterUI, "Table.Players")`, created in `MasterLooterUI:drawPlayersTable` (~862) with columns from `MasterLooterUI:tableColumns()` (~1002).
- Rows are filled by `RollOff:refreshRollsTable()` (~2014) from `RollOff:buildSortedRollData()` (~1872). **We wrap `buildSortedRollData`** to add `PP raw+bonus` to `Entry.rollNotes`, which Gargul shows in the "Note" column. `Entry.ppRaw` and `Entry.ppBonus` are also set.
- Sort order: hidden col 6 priority ascending (SR = 1 when `RollTracking.sortBySoftRes`; TMB prio/wish; otherwise 10000 + bracket priority), then col 7 (+1s, optional), then col 2 (Roll) descending.
- The Award button (~436–503) reads `cols[1]` (name), `cols[2]` (roll) and `cols[4]` (type) **by position**. New columns must be **appended** (11+), never inserted. The table is `SetWidth(430)` inside a fixed-width frame.
- Gargul never auto-awards a roll-off. The loot master picks the row, so ranking by `Roll.amount` (our total) is what makes the bonus count.
- Side effect: award history, the award overview and softres export record the **total** as `Roll.amount`. The raw value survives in `Roll.ppRaw`.

## Gargul's own chat output

- Roll start: `MasterLooting.announceRollStart`. If `SoftRes.announceInfoWhenRolling` is on, it adds "This item was reserved by: …". No such line means nobody reserved the item.
- "Stop your rolls!": `MasterLooting.announceRollEnd`.
- "%s was awarded to %s. Congrats!": `AwardingLoot.awardMessagesEnabled` (raid warning if `announceAwardMessagesInRW`).
- Gargul never announces a winner at roll end, so our results line doesn't clash.

## Implemented in Gargul_PityPoints (see `Gargul.lua`)

Every hook is installed once at boot and checks `PP:gargulFeature(setting)` each time it runs. It returns true only when the `gargul` master switch and that feature's own setting are on. Toggling in Settings therefore takes effect without a `/reload`. A new hook needs a setting in `PP.DEFAULTS` and in the Gargul integration section of `UI/Settings.lua`. With the master switch off, the manual **Sync SR** button still reads Gargul's softres data.

| Requirement | Setting | Hook |
|---|---|---|
| Read SR / sheets | `autoSync` | `GL.SOFTRES_IMPORTED` → `PP:onSoftResImported()` → `PP:syncFromGargul()`. `PP:readSoftresSheet()` combines Gargul's materialized reserves with the decoded `importString`. |
| Bonus added to roll and ranking | `rollBonus` | `GL.ROLLOFF_ROLL_ACCEPTED` → mutate the last `Roll`, using the points of `PP:activeRaidKey()`. With the master switch on, it also records the roller on the active sheet (attendance evidence), even when `rollBonus` is off. |
| Roll window shows raw + bonus | `rollNote` | wrap `GL.RollOff.buildSortedRollData`. With the master switch off it passes Gargul's entries through untouched. |
| Results announcement | `announce`, `channel` | `GL.ROLLOFF_STOPPED` + leeway delay |
| Win → sheet + reset on win | `trackWins`, `resetOnWin` | `GL.ITEM_AWARDED` → `PP:recordWin()` |
| Attendance | `recordAttendance` (not a Gargul hook) | `ENCOUNTER_END` + a 30s ticker in `Sheets.lua` |
| `!pp` / `!pitypoints` whisper | `whisperReply` | Our own `CHAT_MSG_WHISPER` frame. It replies only when `GL.SoftRes:userIsAllowedToBroadcast()` is true (not in a group, or master looter / assist), the same rule Gargul uses for `!sr`. Throttled per sender. |
| `!sr` follow-up | `srFollowUp` | `hooksecurefunc(GL.SoftRes, "handleWhisperCommand", …)`. Gargul's `CHAT_MSG_WHISPER` listener (`SoftRes.lua` ~74) only calls it after its checks (`available()`, `userIsAllowedToBroadcast()`, `SoftRes.enableWhisperCommand`), so the hook inherits them. The prefixes come from `Gargul_L["!sr|!softres|!softreserve"]`. Gargul replies after `onItemLoadDo`, so ours waits 1.5s. |

## Not implemented yet: recipes

1. **Undo / move a reset on unaward or edit.** The v0.2 ledger already logs win resets (`reason = "win"`). Add the award checksum to that ledger entry (store `AwardEntry.checksum` from `onItemAwarded`), and also remove the win from `Sheet.Wins` on undo. In `onItemAwarded`, record `DB.ResetLog[AwardEntry.checksum] = { name, itemID, points }`.
   - On `GL.ITEM_UNAWARDED(AwardEntry)`: restore from the log, then clear `WonThisCycle`.
   - On `GL.ITEM_AWARD_EDITED(AwardEntry)`: restore the old winner from the log, then apply the reset to the new `awardedTo`.
   - Ignore `ITEM_UNAWARDED` with no argument (the Exporter's "clear all").
2. **Real Raw / Bonus / Total columns.** Wrap `GL.MasterLooterUI.tableColumns` (before the window is first drawn) to append column definitions. Then `hooksecurefunc(GL.RollOff, "refreshRollsTable", …)`: walk `RollsTable.data`, append cells, then call `RollsTable:Refresh()`. Widen the table and window, and test with gear icon columns 8–10 present.
3. **Per-instance points and teams: done in v0.2.0** (`Raids[team:instances]`, see `docs/Design-RaidsAndWeeks.md`).
4. **Attendance: done in v0.2.0** (`Sheets.lua`). Gargul doesn't record who was in the raid. `DroppedLootLedger.KilledBosses` is in memory only and has no roster. Award history only shows winners and rollers. Attendance must be recorded by us, e.g. a raid-roster snapshot on `ENCOUNTER_END` (success) and on a timer while inside the instance.
5. **Announcing points at roll start.** `GL.ROLLOFF_STARTED` on the loot master: list reservers and their points. Gargul's own "reserved by" line is from `RollOff:postStartMessage` and can't be extended, so post a separate line.

## Testing checklist (in game)

1. `/reload`. Chat should show "Hooked into Gargul x.y.z". If not, check BugSack.
2. Solo: `/gl roll [item]` → Start → `/pp test` (fake rolls, fake reserve for Alice).
3. Real flow: import a softres.it raid in Gargul, `/pp` to open the manager, Sync, set points on an item you reserved, roll on it, check the Note column (`PP x+y`), the Roll column total, the announcement, and the reset after awarding.
4. A player with points but **no reserve** gets no bonus by design (requirement 8). The add-on warns in chat.
