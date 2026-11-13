#!/usr/bin/env bash
# Reports whether Lakr233/libghostty-spm has a release newer than the one
# Project.swift pins, then where the other two pinned components stand: zmx
# (scripts/zmx.pin) and Tailscale (Bridge/tailnet/go.mod). Read-only: it
# changes nothing.
#
#   scripts/check-libghostty.sh
#
# Exit 0 when every pin is the newest release, 1 when a newer one exists (for
# libghostty: same line or a newer line), 2 when a pin or a remote could not be
# read.
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

# zmx and Tailscale: printed last, whichever way the Ghostty comparison ends.
other_pins() {
    echo
    local zmx_pin zmx_latest
    zmx_pin=$(sed -n 's/^version=//p' scripts/zmx.pin | head -1)
    zmx_latest=$(curl -fsSL https://api.github.com/repos/neurosnap/zmx/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1) || zmx_latest=
    if [ -z "$zmx_pin" ] || [ -z "$zmx_latest" ]; then
        echo "zmx: could not read the pin or the latest release"; [ "$status" -eq 0 ] && status=2
    elif [ "$zmx_pin" = "$zmx_latest" ]; then
        echo "zmx: $zmx_pin pinned, the latest release: current"
    else
        echo "zmx: $zmx_pin pinned, $zmx_latest released: read its CHANGELOG for protocol breaks, then bump scripts/zmx.pin (session-preservation.md)"
        [ "$status" -ne 2 ] && status=1
    fi
    local ts_pin ts_latest
    ts_pin=$(sed -n 's/^require tailscale\.com \(v[^ ]*\).*/\1/p; s/^[[:space:]]*tailscale\.com \(v[^ ]*\).*/\1/p' Bridge/tailnet/go.mod | head -1)
    ts_latest=$(curl -fsSL https://proxy.golang.org/tailscale.com/@latest 2>/dev/null \
        | sed -n 's/.*"Version": *"\([^"]*\)".*/\1/p') || ts_latest=
    if [ -z "$ts_pin" ] || [ -z "$ts_latest" ]; then
        echo "tailscale: could not read the pin or the latest module version"; [ "$status" -eq 0 ] && status=2
    elif [ "$ts_pin" = "$ts_latest" ]; then
        echo "tailscale: $ts_pin pinned, the latest module: current"
    else
        echo "tailscale: $ts_pin pinned, $ts_latest released: bump it in Bridge/tailnet/go.mod (go get tailscale.com@$ts_latest) and re-run remote-e2e.sh"
        [ "$status" -ne 2 ] && status=1
    fi
    return 0
}
finish() { other_pins; exit "$status"; }

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
    finish
fi

# Newest stable release; annotated tags list their commit on the `^{}` line.
release_tags=$(git ls-remote --tags "$ghostty_url" 'refs/tags/v*' 2>/dev/null || true)
release=$(printf '%s\n' "$release_tags" | sed 's#.*refs/tags/##; s#\^{}$##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u -t. -k1.2,1n -k2,2n -k3,3n | tail -1 || true)
release_sha=$(printf '%s\n' "$release_tags" | grep -F "refs/tags/$release^{}" | cut -f1)
[ -n "$release_sha" ] || release_sha=$(printf '%s\n' "$release_tags" \
    | grep -E "refs/tags/$release\$" | cut -f1)

resolved_ref=$(ghostty_ref "$resolved" || true)
if [ -z "$release" ] || [ -z "$release_sha" ] || [ -z "$resolved_ref" ]; then
    echo "ghostty: could not read the release tags or Ghostty.ref, comparison skipped"
    finish
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
    newest_ref=$(ghostty_ref "$same_line" || true)
    if [ "$newest_ref" = "$resolved_ref" ]; then
        echo "ghostty in $same_line: the same commit, so that release only changes the wrapper"
    else
        echo "ghostty in $same_line: ${newest_ref:0:12}, a different Ghostty: compare before bumping"
    fi
fi
finish
