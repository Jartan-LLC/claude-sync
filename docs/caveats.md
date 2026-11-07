# Caveats

The limits of sharing one `~/.claude` between devices, and what to do about each. The
[README](../README.md) lists what syncs; [Recovering files](recovering-files.md) covers
getting a file back.

What this page says Claude Code does was observed on Claude Code 2.1.319, on Linux, except
where it says it was read from Claude Code's code. Later versions may behave differently.

## Claude Code on two devices at once

Most files in `~/.claude` change on one device at a time. `.claude.json` does not: it holds
Claude Code's account details, MCP servers added with `--scope user`, the state of each
project, such as whether you trusted it, and Claude Code's own bookkeeping, which every
running Claude Code rewrites often.

### Where `.claude.json` lives

To see which of these applies, run `echo "$CLAUDE_CONFIG_DIR"` and `ls -l ~/.claude.json`.

- By default it is `~/.claude.json`, beside `~/.claude` rather than in it, so claude-sync
  does not sync it. MCP servers added with `--scope user` and the projects you trusted stay
  on the device where you set them up.
- When `~/.claude.json` is a symlink into the synced folder, the file it points to syncs.
  A symlink the other way, from the synced folder to `~/.claude.json`, syncs as a symlink
  only.
- With `CLAUDE_CONFIG_DIR` set, it is `.claude.json` in that directory. When that directory
  is the synced folder, the file syncs.

Even when `.claude.json` does not sync, copies of it do. Each time Claude Code rewrites the
file, it saves a copy in `backups/` in `~/.claude` (or in `CLAUDE_CONFIG_DIR`) and keeps the
five newest, as its [`.claude` directory page](https://code.claude.com/docs/en/claude-directory.md)
says. These are Claude Code's own backups, and that directory syncs, so each device holds
the other devices' copies too.

### What happens when it syncs

With Claude Code running on two devices, both rewrite `.claude.json` between syncs, so
Syncthing keeps the newer version and saves the other as a conflict copy, for nearly every
write. Going by its code (this was not watched in a running session), Claude Code reads
the file again just before each write and adds its own change to what it reads. So a
change that has already arrived from another device survives, unless the same setting
changed on both, and a change that arrives between that read and the write is lost, with
no conflict copy.

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

Marketplaces do not sync: each device clones its own into `plugins/marketplaces/`. On a
device without the clone, such as a new one, `claude plugin list` shows the marketplace's
plugins as failed to load, with `Marketplace NAME failed to load: cache-miss`. Clone it:

```bash
claude plugin marketplace update NAME
```

`plugins/installed_plugins.json` and `plugins/known_marketplaces.json` hold paths under the
home directory of the device that wrote them. Once the marketplace is cloned, a device
whose home differs, such as `/home/vscode` in a dev container against your user's home on
the host, still loads the plugins: Claude Code loads them from its own `~/.claude/plugins`
whatever path the records give.

`known_marketplaces.json` gives the full path of each marketplace's clone, and it syncs.
When Claude Code refreshes a marketplace, as it does when you install or update a plugin,
and the path another device recorded does not exist on this one, it updates the clone in
its own `plugins/marketplaces/`, cloning it there if it is missing, and records its own
path, with no message. The record then syncs to the other devices, which handle it the
same way. Devices with the same home path record the same path, so nothing changes between
them.

When a clone exists at the other device's path on this one, Claude Code leaves the record
alone. Installing or updating a plugin then warns that the marketplace `has a corrupted
installLocation` and uses the catalog it already has, which may be out of date, and
`claude plugin marketplace update NAME` fails with the same message. Do not follow the
message's advice to remove the marketplace and add it back: removing it also uninstalls
its plugins, and the changed `installed_plugins.json` and `settings.json` sync to the other
devices. Instead, set the marketplace's `installLocation` in `known_marketplaces.json` to
the directory the failed `claude plugin marketplace update NAME` says it expected, followed
by `/NAME`, and run that command again.

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

Syncthing never syncs `.stignore`, `.stfolder` or `.stversions/`; each device has its own.

## What a first join does

A device that joins with a `~/.claude` of its own keeps only the other devices' files,
unless it pairs with `--keep` (see [Joining](pairing.md#joining)). Its own files, such as
plugin versions the others lack, go to its trash can (see
[Recovering files](recovering-files.md)). Its `.credentials.json` and other files
claude-sync does not sync stay, except those inside a directory the join discards, which go
with it.

The first `setup` on a large `~/.claude` returns while Syncthing's first scan carries on,
for minutes (see [setup](commands.md#setup)).
