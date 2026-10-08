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
Docker (actionlint, lychee) and Node (markdownlint) — the devcontainer has both.

## Verify before opening a PR

```bash
make check
```

Runs CI's checks, lint then `make test`; all must pass before merge.

`make test` (`tests/integration.sh`) runs claude-sync against real Syncthing containers and
needs Docker. Everything it creates is named `claude-sync-test-*` and removed afterwards; it
touches nothing else, which matters when the dev container shares the host's Docker daemon.
It points claude-sync at its own objects with `CLAUDE_SYNC_NAME`, and swaps host networking
for a bridge with `CLAUDE_SYNC_COMPOSE_OVERRIDE=tests/compose.test.yaml`.

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- User-facing changes go in `CHANGELOG.md` under `## [Unreleased]`.
- Report security issues privately via [SECURITY.md](.github/SECURITY.md), not a public issue.
