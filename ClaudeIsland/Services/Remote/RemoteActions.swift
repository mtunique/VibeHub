import Foundation

@MainActor
enum RemoteActions {
    static func sendClaudeMessage(session: SessionState, text: String) async -> (ok: Bool, hint: String?) {
        guard let hostId = session.remoteHostId,
              let host = RemoteManager.shared.hosts.first(where: { $0.id == hostId }) else {
            return (false, "no remote host")
        }
        guard let pid = session.pid else {
            return (false, "no pid")
        }

        // Find tmux target containing the pid.
        let finder = """
import subprocess, sys

claude_pid = int(sys.argv[1])

def sh(args):
    return subprocess.check_output(args, text=True).strip()

try:
    panes = sh(['tmux','list-panes','-a','-F','#{session_name}:#{window_index}.#{pane_index} #{pane_pid}']).splitlines()
except Exception:
    sys.exit(2)

# Build parent map
pp = {}
for line in subprocess.check_output(['ps','-eo','pid=,ppid='], text=True).splitlines():
    p = line.strip().split()
    if len(p) != 2: continue
    pp[int(p[0])] = int(p[1])

anc = set()
cur = claude_pid
for _ in range(500):
    anc.add(cur)
    nxt = pp.get(cur)
    if not nxt or nxt == cur: break
    cur = nxt

for line in panes:
    parts = line.split(' ', 1)
    if len(parts) != 2: continue
    target = parts[0]
    try:
        pane_pid = int(parts[1])
    except Exception:
        continue
    if pane_pid in anc:
        print(target)
        sys.exit(0)

sys.exit(1)
"""

        let target = (await RemoteInstaller.runSSH(
            host: host,
            command: "python3 - <<'PY'\n\(finder)\nPY \(pid)"
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let target, !target.isEmpty else {
            return (false, "tmux target not found")
        }

        // Send text + Enter
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "tmux send-keys -t '\(target)' -l '\(escaped)' ; tmux send-keys -t '\(target)' Enter"
        _ = await RemoteInstaller.runSSH(host: host, command: cmd)
        return (true, nil)
    }

    static func sendOpenCodePrompt(session: SessionState, text: String) async -> (ok: Bool, hint: String?) {
        guard let hostId = session.remoteHostId,
              let host = RemoteManager.shared.hosts.first(where: { $0.id == hostId }) else {
            return (false, "no remote host")
        }
        guard let pid = session.pid else {
            return (false, "no pid")
        }
        guard let sid = session.opencodeRawSessionId, !sid.isEmpty else {
            return (false, "no opencode session")
        }

        let payload = """
import json, socket, sys

sock_path = f"/tmp/claude-island-opencode-{sys.argv[1]}.sock"
session_id = sys.argv[2]
text = sys.stdin.read()

req = json.dumps({"type":"prompt","session_id":session_id,"text":text}).encode('utf-8')

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sock_path)
s.sendall(req)
s.shutdown(socket.SHUT_WR)
try:
    s.recv(4096)
except Exception:
    pass
s.close()
"""

        // Pipe prompt text via stdin
        let cmd = "python3 - <<'PY'\n\(payload)\nPY \(pid) '\(sid)'"
        _ = await RemoteInstaller.runSSH(host: host, command: "printf %s " + shellQuote(text) + " | " + cmd)
        return (true, nil)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
