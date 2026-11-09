# Updating the ignore list

`stignore` keeps out of sync what is meaningless or harmful on another machine, and Claude
Code adds files to `~/.claude` as it changes. A new file goes on the list when it belongs
to one machine: its name holds a process ID or a session, a process holds it as a lock, or
each machine fetches it on its own, as with a git clone. Conflict copies of a file nobody
edits by hand, made while two devices run Claude Code, are a sign of such a file. Claude
Code's [`.claude` directory page](https://code.claude.com/docs/en/claude-directory.md)
describes many of its files.

To add a rule:

1. Put it in `stignore` under a one-line comment giving the reason, as the rules there do.
2. Prefix a rule for files inside a synced directory with `(?d)`. Without it, a directory
   deleted on another device, or a joining device's own, stays behind while it holds such
   a file, and a join never finishes. A top-level entry needs none.
3. Spell hex ranges out, as `[0123456789abcdef]`: Syncthing's glob takes one range per `[]`
   class and rejects the whole file on `[0-9a-f]`.
4. Add a path the rule matches to the `ignored` list in `tests/lib/claude-dir.sh`, and a
   look-alike it must not match to `synced`.
5. Add the rule to the README's [What syncs](https://github.com/Jartan-LLC/claude-sync/blob/main/README.md#what-syncs) table.

Each release of claude-sync carries its own copy of `stignore`, so a device picks up the
new list when it runs `setup` from a claude-sync that has it (see the README's
[Upgrade](https://github.com/Jartan-LLC/claude-sync/blob/main/README.md#upgrade) section).
