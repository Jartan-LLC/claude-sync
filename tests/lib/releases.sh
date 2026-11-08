# shellcheck shell=bash
# Fake releases, for the groups that check for or install a newer claude-sync.

# A fake release list in the shape of GitHub's API, for a repository at BASE: v0.4.1 is the
# only release with files, and SUMS, if given, is the repository its SHA-256 is in.
releases_json() {
    local base=$1 sums=${2:-$1}
    cat <<EOF
[
  {"html_url": "$base/releases/tag/v0.5.0", "tag_name": "v0.5.0", "prerelease": false, "assets": []},
  {"html_url": "$base/releases/tag/v0.4.2-rc.1", "tag_name": "v0.4.2-rc.1", "prerelease": true, "assets": []},
  {"html_url": "$base/releases/tag/v0.4.1", "tag_name": "v0.4.1", "prerelease": false, "assets": [
    {"browser_download_url": "$base/releases/download/v0.4.1/claude-sync"},
    {"browser_download_url": "$sums/releases/download/v0.4.1/claude-sync.sha256"}
  ]},
  {"html_url": "$base/releases/tag/v0.4.0", "tag_name": "v0.4.0", "prerelease": false, "assets": []}
]
EOF
}
