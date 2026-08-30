I run a dedicated server for Project Zomboid, self hosted with [Indifferent Broccoli's](https://github.com/indifferentbroccoli/projectzomboid-server-docker) image for the PaymoneyWubby Discord and have come across many annoyances and tweaks needed for the day to day of a server admin that doesn't have fancy tools.

# Caretaking Script
Logic carrying script to check for players online, and if none are online, reboots the server so it can get mod updates.

1. Runs every hour as a crontab entry.
2. If players are online, using RCON, it sends a servermsg to the users online stating they have 30-90 seconds to get safe.
3. The script triggers a save and then a quit, both RCON based. The docker compose is set to auto-restart so it starts up right away.
4. If the server is under heavy load during prime time, it gives the users 90 seconds. You can adjust the heavy hours inside, or disable completely.
5. Waits for the server to come back online to verify, 180s countdown.
6. Exits cleanly and logs to a .log file what happened.

# Supply Drops
Logic carrying script that sends "supply drops" to players online. Runs hourly as a crontab entry.
1. Rolls a number between 1-10000 and assigns it to every user, discreetly.
2. Rolls 3 more numbers between 1 and unlimited (you define it in script) to read a numbered list of loot (pz-loot.txt)
3. Gives users online the items it finds in the 3 rolls above.
4. Assigns a durability check against the first number, and scuffs up stuff if needed.
5. Sends a servermsg out to players for flare, signaling that "something is about to happen".
6. Sends inventory lottery items directly to player inventory.
7. Creates a cooldown file for the hourly trigger; the script has built in cool downs you set, so it can only happen x amount of times per day, once every x hours, or manually run.

# The rest of these scripts are fringe cases and used primarily for my server, however will post them here anyway.

GenMods -- No logic here, after the server is started, generates a list for your options.ini for the Mods= line automatically, and sorts it.

CaseLinks -- Scans for mods that incorrectly have capitals and vice versa, and renames/fixes them. Run with server offline.

Refetch -- Will allow server owners to delete individal mod folders from workshop, and re-acquire it only, updating the manifest file. No more nuclear bomb diagnostics!

Deploy -- Partner script for above.
