# Building

`./claude-sync` runs from the checkout and reports its version as `dev`. `make build`
writes `dist/claude-sync`, the single file a release ships: the script with its version,
its own files (`compose*.yaml`, `stignore`) and `lib/*.sh` built in. To test that file:

```bash
make build VERSION=0.0.0-test
CLAUDE_SYNC_BIN=$PWD/dist/claude-sync CLAUDE_SYNC_BIN_VERSION=0.0.0-test make test
```

`claude-sync` holds the command line; the rest of the program lives in `lib/*.sh`. The
checkout's `claude-sync` loads each of them with a `source` line in its SOURCES block, from
the directory it sits in, symlinks resolved; `packaging/build.sh` puts the same files, in
the same order, into the built file. The checkout's `claude-sync` exits 1, saying why,
without `lib/` beside it or when it has no file to look beside: run from stdin (`bash -s`),
as a string (`bash -c`) or through `bash <(...)`.

Rules for lib files:

- A new lib file needs its `source "$here/lib/NAME.sh"` line in the SOURCES block.
  `build.sh` refuses a lib file that is not listed, a listed file that is missing, and a
  function defined in two files, where the later definition would silently win.
- Top-level code that reads a global or calls a function defined in another file needs that
  file listed first. `make lint` reports a top-level call to a function defined in a
  later-listed file as SC2218, but not such a call inside a function that top-level code
  runs; a global read before it is set fails at startup under `set -u`.
- Lib files hold only definitions and top-level assignments, `lib/instances.sh`'s name block
  included, and their top-level code ends with status 0.
- Code that needs claude-sync's own path reads `claude_sync_file`, never `BASH_SOURCE`, which
  in a function names the lib file in a checkout.
