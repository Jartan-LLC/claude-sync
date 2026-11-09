# Contributing

## Setup

```bash
uv venv        # skip in the devcontainer or with an environment already active
make install
```

`make install` installs the pinned gate tools and docs tools (`ci/requirements.txt`) and wires the
pre-commit hook. The devcontainer has everything; on a bare host it needs Python 3.12+ and
[uv](https://docs.astral.sh/uv/getting-started/installation/).
`make lint` runs the [pre-commit](https://pre-commit.com/) hooks; some need
Docker (actionlint, lychee) and Node (markdownlint), which the devcontainer has.

## Verify before opening a PR

```bash
make check
```

Runs the lint, integration and docs checks CI runs, and an advisory dependency audit that
reports known vulnerabilities without failing. CI runs more (see [CI](docs/scaffold.md#ci)),
and all of it must pass before merge.

`make test` (`tests/integration.sh`) runs claude-sync against real Syncthing containers and
needs Docker and bash 5.1 or newer. Every container, volume, network and image it keeps is
named `claude-sync-test-*`, or is the anonymous volume such a container mounts at
`/var/syncthing`, and is removed afterwards. It removes nothing else, which matters when the
dev container shares the host's Docker daemon. It never reaches a Syncthing of your
own. `CLAUDE_SYNC_TEST_PREFIX=claude-sync-test-NAME-` keeps a run's objects apart from
another run's on the same daemon, and `CLAUDE_SYNC_TEST_FAIL_FAST=1` stops at the first
failing check.

## Building, testing and the ignore list

[Building](docs/building.md), [Writing tests](docs/writing-tests.md) and
[Updating the ignore list](docs/ignore-list.md) are docs pages.

## Releasing

[RELEASING.md](RELEASING.md) says how to cut a release.

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`). So do PR titles, which a squash
  merge can use as the commit subject.
- A commit message says why the change was made; the diff already shows what changed.
- A PR description answers the [pull request template](.github/PULL_REQUEST_TEMPLATE.md)'s
  prompts.
- User-facing changes go in `CHANGELOG.md` under `## [Unreleased]`.
- Report security issues privately via [SECURITY.md](.github/SECURITY.md), not a public issue.
