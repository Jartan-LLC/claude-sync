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

`CLAUDE_SYNC_NAME` names the instance a command acts on (see [Several instances on one
host](#several-instances-on-one-host)).

## setup

`setup` refuses a root-owned target: `chown` it to the user who runs Claude Code. It is
safe to re-run, rewrites `.stignore` each time from the ignore list built into
claude-sync, and prints this device's ID. It fails, with Syncthing's message, if Syncthing cannot
sync the folder, and fails too if Syncthing's API never answers.

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
