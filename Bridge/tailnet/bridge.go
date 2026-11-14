// Package main is Zetty's bridge to an embedded Tailscale node (tsnet),
// built as a C archive and linked into the app. See
// include/zetty_tailnet.h for the C API and
// .hydra/rules/remote-machines.md for how Zetty uses it.
package main

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void (*zt_state_cb)(const char *json);
typedef void (*zt_persist_cb)(const uint8_t *blob, size_t len);
typedef void (*zt_log_cb)(const char *line);

static zt_state_cb zt_state_fn;
static zt_persist_cb zt_persist_fn;
static zt_log_cb zt_log_fn;

static void zt_set_callbacks(zt_state_cb s, zt_persist_cb p, zt_log_cb l) {
	zt_state_fn = s; zt_persist_fn = p; zt_log_fn = l;
}
static void zt_call_state(const char *json) { if (zt_state_fn) zt_state_fn(json); }
static void zt_call_persist(const uint8_t *blob, size_t len) { if (zt_persist_fn) zt_persist_fn(blob, len); }
static void zt_call_log(const char *line) { if (zt_log_fn) zt_log_fn(line); }
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

var (
	mu        sync.Mutex
	server    *tsnet.Server
	nodeName  string // the node's name: from zt_start, then each rename
	store     *blobStore
	cancel    context.CancelFunc
	listeners = map[int]net.Listener{}
	nextID    int
)

// result hands a call's own error back through errOut (freed with
// zt_free; errOut may be NULL): -1 with it set, or 0. Per call, so two
// threads never read each other's error.
func result(errOut **C.char, err error) C.int {
	if err == nil {
		return 0
	}
	if errOut != nil {
		*errOut = C.CString(err.Error())
	}
	return -1
}

func logLine(format string, args ...any) {
	line := C.CString(fmt.Sprintf(format, args...))
	C.zt_call_log(line)
	C.free(unsafe.Pointer(line))
}

func current() (*tsnet.Server, error) {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return nil, errors.New("the Tailscale node isn't running")
	}
	return server, nil
}

//export zt_prepare_env
func zt_prepare_env() {
	// No logs leave the Mac, and a peer that vanishes without a FIN is
	// dropped by keepalive in under a minute instead of two hours.
	//
	// These go through libc setenv, so they must run before the app's first
	// pane: libghostty copies environ once in ghostty_init and reads that
	// copy for every later pane, and a setenv afterwards can move the array
	// out from under it. zt_start used to set them on a background queue at
	// launch, racing the first pane; the laptop crashed in
	// ghostty_surface_new when the pane won.
	envknob.SetNoLogsNoSupport()
	envknob.Setenv("TS_NETSTACK_KEEPALIVE_IDLE", "10s")
	envknob.Setenv("TS_NETSTACK_KEEPALIVE_INTERVAL", "3s")
}

