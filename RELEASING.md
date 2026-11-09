# Releasing

How to cut a release from `main`. The workflows a tag runs are listed in
[Publishing](docs/scaffold.md#publishing).

## Cut a release

1. Choose the version, written `X.Y.Z` below, a pre-release suffix included. A release with a
   breaking change takes a new major version, or a new minor version while the major is 0,
   never a patch: `claude-sync upgrade` tells a breaking release only by its version number,
   and installs a newer release that is not breaking without asking. Write a pre-release in
   SemVer, as `0.2.0-rc.1`: `claude-sync upgrade` reads no other form.
   [Pre-releases](#pre-releases) says what one publishes.
2. On a branch from `main`, move the entries under `## [Unreleased]` in `CHANGELOG.md` to a new
   section below it, headed `## [X.Y.Z] - YYYY-MM-DD`. That section becomes the release notes;
   an entry may wrap across lines, since the notes join them. For a breaking release, the
   section also says how to upgrade by hand, because `claude-sync upgrade` links a breaking
   release's notes instead of installing it, and `dnf` installs it without them: a single-file
   install downloads claude-sync again as in the README's Install section, an RPM install runs
   `sudo dnf upgrade --refresh claude-sync`, and both then run
   `CLAUDE_SYNC_NAME=NAME claude-sync setup` for each instance NAME and any other step the
   release needs. Then point the `[Unreleased]` link at the new tag and add a
   link for the new version. Keep all link definitions at the end of the file, below every
   section and after a blank line, since one written straight after an entry becomes part of
   that entry's text:

   ```markdown
   [Unreleased]: https://github.com/Jartan-LLC/claude-sync/compare/vX.Y.Z...HEAD
   [X.Y.Z]: https://github.com/Jartan-LLC/claude-sync/releases/tag/vX.Y.Z
   ```

3. Open a pull request from that branch and merge it once its checks pass.
4. Wait for CI to pass on the commit the merge made on `main`. A `v*` tag publishes without
   waiting for CI, so tag only a commit whose CI run passed:

   ```bash
   sha=$(gh pr view <PR number> --json mergeCommit --jq .mergeCommit.oid)
   gh run list --workflow ci.yml --commit "$sha"
   gh run watch <run ID> --exit-status   # exits non-zero if the run failed
   ```

   `gh run list` prints nothing until GitHub has created the run; run it again until the run
   appears. If the run fails, fix `main` through another pull request and repeat this step
   with that one.
5. Tag that commit and push the tag:

   ```bash
   git fetch origin   # so the merge commit exists locally
   sha=$(gh pr view <PR number> --json mergeCommit --jq .mergeCommit.oid)   # again, in case the CI step's shell is gone
   git tag vX.Y.Z "$sha"
   git push origin vX.Y.Z
   ```

   The tag is `v` and the version exactly as the changelog heading writes it: `release.yml`
   runs on `v*` tags and takes the notes from `## [X.Y.Z]`.

## After the tag

The tag starts `release.yml`. A Release needs the single file, the RPM and their attestations:
a build, RPM build or attestation that fails or times out leaves the tag without a GitHub
Release. If the failure was transient, such as a mirror timeout, `gh run rerun <run ID>
--failed` on the `release.yml` run creates it. Attestations need a public repository, so a
private copy of this repository gets no Release.

The `sign` job waits for a required reviewer of the `rpm-signing` environment to approve it: open
the run from `gh run list --branch vX.Y.Z` and choose Review deployments. Approve earlier tags
first, and reject a `sign` job you won't approve, or cancel its run: a tag's `release.yml` run
waits until the previous tag's run finishes, so until then later tags get no GitHub Release. A
rejected or failed `sign` job leaves the tag without one too: after a rejection the re-run above
asks for approval again, and [Signing key](docs/signing-key.md) says what to fix first when the
job failed.

1. Check that the run succeeded:

   ```bash
   gh run list --branch vX.Y.Z
   ```

2. Check the notes with `gh release view vX.Y.Z`. If the `release.yml` run warns that it used
   generated notes, `CHANGELOG.md` had nothing under `## [X.Y.Z]` at the tag; the warning says
   why. Check that the Release lists `claude-sync`, `claude-sync.sha256` and
   `claude-sync.noarch.rpm`: `claude-sync upgrade` and the README's install commands download
   them by those names. A full release also lists `claude-sync-dnf-repo.tar.gz`, the dnf
   repository's signed metadata.
3. Check that the `pages.yml` run the release started succeeded: its `verify` job installs the
   package from the release URL and fails unless the live dnf repository lists the Latest
   release as the newest version. A full release becomes Latest only when no full release has a
   higher version. Of the runs this lists, check the one that started when this tag's
   `release.yml` run finished; if that run was cancelled, a later run took its place in the
   queue: check that one, which deploys the release that was Latest when it ran.

   ```bash
   gh run list --workflow pages.yml --limit 5
   ```

## Pre-releases

For a tag with a pre-release version, such as `v0.2.0-rc.1`:

- `release.yml` creates a GitHub pre-release, which GitHub never marks Latest, so the README's
  `releases/latest` downloads don't get it, and `claude-sync upgrade` leaves it out;
- the RPM's version is `0.2.0~rc.1`, which `dnf` upgrades in place to `0.2.0`;
- the RPM is signed, but stays out of the dnf repository, which would otherwise upgrade every
  user to it.

## Installing the RPM

Users install the RPM, and later upgrade it in place, with:

```bash
sudo dnf install https://github.com/Jartan-LLC/claude-sync/releases/latest/download/claude-sync.noarch.rpm
```

`dnf` checks no signature on a package installed from a URL, so it prints `Warning: skipped
OpenPGP checks for 1 package`. To check that a release built it, download it and verify its
attestation before installing it:

```bash
gh release download --repo Jartan-LLC/claude-sync --pattern claude-sync.noarch.rpm
gh attestation verify claude-sync.noarch.rpm --repo Jartan-LLC/claude-sync
sudo dnf install ./claude-sync.noarch.rpm
```

### Updates through dnf

The package adds claude-sync's dnf repository, so `sudo dnf upgrade` installs each new release.
The repository works with dnf on Fedora and on EL 8, 9 and 10.

The key that signs the packages and the repository has the fingerprint
`82BAD8A8DE12B859075DFADAE399D5A015054B82`; `gpg --show-keys /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-sync` prints the
fingerprints of the keys the package installed. [Signing key](docs/signing-key.md) covers making,
rotating and replacing it.

If dnf prints `>>> repomd.xml GPG signature verification error`, it skipped the repository:

- once, right after a release: dnf read the new files and the old signature; run the command
  again;
- every time: the project's signing key changed, and this machine missed the releases that
  brought the new one; install the package again from the URL above.

A machine that updates with no one at a terminal, such as through `dnf-automatic`, can't answer
dnf's prompt to trust the key. After installing the package:

- Fedora 45 and later: nothing to do;
- older Fedora: run
  `sudo rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-sync && sudo dnf -y makecache` once;
- EL: run `sudo rpmkeys --import /etc/pki/rpm-gpg/RPM-GPG-KEY-claude-sync` once.
