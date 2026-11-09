# Contributing

## Setup

```bash
uv venv        # skip in the devcontainer or with an environment already active
make install
```

`make install` installs the pinned gate tools (`ci/requirements.txt`) and wires the
pre-commit hook. The devcontainer has everything; on a bare host it needs Python 3.12+ and
[uv](https://docs.astral.sh/uv/getting-started/installation/).
`make lint` runs the [pre-commit](https://pre-commit.com/) hooks; some need
Docker (actionlint, lychee) and Node (markdownlint), which the devcontainer has.

## Verify before opening a PR

```bash
make check
```

Runs the lint and integration checks CI runs. CI runs more (see [CI](docs/scaffold.md#ci)),
and all of it must pass before merge.

`make test` (`tests/integration.sh`) runs claude-sync against real Syncthing containers and
needs Docker and bash 5.1 or newer. Every container, volume, network and image it keeps is
named `claude-sync-test-*`, or is the anonymous volume such a container mounts at
`/var/syncthing`, and is removed afterwards. It removes nothing else, which matters when the
dev container shares the host's Docker daemon. It never reaches a Syncthing of your
own. `CLAUDE_SYNC_TEST_PREFIX=claude-sync-test-NAME-` keeps a run's objects apart from
another run's on the same daemon, and `CLAUDE_SYNC_TEST_FAIL_FAST=1` stops at the first
failing check.

## Building

`./claude-sync` runs from the checkout and reports its version as `dev`. `make build`
writes `dist/claude-sync`, the single file a release ships: the script with its version,
its own files (`compose*.yaml`, `stignore`) and `lib/*.sh` built in. To test that file:

```bash
make build VERSION=0.0.0-test
CLAUDE_SYNC_BIN=$PWD/dist/claude-sync CLAUDE_SYNC_BIN_VERSION=0.0.0-test make test
```

`claude-sync` holds the command line; the rest of the program lives in `lib/*.sh`. The
checkout's `claude-sync` loads each of them with a `source` line in its SOURCES block, from
the directory it sits in, symlinks resolved; `packaging/build.sh` puts the same files, in
the same order, into the built file. The checkout's `claude-sync` exits 1, saying why,
without `lib/` beside it or when it has no file to look beside: run from stdin (`bash -s`),
as a string (`bash -c`) or through `bash <(...)`.

Rules for lib files:

- A new lib file needs its `source "$here/lib/NAME.sh"` line in the SOURCES block.
  `build.sh` refuses a lib file that is not listed, a listed file that is missing, and a
  function defined in two files, where the later definition would silently win.
- Top-level code that reads a global or calls a function defined in another file needs that
  file listed first. `make lint` reports a top-level call to a function defined in a
  later-listed file as SC2218, but not such a call inside a function that top-level code
  runs; a global read before it is set fails at startup under `set -u`.
- Lib files hold only definitions and top-level assignments, `lib/instances.sh`'s name block
  included, and their top-level code ends with status 0.
- Code that needs claude-sync's own path reads `claude_sync_file`, never `BASH_SOURCE`, which
  in a function names the lib file in a checkout.

## Writing tests

`tests/integration.sh` is the runner: it sources one file per group from `tests/groups/`
and the helpers the groups share from `tests/lib/`, then runs the groups in parallel. So:

- A helper one group uses goes in that group's file; one that two or more use goes in
  `tests/lib/`.
- A new group is a file `tests/groups/NAME.sh` that defines `group_NAME`, and the runner
  needs its `source "$root/tests/groups/NAME.sh"` line; a new `tests/lib/` file needs one
  too. A group runs only as `group_NAME`, from its own `NAME.sh`. Before any Docker call,
  the runner refuses a test file it does not source, a group file without its
  `group_NAME`, and a function defined in two files.
- A group file declares the names of the containers and volumes its group makes, and
  registers them beside the names, at the file's top level, with `own_instances`,
  `own_containers` or `own_volumes`: cleanup removes only what is registered, and a call
  inside `group_NAME` would run in the group's subshell, which cleanup does not see. The
  runner refuses a name registered twice, and a name with the suite's prefix that nothing
  registers. The group makes its volumes and fixtures at the start of `group_NAME`.
- A name declared `readonly` at the top level of `tests/integration.sh` or of a file in
  `tests/lib/` or `tests/groups/` is a read-only global in every test file, so a helper's
  locals and loop variables must not reuse it.

## Updating the ignore list

`stignore` keeps out of sync what is meaningless or harmful on another machine, and Claude
Code adds files to `~/.claude` as it changes. A new file goes on the list when it belongs
to one machine: its name holds a process ID or a session, a process holds it as a lock, or
each machine fetches it on its own, as with a git clone. Conflict copies of a file nobody
edits by hand, made while two devices run Claude Code, are a sign of such a file. Claude
Code's [`.claude` directory page](https://code.claude.com/docs/en/claude-directory.md)
describes many of its files.

To add a rule:

1. Put it in `stignore` under a one-line comment giving the reason, as the rules there do.
2. Prefix a rule for files inside a synced directory with `(?d)`. Without it, a directory
   deleted on another device, or a joining device's own, stays behind while it holds such
   a file, and a join never finishes. A top-level entry needs none.
3. Spell hex ranges out, as `[0123456789abcdef]`: Syncthing's glob takes one range per `[]`
   class and rejects the whole file on `[0-9a-f]`.
4. Add a path the rule matches to the `ignored` list in `tests/lib/claude-dir.sh`, and a
   look-alike it must not match to `synced`.
5. Add the rule to the README's [What syncs](README.md#what-syncs) table.

Each release of claude-sync carries its own copy of `stignore`, so a device picks up the
new list when it runs `setup` from a claude-sync that has it (see the README's
[Upgrade](README.md#upgrade) section).

## Releasing

1. Move the `## [Unreleased]` entries in `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD`
   and update the links at its end. A breaking change takes a new major version, or a new
   minor version while the major is 0, never a patch: `claude-sync upgrade` tells a
   breaking release only by its version number, and installs a newer release that is not
   breaking without asking.
2. Once that is merged, tag `main` and push the tag:
   `git fetch origin && git tag vX.Y.Z origin/main && git push origin vX.Y.Z`. A tag with a
   pre-release part, such as `v0.2.0-rc.1`, is published as a pre-release.
3. If the release is breaking (step 1), add to its notes on GitHub how to upgrade to it by
   hand: download claude-sync as in the README's Install section, run
   `CLAUDE_SYNC_NAME=NAME claude-sync setup` for each instance NAME, and do any other step
   the release needs. `claude-sync upgrade` links
   a breaking release's notes instead of installing it, and the generated notes list only
   the merged PRs.

[Publishing](docs/scaffold.md#publishing) covers what the tag sets off.

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`). So do PR titles, which a squash
  merge can use as the commit subject.
- A commit message says why the change was made; the diff already shows what changed.
- A PR description answers the [pull request template](.github/PULL_REQUEST_TEMPLATE.md)'s
  prompts.
- User-facing changes go in `CHANGELOG.md` under `## [Unreleased]`.
- Report security issues privately via [SECURITY.md](.github/SECURITY.md), not a public issue.
