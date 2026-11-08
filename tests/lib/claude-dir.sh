# shellcheck shell=bash
# The synthetic ~/.claude that chain and backups write into their targets.

# Synthetic ~/.claude: real filename shapes, no real data. The look-alikes in `synced`
# (lockfiles, .tmp-like names, nested daemon/, ide/ and jobs/) must not be caught by ignore rules.
readonly task=tasks/3570ff36-0222-44b7-8023-47d964bf700c
readonly job=jobs/5d1c8e2a
readonly synced=(
    settings.json
    claude.json
    projects/-work-demo/memory/note.md
    projects/-work-demo/0b6c1f9e-4d2a-4c8e-9f3b-2a7d5e8c1b40.jsonl
    skills/demo/SKILL.md
    skills/demo/bun.lock
    skills/demo/template.tmpl
    skills/demo/plan.tmp.md
    skills/demo/notes.tmp.data.txt
    skills/demo/draft.tmp.2.changelog.md
    skills/demo/daemon/notes.md
    skills/demo/ide/4242.lock
    sessions/0b6c1f9e-demo-session.tmp
    "$task/.highwatermark"
    "$job/state.json"
    "$job/timeline.jsonl"
    skills/demo/jobs/1/tmp/notes.md
)
readonly ignored=(
    .credentials.json
    .update.lock
    sessions/4242.json
    sessions/4242.key
    ide/4242.lock
    "$task/.lock"
    plugins/cache/market/demo/1.0.0/.in_use
    plugins/marketplaces/demo/.git/HEAD
    plugins/marketplaces/demo/bun.lock
    daemon/control.key
    session-env/0b6c1f9e-4d2a-4c8e-9f3b-2a7d5e8c1b40/sessionstart-hook-1.sh
    shell-snapshots/snapshot-bash-1700000000000-abc123.sh
    telemetry/1p_failed_events.0b6c1f9e.json
    settings.json.tmp.ab12cd34
    history.jsonl.tmp.4242.0123456789ab
    "$job/tmp/notes.md"
)

fixture="cd /t"
for f in "${synced[@]}" "${ignored[@]}"; do
    fixture+=" && mkdir -p \"\$(dirname '$f')\" && echo 'fixture $f' >'$f'"
done
