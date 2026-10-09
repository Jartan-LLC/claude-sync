# About this template

How the template's parts work and how to keep them current. This page stays useful after
setup.

## What's included

| Area | Contents |
|------|----------|
| `.devcontainer/` | Reproducible dev environment — Python 3.12, Node.js LTS, Docker, GitHub CLI, and the [enchantments](https://github.com/Jartan-LLC/enchantments) Features: Claude Code, the GitHub CLI login, grimoire's plugins, Liza and its agent toolchain. The grimoire Feature installs its plugins at local scope in each clone, skipping any that the repo's `.claude/settings.json` or the clone's `settings.local.json` sets to `false`; `claude plugins disable <id>@grimoire --scope local` sets it for one clone. To drop a Feature, follow the Removal section on its page, where it has one ([the Features list](https://github.com/Jartan-LLC/enchantments#features) links each page), then remove its entry and its `devcontainer-lock.json` key. `post-create.sh` runs `make install`, which installs the gate tools into the system Python, as CI does: `containerEnv` sets `UV_SYSTEM_PYTHON`, so the container has no project `.venv` |
| `.claude/` | Claude Code configuration — enabled plugins (skills & agents from the grimoire marketplace) |
| `.github/` | CI pipeline (lint incl. workflow security lint via actionlint/zizmor, integration tests against the source and the built file, an RPM build in Fedora, dev container build + verify; Node steps commented), Dependabot auto-patching, release (the single file and the RPM, attested) + OpenSSF Scorecard workflows, a weekly external-link-check workflow that tracks findings in one issue and closes it on a clean run, issue/PR + code-of-conduct + security templates |
| `ci/requirements.txt`, `.python-version`, `.codespellrc` | `ci/requirements.txt` exact-pins the tools that run the gate, and the one uv version CI, the devcontainer and `make` all use. `.python-version` sets the Python of `ci.yml`'s lint job; `uv venv` reads it too. `.codespellrc` configures codespell |
| `Makefile`, `.pre-commit-config.yaml` | Task runner (`make install`/`lint`/`test`/`build`/`check`, backed by [uv](https://docs.astral.sh/uv/), installing into the checkout's `.venv`, else the active environment, else the devcontainer's system Python) + the single lint source (codespell, shellcheck, markdownlint, lychee, actionlint, zizmor, hygiene) that `make lint` and CI both run, and the source of the linters' versions (the link-check workflow pins lychee separately) |
| `AGENTS.md` | Symlink to `CLAUDE.md` for vendor-neutral agent tools (Cursor, Copilot, …); tools that don't follow `@` imports won't load `GUARDRAILS.md` |
| `CHANGELOG.md`, `CONTRIBUTING.md` | Keep-a-Changelog skeleton and a contributor guide |
| `.env.example`, `.prettierrc` | Env-var template and Prettier config (for JS/TS work) |
| `.editorconfig` | Language-aware formatting — 4-space Python, 2-space JS/TS, tabs for Makefiles |
| `.gitattributes` | Syntax-aware diffs, LF checkout on every platform |
| `.gitignore` | Comprehensive patterns for Node, Python, Docker, IDEs, env files, build artifacts |
| `CLAUDE.md` | Imports the project rules; corrections, verification commands, skill index |
| `GUARDRAILS.md` | Project rules ranked by how firmly each holds (never / ask first / default / preference) — the tiers Liza agents enforce |

## Syncing template updates

You can still pull in later improvements to the template. How depends on how your repository started.

```bash
# One-time, either way: add the template as an 'upstream' remote
git remote add upstream https://github.com/Jartan-LLC/scaffold.git  # this template's repo
git fetch upstream
```

**If you used *Use this template*** — the button on the template's GitHub page — GitHub started your history
fresh, so there is nothing to merge: `git merge upstream/main` stops at `fatal: refusing to merge
unrelated histories`. Port changes by hand instead, and keep the newest upstream commit you have
dealt with — ported or deliberately skipped — in `.scaffold-sync` at your repository root:

```bash
# First time only: the template commit your repository was created from
git rev-list -1 --before="$(git log --reverse --format=%cI | head -1)" upstream/main > .scaffold-sync

git log --oneline --reverse "$(cat .scaffold-sync)"..upstream/main  # not yet dealt with, oldest first
git show <sha>                          # the change to port; apply the equivalent by hand
echo <sha> > .scaffold-sync             # once everything up to <sha> is ported or skipped
```

Commit `.scaffold-sync` with the port, so the file always matches what the repository contains.

**If you forked this repository**, the history is shared and the merge works:

```bash
git checkout -b template-update
git merge upstream/main   # resolve conflicts, keeping your customizations
```

Open a PR either way, so CI runs before the changes land.

## Liza

The `liza` Feature activates Liza in each clone when the container is created, and
`liza-toolchain` adds its agent tools. To undo activation in a clone, run `liza-deactivate`;
the next container create activates it again. To opt out of either Feature, follow the
Removal steps on its page ([liza](https://github.com/Jartan-LLC/enchantments/blob/main/src/liza/README.md),
[liza-toolchain](https://github.com/Jartan-LLC/enchantments/blob/main/src/liza-toolchain/README.md)).

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

`ci.yml`'s `lint`, `integration` and `rpm` jobs and the dev container build gate the
`check` aggregator. Adding or removing a gating job also means updating its `check.needs`
and results entries. The Node checks are commented steps inside `lint`: uncomment them
there, with no `check` change needed.

In `.github/dependabot.yml`, remove the ecosystems you don't use, add the ones you need,
and adjust `directory` where manifests aren't at the root.

## Publishing

Nothing publishes until you push a `v*` tag. `release.yml` then builds the single-file
claude-sync, runs the integration tests against it, and creates a GitHub Release with
generated notes, the file, its `claude-sync.sha256`, the RPM that `packaging/rpm.sh`
builds in a Fedora container, and build provenance attestations for both. It needs no
secret or setup.
