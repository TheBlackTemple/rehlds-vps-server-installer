# CS 1.6 ReHLDS Server Installer

A couple of bash scripts to stand up a Counter-Strike 1.6 server on a fresh
VPS, running **ReHLDS** + **ReGameDLL_CS** instead of stock HLDS, with
Metamod-R, AMX Mod X, ReAPI, and (optionally) Reunion on top.

**This is unmaintained.** I built it for my own deployment, it works on my
box, and I'm not planning to keep it updated as upstream projects release
new versions. Feel free to fork it, but don't expect fixes or support.
Pinned versions/URLs may go stale over time.

Tested on **Ubuntu 24.04**. Debian 12 is the same target the scripts were
written against (see comments in `bootstrap-root.sh`) and should mostly
work, but I haven't personally verified it.

## What's here

- `bootstrap-root.sh` — Phase 1, run as root. OS packages, i386 multiarch,
  service user, ufw, fail2ban, unattended-upgrades, swap.
- `install-server.sh` — Phase 2, run as the service user (non-root).
  Installs LinuxGSM, swaps in ReHLDS/ReGameDLL_CS, installs Metamod-R/AMX
  Mod X/ReAPI/Reunion, writes hardening cvars + rcon password, and installs
  a cron-safe update wrapper.
- `wrapper-update.sh` — an optional cron-safe wrapper that runs LinuxGSM's
  normal update, then restores the ReHLDS/ReGameDLL_CS files that update
  would otherwise silently overwrite. `install-server.sh` will offer to
  install it and add a cron entry for it. **I don't run this myself and
  wouldn't recommend enabling it** — see below.
- `env.conf` — config values both scripts source (paths, ports, pinned
  versions, asset-matching regexes). Fill this in before running anything.

## Order to run things

1. `sudo ./bootstrap-root.sh` (root)
2. Populate `LOCAL_ASSET_DIR` (see below)
3. `su - <service_user>`, then `./install-server.sh` (non-root)

`install-server.sh` assumes step 1 already happened — it doesn't check for
it, it'll just fail partway through with a generic LinuxGSM "missing
dependencies" error if you skip straight to it.

## Populating LOCAL_ASSET_DIR

Downloads are stubbed out — nothing is fetched automatically. Before running
`install-server.sh`, manually download each component's release archive
yourself and drop it into `LOCAL_ASSET_DIR` (default:
`~/.cs16-installer-local`, overridable via env var or `env.conf`).

Each file's name just needs to match that component's `*_ASSET_REGEX` from
`env.conf`, and its version should match the corresponding `*_PINNED_TAG`.
For ReHLDS specifically, also drop the matching `.asc` signature file next
to the archive (same filename + `.asc`) if you want GPG verification to run
— see the security note below.

Copies of the exact release files I used are included alongside this README
so you don't have to go hunting for matching versions yourself.

## Security notes

- **GPG verification only exists for ReHLDS**, and even there it's a
  *check, not a gate* — if the signature is missing, unverifiable, or fails,
  the script warns loudly and proceeds anyway rather than stopping.
- **ReGameDLL_CS, Metamod-R, AMX Mod X, ReAPI, and Reunion have no
  cryptographic verification at all.** The whole trust model here rests on
  you sourcing these binaries yourself from a source you trust. Don't drop
  arbitrary files matching the asset regexes into `LOCAL_ASSET_DIR`.
- RCON is closed by default and only opened (restricted to `ADMIN_IP`) if
  you set that in `env.conf`.
- `--latest` and `--hardened` are currently no-ops (stubbed) — see comments
  in `install-server.sh` for why.

## About the update wrapper (cron)

`install-server.sh` will offer to install `wrapper-update.sh` and schedule
it via cron so LinuxGSM updates don't silently revert ReHLDS/ReGameDLL_CS
back to stock. I skipped this in my own deployment and would suggest
declining it when asked, for the same reason: it's an unattended process
that overwrites game server binaries with no human in the loop, and its
post-restore checks only warn instead of failing loudly. I'd rather run
updates manually and actually watch what happens. The script is included
for completeness / in case it's useful to someone, not because I'd vouch
for running it unattended.

If you do want auto-updates, at minimum point the cron job's stdout to
something you'll actually check (the wrapper logs there by default) rather
than assuming silence means success.

## Logs

The update wrapper appends to `logs/wrapper-update.log` on every cron run
with no rotation. Not handled — clean it up yourself if it grows too large.

## Credits

This just automates installing other people's work. All credit to the
actual projects:

- [LinuxGSM](https://linuxgsm.com/)
- [ReHLDS](https://github.com/rehlds/ReHLDS)
- [ReGameDLL_CS](https://github.com/s1lentq/ReGameDLL_CS)
- [Metamod-R](https://github.com/theasvel/metamod-r)
- [AMX Mod X](https://www.amxmodx.org/)
- [ReAPI](https://github.com/s1lentq/reapi)
- [Reunion](https://github.com/theasvel/reunion)

## License

No restrictions — free to use, modify, and redistribute as you like.
