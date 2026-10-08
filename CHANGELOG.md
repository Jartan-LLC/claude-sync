# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `claude-sync setup --volume NAME | --path DIR`: runs Syncthing in a container that syncs
  `~/.claude` as its owner, skipping per-machine files and keeping a 14-day trash can.
- `claude-sync uninstall`: removes the container and Syncthing state, leaving the synced
  folder untouched.

[Unreleased]: https://github.com/Jartan-LLC/claude-sync/commits/main
