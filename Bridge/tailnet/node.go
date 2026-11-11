package main

import (
	"context"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// signOut signs s out of Tailscale and keeps host as the name its next
// sign-in uses. Tailscale's Logout deletes the signed-in profile, and the
// fresh one it switches to has no hostname, so without this the next
// sign-in joins under the Mac's own name, which other Zettys refuse.
func signOut(ctx context.Context, s *tsnet.Server, host string) error {
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	if err := lc.Logout(ctx); err != nil {
		return err
	}
	return setHostname(ctx, s, host)
}

// setHostname names the node, now and for its next sign-in.
func setHostname(ctx context.Context, s *tsnet.Server, host string) error {
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	_, err = lc.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{Hostname: host}, HostnameSet: true})
	return err
}
