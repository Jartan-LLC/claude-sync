# claude-sync

[![CI](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/Jartan-LLC/claude-sync/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Jartan-LLC/claude-sync/badge)](https://scorecard.dev/viewer/?uri=github.com/Jartan-LLC/claude-sync)

Continuous sync of `~/.claude` across devices: change a setting or write a memory on one
machine, and it is there on the others.

> **Status:** planned, not yet built.

## How it works

- A [Syncthing](https://syncthing.net/) container on each host mounts the `claude-data`
  Docker volume that holds `~/.claude` and keeps it in sync with the other devices.
- It runs on the host, not in a dev container, so it survives reboots and needs no change
  to any `devcontainer.json`.
- `install.sh` sets up a device: the Syncthing service, its ignore list and a weekly volume
  backup.

## What syncs

Everything in `~/.claude` except what is meaningless or harmful on another machine:

| Not synced | Why |
|---|---|
| `.credentials.json` | Your login: one per device |
| `sessions/*.json`, `sessions/*.key`, `plugins/cache/**/.in_use` | Keyed by a process ID on one machine |
| `*.lock` | Lock files |
| `*.tmp*` | Half-written files mid-save |

Each device keeps deleted or overwritten files for 14 days in Syncthing's trash can.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md); `make check` runs the CI gate.
[docs/scaffold.md](docs/scaffold.md) covers the dev container, CI and Liza.

## License

[MIT](LICENSE)
