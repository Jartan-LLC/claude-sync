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

## From a backup

An archive from [`backup`](commands.md#backup) holds the whole folder as it was. Restore it
with claude-sync, into a Docker volume or a directory:

```bash
claude-sync restore ~/claude-backups/claude-sync-20261107T120000Z.tar.gz --volume claude-data
claude-sync restore ~/claude-backups/claude-sync-20261107T120000Z.tar.gz --path ~/.claude
```

`restore` puts back every file in the archive and removes none (see
[Commands](commands.md#restore)).

In a folder that syncs, the restored files reach every device, and each device moves the
copies they replace to its trash can, so a restore undoes a mistake that has already synced
everywhere. The files that do not sync come back on this device only: its login in
`.credentials.json`, `.stignore`, and the list of unpaired devices. After the restore:

- rerun `setup` as you first ran it, so `.stignore` is this version's ignore list again;
- if a device was unpaired when the backup was made and you paired it again since, run
  `pair` for it again on a device that syncs.

To start a new set of devices from an archive, restore it on the first device before
pairing, then pair that device with `--keep` (see [The first pairing](pairing.md#the-first-pairing)).

Without claude-sync, `tar` restores it too. List what an archive holds, restore all of it,
or restore one file:

```bash
tar -tzf claude-sync-20261107T120000Z.tar.gz
tar -xzf claude-sync-20261107T120000Z.tar.gz -C ~/.claude
tar -xzf claude-sync-20261107T120000Z.tar.gz -C ~/.claude ./settings.json
```

For a Docker volume, run `tar` in a container that mounts it, as the volume's owner:

```bash
docker run --rm -i --user 1000:1000 -v claude-data:/claude busybox \
    tar -xzf - -C /claude <claude-sync-20261107T120000Z.tar.gz
```
