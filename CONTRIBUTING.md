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

Runs the lint and integration checks CI runs. CI also builds the dev container, runs the
integration tests against the built file and builds the RPM (see [Building](#building));
all must pass before merge.

`make test` (`tests/integration.sh`) runs claude-sync against real Syncthing containers and
needs Docker. Every container, volume, network and image it keeps is named
`claude-sync-test-*` and removed afterwards, and it removes nothing else, which matters when
the dev container shares the host's Docker daemon. It never reaches a Syncthing of your
own.

## Building

`./claude-sync` runs from the checkout and reports its version as `dev`. `make build`
writes `dist/claude-sync`, the single file a release ships: the script with its version
and its own files (`compose*.yaml`, `stignore`) built in. To test that file:

```bash
make build VERSION=0.0.0-test
CLAUDE_SYNC_BIN=$PWD/dist/claude-sync CLAUDE_SYNC_BIN_VERSION=0.0.0-test make test
```

CI runs the integration tests against both. It also builds the RPM with
`packaging/rpm.sh` in a Fedora container, and installs it there.

## Releasing

1. Move the `## [Unreleased]` entries in `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD`
   and update the links at its end.
2. Once that is merged, tag `main` and push the tag:
   `git fetch origin && git tag vX.Y.Z origin/main && git push origin vX.Y.Z`. A tag with a
   pre-release part, such as `v0.2.0-rc.1`, is published as a pre-release.

[Publishing](docs/scaffold.md#publishing) covers what the tag sets off.

## Conventions

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- User-facing changes go in `CHANGELOG.md` under `## [Unreleased]`.
- Report security issues privately via [SECURITY.md](.github/SECURITY.md), not a public issue.
