# 📜 List of Somebody That Knocked My SSH (and ban.sh, so they Knock-Knock Nobody's Home)

> *"Who's there?" — Nobody, because they're banned.*

A one-file cron job that pulls a remote IP/CIDR blacklist over HTTP, loads it into an `ipset`, and drops every entry at the `iptables` level. Point it at your blacklist URL, drop it in cron, and let your firewall update itself daily — no manual list-editing, no per-IP rules piling up.

## Why this exists

Every server's `auth.log` eventually turns into a highlight reel of strangers trying `root:123456` at 3am. Instead of banning IPs one at a time, `ban.sh` syncs your whole `INPUT` chain against a single remote text file of offenders — and keeps it in sync automatically, hour after hour.

## What's inside

| File | Purpose |
|---|---|
| `ban.sh` | Downloads the list from `$URL`, validates each entry, syncs it into an `ipset` (`hash:net`), and ensures one `iptables DROP` rule matches the whole set. Optionally mirrors the remote list exactly (removes stale entries that fell off the list). |

## How it works

1. **Installs `ipset`** automatically if missing (supports `apt`, `dnf`, `yum`, `apk`).
2. **Creates the ipset** `blacklist` (type `hash:net`) if it doesn't exist yet, and sanity-checks the type if it does.
3. **Adds one iptables rule**: `INPUT -m set --match-set blacklist src -j DROP`, tagged with a comment so it's never duplicated.
4. **Downloads the list** from `$URL` via `curl` or `wget`.
5. **Validates every line** as a proper IPv4 address or CIDR (bad/malformed lines are skipped and counted, not silently ignored).
6. **Syncs the set**: adds new entries, skips ones already present, and — if `REMOVE_ORPHANS=1` — deletes anything in the live ipset that's no longer in the downloaded list (true mirror mode).
7. **Logs a one-line summary**: `added / skipped / invalid / removed / total`.
8. **Locks itself** with `flock` so overlapping cron runs can't stomp on each other.

## Requirements

- Linux with `iptables` installed
- `curl` or `wget`
- root (the script refuses to run otherwise)
- `ipset` — auto-installed on first run if missing

## Quick start

```bash

cd somebody-knocked-my-ssh/

sudo cp ban.sh /usr/local/sbin/ban.sh
sudo chmod +x /usr/local/sbin/ban.sh

# edit the URL at the top of the script to point at your own list
sudo nano /usr/local/sbin/ban.sh

sudo /usr/local/sbin/ban.sh
```

## Daily (or hourly) auto-update

```bash
sudo crontab -e
```

```cron
0 */6 * * * /usr/local/sbin/ban.sh >> /var/log/blacklist-sync.log 2>&1
```

Every run re-downloads the list and re-syncs the ipset, so newly added entries on the remote list are picked up automatically — and, with mirror mode on, expired entries are dropped too.

## Configuration

All settings live at the top of the script:

| Variable | Default | Meaning |
|---|---|---|
| `URL` | — | Where to fetch the plaintext IP/CIDR list from (one entry per line, `#` comments allowed) |
| `SET_NAME` | `blacklist` | Name of the ipset used |
| `REMOVE_ORPHANS` | `1` | `1` = mirror the remote list exactly (removes IPs no longer on the list). `0` = only ever add, never remove |
| `LOCK_FILE` | `/run/blacklist-sync.lock` | Prevents overlapping runs |
| `IPTABLES_COMMENT` | `ipset-blacklist-drop` | Comment tag used to detect/avoid duplicate iptables rules |

## Checking status

```bash
ipset list blacklist | head -n 20
ipset list blacklist | grep "Number of entries"
iptables -L INPUT -n --line-numbers | grep blacklist
```

## Removing it

```bash
sudo iptables -D INPUT -m set --match-set blacklist src -j DROP -m comment --comment "ipset-blacklist-drop"
sudo ipset destroy blacklist
```

## Notes / gotchas

- IPv4 only — `hash:net` here is validated for dotted-quad IPv4 and `/0`–`/32` CIDR only.
- The remote URL should ideally be hard-to-guess or access-controlled (this script doesn't do auth) since anyone who finds it can see what you consider a "fraud" IP list.
- Mirror mode (`REMOVE_ORPHANS=1`) means if your remote list is temporarily empty or broken, you could unban everyone on the next sync — keep an eye on the log's `removed=` count for anything suspicious.

## License

MIT. Ban responsibly.
