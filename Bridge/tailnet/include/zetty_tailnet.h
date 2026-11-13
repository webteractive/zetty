// Zetty's embedded Tailscale node (Bridge/tailnet, built as a C archive by
// scripts/build-tailnet-bridge.sh). Every call may block on the network:
// never call one on the main thread. Returned strings are freed with zt_free.
// A call that can fail returns -1 and, when `err` isn't NULL, sets *err to
// its own error text (free it with zt_free).
#ifndef ZETTY_TAILNET_H
#define ZETTY_TAILNET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// {"state":"NeedsLogin|NeedsMachineAuth|Starting|Running|Stopped|NoState","authURL":"…","error":"…",
///  "browse":true} — browse: Tailscale asks for authURL to be opened now.
typedef void (*zt_state_cb)(const char *json);
/// The node's whole state map, JSON. Keep it somewhere safe (the Keychain).
typedef void (*zt_persist_cb)(const uint8_t *blob, size_t len);
typedef void (*zt_log_cb)(const char *line);

/// Sets the process environment the node needs. Call once at launch, before
/// the first pane exists (it calls setenv), and before zt_start. Doesn't block.
void zt_prepare_env(void);
/// Starts the node. `authkey` may be NULL. `ephemeral` != 0 keeps state in
/// memory only (persist is never called). 0 on success.
int zt_start(char *dir, char *hostname, char *authkey, int ephemeral,
             uint8_t *blob, size_t blobLen,
             zt_state_cb stateCB, zt_persist_cb persistCB, zt_log_cb logCB, char **err);
void zt_stop(void);
int zt_login(char **err);
int zt_logout(char **err);
int zt_set_hostname(char *name, char **err);
/// ipnstate.Status JSON, or NULL.
char *zt_status_json(void);
/// apitype.WhoIsResponse JSON for "ip:port", or NULL when unknown.
char *zt_whois_json(char *addr);
/// A listener id (> 0), or -1.
int zt_listen(uint16_t port, char **err);
/// Blocks for the next connection: a descriptor, and the peer's "ip:port"
/// in `remote`. -1 once the listener is closed.
int zt_accept(int id, char *remote, size_t remoteLen);
void zt_close_listener(int id);
/// A connected descriptor, or -1.
int zt_dial(char *ip, uint16_t port, int timeoutMS, char **err);
void zt_free(char *p);

#ifdef __cplusplus
}
#endif

#endif
