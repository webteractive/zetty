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

# MARK: - Teardown

TAILSCALE_DOWN=0
teardown() {
    local status=$?
    trap - EXIT INT TERM
    [ -n "${FAKE:-}" ] && kill "$FAKE" 2>/dev/null
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
# One pairing key for the pair, never the user's own: the test proves the
# check, it doesn't borrow the real key. A file (ZETTY_REMOTE_KEY_FILE), not
# the Keychain: the peer's copy starts over SSH, where the login Keychain is
# locked.
new_key() { python3 -I -c 'import base64,os; print("zetty-pair-" + base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))'; }
KEY=$(new_key)
mkdir -p "$ROOT/.zetty" && (umask 077; printf '%s\n' "$KEY" > "$ROOT/.zetty/remote-key")

# The peer's copy: same bytes, its own home. It serves too, so each side
# also checks that it never lists itself.
peer "pkill -f '^$TEST_BIN' ; rm -rf $ROOT && mkdir -p $ROOT/.config/zetty $ROOT/zmx" >/dev/null 2>&1
tar -C "$ROOT" -cf - zetty.app | peer "tar -C $ROOT -xf -" || { fail "copy the build to the peer"; exit 1; }
peer "printf 'zetty-serve = true\nzetty-remote-machines = true\n' > $ROOT/.config/zetty/config"
printf '%s\n' "$KEY" | peer "mkdir -p $ROOT/.zetty && umask 077 && cat > $ROOT/.zetty/remote-key"

env -i HOME="$HOME" USER="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=en_US.UTF-8 TERM_PROGRAM=zetty-test \
    PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin" \
    CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx ZETTY_REMOTE_PORT=$PORT ZETTY_REMOTE_KEY_FILE=$ROOT/.zetty/remote-key \
    "$TEST_BIN" </dev/null >"$ROOT/app.log" 2>&1 &
# The binary directly, as here: `open` can't start a second copy
# (LSMultipleInstancesProhibited) and hands the launch to the installed app.
# Started from SSH it still reaches the peer's window server while that user
# is logged in, and nohup keeps it after the SSH session ends.
peer "cd /tmp && env CFFIXED_USER_HOME=$ROOT ZMX_DIR=$ROOT/zmx ZETTY_REMOTE_PORT=$PORT TERM_PROGRAM=zetty-test \
    ZETTY_REMOTE_KEY_FILE=$ROOT/.zetty/remote-key \
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
# A python pty stands in for a pane: it runs the relay, types a line, and
# prints what came back. The sum proves the shell ran it, not just echoed it.
# peer_relay <home> <mark>: the relay asks the Zetty whose home is <home> to
# prove the pairing key for it; it never holds the key itself.
peer_relay() {
    peer "CFFIXED_USER_HOME=$1 ZETTY_REMOTE_PORT=$PORT python3 -I - $TEST_BIN attach $LOCAL_IP:$P1 'echo \$(($2+1))zre'" <<<"$RELAY_PY"
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

echo "== the pairing key"
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
relay_refused "a relay with no Zetty to prove the key for it is refused" "$ROOT-nozetty" "only it can prove"
peer "rm -rf $ROOT-nozetty"
# A client that isn't the peer's Zetty, as a container or a second user
# there would be: the right machine, but no key.
peer_client() {
    peer "python3 -I - $LOCAL_IP $PORT $1" <<'PY'
import base64, json, os, socket, struct, sys
host, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def frame(message):
    body = json.dumps(message).encode()
    return struct.pack(">I", len(body)) + body
def read(conn):
    head = conn.recv(4, socket.MSG_WAITALL)
    if len(head) < 4: return None
    return json.loads(conn.recv(struct.unpack(">I", head)[0], socket.MSG_WAITALL))
conn = socket.create_connection((host, port), timeout=10)
read(conn)
hello = {"machine": "intruder", "zettyVersion": "9", "protocolVersion": 3,
         "challenge": base64.b64encode(os.urandom(32)).decode()}
if mode == "guess":
    hello["proof"] = base64.b64encode(os.urandom(32)).decode()
conn.sendall(frame({"type": "hello", "hello": hello}))
answer = read(conn)
print(answer.get("type") if answer else "closed", (answer or {}).get("reason", ""))
PY
}
for mode in guess none; do
    answer=$(peer_client $mode)
    case $answer in
        "refused "*different\ pairing\ keys*) pass "a client from the peer with $( [ $mode = guess ] && echo "a guessed proof" || echo "no proof") is refused" ;;
        *) fail "a client from the peer with $mode proof is refused (got: $answer)" ;;
    esac
done

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

