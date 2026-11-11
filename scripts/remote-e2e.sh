#!/usr/bin/env bash
# Runs the remote-machines checklist (.hydra/rules/remote-machines.md →
# Testing) across two Macs with nobody at either one.
#
#   scripts/remote-e2e.sh --peer <user>@<lan-address> [--key <file>]
#                         [--app <zetty.app>] [--no-build] [--keep]
#
# This Mac serves and the peer views. Both run a throwaway copy of the build
# under /tmp/zre (own home, own zmx socket directory), each its own
# ephemeral Tailscale device enrolled with a test auth key, so the installed
# apps on both Macs keep their own devices and none of their sessions is
# touched. Each check prints PASS or FAIL; the exit status is the number of
# failures.
#
# --peer     SSH target for the other Mac (its LAN address). Also read from
#            ZETTY_E2E_PEER.
# --key      SSH key (default ~/.ssh/zetty-e2e when it exists).
# --app      the build to test (default: the Debug product in DerivedData).
# --no-build skip the xcodebuild step.
# --keep     leave both test apps running for a look (tear down by running
#            again, or quit them with their own CLI).
#
# Needs: ZETTY_E2E_TAILSCALE_AUTH_KEY in the environment (a reusable,
# ephemeral, pre-approved, untagged auth key: DEVELOPMENT.md), SSH to the
# peer without a password, zmx here, python3 on the peer, and the peer's own
# Tailscale app running (the non-Zetty refusal check goes through it).
# The peer must be awake and logged in (its screen may be locked); a test
# window opens on each screen.
set -uo pipefail

cd "$(dirname "$0")/.."

PORT=47391
# Today's RemoteProtocol.version, for the stand-in client.
PROTO=$(sed -n 's/.*static let version = \([0-9][0-9]*\).*/\1/p' Sources/ZettyCore/Remote/RemoteWire.swift)
ROOT=/tmp/zre
TEST_APP=$ROOT/zetty.app
TEST_BIN=$TEST_APP/Contents/MacOS/zetty
PEER=${ZETTY_E2E_PEER:-}
KEY=
APP=
BUILD=1
KEEP=0

while [ $# -gt 0 ]; do
    case $1 in
        --peer) PEER=$2; shift 2 ;;
        --key) KEY=$2; shift 2 ;;
        --app) APP=$2; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "remote-e2e: unknown argument $1 (see --help)" >&2; exit 64 ;;
    esac
done
[ -n "$PEER" ] || { echo "remote-e2e: name the other Mac with --peer <user>@<lan-address>" >&2; exit 64; }
[ -z "$KEY" ] && [ -f "$HOME/.ssh/zetty-e2e" ] && KEY=$HOME/.ssh/zetty-e2e
[ -n "${ZETTY_E2E_TAILSCALE_AUTH_KEY:-}" ] || {
    echo "remote-e2e: set ZETTY_E2E_TAILSCALE_AUTH_KEY (a reusable, ephemeral, pre-approved auth key; DEVELOPMENT.md)" >&2
    exit 64
}

# MARK: - Helpers

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5
          -o ControlMaster=auto -o "ControlPath=/tmp/zre-ssh-%C" -o ControlPersist=120)
[ -n "$KEY" ] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
peer() { ssh "${SSH_OPTS[@]}" "$PEER" "$@"; }

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
#   has-project <id> <name>     "yes" when that Mac's workspace has the project
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
elif q[0] == "has-project":
    ws = (ms.get(q[1]) or {}).get("workspace") or {}
    print("yes" if any(p.get("name") == q[2] for p in ws.get("projects", [])) else "no")
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
peer_relay_pids() { peer "pgrep -f '^-?$TEST_BIN attach' | sort -n | tr '\n' ' '"; }

# MARK: - Teardown

