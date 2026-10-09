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
  Syncthing instead (see [Using your own Syncthing](docs/own-syncthing.md)).

## Requirements

- Linux with Docker Engine 25 or newer and its Compose plugin, unless you [use your own
  Syncthing](docs/own-syncthing.md). macOS is untested.
- With `--path`, run claude-sync on the host itself, not inside a dev container: Docker
  resolves the path on the host.

## Install

claude-sync is one file. Download the latest release into `~/.local/bin`, which must be on
your `PATH`:

```bash
mkdir -p ~/.local/bin
curl -fsSLo ~/.local/bin/claude-sync \
    https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync
chmod +x ~/.local/bin/claude-sync
```

`gh attestation verify ~/.local/bin/claude-sync --repo Jartan-LLC/claude-sync` checks that
the file was built by this repository's release workflow; each release also lists its
SHA-256 in `claude-sync.sha256`.

On Fedora, or another distribution that installs RPMs with `dnf`, install the release's
package instead:

```bash
sudo dnf install \
    https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync.noarch.rpm
```

The package is not signed, so `dnf` warns that it skipped its OpenPGP check;
`gh attestation verify` checks it as it does the single file.

## Quickstart

1. On both devices, set up claude-sync; `setup` prints the device's ID:

   ```bash
   claude-sync setup --path ~/.claude        # a directory
   claude-sync setup --volume claude-data    # or a Docker volume
   ```

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

Download claude-sync again, or rerun the `dnf install` line, as in [Install](#install).
Then rerun `setup` on each device as you first ran it there, so it applies the new
version's Syncthing settings and ignore list.

## Uninstall

```bash
claude-sync uninstall
```

Removes the container and this device's Syncthing state; with your own Syncthing, it
removes only claude-sync's folder from it. Your `~/.claude` is untouched (see
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
| `*.tmp.<8 hex>`, `*.tmp.<pid>.<12 hex>` | Half-written files mid-save |

## Documentation

- [Pairing devices](docs/pairing.md): joining, `--keep`, adding and removing devices,
  private networks
- [Commands](docs/commands.md): every command and flag, ports, several instances on one
  host, error messages
- [Recovering files](docs/recovering-files.md): the trash can and conflict copies
- [Using your own Syncthing](docs/own-syncthing.md): `--use-host-syncthing`

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute; [docs/scaffold.md](docs/scaffold.md)
covers the dev container, CI and Liza.

## License

[MIT](LICENSE)
