#!/bin/sh
# Cuts a Zetty release: version bump -> commit -> package -> tag -> GitHub release.
#
# Exists because the mechanical half of a release is easy to get subtly wrong, and
# two of the ways it can go wrong are silent:
#
#   * The version lives in Project.swift (CFBundleShortVersionString), NOT in a
#     package manifest. A generic release tool looks for composer.json/Cargo.toml,
#     finds nothing, and ships a DMG stamped with the previous version — the
#     in-app updater compares versions, so it never offers the update.
#   * The release MUST carry both Zetty-<version>.dmg and its .sha256 sidecar.
#     The in-app self-updater verifies the download against that checksum, so a
#     release missing it breaks updates for everyone already running Zetty.
#
# Release notes are deliberately a required input, never generated: see the
# Releasing rule, .hydra/rules/releasing.md. So is the pre-release review
# record (--review): every release is preceded by a bug sweep and a security
# review of everything since the last tag, and the record has to name exactly
# that range, so a commit landed after the review sends it back.
#
# Usage:
#   scripts/release.sh --notes <file> --review <file> (patch | minor | major | X.Y.Z) [--yes] [--dry-run]
set -eu
cd "$(dirname "$0")/.."

REMOTE=origin
BRANCH=main
LEVEL=
NOTES=
REVIEW=
ASSUME_YES=0
DRY_RUN=0

die() { printf '%s\n' "error: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: scripts/release.sh --notes <file> --review <file> (patch | minor | major | X.Y.Z) [--yes] [--dry-run]

  --notes <file>  release notes body (required — releases ship human-written
                  notes; see .hydra/rules/releasing.md)
  --review <file> the pre-release review record (required): a line
                  "Reviewed: <last tag>..<HEAD short sha>" naming exactly the
                  range being released, and "Unresolved: none" (or
                  "Unresolved: accepted by Glen …" for findings he accepted);
                  see .hydra/rules/releasing.md, "Pre-release review"
  patch|minor|major|X.Y.Z
                  how to bump CFBundleShortVersionString in Project.swift
  --yes, -y       skip the confirmation prompt
  --dry-run       print the plan and exit without changing anything
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --notes) [ $# -ge 2 ] || die "--notes needs a file"; NOTES=$2; shift 2 ;;
    --notes=*) NOTES=${1#--notes=}; shift ;;
    --review) [ $# -ge 2 ] || die "--review needs a file"; REVIEW=$2; shift 2 ;;
    --review=*) REVIEW=${1#--review=}; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    patch|minor|major) LEVEL=$1; shift ;;
    [0-9]*.[0-9]*.[0-9]*) LEVEL=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$LEVEL" ] || die "specify a bump level (patch|minor|major) or an explicit X.Y.Z"
[ -n "$NOTES" ] || die "--notes <file> is required; releases ship human-written notes (see .hydra/rules/releasing.md)"
[ -f "$NOTES" ] || die "notes file not found: $NOTES"
[ -s "$NOTES" ] || die "notes file is empty: $NOTES"
[ -n "$REVIEW" ] || die "--review <file> is required: run the pre-release bug sweep and security review first (.hydra/rules/releasing.md)"
[ -f "$REVIEW" ] || die "review file not found: $REVIEW"
LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null) || die "no earlier tag to review from"
# Compared after dropping CRs and trailing blanks; the commit is compared by
# what it resolves to, since a short sha's length differs between clones.
REVIEW_TEXT=$(tr -d '\r' < "$REVIEW" | sed 's/[[:space:]]*$//')
HEAD_SHORT=$(git rev-parse --short HEAD)
reviewed=$(printf '%s\n' "$REVIEW_TEXT" | sed -n 's/^Reviewed: //p')
[ "$(printf '%s\n' "$reviewed" | grep -c . || true)" -eq 1 ] \
  || die "the review record must have one \"Reviewed: $LAST_TAG..$HEAD_SHORT\" line"
