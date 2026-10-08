# claude-sync

[![CI](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Jartan-LLC/claude-sync/badge)](https://scorecard.dev/viewer/?uri=github.com/Jartan-LLC/claude-sync)

Continuous sync of `~/.claude` across devices: change a setting or write a memory on one
machine, and it is there on the others.

> **Status:** early. `setup`, `pair`, `unpair` and `uninstall` work on Linux; expect rough
> edges.

## How it works

- `claude-sync` runs [Syncthing](https://syncthing.net/) in a container that syncs your
  `~/.claude`, whether it is a directory or a Docker volume mounted into dev containers.
- The container restarts with Docker, so sync survives reboots.
- Syncthing runs as the owner of your `~/.claude`. Its web UI has no password and
  listens only on `127.0.0.1` of the host running Docker, on the port `setup` prints;
  reach it from another machine through an SSH tunnel (`ssh -L 8384:127.0.0.1:8384 HOST`
  for the usual port 8384).
- If you already run Syncthing on the host, claude-sync can add its folder to that
  Syncthing instead (see [Use your own Syncthing](#use-your-own-syncthing)).

## Requirements

- Linux with Docker Engine 25 or newer and its Compose plugin, unless you [use your own
  Syncthing](#use-your-own-syncthing). macOS is untested.
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

In its own container, `setup` also prints the web UI port and the sync port: Syncthing's
usual 8384 and 22000, or free ports Syncthing picks on the first run when another
program, such as another Syncthing, holds those. `--gui-port` and `--sync-port` choose
them instead, and later runs keep them. If another program later takes the web UI port,
Syncthing cannot start its web UI and `setup` cannot move it: free that port again.

### Use your own Syncthing

If Syncthing 2 or newer already runs on the host as you, the user who runs Claude Code
and claude-sync, `--use-host-syncthing` adds claude-sync's folder to it instead of
starting a container:

```bash
./claude-sync setup --path ~/.claude --use-host-syncthing
```

This needs curl but not Docker, and works only with `--path`. claude-sync changes nothing
in that Syncthing beyond its own folder, the devices you pair and the devices `unpair`
removes. `pair`, `unpair` and `uninstall` find it on their own. `setup` refuses a
directory one of that Syncthing's folders syncs, or one inside or around it, following
symlinks, since its files would sync twice. `--private` and `--public` are refused, since
they would change how your other folders connect; set those options in Syncthing itself.
If global discovery is off there, `pair` needs `--address`, as on a [private
network](#private-networks).

When you pair (see below), a device that already syncs other folders with your Syncthing
is not made an introducer, since the devices it introduces would join those folders too.
`pair` then says so, and this device needs pairing with each of the others directly.

Once your Syncthing syncs claude-sync's folder, `setup` without `--use-host-syncthing`
refuses to start a container beside it, since `pair`, `unpair` and `uninstall` would then
act on the container instead.

A device that `unpair` removed elsewhere stays in your Syncthing until claude-sync's
`setup`, `pair`, `unpair` or `uninstall` next runs here: with no container, nothing beside
your Syncthing applies the list of removed devices in between. Until then your Syncthing
may also introduce the device to the others again, which drop it within seconds. A
removed device that also syncs other folders with your Syncthing then leaves only
claude-sync's folder.

### Several instances on one host

`CLAUDE_SYNC_NAME` names an instance: its container and the volume that holds its
Syncthing state. Under different names, one host can sync several `~/.claude` volumes or
directories, each as a device of its own. Give the same name to every command for that
instance:

```bash
CLAUDE_SYNC_NAME=claude-work ./claude-sync setup --volume work-claude
CLAUDE_SYNC_NAME=claude-work ./claude-sync pair OTHER-ID
```

Each instance gets ports of its own, which `setup` prints, as long as the other instances
are running when it first starts: Syncthing takes free ports only then. A name other than
the default, `claude-sync`, can't be combined with `--use-host-syncthing`, since your own
Syncthing holds one claude-sync folder; neither can `--gui-port` or `--sync-port`, since
you set that Syncthing's ports in Syncthing itself.

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
other directly. With your own Syncthing, a device it already syncs other folders with is
the exception (see [Use your own Syncthing](#use-your-own-syncthing)).

A device that syncs with no other yet joins: it sends nothing until it has the others'
files, then moves its own changes, such as a fresh `settings.json` from Claude Code, to
the trash can and syncs both ways. Without this, those newer files would replace yours on
every device. `pair` waits until the join is done, and is safe to interrupt and re-run.
Stop Claude Code on the new device until it finishes: a change made just as the join ends
can still reach the others.

`--keep` keeps this device's files instead, including on a re-run that finishes an
interrupted join; files the join already moved aside stay in the trash can (see
[Recover a file](#recover-a-file)). Paired with
devices that already have files, its files merge with theirs: for each file the newer copy
wins and the other stays as a conflict copy.

If a device with files of its own would join devices that have none, which happens when
the first pairing is missing `--keep`, `pair` stops and undoes the pairing without
discarding anything.

### Remove a device

```bash
./claude-sync unpair OLD-ID    # on any device that syncs
```

`unpair`, run on any device that syncs, removes the device from every device. It adds a
file named after the ID to the `.claude-sync-unpaired` directory in the synced folder, and
each device removes the devices listed there, again whenever an introduction brings one
back. Once every device refuses the removed one, it stops syncing; run `uninstall` there
to remove its state. Pairing the device again with `pair` takes it off the list. `unpair`
refuses on a device that is still joining; finish the join first. A device set up with an
earlier claude-sync applies the list once `setup` has run there again, and one using its
own Syncthing applies it when claude-sync runs there (see [Use your own
Syncthing](#use-your-own-syncthing)).

### Private networks

By default devices find each other anywhere, through Syncthing's global discovery and
relays, with traffic encrypted end to end. `setup --private` turns off global discovery,
relays and NAT traversal, so each device needs the other's address when pairing:

```bash
./claude-sync pair OTHER-ID --address tcp://other-host:22000
```

Use the sync port the other device's `setup` printed, 22000 unless it said otherwise; for a
device using its own Syncthing, the port that Syncthing listens on.

To correct an address, pair again with the new `--address`. A device stays private when
`setup` is re-run; `setup --public` returns it to the defaults.

## Uninstall

```bash
./claude-sync uninstall
```

Removes the container and this device's Syncthing state, including its device ID. Your
`~/.claude` is untouched; Syncthing's `.stignore`, `.stfolder` and `.stversions`, and
claude-sync's `.claude-sync-unpaired`, stay in it and can be deleted, though deleting
`.stversions` empties the trash can.

If you set up with `--use-host-syncthing`, `uninstall` removes only claude-sync's folder
from your Syncthing, and the devices you paired stay, apart from those `unpair` removed
that share no other folder with it.
Syncthing deletes the folder's `.stfolder` itself.

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

Each device keeps the previous copy of anything another device deleted or overwrote, and
of anything a join moved aside, for 14 days, in Syncthing's trash can: `.stversions` in
the synced folder, at the file's own path. Copy it back as the folder's owner:

```bash
cp ~/.claude/.stversions/settings.json ~/.claude/settings.json
```

For a Docker volume, run the copy in a container that mounts it, as the volume's owner
(1000:1000 here; `docker run --rm -v claude-data:/claude busybox stat -c %u:%g /claude`
prints yours):

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
