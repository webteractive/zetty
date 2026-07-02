import Foundation

/// The shared hook helper quertty installs at `~/.quertty/hooks/quertty-hook.py`.
///
/// Written in Python (reliably present; Claude/Hermes/Codex all run in
/// Python-capable environments) so it can robustly read `cwd` from the harness's
/// JSON payload. Two invocation modes:
///
///   quertty-hook.py emit <agent> <event>       # Claude & Hermes: cwd from stdin JSON
///   quertty-hook.py codex <original-notify...>  # Codex: cwd from its JSON (last arg),
///                                               # then chains to the wrapped notify program
public enum AgentHookScript {
    public static let fileName = "quertty-hook.py"

    public static let contents = ##"""
    #!/usr/bin/env python3
    # quertty agent hook — appends {cwd, agent, event} to the event sink.
    # Only reports sessions hosted INSIDE Zetty (ZETTY=1; legacy QUERTTY=1 also
    # panes' environment, so hooks fired from other terminals stay silent.
    import sys, os, json

    SINK = os.path.expanduser("~/.zetty/agent-events.jsonl")
    IN_ZETTY = bool(os.environ.get("ZETTY") or os.environ.get("QUERTTY"))

    def emit(cwd, agent, event):
        if not IN_ZETTY:
            return
        os.makedirs(os.path.dirname(SINK), exist_ok=True)
        with open(SINK, "a") as f:
            f.write(json.dumps({"cwd": cwd, "agent": agent, "event": event}) + "\n")

    def stdin_cwd():
        try:
            data = sys.stdin.read()
            obj = json.loads(data) if data.strip() else {}
            if isinstance(obj, dict) and obj.get("cwd"):
                return obj["cwd"]
        except Exception:
            pass
        return os.environ.get("PWD") or os.getcwd()

    args = sys.argv[1:]
    mode = args[0] if args else ""

    if mode == "emit":
        agent = args[1] if len(args) > 1 else "?"
        event = args[2] if len(args) > 2 else "running"
        emit(stdin_cwd(), agent, event)
    elif mode == "codex":
        # Codex appends its JSON payload as the final arg; the rest is the
        # original notify command to chain to.
        rest = args[1:]
        cwd = os.environ.get("PWD") or os.getcwd()
        if rest:
            try:
                obj = json.loads(rest[-1])
                if isinstance(obj, dict) and obj.get("cwd"):
                    cwd = obj["cwd"]
            except Exception:
                pass
        emit(cwd, "codex", "idle")
        if rest:
            try:
                os.execvp(rest[0], rest)
            except Exception:
                pass
    """##
}
