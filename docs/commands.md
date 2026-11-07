# Commands

Every command and flag, what `setup` checks, and what to do about errors whose message
leaves the fix out. `claude-sync help` prints the same commands and flags.

## Commands and flags

| Command | Does |
|---|---|
| `setup --volume NAME` | Syncs the Docker volume NAME that holds `~/.claude` |
| `setup --path DIR` | Syncs the directory DIR on this host |
| `setup` | Applies this version to the instance already set up, keeping its target |
| `upgrade` | Installs the newest release that is not breaking and applies it to every running instance on this host |
| `pair DEVICE-ID` | Syncs with the device DEVICE-ID; run on both devices |
| `unpair DEVICE-ID` | Removes the device DEVICE-ID from every device; run it on any device |
| `uninstall` | Removes claude-sync's container and Syncthing state, or its folder from your own Syncthing |
| `list` | Lists this host's instances and marks the one commands act on |
| `use NAME` | Makes later commands act on instance NAME |
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

`CLAUDE_SYNC_NAME`, or when it is unset the instance selected with `use`, names the
instance a command acts on (see [Several instances on one host](#several-instances-on-one-host)).

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

With no `--volume` or `--path`, `setup` applies this version to the instance already set
up, with the target it syncs, as after an upgrade with `dnf`. Ports and `--private` stay as
they are unless given again. With your own Syncthing, it applies to claude-sync's folder
there. With no instance set up, it prints the usage, or, when Docker is installed but
cannot be reached, says so.

Each instance records the version of claude-sync that last set it up. When that version
is older than the one installed, `pair` and `unpair` say so, with the `setup` command to
run. They also do when the instance has no record, as one set up by 0.1.1 or earlier, or
records `dev`, as one set up from a checkout. They do not when one pre-release of a
version, such as 0.5.0-rc.1, set up the instance and another, such as 0.5.0-rc.2, is
installed: after installing it, run `setup` yourself.

## upgrade

```bash
claude-sync upgrade
```

Installs the newest release that is not breaking, then runs `setup`, with no target, for
each running instance on this host whose recorded version is older, missing or `dev`,
claude-sync's folder in your own Syncthing included. Run again, it catches up only the
instances an earlier run missed.

- It does not install a breaking release: it says the release is out and links its notes,
  which say how to upgrade by hand. A breaking release has a new major version, or a new
  minor version while the major is 0. Pre-releases are left out.
- Stopped instances, and instances with only their Syncthing state left, are listed and
  left as they are.
- It checks the download against the release's `claude-sync.sha256`. To check its
  attestation too, run `gh attestation verify` afterwards, as in
  [Install](../README.md#install).
- An RPM install is upgraded with `dnf` (see [Upgrade](../README.md#upgrade)).

## Several instances on one host

`CLAUDE_SYNC_NAME` names an instance: its container and the volume that holds its
Syncthing state. Under different names, one host can sync several `~/.claude` volumes or
directories, each as a device of its own:

```bash
CLAUDE_SYNC_NAME=claude-work claude-sync setup --volume work-claude
claude-sync use claude-work
claude-sync pair OTHER-ID
```

`claude-sync list` lists this host's instances. `claude-sync use NAME` makes later
commands act on instance NAME, in every shell of this user, until `claude-sync use
claude-sync` returns to the default or `uninstall` removes that instance. It keeps the
name in `~/.config/claude-sync/instance`, or under `$XDG_CONFIG_HOME` when that is set.
`CLAUDE_SYNC_NAME`, when set, wins over the selection, so a script that sets it acts on
the instance it names. In `list`, `state only` marks an instance whose container is gone
but whose Syncthing state, with its device ID, is left: `setup` with `--volume` or
`--path` under its name uses that state again, and `uninstall` removes it.

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
| `this instance was last set up by` | Run the `setup` command the message gives, to apply the installed version |
| `runs from a checkout` | Update the checkout with git, then run `setup` to apply it |
| `belongs to the RPM package` | Upgrade with `dnf` as in [Upgrade](../README.md#upgrade) |
| `cannot get the list of claude-sync's releases` | Check that this host reaches `api.github.com`; GitHub also [limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) how many such requests one address can make without a login |
| `cannot write to` ... `where claude-sync is` | Run `upgrade` as the user who owns that directory |
| `does not match the release's SHA-256` or `is not version` | Nothing was changed; run `upgrade` again later, and report it if it keeps failing |
| `setup failed for instance` | Fix what that instance's `setup` printed above, then rerun `upgrade` |
| `docker cannot be reached` | Start Docker, and check that `docker ps` works as this user; then rerun `setup` |
| `docker cannot list the instances in containers` | Start Docker, and check that `docker ps` works as this user; then rerun the command |
| `no instance named` | For a new instance, run `setup` with `CLAUDE_SYNC_NAME` set to its name first, then `use` |
