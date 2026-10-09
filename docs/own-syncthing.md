# Using your own Syncthing

If Syncthing 2 or newer already runs on the host as you, the user who runs Claude Code
and claude-sync, `--use-host-syncthing` adds claude-sync's folder to it instead of
starting a container:

```bash
./claude-sync setup --path ~/.claude --use-host-syncthing
```

This needs curl but not Docker, and works only with `--path`. claude-sync changes nothing
in that Syncthing beyond its own folder, the devices you pair and the devices `unpair`
removes. `pair`, `unpair` and `uninstall` find it on their own. `setup` refuses a
directory one of that Syncthing's folders syncs, or one inside or around it, following
symlinks, since its files would sync twice. `--private` and `--public` are refused, since
they would change how your other folders connect; set those options in Syncthing itself.
If global discovery is off there, `pair` needs `--address`, as on a [private
network](pairing.md#private-networks).

When you pair, a device that already syncs other folders with your Syncthing
is not made an introducer, since the devices it introduces would join those folders too.
`pair` then says so, and this device needs pairing with each of the others directly.

Once your Syncthing syncs claude-sync's folder, `setup` without `--use-host-syncthing`
refuses to start a container beside it, since `pair`, `unpair` and `uninstall` would then
act on the container instead.

A device that `unpair` removed elsewhere stays in your Syncthing until claude-sync's
`setup`, `pair`, `unpair` or `uninstall` next runs here: with no container, nothing beside
your Syncthing applies the list of removed devices in between. Until then your Syncthing
may also introduce the device to the others again, which drop it within seconds. A
removed device that also syncs other folders with your Syncthing then leaves only
claude-sync's folder.

## Uninstall

If you set up with `--use-host-syncthing`, `uninstall` removes only claude-sync's folder
from your Syncthing, and the devices you paired stay, apart from those `unpair` removed
that share no other folder with it.
Syncthing deletes the folder's `.stfolder` itself.