reviewed_tag=${reviewed%%..*}
reviewed_sha=${reviewed#*..}
[ "$reviewed_tag" = "$LAST_TAG" ] \
  && [ "$(git rev-parse --verify --quiet "$reviewed_sha^{commit}" || true)" = "$(git rev-parse HEAD)" ] \
  || die "the review record must say \"Reviewed: $LAST_TAG..$HEAD_SHORT\": it covers a different range ($reviewed), so review what is being released"
unresolved=$(printf '%s\n' "$REVIEW_TEXT" | grep -E '^Unresolved:' || true)
[ "$(printf '%s\n' "$unresolved" | grep -c . || true)" -eq 1 ] \
  && printf '%s\n' "$unresolved" | grep -qE '^Unresolved: (none|accepted by Glen( .*)?)$' \
  || die "the review record must have one \"Unresolved: none\" line (only Glen can accept a finding unfixed: \"Unresolved: accepted by Glen …\")"

# --- Preconditions -----------------------------------------------------------
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

current_branch=$(git rev-parse --abbrev-ref HEAD)
[ "$current_branch" = "$BRANCH" ] || die "on branch '$current_branch', expected '$BRANCH'"

# Signing is checked here, before the bump is pushed: package.sh runs after the
# release commit, and failing there leaves a pushed bump with no tag (v0.1.49).
./scripts/package.sh --preflight >/dev/null || die "signing is not ready — see scripts/package.sh --preflight"

git fetch --quiet "$REMOTE" "$BRANCH"
if [ -n "$(git rev-list "HEAD..$REMOTE/$BRANCH")" ]; then
  die "behind $REMOTE/$BRANCH — pull first"
fi

PLIST_KEY=CFBundleShortVersionString
CURRENT=$(sed -n "s/.*\"$PLIST_KEY\": \"\([0-9][0-9.]*\)\".*/\1/p" Project.swift | head -1)
[ -n "$CURRENT" ] || die "could not read $PLIST_KEY from Project.swift"

case "$LEVEL" in
  patch|minor|major)
    MAJOR=$(printf '%s' "$CURRENT" | cut -d. -f1)
    MINOR=$(printf '%s' "$CURRENT" | cut -d. -f2)
    PATCH=$(printf '%s' "$CURRENT" | cut -d. -f3)
    case "$LEVEL" in
      patch) PATCH=$((PATCH + 1)) ;;
      minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
      major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    esac
    VERSION="$MAJOR.$MINOR.$PATCH"
    ;;
  *) VERSION=$LEVEL ;;
esac
TAG="v$VERSION"

# A tag that already exists means someone (or some earlier half-run) got here
# first; resolving that is a judgement call, not something to paper over.
[ "$(git tag -l "$TAG" | wc -l)" -eq 0 ] || die "tag $TAG already exists locally"
[ "$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG" | wc -l)" -eq 0 ] \
  || die "tag $TAG already exists on $REMOTE"

DMG="dist/Zetty-$VERSION.dmg"
SHA="$DMG.sha256"

cat <<PLAN
Release plan
  version      $CURRENT -> $VERSION   (Project.swift: $PLIST_KEY)
  commit       chore(release): $TAG
  tag          $TAG (annotated, on the release commit)
  assets       $DMG
               $SHA
  notes        $NOTES ($(wc -l < "$NOTES" | tr -d ' ') lines)
  remote       $REMOTE/$BRANCH
PLAN

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry run] nothing was changed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Proceed? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

# --- Gate on the test suite --------------------------------------------------
# The pure ZettyCore suite is ~1s; there is no reason to ship without it.
echo "==> swift test"
mise exec -- swift test >/dev/null || die "tests failed — not releasing"

# --- Bump + commit -----------------------------------------------------------
echo "==> bumping $PLIST_KEY to $VERSION"
sed -i '' "s/\"$PLIST_KEY\": \"$CURRENT\"/\"$PLIST_KEY\": \"$VERSION\"/" Project.swift
git diff --quiet -- Project.swift && die "version bump changed nothing — check Project.swift"

git add Project.swift
git commit -m "chore(release): $TAG"
RELEASE_COMMIT=$(git rev-parse HEAD)
git push "$REMOTE" "$BRANCH"

# --- Package -----------------------------------------------------------------
# Runs tuist generate + a Release build, so it must come AFTER the bump for the
# bundle to carry the new version.
echo "==> packaging"
./scripts/package.sh

[ -f "$DMG" ] || die "expected $DMG, not produced"
[ -f "$SHA" ] || die "expected $SHA, not produced"

# The sidecar is load-bearing for the self-updater, so verify rather than trust.
actual=$(shasum -a 256 "$DMG" | awk '{print $1}')
recorded=$(cat "$SHA")
[ "$actual" = "$recorded" ] || die "checksum mismatch: $DMG vs $SHA"

built_version=$(/usr/libexec/PlistBuddy -c "Print :$PLIST_KEY" \
  build/Build/Products/Release/zetty.app/Contents/Info.plist)
[ "$built_version" = "$VERSION" ] \
  || die "packaged app reports $built_version, expected $VERSION"

# --- Tag + release -----------------------------------------------------------
echo "==> tagging $TAG"
git tag -a "$TAG" "$RELEASE_COMMIT" -m "$TAG"
git push "$REMOTE" "$TAG"

echo "==> creating GitHub release"
gh release create "$TAG" --title "$TAG" --notes-file "$NOTES" "$DMG" "$SHA"

echo
echo "Released $TAG"
echo "  commit  $RELEASE_COMMIT"
gh release view "$TAG" --json url,assets \
  -q '"  url     " + .url, "  assets  " + ([.assets[].name] | join(", "))'
echo
# `ditto` in place, never `rm -rf` first: ZettyGhostty.framework is lazy-loaded,
# so deleting the bundle under a live process kills it with a dyld SIGABRT.
# See .hydra/rules/install-after-change.md.
echo "Reminder: install the packaged build so /Applications matches the release:"
echo "  ditto build/Build/Products/Release/zetty.app /Applications/zetty.app \\"
echo "    && defaults read /Applications/zetty.app/Contents/Info.plist ZettyBuildCommit \\"
echo "    && zetty quit && sleep 2 && open -a /Applications/zetty.app"
