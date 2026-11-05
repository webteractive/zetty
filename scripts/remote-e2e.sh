#!/usr/bin/env bash
# Runs the remote-machines checklist (.hydra/rules/remote-machines.md →
# Testing) across two Macs with nobody at either one.
#
#   scripts/remote-e2e.sh --peer <user>@<lan-address> [--key <file>]
#                         [--app <zetty.app>] [--no-build] [--network] [--keep]
#
# This Mac serves and the peer views. Both run a throwaway copy of the build
# under /tmp/zre (own home, own zmx socket directory) on port 47392
# (ZETTY_REMOTE_PORT), so the installed apps on both Macs keep serving and
# viewing on 47391 and none of their sessions is touched. Each check prints
# PASS or FAIL; the exit status is the number of failures.
#
# --peer     SSH target for the other Mac. Use its LAN address: --network
#            takes this Mac off the tailnet, and SSH must survive that.
#            Also read from ZETTY_E2E_PEER.
# --key      SSH key (default ~/.ssh/zetty-e2e when it exists).
# --app      the build to test (default: the Debug product in DerivedData).
# --no-build skip the xcodebuild step.
# --network  also run `tailscale down` here, expect the peer to show this Mac
#            offline, then `tailscale up` and expect it back. Opt-in: the
#            installed apps lose the tailnet for that minute too.
# --keep     leave both test apps running for a look (tear down by running
#            again, or quit them with their own CLI).
#
# Needs: SSH to the peer without a password, both Macs signed in to
# Tailscale as the same user, zmx here, python3 on the peer.
# The peer must be awake and logged in (its screen may be locked); a test
# window opens on each screen.
set -uo pipefail

cd "$(dirname "$0")/.."

PORT=47392
ROOT=/tmp/zre
TEST_APP=$ROOT/zetty.app
TEST_BIN=$TEST_APP/Contents/MacOS/zetty
PEER=${ZETTY_E2E_PEER:-}
KEY=
APP=
BUILD=1
NETWORK=0
KEEP=0

while [ $# -gt 0 ]; do
    case $1 in
        --peer) PEER=$2; shift 2 ;;
        --key) KEY=$2; shift 2 ;;
        --app) APP=$2; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --network) NETWORK=1; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "remote-e2e: unknown argument $1 (see --help)" >&2; exit 64 ;;
    esac
done
[ -n "$PEER" ] || { echo "remote-e2e: name the other Mac with --peer <user>@<lan-address>" >&2; exit 64; }
[ -z "$KEY" ] && [ -f "$HOME/.ssh/zetty-e2e" ] && KEY=$HOME/.ssh/zetty-e2e

# MARK: - Helpers

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5
          -o ControlMaster=auto -o "ControlPath=/tmp/zre-ssh-%C" -o ControlPersist=120)
[ -n "$KEY" ] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
peer() { ssh "${SSH_OPTS[@]}" "$PEER" "$@"; }

TS_LOCAL=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
ts() { TERM_PROGRAM=zetty-test "$TS_LOCAL" "$@"; }
peer_ts() { peer "TERM_PROGRAM=zetty-test; export TERM_PROGRAM; T=/usr/local/bin/tailscale; [ -x \$T ] || T=/Applications/Tailscale.app/Contents/MacOS/Tailscale; \$T $*"; }

iz() { CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx "$TEST_BIN" "$@"; }
peer_iz() { peer "CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx $TEST_BIN $(printf '%q ' "$@")"; }

now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
log() { printf '   %s\n' "$*"; }

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# Reads a `zetty remote list --json` report on stdin and answers one question.
#   machine-state <id>          the state that Mac has, or "absent"
#   has-pane <id> <pane>        "yes" when that Mac's workspace has the pane
#   lists <id>                  "yes" when that Mac is listed at all
#   shown-panes                 the shown tab's pane ids, space-separated
#   shown-placeholder           what the remote view says instead, if anything
report() {
    python3 -I -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    print("unreadable"); sys.exit(0)
q = sys.argv[1:]
ms = {m["id"]: m for m in r.get("machines", [])}
if q[0] == "machine-state":
    print(ms[q[1]]["state"] if q[1] in ms else "absent")
elif q[0] == "lists":
    print("yes" if q[1] in ms else "no")
elif q[0] == "has-pane":
    ws = (ms.get(q[1]) or {}).get("workspace") or {}
    ids = [p["id"] for pr in ws.get("projects", []) for t in pr.get("tabs", []) for p in t.get("panes", [])]
    print("yes" if q[2] in ids else "no")
elif q[0] == "shown-panes":
    print(" ".join((r.get("shown") or {}).get("panes", [])))
elif q[0] == "shown-placeholder":
    print((r.get("shown") or {}).get("placeholder") or "")
' "$@"
}

