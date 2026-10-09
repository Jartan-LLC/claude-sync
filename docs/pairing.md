# Pairing devices

How devices find each other, what joining does, and how to remove a device. The
[README](../README.md) has the two-device quickstart.

## The first pairing

Run `setup` on every device first; it prints the device's ID. Pair two devices by running
`pair` on each with the other's ID. The first pairing starts from the files of one device,
so that one gets `--keep`:

```bash
./claude-sync pair OTHER-ID --keep    # on the device whose files to start from
./claude-sync pair FIRST-ID           # on the other device
```

## Adding a device

To add a device later, pair it with any device that already syncs, on both sides. That
device introduces it to all the others, and them to it, so every device syncs with every
other directly. With your own Syncthing, a device it already syncs other folders with is
the exception (see [Using your own Syncthing](own-syncthing.md)).

## Joining

A device that syncs with no other yet joins: it sends nothing until it has the others'
files, then moves its own changes, such as a fresh `settings.json` from Claude Code, to
the trash can and syncs both ways. Without this, those newer files would replace yours on
every device. `pair` waits until the join is done, and is safe to interrupt and re-run.
Stop Claude Code on the new device until it finishes: a change made just as the join ends
can still reach the others.

`--keep` keeps this device's files instead, including on a re-run that finishes an
interrupted join; files the join already moved aside stay in the trash can (see
[Recovering files](recovering-files.md)). Paired with devices that already have files, its
files merge with theirs: for each file the newer copy wins and the other stays as a
conflict copy.

If a device with files of its own would join devices that have none, which happens when
the first pairing is missing `--keep`, `pair` stops and undoes the pairing without
discarding anything.

## When `pair` stops

- It says it is waiting for the other device, and what to run there: run that `pair`
  command on the other device, adding `--keep` if this is the first pairing and that
  device has the files to start from. This one carries on once it accepts.
- It was interrupted, the other device went away, or the message ends "rerun to finish
  the join": run the same command again. A join picks up where it stopped.
- It says "Syncthing cannot sync the folder": Syncthing's reason follows; fix it, then
  rerun `pair`.
- It says the other device "has no files to join": see the refusal above, and rerun with
  `--keep` on the device whose files to start from, as the message says.
- It says "files here keep changing during the join": stop Claude Code on this device and
  rerun.
- It says it "cannot reach Syncthing": check that claude-sync's container (or your own
  Syncthing) is running, then rerun to finish the join.

## Removing a device

```bash
./claude-sync unpair OLD-ID    # on any device that syncs
```

`unpair` removes the device from every device, whichever one you run it on. It puts an
empty file named after the ID in `.claude-sync-unpaired`, a directory in the synced
folder. Each device removes the devices listed there, and removes them again if an
introduction brings one back. Once all of them refuse it, the removed device stops
syncing; run `uninstall` on it to clear its state.

To pair the device again later, use `pair` as usual, which takes it off the list.
`unpair` refuses to run on a device that is still joining; finish the join first.

Two kinds of device apply the list late:

- one set up with an earlier claude-sync, once `setup` has run there again;
- one using its own Syncthing, whenever claude-sync runs there (see [Using your own
  Syncthing](own-syncthing.md)).

## Private networks

By default devices find each other anywhere, through Syncthing's global discovery and
relays, with traffic encrypted end to end. `setup --private` turns off global discovery,
relays and NAT traversal, so each device needs the other's address when pairing:

```bash
./claude-sync pair OTHER-ID --address tcp://other-host:22000
```

Use the sync port the other device's `setup` printed, 22000 unless it said otherwise; for a
device using its own Syncthing, the port that Syncthing listens on.

To correct an address, pair again with the new `--address`. A device stays private when
`setup` is re-run; `setup --public` returns it to the defaults.
