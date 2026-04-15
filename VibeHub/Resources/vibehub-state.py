#!/usr/bin/env python3
"""
Vibe Hub Hook
- Sends session state to Vibe Hub.app via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
import shutil
import socket
import sys

SOCKET_PATH = os.environ.get(
    "VIBEHUB_SOCKET_PATH",
    os.path.expanduser("~/.vibehub/ci.sock"),
)
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def _ensure_dir(path):
    try:
        os.makedirs(path, exist_ok=True)
    except Exception:
        pass


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _write_json(path, obj):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
            f.write("\n")
        return True
    except Exception:
        return False


def _install_claude_hook(socket_path):
    home = os.path.expanduser("~")
    claude_dir = os.path.join(home, ".claude")
    hooks_dir = os.path.join(claude_dir, "hooks")
    settings_path = os.path.join(claude_dir, "settings.json")
    dst_script = os.path.join(hooks_dir, "vibehub-state.py")

    # Persist socket path for other helpers (e.g. OpenCode plugin).
    state_dir = os.path.join(home, ".vibehub")
    _ensure_dir(state_dir)
    try:
        with open(os.path.join(state_dir, "socket-path"), "w", encoding="utf-8") as f:
            f.write(str(socket_path).strip() + "\n")
    except Exception:
        pass

    _ensure_dir(hooks_dir)

    # Copy this script into ~/.claude/hooks
    try:
        shutil.copy2(os.path.abspath(__file__), dst_script)
        os.chmod(dst_script, 0o755)
    except Exception:
        return False

    # Update ~/.claude/settings.json hooks
    data = _read_json(settings_path)
    hooks = data.get("hooks") or {}

    quoted_sock = socket_path.replace('"', '\\"')
    cmd = f'VIBEHUB_SOCKET_PATH="{quoted_sock}" python3 ~/.claude/hooks/vibehub-state.py'
    hook_entry = [{"type": "command", "command": cmd}]
    hook_entry_with_timeout = [{"type": "command", "command": cmd, "timeout": 86400}]

    with_matcher = [{"matcher": "*", "hooks": hook_entry}]
    with_matcher_timeout = [{"matcher": "*", "hooks": hook_entry_with_timeout}]
    without_matcher = [{"hooks": hook_entry}]
    pre_compact = [
        {"matcher": "auto", "hooks": hook_entry},
        {"matcher": "manual", "hooks": hook_entry},
    ]

    hook_events = [
        ("UserPromptSubmit", without_matcher),
        ("PreToolUse", with_matcher),
        ("PostToolUse", with_matcher),
        ("PermissionRequest", with_matcher_timeout),
        ("Notification", with_matcher),
        ("Stop", without_matcher),
        ("SubagentStop", without_matcher),
        ("SessionStart", without_matcher),
        ("SessionEnd", without_matcher),
        ("PreCompact", pre_compact),
    ]

    def _entry_has_our_hook(entry):
        try:
            hs = entry.get("hooks") or []
            for h in hs:
                c = (h.get("command") or "")
                if "vibehub-state.py" in c:
                    return True
        except Exception:
            pass
        return False

    for event, config in hook_events:
        existing = hooks.get(event)
        if isinstance(existing, list):
            if not any(_entry_has_our_hook(e) for e in existing if isinstance(e, dict)):
                existing.extend(config)
                hooks[event] = existing
        else:
            hooks[event] = config

    data["hooks"] = hooks
    return _write_json(settings_path, data)


def _install_opencode_plugin(socket_path):
    home = os.path.expanduser("~")
    opencode_dir = os.path.join(home, ".config", "opencode")
    config_path = os.path.join(opencode_dir, "opencode.json")
    if not os.path.exists(config_path):
        return True

    plugins_dir = os.path.join(opencode_dir, "plugins")
    dst_plugin = os.path.join(plugins_dir, "vibehub.js")
    _ensure_dir(plugins_dir)

    resource_dir = os.path.dirname(os.path.abspath(__file__))
    src_plugin = os.path.join(resource_dir, "vibehub-opencode.js")
    if not os.path.exists(src_plugin):
        return False

    try:
        shutil.copy2(src_plugin, dst_plugin)
        os.chmod(dst_plugin, 0o644)
    except Exception:
        return False

    data = _read_json(config_path)
    plugin_url = "file://" + dst_plugin

    plugins = data.get("plugin")
    if isinstance(plugins, str):
        plugins = [plugins]
    if not isinstance(plugins, list):
        plugins = []
    if plugin_url not in plugins:
        plugins.append(plugin_url)
    data["plugin"] = plugins

    # OpenCode's config schema is strict; do not add unknown keys.
    # Persist the socket path separately for the plugin to read.
    state_dir = os.path.expanduser("~/.vibehub")
    _ensure_dir(state_dir)
    try:
        with open(os.path.join(state_dir, "socket-path"), "w", encoding="utf-8") as f:
            f.write(str(socket_path).strip() + "\n")
    except Exception:
        pass

    return _write_json(config_path, data)


def install_all():
    # Installer mode: targets standard locations (no directory picker).
    socket_path = os.environ.get("VIBEHUB_SOCKET_PATH") or SOCKET_PATH
    ok1 = _install_claude_hook(socket_path)
    ok2 = _install_opencode_plugin(socket_path)
    return ok1 and ok2


def uninstall_all():
    home = os.path.expanduser("~")
    claude_dir = os.path.join(home, ".claude")
    hooks_dir = os.path.join(claude_dir, "hooks")
    settings_path = os.path.join(claude_dir, "settings.json")
    script_path = os.path.join(hooks_dir, "vibehub-state.py")

    try:
        if os.path.exists(script_path):
            os.remove(script_path)
    except Exception:
        pass

    data = _read_json(settings_path)
    hooks = data.get("hooks")
    if isinstance(hooks, dict):
        for event in list(hooks.keys()):
            entries = hooks.get(event)
            if not isinstance(entries, list):
                continue
            new_entries = []
            for entry in entries:
                if not isinstance(entry, dict):
                    new_entries.append(entry)
                    continue
                hs = entry.get("hooks")
                if isinstance(hs, list) and any("vibehub-state.py" in (h.get("command") or "") for h in hs if isinstance(h, dict)):
                    continue
                new_entries.append(entry)
            if new_entries:
                hooks[event] = new_entries
            else:
                hooks.pop(event, None)
        if hooks:
            data["hooks"] = hooks
        else:
            data.pop("hooks", None)
        _write_json(settings_path, data)

    # OpenCode: remove plugin file only (config cleanup is best-effort).
    opencode_plugin = os.path.join(home, ".config", "opencode", "plugins", "vibehub.js")
    try:
        if os.path.exists(opencode_plugin):
            os.remove(opencode_plugin)
    except Exception:
        pass

    return True


def probe_tiocsti():
    """Check whether TIOCSTI ioctl is available (blocked on macOS Ventura+)."""
    try:
        import fcntl, termios, struct, pty
        m, s = pty.openpty()
        try:
            fcntl.ioctl(s, termios.TIOCSTI, struct.pack('B', 0))
            return True
        except Exception:
            return False
        finally:
            os.close(m)
            os.close(s)
    except Exception:
        return False


def get_tty():
    """Get the TTY by walking up the process tree until a process with a TTY is found."""
    import subprocess

    pid = os.getppid()
    for _ in range(20):
        if pid <= 1:
            break
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "tty=,ppid="],
                capture_output=True,
                text=True,
                timeout=2
            )
            parts = result.stdout.strip().split()
            if not parts:
                break
            tty = parts[0]
            if tty and tty != "??" and tty != "-":
                if not tty.startswith("/dev/"):
                    tty = "/dev/" + tty
                return tty
            # No TTY on this process, walk up to parent
            if len(parts) >= 2:
                pid = int(parts[1])
            else:
                break
        except Exception:
            break
    return None


def _do_send(sock, state):
    """Send state over an already-connected socket; return response or None."""
    sock.sendall(json.dumps(state).encode())
    if state.get("status") == "waiting_for_approval":
        response = sock.recv(4096)
        if response:
            return json.loads(response.decode())
    return None


def send_event(state):
    """Send event to app via Unix socket, return response if any."""
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        return _do_send(sock, state)
    except (socket.error, OSError, json.JSONDecodeError):
        return None
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass


def _jsonl_path_for(session_id, cwd):
    """Return the JSONL file path for SOURCE's project layout, or None."""
    projects_rel = SOURCE_JSONL_PROJECTS.get(SOURCE)
    if not projects_rel:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    return os.path.join(home, projects_rel, project_dir, f"{session_id}.jsonl")


