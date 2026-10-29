# Gargul Pity Points

Soft-reserve **pity points** for **Gargul**. Every raid week a player reserves an item and doesn't win it, they gain points on that item. The next time it drops, those points are added to their roll.

This add-on works alongside Gargul and **requires it**. It doesn't change Gargul's files.

## Features

- **Campaigns.** Each team and raid gets its own rules, e.g. *Gard · Black Temple: 2 SRs, +10 per week, no cap* and *Gard · Sunwell Plateau: 3 SRs, +5 per week, cap 40*.
  - Set per campaign: SRs per week, points per week, points cap, reset on win, and reset items not reserved again.
  - Points are tracked per player and per item within each campaign.
- **softres.it sync.**
  - Importing a sheet in Gargul syncs it automatically.
  - A new sheet asks which campaign it's for (the matching one is preselected), or lets you create one, and starts a new week there.
  - Items that weren't reserved again lose their points, if the campaign says so.
- **Attendance tracking.**
  - The raid roster is noted on every boss kill and on a timer.
  - Tick *Bench* for players who were ready to go.
- **Close week.**
  - Adds the campaign's points per week (up to its cap) to each reserved item of everyone who attended or was benched, except items they won.
  - A preview shows exactly what each player gains, and you can reopen a week to undo it.
- **Bonus on rolls.** Gargul ranks rolls by the total of roll plus points, and its roll window shows *PP roll+points*.
- **Results.** When you award the item, the winner is announced in chat: *"[Player] wins [Item] with a roll of X and points of Y for a total of Z."*, followed by the other rolls.
- **Missing rolls.** The roll window lists soft reservers in the raid who haven't rolled yet, and a raid warning names them when the roll-off ends.
- **Auto-award soft reserves** (optional). As master looter, an item only one raider reserved is awarded to them as soon as you open the loot window. Extra copies are left for a roll.
- **Reset on win.** Winning an item resets the winner's points on it, in campaigns that have it on.
- **Shared points** (optional). For players who float between teams: rolls add their points from every campaign, and resets apply in every campaign.
- **Manager window** (`/pp`):
  - campaigns and sheets sidebar, with New campaign and Edit campaign;
  - search, sort, and +/− / reset of points;
  - CSV export.
- **Points log.** Every change is recorded with when, who, why and which softres sheet. It can be exported to CSV.
- **Whispers:**
  - Players can whisper `!pp` to see their points.
  - Gargul's `!sr` reply gets a follow-up whisper with their points on each reserved item.
- **Launcher.** An optional minimap button, plus a LibDataBroker launcher for Titan Panel and other broker displays.
- **Settings** in Esc > Options > AddOns, covering:
  - attendance recording;
  - the Gargul hooks, announcement channel and whisper replies.

## Commands

- `/pp`: open the manager
- `/pp config`: settings
- `/pp log`: points log
- `/pp sync`: sync the softres sheet imported in Gargul
- `/pp whisper <name>`: preview a player's `!pp` reply
