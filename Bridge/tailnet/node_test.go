package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/tsnet"
)

// Signing out deletes Tailscale's signed-in profile, and the fresh one it
// starts has no hostname: without signOut putting it back, the next sign-in
// joins under the Mac's own name, which other Zettys refuse (Glen's Mac mini
// came back as "hadefication-mini", 2026-11-11). Needs a reusable,
// ephemeral auth key: go test -tags ts_omit_peerapiserver,ts_omit_logtail
// with ZETTY_E2E_TAILSCALE_AUTH_KEY set (warden --global).
func TestSignOutKeepsTheZettyName(t *testing.T) {
	key := os.Getenv("ZETTY_E2E_TAILSCALE_AUTH_KEY")
	if key == "" {
		t.Skip("ZETTY_E2E_TAILSCALE_AUTH_KEY isn't set")
	}
	suffix := make([]byte, 3)
	rand.Read(suffix)
	host := "zetty-e2e-signout-" + hex.EncodeToString(suffix)

	s := &tsnet.Server{Dir: t.TempDir(), Hostname: host, Store: new(mem.Store), Ephemeral: true, AuthKey: key,
		Logf: func(string, ...any) {}}
	defer s.Close()
	ctx, done := context.WithTimeout(context.Background(), 90*time.Second)
	defer done()
	if _, err := s.Up(ctx); err != nil {
		t.Fatalf("up: %v", err)
	}
	lc, err := s.LocalClient()
	if err != nil {
		t.Fatal(err)
	}

	if err := signOut(ctx, s, host); err != nil {
		t.Fatalf("sign out: %v", err)
	}
	prefs, err := lc.GetPrefs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if prefs.Hostname != host {
		t.Fatalf("after signing out the name is %q, want %q", prefs.Hostname, host)
	}

	// Sign in again (with the key, as a phone approving the page would) and
	// check the name the tailnet sees.
	if err := lc.Start(ctx, ipn.Options{AuthKey: key}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if _, err := lc.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{WantRunning: true}, WantRunningSet: true}); err != nil {
		t.Fatalf("want running: %v", err)
	}
	for {
		st, err := lc.Status(ctx)
		if err == nil && st.BackendState == ipn.Running.String() && st.Self != nil {
			if st.Self.HostName != host {
				t.Fatalf("signed in again as %q, want %q", st.Self.HostName, host)
			}
			break
		}
		select {
		case <-ctx.Done():
			t.Fatalf("never signed in again (last state %v)", st)
		case <-time.After(500 * time.Millisecond):
		}
	}
	lc.Logout(context.Background())
}
