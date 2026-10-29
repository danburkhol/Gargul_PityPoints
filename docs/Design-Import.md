# Design: importing pity points

Status: agreed with the user on 2026-10-29. **Implemented in `Import.lua` and `UI/Import.lua`; not yet tested in game.**

## Decisions (from the user)

| Topic | Decision |
|---|---|
| Purpose | A one-time import of the balances the guild already tracks in a spreadsheet. Moving points between clients or doing bulk fixes works the same way. |
| Format | **The same CSV as the points export.** Existing data is converted to it outside the game; the add-on doesn't read other shapes. |
| Mode | **Set only.** Each row sets that player's points on that item. Pairs not in the file are left alone. |
| Unknown campaign | **Reject.** A row whose team and raid don't match an existing campaign is an error. Create the campaign first (sidebar). |
| Undo | **Yes.** An import can be undone as a whole from the points log. |
| Who | Anyone. Points only exist on the client that imports them. |

## Format

The header row of the points export (`PP:buildCSV`):

```
team,raid,player,item_id,item_name,points,reserved
Team Gard,blacktemple,Casto,32239,Slippers of the Seacaller,80,yes
```

| Column | Import |
|---|---|
| `team` | Required. Campaign team, any case. |
| `raid` | Required. Instance slugs joined with `+`, as exported. Matched with `PP:findCampaign`, so slug aliases (`hyjal` / `hyjalsummit`) work. |
| `player` | Required. Normalised with `PP:key`, so `Name-Realm` on our realm is the same as `Name`. |
| `item_id` | Required. A whole number. |
| `points` | Required. A whole number, 0 or more. 0 clears the pair. |
| `item_name`, `reserved` | Read-only context from the export; ignored. |

- Columns are found by header name, in any order; unknown columns are ignored. A UTF-8 BOM, `\r\n` line ends, quoted fields (`"Zhar'doom, Greatstaff of the Devourer"`) and blank lines are handled.
- **All or nothing.** Any error (missing column, bad number, unknown campaign, the same campaign + player + item twice) blocks the import. The preview lists every error with its line number.

## Flow

1. Manager → **Import CSV** (top bar, next to Sync SR).
2. Paste the CSV and click **Preview**. Nothing is written. The preview shows, per campaign, the rows that will change (`old → new`), plus counts of unchanged rows and the errors.
3. **Import** is enabled only when the preview has no errors and at least one change, and the text hasn't been edited since. Every change goes through `PP:setPoints` with reason `import`, then one `notify()`.
4. **Undo** from the points log: click an "Imported" entry. It sets every pair the import changed back to its old value, logged with reason `undo`. It's refused when any of those pairs changed after the import (the dialog names them), or when the import was already undone.

## Data model

- `Imports[id] = { at, by, rows, changes, Raids = { [raidKey] = changes }, undoneAt, undoneBy }`. `id` is the array index.
- `Ledger[]` entries gain an optional `batch = id` on `import` and `undo` entries.
- `LEDGER_REASONS` gains `import = "Imported"` and `undo = "Import undone"`.
- No schema bump: both are additive.