# wait_for <seconds> <command…>: runs the command every 0.25s until it
# succeeds or the time runs out. Prints the seconds it took.
wait_for() {
    local limit=$1; shift
    local start; start=$(now)
    while :; do
        if "$@" >/dev/null 2>&1; then
            perl -e "printf '%.1f', $(now) - $start"
            return 0
        fi
        if perl -e "exit(($(now) - $start) < $limit ? 1 : 0)"; then
            perl -e "printf '%.1f', $(now) - $start"
            return 1
        fi
        sleep 0.25
    done
}

peer_state_is() { [ "$(peer_iz remote list --json | report machine-state "$1")" = "$2" ]; }
local_state_is() { [ "$(iz remote list --json | report machine-state "$1")" = "$2" ]; }
peer_sees_pane() { [ "$(peer_iz remote list --json | report has-pane "$1" "$2")" = yes ]; }
# Anchored: each pane's relay runs as `-<zetty> attach …` (a login shell's
# exec -l) under a `/usr/bin/login … -c exec -l <zetty> attach …` that
# carries the same words, so a bare `pgrep -f "zetty attach"` counts two.
peer_relays() { peer "pgrep -f '^-?$TEST_BIN attach' | wc -l" | tr -d ' '; }
peer_relays_are() { [ "$(peer_relays)" = "$1" ]; }

# MARK: - Teardown

TAILSCALE_DOWN=0
teardown() {
    local status=$?
    trap - EXIT INT TERM
    if [ "$TAILSCALE_DOWN" = 1 ]; then
        log "bringing Tailscale back up here"
        ts up >/dev/null 2>&1
    fi
    if [ "$KEEP" = 1 ]; then
        log "--keep: both test apps are still running (iz/peer_iz as in this script)"
    else
        log "tearing down both test apps"
        peer_iz quit --kill-sessions --force >/dev/null 2>&1
        iz quit --kill-sessions --force >/dev/null 2>&1
        sleep 2
        peer "pkill -f '^$TEST_BIN' ; rm -rf $ROOT" >/dev/null 2>&1
        pkill -f "^$TEST_BIN" 2>/dev/null
        rm -rf "$ROOT"
        if [ -n "${REAL_SESSIONS:-}" ]; then
            local after; after=$(zmx list 2>/dev/null | grep -c zetty- || true)
            [ "$after" = "$REAL_SESSIONS" ] || echo "WARN  this Mac's real zmx sessions went from $REAL_SESSIONS to $after"
        fi
    fi
    ssh "${SSH_OPTS[@]}" -O exit "$PEER" >/dev/null 2>&1
    exit $status
}

# MARK: - Preflight

echo "== preflight"
peer true || { echo "remote-e2e: can't reach $PEER over SSH without a password" >&2; exit 2; }
[ "$(uname -m)" = "$(peer uname -m)" ] || { echo "remote-e2e: the peer is $(peer uname -m), this Mac $(uname -m)" >&2; exit 2; }
command -v zmx >/dev/null || { echo "remote-e2e: zmx isn't installed here; serving needs it" >&2; exit 2; }
peer 'command -v python3 >/dev/null' || { echo "remote-e2e: the peer has no python3" >&2; exit 2; }

LOCAL_ID=$(ts status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["ID"])') \
    || { echo "remote-e2e: Tailscale isn't running here" >&2; exit 2; }
PEER_ID=$(peer_ts status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["ID"])') \
    || { echo "remote-e2e: Tailscale isn't running on the peer" >&2; exit 2; }
LOCAL_IP=$(ts ip -4 | head -1)
log "this Mac $LOCAL_ID ($LOCAL_IP), peer $PEER_ID"

# A test app left by an earlier --keep run goes first.
iz quit --kill-sessions --force >/dev/null 2>&1
peer_iz quit --kill-sessions --force >/dev/null 2>&1
sleep 1
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || peer "lsof -nP -iTCP:$PORT -sTCP:LISTEN" >/dev/null 2>&1; then
    echo "remote-e2e: something already listens on port $PORT on one of the Macs" >&2; exit 2
fi

