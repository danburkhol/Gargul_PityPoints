# Design: raids, softres sheets, attendance and Close week

Status: agreed with the user on 2026-10-29. **Implemented in v0.2.0 (`Core.lua`, `Sheets.lua`, `Gargul.lua`, `UI/Manager.lua`, `UI/Log.lua`); not yet tested in game.** It replaces the flat `Points[player][item]` model and the "accrue on next sheet import" rule.

## Decisions (from the user)

| Topic | Decision |
|---|---|
| Raid key | **Team + raid.** The raid comes from the softres sheet (`metadata.instances`). The team is picked the first time a new sheet is synced and remembered per softres ID. |
| Attendance | **Auto-record + bench list.** Snapshot the raid roster on boss kills and on a timer inside the instance. Close week pre-ticks attendees and rollers; bench players are ticked by hand. |
| Accrual | **Close week button.** Points are added at the end of the raid week, to attendees and bench only. Importing the next week's sheet only resets items that weren't reserved again. |
| List sort | Player name **A → Z** by default (done). SR column removed (done). |

## Workflow

1. **Import the sheet in Gargul** (`/gl sr`), as today.
2. **Sync.** We decode `MetaData.importString` to get the softres ID, instances, `updated_at`, `lockedAt` and item order.
   - **New softres ID:** ask which team, and create a sheet record under `team + raid`. For each player/item with points in that team+raid that **isn't reserved again** on the new sheet, reset to 0 and log it (rule 6).
   - **Known softres ID:** update the sheet's reserves and log the diff (players or items added/removed). Points don't change.
3. **During the raid:** while in a raid group inside an instance, record roster snapshots against the active sheet:
   - on `ENCOUNTER_END` with success (boss name plus roster);
   - every 5 minutes as a fallback;
   - only when an officer with the add-on is present.

   Which sheet is active: the most recently synced open sheet whose raid matches `GetInstanceInfo()`, else the most recently synced open sheet.
4. **Close week** (per sheet, from the sidebar). A checklist of every player who reserved on the sheet:
   - **pre-ticked "Attended"** if seen in any roster snapshot, or if they rolled on or won an item on this sheet's raid (from Gargul events);
   - a **"Bench"** tick box, manual.

   On confirm, every reserved item of an attended or benched player who didn't win that item this sheet gets `+pointsPerWeek` (respecting the cap), and each change is logged. The sheet is then marked closed. Closing again is blocked unless the user reopens the sheet, which reverts the logged "week" entries.
5. **Reset on win** stays as it is (immediate, logged). It records the win against the active sheet.

## Data model (`GargulPityPointsDB`, schema v2)

```lua
Raids[raidKey] = {            -- raidKey = team .. ":" .. instancesSlug, e.g. "gard:blacktemple"
    team = "Gard", instances = { "blacktemple" }, label = "Gard · Black Temple",
    Points = { [player] = { [itemID] = n } },
}
Sheets[softresID] = {
    raidKey, url, note, createdAt, updatedAt, lockedAt, firstSyncedAt, lastSyncedAt,
    Reserves = { [player] = { [itemID] = order } },      -- latest version
    Syncs = { { at, updatedAt, Added = {...}, Removed = {...} } },
    Snapshots = { { at, boss?, Roster = { [player] = true } } },
    Rolled = { [player] = true },   Wins = { [player] = { [itemID] = true } },
    Bench = { [player] = true },    closedAt, closedBy,
}
Ledger = { { at, raidKey, softresID, player, itemID, delta, after, reason = "week"|"win"|"manual"|"reset"|"migrate", by } }
Teams = { "Gard", "Gaarak" }
```

Migration from v1: move `Points` into `Raids["default:unknown"]` with a "migrate" ledger entry, and let the user re-assign them from the UI.

## UI changes

- **Manager:** left sidebar lists raids (team · raid). Under each raid are its sheets (date, softres ID, open/closed). The list on the right shows the selected raid's points.
- **Sheet view:** reserves, the sync history, attendance snapshots, and a **Close week** button.
- **Log tab or window:** the filtered ledger, which is also exportable as CSV.
- **Export:** add `raid` and `team` columns.

## Defaults chosen for the open questions (the user can change these)

- Close week on a sheet that isn't `lockedAt` **warns** in the confirmation dialog; it doesn't block.
- **Rollers and winners count as attended** (`PP:autoAttended`). A manual untick is stored in `Sheet.Override`.
- The team is **free-typed** at first sync, pre-filled with `lastTeam`. Known teams are listed in the dialog and remembered in `DB.Teams`.

## Known limits

- Mid-week re-syncs never change points. A reserve dropped mid-week only resets when the next sheet arrives, and only if it isn't reserved again then.
- The active sheet is the open sheet whose instances match `GetInstanceInfo()`, else the most recently synced open sheet. Two open sheets for the same instance (two teams in BT the same week) resolve to the most recently synced one. Sync the right sheet before the raid.
- Attendance is only recorded by clients running the add-on. The person who closes the week needs the data, because SavedVariables aren't shared.