teardown() {
    local status=$?
    trap - EXIT INT TERM
    # The auth key never outlives the run, on either Mac.
    rm -f "$ROOT/.ts-authkey"
    peer "rm -f $ROOT/.ts-authkey" >/dev/null 2>&1
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

# A test app left by an earlier --keep run goes first.
iz quit --kill-sessions --force >/dev/null 2>&1
peer_iz quit --kill-sessions --force >/dev/null 2>&1
sleep 1

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
# Each copy enrolls its own ephemeral device with the test auth key, from a
# 0600 file that teardown deletes. In memory only: no Keychain (the peer's is
# locked to SSH) and no file holds the device's state.
(umask 077; printf '%s\n' "$ZETTY_E2E_TAILSCALE_AUTH_KEY" > "$ROOT/.ts-authkey")

# The peer's copy: same bytes, its own home. It serves too, so each side
# also checks that it never lists itself.
peer "pkill -f '^$TEST_BIN' ; rm -rf $ROOT && mkdir -p $ROOT/.config/zetty $ROOT/zmx" >/dev/null 2>&1
copied=0
for attempt in 1 2 3; do   # a relayed link drops the odd large copy
    tar -C "$ROOT" -czf - zetty.app | peer "rm -rf $ROOT/zetty.app && tar -C $ROOT -xzf -" && { copied=1; break; }
    sleep 3
done
[ "$copied" = 1 ] || { fail "copy the build to the peer"; exit 1; }
peer "printf 'zetty-serve = true\nzetty-remote-machines = true\n' > $ROOT/.config/zetty/config"
printf '%s\n' "$ZETTY_E2E_TAILSCALE_AUTH_KEY" | peer "umask 077 && cat > $ROOT/.ts-authkey"

# No TERM or TERM_PROGRAM on either copy, as when the Dock opens Zetty.
env -i HOME="$HOME" USER="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
    PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin" \
    CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx ZETTY_TAILSCALE_AUTH_KEY_FILE=$ROOT/.ts-authkey \
    "$TEST_BIN" </dev/null >"$ROOT/app.log" 2>&1 &
# The binary directly, as here: `open` can't start a second copy
# (LSMultipleInstancesProhibited) and hands the launch to the installed app.
# Started from SSH it still reaches the peer's window server while that user
# is logged in, and nohup keeps it after the SSH session ends.
peer "cd /tmp && env -u TERM -u TERM_PROGRAM CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx \
    ZETTY_TAILSCALE_AUTH_KEY_FILE=$ROOT/.ts-authkey \
    nohup $TEST_BIN </dev/null >$ROOT/app.log 2>&1 &"

t=$(wait_for 30 iz status) && pass "test app starts here (${t}s)" || { fail "test app starts here"; exit 1; }
# Its socket under /tmp/zre also proves the environment reached it.
t=$(wait_for 30 peer_iz status) && pass "test app starts on the peer, in its own home (${t}s)" \
    || { fail "test app starts on the peer, in its own home"; exit 1; }
# Each copy's machine ID, made at launch: what the other lists it by.
LOCAL_ID=$(head -n 1 "$ROOT/.zetty/machine-id" 2>/dev/null)
PEER_ID=$(peer "head -n 1 $ROOT/.zetty/machine-id" 2>/dev/null)
log "this copy $LOCAL_ID, the peer's $PEER_ID"

# MARK: - Checks

echo "== serving"
# The node is userspace: nothing of the test app's binds this Mac's own
# interfaces, Tailscale's or any other.
check_bind() {
    local where=$1 listing=$2
    if [ -z "$listing" ]; then pass "$where's test app listens on none of the Mac's interfaces"
    else fail "$where's test app listens on the Mac's own interfaces: $(printf '%s' "$listing" | tr '\n' ' ')"; fi
}
sleep 3
check_bind "this Mac" "$(lsof -nP -a -p "$(pgrep -f "^$TEST_BIN" | head -1)" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')"
check_bind "the peer" "$(peer "lsof -nP -a -p \$(pgrep -f '^$TEST_BIN' | head -1) -iTCP -sTCP:LISTEN" 2>/dev/null | awk 'NR>1{print $9}')"

echo "== listing"
t=$(wait_for 60 peer_state_is "$LOCAL_ID" online) && pass "the peer lists this Mac online (${t}s)" \
    || fail "the peer lists this Mac online (still $(peer_iz remote list --json | report machine-state "$LOCAL_ID") after ${t}s)"
# Where the peer reaches this copy: its own device's tailnet address.
LOCAL_IP=$(peer_iz remote list --json | python3 -I -c 'import json,sys; ms={m["id"]: m for m in json.load(sys.stdin)["machines"]}; print(ms.get(sys.argv[1], {}).get("address") or "")' "$LOCAL_ID")
log "this copy's device is at $LOCAL_IP"
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
# A python pty stands in for a pane: it runs the relay, types a line, and
# prints what came back. The sum proves the shell ran it, not just echoed it.
# peer_relay <home> <mark>: the relay asks the Zetty whose home is <home> to
# dial for it through that Zetty's own Tailscale device.
peer_relay() {
    peer "CFFIXED_USER_HOME=$1 python3 -I - $TEST_BIN attach $LOCAL_IP:$P1 'echo \$(($2+1))zre'" <<<"$RELAY_PY"
}
RELAY_PY=$(cat <<'PY'
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
if line:
    os.write(fd, (line + "\r").encode())
pump(4)
os.kill(pid, signal.SIGTERM)
pump(1)
sys.stdout.write(out.decode("utf-8", "replace"))
PY
)
MARK=$((RANDOM * 7 + 1000))
SUM=$((MARK + 1))
OUT=$(peer_relay "$ROOT" "$MARK")
if printf '%s' "$OUT" | grep -q "${SUM}zre"; then pass "the peer's relay runs a command in this Mac's pane"
else fail "the peer's relay runs a command in this Mac's pane (relay printed: $(printf '%s' "$OUT" | tr -d '\r' | tail -3 | tr '\n' ' '))"; fi
if iz capture --pane "$P1" --lines 40 2>/dev/null | grep -q "^${SUM}zre"; then pass "the command's output is in the pane here"
else fail "the command's output is in the pane here"; fi
t=$(wait_for 5 peer_relays_are 0) && pass "the relay ends with its terminal (${t}s)" || fail "the relay ends with its terminal"

echo "== the viewing screen takes the size"
# zmx gives a session the size of the screen that typed last. Opening a pane
# on the peer takes it without a key typed there (RemoteSizeHandoff): the
# relay's 24x80 reaches the shell, which writes its size on SIGWINCH.
SIZE_FILE=$ROOT/winch-size
iz send --pane "$P1" --enter "trap 'stty size > $SIZE_FILE' WINCH" >/dev/null 2>&1
sleep 1
rm -f "$SIZE_FILE"
size_is() { [ "$(cat "$SIZE_FILE" 2>/dev/null)" = "$1" ]; }
peer "CFFIXED_USER_HOME=$ROOT python3 -I - $TEST_BIN attach $LOCAL_IP:$P1 ''" <<<"$RELAY_PY" >/dev/null &
RELAY_PID=$!
t=$(wait_for 8 size_is "24 80") && pass "opening the pane on the peer gives it the peer's size (${t}s)" \
    || fail "opening the pane on the peer gives it the peer's size (shell saw: $(cat "$SIZE_FILE" 2>/dev/null || echo nothing))"
wait "$RELAY_PID"
wait_for 5 peer_relays_are 0 >/dev/null

echo "== who may connect"
# relay_refused <name> <home> <expected words>: the relay is turned away
# with those words, and nothing it typed ran here.
relay_refused() {
    local mark=$((RANDOM * 7 + 1000))
    local out; out=$(peer_relay "$2" "$mark")
    if printf '%s' "$out" | grep -q "$3" && ! printf '%s' "$out" | grep -q "$((mark + 1))zre" \
        && ! iz capture --pane "$P1" --lines 40 2>/dev/null | grep -q "^$((mark + 1))zre"; then
        pass "$1"
    else
        fail "$1 (relay printed: $(printf '%s' "$out" | tr -d '\r' | tail -2 | tr '\n' ' '))"
    fi
}
peer "rm -rf $ROOT-nozetty && mkdir -p $ROOT-nozetty"
relay_refused "a relay with no Zetty to dial for it says so" "$ROOT-nozetty" "isn't running on this Mac"
peer "rm -rf $ROOT-nozetty"
# A client through the peer Mac's own Tailscale device, as a container, a VM
# or a second macOS user there would connect: Glen's machine, not a Zetty.
peer_client() {
    peer "ZRE_PROTO=$PROTO python3 -I - $LOCAL_IP $PORT" <<'PY'
import json, os, socket, struct, sys
host, port = sys.argv[1], int(sys.argv[2])
def read(conn):
    head = conn.recv(4, socket.MSG_WAITALL)
    if len(head) < 4: return None
    return json.loads(conn.recv(struct.unpack(">I", head)[0], socket.MSG_WAITALL))
try:
    conn = socket.create_connection((host, port), timeout=10)
    answer = read(conn)
    print(answer.get("type") if answer else "closed", (answer or {}).get("reason", ""))
except Exception as error:
    print("unreachable", error)
PY
}
answer=$(peer_client)
case $answer in
    "refused "*"isn't a Zetty"*) pass "a client through the peer Mac's own Tailscale device is refused: ${answer#refused }" ;;
    *) fail "a client through the peer Mac's own Tailscale device is refused (got: $answer)" ;;
