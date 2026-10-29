# Gargul_PityPoints: agent notes

A WoW Classic add-on that tracks soft-reserve "pity points" per team and raid, and adds them to rolls in the **Gargul** loot add-on, without modifying Gargul.

- **Target client:** TBC Anniversary (`_anniversary_`, Interface 20506). The TOC also lists the other Classic interface numbers that Gargul supports.
- **Requirements:** Part 1 of the original spec, summarised in `docs/Research.md`.
- **Design (implemented in v0.2.0):** `docs/Design-RaidsAndWeeks.md` covers raids, softres sheets, attendance, Close week and the points log.
- **Gargul integration:** read `docs/GargulIntegration.md` first. It lists events, data shapes, line refs, gotchas, the softres.it export fields and recipes for what's left.
- **Blizzard UI reference:** `../ExtendedMacroUI/wow-ui-source/Interface/AddOns` (classic_era 1.15.9). Grep it before using any template or API, e.g. `Blizzard_Settings_Shared/Blizzard_ImplementationReadme.lua` for the Settings API.

## Layout

| File | Role |
|---|---|
| `Gargul_PityPoints.toc` | Load order. Libs first, then `Core.lua`, `Sheets.lua`, `Gargul.lua`, `UI/*`. |
| `Libs/` | Embedded LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0 (copied unmodified from BigWigs' bundle). |
| `Core.lua` | Namespace `PP` (addon vararg, also `_G.GargulPityPoints`), SavedVariables + schema migration, raids, the points + ledger API, rows/CSV, slash commands, boot. |
| `Sheets.lua` | Softres sheets: sync (new vs known softres id), the active sheet, attendance snapshots (`ENCOUNTER_END` + timer), wins/rolls, Close week / reopen, team and adopt dialogs. |
| `Gargul.lua` | **The only file that touches Gargul.** `readSoftresSheet` (decodes `MetaData.importString`), `isReserved`, roll bonus, roll-window note, results announcement, award → win, the `!pp` whisper reply, and the `!sr` follow-up (post-hook on `GL.SoftRes.handleWhisperCommand`). |
| `UI/Settings.lua` | Blizzard Settings panel (Esc > Options > AddOns > Gargul Pity Points). |
| `UI/Manager.lua` | Main window: raids/sheets sidebar; points view (search, sort, +/−/reset, export); sheet view (attended/bench checklist, Close week). |
| `UI/Log.lua` | Points log window (ledger), filter by raid or search, CSV export. |
| `UI/Export.lua` | Generic CSV window: `PP:showExport(csv, count, what)`. |
| `UI/Broker.lua` | LibDataBroker data source (Titan Panel etc.) and the LibDBIcon minimap button. |

## Data model (`GargulPityPointsDB`, schema 2)

- `Raids[raidKey] = { team, Instances, label, Points[playerKey][itemID], currentSheet }`. `raidKey = strlower(team) .. ":" .. table.concat(instances, "+")`. `Raids.unassigned` holds pre-v2 points until a new sheet adopts them.
- `Sheets[softresID] = { raidKey, Instances, url, note, createdAt, updatedAt, lockedAt, firstSyncedAt, lastSyncedAt, Reserves[playerKey][itemID] = order, Classes, Syncs[], Seen[playerKey] = { first, last, snapshots, bosses }, Bosses[], Rolled, Wins, Bench, Override, closedAt, closedBy, closeSummary }`.
- `Ledger[] = { at, raid, sheet, player, itemID, delta, after, reason, by }`. Reasons are in `PP.LEDGER_REASONS`.
- `Teams[]`, `lastTeam`, `ItemNames[itemID]` (name cache), `Classes[playerKey]` (class cache from every synced sheet; use `PP:playerClass`), `UI.Collapsed[raidKey]` (sidebar state), `Settings` (see `PP.DEFAULTS`).
- Sheet dates: `createdAt`, `raidStartsAt` and `lockedAt` come from softres.it; `firstSyncedAt` is ours. `PP:sheetDate(id)` picks one per `Settings.sheetDate`.
- `playerKey = strlower(GL:disambiguateName(name))`, which matches Gargul's softres keys.

**Rules:**
- Points change **only** through `PP:setPoints`, which writes the ledger and fires `PP.callbacks:Fire("POINTS_CHANGED")`.
- Sheet mutations also call `PP:notify()`. The UI refreshes on that callback.

## Conventions

- Lua 5.1 (WoW). Semicolons at statement ends, `local` everything, methods as `function PP:name()`. Comments only where intent isn't obvious.
- Never shadow Lua globals such as `select`, `type` or `next` with locals.
- No Ace3. Use Blizzard templates and the Settings API, plus the four embedded libs.
- Only use icons that exist in the TBC client. A missing texture renders as nothing, with no error. `../ExtendedMacroUI/IconNames.lua` maps icon names to file IDs: IDs in the 13xxxx range date from the original game, while the 2xxxxx range was added later. For example, `INV_Misc_Dice_02` (237285) left the portrait blank.
- Fill lists through `setRows` in `UI/Manager.lua`, not `SetDataProvider` directly. A new data provider hides and re-shows every row, which drops clicks in progress, and refreshes come several times a second.
- There is no Lua interpreter here, so code can't be run. Lint with `"C:/Users/agent/tools/luacheck/luacheck.exe" .`, which must report 0 warnings; add new WoW globals we read to `read_globals` in `.luacheckrc`. Then ask the user to test in game, and say plainly that in-game behaviour is untested.

## Repository and publishing

- GitHub: `danburkhol/Gargul_PityPoints`, branch `main`. This folder is both the repo and the live in-game add-on.
- CI: `.github/workflows/lint.yml` runs luacheck on pushes and PRs.
- Releases:
  - `.github/workflows/release.yml` runs the BigWigs packager when a `v*` tag is pushed and uploads the build to CurseForge.
  - It needs the repo secrets `CF_API_KEY` and `X_CURSE_PROJECT_ID`.
  - Use the `/release` skill (`.claude/skills/release/SKILL.md`).
- `.pkgmeta`:
  - Leaves the dev files (`AGENTS.md`, `CLAUDE.md`, `docs/`, `.claude/`, `.github/`) out of the zip.
  - Marks Gargul as a required dependency on CurseForge.
- Version: only `## Version:` in the TOC, kept as a literal. The git tag is `v` plus that version.
- The store copy is `docs/curseforge-description.md` and `docs/curseforge-summary.txt`. The CurseForge description editor takes Markdown, not BBCode or HTML.
