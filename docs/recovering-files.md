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
