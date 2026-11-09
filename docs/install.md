# Installing

How to install claude-sync, check what you downloaded, keep it current and remove it. The
[README's Requirements](https://github.com/Jartan-LLC/claude-sync/blob/main/README.md#requirements)
say what it needs to run.

## Choose a method

| Method | For | Updates through |
|---|---|---|
| [Single file](#single-file) | Any Linux | `claude-sync upgrade` |
| [RPM](#rpm) | Fedora, and EL 8, 9 and 10 | `dnf`, from claude-sync's signed dnf repository |

## Single file

claude-sync is one file. Download the latest release into `~/.local/bin`, which must be on
your `PATH`:

```bash
mkdir -p ~/.local/bin
curl -fsSLo ~/.local/bin/claude-sync \
    https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync
chmod +x ~/.local/bin/claude-sync
```

### Check the download

`gh attestation verify ~/.local/bin/claude-sync --repo Jartan-LLC/claude-sync` checks that
a workflow in this repository built the file; each release also lists its SHA-256 in
`claude-sync.sha256`.

### Remove the single file

Run [`claude-sync uninstall`](commands.md#uninstall) for each instance first, then delete the
file: `rm ~/.local/bin/claude-sync`.

## RPM

On Fedora, EL 8, 9 or 10, or another distribution that installs RPMs with `dnf`:

```bash
sudo dnf install \
    https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync.noarch.rpm
```

`dnf` checks no signature on a package installed from a URL, so it prints `Warning: skipped
OpenPGP checks for 1 package`. To check the package first, download it and verify its
attestation, then install the file:

```bash
gh release download --repo Jartan-LLC/claude-sync --pattern claude-sync.noarch.rpm
gh attestation verify claude-sync.noarch.rpm --repo Jartan-LLC/claude-sync
sudo dnf install ./claude-sync.noarch.rpm
```

The package adds claude-sync's dnf repository, so `dnf` installs each later release as an
upgrade.

### The signing key

The key that signs the packages and the repository has the fingerprint
`82BAD8A8DE12B859075DFADAE399D5A015054B82`.
`gpg --show-keys /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-sync` prints the fingerprints of the keys
the package installed; when `dnf` asks whether to trust the key, check that it matches.

If `dnf` prints `>>> repomd.xml GPG signature verification error`, it skipped the repository:

- once, right after a release: `dnf` read the new files and the old signature; run the command
  again;
- every time: the project's signing key changed, and this machine missed the releases that
  brought the new one; install the package again from the URL above.

### Unattended updates

A machine that updates with no one at a terminal, such as through `dnf-automatic`, can't answer
`dnf`'s prompt to trust the key. After installing the package:

- Fedora 45 and later: nothing to do;
- older Fedora: run
  `sudo rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-sync && sudo dnf -y makecache` once;
- EL: run `sudo rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-sync` once.

### Remove the RPM

Run [`claude-sync uninstall`](commands.md#uninstall) for each instance first, then
`sudo dnf remove claude-sync`.

## Upgrading

On each device:

- **Single file:** run `claude-sync upgrade`. It installs the newest release that is not
  breaking and applies it to every running instance; for a breaking release it links the
  release notes, which say how to upgrade by hand. [`upgrade`](commands.md#upgrade) has the
  details.
- **RPM:** run `sudo dnf upgrade --refresh claude-sync`, then
  `CLAUDE_SYNC_NAME=NAME claude-sync setup`, with no target, for each instance NAME. `dnf`
  installs a breaking release too, without its manual steps, so read the notes of each release
  it crosses.

### From claude-sync 0.1.1 or earlier

- **Single file:** 0.1.1 and earlier have no `upgrade`. Download claude-sync again as in
  [Single file](#single-file), then run `claude-sync upgrade`, which applies it to every running
  instance.
- **RPM:** an RPM installed before claude-sync had a dnf repository (0.1.1 and earlier, and
  0.2.0-rc.1) has none to upgrade from. Rerun the `dnf install` line from [RPM](#rpm) once, then
  run `CLAUDE_SYNC_NAME=NAME claude-sync setup` for each instance NAME; `dnf upgrade` works from
  then on.
