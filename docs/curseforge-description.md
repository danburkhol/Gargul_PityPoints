# Gargul Pity Points

Soft-reserve **pity points** for **Gargul**. Every raid week a player reserves an item and doesn't win it, they gain points on that item. The next time it drops, those points are added to their roll.

This add-on works alongside Gargul and **requires it**. It doesn't change Gargul's files.

## Features

- **Points per team and raid.** Points are tracked per player and per item, separately for each team and raid, e.g. *Team Gard · Black Temple*.
- **softres.it sync.**
  - Importing a sheet in Gargul syncs it automatically.
  - A new sheet starts a new week for that team and raid.
  - Items that weren't reserved again lose their points.
- **Attendance tracking.**
  - The raid roster is noted on every boss kill and on a timer.
  - Tick *Bench* for players who were ready to go.
- **Close week.**
  - Adds points (10 by default) to each reserved item of everyone who attended or was benched, except items they won.
  - A preview shows exactly what each player gains, and you can reopen a week to undo it.
- **Bonus on rolls.** Gargul ranks rolls by the total of roll plus points.
- **Results.** The winner is announced in chat: *"[Player] wins with a roll of X and points of Y for a total of Z."*, followed by the other rolls.
- **Reset on win.** Winning an item resets the winner's points on it.
- **Manager window** (`/pp`):
  - raids and sheets sidebar;
  - search, sort, and +/− / reset of points;
  - CSV export.
- **Points log.** Every change is recorded with when, who, why and which softres sheet. It can be exported to CSV.
- **Whispers:**
  - Players can whisper `!pp` to see their points.
  - Gargul's `!sr` reply gets a follow-up whisper with their points on each reserved item.
- **Launcher.** An optional minimap button, plus a LibDataBroker launcher for Titan Panel and other broker displays.
- **Settings** in Esc > Options > AddOns, covering:
  - points per week, cap and reserves per week;
  - reset on win;
  - announcement channel and whisper replies.

## Commands

- `/pp`: open the manager
- `/pp config`: settings
- `/pp log`: points log
- `/pp sync`: sync the softres sheet imported in Gargul
- `/pp whisper <name>`: preview a player's `!pp` reply
