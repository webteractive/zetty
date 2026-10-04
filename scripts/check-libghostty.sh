#!/usr/bin/env bash
# Reports whether Lakr233/libghostty-spm has a release newer than the one
# Project.swift pins. Read-only: it changes nothing.
#
#   scripts/check-libghostty.sh
#
# Exit 0 when the pin is the newest release, 1 when a newer one exists (same
# line or a newer line), 2 when the pin or the remote could not be read.
set -euo pipefail

cd "$(dirname "$0")/.."

url=$(sed -n 's/.*url: "\(https:[^"]*libghostty-spm[^"]*\)".*/\1/p' Project.swift | head -1)
pinned=$(sed -n 's/.*requirement: .*from: "\([0-9.]*\)".*/\1/p' Project.swift | head -1)
if [ -z "$url" ] || [ -z "$pinned" ]; then
    echo "check-libghostty: could not read the libghostty-spm pin from Project.swift" >&2
    exit 2
fi

# Release tags only: upstream also publishes `upstream.<sha>` tags, which are
# not versions SwiftPM resolves.
if ! tags=$(git ls-remote --tags --refs "$url" 2>/dev/null); then
    echo "check-libghostty: could not reach $url" >&2
    exit 2
fi
versions=$(printf '%s\n' "$tags" | sed 's#.*refs/tags/##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n)

line=${pinned%.*}                       # major.minor, the line upToNextMinor stays inside
same_line=$(printf '%s\n' "$versions" | grep -E "^${line//./\\.}\.[0-9]+$" | tail -1)
overall=$(printf '%s\n' "$versions" | tail -1)

echo "pinned:          $pinned"
echo "newest in $line:   ${same_line:-none}"
echo "newest overall:  $overall"

status=0
if [ -n "$same_line" ] && [ "$same_line" != "$pinned" ]; then
    echo "-> $same_line is a newer release on the pinned line: bump \`from:\` in Project.swift."
    status=1
fi
if [ "${overall%.*}" != "$line" ]; then
    echo "-> ${overall%.*}.x is a newer LINE: not a routine bump, ask before moving to it."
    status=1
fi
[ "$status" -eq 0 ] && echo "-> up to date."
exit "$status"
