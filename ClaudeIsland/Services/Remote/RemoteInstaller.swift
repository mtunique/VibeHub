import Foundation

enum RemoteInstaller {
    static func installAll(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> RemoteInstallReport {
        let startedAt = Date()
        var steps: [RemoteInstallStep] = []

        steps.append(contentsOf: await installClaudeHooks(host: host, progress: progress))
        steps.append(contentsOf: await installOpenCodePlugin(host: host, progress: progress))

        if let progress { await progress("verify files") }

        steps.append(await step(
            name: "verify claude hook",
            command: "test -f ~/.claude/hooks/claude-island-state.py && echo ok || echo missing",
            result: await runSSHResult(host: host, command: "test -f ~/.claude/hooks/claude-island-state.py && echo ok || echo missing", timeoutSeconds: 12)
        ))

        steps.append(await step(
            name: "verify opencode plugin",
            command: "test -f ~/.config/opencode/plugins/claude-island.js && echo ok || echo missing",
            result: await runSSHResult(host: host, command: "test -f ~/.config/opencode/plugins/claude-island.js && echo ok || echo missing", timeoutSeconds: 12)
        ))

        return RemoteInstallReport(startedAt: startedAt, finishedAt: Date(), steps: steps)
    }

    static func installClaudeHooks(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        guard let script = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        steps.append(await step(
            name: "mkdir ~/.claude/hooks",
            command: "ssh \(host.sshTarget) 'mkdir -p ~/.claude/hooks'",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.claude/hooks", timeoutSeconds: 12)
        ))
        if let progress { await progress("upload claude hook") }
        steps.append(await step(
            name: "upload claude hook",
            command: "ssh \(host.sshTarget) 'base64 -d > ~/.claude/hooks/claude-island-state.py'",
            result: await uploadFileViaSSH(host: host, localURL: script, remotePath: "~/.claude/hooks/claude-island-state.py", timeoutSeconds: 20)
        ))
        steps.append(await step(
            name: "chmod claude hook",
            command: "ssh \(host.sshTarget) 'chmod 755 ~/.claude/hooks/claude-island-state.py'",
            result: await runSSHResult(host: host, command: "chmod 755 ~/.claude/hooks/claude-island-state.py", timeoutSeconds: 12)
        ))

        // Merge hook config into ~/.claude/settings.json (best effort)
        let py = """
import json, os, pathlib, subprocess

home = pathlib.Path.home()
settings_path = home / '.claude' / 'settings.json'
settings_path.parent.mkdir(parents=True, exist_ok=True)

data = {}
if settings_path.exists():
    try:
        data = json.loads(settings_path.read_text())
    except Exception:
        data = {}

hooks = data.get('hooks', {})

def detect_python():
    for c in ['python3', 'python']:
        try:
            subprocess.check_call(['which', c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return c
        except Exception:
            pass
    return 'python3'

python = detect_python()
cmd = f"{python} ~/.claude/hooks/claude-island-state.py"
hook_entry = [{"type": "command", "command": cmd}]
hook_entry_with_timeout = [{"type": "command", "command": cmd, "timeout": 86400}]

with_matcher = [{"matcher": "*", "hooks": hook_entry}]
with_matcher_timeout = [{"matcher": "*", "hooks": hook_entry_with_timeout}]
without_matcher = [{"hooks": hook_entry}]
precompact = [
    {"matcher": "auto", "hooks": hook_entry},
    {"matcher": "manual", "hooks": hook_entry},
]

events = {
    'UserPromptSubmit': without_matcher,
    'PreToolUse': with_matcher,
    'PostToolUse': with_matcher,
    'PermissionRequest': with_matcher_timeout,
    'Notification': with_matcher,
    'Stop': without_matcher,
    'SubagentStop': without_matcher,
    'SessionStart': without_matcher,
    'SessionEnd': without_matcher,
    'PreCompact': precompact,
}

def has_our_hook(entry):
    for h in entry.get('hooks', []):
        c = h.get('command', '')
        if 'claude-island-state.py' in c:
            return True
    return False

for ev, config in events.items():
    existing = hooks.get(ev)
    if isinstance(existing, list):
        ok = False
        for e in existing:
            if isinstance(e, dict) and has_our_hook(e):
                ok = True
                break
        if not ok:
            existing.extend(config)
            hooks[ev] = existing
    else:
        hooks[ev] = config

data['hooks'] = hooks
settings_path.write_text(json.dumps(data, indent=2, sort_keys=True))
"""

        steps.append(await step(
            name: "update ~/.claude/settings.json",
            command: "python3 - <<'PY' ... PY",
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeoutSeconds: 20)
        ))

        return steps
    }

