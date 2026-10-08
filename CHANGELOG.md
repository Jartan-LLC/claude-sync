# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `claude-sync setup --volume NAME | --path DIR`: runs Syncthing in a container that syncs
  `~/.claude` as its owner, skipping per-machine files and keeping a 14-day trash can.
- `claude-sync uninstall`: removes the container and Syncthing state, leaving the synced
  folder untouched.
- `claude-sync pair DEVICE-ID [--keep] [--address ADDR]`: pairs devices from the command
  line. A new device joins without its files replacing the others', and every device
  introduces new devices to the rest.
- `claude-sync setup --private | --public`: turns global discovery, relays and NAT
  traversal off or back on.
- `setup` fails with Syncthing's message when Syncthing cannot sync the folder.
- `claude-sync setup --path DIR --use-host-syncthing`: adds claude-sync's folder to a
  Syncthing already running on the host instead of starting a container. `pair` and
  `uninstall` find it on their own. A device that syncs other folders with that Syncthing
  is not made an introducer.
- `CLAUDE_SYNC_NAME` runs several instances on one host. When Syncthing's default ports
  are taken, a new instance's Syncthing picks free ones, and `setup --gui-port PORT
  --sync-port PORT` chooses them. `setup` prints the web UI and sync ports, and `pair`'s
  hints name this instance's sync port.

[Unreleased]: https://github.com/Jartan-LLC/claude-sync/commits/main
