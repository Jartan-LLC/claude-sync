# Recovering files

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
`claude-sync status` counts them. Keep the copy you want under the file's own name and
delete the other; the deletion reaches every device.

## From a backup

An archive from [`backup`](commands.md#backup) holds the whole folder as it was. Restore it
with claude-sync, into a Docker volume or a directory:

```bash
claude-sync restore ~/claude-backups/claude-sync-20261107T120000Z.tar.gz --volume claude-data
claude-sync restore ~/claude-backups/claude-sync-20261107T120000Z.tar.gz --path ~/.claude
```

`restore` removes nothing ([details](commands.md#restore)). In a folder that syncs, the
restored files reach every device, so a restore undoes a mistake that has already synced
everywhere. Every other device moves the copies it replaces to its trash can; this device
keeps none, so take a file the restore overwrote from another device's trash can. The files
that do not sync, those that [What syncs](../README.md#what-syncs) lists as not syncing,
`.stignore` and the trash can, come back on this device only. After the restore:

- rerun `setup` as you first ran it, so `.stignore` is this version's ignore list again;
- if the archive came from another device, its `.credentials.json` is that device's login,
  now in place of this one's; log in to Claude Code again to give this device its own;
- the archive's list of unpaired devices syncs to every device, and each device unpairs the
  devices on it; if you paired one of them again since the backup, run `pair` for it again
  on a device that syncs.

To start a new set of devices from an archive, restore it on the first device before
pairing, then pair that device with `--keep` (see [The first
pairing](pairing.md#the-first-pairing)).

Without claude-sync, `tar` restores it too. List what an archive holds, restore all of it,
or restore one file:

```bash
tar -tzf claude-sync-20261107T120000Z.tar.gz
tar -xzf claude-sync-20261107T120000Z.tar.gz -C ~/.claude
tar -xzf claude-sync-20261107T120000Z.tar.gz -C ~/.claude ./settings.json
```

For a Docker volume, run `tar` in a container that mounts it, as the volume's owner:

```bash
docker volume inspect claude-data >/dev/null &&
    docker run --rm -i --user 1000:1000 -v claude-data:/claude busybox \
        tar -xzf - -C /claude <claude-sync-20261107T120000Z.tar.gz
```
