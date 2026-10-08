# claude-sync

[![CI](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Jartan-LLC/claude-sync/badge)](https://scorecard.dev/viewer/?uri=github.com/Jartan-LLC/claude-sync)

Continuous sync of `~/.claude` across devices: change a setting or write a memory on one
machine, and it is there on the others.

> **Status:** early. `setup`, `pair` and `uninstall` work on Linux; expect rough edges.

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
ID. It fails, with Syncthing's message, if Syncthing cannot sync the folder.

## Pair devices

Run `setup` on every device first; it prints the device's ID. Pair two devices by running
`pair` on each with the other's ID. The first pairing starts from the files of one device,
so that one gets `--keep`:

```bash
./claude-sync pair OTHER-ID --keep    # on the device whose files to start from
./claude-sync pair FIRST-ID           # on the other device
```

To add a device later, pair it with any device that already syncs, on both sides. That
device introduces it to all the others, and them to it, so every device syncs with every
other directly.

A device that syncs with no other yet joins: it sends nothing until it has the others'
files, then moves its own changes to the trash can, such as a fresh `settings.json` from
Claude Code, and syncs both ways. Without this, those newer files would replace yours on
every device. `pair` waits until the join is done, and is safe to interrupt and re-run.
Stop Claude Code on the new device until it finishes: a change made just as the join ends
can still reach the others.

`--keep` keeps this device's files instead, including on a re-run that finishes an
interrupted join; files that join already undid stay in the trash can. Paired with devices that already have files, its files merge with
theirs: for each file the newer copy wins and the other stays as a conflict copy.

If a device with files of its own would join devices that have none, which happens when
the first pairing is missing `--keep`, `pair` stops and undoes the pairing without
discarding anything.

### Private networks

By default devices find each other anywhere, through Syncthing's global discovery and
relays, with traffic encrypted end to end. `setup --private` turns off global discovery,
relays and NAT traversal; give each device the other's address when pairing, on both
sides:

```bash
./claude-sync pair OTHER-ID --address tcp://other-host:22000
```

A device stays private when `setup` is re-run; `setup --public` returns it to the
defaults.

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

## Recover a file

Each device keeps the previous copy of anything another device deleted or overwrote for
14 days, in Syncthing's trash can: `.stversions` in the synced folder, at the file's own
path. Copy it back as the folder's owner:

```bash
cp ~/.claude/.stversions/settings.json ~/.claude/settings.json
```

For a Docker volume, run the copy in a container that mounts it, as the volume's owner
(1000:1000 here; `ls -n` inside the volume shows yours):

```bash
docker run --rm --user 1000:1000 -v claude-data:/claude busybox \
    cp /claude/.stversions/settings.json /claude/settings.json
```

When two devices change a file before syncing, the newer change wins and the other is
kept beside it as `NAME.sync-conflict-DATE-TIME-DEVICE.EXT`, on every device.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute; [docs/scaffold.md](docs/scaffold.md)
covers the dev container, CI and Liza.

## License

[MIT](LICENSE)
