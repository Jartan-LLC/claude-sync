# Commands

Every command and flag, what `setup` checks, and what to do about errors whose message
leaves the fix out. `claude-sync help` prints the same commands and flags.

## Commands and flags

| Command | Does |
|---|---|
| `setup --volume NAME` | Syncs the Docker volume NAME that holds `~/.claude` |
| `setup --path DIR` | Syncs the directory DIR on this host |
| `pair DEVICE-ID` | Syncs with the device DEVICE-ID; run on both devices |
| `unpair DEVICE-ID` | Removes the device DEVICE-ID from every device; run it on any device |
| `uninstall` | Removes claude-sync's container and Syncthing state, or its folder from your own Syncthing |
| `backup DIR` | Writes an archive of the whole synced folder to DIR, then removes older ones there |
| `restore ARCHIVE --volume NAME` | Extracts a backup over the Docker volume NAME |
| `restore ARCHIVE --path DIR` | Extracts a backup over the directory DIR on this machine |
| `version` | Prints claude-sync's version |
| `help` | Prints the commands and flags |

| Flag | With | Does |
|---|---|---|
| `--use-host-syncthing` | `setup --path` | Uses the Syncthing already running as you on this host ([Using your own Syncthing](own-syncthing.md)) |
| `--private` | `setup`, not with `--use-host-syncthing` | Turns off global discovery, relays and NAT traversal ([Private networks](pairing.md#private-networks)) |
| `--public` | `setup`, not with `--use-host-syncthing` | Returns a private device to Syncthing's defaults |
| `--gui-port PORT` | `setup`, not with `--use-host-syncthing` | Fixes the web UI port, from 1024 to 65535 |
| `--sync-port PORT` | `setup`, not with `--use-host-syncthing` | Fixes the sync port, from 1024 to 65535 |
| `--keep` | `pair` | Keeps this device's files instead of joining ([Joining](pairing.md#joining)) |
| `--address tcp://HOST:PORT` | `pair` | Where to reach the other device; required when global discovery is off here (a `--private` device, or your own Syncthing with it off) |
| `--keep-weekly N` | `backup` | Keeps the newest archive of each of the last N weeks that have one; default 4 |
| `--keep-monthly N` | `backup` | Keeps the newest archive of each of the last N months that have one; default 6 |

`CLAUDE_SYNC_NAME` names the instance a command acts on (see [Several instances on one
host](#several-instances-on-one-host)).

## setup

`setup` refuses a root-owned target: `chown` it to the user who runs Claude Code. It is
safe to re-run, rewrites `.stignore` each time from the ignore list built into claude-sync
and has Syncthing apply it at once, and prints this device's ID. It fails, with
Syncthing's message, if Syncthing cannot sync the folder, and fails too if Syncthing's API
never answers. It does not wait for Syncthing's first scan, which takes minutes on a large
`~/.claude`: while the scan goes on, it says so and gives the web UI's address to follow it.

In its own container, `setup` also prints the web UI port and the sync port: Syncthing's
usual 8384 and 22000, or free ports Syncthing picks on the first run when another program,
such as another Syncthing, holds those. `--gui-port` and `--sync-port` choose them
instead, and later runs keep them. Swapping the two ports with each other leaves the sync
port down for about a minute, until Syncthing retries it. If another program later takes
the web UI port, Syncthing cannot start its web UI and `setup` cannot move it: free that
port again.

## Several instances on one host

`CLAUDE_SYNC_NAME` names an instance: its container and the volume that holds its
Syncthing state. Under different names, one host can sync several `~/.claude` volumes or
directories, each as a device of its own. Give the same name to every command for that
instance:

```bash
CLAUDE_SYNC_NAME=claude-work claude-sync setup --volume work-claude
CLAUDE_SYNC_NAME=claude-work claude-sync pair OTHER-ID
```

Each instance gets ports of its own, which `setup` prints, as long as the other instances
are running when it first starts: Syncthing takes free ports only then. Each needs a
target of its own too: `setup` refuses a volume or directory that another Syncthing
container mounts, running or stopped. A name other than the default, `claude-sync`, can't
be combined with `--use-host-syncthing`, since your own Syncthing holds one claude-sync
folder; neither can `--gui-port` or `--sync-port`, since you set that Syncthing's ports in
Syncthing itself.

## uninstall

```bash
claude-sync uninstall
```

Removes the container and this device's Syncthing state, including its device ID. Your
`~/.claude` is untouched; Syncthing's `.stignore`, `.stfolder` and `.stversions`, and
claude-sync's `.claude-sync-unpaired`, stay in it and can be deleted, though deleting
`.stversions` empties the trash can.

With your own Syncthing, see [Using your own Syncthing](own-syncthing.md#uninstall).

## backup

```bash
claude-sync backup ~/claude-backups
```

Writes `claude-sync-YYYYMMDDTHHMMSSZ.tar.gz`, named after the instance's `CLAUDE_SYNC_NAME`
and the time in UTC, to the directory, which it creates if needed. The archive is a gzip
tar of the whole synced folder: it also holds the files that do not sync, this device's
login in `.credentials.json` among them, and Syncthing's trash can, `.stversions`. It is an
ordinary file with your default permissions, which you can copy to any device and restore
there. Syncthing and Claude Code keep running meanwhile, so a file written while `backup`
reads it may go in partly written, and a file removed meanwhile is left out; if `tar`
reports an error, rerun `backup`. With your own Syncthing, `backup` uses this host's `tar`.
It expects GNU or BusyBox `tar`; with another, a backup taken while files come and go fails.

`backup` refuses a directory in the synced folder: there, the archives would sync to every
device, and each would hold the ones before it. With claude-sync's container, it checks
by making a hidden empty file in the directory, or in its nearest existing parent, and
looking for it from inside the container, then removes the file.

Then `backup` removes this instance's older archives in the directory, keeping the newest
archive of each of the last `--keep-weekly` weeks that have one, and of each of the last
`--keep-monthly` months that have one (defaults in [Commands and
flags](#commands-and-flags)); 0 turns a rule off, and the archive just written always
stays. Weeks run from Monday to Sunday, in UTC. `backup` reads each archive's time from its
name, so an archive written while this device's clock ran ahead counts as the newest week
and month, in a place the rules would give another archive, until that time comes. It also
removes the hidden temporary file that a backup stopped partway, by a kill or a power cut,
left there over a day before, and leaves other files alone. Give each device a directory of
its own: two devices backing up one instance name into one directory remove each other's
archives.

## restore

```bash
claude-sync restore ~/claude-backups/claude-sync-20261107T120000Z.tar.gz --volume claude-data
claude-sync restore ~/claude-backups/claude-sync-20261107T120000Z.tar.gz --path ~/.claude
```

Restores an archive from any device, on any device, whether or not claude-sync is set up
there. `restore` reads the whole archive first, so it writes nothing from one it cannot
read. It then extracts every file in the archive over the target, the files that do not
sync included, and removes nothing: files made since the backup stay. A volume must exist
and not be owned by root, as for `setup`; its owner gets the restored files. `--path` names
a directory on this machine, created if needed, and restores it with this machine's `tar`,
as you; it needs no Docker.

In a folder that syncs, the restored files reach every device. [Recovering
files](recovering-files.md#from-a-backup) says what to do after a restore there, and how to
restore with `tar` alone.

## Errors

| The message says | What to do |
|---|---|
| `Docker is required` | Install Docker Engine 25 or newer with its Compose plugin, or [use your own Syncthing](own-syncthing.md) with `--path` |
| `no Docker volume named` | Check the name with `docker volume ls` |
| `cannot read DIR` | The directory must exist on the host running Docker; run claude-sync on that host, not inside a container |
| `DIR is owned by root` | `chown` it to the user who runs Claude Code |
| `already set up for` | This instance syncs another target; run `uninstall` first, or, with claude-sync's own container, use another `CLAUDE_SYNC_NAME` |
| `port N is in use` | Give another `--gui-port` or `--sync-port` |
| `the web UI and sync ports would both be` | Give `--gui-port` and `--sync-port` different ports |
| `Syncthing cannot sync the folder:` | Syncthing's own reason follows; fix it, then rerun the command that failed (`pair` finishes a join) |
| `Syncthing is not running in container` | Rerun `setup` |
| `claude-sync is not set up on this device` | Run `setup` first |
| `not a device ID` | Copy the ID as the other device's `setup` printed it |
| `cannot add device` | Syncthing's reason follows; if it is about the ID, copy it again as the other device's `setup` printed it |
| `this device is private` | Give the other device's `--address` |
| `has no files to join` | Nothing was discarded. On the device whose files to start from, rerun `pair` with `--keep`; if that is this device, rerun the command the message prints. If the other device stopped with this message too, rerun `pair` there without `--keep`. See [Joining](pairing.md#joining) |
| `files here keep changing during the join` | Stop Claude Code on this device and rerun `pair` |
| `this device's own changes are still not undone` | Syncthing's web UI, at the address the message gives, shows the files left and why; fix that, then rerun `pair`. Meanwhile this device gets the other devices' changes but sends none of its own |
| `Syncthing cannot use the ignore list` | Syncthing's reason follows; if you edited claude-sync's ignore list, fix the pattern it names |
| `cannot reach Syncthing` | Check that claude-sync's container (`docker ps`) or your own Syncthing is running, then rerun; a join picks up where it stopped |
| `this device is still joining` | Finish the join with `pair`, then rerun `unpair` |
| `cannot reach the Syncthing on this host` | Start your own Syncthing, as the user who runs claude-sync |
| `claude-sync needs Syncthing 2 or newer` | Upgrade your own Syncthing |
| `already syncs` ... `which overlaps` | Choose a directory that none of your own Syncthing's folders syncs, inside or around |
| `already set up in the Syncthing on this host` | Add `--use-host-syncthing`, or run `uninstall` first |
| `already syncs claude-sync's folder; to sync this volume beside it` | Set `CLAUDE_SYNC_NAME` to another name for this instance |
| `container NAME already syncs` | Give this instance another target, or remove container NAME, which `docker ps -a` lists even when stopped; for a claude-sync instance, `CLAUDE_SYNC_NAME=NAME claude-sync uninstall` removes it |
| `paths containing a comma` or `a newline are not supported` | Choose or rename a directory without one |
| `is on the list of unpaired devices` | Run `pair` for that device on a device that already syncs, then rerun `pair` here |
| `is in the synced folder` | Give `backup` a directory outside the synced folder |
| `could not search the synced folder` | find's message above names the directory. If the folder's owner cannot read it, `chown` it |
| `tar could not archive the synced folder` | tar's message above names the file. If the folder's owner cannot read it, `chown` it; if it was being written at that moment, rerun `backup` |
| `cannot read ARCHIVE as a backup` | The file is not a whole gzip tar archive, such as a copy cut short; copy it again |
| `could not restore all of` | tar's message above says why, such as a full disk. The files restored so far stay; fix it and rerun `restore` |
