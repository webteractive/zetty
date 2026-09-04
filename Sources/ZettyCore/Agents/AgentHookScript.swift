import Foundation

/// The shared hook helper Zetty installs at `~/.zetty/hooks/zetty-hook.py`.
///
/// Emits `{cwd, agent, event}` plus, when available, `surface` (the pane, from
/// `ZETTY_SURFACE` or the `ZETTY_CWD_FILE` stem) and `session` (the harness's
/// own session id — Claude `session_id`, Codex `thread-id`), which is what
/// restart recovery resumes and what routes an event to one exact pane.
///
/// Written in Python (reliably present; Claude/Hermes/Codex all run in
/// Python-capable environments) so it can robustly read `cwd` from the harness's
/// JSON payload. Two invocation modes:
///
///   zetty-hook.py emit <agent> <event>       # Claude & Hermes: cwd from stdin JSON
///   zetty-hook.py codex <original-notify...>  # Codex: cwd from its JSON (last arg),
///                                               # then chains to the wrapped notify program
public enum AgentHookScript {
    public static let fileName = "zetty-hook.py"

    public static let contents = ##"""
    #!/usr/bin/env python3
    # Zetty agent hook — appends {cwd, agent, event, surface?, session?} to the
    # event sink. Only reports sessions hosted INSIDE Zetty: Zetty sets ZETTY=1
    # in its panes' environment, so hooks fired from other terminals stay silent.
    import sys, os, json

    SINK = os.path.expanduser("~/.zetty/agent-events.jsonl")
    IN_ZETTY = bool(os.environ.get("ZETTY"))

    def surface_id():
        # ZETTY_SURFACE is injected per pane; ZETTY_CWD_FILE (<panes>/<uuid>.cwd)
        # predates it and covers preserved sessions created before it existed.
        explicit = os.environ.get("ZETTY_SURFACE")
        if explicit:
            return explicit
        cwd_file = os.environ.get("ZETTY_CWD_FILE")
        if cwd_file:
            stem = os.path.basename(cwd_file)
            if stem.endswith(".cwd"):
                return stem[:-4]
        return None

    def emit(cwd, agent, event, session=None):
        if not IN_ZETTY:
            return
        record = {"cwd": cwd, "agent": agent, "event": event}
        surface = surface_id()
        if surface:
            record["surface"] = surface
        if session:
            record["session"] = str(session)
        os.makedirs(os.path.dirname(SINK), exist_ok=True)
        with open(SINK, "a") as f:
            f.write(json.dumps(record) + "\n")

    def stdin_payload():
        try:
            data = sys.stdin.read()
            obj = json.loads(data) if data.strip() else {}
            return obj if isinstance(obj, dict) else {}
        except Exception:
            return {}

    args = sys.argv[1:]
    mode = args[0] if args else ""

    if mode == "emit":
        agent = args[1] if len(args) > 1 else "?"
        event = args[2] if len(args) > 2 else "running"
        payload = stdin_payload()
        cwd = payload.get("cwd") or os.environ.get("PWD") or os.getcwd()
        emit(cwd, agent, event, payload.get("session_id"))
    elif mode == "codex":
        # Codex appends its JSON payload as the final arg; anything before it
        # is the original notify command to chain to.
        rest = args[1:]
        cwd = os.environ.get("PWD") or os.getcwd()
        session = None
        if rest:
            try:
                obj = json.loads(rest[-1])
                if isinstance(obj, dict):
                    cwd = obj.get("cwd") or cwd
                    session = obj.get("thread-id")
            except Exception:
                pass
        emit(cwd, "codex", "idle", session)
        chain = rest[:-1]
        if chain:
            try:
                os.execvp(chain[0], rest)
            except Exception:
                pass
    """##
}
