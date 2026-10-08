# claude-sync

Continuous sync of `~/.claude` across devices: the `claude-sync` command (Bash) runs
Syncthing in a container (Docker Compose) against a directory or a Docker volume.

## Rules

The project rules live in `GUARDRAILS.md`, ranked by how firmly each holds; this import
loads them into every session:

@GUARDRAILS.md

## Corrections

<!-- Version mismatches are the most common — fill these in early.
"We use Pydantic v2 field_validator, not v1 validator."
"Next.js 15 uses async cookies() — not the sync API from v14." -->

## Skills

<!-- Add project-specific skills and conventions here as they develop. -->

## Verify

Run `make check` before declaring work done — it runs CI's checks, lint then the
integration tests:

```bash
make check
```

`make help` lists the targets.
