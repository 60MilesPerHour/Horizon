#!/usr/bin/env bash
# Print the CHANGELOG.md section for one release tag, for use as the body of
# the GitHub release. Usage: scripts/release-notes.sh v4.8.0 [CHANGELOG.md]
#
# Picks up everything after the "## vX.Y.Z — date" heading until the next
# "## " heading or a "---" rule, with the heading itself and surrounding blank
# lines dropped. Exits 1 with nothing on stdout if the tag has no section, so
# the release step can fall back to GitHub's generated notes.
set -euo pipefail

tag="${1:?usage: release-notes.sh vX.Y.Z [changelog]}"
changelog="${2:-$(dirname "$0")/../CHANGELOG.md}"

awk -v tag="$tag" '
  /^## / {
    if (found) exit
    # Headings may cover a range: "## v3.4.0 – v3.4.2 — date".
    n = split($0, parts, /[ \t]+/)
    for (i = 2; i <= n; i++) if (parts[i] == tag) { found = 1; next }
    next
  }
  found && /^---[ \t]*$/ { exit }
  found { print }
' "$changelog" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "${TMPDIR:-/tmp}/release-notes.$$"

if [ ! -s "${TMPDIR:-/tmp}/release-notes.$$" ]; then
  rm -f "${TMPDIR:-/tmp}/release-notes.$$"
  echo "No CHANGELOG.md section for $tag" >&2
  exit 1
fi
cat "${TMPDIR:-/tmp}/release-notes.$$"
rm -f "${TMPDIR:-/tmp}/release-notes.$$"
