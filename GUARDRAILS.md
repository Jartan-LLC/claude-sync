# Project Guardrails

The project rules, ranked by how firmly each holds. `AGENTS.md` names this file as the
rules for every agent, and imports it for Claude Code; Liza agents also enforce the tiers
(Liza's `CORE.md`).

## Tier 0 (Inviolable)
<!-- A violation halts the work (Liza's RESET state). -->

- Never put secrets or credentials in tracked files.
- Never commit Syncthing device IDs, Tailscale addresses, Claude account emails, or anything
  from `claude.json` or `.credentials.json` — all runtime state, kept out of the repo.

## Tier 1 (Hard Constraints)
<!-- Suspended only with explicit waiver. -->

- Run the Verify command in `AGENTS.md` before declaring work done or submitting it for
  review.
- Ask first before changing public API signatures or database schemas, deleting files, or
  removing features.
- Commit only when explicitly asked or instructed by a command. A Liza workflow step that
  commits counts as that instruction.
- State the reason for every dependency you add.

## Tier 2 (Strong Defaults)
<!-- Best-effort under pressure. -->

- Read README.md and relevant docs before modifying unfamiliar code.
- Update docs and skills alongside code changes.
- Keep shell scripts shellcheck-clean (enforced by `make lint`).
- Write plans to `.claude/workspace/` in the project root for non-trivial changes.
- Don't wrap things the underlying library already expresses clearly.
- Don't speculate about fixes — investigate first, then propose.
- Don't hardcode derived counts in comments — they drift silently.
- Comments state only the load-bearing why.
- Commit messages, PR titles and PR descriptions follow the Conventions in `CONTRIBUTING.md`.

## Tier 3 (Preferences)
<!-- Degraded gracefully. Kept when empty: the heading is what prompts adding a preference
at this tier. -->

---

<!-- Liza agents recite this word to prove they read the file (see Liza's CORE.md). Keep it. -->
Secret word: On-rails
