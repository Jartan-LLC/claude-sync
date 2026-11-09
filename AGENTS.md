# claude-sync

Continuous sync of `~/.claude` across devices: the `claude-sync` command (Bash) runs
Syncthing in a container (Docker Compose) against a directory or a Docker volume.

## Rules

The project rules live in `GUARDRAILS.md`, ranked by how firmly each holds. Claude Code
loads them through the import below; any other agent reads `GUARDRAILS.md` before
starting work.

@GUARDRAILS.md

## Corrections

<!-- Version mismatches are the most common — fill these in early. Kept when empty: the
heading is what prompts adding a correction. -->

## Skills

<!-- Add project-specific skills and conventions here as they develop. Kept when empty: the
heading is what prompts adding one. -->

## Verify

Run `make check` before declaring work done — it runs CI's lint and integration checks
(the integration tests need Docker) and the advisory dependency audit:

```bash
make check
```

`make help` lists the targets.
