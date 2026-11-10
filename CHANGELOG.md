# Changelog

This file lists what changes for users in each release.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!--
Add each change users will notice, under a heading such as ### Added, ### Changed or ### Fixed.
Say what changes for them, not how or why it was done.
Say what they must do to upgrade, if anything.
Put a breaking change first under its heading, starting with "Breaking:".
-->

## [0.2.0] - 2026-11-10

### Upgrading from 0.1.1

On each device:

- Single file: download claude-sync again, as in
  [Single file](https://github.com/Jartan-LLC/claude-sync/blob/main/docs/install.md#single-file),
  then run `claude-sync upgrade`, which applies it to every running instance.
- RPM: rerun the `dnf install` line from
  [RPM](https://github.com/Jartan-LLC/claude-sync/blob/main/docs/install.md#rpm) once, then
  run `CLAUDE_SYNC_NAME=NAME claude-sync setup` for each instance NAME that
  `claude-sync list` shows.

[Upgrading](https://github.com/Jartan-LLC/claude-sync/blob/main/docs/install.md#upgrading) has the details.

### Added

- The docs are published at `https://jartan-llc.github.io/claude-sync/`, among them a page on
  the limits of sharing one `~/.claude` between devices and what to do about each.
- The RPM is signed, and installs claude-sync's dnf repository, so
  `sudo dnf upgrade --refresh claude-sync` installs each new release.
- `claude-sync upgrade` installs the newest release that is not breaking, then applies it
  to every running instance on the host, keeping each one's target, ports and settings. It
  links a breaking release's notes instead of installing it, and refuses an RPM install,
  which you upgrade with `dnf` as before;
  [Upgrading](https://github.com/Jartan-LLC/claude-sync/blob/main/docs/install.md#upgrading)
  has the details. It needs claude-sync saved as a file: run through `bash -s`, `bash -c` or
  `bash <(...)`, it refuses.
- `claude-sync setup` with no `--volume` or `--path` applies the installed version to the
  instance already set up, keeping its target. After upgrading the RPM, run
  `CLAUDE_SYNC_NAME=NAME claude-sync setup` for each instance NAME.
- Each instance records the version of claude-sync that set it up, and `pair` and `unpair`
  say when that version is older than the one installed.
- `claude-sync backup DIR` writes a gzip tar archive of the whole synced folder to DIR,
  including the files that do not sync, such as this device's login, and the trash can. It
  then removes the instance's older archives there, keeping the newest of each of the last
  4 weeks and 6 months; `--keep-weekly N` and `--keep-monthly N` change the counts.
- `claude-sync restore ARCHIVE --volume NAME | --path DIR` extracts an archive over a
  Docker volume or a directory, on any device. In a folder that syncs, the restored files
  reach every device.
- `claude-sync status` shows how the instance commands act on is set up and how it syncs:
  where its Syncthing runs and what it syncs, the web UI's address, the device ID, the sync
  port, whether it is private or public, the folder's state, the number of conflict
  copies, the version that set it up, and whether a newer release is out. It lists the
  devices the folder is shared with: whether each is connected, directly or through a
  relay, when it was last seen, and how much of the folder it has. It changes nothing.
- `claude-sync list` lists the host's instances: each one's name, whether it runs, and the
  volume or directory it syncs, with the one commands act on marked.
- `claude-sync use NAME` makes later commands act on instance NAME without
  `CLAUDE_SYNC_NAME`, until `claude-sync use claude-sync` returns to the default or
  `uninstall` removes that instance. `CLAUDE_SYNC_NAME`, when set, still wins. `setup`,
  `pair`, `unpair`, `uninstall` and `backup` say on stderr which instance they act on when
  it is not `claude-sync`.
- `claude-sync setup --backup-dir DIR` runs `claude-sync backup DIR` for the instance every
  day, with a systemd user timer, while you are logged in; a day missed runs at your next
  login. Later runs of `setup` and `upgrade` keep it; `setup --no-backup` and `uninstall`
  remove it. Hosts without systemd's user manager, such as macOS, refuse it, and so does a
  claude-sync run through `bash -s`, `bash -c` or `bash <(...)`, not saved as a file.

### Changed

- Breaking: a mistake the command line alone shows now exits 2, not 1, and still says what
  is wrong: an unknown argument, a missing or empty value, options that cannot go together,
  a value of the wrong form, or an argument to `list`, `status`, `uninstall` or `upgrade`.
  A script that tests for exit status 1 after such a mistake must test for 2. A missing
  argument exits 2 as before; other failures still exit 1.
- The container runs Syncthing 2.1.7, up from 2.1.6;
  [its release notes](https://github.com/syncthing/syncthing/releases/tag/v2.1.7) list the
  fixes.

### Fixed

- A background job's scratch space, `jobs/<id>/tmp/` in `~/.claude`, no longer syncs. It can
  hold gigabytes in tens of thousands of directories, which every other device copied and
  kept. The upgrade steps above apply the new ignore list on each device. Each device keeps
  the copies it already has: delete them by hand while no background job runs. The job's
  records beside them, `state.json` and `timeline.jsonl`, still sync.
- On a Syncthing already on the host (`--use-host-syncthing`) that syncs other folders too,
  claude-sync sometimes misread whether a folder or device was in Syncthing's list. Since
  0.1.0 this could make a repeated `setup` fail with `folder "claude-sync": folder has
  duplicate ID`, `uninstall` leave claude-sync's folder in place, and `pair` set a device
  that shares other folders as introducer. These no longer happen.
- When `setup` checked a path against the folders of the Syncthing on the host, it read a
  quoted `~NAME` at the start of the path as the home directory followed by NAME, a
  directory beside the home directory, since 0.1.0. It now leaves `~NAME` as a name.
- `setup --path ""` set up the working directory, since 0.1.0. It now refuses an empty
  value with `--path needs a value`; give `--path .` for the working directory. `--volume`,
  `restore`'s `--path` and `--volume`, and `pair --address` now refuse an empty value at
  once in the same way, naming the option. They used to fail later, with a message that
  did not name it.
- Since 0.1.0, `uninstall` left a Docker volume behind, holding only two empty folders,
  once the container had been recreated, as `setup` does after the target's owner
  changes. It now removes that volume, including after `upgrade` has recreated the
  container for a new release. If another container uses it, `uninstall` removes the rest,
  then fails with `kept volume` and the command to remove it once nothing uses it. A volume
  an earlier uninstall left stays.

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

[Unreleased]: https://github.com/Jartan-LLC/claude-sync/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Jartan-LLC/claude-sync/releases/tag/v0.2.0
[0.1.1]: https://github.com/Jartan-LLC/claude-sync/releases/tag/v0.1.1
[0.1.0]: https://github.com/Jartan-LLC/claude-sync/releases/tag/v0.1.0