esac

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

    echo "== leaving and coming back"
    before=$(peer_relay_pids)
    peer_iz remote close >/dev/null
    sleep 2
    after=$(peer_relay_pids)
    [ -n "$before" ] && [ "$after" = "$before" ] && pass "leaving the view keeps its panes connected" \
        || fail "leaving the view keeps its panes connected (relays $before -> $after)"
    peer_iz remote open "$LOCAL_ID" e2e-work >/dev/null
    sleep 2
    again=$(peer_relay_pids)
    [ "$again" = "$before" ] && pass "coming back shows them without reconnecting" \
        || fail "coming back shows them without reconnecting (relays $before -> $again)"
    peer_iz remote close >/dev/null
else
    fail "the peer opens this Mac's project: $(peer_iz remote open "$LOCAL_ID" e2e-work 2>&1)"
fi

echo "== this Mac goes"
iz quit --kill-sessions --force >/dev/null 2>&1
t=$(wait_for 20 peer_state_is "$LOCAL_ID" offline) && log "the peer saw this Mac go (${t}s)"
t=$(wait_for 5 peer_relays_are 0) && pass "panes kept out of view end once this Mac goes (${t}s)" \
    || fail "panes kept out of view end once this Mac goes (have $(peer_relays))"
# Its ephemeral device signed out as it quit, so it leaves the tailnet and
# the peer's sidebar.
peer_gone() { [ "$(peer_iz remote list --json | report lists "$LOCAL_ID")" = no ]; }
t=$(wait_for 40 peer_gone) && pass "a copy that quit leaves the peer's sidebar (${t}s)" \
    || fail "a copy that quit leaves the peer's sidebar (still $(peer_iz remote list --json | report machine-state "$LOCAL_ID"))"

echo "== $FAILS failed"
echo "Not covered here: the sidebar's look."
exit "$FAILS"
