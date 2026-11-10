# claude-sync

[![CI](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml)
[![Deploy Pages](https://github.com/Jartan-LLC/claude-sync/actions/workflows/pages.yml/badge.svg)](https://github.com/Jartan-LLC/claude-sync/actions/workflows/pages.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Jartan-LLC/claude-sync/badge)](https://scorecard.dev/viewer/?uri=github.com/Jartan-LLC/claude-sync)
[![License](https://img.shields.io/badge/license-MIT-blue)](https://github.com/Jartan-LLC/claude-sync/blob/main/LICENSE)
[![Open in Dev Containers](https://img.shields.io/static/v1?label=Dev%20Containers&message=Open&color=blue)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/Jartan-LLC/claude-sync)

Continuous sync of `~/.claude` across devices: change a setting or write a memory on one
machine, and it is there on the others.

Documentation: [jartan-llc.github.io/claude-sync](https://jartan-llc.github.io/claude-sync/)

## How it works

- `claude-sync` runs [Syncthing](https://syncthing.net/) in a container that syncs your
  `~/.claude`, whether it is a directory or a Docker volume mounted into dev containers.
- The container restarts with Docker, so sync survives reboots.
- Syncthing runs as the owner of your `~/.claude`. Its web UI has no password and
  listens only on `127.0.0.1` of the host running Docker, at the address
  `claude-sync status` prints while it runs;
  reach it from another machine through an SSH tunnel (`ssh -L 8384:127.0.0.1:8384 HOST`
  for the usual port 8384).
- If you already run Syncthing on the host, claude-sync can add its folder to that
  Syncthing instead (see [Using your own Syncthing](docs/own-syncthing.md)).

## Requirements

- Linux with Docker Engine 25 or newer and its Compose plugin, unless you [use your own
  Syncthing](docs/own-syncthing.md). macOS is untested.

## Install

claude-sync is one file. Download the latest release into `~/.local/bin`, which must be on
your `PATH`:

```bash
mkdir -p ~/.local/bin
curl -fsSLo ~/.local/bin/claude-sync \
    https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync
chmod +x ~/.local/bin/claude-sync
```

On Fedora or EL, install the RPM instead; `dnf` then keeps it current:

```bash
sudo dnf install \
    https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync.noarch.rpm
```

[Installing](docs/install.md) covers checking a download, the RPM's signing key, unattended
updates and removing claude-sync.

## Quickstart

1. On both devices, set up claude-sync; `setup` prints the device's ID:

   ```bash
   claude-sync setup --path ~/.claude        # a directory
   claude-sync setup --volume claude-data    # or a Docker volume
   ```

   Run `setup --path` on the host itself, not inside a container: Docker resolves the path
   on the host.

2. On the device whose files to start from, pair with the other one:

   ```bash
   claude-sync pair OTHER-ID --keep
   ```

3. Stop Claude Code on the other device, then pair it with the first:

   ```bash
   claude-sync pair FIRST-ID
   ```

   It joins: it takes the first device's files and moves its own changes to the trash can.
   `pair` returns once the join is done; start Claude Code there again.

To add a device later, set it up, stop Claude Code on it, and pair it with any device that
already syncs, on both sides; start Claude Code there again once its `pair` returns. To
remove one, run `claude-sync unpair OLD-ID` on any device that syncs.
[Pairing devices](docs/pairing.md) explains joining, `--keep`, private networks and what
to do when `pair` stops.

## Upgrade

On each device:

```bash
claude-sync upgrade
```

It installs the newest release that is not breaking and applies it to every running
instance; for a breaking release it links the release notes, which say how to upgrade by
hand. With the RPM, run `sudo dnf upgrade --refresh claude-sync` instead, then
`CLAUDE_SYNC_NAME=NAME claude-sync setup`, with no target, for each instance NAME; `dnf`
installs a breaking release too, without its manual steps, so read the notes of each release
it crosses. [Upgrading](docs/install.md#upgrading) covers claude-sync 0.1.1 and earlier,
older RPMs and breaking releases.

## Uninstall

```bash
claude-sync uninstall
```

Removes the container and this device's Syncthing state; with your own Syncthing, it
removes only claude-sync's folder from it. It also removes the daily backup, if set up.
Your `~/.claude` and the backup archives are untouched (see
[Commands](docs/commands.md#uninstall)).

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
| `jobs/*/tmp/` | A background job's scratch space on this machine |
| `*.tmp.<8 hex>`, `*.tmp.<pid>.<12 hex>` | Half-written files mid-save |

A directory deleted on another device is deleted here too, with any of these files in it.

## Documentation

The documentation for the latest release is published at
[jartan-llc.github.io/claude-sync](https://jartan-llc.github.io/claude-sync/). The pages
below are its source in this repository, and can describe changes not yet released:

- [Installing](docs/install.md): every install method, checking a download, the RPM's
  signing key, upgrading and removing claude-sync
- [Pairing devices](docs/pairing.md): joining, `--keep`, adding and removing devices,
  private networks
- [Commands](docs/commands.md): every command and flag, ports, several instances on one
  host, error messages
- [Recovering files](docs/recovering-files.md): the trash can, conflict copies and
  backups
- [Caveats](docs/caveats.md): Claude Code on two devices at once, plugins across home
  paths, and what else to expect from sharing one `~/.claude`
- [Using your own Syncthing](docs/own-syncthing.md): `--use-host-syncthing`

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute; [docs/scaffold.md](docs/scaffold.md)
covers CI, publishing, Liza and syncing with scaffold.

## License

[MIT](LICENSE)