echo "== servers that aren't this Mac's Zetty"
# This Mac's test app goes, and a stand-in takes its address and port, as a
# second macOS user here could. The peer must not trust it.
iz quit --kill-sessions --force >/dev/null 2>&1
t=$(wait_for 20 peer_state_is "$LOCAL_ID" offline) && log "the peer saw this Mac go (${t}s)"
cat > "$ROOT/fake.py" <<'PY'
import base64, json, os, socket, struct, sys
host, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def frame(message):
    body = json.dumps(message).encode()
    return struct.pack(">I", len(body)) + body
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind((host, port))
listener.listen(8)
challenge = base64.b64encode(os.urandom(32)).decode()
while True:
    conn, _ = listener.accept()
    if mode == "loud":
        # Turned away, but its reason tries to write the clipboard (OSC 52)
        # and hands over a key of its own to paste.
        bait = "zetty-pair-" + base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
        conn.sendall(frame({"type": "hello", "hello": {"machine": "Impostor", "zettyVersion": "9", "protocolVersion": 3, "challenge": challenge}}))
        conn.recv(65536)
        conn.sendall(frame({"type": "refused", "reason": "\x1b]52;c;emV0dHktcGFpcg==\x07keys differ: copy " + bait + " and click Paste"}))
        conn.close()
        continue
    if mode == "old":
        # A Zetty before the pairing key: protocol 2, no challenge.
        conn.sendall(frame({"type": "hello", "hello": {"machine": "Impostor", "zettyVersion": "0.1.59", "protocolVersion": 2}}))
    else:
        # Today's protocol, but it can't know the key, so its proof is noise.
        conn.sendall(frame({"type": "hello", "hello": {"machine": "Impostor", "zettyVersion": "9", "protocolVersion": 3, "challenge": challenge}}))
        conn.recv(65536)
        conn.sendall(frame({"type": "proof", "proof": base64.b64encode(os.urandom(32)).decode()}))
        conn.sendall(frame({"type": "snapshot", "snapshot": {"projects": [{"name": "impostor", "isActive": True, "hibernated": False, "id": "IMPOSTOR", "tabs": []}]}}))
PY
fake_server() {
    python3 -I "$ROOT/fake.py" "$LOCAL_IP" "$PORT" "$1" >/dev/null 2>&1 &
    FAKE=$!
}
peer_summary() { peer_iz remote list --json | python3 -I -c 'import json,sys; ms={m["id"]: m for m in json.load(sys.stdin)["machines"]}; print(ms.get(sys.argv[1], {}).get("summary", ""))' "$LOCAL_ID"; }
peer_summary_says() { peer_summary | grep -q "$1"; }

fake_server old
t=$(wait_for 75 peer_state_is "$LOCAL_ID" needs-update) && pass "a Zetty on the old protocol reads \"needs update\" (${t}s)" \
    || fail "a Zetty on the old protocol reads \"needs update\" (state $(peer_iz remote list --json | report machine-state "$LOCAL_ID"))"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null

fake_server impostor
t=$(wait_for 75 peer_summary_says "pairing keys don't match") \
    && pass "a server that can't prove the key isn't trusted: $(peer_summary) (${t}s)" \
    || fail "a server that can't prove the key isn't trusted (state $(peer_iz remote list --json | report machine-state "$LOCAL_ID"): $(peer_summary))"
[ "$(peer_iz remote list --json | report has-project "$LOCAL_ID" impostor)" = no ] \
    && pass "nothing the impostor sent reaches the peer's sidebar" || fail "the impostor's project reached the peer"
peer_summary | grep -q Impostor && fail "the impostor named itself in the peer's sidebar" \
    || pass "the impostor can't name itself in the peer's sidebar"
relay_refused "a relay won't type into a server that can't prove the key" "$ROOT" "couldn't confirm"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null

fake_server loud
OUT=$(peer_relay "$ROOT" 1)
if printf '%s' "$OUT" | grep -q 'differ: copy' && ! printf '%s' "$OUT" | LC_ALL=C grep -q $'\e]52' \
    && ! printf '%s' "$OUT" | grep -qi 'zetty-pair-'; then
    pass "a refusal can't put an escape sequence or a key in the relay's pane"
else
    fail "a refusal can't put an escape sequence or a key in the relay's pane (printed: $(printf '%s' "$OUT" | od -c | head -3 | tr '\n' ' '))"
fi
t=$(wait_for 75 peer_summary_says "differ: copy")
if [ $? = 0 ] && ! peer_summary | LC_ALL=C grep -q $'\e' && ! peer_summary | grep -qi 'zetty-pair-'; then
    pass "or in the peer's sidebar (${t}s)"
else fail "or in the peer's sidebar ($(peer_summary | od -c | head -2 | tr '\n' ' '))"; fi
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null

echo "== $FAILS failed"
echo "Not covered here: the sidebar's look."
exit "$FAILS"