def get_session_title(session_id, cwd):
    try:
        jsonl_path = _jsonl_path_for(session_id, cwd)
        if not jsonl_path or not os.path.exists(jsonl_path):
            return None
        
        first_user_message = None
        summary = None
        
        with open(jsonl_path, "r", encoding="utf-8") as f:
            for line in f:
                if not line.strip(): continue
                try:
                    data = json.loads(line)
                    msg_type = data.get("type")
                    role = data.get("role")
                    content = data.get("content")
                    
                    if isinstance(content, str):
                        if msg_type == "summary":
                            summary = content
                        if role == "user" and not first_user_message:
                            first_user_message = content
                except Exception:
                    pass
                    
        return summary or first_user_message
    except Exception:
        return None

def get_new_jsonl_lines(session_id, cwd):
    try:
        jsonl_path = _jsonl_path_for(session_id, cwd)
        if not jsonl_path or not os.path.exists(jsonl_path):
            return None
        home = os.path.expanduser("~")

        cursor_dir = os.path.join(home, ".vibehub", "cursors")
        _ensure_dir(cursor_dir)
        cursor_path = os.path.join(cursor_dir, f"{session_id}.cursor")
        
        last_pos = 0
        if os.path.exists(cursor_path):
            try:
                with open(cursor_path, "r", encoding="utf-8") as f:
                    last_pos = int(f.read().strip())
            except Exception:
                pass
                
        new_lines = []
        with open(jsonl_path, "r", encoding="utf-8") as f:
            f.seek(0, 2)
            file_size = f.tell()
            
            if file_size < last_pos:
                # File got truncated or rewritten
                last_pos = 0
                
            if file_size == last_pos:
                return []
                
            f.seek(last_pos)
            new_lines = f.readlines()
            new_pos = f.tell()
            
        with open(cursor_path, "w", encoding="utf-8") as f:
            f.write(str(new_pos))
            
        # Strip newlines from the right
        return [line.rstrip("\n") for line in new_lines if line.strip()]
    except Exception:
        return None



