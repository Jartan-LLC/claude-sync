# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `claude-sync upgrade` installs the newest release that is not breaking, then applies it
  to every running instance on the host, keeping each one's target, ports and settings. It
  links a breaking release's notes instead of installing it, and refuses an RPM install,
  which you upgrade with `dnf` as before; the README's Upgrade section has the details.
  From 0.1.1 or earlier, download claude-sync once more as in the README's Install
  section, then run `claude-sync upgrade`.
- `claude-sync setup` with no `--volume` or `--path` applies the installed version to the
  instance already set up, keeping its target. After upgrading the RPM, run it for each
  instance.
- Each instance records the version of claude-sync that set it up, and `pair` and `unpair`
  say when that version is older than the one installed.
- `claude-sync backup DIR` writes a gzip tar archive of the whole synced folder to DIR,
  including the files that do not sync, such as this device's login, and the trash can. It
  then removes the instance's older archives there, keeping the newest of each of the last
  4 weeks and 6 months; `--keep-weekly N` and `--keep-monthly N` change the counts.
- `claude-sync restore ARCHIVE --volume NAME | --path DIR` extracts an archive over a
  Docker volume or a directory, on any device. In a folder that syncs, the restored files
  reach every device.

### Fixed

- A background job's scratch space, `jobs/<id>/tmp/` in `~/.claude`, no longer syncs. It can
  hold gigabytes in tens of thousands of directories, which every other device copied and
  kept. Rerun `setup` on each device to get the new ignore list. Each device keeps the copies
  it already has: delete them by hand while no background job runs. The job's records beside
  them, `state.json` and `timeline.jsonl`, still sync.
- On a Syncthing already on the host (`--use-host-syncthing`) that syncs other folders too,
  claude-sync sometimes misread whether a folder or device was in Syncthing's list. Since
  0.1.0 this could make a repeated `setup` fail with `folder "claude-sync": folder has
  duplicate ID`, `uninstall` leave claude-sync's folder in place, and `pair` set a device
  that shares other folders as introducer. These no longer happen.

## [0.1.1] - 2026-10-09

### Fixed

- `pair` no longer gets stuck joining when this device has directories of its own that the
  other device lacks and that hold files claude-sync does not sync, such as a plugin
  version's `.in_use` marker or a half-written file. A device stuck joining under 0.1.0
  finishes after you upgrade and rerun `setup`, then `pair`.
- `pair` no longer waits forever on a directory the other device deleted while this device
  still has files in it.
- A directory deleted on another device is removed here too, even when it holds files
  claude-sync does not sync, such as a plugin's `.in_use` marker.
- `setup` applies a new ignore list at once instead of at Syncthing's next scan.
- `setup` no longer waits minutes for Syncthing's first scan of a large `~/.claude`.
- Messages that send you to Syncthing's web UI give its address, and a join that cannot finish
  says this device sends nothing until it does.

## [0.1.0] - 2026-10-09

### Added

- Each release ships claude-sync as a single file, with its SHA-256, and as an RPM for
  Fedora, both with build provenance attestations.
- `claude-sync version` prints the installed version.
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
  Syncthing already running on the host instead of starting a container. `pair`, `unpair`
  and `uninstall` find it on their own. A device that syncs other folders with that Syncthing
  is not made an introducer.
- `CLAUDE_SYNC_NAME` runs several instances on one host. When Syncthing's default ports
  are taken, a new instance's Syncthing picks free ones, and `setup --gui-port PORT
  --sync-port PORT` chooses them. `setup` prints the web UI and sync ports, and `pair`'s
  hints name this instance's sync port.
- `claude-sync unpair DEVICE-ID`: removes a device from every device, run on any of them.
  The ID goes on a list in the synced folder, which a companion beside each container's
  Syncthing applies; a device using its own Syncthing applies it when claude-sync runs
  there.

[Unreleased]: https://github.com/Jartan-LLC/claude-sync/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Jartan-LLC/claude-sync/releases/tag/v0.1.1
[0.1.0]: https://github.com/Jartan-LLC/claude-sync/releases/tag/v0.1.0
