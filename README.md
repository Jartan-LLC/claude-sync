# claude-sync

[![CI](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Jartan-LLC/claude-sync/badge)](https://scorecard.dev/viewer/?uri=github.com/Jartan-LLC/claude-sync)

Continuous sync of `~/.claude` across devices: change a setting or write a memory on one
machine, and it is there on the others.

> **Status:** early. `setup` and `uninstall` work; pairing devices from the command line
> is next. Until then, pair devices in Syncthing's web UI.

## How it works

- `claude-sync` runs [Syncthing](https://syncthing.net/) in a container that syncs your
  `~/.claude`, whether it is a directory or a Docker volume mounted into dev containers.
- The container restarts with Docker, so sync survives reboots.
- Syncthing runs as the owner of your `~/.claude`. Its web UI has no password and
  listens only on `127.0.0.1:8384` of the host running Docker; reach it from another
  machine through an SSH tunnel (`ssh -L 8384:127.0.0.1:8384 HOST`).

## Requirements

- Linux with Docker Engine 25 or newer and its Compose plugin. macOS is untested.
- Ports 8384, 22000 and 21027 free: claude-sync's Syncthing cannot share a host with
  another Syncthing.
- With `--path`, run claude-sync on the host itself, not inside a dev container: Docker
  resolves the path on the host.

## Setup

```bash
git clone https://github.com/Jartan-LLC/claude-sync.git
cd claude-sync
./claude-sync setup --path ~/.claude        # a directory
./claude-sync setup --volume claude-data    # or a Docker volume
```

`setup` refuses a root-owned target: `chown` it to the user who runs Claude Code. It is
safe to re-run, rewrites `.stignore` from this repo each time, and prints this device's
ID. Pair a new device while its `~/.claude` is empty and Claude Code is not running there;
otherwise its fresh files can replace yours on every device.

To pair, open each device's web UI, add the other device by its ID, and share the `claude`
folder with it.

## Uninstall

```bash
./claude-sync uninstall
```

Removes the container and this device's Syncthing state, including its device ID. Your
`~/.claude` is untouched; Syncthing's `.stignore`, `.stfolder` and `.stversions` stay in it
and can be deleted, though deleting `.stversions` empties the trash can.

## What syncs

Everything in `~/.claude` except what is meaningless or harmful on another machine
([`stignore`](stignore)):

| Not synced | Why |
|---|---|
| `.credentials.json` | Your login: one per device |
| `sessions/*.json`, `sessions/*.key` | Named after a process ID on one machine |
| `.update.lock`, `ide/*.lock`, `tasks/*/.lock`, `plugins/cache/**/.in_use` | Held by a process on one machine |
| `plugins/marketplaces/` | Git clones each machine pulls on its own |
| `daemon/`, `session-env/`, `shell-snapshots/`, `telemetry/` | This machine's daemon, session environments, shell snapshots and unsent telemetry |
| `*.tmp.<8 hex>`, `*.tmp.<pid>.<12 hex>` | Half-written files mid-save |

Each device keeps the previous copy of anything another device deleted or overwrote for
14 days, in Syncthing's trash can (`.stversions` in the synced folder).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute; [docs/scaffold.md](docs/scaffold.md)
covers the dev container, CI and Liza.

## License

[MIT](LICENSE)