def _file_hash():
    """SHA-256 hash (first 16 hex chars) of this script file."""
    import hashlib
    try:
        with open(os.path.abspath(__file__), "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except Exception:
        return "unknown"

# Explicit CLI source. Every CLI's hook command sets this via
# `VIBEHUB_SOURCE=<name>`. When absent we fall back to `.codex/` path
# detection for compatibility with older installs, and finally to "claude".
SOURCE = os.environ.get("VIBEHUB_SOURCE")
if not SOURCE:
    if "/.codex/" in os.path.abspath(__file__):
        SOURCE = "codex"
    else:
        SOURCE = "claude"

# Home-relative projects dir for JSONL-backed sources. Keep in sync with
# `CLIConfig.jsonlProjectsDirRelative` on the Swift side.
SOURCE_JSONL_PROJECTS = {
    "claude": ".claude/projects",
    "qoder": ".qoder/projects",
    "droid": ".factory/projects",
    "codebuddy": ".codebuddy/projects",
}

# Legacy compat. Kept for any call sites below that still branch on it,
# but new code should check SOURCE directly.
IS_CODEX = SOURCE == "codex"


def _query_opencode_db(session_id):
    """Query the OpenCode SQLite database for a session's messages and parts.

    Output shape on stdout (exit 0):
        {"session": {...} | null, "messages": [...], "parts": [...]}

    `message.data` and `part.data` in the DB are JSON text; we forward them
    verbatim as strings so the Swift side can parse them with the same logic
    used for the local SQLite path (avoids double decode + keeps fidelity).

    Errors go to stderr with exit 1. Missing DB / session returns an empty
    payload with exit 0.
    """
    import sqlite3
    db_path = os.path.expanduser("~/.local/share/opencode/opencode.db")
    if not os.path.exists(db_path):
        print(json.dumps({"session": None, "messages": [], "parts": []}))
        return 0
    try:
        conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        cur.execute(
            "SELECT title, directory, time_created FROM session WHERE id = ? LIMIT 1",
            (session_id,),
        )
        row = cur.fetchone()
        session_obj = None
        if row is not None:
            session_obj = {
                "title": row["title"],
                "directory": row["directory"],
                "time_created": row["time_created"],
            }

        cur.execute(
            "SELECT id, data, time_created FROM message "
            "WHERE session_id = ? ORDER BY time_created ASC, id ASC",
            (session_id,),
        )
        messages = [
            {
                "id": r["id"],
                "data": r["data"],
                "time_created": r["time_created"],
            }
            for r in cur.fetchall()
        ]

        cur.execute(
            "SELECT id, message_id, data, time_created FROM part "
            "WHERE session_id = ? ORDER BY time_created ASC, id ASC",
            (session_id,),
        )
        parts = [
            {
                "id": r["id"],
                "message_id": r["message_id"],
                "data": r["data"],
                "time_created": r["time_created"],
            }
            for r in cur.fetchall()
        ]

        conn.close()
        print(json.dumps({
            "session": session_obj,
            "messages": messages,
            "parts": parts,
        }))
        sys.stdout.flush()
        return 0
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 1


def main():
    if "--version" in sys.argv:
        print(_file_hash())
        sys.exit(0)

    if "--opencode-db" in sys.argv:
        idx = sys.argv.index("--opencode-db")
        if idx + 1 >= len(sys.argv):
            print(json.dumps({"error": "missing session id"}), file=sys.stderr)
            sys.exit(2)
        sys.exit(_query_opencode_db(sys.argv[idx + 1]))

    if "--dump-jsonl" in sys.argv:
        # Usage: --dump-jsonl <session_id> <cwd>
        # Prints the full JSONL file to stdout and advances the cursor to
        # end-of-file so subsequent get_new_jsonl_lines() calls don't
        # re-send the content we just dumped. SOURCE comes from the
        # VIBEHUB_SOURCE env var (caller should set it to match the CLI).
        idx = sys.argv.index("--dump-jsonl")
        if idx + 2 >= len(sys.argv):
            print("", end="")
            sys.exit(0)
        sid = sys.argv[idx + 1]
        cwd = sys.argv[idx + 2]
        jsonl_path = _jsonl_path_for(sid, cwd)
        if not jsonl_path or not os.path.exists(jsonl_path):
            sys.exit(0)
        try:
            with open(jsonl_path, "r", encoding="utf-8") as f:
                data = f.read()
                end_pos = f.tell()
            sys.stdout.write(data)
            sys.stdout.flush()
            home = os.path.expanduser("~")
            cursor_dir = os.path.join(home, ".vibehub", "cursors")
            _ensure_dir(cursor_dir)
            cursor_path = os.path.join(cursor_dir, f"{sid}.cursor")
            with open(cursor_path, "w", encoding="utf-8") as f:
                f.write(str(end_pos))
            sys.exit(0)
        except Exception as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    if "--install" in sys.argv:
        ok = install_all()
        print("ok" if ok else "failed")
        sys.exit(0 if ok else 1)

    if "--uninstall" in sys.argv:
        ok = uninstall_all()
        print("ok" if ok else "failed")
        sys.exit(0 if ok else 1)

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    # Preserve the legacy `codex-` prefix so older Swift builds that still
    # rely on sessionId-prefix detection (plus any historical remote hooks)
    # keep behaving. The authoritative source on the new Swift path is the
    # `_source` field below.
    if SOURCE == "codex" and not session_id.startswith("codex-"):
        session_id = "codex-" + session_id
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()
    can_inject_keystrokes = probe_tiocsti()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        "can_inject_keystrokes": can_inject_keystrokes,
        # Explicit CLI source (first-class field consumed by HookEvent._source).
        "_source": SOURCE,
    }

    # Detect multiplexer and report how to reach this session
    cmux_workspace_id = os.environ.get("CMUX_WORKSPACE_ID")
    cmux_surface_id = os.environ.get("CMUX_SURFACE_ID")
    if cmux_workspace_id or cmux_surface_id:
        state["multiplexer"] = "cmux"
        if cmux_workspace_id:
            state["_cmux_workspace_id"] = cmux_workspace_id
        if cmux_surface_id:
            state["_cmux_surface_id"] = cmux_surface_id
    elif os.environ.get("ZELLIJ_SESSION_NAME"):
        state["multiplexer"] = "zellij"
        state["zellij_session"] = os.environ["ZELLIJ_SESSION_NAME"]
        zellij_pane = os.environ.get("ZELLIJ_PANE_ID")
        if zellij_pane:
            state["zellij_pane_id"] = zellij_pane
    elif os.environ.get("TMUX"):
        state["multiplexer"] = "tmux"

    # Report the tmux binary path so the app doesn't need a hardcoded list
    if os.environ.get("TMUX"):
        import shutil
        tmux_bin = shutil.which("tmux")
        if tmux_bin:
            state["tmux_bin"] = tmux_bin

    # Include SSH client source port for remote tab matching
    ssh_client = os.environ.get("SSH_CLIENT")
    if ssh_client:
        parts = ssh_client.split()
        if len(parts) >= 2:
            state["ssh_client_port"] = parts[1]

    # Fetch any new lines from the JSONL file to stream to the app — only
    # CLIs with a JSONL project directory participate (Claude + forks).
    if SOURCE in SOURCE_JSONL_PROJECTS:
        new_lines = get_new_jsonl_lines(session_id, cwd)
        if new_lines:
            state["new_jsonl_lines"] = new_lines

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"
        if SOURCE in SOURCE_JSONL_PROJECTS:
            title = get_session_title(session_id, cwd)
            if title:
                state["session_title"] = title

    elif event == "PreToolUse":
        tool_name = data.get("tool_name")
        state["status"] = "running_tool"
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

        # AskUserQuestion: block and let the app UI handle it
        if tool_name == "AskUserQuestion":
            state["event"] = "PermissionRequest"
            state["status"] = "waiting_for_approval"

            response = send_event(state)

            if response:
                decision = response.get("decision", "ask")
                answers_raw = response.get("answers")

                if decision == "allow" and answers_raw:
                    # Build answers map: question text -> selected label(s)
                    answers_map = {}
                    questions = (tool_input or {}).get("questions", [])
                    for qi, q in enumerate(questions):
                        q_text = q.get("question", "")
                        if qi < len(answers_raw):
                            selected = answers_raw[qi]
                            if isinstance(selected, list):
                                answers_map[q_text] = ",".join(selected)
                            else:
                                answers_map[q_text] = str(selected)

                    output = {
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "allow",
                            "permissionDecisionReason": "Answered via Vibe Hub",
                            "updatedInput": {
                                "questions": questions,
                                "answers": answers_map,
                            },
                        }
                    }
                    print(json.dumps(output))
                    sys.exit(0)

                elif decision == "ask":
                    # Let Claude Code handle it in terminal
                    sys.exit(0)

            # No response - let Claude Code show its normal UI
            sys.exit(0)

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "always":
                # Allow and add a permanent rule for this tool
                tool_name = data.get("tool_name", "")
                rule = {"toolName": tool_name}
                # For Bash, include the command pattern
                if tool_name == "Bash" and isinstance(tool_input, dict):
                    cmd = tool_input.get("command", "")
                    if cmd:
                        rule["ruleContent"] = cmd
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "allow",
                            "updatedPermissions": [
                                {
                                    "type": "addRules",
                                    "rules": [rule],
                                    "behavior": "allow",
                                    "destination": "projectSettings",
                                }
                            ],
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via Vibe Hub",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # Turn ended via API error (rate limit, auth, billing). Mark waiting
        # so the user sees it's done (not stuck), with the error surfaced
        state["status"] = "waiting_for_input"
        state["stop_error"] = data.get("error") or data.get("message")

    elif event == "SubagentStart":
        # A subagent task is beginning — main session is still processing
        state["status"] = "processing"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - usually means back to waiting
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        # Compaction finished — return to processing so UI exits .compacting phase
        state["status"] = "processing"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
