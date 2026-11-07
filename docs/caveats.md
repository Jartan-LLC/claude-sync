# Caveats

The limits of sharing one `~/.claude` between devices, and what to do about each. The
[README](../README.md) lists what syncs; [Recovering files](recovering-files.md) covers
getting a file back.

What this page says Claude Code does was checked on Claude Code 2.1.319, on Linux; later
versions may behave differently.

## Claude Code on two devices at once

Most files in `~/.claude` change on one device at a time. `.claude.json` does not: it holds
Claude Code's account details, MCP servers added with `--scope user`, the state of each
project, such as whether you trusted it, and Claude Code's own bookkeeping, which every
running Claude Code rewrites often.

### Where `.claude.json` lives

- By default it is `~/.claude.json`, beside `~/.claude` rather than in it, so claude-sync
  does not sync it. MCP servers added with `--scope user` and the projects you trusted stay
  on the device where you set them up.
- With `CLAUDE_CONFIG_DIR` set, it is `.claude.json` in that directory. When that directory
  is the synced folder, the file syncs.
- When `~/.claude.json` is a symlink into the synced folder, the file it points to syncs.
  A symlink the other way, from the synced folder to `~/.claude.json`, syncs as a symlink
  only.

Either way, Claude Code copies the file to `backups/` in `~/.claude` (or in
`CLAUDE_CONFIG_DIR`) when it rewrites it, and that directory syncs: each device holds the
other devices' copies too.

### What happens when it syncs

With Claude Code running on two devices, both rewrite `.claude.json` between syncs, so
Syncthing keeps the newer version and saves the other as a conflict copy, for nearly every
write. Claude Code reads the file again just before each write
and adds its own change to what it reads, so a change that has already arrived from
another device survives, unless the same setting changed on both. A change that arrives
between that read and the write is lost, with no conflict copy.

A conflict copy of the file is named `.claude.sync-conflict-DATE-TIME-DEVICE.json` (or
`claude.sync-conflict-…` for a file named `claude.json`). Most hold only usage counters,
cached feature flags and the last session's statistics for a project. Some hold a real
change made on the device whose write lost, such as an MCP server you added or a project
you trusted. Syncthing keeps only the newest conflict copies of a file (see [Conflict
copies](#conflict-copies)), so such a change is gone a few writes later.

To settle the copies, compare each with the file. Claude Code writes it indented, so
`diff` shows the settings that differ; in the synced folder:

```bash
for copy in .claude.sync-conflict-*.json; do diff .claude.json "$copy"; done
```

For a file named `claude.json`, drop the leading dots.

Redo in Claude Code any change other than counters, caches and statistics, such as
`claude mcp add --scope user` for a missing MCP server, then delete the copies.

To avoid the copies, run Claude Code on one device at a time, or keep `.claude.json` out of
the synced folder, as it is by default.

## Plugins

`plugins/installed_plugins.json` and `plugins/known_marketplaces.json` hold paths under the
home directory of the device that wrote them. Claude Code loads plugins from this device's
own `~/.claude/plugins` whatever path the records give, so a device whose home differs,
such as `/home/vscode` in a dev container against your user's home on the host, still
loads them.

Marketplaces do not sync: each device clones its own into `plugins/marketplaces/`. On a
device without the clone, such as a new one, `claude plugin list` shows the marketplace's
plugins as failed to load, with `Marketplace NAME failed to load: cache-miss`. Clone it:

```bash
claude plugin marketplace update NAME
```

That command also writes this device's path into `known_marketplaces.json`, which syncs.
On a device whose home differs, Claude Code then fails to refresh the marketplace when it
installs a plugin: it says the marketplace `has a corrupted installLocation` and installs
from the catalog it already has, which may be out of date. Before installing or updating a
plugin there, run `claude plugin marketplace update NAME`. It writes that device's path
back, and the other devices then see the same until they run it. Devices with the same home path do not see this.

`plugins/cache/` syncs, so every device has the plugin versions any of them installed.

## One login per device

`.credentials.json` never syncs, so log in to Claude Code on each device.

## Conflict copies

[Recovering files](recovering-files.md) says when Syncthing makes a conflict copy. To settle
one, compare it with the file, copy into the file whatever you want to keep, and delete
the copy. A conflict copy syncs like any other file, so deleting it on one device deletes
it on all of them. Syncthing keeps ten per file and deletes the oldest.

## Syncthing's and claude-sync's files

These live in the synced folder, beside Claude Code's files:

| Path | What it is |
|---|---|
| `.stignore` | The ignore list. Every `setup` rewrites it from the list built into claude-sync, so edits to it do not last |
| `.stfolder` | Syncthing's marker that the folder is in place |
| `.stversions/` | The trash can ([Recovering files](recovering-files.md)) |
| `.claude-sync-unpaired/` | The devices removed with `unpair`, one empty file each ([Removing a device](pairing.md#removing-a-device)) |

Syncthing never syncs the first three; each device has its own.

## What a first join does

A device that joins with a `~/.claude` of its own keeps only the other devices' files. Its
own files, such as plugin versions the others lack, go to its trash can for 14 days (see
[Joining](pairing.md#joining)). Its `.credentials.json` and other files claude-sync does
not sync stay, except those inside a directory the join discards, which go with it.

The first `setup` on a large `~/.claude` returns while Syncthing's first scan carries on,
for minutes (see [setup](commands.md#setup)).
