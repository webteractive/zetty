#!/bin/bash
# Builds Bridge/tailnet (Zetty's embedded Tailscale node) into
# Derived/tailnet/libzettytailnet.a for the given architectures (Xcode's
# $ARCHS, e.g. "arm64" or "arm64 x86_64"), plus its header and module map.
# Skips the build when sources and architectures haven't changed.
# Needs Go (see DEVELOPMENT.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Bridge/tailnet"
OUT="$ROOT/Derived/tailnet"
ARCHS_LIST="${*:-$(uname -m)}"
# Tailscale features Zetty's node doesn't use. ts_omit_peerapiserver matters:
# on macOS the peer API otherwise opens a TCP listener on every interface of
# the Mac (remote-machines.md: never listen outside Tailscale). ts_omit_logtail
# drops Tailscale's log uploader, whose buffer file under Caches otherwise
# holds the sign-in link while signed out (no-logs mode only stubs the upload).
TAGS="ts_omit_peerapiserver,ts_omit_logtail"

GO="$(command -v go || true)"
for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
  [ -n "$GO" ] && break
  [ -x "$candidate" ] && GO="$candidate"
done
if [ -z "$GO" ]; then
  echo "error: Go is needed to build Zetty's Tailscale bridge (brew install go)" >&2
  exit 1
fi

STAMP_INPUT="$(cd "$SRC" && cat go.mod go.sum *.go include/* | shasum -a 256 | cut -d' ' -f1) $ARCHS_LIST $TAGS $("$GO" version)"
if [ -f "$OUT/stamp" ] && [ "$(cat "$OUT/stamp")" = "$STAMP_INPUT" ] && [ -f "$OUT/libzettytailnet.a" ]; then
  exit 0
fi

mkdir -p "$OUT"
LIBS=()
for arch in $ARCHS_LIST; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "error: no Go architecture for $arch" >&2; exit 1 ;;
  esac
  mkdir -p "$OUT/$arch"
  (cd "$SRC" && GOOS=darwin GOARCH="$goarch" CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=14.0 \
    CC="xcrun --sdk macosx clang -arch $arch" \
    "$GO" build -trimpath -tags "$TAGS" -buildmode=c-archive -o "$OUT/$arch/libzettytailnet.a" .)
  LIBS+=("$OUT/$arch/libzettytailnet.a")
done
lipo -create "${LIBS[@]}" -output "$OUT/libzettytailnet.a"
mkdir -p "$OUT/include"
cp "$SRC/include/zetty_tailnet.h" "$SRC/include/module.modulemap" "$OUT/include/"
echo "$STAMP_INPUT" > "$OUT/stamp"
