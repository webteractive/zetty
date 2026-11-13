#!/bin/bash
# Fetches the zmx release scripts/zmx.pin names, verifies both tarballs'
# sha256 against the pin, and lipos them into Derived/zmx/zmx (universal), the
# helper the app bundles at Contents/Helpers/zmx. Skips everything when the
# pin hasn't changed. A cold cache needs the network; a checksum mismatch or a
# failed download fails the build, so no build ever ships without zmx.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/scripts/zmx.pin"
OUT="$ROOT/Derived/zmx"

value() { sed -n "s/^$1=//p" "$PIN" | head -1; }
VERSION="$(value version)"
[ -n "$VERSION" ] || { echo "error: no version in $PIN" >&2; exit 1; }

STAMP_INPUT="$(shasum -a 256 "$PIN" | cut -d' ' -f1)"
if [ -f "$OUT/stamp" ] && [ "$(cat "$OUT/stamp")" = "$STAMP_INPUT" ] && [ -x "$OUT/zmx" ]; then
  exit 0
fi

CACHE="$OUT/$VERSION"
mkdir -p "$CACHE"
SLICES=()
for arch in aarch64 x86_64; do
  want="$(value "sha256-$arch")"
  [ -n "$want" ] || { echo "error: no sha256-$arch in $PIN" >&2; exit 1; }
  tarball="$CACHE/zmx-$VERSION-macos-$arch.tar.gz"
  if [ ! -f "$tarball" ] || [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" != "$want" ]; then
    url="https://github.com/neurosnap/zmx/releases/download/v$VERSION/zmx-$VERSION-macos-$arch.tar.gz"
    curl -fsSL --retry 2 -o "$tarball.part" "$url" \
      || { rm -f "$tarball.part"; echo "error: could not download zmx $VERSION ($arch) from $url, and no verified copy is cached in $CACHE (scripts/zmx.pin)" >&2; exit 1; }
    mv "$tarball.part" "$tarball"
  fi
  got="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$tarball"
    echo "error: zmx $VERSION ($arch) sha256 is $got, scripts/zmx.pin says $want; refusing it" >&2
    exit 1
  fi
  mkdir -p "$CACHE/$arch"
  tar -xzf "$tarball" -C "$CACHE/$arch" zmx
  SLICES+=("$CACHE/$arch/zmx")
done

lipo -create "${SLICES[@]}" -output "$OUT/zmx.part"
chmod 755 "$OUT/zmx.part"
mv "$OUT/zmx.part" "$OUT/zmx"
echo "$STAMP_INPUT" > "$OUT/stamp"
