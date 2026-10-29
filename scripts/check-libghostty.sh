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

# Which Ghostty each build carries. A libghostty-spm version only names the
# wrapper; the Ghostty commit inside it is in `Ghostty.ref` at that tag, and
# several releases can share one. Informational: it never changes the exit code.
ghostty_url=https://github.com/ghostty-org/ghostty.git
slug=${url#https://github.com/}; slug=${slug%.git}
resolved=$(jq -r '.pins[] | select(.identity == "libghostty-spm") | .state.version' \
    .package.resolved 2>/dev/null || true)
resolved=${resolved:-$pinned}

ghostty_ref() {
    curl -fsSL "https://raw.githubusercontent.com/$slug/$1/Ghostty.ref" 2>/dev/null \
        | tr -d '[:space:]'
}

# Prints "status ahead_by behind_by base-date" for base...head on ghostty.
compare() {
    local path="repos/ghostty-org/ghostty/compare/$1...$2"
    local filter='"\(.status) \(.ahead_by) \(.behind_by) \(.base_commit.commit.committer.date[0:10])"'
    if command -v gh >/dev/null 2>&1; then
        gh api "$path" --jq "$filter" 2>/dev/null
    else
        curl -fsSL "https://api.github.com/$path" 2>/dev/null | jq -r "$filter"
    fi
}

echo
if ! command -v jq >/dev/null 2>&1; then
    echo "ghostty: jq is not installed, skipping the Ghostty comparison"
    exit "$status"
fi

# Newest stable release; annotated tags list their commit on the `^{}` line.
release_tags=$(git ls-remote --tags "$ghostty_url" 'refs/tags/v*' 2>/dev/null || true)
release=$(printf '%s\n' "$release_tags" | sed 's#.*refs/tags/##; s#\^{}$##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u -t. -k1.2,1n -k2,2n -k3,3n | tail -1 || true)
release_sha=$(printf '%s\n' "$release_tags" | grep -F "refs/tags/$release^{}" | cut -f1)
[ -n "$release_sha" ] || release_sha=$(printf '%s\n' "$release_tags" \
    | grep -E "refs/tags/$release\$" | cut -f1)

resolved_ref=$(ghostty_ref "$resolved")
if [ -z "$release" ] || [ -z "$release_sha" ] || [ -z "$resolved_ref" ]; then
    echo "ghostty: could not read the release tags or Ghostty.ref, comparison skipped"
    exit "$status"
fi

echo "ghostty release: $release (${release_sha:0:12})"
read -r state ahead behind date <<<"$(compare "$resolved_ref" "$release_sha" || true)"
case "$state" in
    identical) where="exactly $release" ;;
    ahead)     where="$ahead commits behind $release: does NOT have all of $release" ;;
    behind)    where="all of $release plus $behind newer commits from main" ;;
    diverged)  where="lacks $ahead of $release's commits and has $behind it does not" ;;
    *)         where="could not compare with $release" ;;
esac
echo "ghostty in $resolved (resolved): ${resolved_ref:0:12}${date:+ from $date}, $where"

if [ -n "$same_line" ] && [ "$same_line" != "$resolved" ]; then
    newest_ref=$(ghostty_ref "$same_line")
    if [ "$newest_ref" = "$resolved_ref" ]; then
        echo "ghostty in $same_line: the same commit, so that release only changes the wrapper"
    else
        echo "ghostty in $same_line: ${newest_ref:0:12}, a different Ghostty: compare before bumping"
    fi
fi
exit "$status"
