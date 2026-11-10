# claude-sync

Continuous sync of `~/.claude` across devices: the `claude-sync` command runs Syncthing in a
container against a directory or a Docker volume, so a setting or a memory written on one
machine is there on the others. The [README](https://github.com/Jartan-LLC/claude-sync/blob/main/README.md) covers installing, the quickstart
and what syncs.

```{toctree}
:maxdepth: 2

install
commands
pairing
caveats
own-syncthing
recovering-files
```

```{toctree}
:maxdepth: 2
:caption: Contributing

building
writing-tests
ignore-list
scaffold
signing-key
```