if [ -z "$APP" ]; then
    products=$(xcodebuild -project zetty.xcodeproj -scheme zetty -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
    APP=$products/zetty.app
fi
if [ "$BUILD" = 1 ]; then
    log "building"
    xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' build >/tmp/zre-build.log 2>&1 \
        || { echo "remote-e2e: build failed, see /tmp/zre-build.log" >&2; exit 2; }
fi
[ -x "$APP/Contents/MacOS/zetty" ] || { echo "remote-e2e: no app at $APP" >&2; exit 2; }

trap teardown EXIT INT TERM

# MARK: - Launch

echo "== launch"
REAL_SESSIONS=$(zmx list 2>/dev/null | grep -c zetty- || true)
rm -rf "$ROOT"
mkdir -p "$ROOT/.config/zetty" "$ROOT/zmx" "$ROOT/work"
ditto "$APP" "$TEST_APP"
printf 'preserve-sessions = true\nzetty-serve = true\nzetty-remote-machines = true\n' > "$ROOT/.config/zetty/config"

# The peer's copy: same bytes, its own home. It serves too, so each side
# also checks that it never lists itself.
peer "pkill -f '^$TEST_BIN' ; rm -rf $ROOT && mkdir -p $ROOT/.config/zetty $ROOT/zmx" >/dev/null 2>&1
tar -C "$ROOT" -cf - zetty.app | peer "tar -C $ROOT -xf -" || { fail "copy the build to the peer"; exit 1; }
peer "printf 'zetty-serve = true\nzetty-remote-machines = true\n' > $ROOT/.config/zetty/config"

env -i HOME="$HOME" USER="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=en_US.UTF-8 TERM_PROGRAM=zetty-test \
    PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin" \
    CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx ZETTY_REMOTE_PORT=$PORT \
    "$TEST_BIN" </dev/null >"$ROOT/app.log" 2>&1 &
# The binary directly, as here: `open` can't start a second copy
# (LSMultipleInstancesProhibited) and hands the launch to the installed app.
# Started from SSH it still reaches the peer's window server while that user
# is logged in, and nohup keeps it after the SSH session ends.
peer "cd /tmp && env CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx ZETTY_REMOTE_PORT=$PORT TERM_PROGRAM=zetty-test \
    nohup $TEST_BIN </dev/null >$ROOT/app.log 2>&1 &"

t=$(wait_for 30 iz status) && pass "test app starts here (${t}s)" || { fail "test app starts here"; exit 1; }
# Its socket under /tmp/zre also proves the environment reached it.
t=$(wait_for 30 peer_iz status) && pass "test app starts on the peer, in its own home (${t}s)" \
    || { fail "test app starts on the peer, in its own home"; exit 1; }

# MARK: - Checks

echo "== serving"
check_bind() {
    local where=$1 listing=$2
    if [ -z "$listing" ]; then fail "$where listens on port $PORT"; return; fi
    if printf '%s\n' "$listing" | grep -q '\*:'"$PORT"; then
        fail "$where listens on every interface: $(printf '%s' "$listing" | tr '\n' ' ')"
    else
        pass "$where listens only on its Tailscale addresses"
    fi
}
sleep 3   # the first Tailscale poll
check_bind "this Mac" "$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')"
check_bind "the peer" "$(peer "lsof -nP -iTCP:$PORT -sTCP:LISTEN" 2>/dev/null | awk 'NR>1{print $9}')"

echo "== listing"
t=$(wait_for 40 peer_state_is "$LOCAL_ID" online) && pass "the peer lists this Mac online (${t}s)" \
    || fail "the peer lists this Mac online (still $(peer_iz remote list --json | report machine-state "$LOCAL_ID") after ${t}s)"
t=$(wait_for 40 local_state_is "$PEER_ID" online) && pass "this Mac lists the peer online (${t}s)" \
    || fail "this Mac lists the peer online (still $(iz remote list --json | report machine-state "$PEER_ID") after ${t}s)"
[ "$(iz remote list --json | report lists "$LOCAL_ID")" = no ] && pass "this Mac doesn't list itself" \
    || fail "this Mac lists itself"
[ "$(peer_iz remote list --json | report lists "$PEER_ID")" = no ] && pass "the peer doesn't list itself" \
    || fail "the peer lists itself"

echo "== snapshots"
P1=$(iz add-project "$ROOT/work" --name e2e-work) || { fail "add a scratch project here"; exit 1; }
log "scratch project e2e-work, pane $P1"
t=$(wait_for 10 peer_sees_pane "$LOCAL_ID" "$P1") && pass "a new project reaches the peer (${t}s)" \
    || fail "a new project reaches the peer (not after ${t}s)"
P2=$(iz new-tab --project e2e-work)
t=$(wait_for 10 peer_sees_pane "$LOCAL_ID" "$P2")
if [ $? = 0 ] && perl -e "exit($t <= 2.5 ? 0 : 1)"; then pass "a new tab reaches the peer within 2.5s (${t}s)"
else fail "a new tab reaches the peer within 2.5s (${t}s)"; fi

echo "== typing through a relay"
MARK=$((RANDOM * 7 + 1000))
SUM=$((MARK + 1))
# A python pty stands in for a pane: it runs the relay, types a line, and
# prints what came back. The sum proves the shell ran it, not just echoed it.
OUT=$(peer "ZETTY_REMOTE_PORT=$PORT python3 -I - $TEST_BIN attach $LOCAL_IP:$P1 'echo \$(($MARK+1))zre'" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
argv, line = sys.argv[1:-1], sys.argv[-1]
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
out = b""
def pump(seconds):
    global out
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return
pump(4)
os.write(fd, (line + "\r").encode())
pump(4)
os.kill(pid, signal.SIGTERM)
pump(1)
sys.stdout.write(out.decode("utf-8", "replace"))
PY
)
if printf '%s' "$OUT" | grep -q "${SUM}zre"; then pass "the peer's relay runs a command in this Mac's pane"
else fail "the peer's relay runs a command in this Mac's pane (relay printed: $(printf '%s' "$OUT" | tr -d '\r' | tail -3 | tr '\n' ' '))"; fi
if iz capture --pane "$P1" --lines 40 2>/dev/null | grep -q "^${SUM}zre"; then pass "the command's output is in the pane here"
else fail "the command's output is in the pane here"; fi
t=$(wait_for 5 peer_relays_are 0) && pass "the relay ends with its terminal (${t}s)" || fail "the relay ends with its terminal"

echo "== the remote view"
P3=$(iz split --pane "$P1")
log "split pane $P3"
wait_for 10 peer_sees_pane "$LOCAL_ID" "$P3" >/dev/null
if peer_iz remote open "$LOCAL_ID" e2e-work >/dev/null; then
    shown=$(peer_iz remote list --json | report shown-panes)
    count=$(printf '%s' "$shown" | wc -w | tr -d ' ')
    log "the peer shows: $shown"
    t=$(wait_for 10 peer_relays_are "$count") && pass "one relay per shown pane ($count, ${t}s)" \
        || fail "one relay per shown pane (want $count, have $(peer_relays))"
    iz close --pane "$P3" --force >/dev/null
    t=$(wait_for 5 peer_relays_are $((count - 1))) && pass "closing a pane here ends its relay there (${t}s)" \
        || fail "closing a pane here ends its relay there (have $(peer_relays))"

    echo "== a broken frame"
    peer "printf '\xff\xff\xff\xff' | nc -w 2 $LOCAL_IP $PORT" >/dev/null 2>&1
    sleep 2
    if peer_state_is "$LOCAL_ID" online && peer_relays_are $((count - 1)); then
        pass "a garbage frame closes only its own connection"
    else
        fail "a garbage frame closes only its own connection (state $(peer_iz remote list --json | report machine-state "$LOCAL_ID"), relays $(peer_relays))"
    fi

    if [ "$NETWORK" = 1 ]; then
        echo "== offline and back"
        TAILSCALE_DOWN=1
        # Without --accept-risk the CLI refuses whenever it thinks a session
        # rides on the tailnet, and changes nothing. SSH to the peer uses
        # its LAN address, so nothing here does.
        if ! down=$(ts down --accept-risk=lose-ssh 2>&1); then
            fail "tailscale down here: $down"
        fi
        t=$(wait_for 30 peer_state_is "$LOCAL_ID" offline) && pass "the peer shows this Mac offline (${t}s)" \
            || fail "the peer shows this Mac offline within 30s"
        t=$(wait_for 5 peer_relays_are 0) && pass "its relays end while it's offline (${t}s)" \
            || fail "its relays end while it's offline (have $(peer_relays))"
        placeholder=$(peer_iz remote list --json | report shown-placeholder)
        [ -n "$placeholder" ] && pass "the view says so: $placeholder" || fail "the view says nothing while offline"
        ts up >/dev/null 2>&1
        TAILSCALE_DOWN=0
        t=$(wait_for 60 peer_state_is "$LOCAL_ID" online) && pass "the peer shows this Mac online again (${t}s)" \
            || fail "the peer shows this Mac online again within 60s"
        t=$(wait_for 15 peer_relays_are $((count - 1))) && pass "the shown panes reconnect (${t}s)" \
            || fail "the shown panes reconnect (have $(peer_relays))"
    fi

    peer_iz remote close >/dev/null
    t=$(wait_for 5 peer_relays_are 0) && pass "leaving the view ends every relay (${t}s)" \
        || fail "leaving the view ends every relay (have $(peer_relays))"
else
    fail "the peer opens this Mac's project: $(peer_iz remote open "$LOCAL_ID" e2e-work 2>&1)"
fi

echo "== $FAILS failed"
echo "Not covered here: the sidebar's look, and \"needs update\" from another protocol version."
exit "$FAILS"
