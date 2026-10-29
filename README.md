# Gargul Pity Points

Soft-reserve **pity points** for the [Gargul](https://www.curseforge.com/wow/addons/gargul) loot add-on. Every raid week a player reserves an item and doesn't win it, they gain points on that item. Those points are added to their roll the next time it drops. Gargul itself is not modified: this is a separate add-on that hooks into it at runtime.

Built for WoW Classic, TBC Anniversary. Requires Gargul.

## How it works

- **Campaigns.** A campaign is a team and raid with its own rules, e.g. *Gard · Black Temple: 2 SRs, +10 per week, no cap* next to *Gard · Sunwell Plateau: 3 SRs, +5 per week, cap 40*. Points are tracked per player and per item within each campaign.
  - Rules per campaign: SRs per week, points per week, points cap, reset on win, and reset items not reserved again.
  - Rule changes apply from the next sync and Close week. Points already given are never recalculated.
- **Softres sheets.** When a softres.it sheet is imported in Gargul, it's synced automatically. A new softres ID asks which campaign it belongs to (the matching one is preselected) or lets you create one, and starts a new week there. Items a player didn't reserve again lose their points, if the campaign says so.
- **Attendance.** While you're in the raid, the add-on notes who is there on every boss kill and on a timer. Tick **Bench** for players who were ready to go.
- **Close week.** After the raid week, Close week adds the campaign's points per week (up to its cap) to each reserved item of every player who attended or was benched, except items they won. Reopen the week to undo it.
- **Rolls.** When a reserved item is rolled for in Gargul, the player's points are added to their roll. Gargul ranks rolls by the total.
- **Results.** The winner is announced in raid chat: *"[Player] wins with a roll of X and points of Y for a total of Z."*, followed by the other rolls.
- **Reset on win.** Winning an item resets that player's points on it to zero, in campaigns that have it on.

## Using it

- `/pp` opens the manager.
  - **Sidebar:** your campaigns, each with its softres sheets underneath, and **New campaign**. Right-click an entry to edit the campaign, collapse it, open its log, close or reopen the week, or delete it.
  - **Campaign view:** search, sort, +/− and reset points, export to CSV, and **Edit campaign** for its rules.
  - **Sheet view:** attendance and bench checklist, with a preview of the points each player will gain, and **Close week**.
- **Points log:** every change is recorded with when, who, why and which softres sheet. It can be exported to CSV.
- **Whispers:**
  - Players can whisper you `!pp` (or `!pitypoints`) to get their points in every raid.
  - After Gargul answers a `!sr` whisper, the add-on sends a second whisper with the player's points on each reserved item.
  - Like Gargul, only the loot master and assists reply while in a group.
- **Launcher:** a minimap button (optional), and a LibDataBroker launcher for Titan Panel and other broker displays.
- **Settings:** Esc > Options > AddOns > Gargul Pity Points.
  - Attendance recording. (Point rules live on each campaign, in the manager.)
  - **Gargul integration:** a master switch, plus one switch for each hook:
    - auto sync;
    - points on rolls;
    - the roll-window note;
    - win tracking;
    - the announcement and its channel;
    - `!pp` and `!sr` whispers.

    Changes apply without a `/reload`.

### Slash commands

| Command | What it does |
|---|---|
| `/pp` | Open or close the manager |
| `/pp config` | Open the settings |
| `/pp log` | Open the points log |
| `/pp sync` | Sync the softres sheet imported in Gargul |
| `/pp whisper <name>` | Preview the `!pp` reply for a player without sending it |

## Development

- `AGENTS.md` has the layout, data model and conventions.
- `docs/GargulIntegration.md` covers the Gargul hooks.
- Lint with `luacheck .` (see `.luacheckrc`). The same check runs on every push.
- Releases are cut by pushing a `v*` tag. The BigWigs packager then uploads the build to CurseForge (`.github/workflows/release.yml`).
