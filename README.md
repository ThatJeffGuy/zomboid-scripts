# zomboid-scripts

Automated maintenance and supply-drop scripts for self-hosted
[Project Zomboid](https://github.com/indifferentbroccoli/projectzomboid-server-docker)
Docker servers. Designed for low-overhead server administration without
relying on third-party panel tools. Originally built for the PaymoneyWubby
Wubcord Community Server.

Run directly on the host (outside Docker) via cron, not inside the game
container.

> **Note:** the random-event/"storm" scripts that used to live in this repo
> (`event-*.sh`, `pz-event-lib.sh`) have moved to their own repo,
> [zomboid-storm-events](https://github.com/ThatJeffGuy/zomboid-storm-events),
> under their current names (`storm-*.sh`, `pz-storm-lib.sh`) -- this repo is
> now just the maintenance/supply-drop scripts below.

## Caretaking (`caretaking.sh`)

Automated maintenance manager that checks for stale mods and player activity
before initiating server updates.

- **Mod update detection:** monitors server logs via RCON to detect when
  Workshop mods are flagged as "need update".
- **Smart player detection:** checks online player counts via RCON before
  taking action.
- **Quiet hours:** optionally defers automated restarts during configurable
  hours, until the server is less active.
- **Dynamic warning system:** issues an RCON `servermsg` warning players to
  find safety (30-90 second delay based on player count, plus a final
  30-second warning).
- **Crash recovery:** detects a crashed game process even when the
  container itself is still "running," and restarts it -- rate-limited so a
  genuinely broken server escalates (optional email alert) instead of
  restart-looping forever.
- **Graceful restarts:** issues an RCON `save` and `quit`; relies on your
  container's own restart policy to bring it back up.
- **Health verification:** waits (configurable timeout) post-restart to
  confirm the server is back online and RCON is answering.
- **Logging & housekeeping:** output is appended to a dedicated log file,
  and it prunes old Zomboid logs and dangling Docker images.
- **Reboot prep (`--reboot-prep`):** for a host that reboots the container
  on a schedule: warns online players (`REBOOT_WARN_SECONDS`, default 5
  minutes, plus the final warning), saves the world, and exits; the reboot
  itself does the restart.
- **Keep-offline flag:** while `KEEP_OFFLINE_FLAG` exists, a stopped
  container is left stopped instead of auto-started (handy while a world is
  still being built). Put a date/time in the file (e.g. `2026-10-01 00:00`,
  in `KEEP_OFFLINE_TZ`) and it expires then: the next run deletes it, starts
  the server, and sends an alert. An empty file means "offline until deleted".

```
caretaking.sh --status     # print current state, don't act
caretaking.sh --dry-run    # log what it would do, change nothing
caretaking.sh --force      # skip the mod-freshness check, restart anyway
```

Configuration lives in variables at the top of the script (RCON connection,
paths, timing) -- edit those directly for your setup. Optional email alerts
on crash recovery are configured via `/etc/pz-caretaking.env` (root-only,
never commit this), not the script itself:

```bash
GMAIL_USER="you@gmail.com"
GMAIL_APP_PASS="xxxx xxxx xxxx xxxx"
EMAIL_TO="you@gmail.com"
```

Needs `swaks` installed for alerts to actually send; without it (or without
the env file), alerts just get logged instead.

Meant to run on a schedule (e.g. `*/30 * * * *` in root's crontab).

## Supply Drops (`supplydrop.sh`)

An automated event script that delivers randomized, weighted loot directly
to active players over RCON.

- **Weighted RNG distribution:** performs a weighted random selection using
  `pz-pool.txt` to deliver up to a few items per player.
- **Custom pool (`pz-pool.txt`):** a plain-text loot table you define
  yourself, with per-item drop weights -- format documented in the file's
  own header.
- **Immersive broadcasts:** announces drops with a randomized flavor message
  (customize `ANNOUNCE_MESSAGES` in the script for your own server's voice).
- **Cooldown engine:** randomizes the next drop window between a
  configurable minimum and maximum number of hours, to prevent predictable
  farming.
- **Testing & verification tools:** `--odds` simulates drop distributions
  and prints stats without touching the server; `--verify <Player>` spawns
  one of every pool item into a player's inventory to catch invalid item
  IDs.

```
supplydrop.sh                    # normal run (respects cooldown)
supplydrop.sh --dry-run          # simulate without giving items
supplydrop.sh --odds 1000        # print weight-distribution stats, exit
supplydrop.sh --verify <Player>  # spawn 1 of every pool item on a player
```

Meant to run on a schedule too (it self-schedules a random next window
after each successful drop).

## New-character kits (`newplayer-kit.sh`)

Gives a small kit every time a character is created, read from the server's
`PerkLog` (`[Created Player N]` lines, so set `PerkLogs=true` in the server ini).
Run it from cron every minute.

- **Brand-new player** (SteamID never seen on this world): `NEW_KIT` plus one
  random item from `MRE_CHOICES` to them, and one `MRE_CHOICES` item to
  everyone else online. The SteamID is then recorded.
- **Respawn after death** (known SteamID): `RESPAWN_KIT` to that player only.
- Offline players never get anything later (no queue); the triggering player is
  retried for 5 minutes in case they are still spawning or the server is
  restarting.
- Only the server's own `Item ... Added in ...'s inventory` reply counts as
  delivered, so an RCON outage never logs a false delivery.
- Reuses a random line from `ANNOUNCE_MESSAGES` in `supplydrop.sh` as the
  broadcast, read at run time (it never runs `supplydrop.sh`).
- `--seed` records every SteamID in the player DB as seen (run it once on an
  existing world); `--reset` forgets them (for a wiped world); `--dry-run`.

## Permission guard (`fix-perms.sh`)

Re-adds the executable bit to any `*.sh` in the scripts directory that lost
it. Editing scripts over an SMB share (or with tools that don't preserve
Unix permissions) can silently strip `+x`, after which cron can't run them at
all. Run it every 5 minutes from root's crontab:

```
*/5 * * * * /opt/app/zomboid/config/storms/fix-perms.sh >> /root/perm-guard.log 2>&1
```

## Extras

- **`extras/pz-health.sh`** -- read-only health snapshot for one game
  container: state, restarts, OOM kills, CPU/memory, whether the game and
  RCON ports are listening, online players, and new errors since boot
  (known-harmless vanilla B42 boot noise filtered out). Loop it for a soak
  test before opening a server up.
- **`extras/server-presets/`** -- an example of applying world settings that
  live in the save rather than in the sandbox file, without anyone logging
  in. `ServerPresets.lua` sets
  [Irish's Dinosaurs](https://steamcommunity.com/sharedfiles/filedetails/?id=3784875732)
  spawn weights/options and creates admin safezones around spawn points,
  once per world. It also locks the dino options: Irish's Dinosaurs pushes a
  joining admin's local options to the server and saves them into the world,
  so a fresh admin client can silently reset every tuned value. It must sit in the game's own `media/lua/server/` folder,
  which a game update could replace, so keep the real copy in your config
  directory and let the `presets-guard` systemd units (`.path` reacts within
  a second, `.timer` re-checks every 5 minutes) copy it back into place:

  ```
  install -m 0755 extras/server-presets/presets-guard.sh /usr/local/sbin/
  install -m 0644 extras/server-presets/presets-guard.{service,path,timer} /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now presets-guard.path presets-guard.timer
  ```

- **`examples/pools/`** -- the two Wubcord servers' themed supply-drop pools:
  `crater-of-trade.txt` (vanilla + that server's mods; its guns are named as
  [Guns of Marz](https://steamcommunity.com/sharedfiles/filedetails/?id=3722134990)
  items because Marz replaces vanilla guns and ammo on creation) and
  `zomboid-evolved.txt` (primal/dinosaur theme: archery, black powder, horse
  tack, dino bait and eggs, no modern guns). Every ID was checked against the
  scripts installed on that server; B42 renamed or removed dozens of B41 IDs.
- **`extras/zomboid-evolved/`** -- server-side scripts from Zomboid Evolved
  (Irish's Dinosaurs as the only threat):
  - `PE_DinoDamage.lua` -- every hit takes a fixed share of a dino's health by
    species and weapon class (e.g. raptor: 7-10 melee hits, 1-2 gunshots, 3-4
    arrows). B42 applies animal damage as `damage x healthLossMultiplier`,
    which made melee near-useless, while the knife close kill (the "chin stab")
    multiplies damage x1000 on *any* target whenever no more than one zombie
    is chasing you -- always true with zombies off -- and one-shot everything.
    Uses `Hook.WeaponHitCharacter`, which runs before damage and can cancel it.
  - `PE_DinoHeat.lua` -- spawn-zone safe radius that shrinks as the server
    ages (1000 tiles on day 0 to 150 by day 30, in real days), a frontier
    spawner that keeps dinos around players outside it, a hard keep-out
    around each camp, and camp pressure: a shelter budget per player, hunt
    packs sent after overstayers, and night raids once the zone has fully
    collapsed.
  - `PE_Sentries.lua` -- camp defenses. Wandering dinos and hostile Bandits
    inside a camp core are shot (a real corpse); hunt and raid packs meet a
    small ammo pool that reloads every few seconds. Every road into a camp gets
    a sandbag checkpoint (two walls across the road, a nest on each shoulder
    with a lamp), the gaps between them get single-row sandbag gates, and every
    lit lamp is secretly a gun that shoots dinos and hostile bandits near it.
    Kills are announced per camp team ("Alpha Team killed a raptor").
  - `PE_DefenseLine.lua` -- collapsing defense lines: every 50 tiles of radius a
    ring of sandbag gates (a checkpoint where a road crosses it) stands just
    inside the safe radius, falls into lootable ruins when the radius passes it,
    and is cleared 3 days later. Built lazily near players and only on loaded,
    clear ground. It also keeps the lamp list (global ModData `PELights`) that
    the map mod's `ZEM_Lights.lua` turns into light on every client.
  - `PE_AdminCmd.lua` -- a whitelisted command file (`Zomboid/Lua/PE/cmd.txt`)
    for testing things that need a player in game: spawn a dino or a Bandits
    clan near a player, list bandits and animal corpses, trigger a hunt or raid,
    build sample gates. It only runs while someone is online if the server has
    PauseEmpty on.
  - `ze-switchover.sh` / `pz-4221-reminder.sh` -- the plan for turning the Lua
    checksum back on once B42.21 (which re-enables `loadstring`) is Stable, and
    a one-shot email reminder for it. Done on Zomboid Evolved: the scripts run
    from `Zomboid/Lua/ZomboidEvolved/` through the map mod's loader, and a
    regular (non-admin) player joins with `DoLuaChecksum=true`.
  - **Checksum caveat:** the game's `media/lua/server` folder is part of the
    multiplayer Lua checksum, so server-only scripts placed there make
    non-admin players fail it (admins bypass it, which hides the problem).
- **`extras/map-mods/`** -- two Workshop mods that replace the in-game world
  map and minimap with a painted map (a B42 image pyramid, with the vanilla
  street and place names on top), and `build_pyramid.py`, which cuts map art
  into the `pyramid.zip` layout the game uses. The tile zips are not committed.
  `ZomboidEvolvedMap` also carries `ZE_ServerScripts.lua`, a server-side loader
  that runs scripts from `Zomboid/Lua/ZomboidEvolved/` with `loadstring`
  (B42.21+), keeping them out of the checksum, and `ZEM_Lights.lua`, which draws
  a steady light at every checkpoint lamp the server lists and plays the lamp
  guns' shots with a muzzle flash. Both mods carry a small server-browser
  branding script (`*_MenuBranding.lua`: a badge and banner on their server's
  row); its images are not committed, and `COTM_MenuBranding.lua` has
  placeholder host/IP values.

## Prerequisites

- Linux host environment.
- Docker & Docker Compose (built/tested against the
  [Indifferent Broccoli image](https://github.com/indifferentbroccoli/projectzomboid-server-docker),
  but not specific to it).
- RCON enabled on the target Project Zomboid instance.
- `bash`, `python3` (used for a minimal embedded RCON client -- no external
  RCON dependency needed), `awk`, `cron`.
- `swaks` only if you want `caretaking.sh`'s email alerts.

## Related

- [zomboid-status-page](https://github.com/ThatJeffGuy/zomboid-status-page) --
  a web status/admin page that can optionally read `caretaking.sh`'s log for
  mod-state/restart-reason display.
- [zomboid-storm-events](https://github.com/ThatJeffGuy/zomboid-storm-events) --
  the random-event rotation system (formerly part of this repo). If you run
  both, `storms.sh`'s own restart path shares a lock file with
  `caretaking.sh` (see the `LOCK`/`LOCK_FILE` variables in each) so the two
  never restart the server at the same time -- keep those two paths
  matching if you use both.

## License

CC0 1.0 Universal -- see [LICENSE](LICENSE). Public domain, no attribution
required, though a link back is always appreciated.
