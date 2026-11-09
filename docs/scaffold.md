# Project tooling

For contributors: what CI, publishing and Liza do in this repository, which started from
[scaffold](https://github.com/Jartan-LLC/scaffold), a GitHub template repository, and how to
pull in later scaffold changes.

## Liza

The `liza` Feature activates Liza in each clone when the container is created, and
`liza-toolchain` adds its agent tools. To undo activation in a clone, run `liza-deactivate`;
the next container create activates it again. To opt out of either Feature, follow the
Removal steps on its page ([liza](https://github.com/Jartan-LLC/enchantments/blob/main/src/liza/README.md),
[liza-toolchain](https://github.com/Jartan-LLC/enchantments/blob/main/src/liza-toolchain/README.md)).

The grimoire Feature installs grimoire's plugins at local scope in each clone, skipping any
that `.claude/settings.json` or the clone's `settings.local.json` sets to `false`.
`claude plugins disable <id>@grimoire --scope local` turns one off for one clone, and
[its page](https://github.com/Jartan-LLC/enchantments/blob/main/src/grimoire/README.md)
covers removal.

Each Claude session selects its mode at start; start a new session to switch.

| Mode | For | Start it |
|---|---|---|
| Pairing | everyday work; you approve each step | open Claude in an activated clone |
| Adversarial Pairing | one high-stakes change, reviewed by separate sessions | see below |
| Multi-agent | a goal large enough to decompose and run unattended | see below |

**Adversarial Pairing.** Open one Claude session per role and keep the pairing's
blackboard and worktree in `.adversarial/`, because a multi-agent init deletes `.liza/` and `.worktrees/`:

```text
/adversarial-pairing doer .adversarial/<name>.md
/adversarial-pairing reviewer-1 .adversarial/<name>.md
```

When the doer asks where to create its worktree, answer `.adversarial/worktrees/<name>`.
In that worktree, the doer runs `uv venv` and `make install` before its first `make check`,
so the checks run against the worktree's own code rather than the main checkout's install.

**Multi-agent.** Commit a goal document first, then:

```bash
liza init "<goal>" --spec specs/<goal>.md --post-worktree-cmd "uv venv -q --allow-existing && make install"
liza tui
```

`--post-worktree-cmd` gives each task worktree its own `.venv`, which every `make` target
there uses, and runs `make install` in it. That install skips the git hook: Liza sets the
worktree's `core.hooksPath`, and `pre-commit install` refuses to run with it set. Fill in
`GUARDRAILS.md` before a first run. Liza's
[Getting Started](https://github.com/liza-mas/liza/blob/main/GETTING_STARTED.md) covers
the rest of the run: checkpoints, the operator session, logs.

## CI

`ci.yml`'s `check` job passes when every job in its `needs` list passed or was skipped. A
job joins or leaves that gate through two entries in `check`, `needs` and the `results`
array, so a job you write or uncomment goes in both. A step added to an existing job, such as
a Node check in `lint`, needs no `check` change.

The `rpm` job runs on every change while `packaging/rpm.spec` exists: it builds the RPM,
running the spec's `%check`, and installs it in Fedora.

The dev container job runs only when a change touches one of its build inputs, which
`_DEVCONTAINER_INPUTS` in `ci/changes.py` lists. `ci/requirements.txt` is among them, because
`post-create.sh` reads uv's pin from it; `.claude/settings.json`, which the grimoire Feature
reads when the container builds, is not. Scheduled and manual runs run every job, so a change
that breaks only the dev container build through a file outside that list shows at the
weekly run, not on its PR.

## Publishing

A `v*` tag runs these workflows:

| Workflow | Publishes |
|---|---|
| `release.yml` | a GitHub Release whose notes are the tag's `CHANGELOG.md` section (`## [1.2.0]` for `v1.2.0`) with its hard-wrapped lines joined, or GitHub's generated notes, with a warning in the run, when there is no `CHANGELOG.md` or that section is missing, empty or holds only HTML comments. It builds the single-file claude-sync, runs the integration tests against it, and attaches it with its `claude-sync.sha256`, both with a build provenance attestation that `gh attestation verify` checks. A pre-release tag, written in SemVer as [RELEASING.md](../RELEASING.md) requires (`v1.2.0-rc.1`), makes a pre-release. A full release becomes Latest only when no full release has a higher version. Runs go one at a time, in push order: a tag's run waits until the previous tag's run finishes. The Release is created only once the single file, the RPM and their attestations all succeed. It needs no secret or setup |
| `rpm.yml`, run by `release.yml` | `claude-sync.noarch.rpm` on the GitHub Release, built from the tag by `packaging/rpm.sh` in Fedora and installed there first, with a build provenance attestation. A failed build creates no Release |

## Syncing template updates

claude-sync was created with *Use this template*, so `.scaffold-sync` holds the newest
scaffold commit it has ported or skipped. List the scaffold commits after it:

```bash
git remote add upstream https://github.com/Jartan-LLC/scaffold.git  # once per clone
git fetch upstream
git log --oneline --reverse "$(cat .scaffold-sync)"..upstream/main  # not yet dealt with, oldest first
```

Oldest first, port each commit you want, and skip the others by leaving them out:

```bash
git cherry-pick -n <sha>   # stages the commit's change without committing it
```

- `cherry-pick` merges three ways, across the unrelated history *Use this template* creates.
  Resolve each conflict before the next pick, then adapt the change to this project. Where
  scaffold's side of a conflict holds a `TODO(/onboard)` marker or a placeholder, keep this
  project's side.
- A file this project deleted comes up as a `modify/delete` conflict. `git rm <path>` keeps it
  deleted, and the rest of the commit applies.
- Pick one commit at a time. A range (`A..B`) stops at its first conflict and won't continue
  over the staged result.
- `-n` makes no commit, so scaffold's subjects, and the `(#NNN)` numbers in them, which name
  scaffold's issues, stay out of this project's history.
- Scaffold's `main` is linear, so every commit picks without `-m`.

Then record the newest commit you ported or skipped, and commit `.scaffold-sync` with the
port, so the file always matches what the repository contains:

```bash
git rev-parse <sha> > .scaffold-sync
```

Open a PR, so CI runs before the changes land.