    static func installOpenCodePlugin(host: RemoteHost, progress: (@Sendable (String) async -> Void)? = nil) async -> [RemoteInstallStep] {
        guard let plugin = Bundle.main.url(forResource: "claude-island-opencode", withExtension: "js") else {
            return []
        }

        var steps: [RemoteInstallStep] = []

        // Only install if OpenCode config exists.
        let checkResult = await runSSHResult(host: host, command: "test -f ~/.config/opencode/opencode.json && echo ok || echo missing", timeoutSeconds: 12)
        steps.append(await step(name: "check opencode config", command: "test -f ~/.config/opencode/opencode.json", result: checkResult))
        guard (checkResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok") else {
            return steps
        }

        steps.append(await step(
            name: "mkdir ~/.config/opencode/plugins",
            command: "ssh \(host.sshTarget) 'mkdir -p ~/.config/opencode/plugins'",
            result: await runSSHResult(host: host, command: "mkdir -p ~/.config/opencode/plugins", timeoutSeconds: 12)
        ))
        if let progress { await progress("upload opencode plugin") }
        steps.append(await step(
            name: "upload opencode plugin",
            command: "ssh \(host.sshTarget) 'base64 -d > ~/.config/opencode/plugins/claude-island.js'",
            result: await uploadFileViaSSH(host: host, localURL: plugin, remotePath: "~/.config/opencode/plugins/claude-island.js", timeoutSeconds: 20)
        ))

        let py = """
import json, pathlib

home = pathlib.Path.home()
cfg = home / '.config' / 'opencode' / 'opencode.json'
plugins = home / '.config' / 'opencode' / 'plugins'
plugin_file = plugins / 'claude-island.js'

data = json.loads(cfg.read_text())
uri = plugin_file.absolute().as_uri()

existing = data.get('plugin')
arr = []
if isinstance(existing, list):
    arr = existing
elif isinstance(existing, str):
    arr = [existing]

if uri not in arr:
    arr.append(uri)

data['plugin'] = arr
cfg.write_text(json.dumps(data, indent=2, sort_keys=True))
"""

        steps.append(await step(
            name: "update opencode.json plugins",
            command: "python3 - <<'PY' ... PY",
            result: await runSSHResult(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeoutSeconds: 20)
        ))

        return steps
    }

    private static func sshBaseArgs(host: RemoteHost) -> [String] {
        var args: [String] = []

        let controlPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-island", isDirectory: true)
            .appendingPathComponent("ssh-%C")
            .path

        args += [
            "-o", "BatchMode=yes",
            // Avoid hanging forever on network issues.
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            // Avoid interactive host key prompts; accept new hosts and still protect against MITM changes.
            "-o", "StrictHostKeyChecking=accept-new",
            // Force GSSAPI auth only: prevents intermittent "Miscellaneous failure" that occurs
            // when SSH tries gssapi-with-mic alongside other methods.
            "-o", "PreferredAuthentications=gssapi-with-mic",
            // ControlPath: reuse the ControlMaster socket created by SSHForwarder.
            // Must match the path in SSHForwarder.buildArgs exactly.
            "-o", "ControlPath=\(controlPath)",
        ]
        if let port = host.port { args += ["-p", String(port)] }
        if let key = host.identityFile, !key.isEmpty { args += ["-i", key] }
        return args
    }

    static func runSSH(host: RemoteHost, command: String) async -> String? {
        let r = await runSSHResult(host: host, command: command, timeoutSeconds: 20)
        guard r.exitCode == 0 else { return nil }
        return r.output
    }

    static func runSSHResult(host: RemoteHost, command: String, timeoutSeconds: Int) async -> ProcessResult {
        let sshPath = "/usr/bin/ssh"
        var args = sshBaseArgs(host: host)
        args.append(host.sshTarget)
        args.append(command)

        // Run via login shell so ssh inherits the same environment as Terminal
        // (eg SSH_AUTH_SOCK / corp auth envs), which often fixes jump-proxy auth.
        let cmd = shellEnvPrefix() + shellJoin([sshPath] + args)
        return await runShellResult(cmd, timeoutSeconds: timeoutSeconds)
    }

    // Upload a local file to the remote by base64-encoding its content and piping it through SSH.
    // This avoids SCP/SFTP entirely and works with any standard SSH connection.
    private static func uploadFileViaSSH(host: RemoteHost, localURL: URL, remotePath: String, timeoutSeconds: Int) async -> ProcessResult {
        guard let data = try? Data(contentsOf: localURL) else {
            return ProcessResult(output: "", exitCode: 1, stderr: "failed to read local file: \(localURL.path)")
        }
        // base64 output uses only A-Za-z0-9+/= — safe inside single quotes on the remote shell
        let encoded = data.base64EncodedString()
        let command = "printf '%s' '\(encoded)' | base64 -d > \(remotePath)"
        return await runSSHResult(host: host, command: command, timeoutSeconds: timeoutSeconds)
    }

    private static func runShellResult(_ command: String, timeoutSeconds: Int) async -> ProcessResult {
        let zsh = "/bin/zsh"
        let args = ["-lc", command]
        let res = await ProcessExecutor.shared.runWithResult(zsh, arguments: args, timeoutSeconds: timeoutSeconds)
        switch res {
        case .success(let r):
            return r
        case .failure(let e):
            return ProcessResult(output: "", exitCode: (e.exitCode ?? 1), stderr: e.rawStderr ?? e.errorDescription)
        }
    }

    nonisolated private static func shellJoin(_ args: [String]) -> String {
        args.map(shellQuote).joined(separator: " ")
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellEnvPrefix() -> String {
        // Make GUI-launched ssh behave more like Terminal by grabbing launchd env.
        // (Many corp auth setups populate SSH_AUTH_SOCK/KRB5CCNAME in launchd.)
        let prefix = """
SSH_AUTH_SOCK_VAL=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true);
if [ -n \"$SSH_AUTH_SOCK_VAL\" ]; then export SSH_AUTH_SOCK=\"$SSH_AUTH_SOCK_VAL\"; fi;
KRB5CCNAME_VAL=$(launchctl getenv KRB5CCNAME 2>/dev/null || true);
if [ -n \"$KRB5CCNAME_VAL\" ]; then export KRB5CCNAME=\"$KRB5CCNAME_VAL\"; fi;
"""
        return prefix + " "
    }

    private static func step(name: String, command: String, result: ProcessResult) async -> RemoteInstallStep {
        RemoteInstallStep(
            name: name,
            command: command,
            ok: result.exitCode == 0,
            exitCode: result.exitCode,
            stdout: trim(result.output),
            stderr: trim(result.stderr ?? "")
        )
    }

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 4000 {
            return String(t.prefix(4000)) + "\n..."
        }
        return t
    }
}