//export zt_start
func zt_start(dir, hostname, authkey *C.char, ephemeral C.int, blob *C.uint8_t, blobLen C.size_t,
	stateCB C.zt_state_cb, persistCB C.zt_persist_cb, logCB C.zt_log_cb, errOut **C.char) C.int {
	mu.Lock()
	if server != nil {
		mu.Unlock()
		return result(errOut, errors.New("already started"))
	}
	mu.Unlock()

	C.zt_set_callbacks(stateCB, persistCB, logCB)

	var initial []byte
	if blob != nil && blobLen > 0 {
		initial = C.GoBytes(unsafe.Pointer(blob), C.int(blobLen))
	}
	var persist func([]byte)
	if ephemeral == 0 {
		persist = func(b []byte) {
			if len(b) == 0 {
				return
			}
			C.zt_call_persist((*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(len(b)))
		}
	}
	st, err := newBlobStore(initial, persist)
	if err != nil {
		return result(errOut, fmt.Errorf("the saved Tailscale state is unreadable (%w); click Sign Out to sign in again", err))
	}

	s := &tsnet.Server{
		Dir:       C.GoString(dir),
		Hostname:  C.GoString(hostname),
		Store:     st,
		Ephemeral: ephemeral != 0,
		// The backend's own log (Logf) is verbose debugging and stays off;
		// the lines meant for people (UserLogf) go to Zetty's log.
		UserLogf: func(f string, a ...any) { logLine(f, a...) },
	}
	if authkey != nil {
		s.AuthKey = C.GoString(authkey)
	}
	if err := s.Start(); err != nil {
		return result(errOut, err)
	}
	ctx, stop := context.WithCancel(context.Background())
	mu.Lock()
	server, store, cancel = s, st, stop
	nodeName = s.Hostname
	mu.Unlock()
	go watch(ctx, s)
	return 0
}

// stateEvent is what zt_state_cb receives.
type stateEvent struct {
	State   string `json:"state"`
	AuthURL string `json:"authURL,omitempty"`
	Error   string `json:"error,omitempty"`
	// Browse: Tailscale asks for AuthURL to be opened now (after a sign-in
	// request). Only then is it known to be fresh.
	Browse bool `json:"browse,omitempty"`
}

func emit(ev stateEvent) {
	b, _ := json.Marshal(ev)
	cs := C.CString(string(b))
	C.zt_call_state(cs)
	C.free(unsafe.Pointer(cs))
}

// watch reports every backend change (and every new login URL) until stop.
func watch(ctx context.Context, s *tsnet.Server) {
	lc, err := s.LocalClient()
	if err != nil {
		emit(stateEvent{State: "NoState", Error: err.Error()})
		return
	}
	for ctx.Err() == nil {
		w, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
		if err != nil {
			time.Sleep(time.Second)
			continue
		}
		for {
			n, err := w.Next()
			if err != nil {
				break
			}
			if n.State == nil && n.BrowseToURL == nil && n.ErrMessage == nil {
				continue
			}
			ev := stateEvent{}
			if st, err := lc.StatusWithoutPeers(ctx); err == nil {
				ev.State = st.BackendState
				ev.AuthURL = st.AuthURL
			}
			if n.State != nil {
				ev.State = n.State.String()
			}
			if n.BrowseToURL != nil && *n.BrowseToURL != "" {
				ev.AuthURL = *n.BrowseToURL
				ev.Browse = true
			}
			if n.ErrMessage != nil {
				ev.Error = *n.ErrMessage
			}
			emit(ev)
		}
		w.Close()
	}
}

//export zt_stop
func zt_stop() {
	mu.Lock()
	s, stop := server, cancel
	server, store, cancel = nil, nil, nil
	for id, l := range listeners {
		l.Close()
		delete(listeners, id)
	}
	mu.Unlock()
	if stop != nil {
		stop()
	}
	if s != nil {
		// An ephemeral test node leaves the tailnet now rather than when the
		// control server notices it's gone.
		if s.Ephemeral {
			if lc, err := s.LocalClient(); err == nil {
				ctx, done := context.WithTimeout(context.Background(), 3*time.Second)
				lc.Logout(ctx)
				done()
			}
		}
		s.Close()
	}
}

func withLocal(errOut **C.char, timeout time.Duration, f func(ctx context.Context, s *tsnet.Server) error) C.int {
	s, err := current()
	if err != nil {
		return result(errOut, err)
	}
	ctx, done := context.WithTimeout(context.Background(), timeout)
	defer done()
	return result(errOut, f(ctx, s))
}

//export zt_login
func zt_login(errOut **C.char) C.int {
	return withLocal(errOut, 10*time.Second, func(ctx context.Context, s *tsnet.Server) error {
		lc, err := s.LocalClient()
		if err != nil {
			return err
		}
		return lc.StartLoginInteractive(ctx)
	})
}

//export zt_logout
func zt_logout(errOut **C.char) C.int {
	// Logout deletes the signed-in profile and saves that through the store;
	// the machine key stays, so signing in again is the same machine, under
	// the same zetty- name (signOut).
	mu.Lock()
	host := nodeName
	mu.Unlock()
	return withLocal(errOut, 15*time.Second, func(ctx context.Context, s *tsnet.Server) error {
		return signOut(ctx, s, host)
	})
}

//export zt_set_hostname
func zt_set_hostname(name *C.char, errOut **C.char) C.int {
	host := C.GoString(name)
	return withLocal(errOut, 10*time.Second, func(ctx context.Context, s *tsnet.Server) error {
		if err := setHostname(ctx, s, host); err != nil {
			return err
		}
		mu.Lock()
		nodeName = host
		mu.Unlock()
		return nil
	})
}

// jsonOut is v as JSON, or NULL when the read failed (the caller keeps
// its last answer; nothing to report).
func jsonOut(v any, err error) *C.char {
	if err != nil {
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return C.CString(string(b))
}

//export zt_status_json
func zt_status_json() *C.char {
	s, err := current()
	if err != nil {
		return nil
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil
	}
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	return jsonOut(lc.Status(ctx))
}

//export zt_whois_json
func zt_whois_json(addr *C.char) *C.char {
	s, err := current()
	if err != nil {
		return nil
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil
	}
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	return jsonOut(lc.WhoIs(ctx, C.GoString(addr)))
}

//export zt_listen
func zt_listen(port C.uint16_t, errOut **C.char) C.int {
	s, err := current()
	if err != nil {
		return result(errOut, err)
	}
	l, err := s.Listen("tcp", ":"+strconv.Itoa(int(port)))
	if err != nil {
		return result(errOut, err)
	}
	mu.Lock()
	nextID++
	id := nextID
	listeners[id] = l
	mu.Unlock()
	return C.int(id)
}

// zt_accept blocks until a connection arrives, then returns a descriptor
// for it and writes the peer's "ip:port" into remote. -1 once closed.
//
//export zt_accept
func zt_accept(id C.int, remote *C.char, remoteLen C.size_t) C.int {
	mu.Lock()
	l := listeners[int(id)]
	mu.Unlock()
	if l == nil {
		return -1
	}
	for {
		conn, err := l.Accept()
		if err != nil {
			return -1
		}
		fd, err := splice(conn)
		if err != nil {
			continue
		}
		addr := conn.RemoteAddr().String()
		if remote != nil && remoteLen > 0 {
			n := len(addr)
			if n > int(remoteLen)-1 {
				n = int(remoteLen) - 1
			}
			buf := unsafe.Slice((*byte)(unsafe.Pointer(remote)), int(remoteLen))
			copy(buf, addr[:n])
			buf[n] = 0
		}
		return C.int(fd)
	}
}

//export zt_close_listener
func zt_close_listener(id C.int) {
	mu.Lock()
	l := listeners[int(id)]
	delete(listeners, int(id))
	mu.Unlock()
	if l != nil {
		l.Close()
	}
}

//export zt_dial
func zt_dial(ip *C.char, port C.uint16_t, timeoutMS C.int, errOut **C.char) C.int {
	s, err := current()
	if err != nil {
		return result(errOut, err)
	}
	ctx, done := context.WithTimeout(context.Background(), time.Duration(timeoutMS)*time.Millisecond)
	defer done()
	conn, err := s.Dial(ctx, "tcp", net.JoinHostPort(C.GoString(ip), strconv.Itoa(int(port))))
	if err != nil {
		return result(errOut, err)
	}
	fd, err := splice(conn)
	if err != nil {
		return result(errOut, err)
	}
	return C.int(fd)
}

//export zt_free
func zt_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
