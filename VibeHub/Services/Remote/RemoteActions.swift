import Foundation

@MainActor
enum RemoteActions {
    static func sendClaudeMessage(session: SessionState, text: String) async -> (ok: Bool, hint: String?) {
        guard let hostId = session.remoteHostId,
              let host = RemoteManager.shared.hosts.first(where: { $0.id == hostId }) else {
            await RemoteLog.shared.log(.warn, "sendClaudeMessage: no remote host")
            return (false, "no remote host")
        }
        guard let pid = session.pid else {
            await RemoteLog.shared.log(.warn, "sendClaudeMessage: no pid")
            return (false, "no pid")
        }

        // Strategy: try tmux send-keys first (most reliable), then fallback to TTY injection.

        // 1. Try tmux: find pane containing the claude pid.
        let tmuxResult = await sendClaudeViaTmux(host: host, pid: pid, text: text)
        if tmuxResult.ok {
            return tmuxResult
        }

        // 2. Fallback: inject text via TIOCSTI ioctl on the session's TTY.
        if let tty = session.tty {
            let ttyResult = await sendClaudeViaTTY(host: host, tty: tty, text: text)
            if ttyResult.ok {
                return ttyResult
            }
        }

        await RemoteLog.shared.log(.warn, "sendClaudeMessage: all methods failed for pid=\(pid)")
        return (false, tmuxResult.hint ?? "could not reach session")
    }

    /// Try sending via tmux send-keys on remote.
    private static func sendClaudeViaTmux(host: RemoteHost, pid: Int, text: String) async -> (ok: Bool, hint: String?) {
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

        let findResult = await RemoteInstaller.runSSHPython(host: host, script: finder, args: ["\(pid)"])
        let target = findResult.exitCode == 0 ? findResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        guard let target, !target.isEmpty else {
            await RemoteLog.shared.log(.info, "sendClaudeMessage: tmux target not found for pid=\(pid), will try TTY fallback")
            return (false, "tmux target not found")
        }

        // Send text + Enter
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "tmux send-keys -t '\(target)' -l '\(escaped)' ; tmux send-keys -t '\(target)' Enter"
        let r = await RemoteInstaller.runSSHResult(host: host, command: cmd, timeoutSeconds: 12)
        if r.exitCode != 0 {
            await RemoteLog.shared.log(.warn, "sendClaudeMessage: tmux failed exit=\(r.exitCode) stderr=\(r.stderr ?? "")")
            return (false, r.stderr?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? "ssh/tmux failed")
        }
        await RemoteLog.shared.log(.info, "sendClaudeMessage: ok via tmux target=\(target)")
        return (true, nil)
    }

    /// Fallback: inject text into TTY via TIOCSTI ioctl on remote.
    private static func sendClaudeViaTTY(host: RemoteHost, tty: String, text: String) async -> (ok: Bool, hint: String?) {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        let script = """
import os, fcntl, termios, struct, sys, base64

tty_path = sys.argv[1]
text = base64.b64decode(sys.argv[2]).decode('utf-8')

try:
    fd = os.open(tty_path, os.O_RDWR)
    for ch in text:
        for b in ch.encode('utf-8'):
            fcntl.ioctl(fd, termios.TIOCSTI, struct.pack('B', b))
    # Send Enter
    fcntl.ioctl(fd, termios.TIOCSTI, struct.pack('B', 10))
    os.close(fd)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
"""

        let b64 = Data(text.utf8).base64EncodedString()
        let r = await RemoteInstaller.runSSHPython(host: host, script: script, args: [shellQuote(ttyPath), b64], timeoutSeconds: 12)
        if r.exitCode != 0 {
            await RemoteLog.shared.log(.warn, "sendClaudeMessage: TTY injection failed tty=\(ttyPath) exit=\(r.exitCode) stderr=\(r.stderr ?? "")")
            return (false, r.stderr?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? "TTY injection failed")
        }
        await RemoteLog.shared.log(.info, "sendClaudeMessage: ok via TTY \(ttyPath)")
        return (true, nil)
    }

    static func sendOpenCodePrompt(session: SessionState, text: String) async -> (ok: Bool, hint: String?) {
        guard let hostId = session.remoteHostId,
              let host = RemoteManager.shared.hosts.first(where: { $0.id == hostId }) else {
            await RemoteLog.shared.log(.warn, "sendOpenCodePrompt: no remote host")
            return (false, "no remote host")
        }
        guard let pid = session.pid else {
            await RemoteLog.shared.log(.warn, "sendOpenCodePrompt: no pid")
            return (false, "no pid")
        }
        guard let sid = session.opencodeRawSessionId, !sid.isEmpty else {
            await RemoteLog.shared.log(.warn, "sendOpenCodePrompt: no opencode session")
            return (false, "no opencode session")
        }
        await RemoteLog.shared.log(.info, "sendOpenCodePrompt: pid=\(pid) sid=\(sid.prefix(8))...", hostId: hostId)

        let payload = """
 import json, socket, sys, base64, os

 sock_path = os.path.expanduser(f"~/.vibehub/ci-opencode-{sys.argv[1]}.sock")
 session_id = sys.argv[2]
 text = base64.b64decode(sys.argv[3]).decode('utf-8')

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

        // Encode prompt text as base64 argument to avoid stdin conflicts with heredoc.
        let b64 = Data(text.utf8).base64EncodedString()
        let r = await RemoteInstaller.runSSHPython(host: host, script: payload, args: ["\(pid)", shellQuote(sid), b64], timeoutSeconds: 12)
        if r.exitCode != 0 {
            await RemoteLog.shared.log(.warn, "sendOpenCodePrompt ssh failed: exit=\(r.exitCode) stderr=\(r.stderr ?? "")", hostId: hostId)
            let hint = r.stderr?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
                ?? r.output.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
                ?? "ssh/opencode control failed"
            return (false, hint)
        }
        await RemoteLog.shared.log(.info, "sendOpenCodePrompt: ok", hostId: hostId)
        return (true, nil)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
