# Contributing

## Setup

```bash
make install
```

`make install` installs the pinned gate tools (`ci/requirements.txt`) and wires the
pre-commit hook. The devcontainer has everything; on a bare host it needs Python 3.12+,
[uv](https://docs.astral.sh/uv/getting-started/installation/) and an environment (`uv venv`).
`make lint` runs the [pre-commit](https://pre-commit.com/) hooks; some need
Docker (actionlint, lychee) and Node (markdownlint) — the devcontainer has both.

## Verify before opening a PR

```bash
make check
```

Runs the same checks CI does; all must pass before merge.

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- User-facing changes go in `CHANGELOG.md` under `## [Unreleased]`.
- Report security issues privately via [SECURITY.md](.github/SECURITY.md), not a public issue.
