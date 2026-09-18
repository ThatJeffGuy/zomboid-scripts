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
