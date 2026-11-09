# Writing tests

`tests/integration.sh` is the runner: it sources one file per group from `tests/groups/`
and the helpers the groups share from `tests/lib/`, then runs the groups in parallel. So:

- A helper one group uses goes in that group's file; one that two or more use goes in
  `tests/lib/`.
- A new group is a file `tests/groups/NAME.sh` that defines `group_NAME`, and the runner
  needs its `source "$root/tests/groups/NAME.sh"` line; a new `tests/lib/` file needs one
  too. A group runs only as `group_NAME`, from its own `NAME.sh`. Before any Docker call,
  the runner refuses a test file it does not source, a group file without its
  `group_NAME`, and a function defined in two files.
- A group file declares the names of the containers and volumes its group makes, and
  registers them beside the names, at the file's top level, with `own_instances`,
  `own_containers` or `own_volumes`: cleanup removes only what is registered, and a call
  inside `group_NAME` would run in the group's subshell, which cleanup does not see. The
  runner refuses a name registered twice, and a name with the suite's prefix that nothing
  registers. The group makes its volumes and fixtures at the start of `group_NAME`.
- A name declared `readonly` at the top level of `tests/integration.sh` or of a file in
  `tests/lib/` or `tests/groups/` is a read-only global in every test file, so a helper's
  locals and loop variables must not reuse it.
